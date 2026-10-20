import SwiftUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chats: ChatStore
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        NavigationStack {
            let conv = currentConv()
            VStack(spacing: 0) {
                messageList(conv)
                inputBar
            }
            .background(Color(.systemBackground))
            .navigationTitle(conv.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.newChat()
                    } label: {
                        Image(systemName: "plus.message")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        PiPManager.shared.toggle()
                    } label: {
                        Image(systemName: PiPManager.shared.isActive ? "pip.exit" : "pip.enter")
                    }
                }
            }
        }
        .onChange(of: appState.openConversationID) { id in
            if let id {
                vm.open(id)
                appState.openConversationID = nil
            }
        }
        .onAppear { vm.ensureCurrent() }
    }

    private func currentConv() -> Conversation {
        vm.ensureCurrent()
        return chats.conversations.first(where: { $0.id == vm.currentID }) ?? Conversation()
    }

    private func messageList(_ conv: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conv.messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "fish.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.secondary)
                            Text("鲸聊 · DeepSeek 免费直连")
                                .font(.headline)
                            Text("到「账号」页登录网页版账号即可开聊；开「设置→本地网关」还能给其他 App 当 API 用。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                    ForEach(conv.messages) { m in
                        Bubble(m: m).id(m.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: conv.messages.count) { _ in
                scrollToEnd(proxy, conv)
            }
            .onChange(of: conv.messages.last?.content ?? "") { _ in
                scrollToEnd(proxy, conv)
            }
            .onChange(of: conv.messages.last?.thinking ?? "") { _ in
                scrollToEnd(proxy, conv)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ conv: Conversation) {
        if let last = conv.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 6) {
                toggleChip(icon: "brain", title: "深思", on: vm.thinkingOn) {
                    vm.thinkingOn.toggle()
                }
                toggleChip(icon: "globe", title: "联网", on: vm.searchOn) {
                    vm.searchOn.toggle()
                }
            }
            TextField("输入消息…", text: $vm.draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                .submitLabel(.send)
                .onSubmit { vm.send() }
            Button {
                if vm.busy { vm.stop() } else { vm.send() }
            } label: {
                Image(systemName: vm.busy ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(vm.busy ? Color.red : (vm.draft.isEmpty ? Color.gray : Color.blue))
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func toggleChip(icon: String, title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 10))
            }
            .foregroundColor(on ? Color.white : Color.secondary)
            .frame(width: 42, height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.blue : Color(.secondarySystemBackground)))
        }
        .buttonStyle(.borderless)
    }
}

struct Bubble: View {
    let m: ChatMessage
    @State private var showThink = false

    var body: some View {
        HStack(alignment: .top) {
            if m.role == "user" { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 6) {
                if !m.thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showThink) {
                        Text(m.thinking)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label("深度思考", systemImage: "brain.head.profile")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if m.role == "user" {
                    Text(m.content)
                        .foregroundColor(Color.white)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue))
                        .textSelection(.enabled)
                } else if m.failed {
                    Text(m.content)
                        .font(.callout)
                        .foregroundColor(Color.red)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.tertiarySystemFill)))
                } else {
                    MarkdownText(text: m.content.isEmpty ? "…" : m.content)
                        .padding(4)
                }
            }
            if m.role != "user" { Spacer(minLength: 52) }
        }
    }
}
