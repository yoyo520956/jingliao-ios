import SwiftUI

struct ConversationsView: View {
    @EnvironmentObject var chats: ChatStore
    @EnvironmentObject var appState: AppState

    private var sorted: [Conversation] {
        chats.conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if sorted.isEmpty {
                    Text("还没有会话，去「聊天」页发第一条消息吧")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(sorted) { c in
                    Button {
                        appState.openConversationID = c.id
                        appState.tab = 0
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.title)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(c.messages.last?.content ?? "…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            Text(Self.time(c.updatedAt))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let arr = sorted
                    for i in offsets { chats.remove(arr[i].id) }
                }
            }
            .navigationTitle("会话")
        }
    }

    static func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
