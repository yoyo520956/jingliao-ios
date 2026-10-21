import Foundation

/// Token 用量日志：每次网关请求落一条（含客户端标识），按日聚合给设置页面板
struct UsageEntry: Codable {
    var ts: Double
    var prompt: Int
    var completion: Int
    var client: String
    var model: String
}

final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var entries: [UsageEntry] = []
    private let file: URL
    private let cap = 8000

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        file = docs.appendingPathComponent("jl_usage.json")
        if let d = try? Data(contentsOf: file),
           let a = try? JSONDecoder().decode([UsageEntry].self, from: d) {
            entries = a
        }
    }

    func log(prompt: Int, completion: Int, client: String, model: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(UsageEntry(ts: Date().timeIntervalSince1970, prompt: prompt,
                                           completion: completion, client: client, model: model))
            if self.entries.count > self.cap { self.entries.removeFirst(self.entries.count - self.cap) }
            if let d = try? JSONEncoder().encode(self.entries) { try? d.write(to: self.file, options: .atomic) }
        }
    }

    struct DaySum: Identifiable {
        var id: String { day }
        var day: String
        var prompt: Int
        var completion: Int
        var count: Int
        var total: Int { prompt + completion }
    }

    func daily(days: Int = 7) -> [DaySum] {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "MM-dd"
        var out: [DaySum] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Date())),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let s = day.timeIntervalSince1970, e = next.timeIntervalSince1970
            let inDay = entries.filter { $0.ts >= s && $0.ts < e }
            out.append(DaySum(day: f.string(from: day),
                              prompt: inDay.reduce(0) { $0 + $1.prompt },
                              completion: inDay.reduce(0) { $0 + $1.completion },
                              count: inDay.count))
        }
        return out
    }

    var todayTotal: (prompt: Int, completion: Int, count: Int) {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let inDay = entries.filter { $0.ts >= start }
        return (inDay.reduce(0) { $0 + $1.prompt }, inDay.reduce(0) { $0 + $1.completion }, inDay.count)
    }

    /// 全部累计（含历史）
    var grandTotal: Int { entries.reduce(0) { $0 + $1.prompt + $1.completion } }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: file)
    }
}
