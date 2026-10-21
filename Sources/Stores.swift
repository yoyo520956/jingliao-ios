import Foundation

// ── 账号模型与账号池 ───────────────────────────────────────────────────

struct DSAccount: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var label: String = ""
    var email: String = ""
    var mobile: String = ""
    var areaCode: String = "+86"
    var password: String = ""
    var deviceID: String = UUID().uuidString
    var token: String = ""
    var userID: String = ""
    var muted: Bool = false
    var muteUntil: Double = 0
    var lastUsed: Double = 0

    var statusText: String {
        if token.isEmpty { return "未登录" }
        let now = Date().timeIntervalSince1970
        if muted && muteUntil > now {
            let d = (muteUntil - now) / 86400
            return "禁言中（剩 \(String(format: "%.0f", d)) 天）"
        }
        return "可用"
    }

    var display: String {
        if !label.isEmpty { return label }
        if !email.isEmpty { return email }
        if !mobile.isEmpty { return areaCode + " " + mobile }
        return "账号 " + id.suffix(4)
    }
}

final class DSAccountStore: ObservableObject {
    static let shared = DSAccountStore()

    @Published var accounts: [DSAccount] = [] {
        didSet { guard loaded else { return } ; save() }
    }
    private var loaded = false
    private let file: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        file = docs.appendingPathComponent("jl_accounts.json")
        if let d = try? Data(contentsOf: file),
           let arr = try? JSONDecoder().decode([DSAccount].self, from: d) {
            accounts = arr
        }
        loaded = true
    }

    private func save() {
        if let d = try? JSONEncoder().encode(accounts) {
            try? d.write(to: file, options: .atomic)
        }
    }

    func add(_ a: DSAccount) { accounts.append(a) }
    func update(_ a: DSAccount) {
        if let i = accounts.firstIndex(where: { $0.id == a.id }) { accounts[i] = a }
    }
    func remove(_ id: String) { accounts.removeAll { $0.id == id } }

    /// 空闲最久优先；跳过未登录与禁言中
    func pickAvailable() -> DSAccount? {
        let now = Date().timeIntervalSince1970
        let usable = accounts.filter { !$0.token.isEmpty && (!$0.muted || $0.muteUntil <= now) }
        return usable.min { $0.lastUsed < $1.lastUsed }
    }

    func touch(_ a: DSAccount) {
        var m = a
        m.lastUsed = Date().timeIntervalSince1970
        update(m)
    }
}

// ── 本地会话存储 ──────────────────────────────────────────────────────

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var role: String
    var content: String = ""
    var thinking: String = ""
    var failed: Bool = false
    var image: Data? = nil
    var at: Double = Date().timeIntervalSince1970
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String = "新对话"
    var messages: [ChatMessage] = []
    var sessionID: String = ""
    var parentMessageID: Int64 = 0
    var createdAt: Double = Date().timeIntervalSince1970
    var updatedAt: Double = Date().timeIntervalSince1970
}

final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published var conversations: [Conversation] = [] {
        didSet { guard loaded else { return } ; save() }
    }
    private var loaded = false
    private let file: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        file = docs.appendingPathComponent("jl_chats.json")
        if let d = try? Data(contentsOf: file),
           let arr = try? JSONDecoder().decode([Conversation].self, from: d) {
            conversations = arr
        }
        loaded = true
    }

    private func save() {
        if let d = try? JSONEncoder().encode(conversations) {
            try? d.write(to: file, options: .atomic)
        }
    }

    func upsert(_ c: Conversation) {
        if let i = conversations.firstIndex(where: { $0.id == c.id }) {
            conversations[i] = c
        } else {
            conversations.insert(c, at: 0)
        }
    }

    func remove(_ id: String) { conversations.removeAll { $0.id == id } }

    func clearAll() { conversations = [] }
}
