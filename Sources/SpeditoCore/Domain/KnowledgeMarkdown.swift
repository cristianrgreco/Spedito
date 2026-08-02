import Foundation

public enum KnowledgeMarkdown {
  public enum TableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
  }

  public struct Table: Equatable, Sendable {
    public let header: [String]
    public let alignments: [TableAlignment]
    public let rows: [[String]]

    public init(
      header: [String],
      alignments: [TableAlignment],
      rows: [[String]]
    ) {
      self.header = header
      self.alignments = alignments
      self.rows = rows
    }
  }

  public enum Block: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph([String])
    case unorderedList([String])
    case orderedList([String])
    case quote([String])
    case code(String)
    case table(Table)
    case divider
  }

  /// Knowledge page titles are stored separately from their Markdown bodies.
  /// Remove a leading level-one heading so readers do not render the title twice.
  public static func normalizedBody(_ source: String) -> String {
    let normalizedNewlines = source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    var lines = normalizedNewlines.components(separatedBy: "\n")
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeFirst()
    }

    if let first = lines.first {
      let trimmed = first.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("# "), !trimmed.hasPrefix("##") {
        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
          lines.removeFirst()
        }
      }
    }

    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }

  /// Splits a knowledge page into block-level Markdown so SwiftUI does not
  /// flatten headings, paragraphs, and lists into one attributed string.
  public static func blocks(
    in source: String,
    removesLeadingTitle: Bool = true
  ) -> [Block] {
    let normalized = removesLeadingTitle
      ? normalizedBody(source)
      : source
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = normalized.components(separatedBy: "\n")
    var result: [Block] = []
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        index += 1
        continue
      }

      if trimmed.hasPrefix("```") {
        index += 1
        var codeLines: [String] = []
        while index < lines.count,
          !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        {
          codeLines.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        result.append(.code(codeLines.joined(separator: "\n")))
        continue
      }

      if let table = table(in: lines, startingAt: index) {
        result.append(.table(table.value))
        index = table.nextIndex
        continue
      }

      if let heading = heading(from: trimmed) {
        result.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if isDivider(trimmed) {
        result.append(.divider)
        index += 1
        continue
      }

      if let item = unorderedItem(from: trimmed) {
        var items = [item]
        index += 1
        while index < lines.count,
          let next = unorderedItem(
            from: lines[index].trimmingCharacters(in: .whitespaces)
          )
        {
          items.append(next)
          index += 1
        }
        result.append(.unorderedList(items))
        continue
      }

      if let item = orderedItem(from: trimmed) {
        var items = [item]
        index += 1
        while index < lines.count,
          let next = orderedItem(
            from: lines[index].trimmingCharacters(in: .whitespaces)
          )
        {
          items.append(next)
          index += 1
        }
        result.append(.orderedList(items))
        continue
      }

      if trimmed.hasPrefix(">") {
        var quoteLines: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix(">") else { break }
          quoteLines.append(
            String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
          )
          index += 1
        }
        result.append(.quote(quoteLines))
        continue
      }

      var paragraph = [line]
      index += 1
      while index < lines.count {
        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty, !startsBlock(candidate) else { break }
        paragraph.append(lines[index])
        index += 1
      }
      result.append(.paragraph(paragraph))
    }

    return result
  }

  private static func startsBlock(_ line: String) -> Bool {
    line.hasPrefix("```")
      || heading(from: line) != nil
      || unorderedItem(from: line) != nil
      || orderedItem(from: line) != nil
      || line.hasPrefix(">")
      || isDivider(line)
  }

  private static func table(
    in lines: [String],
    startingAt index: Int
  ) -> (value: Table, nextIndex: Int)? {
    guard index + 1 < lines.count else { return nil }
    guard let header = tableCells(from: lines[index]) else { return nil }
    guard
      let delimiterCells = tableCells(from: lines[index + 1]),
      delimiterCells.count == header.count
    else {
      return nil
    }

    let alignments = delimiterCells.compactMap(tableAlignment(from:))
    guard alignments.count == header.count else { return nil }

    var rows: [[String]] = []
    var nextIndex = index + 2
    while nextIndex < lines.count {
      let candidate = lines[nextIndex]
      guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { break }
      guard var cells = tableCells(from: candidate) else { break }
      if cells.count < header.count {
        cells.append(contentsOf: repeatElement("", count: header.count - cells.count))
      } else if cells.count > header.count {
        cells = Array(cells.prefix(header.count))
      }
      rows.append(cells)
      nextIndex += 1
    }

    return (
      Table(header: header, alignments: alignments, rows: rows),
      nextIndex
    )
  }

  private static func tableCells(from line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var cells = [""]
    var foundDelimiter = false
    var isEscaped = false
    var isInCodeSpan = false

    for character in trimmed {
      if isEscaped {
        cells[cells.count - 1].append(character)
        isEscaped = false
        continue
      }
      if character == "\\" {
        cells[cells.count - 1].append(character)
        isEscaped = true
        continue
      }
      if character == "`" {
        cells[cells.count - 1].append(character)
        isInCodeSpan.toggle()
        continue
      }
      if character == "|", !isInCodeSpan {
        foundDelimiter = true
        cells.append("")
      } else {
        cells[cells.count - 1].append(character)
      }
    }

    guard foundDelimiter else { return nil }
    if cells.first?.isEmpty == true {
      cells.removeFirst()
    }
    if cells.last?.isEmpty == true {
      cells.removeLast()
    }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func tableAlignment(from cell: String) -> TableAlignment? {
    let hasLeadingColon = cell.hasPrefix(":")
    let hasTrailingColon = cell.hasSuffix(":")
    let delimiter = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    guard delimiter.count >= 3, delimiter.allSatisfy({ $0 == "-" }) else {
      return nil
    }
    if hasLeadingColon && hasTrailingColon {
      return .center
    }
    if hasTrailingColon {
      return .trailing
    }
    return .leading
  }

  private static func heading(from line: String) -> (level: Int, text: String)? {
    let prefix = line.prefix(while: { $0 == "#" })
    guard !prefix.isEmpty, prefix.count <= 6 else { return nil }
    let remainder = line.dropFirst(prefix.count)
    guard remainder.first == " " else { return nil }
    return (
      prefix.count,
      remainder.trimmingCharacters(in: .whitespaces)
    )
  }

  private static func unorderedItem(from line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(2))
    }
    return nil
  }

  private static func orderedItem(from line: String) -> String? {
    guard let period = line.firstIndex(of: ".") else { return nil }
    let number = line[..<period]
    guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
    let remainder = line[line.index(after: period)...]
    guard remainder.first == " " else { return nil }
    return remainder.trimmingCharacters(in: .whitespaces)
  }

  private static func isDivider(_ line: String) -> Bool {
    let compact = line.filter { !$0.isWhitespace }
    return compact.count >= 3
      && (compact.allSatisfy { $0 == "-" }
        || compact.allSatisfy { $0 == "*" }
        || compact.allSatisfy { $0 == "_" })
  }
}
