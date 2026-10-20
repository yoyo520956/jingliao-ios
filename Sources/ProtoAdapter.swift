import Foundation

/// Anthropic Messages + OpenAI Responses 协议适配（移植自 ds-free-api）
/// 目的：让更多第三方客户端（只认这两种协议的 App）也能直接连鲸聊网关
enum ProtoAdapter {

    // MARK: - Anthropic Messages → OpenAI Chat Completions

    /// /anthropic/v1/messages 请求体 → OpenAI messages 数组
    static func anthropicToOpenAI(_ body: [String: Any]) -> [String: Any] {
        var out = body
        var msgs: [[String: Any]] = []
        // system：Anthropic 是顶层字段（字符串或 blocks 数组）
        if let sys = body["system"] {
            let sysText: String
            if let s = sys as? String { sysText = s }
            else if let blocks = sys as? [[String: Any]] {
                sysText = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { sysText = "" }
            if !sysText.isEmpty { msgs.append(["role": "system", "content": sysText]) }
        }
        // messages：content 为 string 或 blocks
        for m in (body["messages"] as? [[String: Any]] ?? []) {
            let role = m["role"] as? String ?? "user"
            var content = ""
            if let c = m["content"] as? String { content = c }
            else if let blocks = m["content"] as? [[String: Any]] {
                content = blocks.compactMap { b -> String? in
                    if (b["type"] as? String) == "text" { return b["text"] as? String }
                    if (b["type"] as? String) == "tool_result" { return b["content"] as? String }
                    if (b["type"] as? String) == "tool_use", let n = b["name"] as? String {
                        return "[tool_use] \(n) \(json(b["input"] ?? [:]))"
                    }
                    return nil
                }.joined(separator: "\n")
            }
            msgs.append(["role": role == "assistant" ? "assistant" : "user", "content": content])
        }
        out["messages"] = msgs
        // tools → OpenAI 格式
        if let tools = body["tools"] as? [[String: Any]] {
            out["tools"] = tools.map { t -> [String: Any] in
                var f: [String: Any] = [:]
                if let name = t["name"] as? String { f["name"] = name }
                if let desc = t["description"] as? String { f["description"] = desc }
                f["parameters"] = t["input_schema"] ?? [:]
                return ["type": "function", "function": f]
            }
        }
        out.removeValue(forKey: "system")
        // max_tokens / temperature 等原样保留（OpenAI 侧叫 max_tokens）
        return out
    }

    /// OpenAI 响应 → Anthropic Messages 响应
    static func openAIToAnthropic(_ json: [String: Any], model: String) -> [String: Any] {
        let choices = (json["choices"] as? [[String: Any]]) ?? []
        let msg = choices.first?["message"] as? [String: Any] ?? [:]
        let usage = json["usage"] as? [String: Any] ?? [:]
        var contentBlocks: [[String: Any]] = []
        let text = msg["content"] as? String ?? ""
        if !text.isEmpty { contentBlocks.append(["type": "text", "text": text]) }
        for tc in (msg["tool_calls"] as? [[String: Any]] ?? []) {
            let fn = tc["function"] as? [String: Any] ?? [:]
            contentBlocks.append([
                "type": "tool_use",
                "id": tc["id"] as? String ?? "toolu_0",
                "name": fn["name"] as? String ?? "",
                "input": (try? JSONSerialization.jsonObject(with: Data((fn["arguments"] as? String ?? "{}").utf8))) as? [String: Any] ?? [:],
            ])
        }
        var stop: String? = "end_turn"
        let fr = choices.first?["finish_reason"] as? String
        if fr == "tool_calls" { stop = "tool_use" }
        else if fr == "length" { stop = "max_tokens" }
        let input = (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["completion_tokens"] as? Int) ?? 0
        return [
            "id": "msg_" + UUID().uuidString.prefix(12).description,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": contentBlocks,
            "stop_reason": stop ?? NSNull(),
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": input, "output_tokens": output],
        ]
    }

    // MARK: - OpenAI Responses（/v1/responses）→ Chat Completions

    static func responsesToOpenAI(_ body: [String: Any]) -> [String: Any] {
        var out = body
        var msgs: [[String: Any]] = []
        if let instructions = body["instructions"] as? String, !instructions.isEmpty {
            msgs.append(["role": "system", "content": instructions])
        }
        // input 可以是 string 或 blocks 数组
        let input = body["input"]
        var items: [[String: Any]] = []
        if let s = input as? String { items = [["role": "user", "content": s]] }
        else if let arr = input as? [[String: Any]] {
            for it in arr {
                let role = it["role"] as? String ?? "user"
                if let c = it["content"] as? String {
                    items.append(["role": role, "content": c])
                } else if let parts = it["content"] as? [[String: Any]] {
                    let t = parts.compactMap { p -> String? in
                        if (p["type"] as? String) == "input_text" || (p["type"] as? String) == "output_text" {
                            return p["text"] as? String
                        }
                        return nil
                    }.joined(separator: "\n")
                    items.append(["role": role, "content": t])
                }
            }
        }
        msgs.append(contentsOf: items)
        out["messages"] = msgs
        out["stream"] = body["stream"] as? Bool ?? false
        if let maxOut = body["max_output_tokens"] as? Int { out["max_tokens"] = maxOut }
        return out
    }

    // MARK: - 工具调用三层自修复（text → JSON → 调用方兜底）

    /// 第一层：文本修复（修反斜杠转义、未加引号的键）
    static func repairJSONText(_ s: String) -> String {
        var t = s
        // 非法反斜杠：\x 其中 x 不是合法转义字符 → 双写
        var out = ""
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c == "\\" {
                let next = t.index(after: i)
                if next < t.endIndex {
                    let n = t[next]
                    if "\"\\/bfnrtu".contains(n) {
                        out.append(c); out.append(n)
                        i = t.index(after: next)
                        continue
                    }
                }
                out.append("\\\\")   // 双写掉非法转义
                i = t.index(after: i)
                continue
            }
            out.append(c)
            i = t.index(after: i)
        }
        t = out
        // 未加引号的键：{name: 或 ,name:
        t = t.replacingOccurrences(of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#, with: "$1\"$2\":", options: .regularExpression)
        return t
    }

    /// 尝试解析工具参数 JSON：原串 → 文本修复 → 成功返回 JSON 字符串
    static func coerceArguments(_ raw: String) -> String {
        if let _ = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) { return raw }
        let fixed = repairJSONText(raw)
        if let _ = try? JSONSerialization.jsonObject(with: Data(fixed.utf8)) { return fixed }
        // 仍失败：用单引号包裹整体（DeepSeek 偶发）
        let quoted = "\"" + raw.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        if let _ = try? JSONSerialization.jsonObject(with: Data(quoted.utf8)) { return quoted }
        return "{}"
    }

    private static func json(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
