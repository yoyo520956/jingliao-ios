import Foundation
import zlib

/// GitHub 客户端：PAT 登录 + 列仓库 + 下载 zip 解压到沙盒
final class GitHubClient {
    static let shared = GitHubClient()

    struct Repo: Identifiable, Decodable {
        var id: Int
        var name: String
        var full_name: String
        var description: String?
        var html_url: String
        var private_: Bool
        var updated_at: String
        enum CodingKeys: String, CodingKey {
            case id, name, full_name, description, html_url
            case private_ = "private"
            case updated_at
        }
    }

    static var pat: String { UserDefaults.standard.string(forKey: "jl.ghpat") ?? "" }

    /// 把 PAT 织进 https URL：https://x-access-token:<PAT>@github.com/owner/repo
    static func injectToken(_ url: String, token: String) -> String {
        guard url.hasPrefix("https://"), !token.isEmpty, !url.contains("x-access-token") else { return url }
        return url.replacingOccurrences(of: "https://", with: "https://x-access-token:\(token)@")
    }

    func authHeaders() -> [String: String] {
        var h = ["Accept": "application/vnd.github+json", "User-Agent": "Yaotai-App"]
        if !Self.pat.isEmpty { h["Authorization"] = "Bearer \(Self.pat)" }
        return h
    }

    /// 当前登录用户（验证 PAT 是否有效）
    @MainActor
    func checkLogin() async -> (login: String?, error: String?) {
        guard !Self.pat.isEmpty else { return (nil, "未填 PAT") }
        guard let url = URL(string: "https://api.github.com/user") else { return (nil, "URL 错误") }
        var req = URLRequest(url: url)
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return (nil, "HTTP \(code)（PAT 无效或过期）") }
            if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let login = json["login"] as? String {
                return (login, nil)
            }
            return (nil, "响应解析失败")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    @MainActor
    func listRepos() async -> [Repo] {
        guard !Self.pat.isEmpty else { return [] }
        guard let url = URL(string: "https://api.github.com/user/repos?per_page=100&sort=updated") else { return [] }
        var req = URLRequest(url: url)
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (d, _) = try await URLSession.shared.data(for: req)
            return (try? JSONDecoder().decode([Repo].self, from: d)) ?? []
        } catch {
            return []
        }
    }

    /// 解压 zip 到目标目录（仓库 zip 内有一层 <repo>-<branch>/，剥掉它直接落到目标）
    static func unzip(_ data: Data, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("gh_\(UUID().uuidString.prefix(8)).zip")
        try data.write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }

        // 手写 ZIP 中央目录解析（无系统解压 API）：central directory → entries → raw deflate
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { throw NSError(domain: "Yaotai", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 zip"]) }
        let cdOffset = Int(eocd.offset)
        var idx = cdOffset
        guard let cdEntries = zipEntries(bytes, at: &idx, count: Int(eocd.count)) else {
            throw NSError(domain: "Yaotai", code: 2, userInfo: [NSLocalizedDescriptionKey: "zip 目录解析失败"])
        }
        for e in cdEntries where !e.name.hasSuffix("/") {
            let comps = e.name.components(separatedBy: "/")
            // 剥掉第一层目录（owner-repo-branch/）
            guard comps.count >= 2 else { continue }
            let rel = comps.dropFirst().joined(separator: "/")
            let outURL = dest.appendingPathComponent(rel)
            guard outURL.path.hasPrefix(dest.path) else { continue }
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let raw = Data(bytes[e.offset..<(e.offset + e.compSize)])
            let content = raw.count == e.size ? raw : try inflate(raw, expected: e.size)
            try content.write(to: outURL)
        }
    }

    // MARK: - ZIP 解析（中央目录 + raw inflate）

    struct EOCD { let offset: Int; let count: Int }
    static func findEOCD(_ b: [UInt8]) -> EOCD? {
        let minStart = b.count - 22 - 65535
        var i = b.count - 22
        while i >= max(0, minStart) {
            if b[i] == 0x50 && b[i+1] == 0x4b && b[i+2] == 0x05 && b[i+3] == 0x06 {
                let count = Int(b[i+10]) | Int(b[i+11]) << 8
                let cdOff = Int(b[i+16]) | Int(b[i+17]) << 8 | Int(b[i+18]) << 16 | Int(b[i+19]) << 24
                return EOCD(offset: cdOff, count: count)
            }
            i -= 1
        }
        return nil
    }

    struct ZEntry { let name: String; let offset: Int; let compSize: Int; let size: Int }
    static func zipEntries(_ b: [UInt8], at idx: inout Int, count: Int) -> [ZEntry]? {
        var res: [ZEntry] = []
        for _ in 0..<count {
            guard idx + 46 <= b.count, b[idx] == 0x50, b[idx+1] == 0x4b, b[idx+2] == 0x01, b[idx+3] == 0x02 else { return nil }
            let compSize = rd32(b, idx+20)
            let size = rd32(b, idx+24)
            let nameLen = Int(b[idx+28]) | Int(b[idx+29]) << 8
            let extraLen = Int(b[idx+30]) | Int(b[idx+31]) << 8
            let commentLen = Int(b[idx+32]) | Int(b[idx+33]) << 8
            let lho = rd32(b, idx+42)
            let nameStart = idx + 46
            guard nameStart + nameLen <= b.count else { return nil }
            let name = String(decoding: Data(b[nameStart..<(nameStart + nameLen)]), as: UTF8.self)
            // 本地 header 里的数据偏移 = lho + 30 + nameLen(+extraLen)
            var dataOff = lho + 30
            guard dataOff + 26 <= b.count else { return nil }
            let lNameLen = Int(b[dataOff+26]) | Int(b[dataOff+27]) << 8
            let lExtraLen = Int(b[dataOff+28]) | Int(b[dataOff+29]) << 8
            dataOff += lNameLen + lExtraLen
            res.append(ZEntry(name: name, offset: dataOff, compSize: compSize, size: size))
            idx = nameStart + nameLen + extraLen + commentLen
        }
        return res
    }

    static func rd32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24
    }

    /// 系统 libz raw inflate（zip 标准 deflate 流，windowBits=-15）
    /// ⚠️ 不用 compression_stream：真机对标准 zip deflate 流实测不可靠（拆解者项目踩过）
    static func inflate(_ data: Data, expected: Int) throws -> Data {
        var src = [UInt8](data)
        var out = [UInt8](repeating: 0, count: expected)
        var produced: uInt = 0
        var strm = z_stream()
        guard inflateInit2_(&strm, -15, nil, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NSError(domain: "Yaotai", code: 3, userInfo: [NSLocalizedDescriptionKey: "inflateInit2_ 失败"])
        }
        defer { inflateEnd(&strm) }
        strm.next_in = UnsafeMutablePointer(mutating: src)
        strm.avail_in = uInt(src.count)
        strm.next_out = UnsafeMutablePointer(mutating: out)
        strm.avail_out = uInt(out.count)
        let ret = zlib.inflate(&strm, Z_FINISH)
        produced = uInt(out.count) - strm.avail_out
        guard ret == Z_STREAM_END || ret == Z_OK else {
            throw NSError(domain: "Yaotai", code: 4, userInfo: [NSLocalizedDescriptionKey: "inflate 失败 ret=\(ret)"])
        }
        return Data(out.prefix(Int(produced)))
    }
}
