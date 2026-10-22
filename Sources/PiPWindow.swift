import Foundation
import AVKit
import UIKit
import CoreMedia

/// 系统级画中画悬浮窗：AVSampleBufferDisplayLayer 渲染实时监控面板
/// 开启后可在其他 App / 主屏幕上查看实时消耗（每秒刷新）
final class PiPManager: NSObject, ObservableObject {
    static let shared = PiPManager()

    @Published var isActive = false
    @Published var pipRunning = false

    private var layer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?
    private var hostView: UIView?
    private var timer: Timer?
    private var frameCount = 0

    private let W = 960
    private let H = 540

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard controller == nil else { resumePiP(); isActive = true; return }

        // 1. 音频会话（后台存活的钥匙）+ 静音循环兜底
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            EngineLog.shared.add("PiP 音频会话失败: \(error.localizedDescription)")
        }
        startSilentAudio()

        // 2. 渲染层 + 宿主视图挂到 keyWindow
        // 注意：宿主视图必须 isHidden=false（iOS 15+ 对完全隐藏的宿主层会黑屏）；
        // 用 1x1 + alpha 0.01 的「可见但不可见」微窗贴在屏幕左下角，用户无感但层是活的
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.frame = CGRect(x: 0, y: 0, width: W, height: H)
        l.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.13, alpha: 1).cgColor
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.backgroundColor = .black
        v.alpha = 0.01
        v.clipsToBounds = true
        v.layer.addSublayer(l)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            v.center = CGPoint(x: win.bounds.midX, y: win.bounds.height - 40)
            win.addSubview(v)
        }
        hostView = v
        frameCount = 0

        // 3. PiP 控制器
        let cs = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: l, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: cs)
        c.canStartPictureInPictureAutomaticallyFromInline = true   // 切后台自动进 PiP
        c.delegate = self
        controller = c
        layer = l

        // timebase 归位：默认停在 0/rate=0，不推进的化 enqueue 的采样永不过期 → 黑屏
        if let tb = l.controlTimebase {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
        }

        // 4. 每秒一帧监控面板
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.renderTick()
        }
        isActive = true
        renderTick()
        resumePiP()
        EngineLog.shared.add("PiP 监控已开启（每秒刷新）")
    }

    private func resumePiP() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let c = self.controller, self.isActive else { return }
            if c.isPictureInPicturePossible {
                c.startPictureInPicture()
            } else {
                EngineLog.shared.add("PiP 暂不可用（isPictureInPicturePossible=false），切后台时自动进入")
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        controller?.stopPictureInPicture()
        layer?.removeFromSuperlayer()
        layer = nil
        controller = nil
        hostView?.removeFromSuperview()
        hostView = nil
        // 网关还在跑就继续保活
        if !LocalAPIServer.shared.running { SilentAudio.shared.stop() }
        isActive = false
        pipRunning = false
        EngineLog.shared.add("PiP 监控已关闭")
    }

    // MARK: - 渲染

    private func renderTick() {
        guard let layer else { return }
        if layer.status == .failed {
            EngineLog.shared.add("PiP layer 失败: \(String(describing: layer.error))")
            layer.flush()
        }
        let s = LiveStatsCenter.shared
        let image = Self.drawDashboard(contextChars: s.contextChars, contextTokens: s.contextTokensEstimate,
                                       roundChars: s.roundChars, speed: s.charsPerSec,
                                       usage: s.tokenUsage, generating: s.generating, roundCount: s.roundCount)
        guard let pb = Self.pixelBuffer(from: image, width: W, height: H) else {
            EngineLog.shared.add("PiP pixelBuffer 创建失败")
            return
        }

        // 格式描述直接从 pixel buffer 生成，天然匹配（比字面 fourcc 稳）
        var fd: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd) == noErr,
              let fd else {
            EngineLog.shared.add("PiP formatDescription 创建失败")
            return
        }

        frameCount += 1
        if frameCount % 30 == 1 {
            EngineLog.shared.add("[PiP] 帧 #\(frameCount) 已入队 layer.status=\(layer.status.rawValue)")
        }
        // PTS 置 invalid + DisplayImmediately，layer 立即渲染（不依赖 timebase 推进）
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                       formatDescription: fd, sampleTiming: &timing,
                                                       sampleBufferOut: &sb) == noErr,
              let sb else {
            EngineLog.shared.add("PiP sampleBuffer 创建失败")
            return
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        layer.enqueue(sb)
    }

    private static func pixelBuffer(from image: UIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == noErr,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.04, green: 0.07, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let cg = image.cgImage {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pb
    }

    /// 监控面板：960x540（PiP 窗口自动缩放）
    private static func drawDashboard(contextChars: Int, contextTokens: Int,
                                      roundChars: Int, speed: Double,
                                      usage: Int64, generating: Bool, roundCount: Int) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540))
        return renderer.image { ctx in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [CGColor(red: 0.05, green: 0.09, blue: 0.17, alpha: 1),
                                        CGColor(red: 0.03, green: 0.05, blue: 0.10, alpha: 1)] as CFArray,
                               locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero,
                                             end: CGPoint(x: 0, y: 540), options: [])

            // 标题
            let dot = generating ? "🟢" : "⚪️"
            title("\(dot) 鲸聊 · 实时监控", x: 44, y: 34, size: 30, bold: true, color: .white)
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            title(fmt.string(from: Date()), x: 800, y: 42, size: 20, bold: false, color: UIColor(white: 1, alpha: 0.45))

            // 上下文
            row(label: "上下文", value: "\(grouped(contextChars)) 字",
                sub: "≈ \(grouped(contextTokens)) tok",
                y: 120, valueColor: .white)
            // 本轮输出
            let sp = generating ? String(format: "%.1f 字/秒", speed) : "已结束"
            row(label: "本轮输出（第 \(roundCount + (generating ? 1 : 0)) 轮）",
                value: "\(grouped(roundChars)) 字 · \(sp)",
                sub: nil, y: 240, valueColor: UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1))
            // 累计消耗
            row(label: "累计消耗（服务端上报）",
                value: "\(grouped(Int(usage))) tok",
                sub: nil, y: 360, valueColor: UIColor(red: 1.00, green: 0.76, blue: 0.35, alpha: 1))
        }
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func title(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool, color: UIColor) {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byCharWrapping
        (text as NSString).draw(
            at: CGPoint(x: x, y: y),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular),
                .foregroundColor: color, .paragraphStyle: p,
            ])
    }

    private static func row(label: String, value: String, sub: String?, y: CGFloat, valueColor: UIColor) {
        title(label, x: 44, y: y, size: 22, bold: false, color: UIColor(white: 1, alpha: 0.5))
        title(value, x: 44, y: y + 34, size: 40, bold: true, color: valueColor)
        if let sub {
            let w = (value as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 40, weight: .bold)]).width
            title(sub, x: 44 + w + 24, y: y + 48, size: 22, bold: false, color: UIColor(white: 1, alpha: 0.45))
        }
    }

    // MARK: - 静音音频（保活兜底）

    private func startSilentAudio() {
        SilentAudio.shared.start()
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ pc: AVPictureInPictureController, setPlaying playing: Bool) {
        // 面板是实况流，无需暂停语义
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pc: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(value: 3600, timescale: 1))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pc: AVPictureInPictureController) -> Bool { false }

    func pictureInPictureController(_ pc: AVPictureInPictureController, didTransitionToRenderSize newSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pc: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping @Sendable () -> Void) {
        completionHandler()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pc: AVPictureInPictureController) {
        pipRunning = true
        EngineLog.shared.add("PiP 悬浮窗已启动")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pc: AVPictureInPictureController) {
        pipRunning = false
    }

    func pictureInPictureController(_ pc: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        EngineLog.shared.add("PiP 启动失败: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ pc: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
