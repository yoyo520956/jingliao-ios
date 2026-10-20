import Foundation
import Network

/// 本地 OpenAI 兼容 API 网关：127.0.0.1 监听，/v1/models + /v1/chat/completions
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

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "jl.localserver")
    private let engine = DSChatEngine.shared

    func start() {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpoint = NWEndpoint.Host("127.0.0.1")
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
        EngineLog.shared.add("本地网关已启动 http://127.0.0.1:\(port)/v1")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.running = false }
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

    private func sendJSON(_ conn: NWConnection, status: String = "200 OK", _ obj: [String: Any]) {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        sendRaw(conn, "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n")
        send(conn, d)
    }

    private func sendErr(_ conn: NWConnection, status: String, msg: String) {
        sendJSON(conn, status: status, ["error": ["message": msg, "type": "invalid_request_error"]])
    }
    // ── 路由 ─────────────────────────────────────────────────────────

    private func dispatch(_ conn: NWConnection, ctx: ConnCtx, body: Data) {
        let path = ctx.path.split(separator: "?").first.map(String.init) ?? ctx.path
        let auth = ctx.headers["authorization"]
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
                content = arr.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
                    .joined(separator: "\n")
            }
            let tag = role == "assistant" ? "助手" : (role == "system" ? "系统" : "用户")
            parts.append("[\(tag)] \(content)")
        }
        let prompt = parts.joined(separator: "\n\n")
        let stream = (json["stream"] as? Bool) ?? false
        let thinking = (json["thinking_enabled"] as? Bool) ?? false
        let search = (json["search_enabled"] as? Bool) ?? false

        let engine = DSChatEngine.shared
        do {
            let sessionID = try await engine.createSession(account: account)
            let req = DSChatEngine.CompleteRequest(
                account: account, sessionID: sessionID, parentMessageID: nil,
                prompt: prompt, thinking: thinking, search: search, onMeta: nil)
            let model = (json["model"] as? String) ?? "deepseek-chat"
            let cid = "chatcmpl-" + String(UUID().uuidString.prefix(8))
            if stream {
                sendHead(conn, contentType: "text/event-stream")
                do {
                    for try await ev in engine.complete(req) {
                        switch ev {
                        case .thinkDelta(let t):
                            sendRaw(conn, "data: " + chunkJSON(cid, model, ["reasoning_content": t], nil) + "\n\n")
                        case .contentDelta(let t):
                            sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": t], nil) + "\n\n")
                        case .usage:
                            break
                        case .meta:
                            break
                        case .done(let fr):
                            if let fr, fr.hasPrefix("error:") {
                                sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[上游错误] " + String(fr.dropFirst(6))], nil) + "\n\n")
                            }
                            sendRaw(conn, "data: " + chunkJSON(cid, model, [:], "stop") + "\n\n")
                            sendRaw(conn, "data: [DONE]\n\n")
                        }
                    }
                } catch {
                    sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[网关错误] " + error.localizedDescription], nil) + "\n\n")
                    sendRaw(conn, "data: [DONE]\n\n")
                }
                await engine.deleteSession(account: account, sessionID: sessionID)
                conn.cancel()
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
                let text = errMsg.isEmpty ? content : content + "\n[上游错误] " + errMsg
                let obj: [String: Any] = [
                    "id": cid, "object": "chat.completion",
                    "created": Int(Date().timeIntervalSince1970), "model": model,
                    "choices": [[
                        "index": 0,
                        "message": ["role": "assistant", "content": text, "reasoning_content": think],
                        "finish_reason": "stop",
                    ]],
                    "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
                ]
                sendJSON(conn, obj)
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
