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
                    // A tag cut off mid-stream ("<details") goes too, or the nested parse would see it again forever.
                    current = current.replacing(/(?i)<\/?details[^>]*(?:>|$)/, with: "")
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
        // Up to 9 digits, as in CommonMark, so a list can start at 1284.
        guard let match = line.firstMatch(of: /^( *)([-*+•]|\d{1,9}[.)])\s+(.*)$/) else { return nil }
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
        // Swift regexes cost real time per call, and most lines hold none of this syntax. Each step runs
        // only when its trigger character is present, which keeps long streamed answers smooth.
        let hasBracket = text.contains("["), hasTag = text.contains("<"), hasDollar = text.contains("$"), hasColon = text.contains(":")
        guard hasBracket || hasTag || hasDollar || hasColon else { return text }
        var s = text
        // Images become links: a quick panel does not load pictures.
        if hasBracket { s = s.replacing(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/) { match in
            "[🖼 \(match.1.isEmpty ? "image" : match.1)](\(match.2))"
        } }
        // Reference links, full [text][id], collapsed [text][] and shortcut [id].
        if hasBracket, !references.isEmpty {
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
        if hasBracket { s = s.replacing(/\[\^([^\]]+)\]/) { match in InlineMark.sup.wrap(String(match.1)) } }
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
        if hasTag {
            for (pattern, make) in tags {
                s = s.replacing(pattern) { make(String($0.1)) }
            }
            s = s.replacing(/(?i)<br\s*\/?>/, with: "\n")
        }
        // Inline math: $…$ that looks like math (has \ ^ _ { } or =), so "$5 and $10" stays money.
        if hasDollar { s = s.replacing(/(^|[^\\$\w])\$([^\s$](?:[^$\n]*[^\s$\\])?)\$(?![\w$])/) { match in
            let body = String(match.2)
            guard body.contains(where: { "\\^_{}=".contains($0) }) else { return String(match.0) }
            return "\(match.1)" + InlineMark.math.wrap(prettyMath(body))
        } }
        // Emoji codes.
        if hasColon { s = s.replacing(/:([a-z0-9_+\-]+):/) { match in emoji[String(match.1)] ?? String(match.0) } }
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

/// Parses a growing answer without starting over each time. The part before the last seam is settled: it is
/// parsed once and kept. Only the tail after it is parsed again. A seam is a line that starts flush left after
/// a blank line, outside a code fence, or a top level item of a list (so a long list is not parsed again on
/// every update). Answers with footnotes or reference links (which reach across the whole text) are always
/// parsed whole.
public final class StreamingMarkdown {
    private var settledSource = ""
    private var settledBlocks: [MarkdownBlock] = []
    /// True when the settled part ends inside a list that goes on after it.
    private var settledInList = false
    private var scan = Scan()

    public init() {}

    /// How much of the source is settled, in UTF-8 bytes. The checks watch it grow.
    public var settledLength: Int { settledSource.utf8.count }

    /// Pass `streaming` while the answer is still arriving: the last block then hides a `**`, `~~` or
    /// backtick that has not closed yet. A finished answer parses exactly like `Markdown.blocks`.
    public func blocks(_ source: String, streaming: Bool = false) -> [MarkdownBlock] {
        var blocks = parse(source)
        if streaming, let last = blocks.popLast() { blocks.append(Self.hidingOpenMarkers(in: last)) }
        return blocks
    }

    private func parse(_ source: String) -> [MarkdownBlock] {
        if source.contains("[^") || source.contains("]: ") { return Markdown.blocks(source) }
        if !source.hasPrefix(scan.read) {
            // Not the same answer growing: start over.
            scan = Scan()
            settledSource = ""
            settledBlocks = []
            settledInList = false
        }
        scan.advance(source)
        let bytes = source.utf8
        let split = bytes.index(bytes.startIndex, offsetBy: scan.end)
        if scan.end != settledSource.utf8.count {
            // Append only: parse just the newly settled part. It starts at a seam, so it parses the same on
            // its own as inside the whole text, apart from a list that the seam cut in two.
            let from = bytes.index(bytes.startIndex, offsetBy: settledSource.utf8.count)
            settledBlocks = Self.joined(settledBlocks, Markdown.blocks(String(source[from..<split])), listOpen: settledInList)
            settledSource = String(source[..<split])
            settledInList = scan.endsInList
        }
        return Self.joined(settledBlocks, Markdown.blocks(String(source[split...])), listOpen: settledInList)
    }

    /// Puts two halves of a list cut at a seam back together.
    static func joined(_ head: [MarkdownBlock], _ rest: [MarkdownBlock], listOpen: Bool) -> [MarkdownBlock] {
        guard listOpen, case .list(let first)? = head.last, case .list(let second)? = rest.first else { return head + rest }
        return head.dropLast() + [.list(first + second)] + rest.dropFirst()
    }

    /// Finds seams line by line and remembers where it stopped, so each call reads only the new lines.
    /// It follows the block parser's list rules closely enough to know when a list goes on.
    struct Scan {
        /// The source up to `offset`, to check that the next source still starts with it.
        var read = ""
        /// UTF-8 offset of the first line not read yet.
        var offset = 0
        /// UTF-8 offset of the last seam.
        var end = 0
        var endsInList = false
        var inFence = false
        var previousBlank = false
        var inList = false
        var listIndent = 0
        /// Off for good once the text holds a math block, details, tabs or CR: list seams are not safe there.
        var listSeams = true

        mutating func advance(_ text: String) {
            let bytes = text.utf8
            var start = bytes.index(bytes.startIndex, offsetBy: offset)
            while start < bytes.endIndex {
                guard let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) else {
                    // An unfinished last line. Only a plain block break is safe to decide from it.
                    let line = text[start...].trimmingCharacters(in: .whitespaces)
                    if previousBlank, !inFence, !inList, !line.isEmpty, !line.hasPrefix("```"), !line.hasPrefix("~~~"),
                       bytes[start] != UInt8(ascii: " ") {
                        seam(at: offset, list: false)
                    }
                    break
                }
                line(text[start..<newline])
                start = bytes.index(after: newline)
                offset = bytes.distance(from: bytes.startIndex, to: start)
            }
            read = String(text[..<start])
        }

        private mutating func seam(at position: Int, list: Bool) {
            end = position
            endsInList = list
        }

        private mutating func line(_ raw: Substring) {
            let lineStart = offset
            if raw.contains("\r") || raw.contains("$$") || (raw.contains("<") && raw.lowercased().contains("<details")) {
                listSeams = false
            }
            let expanded = raw.contains("\t") ? raw.replacingOccurrences(of: "\t", with: "    ") : String(raw)
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if fence { inFence.toggle() }
            let blank = trimmed.isEmpty
            let indent = expanded.prefix(while: { $0 == " " }).count
            let item = !inFence && !fence && !blank && Markdown.listItem(expanded) != nil
            // The parser ends a list at a blank line unless the next line is an item or indented.
            if inList, previousBlank, !item, indent < 2 { inList = false }

            let listSeam = inList && item && indent == 0 && listIndent == 0 && listSeams && !inFence
            if previousBlank, !inFence, !blank, indent == 0 {
                // A line flush left after a blank line: a new block, or the next item of a list that goes on.
                if !inList { seam(at: lineStart, list: false) } else if listSeam { seam(at: lineStart, list: true) }
            } else if listSeam {
                seam(at: lineStart, list: true)
            }

            if fence {
                inList = false
            } else if inFence || blank {
                // Code, or a blank line: the list state waits for the next line.
            } else if item {
                if !inList { inList = true; listIndent = indent }
            } else if inList, indent >= 2, !Self.opensBlock(trimmed) {
                // A wrapped line of the item above.
            } else {
                inList = false
            }
            previousBlank = blank && !inFence
        }

        /// Lines the parser reads as their own block even when indented inside a list.
        static func opensBlock(_ trimmed: String) -> Bool {
            trimmed.hasPrefix("$$") || trimmed.lowercased().hasPrefix("<details") || trimmed.hasPrefix("|")
                || trimmed.hasPrefix(">") || Markdown.headingLevel(trimmed) != nil || Markdown.isRule(trimmed)
        }
    }

    // MARK: Unclosed markers

    /// While an answer streams, its last block can hold a `**`, `~~` or backtick whose partner has not
    /// arrived yet. This drops the unmatched marker and keeps the words. Code blocks are left alone.
    static func hidingOpenMarkers(in block: MarkdownBlock) -> MarkdownBlock {
        switch block {
        case .paragraph(let text): return .paragraph(hidingOpenMarkers(text))
        case .heading(let level, let text): return .heading(level: level, text: hidingOpenMarkers(text))
        case .list(var items):
            if !items.isEmpty { items[items.count - 1].text = hidingOpenMarkers(items[items.count - 1].text) }
            return .list(items)
        case .quote(let blocks):
            guard let last = blocks.last else { return block }
            return .quote(blocks.dropLast() + [hidingOpenMarkers(in: last)])
        case .callout(let kind, let blocks):
            guard let last = blocks.last else { return block }
            return .callout(kind: kind, blocks: blocks.dropLast() + [hidingOpenMarkers(in: last)])
        default: return block
        }
    }

    /// The text rule behind `hidingOpenMarkers(in:)`. Closed code spans are skipped the way `Markdown.inline`
    /// finds them; an unclosed backtick run goes. An odd `**` or `~~` loses its last one, and a lone `*` or `~`
    /// at the very end (half of a marker) goes too.
    public static func hidingOpenMarkers(_ text: String) -> String {
        guard text.contains(where: { $0 == "*" || $0 == "~" || $0 == "`" }) else { return text }
        let chars = Array(text)
        var drop = IndexSet()
        var bold: [Int] = [], strike: [Int] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            guard c == "`" || c == "*" || c == "~" else { i += 1; continue }
            var run = 1
            while i + run < chars.count, chars[i + run] == c { run += 1 }
            if c == "`" {
                // Find the same run of backticks further on; without one the span is not closed.
                var j = i + run
                var closed = false
                while j + run <= chars.count {
                    if chars[j..<(j + run)].allSatisfy({ $0 == "`" }) { closed = true; break }
                    j += 1
                }
                if closed { i = j + run; continue }
                drop.insert(integersIn: i..<(i + run))
            } else {
                let pairs = stride(from: i, to: i + run - 1, by: 2)
                if c == "*" { bold += pairs } else { strike += pairs }
                if run % 2 == 1, i + run == chars.count { drop.insert(i + run - 1) }
            }
            i += run
        }
        if bold.count % 2 == 1, let last = bold.last { drop.insert(integersIn: last..<(last + 2)) }
        if strike.count % 2 == 1, let last = strike.last { drop.insert(integersIn: last..<(last + 2)) }
        guard !drop.isEmpty else { return text }
        return String(chars.indices.filter { !drop.contains($0) }.map { chars[$0] })
    }
}
