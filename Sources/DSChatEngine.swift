import Foundation

// ── DeepSeek SSE Patch 状态机（p/o/v 三元组，fragments 分 THINK/RESPONSE）──

struct PatchState {
    private(set) var sawStatus = false
    private(set) var responseMessageID: Int64 = 0
    private var fragments: [String] = []

    mutating func apply(_ json: [String: Any]) -> [DSEvent] {
        var events: [DSEvent] = []

        // 错误帧 {code:非0, msg}
        if let code = (json["code"] as? NSNumber)?.intValue, code != 0 {
            let m = json["msg"] as? String ?? "未知错误(\(code))"
            EngineLog.shared.add("上游错误帧: code=\(code) msg=\(m)")
            events.append(.done(finishReason: "error:\(m)"))
            return events
        }

        // 形态一：patch 操作 {p, o, v}
        if let p = json["p"] as? String {
            let op = json["o"] as? String ?? "SET"
            let path = p.hasPrefix("/") ? String(p.dropFirst()) : p
            if op == "APPEND" {
                if path == "response/fragments" {
                    if let arr = json["v"] as? [[String: Any]] {
                        for f in arr { fragments.append(f["type"] as? String ?? "RESPONSE") }
                    }
                } else if path.hasPrefix("response/fragments/"), path.hasSuffix("/content") {
                    if let s = json["v"] as? String {
                        if fragments.last == "THINK" { events.append(.thinkDelta(s)) }
                        else { events.append(.contentDelta(s)) }
                    }
                }
            } else { // SET
                if path == "response/status" {
                    sawStatus = true
                    let st = json["v"] as? String ?? ""
                    if st == "FINISHED" || st == "INCOMPLETE" {
                        events.append(.done(finishReason: st == "FINISHED" ? "stop" : nil))
                    }
                } else if path == "response/fragments" {
                    if let arr = json["v"] as? [[String: Any]] {
                        fragments = arr.map { $0["type"] as? String ?? "RESPONSE" }
                    }
                }
                // accumulated_token_usage 等：忽略
            }
            return events
        }

        // 形态二：全量快照 {response: {...}}
        if let resp = json["response"] as? [String: Any] {
            if let arr = resp["fragments"] as? [[String: Any]] {
                fragments = arr.map { $0["type"] as? String ?? "RESPONSE" }
            }
            if let st = resp["status"] as? String, st == "FINISHED" || st == "INCOMPLETE" {
                sawStatus = true
                events.append(.done(finishReason: st == "FINISHED" ? "stop" : nil))
            }
            return events
        }

        // 形态三：消息 id 元数据
        if let rm = (json["response_message_id"] as? NSNumber)?.int64Value {
            responseMessageID = rm
        }
        return events
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
        var onMeta: ((Int64) -> Void)?
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
        if ch.targetPath.isEmpty { ch.targetPath = targetPath }
        return ch
    }

    private func runCompletion(_ r: CompleteRequest, emit: @escaping (DSEvent) -> Void) async throws {
        EngineLog.shared.add("取 PoW 挑战（\("thinking=\(r.thinking) search=\(r.search)")）")
        let challenge = try await fetchChallenge(account: r.account, targetPath: "/chat/completion")
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
            "ref_file_ids": [String](),
            "thinking_enabled": r.thinking,
            "search_enabled": r.search,
            "action": NSNull(),
            "source": DSConfig.completionSource,
            "preempt": false,
        ]
        if let p = r.parentMessageID { body["parent_message_id"] = p }

        let url = URL(string: DSConfig.apiBase + "/chat/completion")!
        let req = DSIdentity.request(url, method: "POST", headers: headers, jsonBody: body, timeout: 300)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        EngineLog.shared.add("completion HTTP \(status)")
        guard (200..<300).contains(status) else {
            var t = ""
            for try await line in bytes.lines {
                t += line
                if t.count > 400 { break }
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
