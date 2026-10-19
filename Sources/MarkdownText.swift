import SwiftUI

/// 轻量 Markdown 渲染：``` 代码块 + AttributedString 行内
struct MarkdownText: View {
    let text: String

    struct MDBlock {
        var isCode: Bool
        var lang: String
        var text: String
    }

    var body: some View {
        let blocks = Self.blocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { i in
                let b = blocks[i]
                if b.isCode {
                    codeBlock(b)
                } else if !b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(Self.inline(b.text))
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func codeBlock(_ b: MDBlock) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(b.lang.isEmpty ? "代码" : b.lang)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = b.text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(b.text)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    static func blocks(_ s: String) -> [MDBlock] {
        var out: [MDBlock] = []
        let parts = s.components(separatedBy: "```")
        for (i, p) in parts.enumerated() {
            if i % 2 == 1 {
                var t = p
                var lang = ""
                if let nl = t.firstIndex(of: "\n") {
                    lang = String(t[..<nl]).trimmingCharacters(in: .whitespaces)
                    t = String(t[t.index(after: nl)...])
                }
                if t.hasSuffix("\n") { t = String(t.dropLast()) }
                out.append(MDBlock(isCode: true, lang: lang, text: t))
            } else if !p.isEmpty {
                out.append(MDBlock(isCode: false, lang: "", text: p))
            }
        }
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
