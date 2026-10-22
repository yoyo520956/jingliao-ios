import Foundation

// ── DeepSeek SSE Patch 状态机（p/o/v 三元组，fragments 分 THINK/RESPONSE）──

struct PatchState {
    private(set) var sawStatus = false
    private(set) var responseMessageID: Int64 = 0
    private var fragments: [String] = []
    // p/o 跨帧持久化（原码对齐：后续帧可省略 p/o，沿用上一帧的路径与操作）
    private var currentPath: String?
    private var currentOp: String?
    private var logged = 0

    mutating func apply(_ json: [String: Any]) -> [DSEvent] {
        var events: [DSEvent] = []

        // 错误帧 {code:非0, msg}
        if let code = (json["code"] as? NSNumber)?.intValue, code != 0 {
            let m = json["msg"] as? String ?? "未知错误(\(code))"
            EngineLog.shared.add("上游错误帧: code=\(code) msg=\(m)")
            events.append(.done(finishReason: "error:\(m)"))
            return events
        }

        // 链路 id 帧（原码：顶层同时带 request_message_id / response_message_id）
        if let rm = (json["response_message_id"] as? NSNumber)?.int64Value {
            responseMessageID = rm
            return events
        }

        // 原始帧诊断（前 40 帧：p/o/v 形状摘要）
        if logged < 40 {
            logged += 1
            EngineLog.shared.add("sse#\(logged): \(Self.frameSummary(json))")
        }

        if let p = json["p"] as? String { currentPath = p }
        if let o = json["o"] as? String { currentOp = o }
        let op = currentOp ?? "SET"
        let rawPath = currentPath ?? ""
        let path = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath

        guard let v = json["v"] else { return events }

        // 初始快照：无 path 且 v.response 存在
        if currentPath == nil,
           let resp = v as? [String: Any], let r = resp["response"] as? [String: Any] {
            return applySnapshot(r)
        }

        // BATCH 递归分解（子补丁各自 p/o，路径与父路径拼接）
        if op == "BATCH", let arr = v as? [[String: Any]] {
            return applyBatch(parent: path, arr)
        }

        return applyPath(path, op, v)
    }

    private mutating func applyBatch(parent: String, _ arr: [[String: Any]]) -> [DSEvent] {
        var events: [DSEvent] = []
        var subPath = ""
        var subOp = "SET"
        for item in arr {
            if let p = item["p"] as? String { subPath = p }
            if let o = item["o"] as? String { subOp = o }
            guard let v = item["v"] else { continue }
            let sub = subPath.hasPrefix("/") ? String(subPath.dropFirst()) : subPath
            let full = parent.isEmpty ? sub : (sub.isEmpty ? parent : parent + "/" + sub)
            if subOp == "BATCH", let subArr = v as? [[String: Any]] {
                events.append(contentsOf: applyBatch(parent: full, subArr))
            } else {
                events.append(contentsOf: applyPath(full, subOp, v))
            }
        }
        return events
    }

    private mutating func applySnapshot(_ r: [String: Any]) -> [DSEvent] {
        var events: [DSEvent] = []
        if let st = r["status"] as? String, st == "FINISHED" || st == "INCOMPLETE" {
            sawStatus = true
            events.append(.done(finishReason: st == "FINISHED" ? "stop" : nil))
        }
        if let arr = r["fragments"] as? [[String: Any]] {
            fragments = []
            for f in arr {
                let ty = f["type"] as? String ?? ""
                let content = f["content"] as? String ?? ""
                if !content.isEmpty {
                    if ty == "THINK" { events.append(.thinkDelta(content)) }
                    else if ty == "RESPONSE" { events.append(.contentDelta(content)) }
                }
                fragments.append(ty)
            }
        }
        if let u = (r["accumulated_token_usage"] as? NSNumber)?.int64Value {
            events.append(.usage(u))
        }
        return events
    }

    private mutating func applyPath(_ path: String, _ op: String, _ v: Any) -> [DSEvent] {
        var events: [DSEvent] = []
        switch path {
        case "response/status":
            if let st = v as? String {
                sawStatus = true
                if st == "FINISHED" || st == "INCOMPLETE" {
                    events.append(.done(finishReason: st == "FINISHED" ? "stop" : nil))
                }
            }
        case "response/accumulated_token_usage", "accumulated_token_usage":
            if let n = (v as? NSNumber)?.int64Value {
                events.append(.usage(n))
            }
        case "response/fragments/-1/content":
            if let s = v as? String {
                let ty = fragments.last ?? ""
                if ty == "THINK" { events.append(.thinkDelta(s)) }
                else if ty == "RESPONSE" { events.append(.contentDelta(s)) }
                else if fragments.isEmpty {
                    // 原码此处直接丢弃；缺 fragment 元数据时按 RESPONSE 兜底防整段丢失
                    events.append(.contentDelta(s))
                }
            }
        case "response/fragments":
            if op == "APPEND", let arr = v as? [[String: Any]] {
                for f in arr {
                    let ty = f["type"] as? String ?? ""
                    let content = f["content"] as? String ?? ""
                    if !content.isEmpty {
                        if ty == "THINK" { events.append(.thinkDelta(content)) }
                        else if ty == "RESPONSE" { events.append(.contentDelta(content)) }
                    }
                    fragments.append(ty)
                }
            } else if op == "SET", let arr = v as? [[String: Any]] {
                // SET 全量替换：只更新类型表（正文走快照/APPEND 通道）
                fragments = arr.map { $0["type"] as? String ?? "" }
            }
        default:
            break
        }
        return events
    }

    static func frameSummary(_ json: [String: Any]) -> String {
        func kind(_ v: Any) -> String {
            switch v {
            case is String: return "str"
            case is NSNumber: return "num"
            case is [Any]: return "arr[\((v as! [Any]).count)]"
            case is [String: Any]: return "obj"
            default: return "\(Swift.type(of: v))"
            }
        }
        var parts: [String] = []
        if let p = json["p"] as? String { parts.append("p=\(p)") }
        if let o = json["o"] as? String { parts.append("o=\(o)") }
        if let v = json["v"] { parts.append("v=\(kind(v))") }
        if json["p"] == nil && json["v"] == nil {
            parts.append("keys=\(json.keys.prefix(4).joined(separator: ","))")
        }
        let s = parts.joined(separator: " ")
        return s.count > 120 ? String(s.prefix(120)) : s
    }
}

// ── 对话引擎 ──────────────────────────────────────────────────────────

final class DSChatEngine {
    static let shared = DSChatEngine()
    private init() {}

    struct CompleteRequest {
        var account: DSAccount
        var sessionID: String
        var parentMessageID: Int64?
        var prompt: String
        var thinking: Bool
        var search: Bool
        var refFileIds: [String] = []
        var onMeta: ((Int64) -> Void)?
    }

    // MARK: 文件上传（图片多模态）

    /// 上传图片 → 拿 file id → 轮询到 SUCCESS（对齐 ds-free-api upload_and_poll）
    func uploadFile(account: DSAccount, filename: String, mime: String, data: Data) async throws -> String {
        // ① PoW（target=/api/v0/file/upload_file）
        let challenge = try await fetchChallenge(account: account, targetPath: "/api/v0/file/upload_file")
        let answer = try await DSPowSolver.shared.solve(challenge)
        var headers = DSIdentity(deviceID: account.deviceID)
            .authedHeaders(site: "same-origin", token: account.token)
        headers["X-Ds-Pow-Response"] = challenge.powResponseHeader(answer: answer)

        // ② multipart POST /file/upload_file（字段名 file）
        let boundary = "----JL\(UUID().uuidString.prefix(12))"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        let upURL = URL(string: DSConfig.apiBase + "/file/upload_file")!
        let upReq = DSIdentity.request(upURL, method: "POST", headers: headers, timeout: 600)
        // DSIdentity.request 带 jsonBody 才设 body，这里手动挂
        var req = upReq
        req.httpBody = body
        let env = try await DSHttp.fetchJSON(req)
        guard let fileId = env.bizData?.dstr("id") ?? env.data?.dstr("id"), !fileId.isEmpty else {
            throw DSError(message: "图片上传失败：未取到文件 id")
        }
        EngineLog.shared.add("图片已上传 file_id=\(fileId.prefix(12))… 轮询处理状态")

        // ③ 轮询 fetch_files 直到 SUCCESS（2s × 15 次）
        let identity = DSIdentity(deviceID: account.deviceID)
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let fURL = URL(string: DSConfig.apiBase + "/file/fetch_files?file_ids=\(fileId)")!
            let fReq = DSIdentity.request(fURL, method: "GET",
                                          headers: identity.authedHeaders(site: "same-origin", token: account.token))
            guard let fEnv = try? await DSHttp.fetchJSON(fReq),
                  let files = fEnv.bizData?["files"] as? [[String: Any]] ?? fEnv.data?["files"] as? [[String: Any]],
                  let f0 = files.first else { continue }
            let st = f0.dstr("status")
            if st == "SUCCESS" {
                EngineLog.shared.add("图片处理完成 file_id=\(fileId.prefix(12))…")
                return fileId
            }
            if st == "FAILED" { throw DSError(message: "图片处理失败（官方返回 FAILED）") }
        }
        throw DSError(message: "图片处理超时（30s 未就绪）")
    }

    // MARK: 会话管理

    func createSession(account: DSAccount) async throws -> String {
        let identity = DSIdentity(deviceID: account.deviceID)
        let url = URL(string: DSConfig.apiBase + "/chat_session/create")!
        let req = DSIdentity.request(url, method: "POST",
                                     headers: identity.authedHeaders(site: "same-origin", token: account.token),
                                     jsonBody: ["agent": "chat"])
        let env = try await DSHttp.fetchJSON(req)
        let id = env.bizData?.dstr("id")
            ?? (env.bizData?["chat_session"] as? [String: Any])?.dstr("id")
            ?? env.data?.dstr("id")
        guard let id, !id.isEmpty else { throw DSError(message: "创建会话失败：未取到 id") }
        return id
    }

    func deleteSession(account: DSAccount, sessionID: String) async {
        let identity = DSIdentity(deviceID: account.deviceID)
        if let url = URL(string: DSConfig.apiBase + "/chat_session/delete") {
            let req = DSIdentity.request(url, method: "POST",
                                         headers: identity.authedHeaders(site: "same-origin", token: account.token),
                                         jsonBody: ["chat_session_id": sessionID], timeout: 30)
            _ = try? await DSHttp.fetchJSON(req)
        }
    }

    // MARK: 补全（流式）

    func complete(_ r: CompleteRequest) -> AsyncThrowingStream<DSEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runCompletion(r) { ev in
                        continuation.yield(ev)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func fetchChallenge(account: DSAccount, targetPath: String) async throws -> DSChallenge {
        let identity = DSIdentity(deviceID: account.deviceID)
        let url = URL(string: DSConfig.apiBase + "/chat/create_pow_challenge")!
        let req = DSIdentity.request(url, method: "POST",
                                     headers: identity.authedHeaders(site: "same-origin", token: account.token),
                                     jsonBody: ["target_path": targetPath])
        let env = try await DSHttp.fetchJSON(req)
        let cj = (env.bizData?["challenge"] as? [String: Any])
            ?? (env.data?["challenge"] as? [String: Any])
        guard let cj, var ch = DSChallenge.parse(cj) else {
            let raw = env.data.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? "nil"
            EngineLog.shared.add("PoW 挑战原始响应: \(raw)")
            throw DSError(message: "PoW 挑战解析失败 原始data=\(raw)")
        }
        if ch.targetPath.isEmpty { ch.targetPath = "/api/v0/chat/completion" }
        return ch
    }

    private func runCompletion(_ r: CompleteRequest, emit: @escaping (DSEvent) -> Void) async throws {
        EngineLog.shared.add("取 PoW 挑战（\("thinking=\(r.thinking) search=\(r.search)")）")
        let challenge = try await fetchChallenge(account: r.account, targetPath: "/api/v0/chat/completion")
        EngineLog.shared.add("PoW 求解 difficulty=\(Int(challenge.difficulty))")
        let answer = try await DSPowSolver.shared.solve(challenge)
        EngineLog.shared.add("PoW 完成 answer=\(answer)")

        var headers = DSIdentity(deviceID: r.account.deviceID)
            .authedHeaders(site: "same-origin", token: r.account.token)
        headers["X-Ds-Pow-Response"] = challenge.powResponseHeader(answer: answer)
        if let leim = await DSHif.shared.token("leim", deviceID: r.account.deviceID) {
            headers["x-hif-leim"] = leim
        }
        if let dliq = await DSHif.shared.token("dliq", deviceID: r.account.deviceID) {
            headers["x-hif-dliq"] = dliq
        }

        var body: [String: Any] = [
            "chat_session_id": r.sessionID,
            "model_type": DSConfig.modelType,
            "prompt": r.prompt,
            "ref_file_ids": r.refFileIds,
            "thinking_enabled": r.thinking,
            "search_enabled": r.search,
            "action": NSNull(),
            "source": DSConfig.completionSource,
            "preempt": false,
        ]
        if let p = r.parentMessageID { body["parent_message_id"] = p }

        let url = URL(string: DSConfig.apiBase + "/chat/completion")!
        let req = DSIdentity.request(url, method: "POST", headers: headers, jsonBody: body, timeout: 900)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        EngineLog.shared.add("completion HTTP \(status)")
        guard (200..<300).contains(status) else {
            var t = ""
            for try await line in bytes.lines {
                t += line
                if t.count > 65536 { break }
            }
            throw DSError(message: "completion HTTP \(status): \(t)")
        }

        var state = PatchState()
        var metaSent = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let data = payload.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let evs = state.apply(json)
            if !metaSent, state.responseMessageID != 0 {
                metaSent = true
                r.onMeta?(state.responseMessageID)
                emit(.meta(state.responseMessageID))
            }
            for ev in evs { emit(ev) }
        }
        if !state.sawStatus { emit(.done(finishReason: nil)) }
        EngineLog.shared.add("流结束")
    }
}
