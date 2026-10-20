import Foundation

/// 瑶台沙盒文件系统：根目录固定 <Documents>/yaotai/
/// 所有命令与工具都在这棵树里活动，路径穿越（..）一律拒绝
final class WorkbenchFS {
    static let shared = WorkbenchFS()

    let root: URL
    let home: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        root = docs.appendingPathComponent("yaotai", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // 预置欢迎文件
        let readme = home.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? """
            # 瑶台 · Yaotai
            内置开发环境。支持 `ls cd cat mkdir echo node git curl` 等命令，
            `node xxx.js` 用内置 JS 引擎真实执行；网页可写 .html 后 `open x.html` 预览。
            在「AI 助手」页可直接让 AI 帮你操作这一切（需设置页填官方 API Key）。
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// 把用户输入的路径解析成沙盒内绝对 URL；越界返回 nil
    func resolve(_ path: String, cwd: URL) -> URL? {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return cwd }
        if p == "~" { return home }
        if p.hasPrefix("~/") { p = String(p.dropFirst(2)) }
        let base = (p.hasPrefix("/")) ? root : cwd
        let comps = p.components(separatedBy: "/")
        var cur = base
        for c in comps {
            if c.isEmpty || c == "." { continue }
            if c == ".." {
                if cur.path == root.path { return nil } // 拒绝穿越出根
                cur = cur.deletingLastPathComponent()
                continue
            }
            cur = cur.appendingPathComponent(c)
        }
        // 双重校验：必须仍在 root 之内
        guard cur.path == root.path || cur.path.hasPrefix(root.path + "/") else { return nil }
        return cur
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    func list(_ url: URL) -> [(name: String, isDir: Bool, size: Int64)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return [] }
        return items.map { u in
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &d)
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (u.lastPathComponent, d.boolValue, Int64(size))
        }.sorted { a, b in
            a.name != b.name && (a.isDir && !b.isDir)
        }
    }

    func read(_ url: URL) -> String? {
        guard isDir(url) == false else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 显示用相对路径（以 ~ 开头）
    func display(_ url: URL) -> String {
        if url.path.hasPrefix(home.path) { return "~" + url.path.dropFirst(home.path.count) }
        if url.path.hasPrefix(root.path) { return url.path.dropFirst(root.path.count - 1).description }
        return url.path
    }
}
