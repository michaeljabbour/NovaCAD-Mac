import SwiftUI

/// Small native Markdown renderer for chat: inline emphasis/links plus the
/// block styles a reply needs, without loading remote HTML or web content.
struct AIMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AIMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                HStack(alignment: .top, spacing: 6) {
                    if let marker = block.marker { Text(marker).accessibilityHidden(true) }
                    if block.isCode {
                        Text(block.text).font(.system(.caption, design: .monospaced))
                    } else {
                        Text(AIMarkdown.inline(block.text))
                            .fontWeight(block.isHeading ? .semibold : .regular)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

enum AIMarkdown {
    struct Block: Equatable {
        var text: String
        var marker: String? = nil
        var isHeading = false
        var isCode = false
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flush() {
            if !paragraph.isEmpty { result.append(Block(text: paragraph.joined(separator: "\n"))) }
            paragraph.removeAll()
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if let lines = code { result.append(Block(text: lines.joined(separator: "\n"), isCode: true)); code = nil }
                else { code = [] }
            } else if code != nil { code?.append(line) }
            else if trimmed.isEmpty { flush() }
            else if let range = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flush(); result.append(Block(text: String(trimmed[range.upperBound...]), isHeading: true))
            } else if let range = trimmed.range(of: "^[-*+]\\s+", options: .regularExpression) {
                flush(); result.append(Block(text: String(trimmed[range.upperBound...]), marker: "•"))
            } else if let range = trimmed.range(of: "^[0-9]+[.)]\\s+", options: .regularExpression) {
                flush(); result.append(Block(text: String(trimmed[range.upperBound...]),
                    marker: String(trimmed[range]).trimmingCharacters(in: .whitespaces)))
            } else { paragraph.append(line) }
        }
        flush()
        if let code { result.append(Block(text: code.joined(separator: "\n"), isCode: true)) }
        return result
    }
}
