import Foundation
import Combine

/// 实时统计中枢：供画中画悬浮窗每秒渲染
final class LiveStatsCenter: ObservableObject {
    static let shared = LiveStatsCenter()

    /// 上下文字符数（会话全部消息 + 本轮流式增量）
    @Published var contextChars: Int = 0
    /// 本轮输出字符数
    @Published var roundChars: Int = 0
    /// 每秒输出字符数（滑动窗口）
    @Published var charsPerSec: Double = 0
    /// SSE 上报的累计 token 消耗（accumulated_token_usage）
    @Published var tokenUsage: Int64 = 0
    /// 是否正在生成
    @Published var generating: Bool = false
    /// 累计生成消息数（结束一轮 +1）
    @Published var roundCount: Int = 0

    private var samples: [(t: Date, chars: Int)] = []
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recomputeSpeed()
        }
    }

    /// 开新一轮：base = 会话已有消息的上下文字符 + prompt
    func beginRound(baseContextChars: Int) {
        roundChars = 0
        charsPerSec = 0
        samples.removeAll()
        contextChars = baseContextChars
        generating = true
    }

    func appendStream(_ s: String) {
        guard !s.isEmpty else { return }
        roundChars += s.count
        contextChars += s.count
        samples.append((Date(), roundChars))
        if samples.count > 30 { samples.removeFirst(samples.count - 30) }
    }

    func endRound() {
        generating = false
        roundCount += 1
        recomputeSpeed()
    }

    func abortRound() {
        generating = false
        recomputeSpeed()
    }

    func setUsage(_ u: Int64) {
        if u > 0 { tokenUsage = u }
    }

    private func recomputeSpeed() {
        guard samples.count >= 2 else {
            if !generating { charsPerSec = 0 }
            return
        }
        let cutoff = Date().addingTimeInterval(-6)
        let recent = samples.filter { $0.t >= cutoff }
        guard let first = recent.first, let last = samples.last, last.t.timeIntervalSince(first.t) > 0.2 else {
            if generating { charsPerSec = 0 }
            return
        }
        charsPerSec = Double(last.chars - first.chars) / last.t.timeIntervalSince(first.t)
    }

    /// token 粗估（中文 ≈ 0.6 tok/字，仅估算展示）
    var contextTokensEstimate: Int { Int(Double(contextChars) * 0.6) }
}
