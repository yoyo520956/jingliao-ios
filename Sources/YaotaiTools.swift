import Foundation

/// 网页版协议上的 OpenAI function calling（移植自 ds-free-api openai_adapter）
///
/// 原理：DeepSeek 网页版没有原生 tools 字段，但模型会认"标记包裹 JSON"的指令——
///   请求侧：把工具定义 + 调用格式规则注入 prompt（tools.rs）
///   响应侧：从模型正文里用 <|tool_calls_begin|>…<|tool_calls_end|> 切出 JSON 数组（tool_parser）
/// 三层自修复（文本修复 → JSON 修复 → 模型兜底请求）由调用方按序执行。
enum YaotaiTools {

    static let TOOL_CALL_START = "<|tool_calls_begin|>"
    static let TOOL_CALL_END = "<|tool_calls_end|>"
    /// DeepSeek 网页模型的原生工具标记（网页版 UI 用的就是这套，实测模型优先吐它）
    /// 形如：<|DSML|calls><|DSML|invoke name="run_command"><|DSML|parameter name="command" string="true">ls<|DSML|parameter>…<|DSML|invoke><|DSML|calls>
    static let DSML_CALLS_OPEN = "<|DSML|calls>"
    static let DSML_INVOKE_OPEN = "<|DSML|invoke"

    // MARK: - 请求侧：工具定义注入 prompt

    /// 从 OpenAI 请求体提取 tools 列表（[{function:{name,description,parameters}}]）
    static func extractToolDefs(_ json: [String: Any]) -> [[String: Any]] {
        guard let tools = json["tools"] as? [[String: Any]], !tools.isEmpty else { return [] }
        guard let choice = toolChoice(json) else { return [] }   // none 时不注入
        var funcs: [[String: Any]] = []
        for t in tools {
            if (t["type"] as? String ?? "function") == "function",
               let f = t["function"] as? [String: Any],
               let name = f["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                funcs.append(f)
            }
        }
        return funcs
    }

    /// tool_choice: "none" → nil（不注入）；其余 → 行为指令文本（可空字符串）
    static func toolChoice(_ json: [String: Any]) -> String? {
        let hasTools = ((json["tools"] as? [[String: Any]]) ?? []).isEmpty == false
        let choice: Any = json["tool_choice"] ?? (hasTools ? "auto" : "none")
        if let mode = choice as? String {
            if mode == "none" { return nil }
            return mode == "required" ? "**注意：你必须调用一个或多个工具。**" : ""
        }
        if let named = choice as? [String: Any], let f = named["function"] as? [String: Any],
           let name = f["name"] as? String {
            return "**注意：你必须调用 '\(name)' 工具。**"
        }
        return nil
    }

    /// 生成完整的工具注入文本（格式模板 + 规则 + 工具定义 + 行为指令）
    static func buildInjection(_ json: [String: Any], funcs: [[String: Any]]) -> String {
        var lines: [String] = []
        let names = funcs.compactMap { $0["name"] as? String }

        // 格式模板与规则
        lines.append("**工具调用格式 — 请严格遵守：**")
        lines.append("")
        lines.append("方式一（JSON 标记）：将 JSON 数组包裹在工具调用标记中：")
        lines.append("")
        lines.append("\(TOOL_CALL_START)[{\"name\": \"工具名\", \"arguments\": {参数JSON}}]\(TOOL_CALL_END)")
        lines.append("")
        lines.append("方式二（DeepSeek 原生 DSML 标记，与上面二选一即可）：")
        lines.append("")
        lines.append("\(DSML_CALLS_OPEN)<|DSML|invoke name=\"工具名\"><|DSML|parameter name=\"参数名\" string=\"true\">参数值<|DSML|parameter><|DSML|invoke><|/DSML|calls>")
        lines.append("")
        lines.append("**规则：**")
        lines.append("")
        lines.append("**核心：决定调用工具时，你的响应中只允许出现工具调用文本本身，禁止任何解释、前缀、总结、问候语等额外内容。**")
        lines.append("")
        lines.append("1. JSON 数组必须以 \(TOOL_CALL_START) 开头、以 \(TOOL_CALL_END) 结尾，完整包裹在标记内。")
        lines.append("2. 所有工具调用必须放在一个 JSON 数组中，多个调用用逗号分隔。")
        lines.append("3. 输出 \(TOOL_CALL_END) 后立即停止，不得添加后续文本。")
        lines.append("4. 不要将工具调用包裹在 markdown 代码块中。")
        lines.append("5. 字符串参数值必须用双引号包裹（JSON 标准）。")
        lines.append("6. 决定调用工具时，输出的第一个非空白字符必须是 \(TOOL_CALL_START)。")
        lines.append("7. 整个响应中只能出现一个 \(TOOL_CALL_START) 块，不要重复输出。")
        lines.append("8. 不要把回复和工具调用放在思考内容（<think> 标签）中。")
        lines.append("")

        // 动态示例
        if let a = names.first {
            lines.append("**正确示例：**")
            lines.append("**示例A** — 调用一个工具：")
            lines.append("\(TOOL_CALL_START)[{\"name\": \"\(a)\", \"arguments\": \(exampleArgs(a))}]\(TOOL_CALL_END)")
            lines.append("")
        }

        // 工具定义
        lines.append("你可以使用以下工具：")
        for f in funcs {
            let name = f["name"] as? String ?? "?"
            let desc = ((f["description"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let params = jsonString(f["parameters"] ?? [:])
            let example = "\(TOOL_CALL_START)[{\"name\": \"\(name)\", \"arguments\": \(params)}]\(TOOL_CALL_END)"
            let descBlock = desc.isEmpty ? "  无描述" : "  \(desc)"
            lines.append("- **\(name)** (function):")
            lines.append("  - 调用方法: `\(example)`")
            lines.append("  - 简要说明:")
            lines.append(descBlock)
        }

        // 行为指令
        if let instr = toolChoice(json), !instr.isEmpty {
            lines.append("")
            lines.append(instr)
        }
        if json["parallel_tool_calls"] as? Bool == false {
            lines.append("**注意：一次只能调用一个工具。**")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 响应侧：从正文文本切出 tool_calls

    struct ParsedToolCall {
        var id: String
        var name: String
        var arguments: String     // JSON 字符串
    }

    /// 在累积正文里查找工具调用块；返回 (工具列表, 剥掉工具块后的剩余正文)
    /// 对应 Rust 的 parse_tool_calls_with；DSML 为 DeepSeek 网页模型原生格式，优先尝试
    static func parse(_ text: String) -> (calls: [ParsedToolCall], remainder: String)? {
        if text.contains("<|DSML|"), let dsml = parseDSML(text) { return dsml }
        guard let sRange = text.range(of: TOOL_CALL_START) else { return nil }
        let afterStart = text[sRange.upperBound...]
        // 找第一个 END 标记（END 前的 JSON 数组）
        guard let eRange = afterStart.range(of: TOOL_CALL_END) else {
            // 流式场景：END 还没到，调用方应继续累积
            return nil
        }
        let rawJSON = String(afterStart[..<eRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = parseCallArray(rawJSON)
        // 剥掉工具块：start 之前 + end 之后
        let before = String(text[..<sRange.lowerBound])
        let after = String(text[eRange.upperBound...])
        let remainder = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        return (calls, remainder)
    }

    /// 流式中场：只有 START 没有 END —— 告诉调用方"进入工具调用态，正文暂不外发"
    static func hasStart(_ text: String) -> Bool {
        text.contains(TOOL_CALL_START) || text.contains("<|DSML|")
    }

    // MARK: - DSML 解析（DeepSeek 原生工具标记）

    /// 解析 DSML 块：invoke name + parameter string 两种形态
    /// - string="true" → 参数体是原始字符串，直接用
    /// - 无/string="false" → 参数体是 JSON 文本，解析失败回落原始字符串
    private static func parseDSML(_ text: String) -> (calls: [ParsedToolCall], remainder: String)? {
        guard let ir = try? NSRegularExpression(pattern: "<\\|\\/?DSML\\|invoke\\s+name=\"([^\"]+)\"\\s*>"),
              let pr = try? NSRegularExpression(pattern: "<\\|\\/?DSML\\|parameter\\s+name=\"([^\"]+)\"(?:\\s+string=\"([^\"]*)\")?\\s*>") else {
            return nil
        }
        let ns = text as NSString
        let invokes = ir.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !invokes.isEmpty else { return nil }

        // 块结束标记：最后出现的 invoke/calls 关闭（带不带斜杠都认）；一个都没有=流式截断，块后无正文
        var blockEnd = ns.length
        if let r = lastCloseMarker(text, closers: ["</|DSML|calls>", "<|/DSML|calls>", "</|DSML|invoke>", "<|/DSML|invoke>", "<|DSML|invoke>", "<|DSML|calls>"]) {
            blockEnd = text.distance(from: text.startIndex, to: r)
        }

        var calls: [ParsedToolCall] = []
        for (i, im) in invokes.enumerated() {
            let regionStart = im.range.location + im.range.length
            let regionEnd = min((i + 1 < invokes.count) ? invokes[i + 1].range.location : blockEnd, blockEnd)
            guard regionStart <= regionEnd else { continue }
            let region = ns.substring(with: NSRange(location: regionStart, length: max(0, regionEnd - regionStart)))
            let args = parseDSMLParams(region, regex: pr)
            calls.append(ParsedToolCall(id: "call_\(UUID().uuidString.prefix(8))_\(i)",
                                        name: ns.substring(with: im.range(at: 1)), arguments: args))
        }

        // 剥除：第一个 DSML 标记之前是正文，块结束标记之后是尾巴
        let cutFrom = text.range(of: "<|DSML")?.lowerBound ?? text.startIndex
        let head = String(text[..<cutFrom]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail: String
        if blockEnd < ns.length, blockEnd > 0 {
            tail = ns.substring(from: blockEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            tail = ""
        }
        return (calls, [head, tail].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// 所有关闭标记里取位置最靠后的一个（返回其 UTF-16 起始偏移）
    private static func lastCloseMarker(_ text: String, closers: [String]) -> Int? {
        var best: Int?
        for c in closers {
            var r = text.range(of: c)
            while let rr = r {
                let loc = text.distance(from: text.startIndex, to: rr.upperBound)
                best = max(best ?? 0, loc)
                r = text.range(of: c, range: rr.upperBound..<text.endIndex)
            }
        }
        return best
    }

    private static func parseDSMLParams(_ region: String, regex: NSRegularExpression) -> String {
        let ns = region as NSString
        let matches = regex.matches(in: region, range: NSRange(location: 0, length: ns.length))
        var dict: [String: Any] = [:]
        guard !matches.isEmpty else { return "{}" }
        for m in matches {
            let key = ns.substring(with: m.range(at: 1))
            let r2 = m.range(at: 2)
            // string="true" → 原始字符串；缺省或 false → 参数体按 JSON 解析（DeepSeek DSML 规范）
            let asString = (r2.location != NSNotFound) && (ns.substring(with: r2) == "true")
            let bodyStart = m.range.location + m.range.length
            // 参数体到下一个 parameter 关闭标记（带不带斜杠都认）
            var bodyEnd = ns.length
            for closer in ["<|/DSML|parameter>", "</|DSML|parameter>", "<|DSML|parameter>", "<|/DSML|invoke>", "</|DSML|invoke>", "<|DSML|invoke>"] {
                if let r = region.range(of: closer, options: .literal, range: region.index(region.startIndex, offsetBy: min(bodyStart, ns.length))..<region.endIndex) {
                    let loc = region.distance(from: region.startIndex, to: r.lowerBound)
                    bodyEnd = min(bodyEnd, loc)
                }
            }
            guard bodyEnd >= bodyStart else { continue }
            let raw = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if asString {
                dict[key] = raw
            } else if let d = raw.data(using: .utf8),
                      let v = try? JSONSerialization.jsonObject(with: d) {
                dict[key] = v   // 数字/布尔/对象/数组/JSON 字符串原样进参
            } else {
                dict[key] = raw
            }
        }
        return jsonString(dict as Any)
    }

    private static func parseCallArray(_ raw: String) -> [ParsedToolCall] {
        // 容忍模型在数组前后吐了废话：截取第一个 [ 到最后一个 ]
        var s = raw
        if let lb = s.firstIndex(of: "["), s.hasPrefix("[") == false {
            s = String(s[lb...])
        }
        if let rb = s.lastIndex(of: "]"), !s.hasSuffix("]") {
            s = String(s[..<rb] + "]")
        }
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [ParsedToolCall] = []
        for (i, item) in arr.enumerated() {
            guard let name = item["name"] as? String else { continue }
            let args: String
            if let a = item["arguments"] as? String { args = a }
            else if let a = item["arguments"] { args = jsonString(a) }
            else { args = "{}" }
            out.append(ParsedToolCall(id: "call_\(UUID().uuidString.prefix(8))_\(i)", name: name, arguments: args))
        }
        return out
    }

    private static func jsonString(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func exampleArgs(_ name: String) -> String {
        switch name {
        case "Read", "read_file": return "{\"file_path\": \"/path/to/file\"}"
        case "Bash", "execute_command", "exec_command", "run_command": return "{\"command\": \"ls -la\"}"
        case "Write", "write_to_file", "write_file": return "{\"file_path\": \"/path/to/file\", \"content\": \"hello\"}"
        case "Edit": return "{\"file_path\": \"/path/to/file\", \"old_string\": \"foo\", \"new_string\": \"bar\"}"
        case "list_files": return "{\"path\": \".\"}"
        case "git_clone": return "{\"url\": \"https://github.com/owner/repo\"}"
        default: return "{\"key\": \"value\"}"
        }
    }
}
