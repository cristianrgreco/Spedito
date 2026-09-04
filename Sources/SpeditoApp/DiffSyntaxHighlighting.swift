import Chroma
import Foundation
import SwiftUI

/// Token categories the diff viewer colours. They mirror Chroma's built-in
/// kinds; anything the tokeniser adds later renders as plain text rather than
/// an unknown colour.
enum DiffSyntaxTokenKind: String, CaseIterable, Sendable {
  case plain
  case keyword
  case type
  case number
  case string
  case comment
  case function
  case property
  case punctuation
  case `operator`

  init(chromaRawValue: String) {
    self = Self(rawValue: chromaRawValue) ?? .plain
  }

  /// System semantic colours follow light and dark appearance and the Increase
  /// Contrast setting without a hand-maintained palette. The pairs are chosen
  /// to stay readable on the added and removed row tints in both appearances.
  var color: Color {
    switch self {
    case .plain, .punctuation, .operator: .primary
    case .comment: .secondary
    case .keyword: .pink
    case .type: .purple
    case .function, .property: .indigo
    case .string: .red
    case .number: .blue
    }
  }
}

/// A contiguous slice of one diff line's content that shares a token kind.
struct DiffSyntaxRun: Equatable, Sendable {
  let kind: DiffSyntaxTokenKind
  let text: String
}

/// One rendered line of a unified diff.
struct HighlightedDiffLine: Equatable, Identifiable, Sendable {
  let id: Int
  /// The raw diff line, including any leading `+`, `-`, or space.
  let text: String
  let presentation: UnifiedDiffLinePresentation
  /// The leading `+`, `-`, or space of a content line. Metadata, hunk
  /// headers, and marker lines such as `\ No newline at end of file` have none.
  let marker: String?
  /// The line without its marker.
  let content: String
  /// Syntax runs covering `content`, or empty when nothing could be coloured.
  let runs: [DiffSyntaxRun]

  init(id: Int, text: String, runs: [DiffSyntaxRun] = []) {
    self.id = id
    self.text = text
    self.runs = runs
    presentation = UnifiedDiffLinePresentation(line: text)
    switch presentation {
    case .added, .removed:
      marker = String(text.prefix(1))
      content = String(text.dropFirst())
    case .context where text.hasPrefix(" "):
      marker = " "
      content = String(text.dropFirst())
    case .context, .metadata, .hunk:
      marker = nil
      content = text
    }
  }

  func replacingRuns(_ runs: [DiffSyntaxRun]) -> Self {
    Self(id: id, text: text, runs: runs)
  }

  /// The marker in its diff colour followed by the coloured content.
  var attributedText: AttributedString {
    var result = AttributedString()
    if let marker {
      var markerText = AttributedString(marker)
      markerText.foregroundColor = presentation.foreground
      result += markerText
    }
    result += attributedContent
    return result.characters.isEmpty ? AttributedString(" ") : result
  }

  /// The content alone, for side-by-side cells that draw their own gutter.
  var attributedContent: AttributedString {
    guard !runs.isEmpty else {
      var plain = AttributedString(content)
      plain.foregroundColor = marker == nil ? presentation.foreground : .primary
      return plain
    }
    var result = AttributedString()
    for run in runs {
      var runText = AttributedString(run.text)
      runText.foregroundColor = run.kind.color
      result += runText
    }
    return result
  }
}

/// A unified diff split into lines, optionally coloured per file language.
struct HighlightedDiffDocument: Equatable, Sendable {
  /// The diff the lines were derived from, so a view can tell a stale
  /// coloured document from the diff it is currently showing.
  let source: String
  let lines: [HighlightedDiffLine]

  /// Splits the diff without colouring. Cheap enough to render immediately.
  static func plain(unifiedDiff: String) -> Self {
    let lines = unifiedDiff.components(separatedBy: "\n").enumerated().map { offset, text in
      HighlightedDiffLine(id: offset, text: text)
    }
    return Self(source: unifiedDiff, lines: lines)
  }

  /// Colours each file section by the language of its `diff --git` header.
  /// `defaultPath` names the file for a bare hunk that carries no header, such
  /// as a GitHub review excerpt. Runs on the cooperative pool, not the caller.
  nonisolated static func highlighted(
    unifiedDiff: String,
    defaultPath: String? = nil,
    tokenizer: DiffSyntaxTokenizer = .shared
  ) async -> Self {
    var lines = plain(unifiedDiff: unifiedDiff).lines
    for hunk in DiffHunkAssembly.hunks(in: lines, defaultPath: defaultPath) {
      guard let language = hunk.languageIdentifier else { continue }
      // The old and new versions are tokenised separately so a comment or
      // string opened on a removed line cannot bleed into its replacement.
      // Context lines belong to both; the new side is applied last and wins.
      for side in [hunk.oldSide, hunk.newSide] where !side.isEmpty {
        let joined = side.map(\.content).joined(separator: "\n")
        let spans = await tokenizer.spans(in: joined, languageIdentifier: language)
        for (index, runs) in DiffSyntaxRunSplitter.runsByLine(
          spans: spans, joined: joined, lines: side
        ) {
          lines[index] = lines[index].replacingRuns(runs)
        }
      }
    }
    return Self(source: unifiedDiff, lines: lines)
  }
}

/// Owns the one Chroma highlighter so compiled grammars are reused. Chroma's
/// types are not `Sendable`, so they never leave this actor.
actor DiffSyntaxTokenizer {
  struct Span: Equatable, Sendable {
    let kind: DiffSyntaxTokenKind
    /// UTF-16 offsets into the tokenised string.
    let range: NSRange
  }

  static let shared = DiffSyntaxTokenizer()

  private let highlighter = Highlighter()

  func spans(in code: String, languageIdentifier: String) -> [Span] {
    let language = LanguageID(rawValue: languageIdentifier)
    guard let tokens = try? highlighter.tokenize(code, language: language) else {
      return []
    }
    return tokens.map { token in
      Span(kind: DiffSyntaxTokenKind(chromaRawValue: token.kind.rawValue), range: token.range)
    }
  }
}

enum DiffLanguageDetection {
  /// Chroma's identifier for the file's language, or nil when it has none.
  /// Common file types Chroma does not name are resolved through an
  /// extension it does, so Chroma stays the only source of identifiers.
  static func languageIdentifier(forPath path: String) -> String? {
    if let language = LanguageID.fromFilePath(path) {
      return language.rawValue
    }
    let fileName = (path as NSString).lastPathComponent.lowercased()
    let alias =
      fileNameAliases[fileName]
      ?? fileExtension(of: fileName).flatMap { extensionAliases[$0] }
    guard let alias else { return nil }
    return LanguageID.fromFileName("alias.\(alias)")?.rawValue
  }

  private static func fileExtension(of fileName: String) -> String? {
    guard let dot = fileName.lastIndex(of: "."), dot > fileName.startIndex else { return nil }
    let value = fileName[fileName.index(after: dot)...]
    return value.isEmpty ? nil : String(value)
  }

  /// Extensions Chroma does not map, keyed to an extension it does.
  private static let extensionAliases: [String: String] = [
    "mjs": "js", "cjs": "js",
    "mts": "ts", "cts": "ts",
    "h": "c",
    "pyi": "py", "pyw": "py",
    "rake": "rb", "gemspec": "rb", "podspec": "rb",
    "swiftinterface": "swift",
    "mdx": "md",
    "xhtml": "html",
    "plist": "xml", "xib": "xml", "storyboard": "xml", "svg": "xml",
    "xsd": "xml", "xsl": "xml", "xslt": "xml",
    "xcscheme": "xml", "entitlements": "xml", "xcprivacy": "xml", "xcworkspacedata": "xml",
    "jsonc": "json", "json5": "json", "geojson": "json", "webmanifest": "json",
    "xcstrings": "json",
  ]

  /// File names without a usable extension, lowercased, keyed the same way.
  private static let fileNameAliases: [String: String] = [
    "gemfile": "rb", "rakefile": "rb", "podfile": "rb", "fastfile": "rb",
    "appfile": "rb", "matchfile": "rb", "brewfile": "rb", "vagrantfile": "rb",
    "guardfile": "rb",
    "package.resolved": "json", ".swift-format": "json",
    ".babelrc": "json", ".eslintrc": "json", ".prettierrc": "json",
    ".zshrc": "zsh", ".zprofile": "zsh", ".zshenv": "zsh", ".zlogin": "zsh",
    ".bashrc": "bash", ".bash_profile": "bash", ".bash_aliases": "bash",
    ".profile": "sh",
    "containerfile": "dockerfile",
    ".clang-format": "yaml",
    "cargo.lock": "toml", "pipfile": "toml",
  ]

  /// The new-side path named by a `diff --git a/old b/new` header.
  static func path(fromDiffHeader line: String) -> String? {
    guard line.hasPrefix("diff --git ") else { return nil }
    let header = line.dropFirst("diff --git ".count)
    // Git quotes a path that contains spaces or unusual characters.
    guard
      let separator = header.range(of: " \"b/", options: .backwards)
        ?? header.range(of: " b/", options: .backwards)
    else { return nil }
    let path = header[separator.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return path.isEmpty ? nil : path
  }
}

/// The content lines of one hunk, split into the old and new versions.
struct DiffHunk: Equatable, Sendable {
  struct Line: Equatable, Sendable {
    let index: Int
    let content: String
  }

  var languageIdentifier: String?
  var oldSide: [Line] = []
  var newSide: [Line] = []
}

enum DiffHunkAssembly {
  static func hunks(in lines: [HighlightedDiffLine], defaultPath: String?) -> [DiffHunk] {
    var hunks: [DiffHunk] = []
    var language = defaultPath.flatMap(DiffLanguageDetection.languageIdentifier(forPath:))
    var current: DiffHunk?

    func close() {
      if let hunk = current, !(hunk.oldSide.isEmpty && hunk.newSide.isEmpty) {
        hunks.append(hunk)
      }
      current = nil
    }

    for line in lines {
      if let path = DiffLanguageDetection.path(fromDiffHeader: line.text) {
        close()
        language = DiffLanguageDetection.languageIdentifier(forPath: path)
        continue
      }
      switch line.presentation {
      case .hunk:
        close()
        current = DiffHunk(languageIdentifier: language)
      case .metadata:
        close()
      case .added, .removed, .context:
        // Marker-less lines such as `\ No newline at end of file` are not code.
        guard let marker = line.marker else { continue }
        if current == nil {
          current = DiffHunk(languageIdentifier: language)
        }
        let entry = DiffHunk.Line(index: line.id, content: line.content)
        switch marker {
        case "-":
          current?.oldSide.append(entry)
        case "+":
          current?.newSide.append(entry)
        default:
          current?.oldSide.append(entry)
          current?.newSide.append(entry)
        }
      }
    }
    close()
    return hunks
  }
}

enum DiffSyntaxRunSplitter {
  /// Distributes token spans over the joined side text back onto its lines.
  /// A span that crosses a line break, such as a block comment, contributes a
  /// run to every line it touches. Gaps between spans render as plain text.
  static func runsByLine(
    spans: [DiffSyntaxTokenizer.Span],
    joined: String,
    lines: [DiffHunk.Line]
  ) -> [(index: Int, runs: [DiffSyntaxRun])] {
    let text = joined as NSString
    var result: [(index: Int, runs: [DiffSyntaxRun])] = []
    var spanIndex = 0
    var lineStart = 0

    for line in lines {
      let lineEnd = lineStart + (line.content as NSString).length
      var runs: [DiffSyntaxRun] = []
      var covered = lineStart

      func append(_ kind: DiffSyntaxTokenKind, from start: Int, to end: Int) {
        guard end > start else { return }
        runs.append(
          DiffSyntaxRun(
            kind: kind,
            text: text.substring(with: NSRange(location: start, length: end - start))
          )
        )
        covered = end
      }

      while spanIndex < spans.count, NSMaxRange(spans[spanIndex].range) <= lineStart {
        spanIndex += 1
      }
      var cursor = spanIndex
      while cursor < spans.count, spans[cursor].range.location < lineEnd {
        let span = spans[cursor]
        let start = max(span.range.location, lineStart)
        append(.plain, from: covered, to: start)
        append(span.kind, from: start, to: min(NSMaxRange(span.range), lineEnd))
        if NSMaxRange(span.range) > lineEnd {
          break
        }
        cursor += 1
      }
      append(.plain, from: covered, to: lineEnd)
      spanIndex = cursor
      result.append((index: line.index, runs: runs))
      lineStart = lineEnd + 1
    }
    return result
  }
}
