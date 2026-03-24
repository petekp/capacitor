import SwiftUI

/// A lightweight markdown renderer for review briefs and artifact descriptions.
///
/// Supports:
/// - Inline formatting: **bold**, *italic*, `code`, [links](url)
/// - Code fences (``` blocks) rendered with monospaced font and dark background
/// - Headers (# through ###) rendered with appropriate weight
/// - Bullet/numbered lists with proper indentation
///
/// Falls back to plain text if markdown parsing fails.
struct MarkdownTextView: View {
    let text: String
    var bodyColor: Color = .white.opacity(0.9)
    var secondaryColor: Color = .white.opacity(0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block Parsing

    private enum Block {
        case paragraph(String)
        case heading(Int, String) // level, text
        case codeBlock(String, String?) // content, language
        case list([String]) // items
    }

    private var blocks: [Block] {
        parseBlocks(text)
    }

    private func parseBlocks(_ input: String) -> [Block] {
        var result: [Block] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                result.append(.codeBlock(codeLines.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                continue
            }

            // Heading
            if let headingMatch = parseHeading(trimmed) {
                flushParagraph()
                result.append(.heading(headingMatch.0, headingMatch.1))
                i += 1
                continue
            }

            // List item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                flushParagraph()
                var items: [String] = []
                while i < lines.count {
                    let listLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if listLine.hasPrefix("- ") {
                        items.append(String(listLine.dropFirst(2)))
                    } else if listLine.hasPrefix("* ") {
                        items.append(String(listLine.dropFirst(2)))
                    } else if let range = listLine.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                        items.append(String(listLine[range.upperBound...]))
                    } else if listLine.isEmpty {
                        break
                    } else {
                        // Continuation of previous item
                        if !items.isEmpty {
                            items[items.count - 1] += " " + listLine
                        }
                        i += 1
                        continue
                    }
                    i += 1
                }
                if !items.isEmpty {
                    result.append(.list(items))
                }
                continue
            }

            // Empty line = paragraph break
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Regular text
            paragraphBuffer.append(line)
            i += 1
        }

        flushParagraph()
        return result
    }

    private func parseHeading(_ line: String) -> (Int, String)? {
        if line.hasPrefix("### ") { return (3, String(line.dropFirst(4))) }
        if line.hasPrefix("## ") { return (2, String(line.dropFirst(3))) }
        if line.hasPrefix("# ") { return (1, String(line.dropFirst(2))) }
        return nil
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case let .paragraph(content):
            inlineMarkdownText(content)
                .textSelection(.enabled)

        case let .heading(level, content):
            Text(content)
                .font(headingFont(level: level))
                .foregroundColor(.white.opacity(0.9))
                .textSelection(.enabled)

        case let .codeBlock(content, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(AppTypography.monoCaption)
                    .foregroundColor(.white.opacity(0.7))
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5),
                    ),
            )

        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}")
                            .font(AppTypography.body)
                            .foregroundColor(.white.opacity(0.4))
                        inlineMarkdownText(item)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: AppTypography.sectionTitle
        case 2: AppTypography.cardTitle
        default: AppTypography.bodyMedium
        }
    }

    // MARK: - Inline Markdown

    private func inlineMarkdownText(_ content: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
        ) {
            return Text(attributed)
                .font(AppTypography.body)
                .foregroundColor(bodyColor)
        }
        return Text(content)
            .font(AppTypography.body)
            .foregroundColor(bodyColor)
    }
}
