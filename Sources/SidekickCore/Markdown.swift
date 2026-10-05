import Foundation

/// The block structure of an answer. Inline styling (bold, code, links) is left to AttributedString.
/// Small on purpose: answers are short, and an unfinished stream must still parse to something sane.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbered(start: Int, items: [String])
    case code(language: String, text: String)
    case quote(String)
    /// A pipe table. The first row is the header; the |---| line is dropped.
    case table([[String]])
    case rule
}

public enum Markdown {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var numberedStart = 1
        var quote: [String] = []
        var table: [String] = []
        var code: [String]? = nil
        var codeLanguage = ""

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(start: numberedStart, items: numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(tableRows(table))); table = [] }
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: codeLanguage, text: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if trimmed.isEmpty { flush(); continue }

            if trimmed.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(trimmed)
                continue
            } else if !table.isEmpty {
                flush()
            }

            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if let item = bulletItem(trimmed) {
                if bullets.isEmpty { flush() }
                bullets.append(item)
                continue
            }
            if let (number, item) = numberedItem(trimmed) {
                if numbered.isEmpty { flush(); numberedStart = number }
                numbered.append(item)
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            // A wrapped line that belongs to the list item above it.
            if line.hasPrefix("  "), !bullets.isEmpty {
                bullets[bullets.count - 1] += " " + trimmed
                continue
            }
            if line.hasPrefix("  "), !numbered.isEmpty {
                numbered[numbered.count - 1] += " " + trimmed
                continue
            }
            if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        // An unclosed fence while streaming still shows as code.
        if let lines = code { flush(); blocks.append(.code(language: codeLanguage, text: lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func tableRows(_ lines: [String]) -> [[String]] {
        lines.compactMap { line in
            var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            let isRule = !cells.isEmpty && cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
            return isRule ? nil : cells
        }
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " else { return nil }
        return hashes
    }

    static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count < 4, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}
