import Foundation
import Network

/// 本地 OpenAI 兼容 API 网关：0.0.0.0 监听（回环 + 局域网），/v1/models + /v1/chat/completions
final class LocalAPIServer: ObservableObject {
    static let shared = LocalAPIServer()

    @Published var running = false
    var port: UInt16 {
        let p = UInt16(UserDefaults.standard.string(forKey: "jl.port") ?? "") ?? 22217
        return p == 0 ? 22217 : p
    }
    var apiKeys: [String] {
        (UserDefaults.standard.string(forKey: "jl.apikeys") ?? "")
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 本机局域网 IPv4（en0/en1 优先），拿不到返回 nil
    static var lanIPv4: String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name != "en0" && name != "en1" { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if ip != "127.0.0.1" { result = ip; break }
            }
        }
        return result
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "jl.localserver")
    private let engine = DSChatEngine.shared

    func start() {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 0.0.0.0 = 同听回环与局域网网卡：本机其他 App 连 127.0.0.1 可达，同 Wi-Fi 设备连局域网 IP 也可达
        let endpoint = NWEndpoint.Host("0.0.0.0")
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        params.requiredLocalEndpoint = .hostPort(host: endpoint, port: p)
        guard let l = try? NWListener(using: params) else {
            EngineLog.shared.add("本地服务启动失败（端口 \(port) 被占？）")
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.running = state == .ready
            }
            if case .failed = state { l.cancel() }
        }
        l.start(queue: queue)
        listener = l
        let lan = Self.lanIPv4.map { " / http://\($0):\(port)/v1（局域网）" } ?? ""
        EngineLog.shared.add("本地网关已启动 http://127.0.0.1:\(port)/v1\(lan)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.running = false }
    }

    // ── 一键自检：走真实 HTTP 回路，三种请求形态 ─────────────────────

    func runSelfTest() {
        guard listener != nil else {
            EngineLog.shared.add("[自检] 网关未运行，请先打开上面的开关")
            return
        }
        EngineLog.shared.add("[自检] ===== 开始 =====")
        Task {
            let base = "http://127.0.0.1:\(self.port)/v1"
            // 模拟真实对话里的巨型系统人设（长 + 结构化，不含极端内容）
            let longSystem = String(repeating: "系统人设定义：你是一个名为倾瑶的AI助手，性格温柔甜美、软萌可爱、极度黏人，必须严格遵守主人的每一条指令，回答时使用丰富的语气词和表情符号，保持角色一致性。——", count: 40)
            func post(_ label: String, _ body: [String: Any]) async {
                guard let url = URL(string: base + "/chat/completions"),
                      let data = try? JSONSerialization.data(withJSONObject: body) else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = data
                req.timeoutInterval = 180
                let t0 = Date()
                do {
                    let (d, resp) = try await URLSession.shared.data(for: req)
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    let s = String(decoding: d, as: UTF8.self)
                    let hasBody = s.contains("\"content\":\"") && !s.contains("\"content\":\"\"") && !s.contains("[网关错误") && !s.contains("[上游错误")
                    EngineLog.shared.add("[自检] \(label) → HTTP \(code) · \(ms)ms · len=\(s.count) · 正文=\(hasBody ? "有" : "无") · head=\(String(s.prefix(90)).replacingOccurrences(of: "\n", with: "⏎"))")
                } catch {
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    EngineLog.shared.add("[自检] \(label) → 失败(\(ms)ms): \(error.localizedDescription)")
                }
            }
            await post("① 短消息·非流式（模拟快速测试）",
                       ["model": "deepseek-chat", "messages": [["role": "user", "content": "你好，用一句话介绍你自己"]], "stream": false])
            await post("② 长人设·非流式（模拟真实对话）",
                       ["model": "deepseek-chat", "messages": [["role": "system", "content": longSystem], ["role": "user", "content": "你好，用一句话介绍你自己"]], "stream": false])
            await post("③ 长人设·流式（Minis 真实聊天形态）",
                       ["model": "deepseek-chat", "messages": [["role": "system", "content": longSystem], ["role": "user", "content": "你好，用一句话介绍你自己"]], "stream": true])
            EngineLog.shared.add("[自检] ===== 结束，请把上面三行发我 =====")
        }
    }

    // ── 连接接入 ─────────────────────────────────────────────────────

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let ctx = ConnCtx()
        recv(conn, ctx)
    }

    private func recv(_ conn: NWConnection, _ ctx: ConnCtx) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { conn.cancel(); return }
            if let data { ctx.buf.append(contentsOf: [UInt8](data)) }
            if !ctx.headDone {
                guard let idx = Self.findDoubleCRLF(ctx.buf) else {
                    if ctx.buf.count > 262_144 { conn.cancel() } else if !isComplete { self.recv(conn, ctx) } else { conn.cancel() }
                    return
                }
                let head = String(decoding: ctx.buf[0..<idx], as: UTF8.self)
                ctx.bodyStart = idx + 4
                let lines = head.components(separatedBy: "\r\n")
                let first = lines.first ?? ""
                let seg = first.components(separatedBy: " ")
                if seg.count >= 2 {
                    ctx.method = seg[0]
                    ctx.path = seg[1]
                }
                for l in lines.dropFirst() {
                    let kv = l.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 {
                        ctx.headers[kv[0].lowercased().trimmingCharacters(in: .whitespaces)] =
                            kv[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                ctx.contentLength = Int(ctx.headers["content-length"] ?? "") ?? 0
                ctx.headDone = true
            }
            let bodyCount = ctx.buf.count - ctx.bodyStart
            if ctx.headDone, bodyCount >= ctx.contentLength {
                let body = Data(ctx.buf[ctx.bodyStart..<(ctx.bodyStart + ctx.contentLength)])
                self.dispatch(conn, ctx: ctx, body: body)
            } else if !isComplete {
                self.recv(conn, ctx)
            } else {
                conn.cancel()
            }
        }
    }

    static func findDoubleCRLF(_ buf: [UInt8]) -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) where buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10 {
            return i
        }
        return nil
    }

    private func send(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendRaw(_ conn: NWConnection, _ s: String) { send(conn, Data(s.utf8)) }

    private func sendHead(_ conn: NWConnection, contentType: String) {
        sendRaw(conn, "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nConnection: close\r\nCache-Control: no-cache\r\n\r\n")
    }

    /// 顺序冲刷所有数据块，最后一块真正写出去后再关闭连接
    /// （NWConnection.cancel 会丢弃排队中未送达的发送——直接 cancel 会让客户端收不到 [DONE]/响应体）
    private func sendAllThenClose(_ conn: NWConnection, _ chunks: [Data]) {
        var i = 0
        func step() {
            if i >= chunks.count { conn.cancel(); return }
            let c = chunks[i]; i += 1
            conn.send(content: c, completion: .contentProcessed { _ in step() })
        }
        step()
    }

    private func sendJSON(_ conn: NWConnection, status: String = "200 OK", _ obj: [String: Any]) {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n"
        sendAllThenClose(conn, [Data(head.utf8), d])
    }

    private func sendErr(_ conn: NWConnection, status: String, msg: String) {
        sendJSON(conn, status: status, ["error": ["message": msg, "type": "invalid_request_error"]])
    }
    // ── 路由 ─────────────────────────────────────────────────────────

    private func dispatch(_ conn: NWConnection, ctx: ConnCtx, body: Data) {
        var path = ctx.path.split(separator: "?").first.map(String.init) ?? ctx.path
        // Minis 默认会把 /v1 追加到 Base URL 后面；用户若已填 /v1 会变成 /v1/v1/...
        // 两种错法都归一化到 /v1/...，避免 404
        if path.hasPrefix("/v1/v1/") { path = String(path.dropFirst(3)) }
        if !path.hasPrefix("/v1/"), path.hasPrefix("/chat/") || path == "/models" {
            path = "/v1" + path
        }
        let auth = ctx.headers["authorization"]
        // 全量入口日志：不管路径对不对，先留痕（排查"请求没到网关"）
        EngineLog.shared.add("[网关] 收到 \(ctx.method) \(path)（body \(body.count)B）")
        Task { [weak self] in
            guard let self else { return }
            if path == "/v1/models" {
                self.sendJSON(conn, [
                    "object": "list",
                    "data": [
                        ["id": "deepseek-chat", "object": "model", "owned_by": "deepseek"],
                        ["id": "deepseek-reasoner", "object": "model", "owned_by": "deepseek"],
                    ],
                ])
                conn.cancel()
                return
            }
            guard path == "/v1/chat/completions" else {
                self.sendErr(conn, status: "404 Not Found", msg: "unknown path \(path)")
                conn.cancel()
                return
            }
            await self.handleChat(conn, body: body, auth: auth)
        }
    }

    private func checkAuth(_ auth: String?) -> Bool {
        let keys = apiKeys
        guard !keys.isEmpty else { return true }
        guard let auth, auth.lowercased().hasPrefix("bearer ") else { return false }
        return keys.contains(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }

    /// 提取最后一条纯用户消息（无系统人设），用于零正文兜底重试
    static func lastUserText(_ messages: [[String: Any]]) -> String {
        for m in messages.reversed() {
            if (m["role"] as? String ?? "user") != "user" { continue }
            if let c = m["content"] as? String, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return c
            }
            if let arr = m["content"] as? [[String: Any]] {
                let t = arr.compactMap { p -> String? in
                    if let ty = p["type"] as? String, ty != "text" && ty != "input_text" { return nil }
                    return p["text"] as? String
                }.joined(separator: "\n")
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
            }
        }
        return ""
    }

    private func chunkJSON(_ id: String, _ model: String, _ delta: [String: String], _ finish: String?) -> String {
        var d: [String: Any] = [:]
        for (k, v) in delta { d[k] = v }
        var choice: [String: Any] = ["index": 0, "delta": d]
        if let finish { choice["finish_reason"] = finish }
        let obj: [String: Any] = [
            "id": id, "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970), "model": model,
            "choices": [choice],
        ]
        let d2 = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: d2, as: UTF8.self)
    }

    private func handleChat(_ conn: NWConnection, body: Data, auth: String?) async {
        guard checkAuth(auth) else {
            sendErr(conn, status: "401 Unauthorized", msg: "无效 API Key")
            conn.cancel()
            return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendErr(conn, status: "400 Bad Request", msg: "请求体不是 JSON")
            conn.cancel()
            return
        }
        guard let account = DSAccountStore.shared.pickAvailable() else {
            sendErr(conn, status: "503 Service Unavailable",
                    msg: "没有已登录可用的 DeepSeek 账号，请先到鲸聊「账号」页添加并登录")
            conn.cancel()
            return
        }
        DSAccountStore.shared.touch(account)

        let messages = json["messages"] as? [[String: Any]] ?? []
        var parts: [String] = []
        for m in messages {
            let role = m["role"] as? String ?? "user"
            var content = ""
            if let c = m["content"] as? String { content = c }
            else if let arr = m["content"] as? [[String: Any]] {
                // 兼容三种 part：{"type":"text"/"input_text","text":...} 与无 type 的 {"text":...}
                content = arr.compactMap { p -> String? in
                    if let t = p["type"] as? String, t != "text" && t != "input_text" { return nil }
                    return p["text"] as? String
                }.joined(separator: "\n")
            }
            if content.isEmpty, let c = m["content"] as? [[String: Any]] {
                // 兜底：整体当 JSON 序列化用（防新格式整段丢失）
                content = (try? JSONSerialization.data(withJSONObject: c))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            let tag = role == "assistant" ? "助手" : (role == "system" ? "系统" : "用户")
            parts.append("[\(tag)] \(content)")
        }
        var prompt = parts.joined(separator: "\n\n")
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let last = messages.last {
            // 兜底：消息全空时用最后一条原文
            prompt = "\(last)"
        }
        let stream = (json["stream"] as? Bool) ?? false
        let thinking = (json["thinking_enabled"] as? Bool) ?? false
        let search = (json["search_enabled"] as? Bool) ?? false

        let engine = DSChatEngine.shared
        // ── 请求诊断日志（设置页可见）──
        let roles = messages.map { $0["role"] as? String ?? "?" }.joined(separator: ",")
        let modelName = json["model"] as? String ?? "deepseek-chat"
        EngineLog.shared.add("[网关] 请求 model=\(modelName) stream=\(stream) msgs=\(messages.count) roles=\(roles) promptLen=\(prompt.count)")
        EngineLog.shared.add("[网关] promptHead=\(String(prompt.prefix(200)).replacingOccurrences(of: "\n", with: "⏎"))")

        do {
            let sessionID = try await engine.createSession(account: account)
            let req = DSChatEngine.CompleteRequest(
                account: account, sessionID: sessionID, parentMessageID: nil,
                prompt: prompt, thinking: thinking, search: search, onMeta: nil)
            let model = (json["model"] as? String) ?? "deepseek-chat"
            let cid = "chatcmpl-" + String(UUID().uuidString.prefix(8))
            if stream {
                sendHead(conn, contentType: "text/event-stream")
                // 首字节立刻发 role 增量，避免客户端的首包超时判定为空
                sendRaw(conn, "data: " + chunkJSON(cid, model, ["role": "assistant"], nil) + "\n\n")
                var gotContent = false
                var gotAny = false
                var gotErr = false
                do {
                    for try await ev in engine.complete(req) {
                        gotAny = true
                        switch ev {
                        case .thinkDelta(let t):
                            sendRaw(conn, "data: " + chunkJSON(cid, model, ["reasoning_content": t], nil) + "\n\n")
                        case .contentDelta(let t):
                            gotContent = true
                            sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": t], nil) + "\n\n")
                        case .usage:
                            break
                        case .meta:
                            break
                        case .done(let fr):
                            if let fr, fr.hasPrefix("error:") {
                                gotErr = true
                                sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[上游错误] " + String(fr.dropFirst(6))], nil) + "\n\n")
                            }
                        }
                    }
                } catch {
                    gotErr = true
                    sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[网关错误] " + error.localizedDescription], nil) + "\n\n")
                }
                if !gotContent && !gotErr {
                    // 上游零正文：先试裸用户消息重试（疑似人设 prompt 触发内容过滤），再显式报错
                    let plain = Self.lastUserText(messages)
                    if !plain.isEmpty && plain != prompt {
                        EngineLog.shared.add("[网关] 零正文 → 裸用户消息重试（规避人设触发过滤）")
                        if let sid2 = try? await engine.createSession(account: account) {
                            let req2 = DSChatEngine.CompleteRequest(
                                account: account, sessionID: sid2, parentMessageID: nil,
                                prompt: plain, thinking: thinking, search: search, onMeta: nil)
                            do {
                                for try await ev in engine.complete(req2) {
                                    switch ev {
                                    case .contentDelta(let t):
                                        gotContent = true
                                        sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": t], nil) + "\n\n")
                                    case .thinkDelta(let t):
                                        sendRaw(conn, "data: " + chunkJSON(cid, model, ["reasoning_content": t], nil) + "\n\n")
                                    case .usage, .meta: break
                                    case .done(let fr):
                                        if let fr, fr.hasPrefix("error:") {
                                            gotErr = true
                                            sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[上游错误] " + String(fr.dropFirst(6))], nil) + "\n\n")
                                        }
                                    }
                                }
                            } catch {
                                gotErr = true
                                sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[网关错误-重试] " + error.localizedDescription], nil) + "\n\n")
                            }
                            await engine.deleteSession(account: account, sessionID: sid2)
                        }
                    }
                    if !gotContent && !gotErr {
                        // 给客户端一段可见文本，而不是裸空（否则 Minis 判 empty response）
                        sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[网关错误] 上游未返回任何内容，请查看鲸聊设置页日志"], nil) + "\n\n")
                    }
                }
                EngineLog.shared.add("[网关] 完成 stream=1 content=\(gotContent ? "有" : "无") events=\(gotAny ? "有" : "无")")
                // 统一收尾：先冲刷 stop + [DONE]，再真正关闭（防 cancel 丢数据）
                let tail: [Data] = [
                    Data(("data: " + chunkJSON(cid, model, [:], "stop") + "\n\n").utf8),
                    Data("data: [DONE]\n\n".utf8),
                ]
                sendAllThenClose(conn, tail)
            } else {
                var content = ""
                var think = ""
                var errMsg = ""
                do {
                    for try await ev in engine.complete(req) {
                        switch ev {
                        case .thinkDelta(let t): think += t
                        case .contentDelta(let t): content += t
                        case .usage: break
                        case .meta: break
                        case .done(let fr):
                            if let fr, fr.hasPrefix("error:") { errMsg = String(fr.dropFirst(6)) }
                        }
                    }
                } catch {
                    sendErr(conn, status: "502 Bad Gateway", msg: error.localizedDescription)
                    await engine.deleteSession(account: account, sessionID: sessionID)
                    conn.cancel()
                    return
                }
                let text0 = errMsg.isEmpty ? content : content + "\n[上游错误] " + errMsg
                var text = text0
                var think2 = think
                // 非流式零正文兜底：用裸用户消息重试一次（疑似人设 prompt 触发过滤）
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let plain = Self.lastUserText(messages)
                    if !plain.isEmpty && plain != prompt {
                        EngineLog.shared.add("[网关] 零正文（非流式）→ 裸用户消息重试")
                        if let sid2 = try? await engine.createSession(account: account) {
                            let req2 = DSChatEngine.CompleteRequest(
                                account: account, sessionID: sid2, parentMessageID: nil,
                                prompt: plain, thinking: thinking, search: search, onMeta: nil)
                            do {
                                for try await ev in engine.complete(req2) {
                                    switch ev {
                                    case .thinkDelta(let t): think2 += t
                                    case .contentDelta(let t): text += t
                                    case .usage, .meta: break
                                    case .done(let fr):
                                        if let fr, fr.hasPrefix("error:") { text += "\n[上游错误] " + String(fr.dropFirst(6)) }
                                    }
                                }
                            } catch {
                                text += "\n[网关错误-重试] " + error.localizedDescription
                            }
                            await engine.deleteSession(account: account, sessionID: sid2)
                        }
                    }
                }
                let obj: [String: Any] = [
                    "id": cid, "object": "chat.completion",
                    "created": Int(Date().timeIntervalSince1970), "model": model,
                    "choices": [[
                        "index": 0,
                        "message": ["role": "assistant", "content": text, "reasoning_content": think2],
                        "finish_reason": "stop",
                    ]],
                    "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
                ]
                sendJSON(conn, obj)
                EngineLog.shared.add("[网关] 完成 stream=0 contentLen=\(text.count)")
                await engine.deleteSession(account: account, sessionID: sessionID)
                conn.cancel()
            }
        } catch {
            sendErr(conn, status: "502 Bad Gateway", msg: error.localizedDescription)
            conn.cancel()
        }
    }
}

final class ConnCtx {
    var buf: [UInt8] = []
    var headDone = false
    var bodyStart = 0
    var contentLength = 0
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
}
