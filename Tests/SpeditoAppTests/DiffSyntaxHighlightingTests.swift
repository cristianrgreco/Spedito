import SwiftUI
import Testing

@testable import SpeditoApp

@Suite("Diff syntax highlighting")
struct DiffSyntaxHighlightingTests {
  @Test("[V03] Content lines split into a diff marker and runs that cover the content")
  func v03ContentLinesSplitIntoMarkerAndRuns() async {
    let diff = """
      diff --git a/Sources/Feature.swift b/Sources/Feature.swift
      index 1111111..2222222 100644
      --- a/Sources/Feature.swift
      +++ b/Sources/Feature.swift
      @@ -1,3 +1,3 @@
       import Foundation
      -let count = 1 // old
      +let count = 2 // new
      """
    let document = await HighlightedDiffDocument.highlighted(unifiedDiff: diff)

    #expect(document.source == diff)
    #expect(document.lines.count == 8)
    let header = document.lines[0]
    #expect(header.presentation == .metadata)
    #expect(header.marker == nil)
    #expect(header.content == header.text)
    #expect(header.runs.isEmpty)
    #expect(document.lines[4].presentation == .hunk)
    #expect(document.lines[4].runs.isEmpty)

    let context = document.lines[5]
    #expect(context.marker == " ")
    #expect(context.content == "import Foundation")
    #expect(context.runs.first == DiffSyntaxRun(kind: .keyword, text: "import"))

    let removed = document.lines[6]
    #expect(removed.marker == "-")
    #expect(removed.runs.contains(DiffSyntaxRun(kind: .number, text: "1")))

    let added = document.lines[7]
    #expect(added.marker == "+")
    #expect(added.content == "let count = 2 // new")
    #expect(added.runs.map(\.text).joined() == added.content)
    #expect(added.runs.first == DiffSyntaxRun(kind: .keyword, text: "let"))
    #expect(added.runs.contains(DiffSyntaxRun(kind: .number, text: "2")))
    #expect(added.runs.contains(DiffSyntaxRun(kind: .comment, text: "// new")))
  }

  @Test("A block comment opened on one line keeps colouring the next line of the hunk")
  func blockCommentSpansLines() async {
    let diff = """
      diff --git a/A.swift b/A.swift
      @@ -1,2 +1,2 @@
      +/* start
      +still inside */ let x = 1
      """
    let document = await HighlightedDiffDocument.highlighted(unifiedDiff: diff)

    #expect(document.lines[2].runs == [DiffSyntaxRun(kind: .comment, text: "/* start")])
    #expect(document.lines[3].runs.first == DiffSyntaxRun(kind: .comment, text: "still inside */"))
    #expect(document.lines[3].runs.contains(DiffSyntaxRun(kind: .keyword, text: "let")))
  }

  @Test("Removed and added lines are tokenised as separate old and new versions")
  func oldAndNewSidesDoNotBleed() async {
    let diff = """
      diff --git a/A.swift b/A.swift
      @@ -1,2 +1,1 @@
      -/* removed one
      +let added = 1
      -removed two */
      """
    let document = await HighlightedDiffDocument.highlighted(unifiedDiff: diff)

    #expect(document.lines[2].runs == [DiffSyntaxRun(kind: .comment, text: "/* removed one")])
    #expect(document.lines[3].runs.first == DiffSyntaxRun(kind: .keyword, text: "let"))
    #expect(document.lines[4].runs == [DiffSyntaxRun(kind: .comment, text: "removed two */")])
  }

  @Test("Each file section is coloured by its own language and unknown files stay plain")
  func eachFileSectionUsesItsOwnLanguage() async {
    let diff = """
      diff --git a/A.swift b/A.swift
      @@ -1 +1 @@
      +let a = 1
      diff --git a/config.json b/config.json
      @@ -1 +1 @@
      +{"key": 1}
      diff --git a/notes.txt b/notes.txt
      @@ -1 +1 @@
      +let a = 1
      """
    let document = await HighlightedDiffDocument.highlighted(unifiedDiff: diff)

    #expect(document.lines[2].runs.first == DiffSyntaxRun(kind: .keyword, text: "let"))
    #expect(document.lines[5].runs.contains(DiffSyntaxRun(kind: .property, text: "\"key\"")))
    #expect(document.lines[5].runs.contains(DiffSyntaxRun(kind: .number, text: "1")))
    #expect(document.lines[8].runs.isEmpty)
    #expect(document.lines[8].marker == "+")
    #expect(document.lines[8].content == "let a = 1")
  }

  @Test("A review hunk without file headers is coloured by the reviewed path")
  func headerlessHunkUsesTheReviewedPath() async {
    let hunk = """
      @@ -1,2 +1,2 @@
      -let a = 1
      +let a = 2
      """
    let swift = await HighlightedDiffDocument.highlighted(
      unifiedDiff: hunk,
      defaultPath: "Sources/Feature.swift"
    )
    let text = await HighlightedDiffDocument.highlighted(
      unifiedDiff: hunk,
      defaultPath: "notes.txt"
    )

    #expect(swift.lines[2].runs.first == DiffSyntaxRun(kind: .keyword, text: "let"))
    #expect(text.lines[2].runs.isEmpty)
  }

  @Test("Marker-less lines and a truncated tail render plain without breaking the hunk")
  func markerlessAndTruncatedLinesStayPlain() async {
    let diff = """
      diff --git a/A.swift b/A.swift
      @@ -1,2 +1,2 @@
      -let a = 1
      \\ No newline at end of file
      +let a = 2
      +let b = "cut
      """
    let document = await HighlightedDiffDocument.highlighted(unifiedDiff: diff)

    let noNewline = document.lines[3]
    #expect(noNewline.presentation == .context)
    #expect(noNewline.marker == nil)
    #expect(noNewline.runs.isEmpty)
    #expect(document.lines[4].runs.first == DiffSyntaxRun(kind: .keyword, text: "let"))
    let truncated = document.lines[5]
    #expect(truncated.marker == "+")
    #expect(truncated.runs.map(\.text).joined() == truncated.content)
  }

  @Test("The plain document has the same lines as the coloured one without runs")
  func plainDocumentMatchesLineStructure() async {
    let diff = """
      diff --git a/A.swift b/A.swift
      @@ -1,2 +1,2 @@
       let a = 1
      -let b = 2
      +let b = 3
      """
    let plain = HighlightedDiffDocument.plain(unifiedDiff: diff)
    let highlighted = await HighlightedDiffDocument.highlighted(unifiedDiff: diff)

    #expect(plain.source == highlighted.source)
    #expect(plain.lines.map(\.id) == highlighted.lines.map(\.id))
    #expect(plain.lines.map(\.text) == highlighted.lines.map(\.text))
    #expect(plain.lines.map(\.marker) == highlighted.lines.map(\.marker))
    #expect(plain.lines.map(\.content) == highlighted.lines.map(\.content))
    #expect(plain.lines.map(\.presentation) == highlighted.lines.map(\.presentation))
    #expect(plain.lines.allSatisfy { $0.runs.isEmpty })
    #expect(highlighted.lines[2...].allSatisfy { !$0.runs.isEmpty })
  }

  @Test("Diff headers name the new-side path, quoted or not")
  func diffHeaderPaths() {
    #expect(
      DiffLanguageDetection.path(fromDiffHeader: "diff --git a/Sources/A.swift b/Sources/A.swift")
        == "Sources/A.swift"
    )
    #expect(
      DiffLanguageDetection.path(fromDiffHeader: "diff --git \"a/x y.md\" \"b/x y.md\"")
        == "x y.md"
    )
    #expect(DiffLanguageDetection.path(fromDiffHeader: "index 1111111..2222222 100644") == nil)
    #expect(DiffLanguageDetection.languageIdentifier(forPath: "Sources/A.swift") == "swift")
    #expect(DiffLanguageDetection.languageIdentifier(forPath: "docs/README.md") != nil)
    #expect(DiffLanguageDetection.languageIdentifier(forPath: "notes.txt") == nil)
  }

  @Test("Common file types Chroma does not name resolve through one it does")
  func aliasedFileTypesResolveToTheirLanguage() async {
    func language(_ path: String) -> String? {
      DiffLanguageDetection.languageIdentifier(forPath: path)
    }
    let pairs: [(alias: String, known: String)] = [
      ("scripts/run.mjs", "scripts/run.js"),
      ("lib/index.cjs", "lib/index.js"),
      ("src/types.mts", "src/types.ts"),
      ("src/types.cts", "src/types.ts"),
      ("Sources/Bridge/module.h", "Sources/Bridge/module.c"),
      ("stubs/typed.pyi", "stubs/typed.py"),
      ("lib/tasks/build.rake", "lib/tasks/build.rb"),
      ("Spedito.swiftinterface", "Spedito.swift"),
      ("docs/guide.mdx", "docs/guide.md"),
      ("App/Info.plist", "App/Info.xml"),
      ("App/Main.storyboard", "App/Main.xml"),
      ("Assets/icon.svg", "Assets/icon.xml"),
      ("App/App.entitlements", "App/App.xml"),
      ("Localizable.xcstrings", "Localizable.json"),
      ("tsconfig.jsonc", "tsconfig.json"),
      ("Gemfile", "deps.rb"),
      ("ios/Podfile", "ios/deps.rb"),
      ("fastlane/Fastfile", "fastlane/lanes.rb"),
      ("Package.resolved", "Package.json"),
      (".swift-format", "format.json"),
      (".zshrc", "shell.zsh"),
      (".bash_profile", "shell.bash"),
      ("Containerfile", "Dockerfile"),
      ("Cargo.lock", "Cargo.toml"),
      (".clang-format", "format.yaml"),
    ]
    for pair in pairs {
      let resolved = language(pair.alias)
      #expect(resolved != nil, "\(pair.alias) has no language")
      #expect(resolved == language(pair.known), "\(pair.alias) should match \(pair.known)")
    }
    #expect(language("README.MD") == language("README.md"))
    #expect(language("notes.txt") == nil)
    #expect(language("LICENSE") == nil)
    #expect(language(".gitignore") == nil)
    #expect(language("archive.tar.gz") == nil)

    let diff = """
      diff --git a/scripts/run.mjs b/scripts/run.mjs
      @@ -1 +1 @@
      +const answer = 42
      """
    let document = await HighlightedDiffDocument.highlighted(unifiedDiff: diff)
    #expect(document.lines[2].runs.first == DiffSyntaxRun(kind: .keyword, text: "const"))
    #expect(document.lines[2].runs.contains(DiffSyntaxRun(kind: .number, text: "42")))
  }

  @Test("Token colours keep readable contrast on every diff row tint in light and dark appearance")
  func tokenColoursKeepContrastInBothAppearances() {
    var light = EnvironmentValues()
    light.colorScheme = .light
    var dark = EnvironmentValues()
    dark.colorScheme = .dark

    // The resolver must actually follow the colour scheme, or the dark half
    // of this test would prove nothing.
    #expect(
      Color.primary.resolve(in: light).linearRed != Color.primary.resolve(in: dark).linearRed
    )

    for (environment, page) in [(light, SRGB.white), (dark, SRGB.darkTextBackground)] {
      let tints: [(name: String, color: Color?)] = [
        ("plain", nil), ("added", .green), ("removed", .red),
      ]
      for kind in DiffSyntaxTokenKind.allCases {
        let ink = SRGB(kind.color.resolve(in: environment))
        for tint in tints {
          var background = page
          if let tintColor = tint.color {
            background = SRGB(tintColor.resolve(in: environment)).blended(over: background, opacity: 0.08)
          }
          let ratio = ink.blended(over: background).contrastRatio(against: background)
          #expect(
            ratio >= 3,
            """
            \(kind) on a \(tint.name) row in \(environment.colorScheme) mode has contrast \(ratio) \
            (ink \(ink), background \(background))
            """
          )
        }
      }
    }
  }
}

/// Gamma-encoded sRGB with straight alpha. AppKit composites in this space,
/// so alpha blending happens here and only the luminance step linearises.
private struct SRGB: CustomStringConvertible {
  var red: Double
  var green: Double
  var blue: Double
  var opacity: Double = 1

  static let white = SRGB(red: 1, green: 1, blue: 1)
  /// `NSColor.textBackgroundColor` in dark appearance is #1E1E1E.
  static let darkTextBackground = SRGB(red: 30 / 255, green: 30 / 255, blue: 30 / 255)

  init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  init(_ resolved: Color.Resolved) {
    self.init(
      red: Double(resolved.red),
      green: Double(resolved.green),
      blue: Double(resolved.blue),
      opacity: Double(resolved.opacity)
    )
  }

  var description: String {
    String(format: "rgba(%.3f, %.3f, %.3f, %.2f)", red, green, blue, opacity)
  }

  func blended(over background: SRGB, opacity override: Double? = nil) -> SRGB {
    let alpha = override ?? opacity
    return SRGB(
      red: red * alpha + background.red * (1 - alpha),
      green: green * alpha + background.green * (1 - alpha),
      blue: blue * alpha + background.blue * (1 - alpha)
    )
  }

  private static func linear(_ channel: Double) -> Double {
    let clamped = min(max(channel, 0), 1)
    return clamped <= 0.04045 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
  }

  var luminance: Double {
    0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
  }

  func contrastRatio(against other: SRGB) -> Double {
    let lighter = max(luminance, other.luminance)
    let darker = min(luminance, other.luminance)
    return (lighter + 0.05) / (darker + 0.05)
  }
}
