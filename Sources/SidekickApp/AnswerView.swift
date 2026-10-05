import SwiftUI
import SidekickCore

/// Renders an answer's markdown. Blocks come from SidekickCore's parser; inline styles from AttributedString
/// plus the `InlineMark`s the parser leaves for underline, highlight, sub, sup, keys and math.
struct AnswerView: View {
    let markdown: String

    var body: some View {
        BlocksView(blocks: Markdown.blocks(markdown))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Answers are model output. Only web and mail links open; file:, app schemes and the rest do not.
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return .discarded }
                return .systemAction
            })
    }
}

/// A stack of blocks. Quotes, callouts and details hold blocks of their own, so this view nests.
struct BlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
    }
}

struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Inline.text(text).font(.system(size: 14)).lineSpacing(2.5)
        case .heading(let level, let text):
            Inline.text(text)
                .font(.system(size: Self.headingSize[min(level, 6) - 1], weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(level >= 5 ? .secondary : .primary)
                .padding(.top, level <= 2 ? 4 : 2)
        case .list(let items):
            ListBlock(items: items)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.45)).frame(width: 2)
                AnyView(BlocksView(blocks: blocks)).foregroundStyle(.secondary)
            }
        case .callout(let kind, let blocks):
            Callout(kind: kind, blocks: blocks)
        case .table(let rows):
            TableBlock(rows: rows)
        case .details(let summary, let blocks):
            DetailsBlock(summary: summary, blocks: blocks)
        case .math(let tex):
            Inline.math(Markdown.prettyMath(tex))
                .font(.system(size: 15, design: .serif).italic())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        case .definition(let term, let definitions):
            VStack(alignment: .leading, spacing: 3) {
                Inline.text(term).font(.system(size: 14, weight: .semibold))
                ForEach(Array(definitions.enumerated()), id: \.offset) { _, definition in
                    Inline.text(definition).font(.system(size: 14)).foregroundStyle(.secondary).padding(.leading, 14)
                }
            }
        case .footnotes(let notes):
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.bottom, 2)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.id).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        Inline.text(note.text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
            }
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    static let headingSize: [CGFloat] = [20, 17.5, 15.5, 14.5, 14, 13]
}

struct ListBlock: View {
    let items: [ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    marker(item)
                    Inline.text(item.text)
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .strikethrough(item.marker == .task(done: true), color: .secondary)
                        .foregroundStyle(item.marker == .task(done: true) ? .secondary : .primary)
                }
                .padding(.leading, CGFloat(item.level) * 18)
            }
        }
    }

    @ViewBuilder private func marker(_ item: ListItem) -> some View {
        switch item.marker {
        case .bullet:
            Circle()
                .strokeBorder(.secondary, lineWidth: item.level == 1 ? 1 : 0)
                .background(Circle().fill(item.level == 1 ? .clear : Color.secondary))
                .frame(width: item.level >= 2 ? 4 : 5, height: item.level >= 2 ? 4 : 5)
                .frame(width: 14)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
        case .number(let number):
            Text("\(number).")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(done ? Color.sidekick : .secondary)
                .frame(width: 14)
        }
    }
}

/// A GitHub alert: tinted box, icon and title in the alert's color.
struct Callout: View {
    let kind: CalloutKind
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kind.title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(color)
            AnyView(BlocksView(blocks: blocks))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.10)))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                .fill(color)
                .frame(width: 3)
        }
    }

    private var color: Color {
        switch kind {
        case .note: .blue
        case .tip: .green
        case .important: .purple
        case .warning: .orange
        case .caution: .red
        }
    }

    private var symbol: String {
        switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }
}

struct DetailsBlock: View {
    let summary: String
    let blocks: [MarkdownBlock]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 1)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Inline.text(summary).font(.system(size: 14, weight: .medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                AnyView(BlocksView(blocks: blocks))
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Inline.text(cell)
                                .font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                    if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct CodeBlock: View {
    let language: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Highlighter.highlight(text, language: language))
                    .font(.system(size: 12.5, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.top, language.isEmpty ? 8 : 4)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
    }
}

/// Inline text: AttributedString markdown, then the parser's marks become styles.
enum Inline {
    static func text(_ source: String) -> Text {
        Text(attributed(source))
    }

    /// Math is not markdown (underscores, stars), so only the marks are applied.
    static func math(_ source: String) -> Text {
        var string = AttributedString(source)
        applyMarks(&string)
        return Text(string)
    }

    static func attributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var string = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = .system(size: 12.5, design: .monospaced)
            string[run.range].backgroundColor = Color.primary.opacity(0.08)
        }
        applyMarks(&string)
        return string
    }

    /// Finds each start mark, styles the text up to its end mark, and removes both marks.
    static func applyMarks(_ string: inout AttributedString) {
        while let start = string.characters.firstIndex(where: { InlineMark.starting($0) != nil }) {
            let mark = InlineMark.starting(string.characters[start])!
            let afterStart = string.characters.index(after: start)
            guard let end = string.characters[afterStart...].firstIndex(of: mark.end) else {
                string.removeSubrange(start..<afterStart)
                continue
            }
            if afterStart < end {
                let range = afterStart..<end
                switch mark {
                case .underline:
                    string[range].underlineStyle = .single
                case .highlight:
                    string[range].backgroundColor = Color.yellow.opacity(0.35)
                case .sub:
                    string[range].baselineOffset = -3
                    string[range].font = .system(size: 10.5)
                case .sup:
                    string[range].baselineOffset = 6
                    string[range].font = .system(size: 10.5)
                case .key:
                    string[range].font = .system(size: 11.5, weight: .medium, design: .rounded)
                    string[range].backgroundColor = Color.primary.opacity(0.10)
                case .math:
                    string[range].font = .system(size: 14.5, design: .serif).italic()
                }
            }
            string.removeSubrange(end..<string.characters.index(after: end))
            string.removeSubrange(start..<afterStart)
        }
    }
}

/// A small, language-agnostic highlighter: comments, strings, numbers, keywords; diff lines in red and green.
enum Highlighter {
    static func highlight(_ code: String, language: String) -> AttributedString {
        var out = AttributedString()
        let lang = language.lowercased()
        let lines = code.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var part = lang == "diff" || lang == "patch" ? diffLine(line) : codeLine(line, hashComments: hashLanguages.contains(lang))
            if index < lines.count - 1 { part.append(AttributedString("\n")) }
            out.append(part)
        }
        return out
    }

    static func diffLine(_ line: String) -> AttributedString {
        var part = AttributedString(line)
        if line.hasPrefix("+") && !line.hasPrefix("+++") { part.foregroundColor = .green }
        else if line.hasPrefix("-") && !line.hasPrefix("---") { part.foregroundColor = .red }
        else if line.hasPrefix("@@") { part.foregroundColor = .purple }
        return part
    }

    static func codeLine(_ line: String, hashComments: Bool) -> AttributedString {
        var part = AttributedString(line)
        let text = line
        func color(_ range: Range<String.Index>, _ color: Color) {
            guard let lower = AttributedString.Index(range.lowerBound, within: part),
                  let upper = AttributedString.Index(range.upperBound, within: part) else { return }
            part[lower..<upper].foregroundColor = color
        }
        var covered: [Range<String.Index>] = []
        func free(_ range: Range<String.Index>) -> Bool { !covered.contains { $0.overlaps(range) } }

        for match in text.matches(of: /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/) {
            covered.append(match.range)
            color(match.range, .orange)
        }
        let comment = hashComments ? text.firstMatch(of: /#.*$/) : text.firstMatch(of: /\/\/.*$/)
        if let comment, free(comment.range) {
            covered.append(comment.range)
            color(comment.range, .gray)
        }
        for match in text.matches(of: /\b\d+(?:\.\d+)?\b/) where free(match.range) {
            color(match.range, .teal)
        }
        for match in text.matches(of: /\b[A-Za-z_]+\b/) where free(match.range) && keywords.contains(String(match.0)) {
            color(match.range, .pink)
        }
        return part
    }

    static let hashLanguages: Set<String> = ["python", "py", "sh", "bash", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml", "r", "perl", "make", "makefile", "dockerfile"]

    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case",
        "switch", "guard", "def", "from", "as", "in", "and", "or", "not", "is", "None", "True", "False", "true",
        "false", "nil", "null", "const", "function", "async", "await", "export", "default", "new", "try", "catch",
        "throw", "public", "private", "static", "self", "this", "fn", "pub", "use", "mut", "impl", "type",
        "interface", "package", "go", "select", "with", "yield", "lambda", "echo", "then", "fi", "do", "done",
        "SELECT", "FROM", "WHERE", "JOIN", "GROUP", "BY", "ORDER", "LIMIT", "INSERT", "UPDATE", "DELETE",
    ]
}
