import WidgetKit
import SwiftUI

// 鲸聊桌面小组件：轮询本机网关 /v1/stats（App 运行时可达），显示网关状态 + 今日用量
// 无需 App Group（Feather 签名下不可靠），直接 HTTP 读活数据

struct StatsEntry: TimelineEntry {
    let date: Date
    let running: Bool
    let todayRequests: Int
    let todayTokens: Int
    let clients: Int
    let accountsUsable: Int
    let accounts: Int
}

private let emptyEntry = StatsEntry(date: Date(), running: false, todayRequests: 0,
                                    todayTokens: 0, clients: 0, accountsUsable: 0, accounts: 0)

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry { emptyEntry }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        Task { completion(await fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        Task {
            let e = await fetch()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }

    private func fetch() async -> StatsEntry {
        guard let url = URL(string: "http://127.0.0.1:22217/v1/stats") else { return emptyEntry }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return emptyEntry
        }
        func i(_ k: String) -> Int { (j[k] as? NSNumber)?.intValue ?? 0 }
        return StatsEntry(date: Date(), running: true,
                          todayRequests: i("todayRequests"),
                          todayTokens: i("todayTokens"),
                          clients: i("clients"),
                          accountsUsable: i("accountsUsable"),
                          accounts: i("accounts"))
    }
}

struct JLWidgetView: View {
    let e: StatsEntry

    var body: some View {
        content
            .modifier(WidgetBG(color: e.running ? Color(red: 0.96, green: 0.99, blue: 0.96) : Color(white: 0.97)))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(e.running ? Color(red: 0.03, green: 0.76, blue: 0.37) : Color(white: 0.7))
                    .frame(width: 9, height: 9)
                Text(e.running ? "网关运行中" : "网关未运行")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                Spacer()
                Image(systemName: "fish.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.03, green: 0.76, blue: 0.37))
            }
            if e.running {
                HStack(spacing: 0) {
                    cell("今日请求", "\(e.todayRequests)", "次")
                    cell("今日 Token", short(e.todayTokens), "")
                    cell("客户端", "\(e.clients)", "个")
                    cell("账号", "\(e.accountsUsable)/\(e.accounts)", "")
                }
                Text("打开鲸聊 · 端口 22217")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("打开鲸聊并开启本地网关")
                        .font(.system(size: 12))
                        .foregroundColor(.black.opacity(0.75))
                    Text("小组件每 15 分钟自动刷新状态")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(2)
    }

    private func cell(_ t: String, _ v: String, _ u: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.system(size: 9)).foregroundColor(.gray)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(v).font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                Text(u).font(.system(size: 8)).foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// iOS17+ 必须 containerBackground，iOS16 退回普通背景
struct WidgetBG: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { RoundedRectangle(cornerRadius: 16).fill(color) }
        } else {
            content.padding(10).background(RoundedRectangle(cornerRadius: 16).fill(color))
        }
    }
}

struct JLWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JLGatewayWidget", provider: StatsProvider()) { e in
            JLWidgetView(e: e)
        }
        .configurationDisplayName("鲸聊网关")
        .description("显示本地 API 网关运行状态与今日用量（鲸聊运行时有效）")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct JLWidgetBundle: WidgetBundle {
    var body: some Widget {
        JLWidget()
    }
}
