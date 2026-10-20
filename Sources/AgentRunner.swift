import Foundation

/// 瑶台 AI 助手：官方 DeepSeek API + 工具调用闭环
/// 工具：run_command / read_file / write_file / list_files / git_clone
final class AgentRunner: ObservableObject {
    static let shared = AgentRunner()

    struct Msg: Identifiable {
        let id = UUID().uuidString
        var role: String          // user / assistant / tool
        var text: String
        var toolCalls: [[String: Any]] = []
        var toolResults: [(name: String, result: String)] = []
        var running = false
    }

    @Published var messages: [Msg] = []
    @Published var busy = false
    @Published var status = ""

    private let fs = WorkbenchFS.shared
    private let shell = ShellEngine.shared
    private let maxRounds = 8

    /// 是否可用：官方 Key（直通）或免费账号（网页协议工具降级）任一在就行
    var ready: Bool {
        !(UserDefaults.standard.string(forKey: "jl.officialkey") ?? "").isEmpty
            || DSAccountStore.shared.pickAvailable() != nil
    }

    /// 当前通道描述（界面显示用）
    var modeText: String {
        (UserDefaults.standard.string(forKey: "jl.officialkey") ?? "").isEmpty
            ? "网页协议 · 工具降级模式"
            : "官方 API 直通"
    }

    func toolsSchema() -> [[String: Any]] { [
        ["type": "function", "function": [
            "name": "run_command",
            "description": "在瑶台内置 Linux shell 执行命令。支持 ls/cd/cat/mkdir/rm/cp/mv/echo/head/tail/grep/sed/find/tree/wc/sort/uniq/node/js/git/curl/date。node 会真实执行 JavaScript。",
            "parameters": ["type": "object", "properties": [
                "command": ["type": "string", "description": "要执行的 shell 命令"],
            ], "required": ["command"]],
        ]],
        ["type": "function", "function": [
            "name": "read_file",
            "description": "读取沙盒内文件内容（相对 ~/ 的路径）",
            "parameters": ["type": "object", "properties": [
                "path": ["type": "string", "description": "文件路径，如 ~/hello.js 或 /home/hello.js"],
            ], "required": ["path"]],
        ]],
        ["type": "function", "function": [
            "name": "write_file",
            "description": "写入（或新建）沙盒内文件",
            "parameters": ["type": "object", "properties": [
                "path": ["type": "string", "description": "文件路径"],
                "content": ["type": "string", "description": "完整文件内容"],
            ], "required": ["path", "content"]],
        ]],
        ["type": "function", "function": [
            "name": "list_files",
            "description": "递归列出目录内容",
            "parameters": ["type": "object", "properties": [
                "path": ["type": "string", "description": "目录路径，空 = ~/"],
            ]],
        ]],
        ["type": "function", "function": [
            "name": "git_clone",
            "description": "把 GitHub 仓库克隆到沙盒（公开仓库无需登录；私有仓库需设置页填 PAT）",
            "parameters": ["type": "object", "properties": [
                "url": ["type": "string", "description": "仓库 https 地址，如 https://github.com/owner/repo"],
            ], "required": ["url"]],
        ]],
    ] }

    func clear() { messages.removeAll() }

    func ask(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        messages.append(Msg(role: "user", text: text))
        busy = true
        // 没填官方 Key → 走网页协议工具降级（本地网关负责注入/解析）
        if (UserDefaults.standard.string(forKey: "jl.officialkey") ?? "").isEmpty {
            Task { await runWebProtocol() }
        } else {
            Task { await runLoop() }
        }
    }

    // MARK: - 网页协议工具降级（过本地网关）

    private func runWebProtocol() async {
        status = "思考中（网页协议工具模式）…"
        var wire: [[String: Any]] = [["role": "system", "content": PromptStore.shared.agentSystem]]
        for m in messages {
            var d: [String: Any] = ["role": m.role, "content": m.text]
            if !m.toolCalls.isEmpty { d["tool_calls"] = m.toolCalls }
            if m.role == "tool" {
                d["tool_call_id"] = (m.toolCalls.first?["id"] as? String) ?? "call_0"
            }
            wire.append(d)
        }
        await webRound(wire)
    }

    private func webRound(_ wire: [[String: Any]]) async {
        let body: [String: Any] = [
            "model": "deepseek-chat", "messages": wire,
            "tools": toolsSchema(), "tool_choice": "auto", "stream": false,
        ]
        guard let url = URL(string: "http://127.0.0.1:\(LocalAPIServer.shared.port)/v1/chat/completions"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            await finish("网关地址无效"); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 180
        status = "思考中…"
        do {
            let (d, _) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            if let e = json["error"] as? [String: Any], let m = e["message"] as? String {
                await finish(m); return
            }
            let msg = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] ?? [:]
            let text = msg["content"] as? String ?? ""
            let calls = msg["tool_calls"] as? [[String: Any]] ?? []
            await MainActor.run {
                var m = Msg(role: "assistant", text: text)
                if !calls.isEmpty { m.running = true; m.toolCalls = calls }
                messages.append(m)
            }
            if calls.isEmpty { await finish(nil); return }
            // 逐个执行工具
            var toolWire: [[String: Any]] = wire
            for tc in calls {
                let fn = tc["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let args = (try? JSONSerialization.jsonObject(with: Data((fn["arguments"] as? String ?? "{}").utf8)))
                    as? [String: Any] ?? [:]
                status = "执行工具 \(name) …"
                let result = execute(name, args)
                await MainActor.run {
                    messages.append(Msg(role: "tool", text: result))
                    if let i = messages.indices.last(where: { messages[$0].running }) {
                        messages[i].toolResults.append((name, result))
                        messages[i].running = false
                    }
                }
                // assistant 的 tool_calls 原样带回（OpenAI 协议要求 tool 消息紧跟带 tool_calls 的 assistant）
                toolWire.append(["role": "assistant", "content": text.isEmpty ? " " : text, "tool_calls": calls])
                toolWire.append(["role": "tool", "tool_call_id": (tc["id"] as? String) ?? "call_0", "content": result])
            }
            status = ""
            await webRound(toolWire)
        } catch {
            await finish("请求网关失败：\(error.localizedDescription)")
        }
    }

    private func finish(_ text: String?) async {
        await MainActor.run {
            if let text { messages.append(Msg(role: "assistant", text: "⚠️ \(text)")) }
            busy = false
            status = ""
        }
    }

    private func runLoop() async {
        for _ in 0..<maxRounds {
            let (resp, errMsg) = await callAPI()
            guard let resp else {
                await MainActor.run {
                    messages.append(Msg(role: "assistant", text: "⚠️ 请求失败：\(errMsg ?? "未知错误")"))
                    busy = false
                }
                return
            }
            let toolCalls = resp["tool_calls"] as? [[String: Any]] ?? []
            let content = resp["content"] as? String ?? ""

            await MainActor.run {
                var m = Msg(role: "assistant", text: content)
                if !toolCalls.isEmpty {
                    m.running = true
                    m.toolCalls = toolCalls
                }
                messages.append(m)
            }

            if toolCalls.isEmpty { break }   // 纯文本 = 收尾

            // 逐个执行工具
            for tc in toolCalls {
                let fn = tc["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let argsRaw = fn["arguments"] as? String ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argsRaw.utf8)))
                    as? [String: Any] ?? [:]
                await MainActor.run { status = "执行工具 \(name) …" }
                let result = execute(name, args)
                await MainActor.run {
                    if let i = messages.indices.last(where: { messages[$0].running }) {
                        messages[i].toolResults.append((name, result))
                    }
                    messages.append(Msg(role: "tool", text: result))
                }
            }
            await MainActor.run {
                if let i = messages.indices.last(where: { messages[$0].running }) { messages[i].running = false }
                status = ""
            }
        }
        await MainActor.run { busy = false }
    }

    // MARK: - 工具执行（全部走真实引擎）

    private func execute(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "run_command":
            let cmd = args["command"] as? String ?? ""
            let r = shell.run(cmd, cwd: fs.home)
            return (r.output.isEmpty ? "（命令执行完毕，无输出）" : r.output)
        case "read_file":
            let p = args["path"] as? String ?? ""
            guard let u = fs.resolve(p, cwd: fs.home) else { return "路径无效或越界" }
            guard let s = fs.read(u) else { return "读取失败：文件不存在或是目录" }
            return String(s.prefix(20000))
        case "write_file":
            let p = args["path"] as? String ?? ""
            let c = args["content"] as? String ?? ""
            guard let u = fs.resolve(p, cwd: fs.home) else { return "路径无效或越界" }
            do { try fs.write(u, c); return "已写入 \(fs.display(u))（\(c.utf8.count) 字节）" }
            catch { return "写入失败：\(error.localizedDescription)" }
        case "list_files":
            let p = args["path"] as? String ?? "~"
            guard let u = fs.resolve(p, cwd: fs.home) else { return "路径无效" }
            if !fs.isDir(u) { return fs.display(u) + "（文件）" }
            return fs.list(u).map { $0.name + ($0.isDir ? "/" : "") }.joined(separator: "  ")
        case "git_clone":
            let url = args["url"] as? String ?? ""
            let injected = GitHubClient.injectToken(url, token: GitHubClient.pat)
            guard let u = URL(string: injected) else { return "URL 无效" }
            var body = Data()
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: u) { d, _, _ in body = d ?? Data(); sem.signal() }.resume()
            sem.wait()
            guard !body.isEmpty else { return "下载失败（仓库不存在或私有未授权）" }
            let name = (url as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
            let dest = fs.home.appendingPathComponent(name.isEmpty ? "repo" : name)
            do {
                try GitHubClient.unzip(body, to: dest)
                return "已克隆到 \(fs.display(dest))"
            } catch { return "解压失败：\(error.localizedDescription)" }
        default:
            return "未知工具 \(name)"
        }
    }

    // MARK: - 官方 API 调用（非流式，带完整 tools）

    private func callAPI() async -> ([String: Any]?, String?) {
        let key = UserDefaults.standard.string(forKey: "jl.officialkey") ?? ""
        guard !key.isEmpty else { return (nil, "未配置官方 API Key（设置页 → 官方直通）") }
        var wire: [[String: Any]] = [
            ["role": "system", "content": PromptStore.shared.agentSystem + (PromptStore.shared.toolsNote.isEmpty ? "" : "\n\n" + PromptStore.shared.toolsNote)],
        ]
        for m in messages {
            var d: [String: Any] = ["role": m.role, "content": m.text]
            if !m.toolCalls.isEmpty { d["tool_calls"] = m.toolCalls }
            if m.role == "tool" && !m.toolCalls.isEmpty {
                d["tool_call_id"] = (m.toolCalls.first?["id"] as? String) ?? "call_0"
            }
            wire.append(d)
        }
        // tool 消息需要配 tool_call_id：用 assistant 消息里的 id 补齐
        var lastCallID = ""
        for i in wire.indices {
            var d = wire[i]
            if let tcs = d["tool_calls"] as? [[String: Any]], let id = tcs.first?["id"] as? String {
                lastCallID = id
            }
            if d["role"] as? String == "tool" {
                d["tool_call_id"] = lastCallID
                wire[i] = d
            }
        }

        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": wire,
            "tools": toolsSchema(),
            "tool_choice": "auto",
            "stream": false,
            "temperature": 0.3,
        ]
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { return (nil, "URL 错误") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let head = String(decoding: d.prefix(300), as: UTF8.self)
                return (nil, "HTTP \(code) \(head)")
            }
            let json = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
            if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return (nil, m) }
            let msg = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] ?? [:]
            return (msg, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
