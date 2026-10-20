import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var server: LocalAPIServer
    @EnvironmentObject var logs: EngineLog
    @EnvironmentObject var chats: ChatStore
    @AppStorage("jl.port") private var port = "22217"
    @AppStorage("jl.apikeys") private var apiKeys = ""
    @State private var hifOn = DSHif.shared.enabled
    @State private var copied = false
    @AppStorage("jl.officialkey") private var officialKey = ""

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
                    if server.running {
                        // 本机其他 App（走回环）+ 同 Wi-Fi 设备（走局域网 IP）都可调
                        HStack {
                            Text("本机地址")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("http://127.0.0.1:\(server.port)/v1")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = "http://127.0.0.1:\(server.port)/v1"
                            copied = true
                        }
                        if let lan = LocalAPIServer.lanIPv4 {
                            HStack {
                                Text("局域网地址")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("http://\(lan):\(server.port)/v1")
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIPasteboard.general.string = "http://\(lan):\(server.port)/v1"
                                copied = true
                            }
                        }
                        if copied {
                            Text("已复制 ✓（Base URL 填这个，模型 deepseek-chat）")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
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
                    Text("本地网关（OpenAI / ChatGPT 官方格式）")
                } footer: {
                    Text("在 Minis 等 OpenAI 兼容客户端里添加自定义模型：Base URL 填上面的地址（本机其他 App 用 127.0.0.1；同一 Wi-Fi 下的其他设备用局域网地址），Key 填上面任意一个（若已设置）。模型选 deepseek-chat。支持流式。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("官方 API Key（可选）")
                            .font(.body)
                        Text(officialKey.isEmpty
                             ? "未填写 → 走免费网页协议（纯聊天，无工具）"
                             : "已填写 → 官方直通：工具调用 / 深度思考 / 真实 token 用量全部可用")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DeepSeek 开放平台 Key（platform.deepseek.com 申请）；填写后第三方 App 的请求全部转发到 api.deepseek.com，原样支持 tools")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TextField("sk-…（留空则关闭直通）", text: $officialKey)
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Link("没有 Key？点这里去 platform.deepseek.com 申请 →", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                            .font(.caption2)
                    }
                } header: {
                    Text("官方直通（想让 Minis 里的倾瑶能调工具就填它）")
                } footer: {
                    Text("免费网页协议的 completion 报文里根本没有 tools 字段——工具调用是它的天花板，不是网关的缺陷。填了官方 Key，网关就把第三方 App 的请求原样转发给官方 API：工具、思考、真实消耗全都有。Key 只存本机。")
                }

                Section {
                    Button {
                        LocalAPIServer.shared.runSelfTest()
                    } label: {
                        HStack {
                            Image(systemName: "stethoscope")
                            Text("网关自检（跑三种请求形态）")
                        }
                    }
                    .disabled(!server.running)
                } header: {
                    Text("诊断（排“快速测试通、真实对话空”）")
                } footer: {
                    Text("点一下，鲸聊会通过自己的网关往本机回路发三种请求：① 短消息非流式（=快速测试）② 长人设非流式 ③ 长人设流式（=Minis 真实聊天）。三条结果写进下方日志，直接照见是哪一层断。")
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("画中画实时监控")
                                .font(.body)
                            Text(PiPManager.shared.pipRunning
                                 ? "悬浮窗运行中 · 每秒刷新"
                                 : PiPManager.shared.isActive ? "已开启 · 切后台自动进入" : "已关闭")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { PiPManager.shared.isActive },
                            set: { on in on ? PiPManager.shared.start() : PiPManager.shared.stop() }
                        ))
                        .labelsHidden()
                    }
                } header: {
                    Text("画中画监控（其他 App / 主屏幕可看）")
                } footer: {
                    Text("开启后显示实时上下文、本轮输出与字/秒、服务端累计 token 消耗，每秒刷新；可最小化到主屏幕或其他 App 上悬浮查看，点悬浮窗左上角「还原」回到本 App。")
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
