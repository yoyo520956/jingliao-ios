import SwiftUI

/// 底层提示词编辑器——微信 8.0.79 风格：灰底圆角白卡 + 胶囊按钮
struct PromptEditorView: View {
    @State private var agent = PromptStore.shared.agentSystem
    @State private var chat = PromptStore.shared.chatPrefix
    @State private var gateway = PromptStore.shared.gatewayDefault
    @State private var toolsNote = PromptStore.shared.toolsNote
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                editorCard(
                    title: "AI 助手系统提示词（瑶台）",
                    footer: "决定瑶台 AI 助手的人设与行为方式。",
                    text: $agent,
                    showDefault: true
                )
                editorCard(
                    title: "工具说明附加段（高级）",
                    footer: "追加在 AI 助手系统提示词后面的额外指令。",
                    text: $toolsNote,
                    showDefault: false
                )
                editorCard(
                    title: "鲸聊聊天前缀",
                    footer: "在鲸聊「聊天」页发消息时自动拼在每条消息最前面（人设/风格控制），留空不加。",
                    text: $chat,
                    showDefault: false
                )
                editorCard(
                    title: "网关默认系统提示词",
                    footer: "第三方 App（如 Minis）的请求里没带 system 消息时，网关用它顶上。留空则不加。",
                    text: $gateway,
                    showDefault: false
                )
                .padding(.bottom, 24)
            }
        }
        .background(WX.listBG)
        .scrollContentBackground(.hidden)
        .navigationTitle("底层提示词")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    PromptStore.shared.agentSystem = agent
                    PromptStore.shared.toolsNote = toolsNote
                    PromptStore.shared.chatPrefix = chat
                    PromptStore.shared.gatewayDefault = gateway
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
                }
                .foregroundColor(WX.green)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button("完成") { dismiss() }
            }
        }
        .overlay(alignment: .bottom) {
            if saved {
                Text("已保存 ✓")
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(WX.green))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
            }
        }
    }

    private func editorCard(title: String, footer: String, text: Binding<String>, showDefault: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(WX.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WX.separator, lineWidth: 0.5))
            if showDefault {
                Button("恢复默认") { text.wrappedValue = PromptStore.defaultAgent }
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(WX.green))
            }
            Text(footer)
                .font(.system(size: 12))
                .foregroundColor(WX.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(WX.cellBG)
        .cornerRadius(WX.rowCorner)
        .padding(.horizontal, 15)
        .padding(.top, 10)
    }
}
