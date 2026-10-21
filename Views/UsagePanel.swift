import SwiftUI

/// Token 用量面板：今日汇总 + 近 7 天柱状图 + 清空按钮
struct UsagePanel: View {
    @ObservedObject private var usage = UsageStore.shared
    @State private var cleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let t = usage.todayTotal
            HStack(spacing: 14) {
                statCell("今日请求", "\(t.count)", "次")
                statCell("今日 Prompt", Self.short(t.prompt), "tokens")
                statCell("今日输出", Self.short(t.completion), "tokens")
                statCell("累计", Self.short(usage.grandTotal), "tokens")
            }
            // 近 7 天柱状图
            let days = usage.daily(days: 7)
            let maxV = max(days.map { $0.total }.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { d in
                    VStack(spacing: 4) {
                        Text(d.total > 0 ? Self.short(d.total) : " ")
                            .font(.system(size: 9))
                            .foregroundColor(WX.secondary)
                        Capsule()
                            .fill(d.total > 0 ? WX.green : WX.separator)
                            .frame(height: max(3, CGFloat(d.total) / CGFloat(maxV) * 64))
                        Text(d.day)
                            .font(.system(size: 9))
                            .foregroundColor(WX.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
            HStack {
                Text("近 7 天（每根柱 = 当日 prompt+输出 token）")
                    .font(.system(size: 11))
                    .foregroundColor(WX.secondary)
                Spacer()
                Button(cleared ? "已清空" : "清空统计") {
                    usage.clear()
                    cleared = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { cleared = false }
                }
                .font(.system(size: 13))
                .foregroundColor(WX.badgeRed)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    private func statCell(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundColor(WX.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 16, weight: .semibold)).foregroundColor(WX.titleBlack)
                Text(unit).font(.system(size: 9)).foregroundColor(WX.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
