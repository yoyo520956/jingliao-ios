import Foundation
import JavaScriptCore

/// 瑶台 Shell：Linux 风格命令解释器（同步执行）
/// `node x.js` 走系统自带 JavaScriptCore，真实执行 JS
final class ShellEngine {
    static let shared = ShellEngine()

    struct Result {
        var output: String
        var exitCode: Int
        var newCwd: URL?
        var clear: Bool = false
    }

    private let fs = WorkbenchFS.shared
    private var history: [String] = []

    func runHistoryAdd(_ c: String) { history.append(c) }

    func run(_ line: String, cwd: URL) -> Result {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return Result(output: "", exitCode: 0, newCwd: nil) }
        // 支持 | 简易管道（只支持 cat x | grep y 这类单级）
        if t.contains("|") {
            let segs = t.split(separator: "|", map: { $0.trimmingCharacters(in: .whitespaces) })
            var pipeIn = ""
            var last = Result(output: "", exitCode: 0, newCwd: nil)
            for (i, s) in segs.enumerated() {
                var r = exec(s, cwd: cwd, stdin: pipeIn, isPipe: i > 0)
                pipeIn = r.output
                last = r
                if r.exitCode != 0 { break }
            }
            return last
        }
        return exec(t, cwd: cwd, stdin: nil, isPipe: false)
    }

    private func exec(_ raw: String, cwd: URL, stdin: String?, isPipe: Bool) -> Result {
        let argv = tokenize(raw)
        guard let cmd = argv.first else { return Result(output: "", exitCode: 0, newCwd: nil) }
        let args = Array(argv.dropFirst())

        func out(_ s: String, code: Int = 0, newCwd: URL? = nil) -> Result {
            Result(output: s, exitCode: code, newCwd: newCwd)
        }
        func err(_ s: String) -> Result { Result(output: "shell: \(s)", exitCode: 1, newCwd: nil) }

        switch cmd {
        case "help", "?":
            return out("""
            瑶台 Shell 内置命令：
            ls [-l] [路径]      列出文件        cd <路径>        切换目录
            pwd                当前目录        cat <文件...>    看内容
            echo <文本>        输出文本        head/tail [-n N] 头/尾 N 行
            wc [-l] <文件>     统计行数        grep <词> [文件] 搜索
            find [路径]        递归列出        tree             树形展示
            mkdir [-p] <目录>  创建            rm [-rf] <路径>  删除
            cp/mv <源> <目标>  复制/移动       touch <文件>     新建
            sed 's/旧/新/' <文件>  替换改写    sort/uniq <文件> 排序/去重
            date               当前时间        whoami/uname     身份/内核
            env / export K=V   环境变量        history          命令历史
            node <js文件>      用内置 JS 引擎执行（console.log 可用）
            git clone <url>    下载 GitHub 仓库到当前目录
            curl <url> [-o 文件]  下载
            open <html文件>    在预览页打开     edit <文件>      在编辑器打开
            clear              清屏
            """)

        case "pwd":
            return out(fs.display(cwd))

        case "cd":
            guard let a = args.first else { return out("", newCwd: fs.home) }
            if a == "~" { return out("", newCwd: fs.home) }
            guard let target = fs.resolve(a, cwd: cwd) else { return err("cd: 路径越界或无效: \(a)") }
            guard fs.isDir(target) else { return err("cd: 不是目录: \(a)") }
            return out("", newCwd: target)

        case "ls":
            let long = args.contains("-l") || args.contains("-la") || args.contains("-al")
            let target = args.first(where: { !$0.hasPrefix("-") }).map { fs.resolve($0, cwd: cwd) } ?? cwd
            guard let url = target else { return err("ls: 路径无效") }
            if !fs.isDir(url) { return out(fs.display(url)) }
            let items = fs.list(url)
            if items.isEmpty { return out("") }
            let txt: String
            if long {
                txt = items.map { "\($0.isDir ? "d" : "-")  \(String(format: "%8d", $0.size))  \($0.name)\($0.isDir ? "/" : "")" }
                    .joined(separator: "\n")
            } else {
                txt = items.map { $0.isDir ? $0.name + "/" : $0.name }.joined(separator: "  ")
            }
            return out(txt)

        case "cat":
            guard !args.isEmpty else {
                if let s = stdin { return out(s) }
                return err("cat: 缺少文件参数")
            }
            var buf = ""
            for a in args where !a.hasPrefix("-") {
                guard let u = fs.resolve(a, cwd: cwd), !fs.isDir(u) else { return err("cat: \(a): 无此文件") }
                guard let s = fs.read(u) else { return err("cat: \(a): 读取失败（可能非 UTF-8 文本）") }
                buf += (buf.isEmpty ? "" : "\n") + s
            }
            return out(buf)

        case "echo":
            return out(args.joined(separator: " "))

        case "mkdir":
            if args.contains("-p") || args.count > 1 {
                for a in args where !a.hasPrefix("-") {
                    guard let u = fs.resolve(a, cwd: cwd) else { return err("mkdir: 路径无效") }
                    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                }
                return out("")
            }
            guard let a = args.first, let u = fs.resolve(a, cwd: cwd) else { return err("mkdir: 用法 mkdir [-p] <目录>") }
            do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false) } catch {
                return err("mkdir: \(error.localizedDescription)")
            }
            return out("")

        case "touch":
            guard let a = args.first, let u = fs.resolve(a, cwd: cwd) else { return err("touch: 用法 touch <文件>") }
            if !fs.exists(u) { try? fs.write(u, "") } else {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
            }
            return out("")

        case "rm":
            let recursive = args.contains("-r") || args.contains("-rf") || args.contains("-fr")
            for a in args where !a.hasPrefix("-") {
                guard let u = fs.resolve(a, cwd: cwd), fs.exists(u) else { return err("rm: \(a): 无此文件") }
                let isDir = fs.isDir(u)
                if isDir && !recursive { return err("rm: \(a) 是目录，需要 -r") }
                do { try FileManager.default.removeItem(at: u) } catch { return err("rm: \(a): \(error.localizedDescription)") }
            }
            return out("")

        case "cp":
            guard args.count >= 2, let s = fs.resolve(args[0], cwd: cwd), let d = fs.resolve(args[1], cwd: cwd) else { return err("cp: 用法 cp <源> <目标>") }
            let dest = fs.isDir(d) ? d.appendingPathComponent(s.lastPathComponent) : d
            do { try FileManager.default.copyItem(at: s, to: dest) } catch { return err("cp: \(error.localizedDescription)") }
            return out("")

        case "mv":
            guard args.count >= 2, let s = fs.resolve(args[0], cwd: cwd), let d = fs.resolve(args[1], cwd: cwd) else { return err("mv: 用法 mv <源> <目标>") }
            let dest = fs.isDir(d) ? d.appendingPathComponent(s.lastPathComponent) : d
            do { try FileManager.default.moveItem(at: s, to: dest) } catch { return err("mv: \(error.localizedDescription)") }
            return out("")

        case "head", "tail":
            guard let f = args.last(where: { !$0.hasPrefix("-") }), let u = fs.resolve(f, cwd: cwd), let s = fs.read(u) else { return err("\(cmd): 用法 \(cmd) [-n N] <文件>") }
            var n = 10
            if let i = args.firstIndex(of: "-n"), i + 1 < args.count { n = Int(args[i + 1]) ?? 10 }
            var lines = s.components(separatedBy: "\n")
            lines = (cmd == "head") ? Array(lines.prefix(n)) : Array(lines.suffix(n))
            return out(lines.joined(separator: "\n"))

        case "wc":
            guard let f = args.last(where: { !$0.hasPrefix("-") }), let u = fs.resolve(f, cwd: cwd), let s = fs.read(u) else { return err("wc: 用法 wc [-l] <文件>") }
            if args.contains("-l") { return out("\(s.components(separatedBy: "\n").count) \(f)") }
            return out("\(s.components(separatedBy: "\n").count) \(s.count) \(s.utf8.count) \(f)")

        case "grep":
            guard let pat = args.first(where: { !$0.hasPrefix("-") }) else { return err("grep: 用法 grep <词> [文件]") }
            let files = args.dropFirst().filter { !$0.hasPrefix("-") }
            if files.isEmpty, let s = stdin {
                return out(s.components(separatedBy: "\n").filter { $0.contains(pat) }.joined(separator: "\n"))
            }
            var buf = ""
            for f in files {
                guard let u = fs.resolve(f, cwd: cwd), let s = fs.read(u) else { continue }
                buf += s.components(separatedBy: "\n").filter { $0.contains(pat) }.joined(separator: "\n") + "\n"
            }
            return out(buf.trimmingCharacters(in: .whitespacesAndNewlines))

        case "find":
            let base = args.first(where: { !$0.hasPrefix("-") }).map { fs.resolve($0, cwd: cwd) } ?? cwd
            guard let u = base else { return err("find: 路径无效") }
            return out(walk(u).joined(separator: "\n"))

        case "tree":
            let base = args.first(where: { !$0.hasPrefix("-") }).map { fs.resolve($0, cwd: cwd) } ?? cwd
            guard let u = base else { return err("tree: 路径无效") }
            var lines = [fs.display(u) + "/"]
            treeLines(u, prefix: "", into: &lines)
            return out(lines.joined(separator: "\n"))

        case "sort":
            guard let f = args.last(where: { !$0.hasPrefix("-") }), let u = fs.resolve(f, cwd: cwd) else {
                if let s = stdin { return out(s.components(separatedBy: "\n").sorted().joined(separator: "\n")) }
                return err("sort: 用法 sort <文件>")
            }
            guard let s = fs.read(u) else { return err("sort: 读取失败") }
            return out(s.components(separatedBy: "\n").sorted().joined(separator: "\n"))

        case "uniq":
            guard let f = args.last(where: { !$0.hasPrefix("-") }), let u = fs.resolve(f, cwd: cwd) else {
                if let s = stdin {
                    var last: String? = nil; var buf: [String] = []
                    for l in s.components(separatedBy: "\n") where l != last { buf.append(l); last = l }
                    return out(buf.joined(separator: "\n"))
                }
                return err("uniq: 用法 uniq <文件>")
            }
            guard let s = fs.read(u) else { return err("uniq: 读取失败") }
            var last: String? = nil; var buf: [String] = []
            for l in s.components(separatedBy: "\n") where l != last { buf.append(l); last = l }
            return out(buf.joined(separator: "\n"))

        case "sed":
            // 简易：sed 's/旧/新/' <文件>（无正则、无 g 旗的全局循环只替换首个）
            guard args.count >= 2, let pat = args.first, pat.hasPrefix("s"), pat.count >= 4 else {
                return err("sed: 用法 sed 's/旧/新/' <文件>")
            }
            let inner = String(pat.dropFirst(2)).dropLast()
            let parts = inner.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let u = fs.resolve(args[1], cwd: cwd), var s = fs.read(u) else { return err("sed: 解析失败") }
            s = s.replacingOccurrences(of: parts[0], with: parts[1])
            try? fs.write(u, s)
            return out(s)

        case "date":
            let f = DateFormatter(); f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return out(f.string(from: Date()))

        case "whoami":
            return out("mobile")

        case "uname":
            return out("Yaotai shell 1.0 (Darwin/arm64, sandboxed FS)")

        case "env":
            return out(["HOME=\(fs.display(fs.home))", "PWD=\(fs.display(cwd))", "SHELL=/bin/yaotai"].joined(separator: "\n"))

        case "export", "set":
            return out("")

        case "history":
            return out(history.suffix(30).enumerated().map { "\($0.offset + 1)  \($0.element)" }.joined(separator: "\n"))

        case "clear", "cls":
            return Result(output: "", exitCode: 0, newCwd: nil, clear: true)

        case "node", "nodejs":
            guard let f = args.first(where: { !$0.hasPrefix("-") }), let u = fs.resolve(f, cwd: cwd), let src = fs.read(u) else {
                return err("node: 用法 node <js文件>")
            }
            return out(runJS(src))

        case "curl":
            guard let urlStr = args.first(where: { !$0.hasPrefix("-") }), let url = URL(string: urlStr) else {
                return err("curl: 用法 curl <url> [-o 文件]")
            }
            var body = Data()
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: url) { d, _, e in
                body = d ?? Data(); sem.signal()
            }.resume()
            sem.wait()
            if let oi = args.firstIndex(of: "-o"), oi + 1 < args.count {
                guard let dest = fs.resolve(args[oi + 1], cwd: cwd) else { return err("curl: 目标路径无效") }
                try? fs.write(dest, String(decoding: body, as: UTF8.self))
                return out("已保存 \(body.count) 字节 → \(fs.display(dest))")
            }
            if body.count > 4000 { return out(String(decoding: body.prefix(4000), as: UTF8.self) + "\n…[共 \(body.count) 字节，截断显示]") }
            return out(String(decoding: body, as: UTF8.self))

        case "git":
            guard args.first == "clone" else { return err("git: 目前只支持 git clone <url>") }
            guard let urlStr = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return err("git: 用法 git clone <url>") }
            let pat = UserDefaults.standard.string(forKey: "jl.ghpat") ?? ""
            let injected = GitHubClient.injectToken(urlStr, token: pat)
            guard let u = URL(string: injected) else { return err("git: URL 无效") }
            var body = Data()
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: u) { d, _, _ in body = d ?? Data(); sem.signal() }.resume()
            sem.wait()
            guard !body.isEmpty else { return err("git: 下载失败（仓库不存在或私有仓库未填 PAT）") }
            let name = (urlStr as NSString).lastPathComponent
                .replacingOccurrences(of: ".git", with: "")
            let dest = cwd.appendingPathComponent(name.isEmpty ? "repo" : name)
            do {
                try GitHubClient.unzip(body, to: dest)
                return out("已克隆 → \(fs.display(dest))")
            } catch {
                return err("git: 解压失败 \(error.localizedDescription)")
            }

        case "open":
            guard let f = args.first, let u = fs.resolve(f, cwd: cwd) else { return err("open: 用法 open <html文件>") }
            NotificationCenter.default.post(name: .yaotaiOpenFile, object: u.path)
            return out("已在预览页打开 \(fs.display(u))")

        case "edit":
            guard let f = args.first, let u = fs.resolve(f, cwd: cwd) else { return err("edit: 用法 edit <文件>") }
            NotificationCenter.default.post(name: .yaotaiOpenFile, object: u.path)
            return out("已在编辑器打开 \(fs.display(u))")

        case "exit", "quit":
            return out("")

        default:
            return err("\(cmd): command not found（输入 help 看内置命令）")
        }
    }

    // MARK: - JS 引擎（JavaScriptCore）

    private func runJS(_ src: String) -> String {
        let ctx = JSContext()!
        var buf = ""
        let log: @convention(block) (String) -> Void = { s in buf += s + "\n" }
        ctx.setObject(log, forKeyedSubscript: "yaotaiPrint" as NSString)
        ctx.evaluateScript("var console = { log: function(){ for (var i=0;i<arguments.length;i++) yaotaiPrint(String(arguments[i])); }, error: console.log, warn: console.log };")
        let result = ctx.evaluateScript(src)
        if let e = ctx.exception {
            return buf + "JS Error: " + e.toString()
        }
        if let r = result, !r.isUndefined, !r.isNull {
            let s = r.toString()
            if !s.isEmpty { buf += "⇒ " + s + "\n" }
        }
        return buf.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 管道与树

    private func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character = "\0"
        for ch in s {
            if ch == "\"" || ch == "'" {
                if quote == ch { quote = "\0" } else if quote == "\0" { quote = ch } else { cur.append(ch) }
                continue
            }
            if ch == " " && quote == "\0" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                continue
            }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func walk(_ url: URL) -> [String] {
        var res: [String] = []
        for item in fs.list(url) {
            let u = url.appendingPathComponent(item.name)
            res.append(fs.display(u) + (item.isDir ? "/" : ""))
            if item.isDir { res.append(contentsOf: walk(u)) }
        }
        return res
    }

    private func treeLines(_ url: URL, prefix: String, into lines: inout [String]) {
        let items = fs.list(url)
        for (i, item) in items.enumerated() {
            let last = i == items.count - 1
            lines.append(prefix + (last ? "└── " : "├── ") + item.name + (item.isDir ? "/" : ""))
            if item.isDir {
                treeLines(url.appendingPathComponent(item.name), prefix: prefix + (last ? "    " : "│   "), into: &lines)
            }
        }
    }
}

extension Notification.Name {
    static let yaotaiOpenFile = Notification.Name("yaotaiOpenFile")
}
