import Foundation
import AVKit

/// 静音音频保活：后台挂个 0.01 音量的无声循环，让 App 不被 iOS 挂起
/// （本地网关 / 画中画都需要——用户切到其他 App 时服务还必须活着）
final class SilentAudio {
    static let shared = SilentAudio()
    private var player: AVAudioPlayer?
    private(set) var running = false

    private init() {}

    func start() {
        guard !running else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            EngineLog.shared.add("保活音频会话失败: \(error.localizedDescription)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jl_silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) { Self.writeSilentWav(to: url) }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.01
        player?.play()
        running = true
        EngineLog.shared.add("后台保活音频已启动（切后台服务不断）")
    }

    func stop() {
        player?.stop()
        player = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func writeSilentWav(to url: URL) {
        let sampleRate = 44100
        let dataCount = sampleRate * 2 // 1 秒 16bit mono
        var d = Data()
        func s(_ x: String) { d.append(x.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        s("RIFF"); u32(UInt32(36 + dataCount)); s("WAVE")
        s("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        s("data"); u32(UInt32(dataCount))
        d.append(Data(count: dataCount))
        try? d.write(to: url)
    }
}
