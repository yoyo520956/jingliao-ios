import SwiftUI

/// 设置页——微信 8.0.79 风格：灰底圆角白卡 + 行首绿底图标 + 胶囊按钮 + 绿开关
struct SettingsView: View {
    @EnvironmentObject var server: LocalAPIServer
    @EnvironmentObject var logs: EngineLog
    @EnvironmentObject var chats: ChatStore
    @AppStorage("jl.port") private var port = "22217"
    @AppStorage("jl.apikeys") private var apiKeys = ""
    @State private var hifOn = DSHif.shared.enabled
    @State private var copied = false
    @AppStorage("jl.officialkey") private var officialKey = ""
    @AppStorage("jl.ghpat") private var ghPat = ""
    @State private var ghUser = ""
    @State private var ghError: String?
    @State private var ghChecking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    groupHeader("本地网关（OpenAI / ChatGPT 官方格式）")
                    WXGroup {
                        WX.rowContent {
                            WXRowIcon(name: "ic_gateway")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("本地 API 网关").font(.system(size: 17)).foregroundColor(WX.titleBlack)
                                Text(server.running
                                     ? "运行中 · http://127.0.0.1:\(server.port)/v1"
                                     : "已停止")
                                    .font(.system(size: 12))
                                    .foregroundColor(WX.secondary)
                            }
                            Spacer(minLength: 6)
                            Toggle("", isOn: Binding(
                                get: { server.running },
                                set: { on in on ? server.start() : server.stop() }
                            ))
                            .labelsHidden()
                            .tint(WX.green)
                        }
                        WX.rowContent {
                            WXRowIcon(name: "ic_server_stack")
                            Text("端口").font(.system(size: 17)).foregroundColor(WX.titleBlack)
                            Spacer(minLength: 6)
                            TextField("22217", text: $port)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                                .font(.system(size: 15))
                        }
                        if server.running {
                            addrRow(title: "本机地址", value: "http://127.0.0.1:\(server.port)/v1")
                            if let lan = LocalAPIServer.lanIPv4 {
                                addrRow(title: "局域网地址", value: "http://\(lan):\(server.port)/v1")
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("API Key（逗号分隔，留空不校验）")
                                .font(.system(size: 12))
                                .foregroundColor(WX.secondary)
                            TextField("sk-xxx,sk-yyy", text: $apiKeys)
                                .font(.system(size: 13))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        if copied {
                            Text("已复制 ✓（模型选 deepseek-chat）")
                                .font(.system(size: 12))
                                .foregroundColor(WX.green)
                                .padding(.horizontal, 15)
                                .padding(.bottom, 8)
                        }
                    }
                    groupFooter("在 Minis 等 OpenAI 兼容客户端里添加自定义模型：Base URL 填上面的地址（本机其他 App 用 127.0.0.1；同一 Wi-Fi 下的其他设备用局域网地址），Key 填上面任意一个（若已设置）。模型选 deepseek-chat。支持流式。")

                    groupHeader("官方直通（填 Key 后工具调用 / 深度思考 / 真实用量全开）")
                    WXGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(officialKey.isEmpty
                                 ? "未填写 → 走免费网页协议（纯聊天，无工具）"
                                 : "已填写 → 官方直通：工具调用 / 深度思考 / 真实 token 用量全部可用")
                                .font(.system(size: 12))
                                .foregroundColor(officialKey.isEmpty ? WX.secondary : WX.green)
                            TextField("sk-…（留空则关闭直通）", text: $officialKey)
                                .font(.system(size: 13))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Link("没有 Key？点这里去 platform.deepseek.com 申请 →",
                                 destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                                .font(.system(size: 12))
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                    }
                    groupFooter("免费网页协议的报文字段没有 tools——工具调用是协议天花板，不是网关缺陷。填官方 Key 后网关把请求原样转发给官方 API。Key 只存本机。")

                    groupHeader("诊断")
                    WXGroup {
                        Button {
                            LocalAPIServer.shared.runSelfTest()
                        } label: {
                            WX.rowContent {
                                WXRowIcon(name: "ic_stethoscope")
                                Text("网关自检（跑三种请求形态）")
                                    .font(.system(size: 17))
                                    .foregroundColor(WX.titleBlack)
                                Spacer(minLength: 6)
                                if !server.running {
                                    Text("网关未运行").font(.system(size: 12)).foregroundColor(WX.secondary)
                                }
                            }
                        }
                        .disabled(!server.running)
                        .buttonStyle(.plain)
                    }
                    groupFooter("点一下，鲸聊通过自己的网关往本机回路发三种请求：① 短消息非流式 ② 长人设非流式 ③ 长人设流式（=Minis 真实聊天）。结果写进下方日志。")

                    groupHeader("画中画监控")
                    WXGroup {
                        WX.rowContent {
                            WXRowIcon(name: "ic_pip")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("画中画实时监控").font(.system(size: 17)).foregroundColor(WX.titleBlack)
                                Text(PiPManager.shared.pipRunning
                                     ? "悬浮窗运行中 · 每秒刷新"
                                     : PiPManager.shared.isActive ? "已开启 · 切后台自动进入" : "已关闭")
                                    .font(.system(size: 12))
                                    .foregroundColor(WX.secondary)
                            }
                            Spacer(minLength: 6)
                            Toggle("", isOn: Binding(
                                get: { PiPManager.shared.isActive },
                                set: { on in on ? PiPManager.shared.start() : PiPManager.shared.stop() }
                            ))
                            .labelsHidden()
                            .tint(WX.green)
                        }
                    }
                    groupFooter("开启后显示实时上下文、本轮输出与字/秒、服务端累计 token 消耗，每秒刷新；可最小化到主屏幕或其他 App 上悬浮查看。")

                    groupHeader("瑶台开发环境")
                    WXGroup {
                        NavigationLink {
                            PromptEditorView()
                        } label: {
                            WX.rowContent {
                                WXRowIcon(name: "ic_prompt")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("底层提示词").font(.system(size: 17)).foregroundColor(WX.titleBlack)
                                    Text("AI 助手 / 聊天前缀 / 网关默认系统 / 工具说明，全部可改")
                                        .font(.system(size: 12))
                                        .foregroundColor(WX.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GitHub PAT（克隆私有仓库用；公开仓库可不填）")
                                .font(.system(size: 12))
                                .foregroundColor(WX.secondary)
                            TextField("github_pat_… / ghp_…", text: $ghPat)
                                .font(.system(size: 13))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        WX.rowContent {
                            WXRowIcon(name: "ic_git")
                            Text(ghUser.isEmpty ? "PAT 状态未检测" : "已登录：\(ghUser)")
                                .font(.system(size: 15))
                                .foregroundColor(WX.titleBlack)
                            Spacer(minLength: 6)
                            Button(ghChecking ? "检测中…" : "检测") {
                                ghChecking = true
                                Task {
                                    let r = await GitHubClient.shared.checkLogin()
                                    await MainActor.run {
                                        ghUser = r.login ?? ""
                                        ghError = r.error ?? ""
                                        ghChecking = false
                                    }
                                }
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(WX.green))
                            .disabled(ghChecking || ghPat.isEmpty)
                        }
                        if let ghError, !ghError.isEmpty {
                            Text(ghError).font(.system(size: 12)).foregroundColor(WX.badgeRed)
                                .padding(.horizontal, 15)
                                .padding(.bottom, 8)
                        }
                        Link("没有 PAT？github.com/settings/tokens 生成（勾 repo 权限）→",
                             destination: URL(string: "https://github.com/settings/tokens")!)
                            .font(.system(size: 12))
                            .padding(.horizontal, 15)
                            .padding(.bottom, 12)
                    }
                    groupFooter("瑶台 = 内置 Linux 风格终端 + 沙盒文件系统 + JS 引擎（node）+ git/curl + GitHub + 网页预览，AI 助手可通过工具直接操作这一切。")

                    groupHeader("引擎")
                    WXGroup {
                        WX.rowContent {
                            WXRowIcon(name: "ic_chip")
                            Text("补齐 x-hif-leim 风控令牌（推荐开）")
                                .font(.system(size: 17))
                                .foregroundColor(WX.titleBlack)
                            Spacer(minLength: 6)
                            Toggle("", isOn: Binding(
                                get: { hifOn },
                                set: { v in hifOn = v; DSHif.shared.enabled = v }
                            ))
                            .labelsHidden()
                            .tint(WX.green)
                        }
                        Button {
                            if let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                                try? FileManager.default.removeItem(at: doc.appendingPathComponent("sha3_wasm.bin"))
                            }
                            EngineLog.shared.add("wasm 缓存已清除，下次对话重新下载")
                        } label: {
                            WX.rowContent {
                                WXRowIcon(name: "ic_trash")
                                Text("清除 wasm 缓存")
                                    .font(.system(size: 17))
                                    .foregroundColor(WX.titleBlack)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    groupFooter("PoW 求解用隐藏 WebView 运行官方 sha3 wasm（自动下载并缓存），算法永远与官方网页同步。")

                    groupHeader("引擎日志")
                    WXGroup {
                        HStack {
                            Text("日志（最近 60 行）")
                                .font(.system(size: 15))
                                .foregroundColor(WX.titleBlack)
                            Spacer()
                            Button(copied ? "已复制" : "复制") {
                                UIPasteboard.general.string = logs.lines.joined(separator: "\n")
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            }
                            .font(.system(size: 14))
                            .foregroundColor(WX.green)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        if logs.lines.isEmpty {
                            Text("暂无日志")
                                .font(.system(size: 12))
                                .foregroundColor(WX.secondary)
                                .padding(.horizontal, 15)
                                .padding(.bottom, 10)
                        } else {
                            ForEach(logs.lines.suffix(60), id: \.self) { l in
                                Text(l)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                            }
                        }
                    }

                    groupHeader("数据")
                    WXGroup {
                        Button("清空全部会话") { chats.clearAll() }
                            .font(.system(size: 17))
                            .foregroundColor(WX.badgeRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 14)
                    }

                    WXGroup {
                        WX.rowContent {
                            WXRowIcon(name: "ic_info")
                            Text("版本").font(.system(size: 17)).foregroundColor(WX.titleBlack)
                            Spacer(minLength: 6)
                            Text(Self.version).font(.system(size: 15)).foregroundColor(WX.secondary)
                        }
                        WX.rowContent {
                            WXRowIcon(name: "ic_chip")
                            Text("协议基线").font(.system(size: 17)).foregroundColor(WX.titleBlack)
                            Spacer(minLength: 6)
                            Text("ds-free-api v0.5.1 对齐").font(.system(size: 15)).foregroundColor(WX.secondary)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .background(WX.listBG)
            .scrollContentBackground(.hidden)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 小组件

    private func groupHeader(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 13))
            .foregroundColor(WX.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func groupFooter(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12))
            .foregroundColor(WX.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 4)
    }

    private func addrRow(title: String, value: String) -> some View {
        WX.rowContent {
            WXRowIcon(name: "ic_lan")
            Text(title).font(.system(size: 17)).foregroundColor(WX.titleBlack)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(WX.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = value
            copied = true
        }
    }

    private func showChevronFalse() -> some View {
        EmptyView()
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
