import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var draft = ""
    @Published var thinkingOn: Bool {
        didSet { UserDefaults.standard.set(thinkingOn, forKey: "jl.thinking") }
    }
    @Published var searchOn: Bool {
        didSet { UserDefaults.standard.set(searchOn, forKey: "jl.search") }
    }
    @Published var busy = false
    @Published var currentID = ""
    @Published var pendingImage: UIImage? = nil

    private var task: Task<Void, Never>?
    private let store = ChatStore.shared
    private let accounts = DSAccountStore.shared

    init() {
        thinkingOn = UserDefaults.standard.object(forKey: "jl.thinking") as? Bool ?? true
        searchOn = UserDefaults.standard.object(forKey: "jl.search") as? Bool ?? false
    }

    func ensureCurrent() {
        if currentID.isEmpty || !store.conversations.contains(where: { $0.id == currentID }) {
            let c = Conversation()
            store.upsert(c)
            currentID = c.id
        }
    }

    func newChat() {
        let c = Conversation()
        store.upsert(c)
        currentID = c.id
    }

    func open(_ id: String) {
        currentID = id
    }

    func send() {
        let prefix = PromptStore.shared.chatPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy else { return }
        guard !text.isEmpty || pendingImage != nil else { return }
        let img = pendingImage
        // 压到 ≤1.5MB（JPEG 0.8），上传官方限制内
        var imageData: Data? = nil
        if let img {
            var d = img.jpegData(compressionQuality: 0.8)
            if let dd = d, dd.count > 1_500_000, let smaller = img.jpegData(compressionQuality: 0.5) { d = smaller }
            imageData = d
        }
        let prompt: String
        if text.isEmpty {
            prompt = (prefix.isEmpty ? "" : prefix + "\n\n") + "请看这张图片，描述并回答关于它的问题。"
        } else {
            prompt = prefix.isEmpty ? text : prefix + "\n\n" + text
        }
        ensureCurrent()
        draft = ""
        pendingImage = nil
        guard var conv = store.conversations.first(where: { $0.id == currentID }) else { return }
        if conv.title == "新对话" { conv.title = String((text.isEmpty ? "图片对话" : text).prefix(24)) }
        conv.messages.append(ChatMessage(role: "user", content: text.isEmpty ? "[图片]" : text, image: imageData))
        let placeholder = ChatMessage(role: "assistant")
        conv.messages.append(placeholder)
        conv.updatedAt = Date().timeIntervalSince1970
        store.upsert(conv)
        busy = true
        let thinking = thinkingOn
        let search = searchOn
        task = Task { [weak self] in
            await self?.run(convID: conv.id, placeholderID: placeholder.id,
                            prompt: prompt, thinking: thinking, search: search, imageData: imageData)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        busy = false
    }

    private func run(convID: String, placeholderID: String, prompt: String,
                     thinking: Bool, search: Bool, imageData: Data? = nil) async {
        guard let account = accounts.pickAvailable() else {
            fail(convID: convID, placeholderID: placeholderID,
                 msg: "没有已登录可用的账号。请到「账号」页添加并登录（建议小号）。")
            return
        }
        accounts.touch(account)
        let engine = DSChatEngine.shared
        do {
            // 图片先传官方拿 ref_file_ids
            var refFileIds: [String] = []
            if let imageData {
                let fid = try await engine.uploadFile(account: account, filename: "img.jpg",
                                                      mime: "image/jpeg", data: imageData)
                refFileIds = [fid]
            }
            guard var conv = store.conversations.first(where: { $0.id == convID }) else { return }
            if conv.sessionID.isEmpty {
                conv.sessionID = try await engine.createSession(account: account)
                store.upsert(conv)
            }
            let parentID = conv.parentMessageID
            let req = DSChatEngine.CompleteRequest(
                account: account, sessionID: conv.sessionID,
                parentMessageID: parentID == 0 ? nil : parentID,
                prompt: prompt, thinking: thinking, search: search,
                refFileIds: refFileIds, onMeta: nil)
            // 实时统计：上下文基线 = 历史消息正文 + 本条 prompt
            let baseCtx = conv.messages.reduce(0) { $0 + $1.content.count } + prompt.count
            LiveStatsCenter.shared.beginRound(baseContextChars: baseCtx)
            var thinkText = ""
            var contentText = ""
            for try await ev in engine.complete(req) {
                if Task.isCancelled { break }
                switch ev {
                case .thinkDelta(let t):
                    thinkText += t
                    patch(convID: convID, msgID: placeholderID) { $0.thinking = thinkText }
                case .contentDelta(let t):
                    contentText += t
                    LiveStatsCenter.shared.appendStream(t)
                    patch(convID: convID, msgID: placeholderID) { $0.content = contentText }
                case .usage(let u):
                    LiveStatsCenter.shared.setUsage(u)
                case .meta(let mid):
                    if var c = store.conversations.first(where: { $0.id == convID }) {
                        c.parentMessageID = mid
                        store.upsert(c)
                    }
                case .done(let fr):
                    if let fr, fr.hasPrefix("error:") {
                        throw DSError(message: String(fr.dropFirst(6)))
                    }
                }
            }
            LiveStatsCenter.shared.endRound()
            patch(convID: convID, msgID: placeholderID) { m in
                m.thinking = thinkText
                m.content = contentText.isEmpty ? "（空回复）" : contentText
            }
        } catch is CancellationError {
            LiveStatsCenter.shared.abortRound()
            patch(convID: convID, msgID: placeholderID) { m in
                if m.content.isEmpty { m.content = "（已停止）" }
            }
        } catch {
            LiveStatsCenter.shared.abortRound()
            let msg = error.localizedDescription
            if msg.contains("SESSION") || msg.lowercased().contains("session") {
                if var c = store.conversations.first(where: { $0.id == convID }) {
                    c.sessionID = ""
                    store.upsert(c)
                }
            }
            fail(convID: convID, placeholderID: placeholderID, msg: msg)
        }
        busy = false
        task = nil
    }

    private func patch(convID: String, msgID: String, _ f: (inout ChatMessage) -> Void) {
        guard var conv = store.conversations.first(where: { $0.id == convID }) else { return }
        guard let i = conv.messages.firstIndex(where: { $0.id == msgID }) else { return }
        f(&conv.messages[i])
        conv.updatedAt = Date().timeIntervalSince1970
        store.upsert(conv)
    }

    private func fail(convID: String, placeholderID: String, msg: String) {
        patch(convID: convID, msgID: placeholderID) { m in
            m.failed = true
            m.content = "❌ " + msg
        }
        busy = false
    }
}
