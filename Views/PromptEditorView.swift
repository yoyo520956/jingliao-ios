import SwiftUI

/// 底层提示词编辑器：所有系统级提示词都在这里改
struct PromptEditorView: View {
    @State private var agent = PromptStore.shared.agentSystem
    @State private var chat = PromptStore.shared.chatPrefix
    @State private var gateway = PromptStore.shared.gatewayDefault
    @State private var toolsNote = PromptStore.shared.toolsNote
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(align: .leading, spacing: 6) {
                    TextEditor(text: $agent)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 180)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    Button("恢复默认") { agent = PromptStore.defaultAgent }
                        .font(.caption)
                }
            } header: {
                Text("AI 助手系统提示词（瑶台）")
            } footer: {
                Text("决定瑶台 AI 助手的人设与行为方式。")
            }

            Section {
                TextEditor(text: $toolsNote)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            } header: {
                Text("工具说明附加段（高级）")
            } footer: {
                Text("追加在 AI 助手系统提示词后面的额外指令。")
            }

            Section {
                TextEditor(text: $chat)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            } header: {
                Text("鲸聊聊天前缀")
            } footer: {
                Text("在鲸聊「聊天」页发消息时自动拼在每条消息最前面（人设/风格控制），留空不加。")
            }

            Section {
                TextEditor(text: $gateway)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            } header: {
                Text("网关默认系统提示词")
            } footer: {
                Text("第三方 App（如 Minis）的请求里没带 system 消息时，网关用它顶上。留空则不加。")
            }
        }
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
                    .background(Capsule().fill(Color.green.opacity(0.9)))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
            }
        }
    }
}
