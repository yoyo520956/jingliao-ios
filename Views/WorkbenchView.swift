import SwiftUI
import WebKit

// MARK: - 瑶台开发台（终端 / 文件 / 网页预览 / AI 助手）

struct WorkbenchView: View {
    @StateObject private var agent = AgentRunner.shared
    @State private var tab = 0

    private let subtabs: [(Int, String, String, String)] = [
        (0, "终端", "ic_node", "run_command"),
        (1, "AI 助手", "ic_robot", "agent_loop"),
        (2, "文件", "ic_folder", "workbench_fs"),
        (3, "网页", "ic_globe", "web_preview"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 微信风格分段选择器：圆角白条 + 绿字选中
                HStack(spacing: 4) {
                    ForEach(subtabs, id: \.0) { t in
                        let on = tab == t.0
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { tab = t.0 }
                        } label: {
                            HStack(spacing: 5) {
                                Image(uiImage: uiIcon(t.2))
                                    .renderingMode(.template)
                                Text(t.1)
                                    .font(.system(size: 14, weight: on ? .semibold : .regular))
                            }
                            .foregroundColor(on ? WX.green : WX.titleBlack)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? WX.green.opacity(0.12) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 9).fill(WX.inputField).shadow(color: .black.opacity(0.04), radius: 2, y: 1))
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Group {
                    switch tab {
                    case 0: TerminalView()
                    case 1: AgentChatView()
                    case 2: FileBrowserView()
                    default: WebPreviewView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(WX.listBG)
            .navigationTitle("瑶台 · 开发环境")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func uiIcon(_ name: String) -> UIImage {
        return UIImage(named: name)?.withRenderingMode(.alwaysTemplate) ?? UIImage()
    }
}

// MARK: - 终端

struct TerminalView: View {
    @StateObject private var vm = TerminalVM()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(vm.lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 12, design: .monospaced))
                                .foregroundColor(l.hasPrefix("shell:") ? .red : (l.hasPrefix(vm.prompt) ? .green : .primary))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(vm.lines.count - 1)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: vm.lines.count) { _ in
                    proxy.scrollTo(vm.lines.count - 1, anchor: .bottom)
                }
            }
            HStack(spacing: 8) {
                Text(vm.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green)
                TextField("输入命令（help 看全部）", text: $vm.input)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { vm.submit() }
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.chevron.down")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
        }
        .onAppear { focused = true }
    }
}

final class TerminalVM: ObservableObject {
    @Published var lines: [String] = []
    @Published var input = ""
    @Published var prompt = "~/ $"

    private let shell = ShellEngine.shared
    private let fs = WorkbenchFS.shared
    private var cwd: URL
    private var histIdx = -1
    private var hist: [String] = []

    init() {
        cwd = fs.home
        lines = ["瑶台 Shell 1.0 · 内置 JS 引擎（node）/ git / curl", "输入 help 查看命令，open x.html 预览网页", ""]
    }

    func submit() {
        let cmd = input.trimmingCharacters(in: .whitespaces)
        input = ""
        guard !cmd.isEmpty else { return }
        lines.append(prompt + " " + cmd)
        hist.append(cmd)
        histIdx = hist.count
        if cmd == "clear" { lines = [""]; return }
        let r = shell.run(cmd, cwd: cwd)
        if !r.output.isEmpty { lines.append(contentsOf: r.output.components(separatedBy: "\n")) }
        if let nc = r.newCwd { cwd = nc }
        prompt = fs.display(cwd) + " $"
    }
}

// MARK: - 文件浏览器 + 编辑器

struct FileBrowserView: View {
    @StateObject private var vm = FileVM()

    var body: some View {
        List {
            Section("目录：\(vm.path)") {
                ForEach(vm.items) { it in
                    HStack(spacing: 10) {
                        WXRowIcon(name: it.isDir ? "ic_folder" : (it.name.hasSuffix(".html") ? "ic_globe" : (it.name.hasSuffix(".js") ? "ic_code" : "ic_file")))
                        Text(it.name)
                            .font(.system(size: 17))
                            .foregroundColor(WX.titleBlack)
                        Spacer()
                        if !it.isDir {
                            Text("\(it.size)B").font(.system(size: 12)).foregroundColor(WX.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if it.isDir {
                            vm.enter(it.name)
                        } else {
                            vm.openFile(it.name)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .background(WX.listBG)
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !vm.atRoot { Button("返回") { vm.up() } }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { vm.newFile() } label: {
                    Image(uiImage: uiIcon("ic_plus_small")).renderingMode(.template)
                        .foregroundColor(WX.titleBlack)
                }
            }
        }
        .sheet(item: $vm.editing) { f in
            let bind = Binding(get: { f.text }, set: { f.text = $0 })
            NavigationStack {
                TextEditor(text: bind)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .navigationTitle(f.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("保存") { vm.save(f) }.foregroundColor(WX.green)
                        }
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("完成") { vm.editing = nil }
                        }
                    }
            }
        }
    }

    private func uiIcon(_ name: String) -> UIImage {
        return UIImage(named: name)?.withRenderingMode(.alwaysTemplate) ?? UIImage()
    }
}

final class FileVM: ObservableObject {
    struct Item: Identifiable, Hashable {
        let id = UUID().uuidString
        let name: String
        let isDir: Bool
        let size: Int64
    }
    final class EditingFile: Identifiable {
        let id = UUID().uuidString
        var name: String
        let url: URL
        var text: String
        init(name: String, url: URL, text: String) {
            self.name = name; self.url = url; self.text = text
        }
    }

    @Published var items: [Item] = []
    @Published var path = "~"
    @Published var editing: EditingFile?

    private let fs = WorkbenchFS.shared
    private var cwd: URL

    init() {
        cwd = fs.home
        reload()
    }

    var atRoot: Bool { cwd.path == fs.root.path }

    func reload() {
        items = fs.list(cwd).map { Item(name: $0.name, isDir: $0.isDir, size: $0.size) }
        path = fs.display(cwd)
    }

    func enter(_ name: String) {
        guard let u = fs.resolve(name, cwd: cwd) else { return }
        cwd = u
        reload()
    }

    func up() {
        cwd = cwd.deletingLastPathComponent()
        if cwd.path.count < fs.root.path.count { cwd = fs.root }
        reload()
    }

    func openFile(_ name: String) {
        guard let u = fs.resolve(name, cwd: cwd) else { return }
        if name.hasSuffix(".html") {
            NotificationCenter.default.post(name: .yaotaiOpenFile, object: u.path)
            return
        }
        let text = fs.read(u) ?? ""
        editing = EditingFile(name: name, url: u, text: text)
    }

    func newFile() {
        let name = "untitled-\(Int(Date().timeIntervalSince1970) % 10000).txt"
        guard let u = fs.resolve(name, cwd: cwd) else { return }
        try? fs.write(u, "")
        editing = EditingFile(name: name, url: u, text: "")
    }

    func save(_ f: EditingFile) {
        try? fs.write(f.url, f.text)
        reload()
    }
}

// MARK: - 网页预览（WKWebView 加载沙盒 HTML）

struct WebPreviewView: View {
    @StateObject private var vm = WebPreviewVM()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(vm.htmlFiles, id: \.self) { f in
                        Button(f) { vm.open(f) }
                    }
                    if vm.htmlFiles.isEmpty {
                        Text("（~/ 下还没有 .html 文件）")
                    }
                } label: {
                    Label(vm.current.isEmpty ? "选择网页" : vm.current, systemImage: "doc.text")
                        .font(.caption)
                }
                Spacer()
                Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            WebViewRep(url: vm.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
        }
        .onReceive(NotificationCenter.default.publisher(for: .yaotaiOpenFile)) { n in
            if let p = n.object as? String { vm.openPath(p) }
        }
        .onAppear { vm.scan() }
    }
}

final class WebPreviewVM: ObservableObject {
    @Published var htmlFiles: [String] = []
    @Published var current = ""
    @Published var url: URL?

    private let fs = WorkbenchFS.shared

    func scan() {
        func walk(_ u: URL) -> [String] {
            var r: [String] = []
            for it in fs.list(u) {
                let c = u.appendingPathComponent(it.name)
                if it.isDir { r.append(contentsOf: walk(c)) }
                else if it.name.hasSuffix(".html") { r.append(fs.display(c)) }
            }
            return r
        }
        htmlFiles = walk(fs.home).sorted()
    }

    func open(_ rel: String) {
        guard let u = fs.resolve(rel, cwd: fs.home) else { return }
        openPath(u.path)
    }

    func openPath(_ path: String) {
        let u = URL(fileURLWithPath: path)
        url = u
        current = (path as NSString).lastPathComponent
    }

    func reload() {
        let cur = url
        url = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.url = cur }
    }
}

struct WebViewRep: UIViewRepresentable {
    let url: URL?
    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url else { return }
        uiView.loadFileURL(url, allowingReadAccessTo: WorkbenchFS.shared.root)
    }
}

// MARK: - AI 助手

/// 未就绪空态（独立子视图：避免巨表达式拖垮编译器类型检查）
struct AgentEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclam").font(.largeTitle)
            Text("AI 助手还没就绪").font(.headline)
            Text("两种通道任一即可：① 设置页登录 DeepSeek 网页版账号（免费，走网页协议工具降级模式）② 填官方 API Key（原生工具调用）。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单条消息（气泡 + 工具结果卡 + 运行中指示）
struct AgentRow: View {
    let m: Msg
    let showProgress: Bool
    let status: String
    var body: some View {
        HStack(alignment: .top) {
            if m.role == "user" { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if m.role == "user" {
                    Text(m.text)
                        .font(.system(size: 17))
                        .foregroundColor(WX.titleBlack)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(WX.bubbleMine)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if m.role == "tool" {
                    Text("🔧 \(m.text.prefix(600))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(WX.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WX.inputField))
                } else {
                    Text(m.text.isEmpty ? (m.running ? "思考中…" : "") : m.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                if showProgress, m.running {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(status.isEmpty ? "AI 运行中…" : status)
                            .font(.system(size: 11))
                            .foregroundColor(WX.secondary)
                    }
                }
            }
            if m.role != "user" { Spacer(minLength: 48) }
        }
    }
}

struct AgentChatView: View {
    @StateObject private var agent = AgentRunner.shared
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !agent.ready {
                AgentEmptyState()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(agent.messages) { m in
                                AgentRow(m: m, showProgress: agent.busy && m.running, status: agent.status)
                                    .id(m.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: agent.messages.count) { _ in
                        if let last = agent.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                HStack(spacing: 8) {
                    TextField("让 AI 帮你操作瑶台…", text: $input)
                        .font(.system(size: 17))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(WX.inputField))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WX.separator, lineWidth: 0.5))
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit { send() }
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Image(systemName: "keyboard.chevron.chevron.down")
                            .foregroundColor(WX.titleBlack)
                    }
                    .buttonStyle(.borderless)
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                            .foregroundColor(input.isEmpty ? WX.secondary : WX.green)
                    }
                    .disabled(agent.busy || input.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(WX.inputBar)
                .overlay(alignment: .top) { Rectangle().fill(WX.separator).frame(height: 0.5) }
            }
        }
        .onAppear { focused = true }
    }

    private func send() {
        let t = input
        input = ""
        agent.ask(t)
    }
}
