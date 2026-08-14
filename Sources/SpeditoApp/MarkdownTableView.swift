import SpeditoCore
import SwiftUI

enum SafeURLPolicy {
  static func allows(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
    return url.user == nil && url.password == nil && url.host?.isEmpty == false
  }

  static func markdown(_ source: String) -> AttributedString {
    var attributed = (try? AttributedString(markdown: source)) ?? AttributedString(source)
    let unsafeLinkRanges: [Range<AttributedString.Index>] = attributed.runs.compactMap {
      run in
      guard let link = run.link, !allows(link) else { return nil }
      return run.range
    }
    for range in unsafeLinkRanges {
      attributed[range].link = nil
    }
    return attributed
  }

  @MainActor static var openURLAction: OpenURLAction {
    OpenURLAction { url in
      allows(url) ? .systemAction(url) : .discarded
    }
  }
}

struct MarkdownTableView: View {
  let table: KnowledgeMarkdown.Table
  let font: Font
  let inlineMarkdown: (String) -> AttributedString

  private var columnCount: Int {
    table.header.count
  }

  private var rowCount: Int {
    table.rows.count + 1
  }

  var body: some View {
    ScrollView(.horizontal) {
      MarkdownTableLayout(columnCount: columnCount) {
        ForEach(0..<(columnCount * rowCount), id: \.self) { index in
          let row = index / columnCount
          let column = index % columnCount
          let cells = row == 0 ? table.header : table.rows[row - 1]

          Text(inlineMarkdown(cells[column]))
            .font(row == 0 ? font.bold() : font)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(textAlignment(for: column))
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: alignment(for: column)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background(for: row))
            .overlay(alignment: .trailing) {
              if column < columnCount - 1 {
                Color(nsColor: .separatorColor)
                  .frame(width: 1)
              }
            }
            .overlay(alignment: .bottom) {
              if row < rowCount - 1 {
                Color(nsColor: .separatorColor)
                  .frame(height: 1)
              }
            }
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

  private func alignment(for column: Int) -> Alignment {
    switch table.alignments[column] {
    case .leading: .topLeading
    case .center: .top
    case .trailing: .topTrailing
    }
  }

  private func textAlignment(for column: Int) -> TextAlignment {
    switch table.alignments[column] {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private func background(for row: Int) -> Color {
    if row == 0 {
      return Color(nsColor: .controlBackgroundColor)
    }
    if (row - 1).isMultiple(of: 2) {
      return Color.secondary.opacity(0.035)
    }
    return Color.clear
  }
}

private struct MarkdownTableLayout: Layout {
  private static let minimumColumnWidth: CGFloat = 110
  private static let maximumColumnWidth: CGFloat = 280

  let columnCount: Int

  struct Cache {
    var measurements: Measurements?
  }

  struct Measurements {
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
    let origins: [CGPoint]
    let size: CGSize
  }

  func makeCache(subviews: Subviews) -> Cache {
    Cache()
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache.measurements = nil
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> CGSize {
    let measurements = measurements(for: subviews)
    cache.measurements = measurements
    return measurements.size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) {
    let measurements = cache.measurements ?? measurements(for: subviews)
    for (index, subview) in subviews.enumerated() {
      let column = index % columnCount
      let row = index / columnCount
      let origin = measurements.origins[index]
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        anchor: .topLeading,
        proposal: ProposedViewSize(
          width: measurements.columnWidths[column],
          height: measurements.rowHeights[row]
        )
      )
    }
  }

  private func measurements(for subviews: Subviews) -> Measurements {
    guard columnCount > 0, !subviews.isEmpty else {
      return Measurements(columnWidths: [], rowHeights: [], origins: [], size: .zero)
    }

    var columnWidths = Array(
      repeating: Self.minimumColumnWidth,
      count: columnCount
    )
    for (index, subview) in subviews.enumerated() {
      let column = index % columnCount
      let intrinsicWidth = subview.sizeThatFits(.unspecified).width
      columnWidths[column] = min(
        Self.maximumColumnWidth,
        max(columnWidths[column], intrinsicWidth)
      )
    }

    let rowCount = (subviews.count + columnCount - 1) / columnCount
    var rowHeights = Array(repeating: CGFloat.zero, count: rowCount)
    for (index, subview) in subviews.enumerated() {
      let column = index % columnCount
      let row = index / columnCount
      let wrappedSize = subview.sizeThatFits(
        ProposedViewSize(width: columnWidths[column], height: nil)
      )
      rowHeights[row] = max(rowHeights[row], wrappedSize.height)
    }

    var columnOrigins = Array(repeating: CGFloat.zero, count: columnCount)
    for column in 1..<columnCount {
      columnOrigins[column] = columnOrigins[column - 1] + columnWidths[column - 1]
    }

    var rowOrigins = Array(repeating: CGFloat.zero, count: rowCount)
    for row in 1..<rowCount {
      rowOrigins[row] = rowOrigins[row - 1] + rowHeights[row - 1]
    }

    let origins = subviews.indices.map { index in
      CGPoint(
        x: columnOrigins[index % columnCount],
        y: rowOrigins[index / columnCount]
      )
    }
    return Measurements(
      columnWidths: columnWidths,
      rowHeights: rowHeights,
      origins: origins,
      size: CGSize(
        width: columnWidths.reduce(0, +),
        height: rowHeights.reduce(0, +)
      )
    )
  }
}
