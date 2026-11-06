import Foundation
import os

/// A legal document as the blocks its page draws. It reads the Markdown subset `scripts/check-legal-texts.py` allows:
/// Jekyll front matter and the `# ` title are skipped, as the navigation bar shows the title; a `## ` line is a heading,
/// `- ` starts a bullet, an empty line ends a block, and the lines of a paragraph or a bullet are joined with spaces.
/// Links and bold inside a block stay attributes of its text.
struct LegalText: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case heading(AttributedString)
        case paragraph(AttributedString)
        case bullet(AttributedString)
    }

    let blocks: [Block]

    init(markdown: String) {
        var blocks: [Block] = []
        var open: (kind: Kind, lines: [String])?

        func close() {
            guard let block = open else { return }
            blocks.append(block.kind.block(Self.inline(block.lines.joined(separator: " "))))
            open = nil
        }

        for line in Self.body(of: markdown) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
            } else if line.hasPrefix("# ") {
                close()
            } else if line.hasPrefix("## ") {
                close()
                open = (.heading, [String(line.dropFirst(3))])
                // A heading is one line in Markdown, as GitHub Pages draws it.
                close()
            } else if line.hasPrefix("- ") {
                close()
                open = (.bullet, [String(line.dropFirst(2))])
            } else if open != nil {
                open?.lines.append(line)
            } else {
                open = (.paragraph, [line])
            }
        }
        close()
        self.blocks = blocks
    }

    private enum Kind {
        case heading
        case paragraph
        case bullet

        func block(_ text: AttributedString) -> Block {
            switch self {
                case .heading:
                    .heading(text)
                case .paragraph:
                    .paragraph(text)
                case .bullet:
                    .bullet(text)
            }
        }
    }

    /// The lines after the front matter, if the text opens with one.
    private static func body(of markdown: String) -> ArraySlice<Substring> {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return lines[...] }
        return lines[(end + 1)...]
    }

    private static func inline(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            logger.error("Legal text kept as plain text, its Markdown did not parse: \(error)")
            return AttributedString(text)
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CircuitTimer", category: "LegalText")
}
