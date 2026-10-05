import SwiftUI
import SidekickCore

/// Renders an answer's markdown. Blocks come from SidekickCore's parser; inline styles from AttributedString.
struct AnswerView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Markdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).font(.system(size: 14)).lineSpacing(2.5)
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level <= 2 ? 15 : 14, weight: .semibold))
                .padding(.top, 2)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4.5 }
                        inline(item).font(.system(size: 14)).lineSpacing(2)
                    }
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + offset).")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        inline(item).font(.system(size: 14)).lineSpacing(2)
                    }
                }
            }
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.07)))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell)
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
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.5)).frame(width: 2)
                inline(text).font(.system(size: 14)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        if var attributed = try? AttributedString(markdown: text, options: options) {
            for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 12.5, design: .monospaced)
                attributed[run.range].backgroundColor = Color.primary.opacity(0.07)
            }
            return Text(attributed)
        }
        return Text(text)
    }
}
