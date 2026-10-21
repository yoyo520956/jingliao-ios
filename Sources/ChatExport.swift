import SwiftUI
import UIKit

/// 聊天记录导出：Markdown 文件 + 长图（ImageRenderer 渲染微信风对话卡）
enum ChatExport {

    static func markdown(_ c: Conversation) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "# \(c.title)\n\n> 导出于 \(f.string(from: Date())) · \(c.messages.count) 条消息 · 由鲸聊导出\n\n---\n\n"
        for m in c.messages {
            let who = m.role == "user" ? "🧑 我" : (m.role == "assistant" ? "🤖 AI" : m.role)
            s += "**\(who)** · \(f.string(from: Date(timeIntervalSince1970: m.at)))\n\n\(m.content)\n\n"
            if !m.thinking.isEmpty {
                s += "<details><summary>💭 思考过程</summary>\n\n\(m.thinking)\n\n</details>\n\n"
            }
            s += "---\n\n"
        }
        return s
    }

    static func tempFile(_ c: Conversation) -> URL? {
        let safe = c.title.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_").prefix(30)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970)).md")
        do {
            try markdown(c).data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    /// 长图：iOS16+ ImageRenderer，微信风双气泡白底卡片
    @MainActor
    static func longImage(_ c: Conversation) -> UIImage? {
        let renderer = ImageRenderer(content: ExportCanvas(c: c))
        renderer.scale = 2
        return renderer.uiImage
    }

    static func saveToDocuments(_ image: UIImage, name: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("exports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let d = image.pngData() else { return nil }
        do { try d.write(to: url, options: .atomic); return url } catch { return nil }
    }
}

private struct ExportCanvas: View {
    let c: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).fill(WX.green)
                    .frame(width: 22, height: 22)
                    .overlay(Text("鲸").font(.system(size: 12, weight: .bold)).foregroundColor(.white))
                Text(c.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .lineLimit(1)
                Spacer()
            }
            ForEach(c.messages) { m in
                bubble(m)
            }
            HStack {
                Spacer()
                Text("由鲸聊导出 · \(Self.dateStr(c.updatedAt))")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
        .padding(18)
        .background(Color.white)
        .frame(width: 380)
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        let mine = m.role == "user"
        HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 48) }
            Text(m.content.isEmpty ? "（空）" : m.content)
                .font(.system(size: 13.5))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(mine ? Color(red: 0.584, green: 0.925, blue: 0.412) : Color(white: 0.95)))
            if !mine { Spacer(minLength: 48) }
        }
    }

    private static func dateStr(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

/// UIKit 分享面板包装
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
