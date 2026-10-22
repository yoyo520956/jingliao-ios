import SwiftUI

/// 会话列表——微信 8.0.79 风格：导航栏 + 搜索 + 头像行 + 右侧时间/红点
struct ConversationsView: View {
    @EnvironmentObject var chats: ChatStore
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var shareItems: [Any] = []
    @State private var sharing = false

    /// 跨所有会话的所有消息做全文搜索
    private var sorted: [Conversation] {
        let arr = chats.conversations.sorted { $0.updatedAt > $1.updatedAt }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return arr }
        // 标题命中 或 任意消息命中
        return arr.filter { c in
            if c.title.localizedCaseInsensitiveContains(q) { return true }
            return c.messages.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    /// 当前会话在搜索结果中的匹配消息数
    func matchCount(in c: Conversation) -> Int {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        return c.messages.filter { $0.content.localizedCaseInsensitiveContains(q) }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if sorted.isEmpty {
                    Text("还没有会话，去「聊天」页发第一条消息吧")
                        .font(.footnote)
                        .foregroundColor(WX.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(sorted) { c in
                    Button {
                        appState.openConversationID = c.id
                        appState.tab = 0
                    } label: {
                        HStack(spacing: 10) {
                            // 头像：墨底钤印（松烟墨底 + 宣纸字 + 细框）
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(WX.bubbleMine)
                                Text(String(c.title.prefix(1)))
                                    .font(WX.MBF.serif(20))
                                    .foregroundColor(WX.onInk)
                            }
                            .frame(width: 46, height: 46)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(WX.separator, lineWidth: 0.5)
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.title)
                                    .font(WX.MBF.serif(17))
                                    .foregroundColor(WX.titleBlack)
                                    .lineLimit(1)
                                Text(c.messages.last?.content ?? "…")
                                    .font(.system(size: 14))
                                    .foregroundColor(WX.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(Self.time(c.updatedAt))
                                    .font(.system(size: 11))
                                    .foregroundColor(WX.secondary)
                                if !searchText.isEmpty {
                                    let n = matchCount(in: c)
                                    if n > 0 {
                                        Text("\(n) 条命中")
                                            .font(.system(size: 10))
                                            .foregroundColor(WX.green)
                                    }
                                }
                                if !c.messages.isEmpty {
                                    Circle().fill(WX.badgeRed).frame(width: 8, height: 8)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            if let url = ChatExport.tempFile(c) {
                                shareItems = [url]
                                sharing = true
                            }
                        } label: {
                            Label("导出 Markdown", systemImage: "doc.text")
                        }
                        Button {
                            Task { @MainActor in
                                if let img = ChatExport.longImage(c) {
                                    shareItems = [img]
                                    sharing = true
                                }
                            }
                        } label: {
                            Label("生成长图分享", systemImage: "photo.on.rectangle")
                        }
                        Button(role: .destructive) {
                            chats.remove(c.id)
                        } label: {
                            Label("删除会话", systemImage: "trash")
                        }
                    }
                    .listRowBackground(WX.cellBG)
                    .listRowSeparator(.hidden)
                }
                .onDelete { offsets in
                    let arr = sorted
                    for i in offsets { chats.remove(arr[i].id) }
                }
            }
            .listStyle(.plain)
            .background(WX.listBG)
            .scrollContentBackground(.hidden)
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 18) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17))
                            .foregroundColor(WX.green)
                        Image(systemName: "plus")
                            .font(.system(size: 18))
                            .foregroundColor(WX.green)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "搜索会话")
            .sheet(isPresented: $sharing) {
                ShareSheet(items: shareItems)
            }
        }
    }

    static func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
