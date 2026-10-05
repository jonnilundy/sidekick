import Foundation

/// The block structure of an answer. Inline styling (bold, code, links) is left to AttributedString,
/// after `Markdown.inline` has rewritten what AttributedString does not know (HTML tags, images,
/// reference links, footnotes, emoji codes, math). An unfinished stream must still parse to something sane.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([ListItem])
    case code(language: String, text: String)
    case quote([MarkdownBlock])
    /// A GitHub alert: `> [!NOTE]`, TIP, IMPORTANT, WARNING or CAUTION.
    case callout(kind: CalloutKind, blocks: [MarkdownBlock])
    /// A pipe table. The first row is the header; the |---| line is dropped.
    case table([[String]])
    /// `<details><summary>…</summary> … </details>`, shown collapsed.
    case details(summary: String, blocks: [MarkdownBlock])
    /// A `$$ … $$` block.
    case math(String)
    /// `Term` followed by `: definition` lines.
    case definition(term: String, definitions: [String])
    /// Footnote texts, collected at the end of the answer.
    case footnotes([Footnote])
    case rule
}

public struct ListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable { case bullet, number(Int), task(done: Bool) }
    public var level: Int
    public var marker: Marker
    public var text: String

    public init(level: Int, marker: Marker, text: String) {
        self.level = level
        self.marker = marker
        self.text = text
    }
}

public struct Footnote: Equatable, Sendable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum CalloutKind: String, CaseIterable, Sendable {
    case note = "NOTE", tip = "TIP", important = "IMPORTANT", warning = "WARNING", caution = "CAUTION"

    public var title: String { rawValue.prefix(1) + rawValue.dropFirst().lowercased() }
}

/// Private-use characters that mark inline styles AttributedString's markdown has no syntax for.
/// `Markdown.inline` wraps text in a start and end mark; the renderer applies the style and drops the marks.
public enum InlineMark: Character, CaseIterable, Sendable {
    case underline = "\u{E000}", highlight = "\u{E002}", sub = "\u{E004}", sup = "\u{E006}", key = "\u{E008}", math = "\u{E00A}"

    public var start: Character { rawValue }
    public var end: Character { Character(Unicode.Scalar(rawValue.unicodeScalars.first!.value + 1)!) }

    public func wrap(_ text: String) -> String { "\(start)\(text)\(end)" }

    public static func starting(_ character: Character) -> InlineMark? { allCases.first { $0.start == character } }
}

public enum Markdown {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
        let (references, footnotes) = extractDefinitions(&lines)
        var blocks = parse(lines, references: references)
        if !footnotes.isEmpty {
            // The footnotes draw their own line; a rule right before them would double it.
            if blocks.last == .rule { blocks.removeLast() }
            blocks.append(.footnotes(footnotes.map { Footnote(id: $0.id, text: inline($0.text, references: references)) }))
        }
        return blocks
    }

    // MARK: Definitions

    /// Takes `[id]: url` reference lines and `[^id]: text` footnote lines out of the source.
    static func extractDefinitions(_ lines: inout [String]) -> (references: [String: String], footnotes: [Footnote]) {
        var references: [String: String] = [:]
        var footnotes: [Footnote] = []
        var kept: [String] = []
        var inFence = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let match = trimmed.firstMatch(of: /^\[\^([^\]]+)\]:\s?(.*)$/) {
                var text = String(match.2)
                // Indented lines after a footnote belong to it.
                while index + 1 < lines.count, lines[index + 1].hasPrefix("    "), !lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                }
                footnotes.append(Footnote(id: String(match.1), text: text))
            } else if !inFence, line.prefix(while: { $0 == " " }).count < 4,
                      let match = trimmed.firstMatch(of: /^\[([^\]\^][^\]]*)\]:\s+<?([^\s>]+)>?(?:\s+["'(].*["')])?$/) {
                references[String(match.1).lowercased()] = String(match.2)
            } else {
                kept.append(line)
            }
            index += 1
        }
        lines = kept
        return (references, footnotes)
    }

    // MARK: Blocks

    static func parse(_ lines: [String], references: [String: String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [ListItem] = []
        var indents: [Int] = []
        var index = 0

        func text(_ raw: String) -> String { inline(raw, references: references) }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(text(paragraph.joined(separator: "\n"))))
            paragraph = []
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items))
            items = []
            indents = []
        }
        func flush() { flushParagraph(); flushList() }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            defer { index += 1 }

            if trimmed.isEmpty {
                flushParagraph()
                // A blank line inside a list ends it only when the next line is not part of it.
                if !items.isEmpty, index + 1 < lines.count, listItem(lines[index + 1]) == nil,
                   lines[index + 1].prefix(while: { $0 == " " }).count < 2 {
                    flushList()
                }
                continue
            }

            // Fenced code. An unclosed fence while streaming still shows as code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.drop(while: { $0 == fence.first })).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(String(lines[index].dropFirst(min(indent, lines[index].prefix(while: { $0 == " " }).count))))
                    index += 1
                }
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                continue
            }

            // Math block.
            if trimmed.hasPrefix("$$") {
                flush()
                let rest = trimmed.dropFirst(2)
                if rest.hasSuffix("$$"), rest.count >= 2 {
                    blocks.append(.math(String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
                var body: [String] = rest.isEmpty ? [] : [String(rest)]
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                    body.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.math(body.joined(separator: "\n")))
                continue
            }

            // <details> with a <summary>, nested parse inside.
            if trimmed.lowercased().hasPrefix("<details") {
                flush()
                var body: [String] = []
                var depth = 0
                var summary = "Details"
                while index < lines.count {
                    var current = lines[index]
                    let lower = current.lowercased()
                    depth += lower.components(separatedBy: "<details").count - 1
                    depth -= lower.components(separatedBy: "</details>").count - 1
                    if let match = current.firstMatch(of: /(?i)<summary>(.*?)<\/summary>/) {
                        summary = String(match.1).trimmingCharacters(in: .whitespaces)
                        current.replaceSubrange(match.range, with: "")
                    }
                    current = current.replacing(/(?i)<\/?details[^>]*>/, with: "")
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty { body.append(current) }
                    if depth <= 0 { break }
                    index += 1
                }
                blocks.append(.details(summary: text(summary), blocks: parse(body, references: references)))
                continue
            }

            // Tables.
            if trimmed.hasPrefix("|") {
                flush()
                var rows: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                index -= 1
                blocks.append(.table(tableRows(rows).map { $0.map(text) }))
                continue
            }

            // Setext headings: a paragraph line underlined with === or ---.
            if !paragraph.isEmpty, items.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.count >= 2 && trimmed.allSatisfy({ $0 == "-" })) {
                let title = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, text: text(title)))
                continue
            }

            if let level = headingLevel(trimmed) {
                flush()
                let title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text(title.replacing(/\s#+$/, with: ""))))
                continue
            }

            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                continue
            }

            // Quotes, parsed again inside. A first line [!NOTE] makes it a callout.
            if trimmed.hasPrefix(">") {
                flush()
                var body: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var inner = Substring(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                    if inner.hasPrefix(" ") { inner = inner.dropFirst() }
                    body.append(String(inner))
                    index += 1
                }
                index -= 1
                if let first = body.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   let match = body[first].trimmingCharacters(in: .whitespaces).firstMatch(of: /^\[!([A-Za-z]+)\]\s*(.*)$/),
                   let kind = CalloutKind(rawValue: String(match.1).uppercased()) {
                    var rest = Array(body[(first + 1)...])
                    if !match.2.isEmpty { rest.insert(String(match.2), at: 0) }
                    blocks.append(.callout(kind: kind, blocks: parse(rest, references: references)))
                } else {
                    blocks.append(.quote(parse(body, references: references)))
                }
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                if indents.isEmpty { indents = [item.indent] }
                while let last = indents.last, item.indent < last, indents.count > 1 { indents.removeLast() }
                if let last = indents.last, item.indent > last + 1 { indents.append(item.indent) }
                items.append(ListItem(level: min(indents.count - 1, 4), marker: item.marker, text: text(item.text)))
                continue
            }

            // A wrapped line that belongs to the list item above it.
            if !items.isEmpty, indent >= 2 {
                items[items.count - 1].text += " " + text(trimmed)
                continue
            }

            // Indented code: four spaces, not part of a paragraph or list.
            if indent >= 4, paragraph.isEmpty, items.isEmpty {
                flush()
                var body: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    let blank = current.trimmingCharacters(in: .whitespaces).isEmpty
                    guard blank || current.hasPrefix("    ") else { break }
                    body.append(blank ? "" : String(current.dropFirst(4)))
                    index += 1
                }
                index -= 1
                while body.last?.isEmpty == true { body.removeLast() }
                blocks.append(.code(language: "", text: body.joined(separator: "\n")))
                continue
            }

            // Definition list: one term line, then ": definition" lines.
            if trimmed.hasPrefix(": "), paragraph.count == 1 {
                let term = paragraph[0]
                paragraph = []
                var definitions: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(": ") {
                    definitions.append(text(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst(2))))
                    index += 1
                }
                index -= 1
                blocks.append(.definition(term: text(term), definitions: definitions))
                continue
            }

            if !items.isEmpty { flushList() }
            // Two trailing spaces or a backslash mark a hard break; every line break is kept anyway.
            var kept = line.trimmingCharacters(in: .whitespaces)
            if kept.hasSuffix("\\") { kept.removeLast() }
            paragraph.append(kept)
        }
        flush()
        return blocks
    }

    static func listItem(_ line: String) -> (indent: Int, marker: ListItem.Marker, text: String)? {
        guard let match = line.firstMatch(of: /^( *)([-*+•]|\d{1,3}[.)])\s+(.*)$/) else { return nil }
        // "---" is a rule, "* * *" too, not an empty item.
        if isRule(line.trimmingCharacters(in: .whitespaces)) { return nil }
        let indent = match.1.count
        let symbol = String(match.2)
        var body = String(match.3)
        var marker: ListItem.Marker
        if let digits = Int(symbol.dropLast()) {
            marker = .number(digits)
        } else {
            marker = .bullet
            if let task = body.firstMatch(of: /^\[([ xX])\]\s+/) {
                marker = .task(done: task.1 != " ")
                body = String(body[task.range.upperBound...])
            }
        }
        return (indent, marker, body)
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
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

    // MARK: Inline

    /// Rewrites inline syntax AttributedString does not parse into syntax it does, or into `InlineMark`s.
    /// Code spans are left alone.
    public static func inline(_ text: String, references: [String: String] = [:]) -> String {
        var out = ""
        var rest = Substring(text)
        // Split on code spans: `x` or ``x``. Only the text between them is rewritten.
        while let open = rest.firstIndex(of: "`") {
            let ticks = rest[open...].prefix(while: { $0 == "`" })
            let after = rest[ticks.endIndex...]
            guard let close = after.range(of: String(ticks)) else { break }
            out += rewrite(String(rest[..<open]), references: references)
            out += rest[open..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        return out + rewrite(String(rest), references: references)
    }

    static func rewrite(_ text: String, references: [String: String]) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        // Images become links: a quick panel does not load pictures.
        s = s.replacing(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/) { match in
            "[🖼 \(match.1.isEmpty ? "image" : match.1)](\(match.2))"
        }
        // Reference links, full [text][id], collapsed [text][] and shortcut [id].
        if !references.isEmpty {
            s = s.replacing(/\[([^\]\^][^\]]*)\]\[([^\]]*)\]/) { match in
                let key = (match.2.isEmpty ? String(match.1) : String(match.2)).lowercased()
                guard let url = references[key] else { return String(match.0) }
                return "[\(match.1)](\(url))"
            }
            // Swift regex has no lookbehind, so the character before the [ is captured and put back.
            s = s.replacing(/(^|[^\]!\)])\[([^\]\^][^\]]*)\](?![\(\[:])/) { match in
                guard let url = references[String(match.2).lowercased()] else { return String(match.0) }
                return "\(match.1)[\(match.2)](\(url))"
            }
        }
        // Footnote references become superscripts.
        s = s.replacing(/\[\^([^\]]+)\]/) { match in InlineMark.sup.wrap(String(match.1)) }
        // HTML tags with a markdown or mark equivalent.
        let tags: [(Regex<(Substring, Substring)>, (String) -> String)] = [
            (/(?is)<(?:b|strong)>(.*?)<\/(?:b|strong)>/, { "**\($0)**" }),
            (/(?is)<(?:i|em)>(.*?)<\/(?:i|em)>/, { "*\($0)*" }),
            (/(?is)<(?:s|del|strike)>(.*?)<\/(?:s|del|strike)>/, { "~~\($0)~~" }),
            (/(?is)<code>(.*?)<\/code>/, { "`\($0)`" }),
            (/(?is)<u>(.*?)<\/u>/, { InlineMark.underline.wrap($0) }),
            (/(?is)<mark>(.*?)<\/mark>/, { InlineMark.highlight.wrap($0) }),
            (/(?is)<sub>(.*?)<\/sub>/, { InlineMark.sub.wrap($0) }),
            (/(?is)<sup>(.*?)<\/sup>/, { InlineMark.sup.wrap($0) }),
            (/(?is)<kbd>(.*?)<\/kbd>/, { InlineMark.key.wrap($0) }),
        ]
        for (pattern, make) in tags {
            s = s.replacing(pattern) { make(String($0.1)) }
        }
        s = s.replacing(/(?i)<br\s*\/?>/, with: "\n")
        // Inline math: $…$ that looks like math (has \ ^ _ { } or =), so "$5 and $10" stays money.
        s = s.replacing(/(^|[^\\$\w])\$([^\s$](?:[^$\n]*[^\s$\\])?)\$(?![\w$])/) { match in
            let body = String(match.2)
            guard body.contains(where: { "\\^_{}=".contains($0) }) else { return String(match.0) }
            return "\(match.1)" + InlineMark.math.wrap(prettyMath(body))
        }
        // Emoji codes.
        s = s.replacing(/:([a-z0-9_+\-]+):/) { match in emoji[String(match.1)] ?? String(match.0) }
        return s
    }

    /// A light touch for TeX in a text panel: common commands become symbols, ^ and _ become sup and sub
    /// marks, fractions become a/b, braces go.
    public static func prettyMath(_ tex: String) -> String {
        var s = tex
        for (command, symbol) in texSymbols { s = s.replacingOccurrences(of: command, with: symbol) }
        s = s.replacing(/\^\{([^{}]*)\}|\^([^\s{}^_])/) { InlineMark.sup.wrap(String($0.1 ?? $0.2 ?? "")) }
        s = s.replacing(/_\{([^{}]*)\}|_([^\s{}^_])/) { InlineMark.sub.wrap(String($0.1 ?? $0.2 ?? "")) }
        // Fractions last, so their parts already carry their marks. A single token needs no parentheses.
        func part(_ text: Substring) -> String {
            text.contains(where: { " +-=".contains($0) }) ? "(\(text))" : String(text)
        }
        while let match = s.firstMatch(of: /\\frac\{([^{}]*)\}\{([^{}]*)\}/) {
            s.replaceSubrange(match.range, with: "\(part(match.1))/\(part(match.2))")
        }
        return s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    // Longer commands first, so \rightarrow is not read as \r + ightarrow and \infty before \in.
    static let texSymbols: [(String, String)] = [
        ("\\rightarrow", "→"), ("\\infty", "∞"), ("\\approx", "≈"), ("\\lambda", "λ"), ("\\alpha", "α"),
        ("\\gamma", "γ"), ("\\delta", "δ"), ("\\theta", "θ"), ("\\sigma", "σ"), ("\\times", "×"), ("\\sqrt", "√"),
        ("\\beta", "β"), ("\\cdot", "·"), ("\\neq", "≠"), ("\\sum", "∑"), ("\\int", "∫"), ("\\mu", "μ"),
        ("\\pi", "π"), ("\\le", "≤"), ("\\ge", "≥"), ("\\to", "→"), ("\\pm", "±"), ("\\ ", " "),
    ]

    static let emoji: [String: String] = [
        "rocket": "🚀", "tada": "🎉", "warning": "⚠️", "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌",
        "fire": "🔥", "sparkles": "✨", "bulb": "💡", "memo": "📝", "+1": "👍", "thumbsup": "👍", "-1": "👎",
        "heart": "❤️", "eyes": "👀", "star": "⭐", "smile": "😄", "wave": "👋", "zap": "⚡", "bug": "🐛",
        "lock": "🔒", "key": "🔑", "link": "🔗", "calendar": "📅", "chart_with_upwards_trend": "📈",
        "point_right": "👉", "question": "❓", "exclamation": "❗", "information_source": "ℹ️", "construction": "🚧",
        "hourglass": "⌛", "mag": "🔍", "pushpin": "📌", "email": "📧", "package": "📦", "gear": "⚙️", "100": "💯",
    ]
}
