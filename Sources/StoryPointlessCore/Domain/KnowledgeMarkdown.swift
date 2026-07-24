import Foundation

public enum KnowledgeMarkdown {
  public enum Block: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph([String])
    case unorderedList([String])
    case orderedList([String])
    case quote([String])
    case code(String)
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
