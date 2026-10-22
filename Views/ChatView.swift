import SwiftUI
import UIKit
import PhotosUI
import AVFoundation

/// 聊天页——微信 8.0.79 风格：灰底白/我的绿气泡、底部语音/表情/加号输入栏
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var chats: ChatStore
    @StateObject private var vm = ChatViewModel()
    @State private var photoItem: PhotosPickerItem?

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
                // 衬线书卷标题
                ToolbarItem(placement: .principal) {
                    Text(conv.title)
                        .font(WX.MBF.serif(18))
                        .foregroundColor(WX.titleBlack)
                        .lineLimit(1)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.newChat()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18))
                            .foregroundColor(WX.green)
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
                                .foregroundColor(WX.green)
                            Text("鲸聊 · 一札新纸")
                                .font(WX.MBF.serif(20))
                                .foregroundColor(WX.titleBlack)
                            Text("到「账号」页登录网页版账号即可开聊；开「设置→本地网关」还能给其他 App 当 API 用。")
                                .font(.system(size: 14))
                                .foregroundColor(WX.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 280)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                    ForEach(conv.messages) { m in
                        Bubble(m: m).id(m.id)
                            .contextMenu {
                                if !m.content.isEmpty {
                                    Button {
                                        UIPasteboard.general.string = m.content
                                    } label: {
                                        Label("复制内容", systemImage: "doc.on.doc")
                                    }
                                    ShareLink(item: m.content) {
                                        Label("分享", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        if TTSController.shared.isSpeaking {
                                            TTSController.shared.stop()
                                        } else {
                                            TTSController.shared.speak(m.content)
                                        }
                                    } label: {
                                        Label("朗读", systemImage: "speaker.wave.2")
                                    }
                                    Divider()
                                }
                                Button(role: .destructive) {
                                    if let idx = chats.conversations.firstIndex(where: { $0.id == conv.id }) {
                                        if let midx = chats.conversations[idx].messages.firstIndex(where: { $0.id == m.id }) {
                                            chats.conversations[idx].messages.remove(at: midx)
                                            chats.upsert(chats.conversations[idx])
                                        }
                                    }
                                } label: {
                                    Label("删除消息", systemImage: "trash")
                                }
                            }
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
                .background(RoundedRectangle(cornerRadius: WX.rowCorner).fill(WX.inputField))
                .overlay(RoundedRectangle(cornerRadius: WX.rowCorner).stroke(WX.separator, lineWidth: 0.5))
                .submitLabel(.send)
                .onSubmit { vm.send() }
                .overlay(alignment: .bottomLeading) {
                    if let img = vm.pendingImage {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .topTrailing) {
                                Button { vm.pendingImage = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .shadow(radius: 2)
                                }
                            }
                            .offset(x: 8, y: -28)
                    }
                }
            VStack(spacing: 6) {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.chevron.down")
                        .font(.system(size: 15))
                        .foregroundColor(WX.titleBlack)
                        .frame(width: 34, height: 32)
                        .background(RoundedRectangle(cornerRadius: WX.rowCorner).fill(WX.inputField))
                        .overlay(RoundedRectangle(cornerRadius: WX.rowCorner).stroke(WX.separator, lineWidth: 0.5))
                }
                .buttonStyle(.borderless)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 15))
                        .foregroundColor(WX.titleBlack)
                        .frame(width: 34, height: 32)
                        .background(RoundedRectangle(cornerRadius: WX.rowCorner).fill(WX.inputField))
                        .overlay(RoundedRectangle(cornerRadius: WX.rowCorner).stroke(WX.separator, lineWidth: 0.5))
                }
                .buttonStyle(.borderless)
                .onChange(of: photoItem) { item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            vm.pendingImage = img
                        }
                    }
                    photoItem = nil
                }
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
                .background(RoundedRectangle(cornerRadius: WX.rowCorner).fill(on ? WX.green : WX.inputField))
                .overlay(RoundedRectangle(cornerRadius: WX.rowCorner).stroke(WX.separator, lineWidth: 0.5))
        }
        .buttonStyle(.borderless)
    }
}

/// 微信气泡：我的 #95EC69 右对齐带尾巴，对方白色左对齐
struct Bubble: View {
    let m: ChatMessage
    @State private var showThink = false
    @State private var expanded = false

    private var isLong: Bool { m.content.count > 500 }

    private var displayText: String {
        if isLong && !expanded {
            return String(m.content.prefix(500)) + "…"
        }
        return m.content
    }

    var body: some View {
        HStack(alignment: .top) {
            if m.role == "user" { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 6) {
                if let d = m.image, let img = UIImage(data: d) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 180, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: WX.rowCorner))
                        .overlay(RoundedRectangle(cornerRadius: WX.rowCorner).stroke(WX.separator, lineWidth: 0.5))
                }
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
                            .foregroundColor(WX.onInk)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        Text("")
                            .frame(width: 6, height: 6)
                            .background(Color.white.opacity(0.0001))
                    }
                    // 墨气泡：松烟墨底、宣纸字、直角 2pt 小圆角、无尾
                    .background(WX.bubbleMine)
                    .clipShape(RoundedRectangle(cornerRadius: WX.rowCorner))
                } else if m.failed {
                    Text(m.content)
                        .font(.callout)
                        .foregroundColor(WX.green)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: WX.rowCorner).fill(WX.faintInk))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        MarkdownText(text: displayText.isEmpty ? "…" : displayText)
                            .padding(4)
                        if isLong {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10))
                                    Text(expanded ? "收起" : "展开全文（\(m.content.count) 字）")
                                        .font(.caption)
                                }
                                .foregroundColor(WX.secondary)
                                .padding(.top, 2)
                            }
                            .buttonStyle(.borderless)
                            .padding(.leading, 4)
                        }
                    }
                }
            }
            if m.role != "user" { Spacer(minLength: 52) }
        }

    }
}

// MARK: - 消息朗读控制器（AVSpeech 中文女声）
final class TTSController: NSObject {
    static let shared = TTSController()
    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking = false

    @objc func notifyDidStop(_ n: Notification) { isSpeaking = false }
    @objc func notifyDidCancel(_ n: Notification) { isSpeaking = false }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(notifyDidStop),
            name: AVSpeechSynthesizer.didFinishSpeakingNotification, object: synth)
        NotificationCenter.default.addObserver(self, selector: #selector(notifyDidCancel),
            name: AVSpeechSynthesizer.didCancelUtteranceNotification, object: synth)
    }

    func speak(_ text: String) {
        if text.isEmpty { return }
        if isSpeaking { synth.stopSpeaking(at: .immediate); isSpeaking = false }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN") ?? AVSpeechSynthesisVoice(language: "zh")
        u.rate = 0.5
        u.pitchMultiplier = 1.0
        u.volume = 1.0
        isSpeaking = true
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}
