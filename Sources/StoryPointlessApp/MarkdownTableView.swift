import StoryPointlessCore
import SwiftUI

struct MarkdownTableView: View {
  let table: KnowledgeMarkdown.Table
  let font: Font
  let inlineMarkdown: (String) -> AttributedString

  var body: some View {
    ScrollView(.horizontal) {
      Grid(horizontalSpacing: 0, verticalSpacing: 0) {
        tableRow(table.header, isHeader: true, rowIndex: nil)

        ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
          tableRow(row, isHeader: false, rowIndex: index)
        }
      }
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
    }
  }

  private func tableRow(
    _ cells: [String],
    isHeader: Bool,
    rowIndex: Int?
  ) -> some View {
    GridRow(alignment: .top) {
      ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
        Text(inlineMarkdown(cell))
          .font(isHeader ? font.bold() : font)
          .fixedSize(horizontal: false, vertical: true)
          .frame(
            minWidth: 90,
            maxWidth: 260,
            maxHeight: .infinity,
            alignment: alignment(for: column)
          )
          .multilineTextAlignment(textAlignment(for: column))
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(background(isHeader: isHeader, rowIndex: rowIndex))
          .overlay(alignment: .trailing) {
            if column < cells.count - 1 {
              Color(nsColor: .separatorColor)
                .frame(width: 1)
            }
          }
          .overlay(alignment: .bottom) {
            if isHeader || rowIndex != table.rows.indices.last {
              Color(nsColor: .separatorColor)
                .frame(height: 1)
            }
          }
      }
    }
  }

  private func alignment(for column: Int) -> Alignment {
    switch table.alignments[column] {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private func textAlignment(for column: Int) -> TextAlignment {
    switch table.alignments[column] {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private func background(isHeader: Bool, rowIndex: Int?) -> Color {
    if isHeader {
      return Color(nsColor: .controlBackgroundColor)
    }
    if let rowIndex, rowIndex.isMultiple(of: 2) {
      return Color.secondary.opacity(0.035)
    }
    return Color.clear
  }
}
