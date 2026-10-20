import Foundation

// ── DeepSeek 网页协议常量（对齐 ds-free-api 2026-10 风控版）──────────────

enum DSConfig {
    static let apiBase = "https://chat.deepseek.com/api/v0"
    static let wasmURLString = "https://fe-static.deepseek.com/chat/static/sha3_wasm_bg.7b9ca65ddd.wasm"
    static let leimURLString = "https://hif-leim.deepseek.com/query"
    static let dliqURLString = "https://hif-dliq.deepseek.com/query"
    static let origin = "https://chat.deepseek.com"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    static let secChUa = "\"Chromium\";v=\"140\", \"Google Chrome\";v=\"140\", \"Not-A.Brand\";v=\"24\""
    static let clientVersion = "2.5.0"
    static let clientPlatform = "web"
    static let clientLocale = "zh_CN"
    static let clientBundleID = "chat.deepseek.web"
    static let clientOS = "web"
    static let deviceModel = "Windows 10 x64"
    static let modelType = "deep_seek_chat"
    static let completionSource = "input"
}

// ── PoW 挑战 ──────────────────────────────────────────────────────────

struct DSChallenge {
    var algorithm: String = ""
    var challenge: String = ""
    var salt: String = ""
    var difficulty: Double = 0
    var expireAt: Double = 0
    var signature: String = ""
    var targetPath: String = ""

    static func parse(_ json: [String: Any]) -> DSChallenge? {
        let c = DSChallenge(
            algorithm: json["algorithm"] as? String ?? "",
            challenge: json["challenge"] as? String ?? "",
            salt: json["salt"] as? String ?? "",
            difficulty: (json["difficulty"] as? NSNumber)?.doubleValue ?? 0,
            expireAt: (json["expire_at"] as? NSNumber)?.doubleValue ?? 0,
            signature: json["signature"] as? String ?? "",
            targetPath: json["target_path"] as? String ?? "/api/v0/chat/completion")
        guard !c.challenge.isEmpty, !c.salt.isEmpty else { return nil }
        return c
    }

    /// X-Ds-Pow-Response 头：base64(JSON{algorithm,challenge,salt,answer,signature,target_path})
    func powResponseHeader(answer: Int64) -> String {
        let obj: [String: Any] = [
            "algorithm": algorithm,
            "challenge": challenge,
            "salt": salt,
            "answer": NSNumber(value: answer),
            "signature": signature,
            "target_path": targetPath,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "" }
        return d.base64EncodedString()
    }
}

// ── JSON 宽松取值工具 ──────────────────────────────────────────────────

extension Dictionary where Key == String, Value == Any {
    func dstr(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func dnum(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }
    func ddict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func darr(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
    /// 深层路径取值：path("data","user","token")
    func dpath(_ keys: String...) -> Any? {
        var cur: Any? = self
        for k in keys {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[k]
        }
        return cur
    }
}

/// 通用信封 {code, msg, data:{biz_code, biz_msg, biz_data:...}}
struct DSEnvelope {
    var code: Int
    var msg: String
    var data: [String: Any]?
    var bizData: [String: Any]?
    var bizCode: Int
    var bizMsg: String

    static func parse(_ data: Data) -> DSEnvelope? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let inner = root["data"] as? [String: Any]
        let biz = inner?["biz_data"] as? [String: Any]
        return DSEnvelope(
            code: (root["code"] as? NSNumber)?.intValue ?? -1,
            msg: root["msg"] as? String ?? "",
            data: inner,
            bizData: biz,
            bizCode: (inner?["biz_code"] as? NSNumber)?.intValue ?? 0,
            bizMsg: inner?["biz_msg"] as? String ?? "")
    }
}

// ── 引擎事件 ──────────────────────────────────────────────────────────

enum DSEvent {
    case thinkDelta(String)
    case contentDelta(String)
    case meta(Int64)
    case done(finishReason: String?)
}

struct DSError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// ── 引擎日志 ──────────────────────────────────────────────────────────

final class EngineLog: ObservableObject {
    static let shared = EngineLog()
    @Published var lines: [String] = []
    private let lock = NSLock()
    func add(_ s: String) {
        lock.lock()
        let line = "[\(Self.stamp())] \(s)"
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lines.append(line)
            if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
        }
    }
    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
