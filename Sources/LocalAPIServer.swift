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

    // ── 会话链：同一对话复用上游 DeepSeek session，后续轮只发新消息 ──
    // 根治两件事：①后续轮 prompt 不再滚雪球（不会被上游截断）②历史由上游会话自己保管 = 真记忆
    // 落盘持久化：App 重启/重装后链还在，不会因为重启又变回“完整 prompt 被截断”
    private struct ConvChain: Codable {
        var sessionID: String
        var lastMsgID: Int64
        var msgCount: Int
        var lastUser: String
        var usedAt: Date
    }
    private var chains: [String: ConvChain] = [:]
    private let chainLock = NSLock()
    private var chainsLoaded = false
    /// 幂等重放缓存（Idempotency-Key → 上次响应体，10 分钟有效，最多 100 条）
    private var idemCache: [String: (resp: Data, at: Date)] = [:]
    private let idemLock = NSLock()
    private final class MsgBox { var msgID: Int64 = 0; var usage: Int64 = 0 }

    private func idempotencyGet(_ key: String) -> Data? {
        idemLock.lock(); defer { idemLock.unlock() }
        idemCache = idemCache.filter { Date().timeIntervalSince($0.value.at) < 600 }
        return idemCache[key]?.resp
    }

    private func idempotencyReplay(_ key: String) -> Data? { idempotencyGet(key) }

    private func idempotencyStore(_ key: String, _ body: Data) {
        idemLock.lock(); defer { idemLock.unlock() }
        if idemCache.count > 100 { idemCache.removeAll() }
        idemCache[key] = (body, Date())
    }

    private func loadChains() {
        guard !chainsLoaded else { return }
        chainsLoaded = true
        guard let d = UserDefaults.standard.data(forKey: "jl.chains"),
              let arr = try? JSONDecoder().decode([String: ConvChain].self, from: d) else { return }
        chains = arr
        EngineLog.shared.add("已恢复 \(chains.count) 条会话链（重启不失忆）")
    }

    private func persistChains() {
        guard let d = try? JSONEncoder().encode(chains) else { return }
        UserDefaults.standard.set(d, forKey: "jl.chains")
    }

    /// 从消息里抽正文（兼容 string / parts / input_text / 无 type / 纯 JSON 兜底）
    static func msgText(_ m: [String: Any]) -> String {
        if let c = m["content"] as? String { return c }
        if let arr = m["content"] as? [[String: Any]] {
            let t = arr.compactMap { p -> String? in
                if let ty = p["type"] as? String, ty != "text" && ty != "input_text" { return nil }
                return p["text"] as? String
            }.joined(separator: "\n")
            if !t.isEmpty { return t }
            return (try? JSONSerialization.data(withJSONObject: arr))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return ""
    }

    /// 对话身份键：系统人设头部 + 第一条用户消息**全文**（同一对话跨轮稳定；新对话开场不同则分开）
    static func conversationKey(_ messages: [[String: Any]]) -> String {
        let sys = messages.first(where: { ($0["role"] as? String) == "system" }).map { msgText($0) } ?? ""
        let firstUser = messages.first(where: { ($0["role"] as? String) == "user" }).map { msgText($0) } ?? ""
        return String(sys.prefix(120)) + "\u{1}" + firstUser
    }

    /// 请求里是否带助手/工具历史：Minis 等客户端每轮发全量历史（msgs 4→6→8 递增），
    /// 真·新对话的首轮必然一条都没有。这是区分"同人设同开场白的新对话"与"续轮"的唯一可靠判据
    static func hasAssistantHistory(_ messages: [[String: Any]]) -> Bool {
        messages.contains { let r = $0["role"] as? String ?? ""; return r == "assistant" || r == "tool" }
    }

    /// 从消息 content parts 里抽 image_url（OpenAI 格式：字符串或 {url:...}）
    static func extractImageRefs(_ messages: [[String: Any]]) -> [String] {
        var out: [String] = []
        for m in messages {
            guard let arr = m["content"] as? [[String: Any]] else { continue }
            for p in arr where (p["type"] as? String) == "image_url" {
                if let s = p["image_url"] as? String { out.append(s) }
                else if let d = p["image_url"] as? [String: Any], let u = d["url"] as? String { out.append(u) }
            }
        }
        return out
    }

    /// 按 [系统]/[用户]/[助手]/[工具] 标签拼完整 prompt
    static func assemblePrompt(_ messages: [[String: Any]], keep: Int? = nil) -> String {
        let list: [[String: Any]]
        if let keep, messages.count > keep {
            var k: [[String: Any]] = []
            if (messages.first?["role"] as? String) == "system" { k.append(messages[0]) }
            if messages.count > 1 { k.append(messages[1]) }
            k.append(contentsOf: messages.suffix(4))
            list = k
        } else {
            list = messages
        }
        return list.map { m -> String in
            let role = m["role"] as? String ?? "user"
            let tag = role == "assistant" ? "助手" : (role == "system" ? "系统" : (role == "tool" ? "工具" : "用户"))
            return "[\(tag)] \(msgText(m))"
        }.joined(separator: "\n\n")
    }

    /// 超长 prompt 智能裁剪（首轮兜底）：系统人设头尾保留 + 首条用户消息 + 最近 4 条，目标 ≤2 万字符
    /// （人设数万字时上游服务端会把中后部整段截掉，历史全丢——这是“失忆”的根因）
    static func compactPrompt(_ messages: [[String: Any]]) -> String {
        func tagLine(_ m: [String: Any]) -> String {
            let role = m["role"] as? String ?? "user"
            var tag = "用户"
            if role == "assistant" { tag = "助手" }
            else if role == "system" { tag = "系统" }
            else if role == "tool" { tag = "工具" }
            return "[\(tag)] \(msgText(m))"
        }
        let sysIdx = messages.firstIndex { ($0["role"] as? String) == "system" }
        let sysText = sysIdx.map { msgText(messages[$0]) } ?? ""
        var out: [String] = []
        if !sysText.isEmpty {
            let capped = sysText.count > 8000
                ? String(sysText.prefix(4000)) + "\n……[系统人设过长，中部省略 \(sysText.count - 8000) 字]……\n" + String(sysText.suffix(4000))
                : sysText
            out.append("[系统] \(capped)")
        }
        let firstUserIdx = messages.firstIndex { ($0["role"] as? String) == "user" }
        if let i = firstUserIdx {
            out.append("[用户] \(String(msgText(messages[i]).prefix(1000)))")
        }
        var seen = Set<Int>()
        if let i = sysIdx { seen.insert(i) }
        if let i = firstUserIdx { seen.insert(i) }
        let tail = messages.suffix(4)
        for (off, m) in tail.enumerated() {
            let real = messages.count - tail.count + off
            if seen.contains(real) { continue }
            out.append(tagLine(m))
        }
        return out.joined(separator: "\n\n")
    }

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
        loadChains()
        loadClients()
        SilentAudio.shared.start()   // 切后台保活：服务不能随 App 挂起而死
        let lan = Self.lanIPv4.map { " / http://\($0):\(port)/v1（局域网）" } ?? ""
        EngineLog.shared.add("本地网关已启动 http://127.0.0.1:\(port)/v1\(lan)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.running = false }
        SilentAudio.shared.stop()
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

    // ── 网关客户端监控：谁在连、连了多少次 ──────────────────────────────

    struct GatewayClient: Codable, Identifiable, Equatable {
        var id: String { ip }
        var ip: String
        var ua: String
        var requests: Int
        var lastAt: Double
    }

    @Published var clients: [GatewayClient] = []
    private var clientMap: [String: GatewayClient] = [:]
    private let clientsFileKey = "jl.clients"

    private func loadClients() {
        if let d = UserDefaults.standard.data(forKey: clientsFileKey),
           let arr = try? JSONDecoder().decode([GatewayClient].self, from: d) {
            clientMap = Dictionary(uniqueKeysWithValues: arr.map { ($0.ip, $0) })
            clients = arr.sorted { $0.lastAt > $1.lastAt }
        }
    }

    private func persistClients() {
        if let d = try? JSONEncoder().encode(Array(clientMap.values)) {
            UserDefaults.standard.set(d, forKey: clientsFileKey)
        }
    }

    private func noteClient(_ conn: NWConnection, ctx: ConnCtx) {
        let ip: String
        switch conn.endpoint {
        case let .hostPort(host, _):
            switch host {
            case let .ipv4(a): ip = "\(a)"
            case let .ipv6(a): ip = "\(a)"
            case let .name(n, _): ip = n
            @unknown default: ip = "未知"
            }
        default:
            ip = "未知"
        }
        ctx.clientIP = ip
        let ua = ctx.headers["user-agent"] ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var c = self.clientMap[ip] ?? GatewayClient(ip: ip, ua: "", requests: 0, lastAt: 0)
            c.requests += 1
            c.lastAt = Date().timeIntervalSince1970
            if !ua.isEmpty { c.ua = ua }
            self.clientMap[ip] = c
            self.clients = self.clientMap.values.sorted { $0.lastAt > $1.lastAt }
            self.persistClients()
        }
    }

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
        noteClient(conn, ctx: ctx)

        // ── 幂等重放：带 Idempotency-Key 的请求，同 key 直接回放上次响应 ──
        if let idemKey = ctx.headers["idempotency-key"], !idemKey.isEmpty {
            if let replay = idempotencyReplay(idemKey) {
                EngineLog.shared.add("[网关] 幂等命中 key=\(idemKey.prefix(8)) → 回放 \(replay.count)B")
                sendRaw(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(replay.count)\r\nConnection: close\r\nidempotent-replayed: true\r\n\r\n")
                sendAllThenClose(conn, [replay])
                return
            }
        }

        Task { [weak self] in
            guard let self else { return }
            if path == "/v1/stats" {
                // 小组件/客户端状态端点：本机可读，不走鉴权
                let t = UsageStore.shared.todayTotal
                let accs = DSAccountStore.shared.accounts
                let now = Date().timeIntervalSince1970
                let usable = accs.filter { !$0.token.isEmpty && (!$0.muted || $0.muteUntil <= now) }.count
                self.sendJSON(conn, [
                    "running": true,
                    "port": self.port,
                    "accounts": accs.count,
                    "accountsUsable": usable,
                    "todayRequests": t.count,
                    "todayPrompt": t.prompt,
                    "todayCompletion": t.completion,
                    "todayTokens": t.prompt + t.completion,
                    "clients": self.clients.count,
                ])
                return
            }
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
            // 三协议入口：OpenAI / Anthropic Messages / OpenAI Responses
            let proto: LocalAPIServer.ProtoKind
            if path == "/v1/chat/completions" { proto = .openai }
            else if path == "/anthropic/v1/messages" || path == "/v1/messages" { proto = .anthropic }
            else if path == "/v1/responses" { proto = .responses }
            else {
                self.sendErr(conn, status: "404 Not Found", msg: "unknown path \(path)")
                conn.cancel()
                return
            }
            await self.handleChat(conn, body: body, auth: auth, proto: proto, idemKey: ctx.headers["idempotency-key"], clientIP: ctx.clientIP)
        }
    }

    /// 当前连接的幂等 key（仅用于缓存回写；并发下最差不缓存，不影响正确性）
    private var currentIdemKey: String?

    /// 请求协议类型（用于 body 转换）
    private enum ProtoKind { case openai, anthropic, responses }

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
            let t = msgText(m)
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        }
        return ""
    }

    private func chunkJSON(_ id: String, _ model: String, _ delta: [String: String], _ finish: String?) -> String {
        chunkJSONRaw(id, model, delta.isEmpty ? [:] : delta, finish)
    }

    /// 通用版：delta 值可以是嵌套结构（tool_calls 数组）
    private func chunkJSONRaw(_ id: String, _ model: String, _ delta: [String: Any], _ finish: String?) -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        let obj: [String: Any] = [
            "id": id, "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970), "model": model,
            "choices": [choice],
        ]
        let d2 = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: d2, as: UTF8.self)
    }

    /// 流式泵：跑一轮 completion，把事件转成 SSE chunk 吐出；返回 (有正文, 出错)
    private func pumpStream(
        _ conn: NWConnection, _ account: DSAccount, _ sid: String,
        _ req: DSChatEngine.CompleteRequest, _ cid: String, _ model: String,
        _ box: MsgBox? = nil
    ) async -> (content: Bool, err: Bool) {
        var gotContent = false, gotErr = false
        var visibleText = ""
        var toolStartSeen = false
        do {
            for try await ev in engine.complete(req) {
                switch ev {
                case .contentDelta(let t):
                    visibleText += t
                    if YaotaiTools.hasStart(visibleText) { toolStartSeen = true }
                    if !toolStartSeen {
                        gotContent = true
                        sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": t], nil) + "\n\n")
                    }
                case .thinkDelta(let t):
                    sendRaw(conn, "data: " + chunkJSON(cid, model, ["reasoning_content": t], nil) + "\n\n")
                case .usage(let u):
                    box?.usage = u     // SSE 上报的服务端真实累计 token
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
        // 流式工具调用：END 到齐后解析，以标准 OpenAI tool_calls chunk 下发
        if toolStartSeen, let parsed = YaotaiTools.parse(visibleText) {
            if !parsed.remainder.isEmpty {
                sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n" + parsed.remainder], nil) + "\n\n")
            }
            for tc in parsed.calls {
                let delta: [String: Any] = ["tool_calls": [[
                    "index": 0, "id": tc.id, "type": "function",
                    "function": ["name": tc.name, "arguments": ProtoAdapter.coerceArguments(tc.arguments)],
                ]]]
                sendRaw(conn, "data: " + chunkJSONRaw(cid, model, delta, nil) + "\n\n")
            }
            EngineLog.shared.add("[网关] 工具调用：\(parsed.calls.map { $0.name }.joined(separator: ", "))")
        }
        _ = sid
        return (gotContent, gotErr)
    }

    /// 非流式泵：跑一轮 completion，累计正文；返回 (正文, 思考, 错误)
    private func pumpCollect(_ account: DSAccount, _ req: DSChatEngine.CompleteRequest, _ box: MsgBox? = nil) async -> (content: String, think: String, err: String) {
        var content = "", think = "", err = ""
        do {
            for try await ev in engine.complete(req) {
                switch ev {
                case .thinkDelta(let t): think += t
                case .contentDelta(let t): content += t
                case .usage(let u): box?.usage = u
                case .meta: break
                case .done(let fr):
                    if let fr, fr.hasPrefix("error:") { err = String(fr.dropFirst(6)) }
                }
            }
        } catch {
            err = error.localizedDescription
        }
        return (content, think, err)
    }

    /// OpenAI 流式响应尾部的 usage chunk（choices 为空数组，客户端读真实用量）
    private func usageJSON(_ id: String, _ model: String, promptTokens: Int, completionTokens: Int) -> String {
        let obj: [String: Any] = [
            "id": id, "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970), "model": model,
            "choices": [],
            "usage": ["prompt_tokens": promptTokens, "completion_tokens": completionTokens,
                      "total_tokens": promptTokens + completionTokens],
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// 官方 DeepSeek API 直通：原样转发客户端请求体（tools/thinking/stream 全支持），
    /// SSE 原样回流——第三方 App 拿到的是和官方一致的完整能力
    private func handleOfficial(_ conn: NWConnection, body: Data, json: [String: Any], key: String) async {
        var out = json
        // 网关私有字段清掉，官方不认识
        out.removeValue(forKey: "thinking_enabled")
        out.removeValue(forKey: "search_enabled")
        if let m = out["model"] as? String, !m.contains("deepseek") { out["model"] = "deepseek-chat" }
        let stream = (json["stream"] as? Bool) ?? false
        let model = out["model"] as? String ?? "deepseek-chat"

        EngineLog.shared.add("[网关] 官方直通 stream=\(stream) model=\(model)")

        var req = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: out)) ?? body
        req.timeoutInterval = 300

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                var t = ""
                for try await line in bytes.lines { t += line; if t.count > 300 { break } }
                sendErr(conn, status: "502 Bad Gateway", msg: "官方 API HTTP \(code): \(t)")
                conn.cancel()
                return
            }
            if stream {
                sendHead(conn, contentType: "text/event-stream")
                // 原样转发 SSE 行（加回空行分隔），[DONE] 一起过去
                sendRaw(conn, "data: " + Self.chunkRoleLine() + "\n\n")
                var forwarded = 0
                for try await line in bytes.lines {
                    if line.isEmpty { continue }
                    sendRaw(conn, line + "\n\n")
                    forwarded += 1
                }
                EngineLog.shared.add("[网关] 官方直通转发 \(forwarded) 行")
                sendAllThenClose(conn, [Data("data: [DONE]\n\n".utf8)])
            } else {
                var d = Data()
                for try await byte in bytes { d.append(byte) }
                EngineLog.shared.add("[网关] 官方直通响应 \(d.count)B")
                sendRaw(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n")
                sendAllThenClose(conn, [d])
            }
        } catch {
            sendErr(conn, status: "502 Bad Gateway", msg: "官方 API 失败: \(error.localizedDescription)")
            conn.cancel()
        }
    }

    private static func chunkRoleLine() -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [
            "id": "chatcmpl-direct", "object": "chat.completion.chunk", "created": Int(Date().timeIntervalSince1970),
            "model": "deepseek-chat", "choices": [["index": 0, "delta": ["role": "assistant"], "finish_reason": NSNull()]],
        ])) ?? Data("{}".utf8), as: UTF8.self)
    }

    private func handleChat(_ conn: NWConnection, body: Data, auth: String?) async {
        await handleChat(conn, body: body, auth: auth, proto: .openai)
    }

    private func handleChat(_ conn: NWConnection, body: Data, auth: String?, proto: ProtoKind, clientIP: String = "本机") async {
        await handleChat(conn, body: body, auth: auth, proto: proto, idemKey: nil, clientIP: clientIP)
    }

    private func handleChat(_ conn: NWConnection, body: Data, auth: String?, proto: ProtoKind, idemKey: String?, clientIP: String = "本机") async {
        currentIdemKey = idemKey
        guard checkAuth(auth) else {
            sendErr(conn, status: "401 Unauthorized", msg: "无效 API Key")
            conn.cancel()
            return
        }
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendErr(conn, status: "400 Bad Request", msg: "请求体不是 JSON")
            conn.cancel()
            return
        }
        // Anthropic Messages 协议 → OpenAI 格式（下游统一走 chat/completions）
        if proto == .anthropic {
            json = ProtoAdapter.anthropicToOpenAI(json)
        }
        // OpenAI Responses 协议 → Chat Completions
        if proto == .responses {
            json = ProtoAdapter.responsesToOpenAI(json)
        }
        // 官方 API 直通模式：填了官方 Key 就走官方通道——工具调用/深度思考/真实 token 用量全支持
        if let officialKey = UserDefaults.standard.string(forKey: "jl.officialkey"), !officialKey.isEmpty {
            await handleOfficial(conn, body: body, json: json, key: officialKey)
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
        let stream = (json["stream"] as? Bool) ?? false
        let thinking = (json["thinking_enabled"] as? Bool) ?? false
        let search = (json["search_enabled"] as? Bool) ?? false
        let model = (json["model"] as? String) ?? "deepseek-chat"
        let cid = "chatcmpl-" + String(UUID().uuidString.prefix(8))
        let lastUser = Self.lastUserText(messages)

        // 完整 prompt：正常全量；超 2 万字符走智能裁剪（人设数万字会被上游服务端截断，历史全丢）
        // 第三方请求没带 system 且用户配了「网关默认系统提示词」时，用它顶上
        var effective = messages
        let gwDefault = PromptStore.shared.gatewayDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gwDefault.isEmpty, !messages.contains(where: { ($0["role"] as? String) == "system" }) {
            effective = [["role": "system", "content": gwDefault]] + messages
        }
        // 【v2.0.7 内置必发】官方服务端会删聊天记录 → 会话不可依赖。
        // 这段提示词存软件里，每一条请求（不管客户端是谁、聊什么、发没发 system）都全量拼在最前面
        if PromptStore.shared.builtinOn {
            let bi = PromptStore.shared.builtin.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bi.isEmpty {
                effective = [["role": "system", "content": bi]] + effective
                EngineLog.shared.add("[网关] 内置必发提示词已注入（\(bi.count) 字）")
            }
        }
        let fullSource = effective
        var fullPrompt = Self.assemblePrompt(fullSource)
        if fullPrompt.count > 20_000 {
            EngineLog.shared.add("[网关] prompt \(fullPrompt.count) 字超 2 万 → 智能裁剪（人设头尾+首轮+最近 4 条）")
            fullPrompt = Self.compactPrompt(fullSource)
        }

        // ── 工具调用（网页版协议上的 function calling）──
        // 有 tools 就注入调用指令（含格式规则/示例/工具定义）；tool 结果消息也编进 prompt
        let toolDefs = YaotaiTools.extractToolDefs(json)
        if !toolDefs.isEmpty {
            let toolMsgs = messages.filter { ($0["role"] as? String) == "tool" }
            if !toolMsgs.isEmpty {
                fullPrompt += "\n\n" + toolMsgs.map { "[工具结果] \(Self.msgText($0))" }.joined(separator: "\n")
            }
            fullPrompt += "\n\n" + YaotaiTools.buildInjection(json, funcs: toolDefs)
            EngineLog.shared.add("[网关] 工具调用启用：\(toolDefs.count) 个工具（网页版协议降级模式，无需官方 Key）")
        }

        // ── 图片多模态：content parts 里的 image_url → 上传官方 → ref_file_ids ──
        var refFileIds: [String] = []
        let imgRefs = Self.extractImageRefs(messages)
        if !imgRefs.isEmpty {
            for (i, src) in imgRefs.prefix(3).enumerated() {
                do {
                    let data: Data
                    let mime: String
                    if src.hasPrefix("data:") {
                        guard let b64 = src.split(separator: ",").last,
                              let d = Data(base64Encoded: String(b64)) else { continue }
                        data = d
                        mime = src.contains("image/png") ? "image/png" : (src.contains("image/webp") ? "image/webp" : "image/jpeg")
                    } else if src.hasPrefix("http") {
                        guard let u = URL(string: src) else { continue }
                        var r2 = URLRequest(url: u); r2.timeoutInterval = 30
                        let (d, _) = try await URLSession.shared.data(for: r2)
                        data = d
                        mime = "image/jpeg"
                    } else { continue }
                    guard data.count <= 8_000_000 else { throw DSError(message: "图片超过 8MB") }
                    let fid = try await engine.uploadFile(account: account, filename: "img\(i + 1).jpg", mime: mime, data: data)
                    refFileIds.append(fid)
                } catch {
                    EngineLog.shared.add("[网关] 图片\(i + 1) 上传失败：\(error.localizedDescription)")
                }
            }
            EngineLog.shared.add("[网关] 图片多模态：\(refFileIds.count)/\(min(imgRefs.count, 3)) 张就绪")
        }

        // ── 会话链判定 ──
        let key = Self.conversationKey(messages)
        chainLock.lock()
        if chains.count > 200 {
            chains = Dictionary(uniqueKeysWithValues: chains.suffix(200).map { ($0.key, $0.value) })
        }
        chains = chains.filter { $0.value.usedAt > Date().addingTimeInterval(-12 * 3600) }
        var reuse = chains[key]
        // ── 防串话铁律：同 key 但本请求零助手历史 = 新开对话 ──
        // 场景：同一个人设 + 相同开场白 → key 撞车，若放行就会并进上一个（通常是第一个）对话
        if let e = reuse, !Self.hasAssistantHistory(messages), e.msgCount >= 2 {
            reuse = nil
            chains.removeValue(forKey: key)
            EngineLog.shared.add("[网关] 同 key 但无助手历史 → 判定新对话，不复用旧会话（防串话）")
        }
        if let e = reuse {
            let grow = messages.count > e.msgCount
            let sameTurn = messages.count == e.msgCount && e.lastUser == lastUser
            if !(grow || sameTurn) || e.lastMsgID == 0 || lastUser.isEmpty {
                reuse = nil
                chains.removeValue(forKey: key)
                EngineLog.shared.add("[网关] 消息数回退/无链 id → 按新对话处理")
            }
        }
        chainLock.unlock()
        persistChains()
        // 【v2.0.7 无状态全量模式】官方服务端会删聊天记录 → 链式复用随时断链（工具上下文全丢、历史消失）。
        // 改为每条请求都开全新会话 + 完整 prompt（上下文全量自带，与 Minis 行为一致），响应完成即删会话。
        reuse = nil
        let chained = false

        EngineLog.shared.add("[网关] 请求 model=\(model) stream=\(stream) msgs=\(messages.count) chain=\(chained ? "复用" : "新建") fullLen=\(fullPrompt.count)")
        if chained, let c = reuse {
            EngineLog.shared.add("[网关] 复用会话 sid=…\(c.sessionID.suffix(8)) 上轮msgID=\(c.lastMsgID) 上轮msgCount=\(c.msgCount)")
        }
        EngineLog.shared.add("[网关] promptHead=\(String((chained ? lastUser : fullPrompt).prefix(200)).replacingOccurrences(of: "\n", with: "⏎"))")

        do {
            let sessionID: String
            let parent: Int64?
            if let c = reuse {
                sessionID = c.sessionID
                parent = c.lastMsgID
            } else {
                sessionID = try await engine.createSession(account: account)
                parent = nil
            }
            let box = MsgBox()
            let req = DSChatEngine.CompleteRequest(
                account: account, sessionID: sessionID, parentMessageID: parent,
                // 链式轮只发新消息（历史在上游会话里）；首轮发完整 prompt
                prompt: chained ? (lastUser.isEmpty ? fullPrompt : lastUser) : fullPrompt,
                thinking: thinking, search: search,
                refFileIds: refFileIds,
                onMeta: { mid in
                    box.msgID = mid
                    EngineLog.shared.add("[网关] 上游响应 message id=\(mid)")
                })
            EngineLog.shared.add("[网关] 发送 sid=…\(sessionID.suffix(8)) parent=\(parent.map { "\($0)" } ?? "nil")")

            func saveChain(_ sid: String) {
                chainLock.lock()
                var mid = box.msgID
                if mid == 0, let c = reuse { mid = c.lastMsgID }
                if mid != 0 {
                    chains[key] = ConvChain(sessionID: sid, lastMsgID: mid,
                                            msgCount: messages.count, lastUser: lastUser, usedAt: Date())
                } else {
                    chains.removeValue(forKey: key)
                }
                chainLock.unlock()
                persistChains()   // 落盘：重启/重装不失忆
            }

            if stream {
                sendHead(conn, contentType: "text/event-stream")
                // 首字节立刻发 role 增量，避免客户端的首包超时判定为空
                sendRaw(conn, "data: " + chunkJSON(cid, model, ["role": "assistant"], nil) + "\n\n")
                var r = await pumpStream(conn, account, sessionID, req, cid, model, box)
                var activeSid = sessionID

                // 兜底 1：链式轮失败/零正文 → 新会话 + 完整 prompt（上游会话过期就靠这层救）
                if chained && (!r.content || r.err) {
                    EngineLog.shared.add("[网关] 链式轮失败/空 → 新会话完整 prompt 重试")
                    if let sid2 = try? await engine.createSession(account: account) {
                        if sessionID != sid2 { await engine.deleteSession(account: account, sessionID: sessionID) }
                        activeSid = sid2
                        let req2 = DSChatEngine.CompleteRequest(
                            account: account, sessionID: sid2, parentMessageID: nil,
                            prompt: fullPrompt, thinking: thinking, search: search,
                            onMeta: { box.msgID = $0 })
                        r = await pumpStream(conn, account, sid2, req2, cid, model, box)
                    }
                }

                // 兜底 2：仍零正文且无错 → 新会话 + 裸用户消息（防人设 prompt 触发上游过滤）
                if !r.content && !r.err {
                    if !lastUser.isEmpty && lastUser != fullPrompt {
                        EngineLog.shared.add("[网关] 零正文 → 裸用户消息重试（规避人设触发过滤）")
                        if let sid3 = try? await engine.createSession(account: account) {
                            let req3 = DSChatEngine.CompleteRequest(
                                account: account, sessionID: sid3, parentMessageID: nil,
                                prompt: lastUser, thinking: thinking, search: search, onMeta: nil)
                            let r3 = await pumpStream(conn, account, sid3, req3, cid, model)
                            if r3.content {
                                r = (true, false)
                                await engine.deleteSession(account: account, sessionID: sid3)
                            } else {
                                await engine.deleteSession(account: account, sessionID: sid3)
                            }
                        }
                    }
                }

                // 兜底 3：还是空的 → 给客户端一段可见错误文本（否则 Minis 判 empty response）
                if !r.content && !r.err {
                    sendRaw(conn, "data: " + chunkJSON(cid, model, ["content": "\n[网关错误] 上游未返回任何内容，请查看鲸聊设置页日志"], nil) + "\n\n")
                }
                EngineLog.shared.add("[网关] 完成 stream=1 content=\(r.content ? "有" : "无") err=\(r.err ? "有" : "无") tokens=\(box.usage)")
                if r.content { saveChain(activeSid) }
                // 统一收尾：stop → usage（真实 completion tokens + 估算 prompt tokens）→ [DONE]，冲刷后关闭
                let promptEst = max(1, (chained ? lastUser.count : fullPrompt.count) / 2)
                UsageStore.shared.log(prompt: promptEst, completion: Int(box.usage),
                                      client: clientIP.isEmpty ? "本机" : clientIP, model: model)
                let tail: [Data] = [
                    Data(("data: " + chunkJSON(cid, model, [:], "stop") + "\n\n").utf8),
                    Data(("data: " + usageJSON(cid, model, promptTokens: promptEst, completionTokens: Int(box.usage)) + "\n\n").utf8),
                    Data("data: [DONE]\n\n".utf8),
                ]
                sendAllThenClose(conn, tail)
                // 无状态模式：响应交付完即删上游会话（官方本来也会删，主动删干净不占列表）
                await engine.deleteSession(account: account, sessionID: activeSid)
            } else {
                var res = await pumpCollect(account, req, box)
                var activeSid = sessionID
                // 兜底 1：链式失败/空 → 新会话完整 prompt
                if chained && (res.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !res.err.isEmpty) {
                    EngineLog.shared.add("[网关] 链式轮失败/空（非流式）→ 新会话完整 prompt 重试")
                    if let sid2 = try? await engine.createSession(account: account) {
                        if sessionID != sid2 { await engine.deleteSession(account: account, sessionID: sessionID) }
                        activeSid = sid2
                        let req2 = DSChatEngine.CompleteRequest(
                            account: account, sessionID: sid2, parentMessageID: nil,
                            prompt: fullPrompt, thinking: thinking, search: search,
                            onMeta: { box.msgID = $0 })
                        res = await pumpCollect(account, req2, box)
                    }
                }
                // 兜底 2：仍空且无错 → 裸用户消息
                if res.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, res.err.isEmpty {
                    if !lastUser.isEmpty && lastUser != fullPrompt {
                        EngineLog.shared.add("[网关] 零正文（非流式）→ 裸用户消息重试")
                        if let sid3 = try? await engine.createSession(account: account) {
                            let req3 = DSChatEngine.CompleteRequest(
                                account: account, sessionID: sid3, parentMessageID: nil,
                                prompt: lastUser, thinking: thinking, search: search, onMeta: nil)
                            let r3 = await pumpCollect(account, req3)
                            if !r3.content.isEmpty { res = r3 }
                            await engine.deleteSession(account: account, sessionID: sid3)
                        }
                    }
                }
                var text = res.content
                if !res.err.isEmpty { text += "\n[上游错误] " + res.err }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = "\n[网关错误] 上游未返回任何内容，请查看鲸聊设置页日志"
                }
                // 工具调用解析：模型吐了标记就升级成标准 tool_calls 响应
                var toolCallsJSON: [[String: Any]] = []
                if !toolDefs.isEmpty, let parsed = YaotaiTools.parse(text) {
                    toolCallsJSON = parsed.calls.map { tc in
                        ["id": tc.id, "type": "function",
                         "function": ["name": tc.name, "arguments": ProtoAdapter.coerceArguments(tc.arguments)]]
                    }
                    text = parsed.remainder
                    EngineLog.shared.add("[网关] 工具调用（非流式）：\(parsed.calls.map { $0.name }.joined(separator: ", "))")
                }
                let finishReason = toolCallsJSON.isEmpty ? "stop" : "tool_calls"
                var message: [String: Any] = ["role": "assistant", "content": text, "reasoning_content": res.think]
                if !toolCallsJSON.isEmpty { message["tool_calls"] = toolCallsJSON }
                let obj: [String: Any] = [
                    "id": cid, "object": "chat.completion",
                    "created": Int(Date().timeIntervalSince1970), "model": model,
                    "choices": [[
                        "index": 0,
                        "message": message,
                        "finish_reason": finishReason,
                    ]],
                    "usage": [
                        "prompt_tokens": max(1, fullPrompt.count / 2),
                        "completion_tokens": Int(box.usage),
                        "total_tokens": max(1, fullPrompt.count / 2) + Int(box.usage),
                    ],
                ]
                // Anthropic 协议：响应转成 Messages 格式后只发一份
                if proto == .anthropic {
                    sendJSON(conn, ProtoAdapter.openAIToAnthropic(obj, model: model))
                } else {
                    sendJSON(conn, obj)
                }
                // 幂等缓存：带 Idempotency-Key 的请求存响应，重试原样回放
                if let idem = currentIdemKey, let d = (try? JSONSerialization.data(withJSONObject: obj)) {
                    idempotencyStore(idem, d)
                }
                EngineLog.shared.add("[网关] 完成 stream=0 contentLen=\(text.count) tokens=\(box.usage)")
                UsageStore.shared.log(prompt: max(1, fullPrompt.count / 2), completion: Int(box.usage),
                                      client: clientIP.isEmpty ? "本机" : clientIP, model: model)
                if !res.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saveChain(activeSid)
                }
                // 无状态模式：响应交付完即删上游会话
                await engine.deleteSession(account: account, sessionID: activeSid)
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
    var clientIP = ""
}
