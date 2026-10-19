import Foundation
import WebKit

/// 隐藏 WKWebView 运行官方 sha3 wasm，求解 DeepSeekHashV1 PoW 挑战
final class DSPowSolver: NSObject, WKScriptMessageHandler {
    static let shared = DSPowSolver()

    private var webview: WKWebView?
    private var wasmLoaded = false
    private var wasmBytes: Data?
    private var readyCont: CheckedContinuation<Void, Error>?
    private var wasmCont: CheckedContinuation<Void, Error>?
    private var pendingError: String?
    private let lock = NSLock()

    // ── 对外 ────────────────────────────────────────────────────────

    func solve(_ c: DSChallenge) async throws -> Int64 {
        guard c.algorithm == "DeepSeekHashV1" else {
            throw DSError(message: "不支持的 PoW 算法: \(c.algorithm)")
        }
        try await ensureReady()
        try await ensureWasm()
        guard let wv = self.webview else { throw DSError(message: "PoW WebView 未就绪") }
        let js = "__solve(\(Self.jsString(c.challenge)), \(Self.jsString(c.salt)), \(c.expireAt), \(c.difficulty))"
        let result = try await wv.evaluateJavaScript(js)
        guard let dict = result as? [String: Any] else {
            throw DSError(message: "PoW 返回异常: \(String(describing: result))")
        }
        if let e = dict["error"] as? String { throw DSError(message: "PoW 求解失败: \(e)") }
        if let n = dict["answer"] as? NSNumber { return n.int64Value }
        if let d = dict["answer"] as? Double { return Int64(d) }
        throw DSError(message: "PoW 答案缺失")
    }

    // ── 准备 ────────────────────────────────────────────────────────

    private func ensureReady() async throws {
        lock.lock()
        let has = webview != nil
        lock.unlock()
        if !has { try await setupWebview() }
    }

    private func ensureWasm() async throws {
        lock.lock()
        let loaded = wasmLoaded
        lock.unlock()
        if loaded { return }
        let bytes: Data
        if let cached = self.wasmBytes { bytes = cached }
        else {
            bytes = try await Self.downloadWasm()
            self.wasmBytes = bytes
        }
        guard let wv = self.webview else { throw DSError(message: "WebView 未就绪") }
        let b64 = bytes.base64EncodedString()
        pendingError = nil
        let got: Void = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock(); wasmCont = cont; lock.unlock()
            Task { @MainActor in
                wv.evaluateJavaScript("__loadWasm('\(b64)')", completionHandler: nil)
            }
        }
        _ = got
        lock.lock(); let err = pendingError; lock.unlock()
        if let err { throw DSError(message: "wasm 加载失败: \(err)") }
    }

    private static func downloadWasm() async throws -> Data {
        let fm = FileManager.default
        if let doc = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let f = doc.appendingPathComponent("sha3_wasm.bin")
            if let d = try? Data(contentsOf: f), d.count > 100_000 { return d }
        }
        var req = URLRequest(url: URL(string: DSConfig.wasmURLString)!)
        req.timeoutInterval = 60
        req.setValue(DSConfig.userAgent, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200, d.count > 100_000 else {
            throw DSError(message: "PoW wasm 下载失败（\(d.count)B）")
        }
        if let doc = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? d.write(to: doc.appendingPathComponent("sha3_wasm.bin"))
        }
        return d
    }

    private func setupWebview() async throws {
        guard let url = Bundle.main.url(forResource: "pow", withExtension: "html") else {
            throw DSError(message: "pow.html 资源缺失")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock(); readyCont = cont; lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cfg = WKWebViewConfiguration()
                cfg.userContentController.add(self, name: "pow")
                let wv = WKWebView(frame: CGRect(x: -20, y: -20, width: 2, height: 2), configuration: cfg)
                wv.alpha = 0.01
                if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                   let win = scene.windows.first(where: { $0.isKey }) ?? scene.windows.first {
                    win.addSubview(wv)
                }
                self.lock.lock(); self.webview = wv; self.lock.unlock()
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
        // ready 消息在 continuation resume 时已消费
    }

    // ── JS 消息 ─────────────────────────────────────────────────────

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "pow", let d = message.body as? [String: Any], let t = d["t"] as? String else { return }
        lock.lock()
        switch t {
        case "ready":
            let c = readyCont; readyCont = nil; lock.unlock()
            c?.resume(returning: ())
        case "wasmok":
            wasmLoaded = true
            let c = wasmCont; wasmCont = nil; lock.unlock()
            c?.resume(returning: ())
        case "wasmerr":
            pendingError = d["e"] as? String ?? "未知"
            let c = wasmCont; wasmCont = nil; lock.unlock()
            c?.resume(returning: ())
        default:
            lock.unlock()
        }
    }

    private static func jsString(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'" + esc + "'"
    }
}

// evaluateJavaScript 异步包装（iOS16 可用，避开 iOS15 专属 async API 歧义）
extension WKWebView {
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            evaluateJavaScript(script) { result, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: result) }
            }
        }
    }
}
