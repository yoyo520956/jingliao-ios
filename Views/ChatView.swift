import SwiftUI
import UIKit

/// 聊天页——微信 8.0.79 风格：灰底白/我的绿气泡、底部语音/表情/加号输入栏
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
            .background(WX.listBG)
            .navigationTitle(conv.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.newChat()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18))
                            .foregroundColor(WX.titleBlack)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        PiPManager.shared.toggle()
                    } label: {
                        Image(systemName: PiPManager.shared.isActive ? "pip.exit" : "pip.enter")
                            .foregroundColor(WX.titleBlack)
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    if conv.messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "fish.fill")
                                .font(.system(size: 44))
                                .foregroundColor(WX.secondary)
                            Text("鲸聊 · DeepSeek 免费直连")
                                .font(.headline)
                                .foregroundColor(WX.titleBlack)
                            Text("到「账号」页登录网页版账号即可开聊；开「设置→本地网关」还能给其他 App 当 API 用。")
                                .font(.footnote)
                                .foregroundColor(WX.secondary)
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
            .onChange(of: conv.messages.count) { _ in scrollToEnd(proxy, conv) }
            .onChange(of: conv.messages.last?.content ?? "") { _ in scrollToEnd(proxy, conv) }
            .onChange(of: conv.messages.last?.thinking ?? "") { _ in scrollToEnd(proxy, conv) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ conv: Conversation) {
        if let last = conv.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    /// 微信输入栏：工具列（深思/联网）+ 输入框 + 语音键 + 发送键
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 6) {
                toggleChip(title: "深思", on: vm.thinkingOn) { vm.thinkingOn.toggle() }
                toggleChip(title: "联网", on: vm.searchOn) { vm.searchOn.toggle() }
            }
            TextField("", text: $vm.draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 17))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(WX.inputField))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WX.separator, lineWidth: 0.5))
                .submitLabel(.send)
                .onSubmit { vm.send() }
            VStack(spacing: 6) {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.chevron.down")
                        .font(.system(size: 15))
                        .foregroundColor(WX.titleBlack)
                        .frame(width: 34, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(WX.inputField))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WX.separator, lineWidth: 0.5))
                }
                .buttonStyle(.borderless)
                Button {
                    if vm.busy { vm.stop() } else { vm.send() }
                } label: {
                    Image(systemName: vm.busy ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(vm.busy ? WX.badgeRed : (vm.draft.isEmpty ? WX.secondary : WX.green))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WX.inputBar)
        .overlay(alignment: .top) { Rectangle().fill(WX.separator).frame(height: 0.5) }
    }

    private func toggleChip(title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(on ? .white : WX.titleBlack)
                .frame(width: 42, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? WX.green : WX.inputField))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WX.separator, lineWidth: 0.5))
        }
        .buttonStyle(.borderless)
    }
}

/// 微信气泡：我的 #95EC69 右对齐带尾巴，对方白色左对齐
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
                            .foregroundColor(WX.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label("深度思考", systemImage: "brain.head.profile")
                            .font(.caption)
                            .foregroundColor(WX.secondary)
                    }
                }
                if m.role == "user" {
                    HStack(alignment: .bottom, spacing: 6) {
                        Text(m.content)
                            .font(.system(size: 17))
                            .foregroundColor(WX.titleBlack)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        Text("")
                            .frame(width: 6, height: 6)
                            .background(Color.white.opacity(0.0001))
                    }
                    .background(WX.bubbleMine)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        // 气泡小尾巴
                        Path { p in
                            p.move(to: CGPoint(x: 40, y: 0))
                            p.addLine(to: CGPoint(x: 48, y: 0))
                            p.addLine(to: CGPoint(x: 40, y: 6))
                            p.closeSubpath()
                        }
                        .fill(WX.bubbleMine)
                        .rotationEffect(.degrees(180))
                        .offset(x: -4, y: -3)
                        .frame(width: 48, height: 6)
                    }
                } else if m.failed {
                    Text(m.content)
                        .font(.callout)
                        .foregroundColor(WX.badgeRed)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
                } else {
                    MarkdownText(text: m.content.isEmpty ? "…" : m.content)
                        .padding(4)
                }
            }
            if m.role != "user" { Spacer(minLength: 52) }
        }
    }
}
