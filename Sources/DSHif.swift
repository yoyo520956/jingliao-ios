import Foundation

/// x-hif-leim / x-hif-dliq 风控令牌（hif-leim.deepseek.com / hif-dliq.deepseek.com，无鉴权，按设备缓存）
final class DSHif {
    static let shared = DSHif()

    struct Entry {
        var leim: String = ""
        var leimExp: Date = .distantPast
        var dliq: String = ""
        var dliqExp: Date = .distantPast
    }

    var enabled = true
    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    private struct Tok: @unchecked Sendable {}

    func cachedToken(_ kind: String, deviceID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let e = cache[deviceID] else { return nil }
        let now = Date()
        if kind == "leim", !e.leim.isEmpty, e.leimExp > now { return e.leim }
        if kind == "dliq", !e.dliq.isEmpty, e.dliqExp > now { return e.dliq }
        return nil
    }

    func token(_ kind: String, deviceID: String) async -> String? {
        if let c = cachedToken(kind, deviceID: deviceID) { return c }
        guard enabled, let url = URL(string: kind == "leim" ? DSConfig.leimURLString : DSConfig.dliqURLString) else { return nil }
        let identity = DSIdentity(deviceID: deviceID)
        var h = identity.baseHeaders(site: "cross-site")
        h.removeValue(forKey: "Referer")
        h.removeValue(forKey: "Origin")
        let req = DSIdentity.request(url, method: "GET", headers: h, timeout: 20)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            var value = ""
            var ttl: Double = 600
            // 解析顺序：JSON 常见字段 → 响应头
            if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                value = root.dstr("token") ?? root.dstr(kind) ?? root.dstr("value") ?? ""
                if let inner = (root["data"] as? [String: Any]) ?? (root["biz_data"] as? [String: Any]) {
                    if value.isEmpty { value = inner.dstr("token") ?? inner.dstr(kind) ?? "" }
                    if let e = inner.dnum("expire_at") { ttl = max(60, e - Date().timeIntervalSince1970) }
                }
                if let t = root.dnum("ttl") { ttl = t }
                if let t = root.dnum("expire_at") { ttl = max(60, t - Date().timeIntervalSince1970) }
            }
            if value.isEmpty, let hs = http?.allHeaderFields {
                let key = kind == "leim" ? "x-hif-leim" : "x-hif-dliq"
                for (k, v) in hs where (k as? String)?.lowercased() == key { value = v as? String ?? "" }
                for (k, v) in hs where (k as? String)?.lowercased() == "x-hif-ttl" {
                    if let t = Double(v as? String ?? "") { ttl = t }
                }
            }
            guard !value.isEmpty else {
                EngineLog.shared.add("hif/\(kind) 未取到令牌（HTTP \(http?.statusCode ?? 0)）")
                return nil
            }
            lock.lock()
            var e = cache[deviceID] ?? Entry()
            if kind == "leim" { e.leim = value; e.leimExp = Date().addingTimeInterval(max(30, ttl - 15)) }
            else { e.dliq = value; e.dliqExp = Date().addingTimeInterval(max(30, ttl - 15)) }
            cache[deviceID] = e
            lock.unlock()
            EngineLog.shared.add("hif/\(kind) 令牌已缓存 ttl=\(Int(ttl))s")
            return value
        } catch {
            EngineLog.shared.add("hif/\(kind) 请求失败: \(error.localizedDescription)")
            return nil
        }
    }
}
