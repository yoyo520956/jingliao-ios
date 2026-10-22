import Foundation
import AVKit
import UIKit
import CoreMedia

/// 系统级画中画悬浮窗。
///
/// 前几版用 AVSampleBufferDisplayLayer 手动喂 CVPixelBuffer，前台 inline 能看到，
/// 但系统 PiP 悬浮窗里永远是纯黑——这条路在真机上不可靠。
/// 现在改成业界最稳的做法：**AVPlayer + 真实视频文件**。
/// 画面由 AVFoundation 自己解码播放，PiP 只负责把 playerLayer 的画面投到悬浮窗，
/// 能出图的概率接近 100%（YouTube/哔哩哔哩都是这条路）。
///
/// 视频是运行时用 AVAssetWriter 生成的 960x540 纯色循环短片（带音频轨，PiP 保活必需），
/// 面板文字另外画在一个透明的 overlay 上，用 CADisplayLink 每秒刷新。
final class PiPManager: NSObject, ObservableObject {
    static let shared = PiPManager()

    @Published var isActive = false
    @Published var pipRunning = false

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?
    private var controller: AVPictureInPictureController?
    private var hostView: UIView?
    private var overlayView: UIImageView?
    private var timer: Timer?
    private var frameCount = 0
    private var videoURL: URL?

    private let W: CGFloat = 960
    private let H: CGFloat = 540

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard controller == nil else { resumePiP(); isActive = true; return }

        // 1. 音频会话（后台保活 + PiP 必需）
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            EngineLog.shared.add("PiP 音频会话失败: \(error.localizedDescription)")
        }
        SilentAudio.shared.start()

        // 2. 生成（或复用）背景视频文件
        guard let url = ensureVideoFile() else {
            EngineLog.shared.add("PiP 视频文件生成失败，无法启动")
            return
        }
        videoURL = url

        // 3. AVPlayer + 无缝循环
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        player = p

        // 4. 宿主视图 + playerLayer（必须挂到 keyWindow 上且可见，否则系统采不到画面）
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        host.backgroundColor = .black
        host.alpha = 0.02
        host.clipsToBounds = false

        let pl = AVPlayerLayer(player: p)
        pl.videoGravity = .resizeAspect
        pl.frame = CGRect(x: 0, y: 0, width: W, height: H)
        host.layer.addSublayer(pl)
        playerLayer = pl

        // overlay：把数据面板画在透明图上盖在 playerLayer 上面（仅 inline 可见，PiP 里只播视频）
        let ov = UIImageView(frame: pl.frame)
        ov.backgroundColor = .clear
        ov.isUserInteractionEnabled = false
        host.addSubview(ov)
        overlayView = ov

        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            host.center = CGPoint(x: win.bounds.midX, y: win.bounds.height - 40)
            win.addSubview(host)
        }
        hostView = host
        frameCount = 0

        // 5. PiP 控制器（playerLayer 路径，最稳）
        let cs = AVPictureInPictureController.ContentSource(playerLayer: pl)
        let c = AVPictureInPictureController(contentSource: cs)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        controller = c

        // 6. 播放 + 每秒刷新 overlay
        p.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.renderOverlay()
        }
        isActive = true
        renderOverlay()
        resumePiP()
        EngineLog.shared.add("PiP 监控已开启（AVPlayer 真实视频 + 面板叠加）")
    }

    private func resumePiP() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
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
        player?.pause()
        if let o = loopObserver { NotificationCenter.default.removeObserver(o); loopObserver = nil }
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        controller = nil
        overlayView?.removeFromSuperview()
        overlayView = nil
        hostView?.removeFromSuperview()
        hostView = nil
        if !LocalAPIServer.shared.running { SilentAudio.shared.stop() }
        isActive = false
        pipRunning = false
        EngineLog.shared.add("PiP 监控已关闭")
    }

    // MARK: - 背景视频生成

    /// 生成 8 秒 960x540 深蓝渐变循环视频（H.264 + AAC 静音音轨）。
    /// 只要文件已存在就复用，避免每次启动都重编码。
    private func ensureVideoFile() -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("pip_loop.mp4")
        if FileManager.default.fileExists(atPath: url.path),
           let sz = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, sz > 1000 {
            return url
        }
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            EngineLog.shared.add("PiP 视频 writer 创建失败: \(error.localizedDescription)")
            return nil
        }

        let vw = 960, vh = 540
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: vw,
            AVVideoHeightKey: vh,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 800_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 2,
            ],
        ]
        guard let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings) else {
            EngineLog.shared.add("PiP 视频输入创建失败")
            return nil
        }
        vIn.expectsMediaDataInRealTime = false

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        guard let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) else {
            EngineLog.shared.add("PiP 音频输入创建失败")
            return nil
        }
        aIn.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: vw,
                kCVPixelBufferHeightKey as String: vh,
            ]
        )

        guard writer.canAdd(vIn), writer.canAdd(aIn) else {
            EngineLog.shared.add("PiP writer 无法添加输入")
            return nil
        }
        writer.add(vIn)
        writer.add(aIn)
        guard writer.startWriting() else {
            EngineLog.shared.add("PiP writer startWriting 失败: \(writer.error?.localizedDescription ?? "")")
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        // 视频：8 秒 × 2fps = 16 帧，画渐变 + 文字底纹
        let frameCount = 16
        let fps: Int32 = 2
        let queue = DispatchQueue(label: "pip.video.write")
        let sem = DispatchSemaphore(value: 0)

        var fi = 0
        vIn.requestMediaDataWhenReady(on: queue) { [weak vIn] in
            guard let vIn else { sem.signal(); return }
            while vIn.isReadyForMoreMediaData {
                if fi >= frameCount { vIn.markAsFinished(); sem.signal(); return }
                let t = CMTime(value: CMTimeValue(fi), timescale: fps)
                if let pb = Self.makeFrame(width: vw, height: vh, index: fi, total: frameCount) {
                    adaptor.append(pb, withPresentationTime: t)
                }
                fi += 1
            }
        }
        sem.wait()

        // 音频：8 秒静音 AAC
        var ai = 0
        let audioFramesTotal = 8 * 44_100
        let chunk = 1024
        let asem = DispatchSemaphore(value: 0)
        aIn.requestMediaDataWhenReady(on: queue) { [weak aIn] in
            guard let aIn else { asem.signal(); return }
            while aIn.isReadyForMoreMediaData {
                if ai >= audioFramesTotal { aIn.markAsFinished(); asem.signal(); return }
                let n = min(chunk, audioFramesTotal - ai)
                if let sb = Self.makeSilentAudio(frames: n, startFrame: ai) {
                    aIn.append(sb)
                }
                ai += n
            }
        }
        asem.wait()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        if writer.status == .completed {
            EngineLog.shared.add("PiP 背景视频已生成（\(frameCount) 帧 / 8 秒）")
            return url
        }
        EngineLog.shared.add("PiP 视频写入失败: \(writer.error?.localizedDescription ?? "未知")")
        return nil
    }

    private static func makeFrame(width: Int, height: Int, index: Int, total: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == noErr, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // 深蓝渐变 + 轻微相位移动，看起来像“活”的
        let phase = CGFloat(index) / CGFloat(max(total, 1))
        let colors = [
            CGColor(red: 0.05 + 0.02 * phase, green: 0.09, blue: 0.20, alpha: 1),
            CGColor(red: 0.02, green: 0.04 + 0.02 * phase, blue: 0.10, alpha: 1),
        ] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        } else {
            ctx.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // 中央大号“鲸聊”水印（PiP 里唯一能看到的东西，所以做得显眼）
        let str = "🐋 鲸聊" as NSString
        let font = UIFont.systemFont(ofSize: 96, weight: .bold)
        let attrs2: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(white: 1, alpha: 0.92),
        ]
        let size = str.size(withAttributes: attrs2)
        str.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2,
                             y: (CGFloat(height) - size.height) / 2),
                 withAttributes: attrs2)

        return pb
    }

    /// 生成一段静音 AAC CMSampleBuffer
    private static func makeSilentAudio(frames: Int, startFrame: Int) -> CMSampleBuffer? {
        let sampleRate = 44_100
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &fmt) == noErr,
              let fmt else { return nil }

        let byteCount = frames * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)

        let pts = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate))
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sb
        ) == noErr else { return nil }
        return sb
    }

    // MARK: - Overlay 数据面板

    private func renderOverlay() {
        guard let ov = overlayView else { return }
        let s = LiveStatsCenter.shared
        let img = Self.drawPanel(
            size: CGSize(width: W, height: H),
            contextChars: s.contextChars, contextTokens: s.contextTokensEstimate,
            roundChars: s.roundChars, speed: s.charsPerSec,
            usage: s.tokenUsage, generating: s.generating, roundCount: s.roundCount,
            logs: Array(EngineLog.shared.lines.suffix(10))
        )
        ov.image = img
        frameCount += 1
        if frameCount % 30 == 1 {
            EngineLog.shared.add("[PiP] 面板帧 #\(frameCount) player=\(player?.timeControlStatus == .playing ? "播放中" : "暂停") pip=\(controller?.isPictureInPictureActive == true ? "开" : "关")")
        }
    }

    private static func drawPanel(size: CGSize, contextChars: Int, contextTokens: Int,
                                  roundChars: Int, speed: Double,
                                  usage: Int64, generating: Bool,
                                  roundCount: Int, logs: [String]) -> UIImage {
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            let cg = ctx.cgContext
            // 全透明底，只画文字
            cg.clear(CGRect(origin: .zero, size: size))

            // 顶部标题 + 时间
            let dot = generating ? "🟢" : "⚪️"
            title("\(dot) 鲸聊 · 实时监控", x: 44, y: 26, size: 28, bold: true,
                  color: .white)
            let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
            let t = fmt.string(from: Date())
            let tw = (t as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 24)]).width
            title(t, x: size.width - 44 - tw, y: 30, size: 24, bold: false,
                  color: UIColor(white: 1, alpha: 0.7))

            // 三行统计
            row(label: "上下文", value: "\(grouped(contextChars)) 字",
                sub: "≈ \(grouped(contextTokens)) tok",
                y: 96, valueColor: .white)
            let sp = generating ? String(format: "%.1f 字/秒", speed) : "已结束"
            row(label: "本轮输出（第 \(roundCount + (generating ? 1 : 0)) 轮）",
                value: "\(grouped(roundChars)) 字 · \(sp)", sub: nil,
                y: 188, valueColor: UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1))
            row(label: "累计消耗（服务端上报）",
                value: "\(grouped(Int(usage))) tok", sub: nil,
                y: 280, valueColor: UIColor(red: 1.00, green: 0.76, blue: 0.35, alpha: 1))

            // 日志分隔
            cg.setFillColor(UIColor(white: 1, alpha: 0.15).cgColor)
            cg.fill(CGRect(x: 44, y: 372, width: size.width - 88, height: 1))
            title("实时日志", x: 44, y: 382, size: 18, bold: true,
                  color: UIColor(white: 1, alpha: 0.55))

            var y: CGFloat = 408
            for line in logs.reversed() {
                let s2 = String(line.prefix(58))
                let color: UIColor = line.contains("错误") || line.contains("失败")
                    ? UIColor(red: 1, green: 0.55, blue: 0.55, alpha: 1)
                    : (line.contains("完成") || line.contains("已"))
                    ? UIColor(red: 0.55, green: 0.88, blue: 0.68, alpha: 1)
                    : UIColor(white: 1, alpha: 0.8)
                title(s2, x: 44, y: y, size: 15, bold: false, color: color)
                y += 16.5
            }
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
        p.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular),
            .foregroundColor: color, .paragraphStyle: p,
        ])
    }

    private static func row(label: String, value: String, sub: String?, y: CGFloat, valueColor: UIColor) {
        title(label, x: 44, y: y, size: 22, bold: false, color: UIColor(white: 1, alpha: 0.55))
        title(value, x: 44, y: y + 34, size: 40, bold: true, color: valueColor)
        if let sub {
            let w = (value as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 40, weight: .bold)]).width
            title(sub, x: 44 + w + 24, y: y + 48, size: 22, bold: false, color: UIColor(white: 1, alpha: 0.5))
        }
    }
}

// MARK: - delegate

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pc: AVPictureInPictureController) {
        pipRunning = true
        EngineLog.shared.add("PiP 悬浮窗已启动")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pc: AVPictureInPictureController) {
        pipRunning = false
        EngineLog.shared.add("PiP 悬浮窗已关闭")
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
