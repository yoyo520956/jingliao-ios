import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var server: LocalAPIServer
    @EnvironmentObject var logs: EngineLog
    @EnvironmentObject var chats: ChatStore
    @AppStorage("jl.port") private var port = "22217"
    @AppStorage("jl.apikeys") private var apiKeys = ""
    @State private var hifOn = DSHif.shared.enabled
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本地 API 网关")
                                .font(.body)
                            Text(server.running
                                 ? "运行中 · http://127.0.0.1:\(server.port)/v1"
                                 : "已停止")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { server.running },
                            set: { on in on ? server.start() : server.stop() }
                        ))
                        .labelsHidden()
                    }
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("22217", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("API Key（逗号分隔，留空不校验）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("sk-xxx,sk-yyy", text: $apiKeys)
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("本地网关（给 Minis 等 OpenAI 兼容客户端用）")
                } footer: {
                    Text("在 Minis 里添加自定义模型：Base URL 填 http://127.0.0.1:\(port)/v1，Key 填上面任意一个（若已设置）。模型选 deepseek-chat。")
                }

                Section {
                    Toggle("补齐 x-hif-leim 风控令牌（推荐开）", isOn: $hifOn)
                        .onChange(of: hifOn) { v in DSHif.shared.enabled = v }
                    Button("清除 wasm 缓存") {
                        if let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            try? FileManager.default.removeItem(at: doc.appendingPathComponent("sha3_wasm.bin"))
                        }
                        EngineLog.shared.add("wasm 缓存已清除，下次对话重新下载")
                    }
                } header: {
                    Text("引擎")
                } footer: {
                    Text("PoW 求解用隐藏 WebView 运行官方 sha3 wasm（自动下载并缓存），算法永远与官方网页同步。")
                }

                Section {
                    if logs.lines.isEmpty {
                        Text("暂无日志").font(.caption).foregroundColor(.secondary)
                    } else {
                        ForEach(logs.lines.suffix(60), id: \.self) { l in
                            Text(l).font(.system(size: 11, design: .monospaced))
                        }
                    }
                } header: {
                    HStack {
                        Text("引擎日志")
                        Spacer()
                        Button(copied ? "已复制" : "复制") {
                            UIPasteboard.general.string = logs.lines.joined(separator: "\n")
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }

                Section {
                    Button("清空全部会话", role: .destructive) { chats.clearAll() }
                } header: {
                    Text("数据")
                }

                Section {
                    LabeledContent("版本", value: Self.version)
                    LabeledContent("协议基线", value: "ds-free-api v0.5.1 对齐")
                } header: {
                    Text("关于鲸聊")
                }
            }
            .navigationTitle("设置")
        }
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
