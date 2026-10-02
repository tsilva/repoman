import AppKit
import SwiftUI

struct ConversationMarkdownView: View {
    private let markdown: ConversationMarkdown

    init(_ source: String) {
        markdown = ConversationMarkdown(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(markdown.blocks.indices, id: \.self) { index in
                switch markdown.blocks[index] {
                case .text(let source):
                    Text(Self.inline(source))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let table):
                    ConversationMarkdownTable(table: table)
                }
            }
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    fileprivate static func inline(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }
}

private struct ConversationMarkdownTable: View {
    let table: ConversationMarkdown.Table

    private var widths: [CGFloat] {
        table.headers.indices.map { column in
            let values = [table.headers[column]] + table.rows.map { $0[column] }
            let widest = values.map { value in
                let plain = String(ConversationMarkdownView.inline(value).characters)
                return (plain as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
            }.max() ?? 0
            return min(300, max(70, ceil(widest)))
        }
    }

    var body: some View {
        let widths = widths
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                row(table.headers, widths: widths, isHeader: true)
                    .background(Theme.field)
                ForEach(table.rows.indices, id: \.self) { index in
                    row(table.rows[index], widths: widths, isHeader: false)
                        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
                }
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1) }
            .padding(.bottom, 4)
        }
        .accessibilityLabel("Table with \(table.headers.count) columns and \(table.rows.count) rows")
    }

    private func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        GridRow(alignment: .top) {
            ForEach(cells.indices, id: \.self) { column in
                Text(ConversationMarkdownView.inline(cells[column]))
                    .fontWeight(isHeader ? .semibold : .regular)
                    .multilineTextAlignment(textAlignment(table.alignments[column]))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: widths[column], alignment: alignment(table.alignments[column]))
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .accessibilityLabel(isHeader ? cells[column] : "\(table.headers[column]): \(cells[column])")
            }
        }
    }

    private func alignment(_ value: ConversationMarkdown.Table.Alignment) -> Alignment {
        switch value {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func textAlignment(_ value: ConversationMarkdown.Table.Alignment) -> TextAlignment {
        switch value {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}
