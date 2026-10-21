import SwiftUI

/// Renders the small Markdown subset the prompts produce: paragraphs, bullets, numbered items, headings, bold/italic/code.
struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 15
    var rtl: Bool = false

    private enum Block: Hashable {
        case heading(String)
        case bullet(String)
        case numbered(String, String)
        case paragraph(String)
        case code(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let s):
            Text(inline(s)).font(.system(size: fontSize * 1.1, weight: .bold))
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(.system(size: fontSize, weight: .bold)).foregroundStyle(Brand.indigo)
                Text(inline(s)).font(.system(size: fontSize))
            }
        case .numbered(let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(Brand.indigo)
                Text(inline(s)).font(.system(size: fontSize))
            }
        case .paragraph(let s):
            Text(inline(s)).font(.system(size: fontSize)).lineSpacing(fontSize * 0.25)
        case .code(let s):
            Text(s)
                .font(.system(size: fontSize * 0.86, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .environment(\.layoutDirection, .leftToRight)
        case .rule:
            Divider()
        }
    }

    /// Inline Markdown; RTL paragraphs get a right-to-left mark so mixed Arabic/English lines start on the right.
    private func inline(_ s: String) -> AttributedString {
        let source = rtl ? "\u{200F}" + s : s
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 { flush(); result.append(.rule); continue }
            if line.hasPrefix("#") {
                flush()
                result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
                flush()
                result.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            if let match = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flush()
                let marker = line[match].trimmingCharacters(in: .whitespaces)
                result.append(.numbered(marker, String(line[match.upperBound...])))
                continue
            }
            paragraph.append(line)
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return result
    }
}
