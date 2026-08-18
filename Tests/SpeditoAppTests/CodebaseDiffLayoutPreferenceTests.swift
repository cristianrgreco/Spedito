import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Codebase diff layout preference")
struct CodebaseDiffLayoutPreferenceTests {
  @Test("The default layout is Auto")
  func defaultsToAutomatic() throws {
    try withDefaults { defaults in
      #expect(CodebaseDiffLayoutPreference.load(defaults: defaults) == .automatic)
    }
  }

  @Test("Every layout choice is persisted")
  func persistsEveryLayout() throws {
    try withDefaults { defaults in
      for layout in CodebaseDiffLayout.allCases {
        CodebaseDiffLayoutPreference.save(layout, defaults: defaults)

        #expect(CodebaseDiffLayoutPreference.load(defaults: defaults) == layout)
      }
    }
  }

  @Test("An unrecognized stored layout falls back to Auto")
  func invalidLayoutFallsBackToAutomatic() throws {
    try withDefaults { defaults in
      defaults.set("unknown-layout", forKey: "codebaseDiffLayout")

      #expect(CodebaseDiffLayoutPreference.load(defaults: defaults) == .automatic)
    }
  }

  @Test("Unified diff lines distinguish changes from file headers")
  func classifiesUnifiedDiffLines() {
    #expect(UnifiedDiffLinePresentation(line: "+added") == .added)
    #expect(UnifiedDiffLinePresentation(line: "-removed") == .removed)
    #expect(UnifiedDiffLinePresentation(line: "@@ -1 +1 @@") == .hunk)
    #expect(UnifiedDiffLinePresentation(line: "+++ b/File.swift") == .metadata)
    #expect(UnifiedDiffLinePresentation(line: "--- a/File.swift") == .metadata)
    #expect(UnifiedDiffLinePresentation(line: " unchanged") == .context)
  }

  @Test("[V03] File selection and diff layout resolve from one bounded presentation policy")
  func v03FileSelectionAndDiffLayoutResolution() throws {
    let files = [
      GitChangedFile(status: "M", path: "Sources/Feature.swift"),
      GitChangedFile(status: "A", path: "Tests/FeatureTests.swift"),
    ]
    #expect(
      CodebaseFileSelection.resolved(
        currentPath: "Sources/Feature.swift",
        files: files
      ) == "Sources/Feature.swift"
    )
    #expect(
      CodebaseFileSelection.resolved(
        currentPath: "Removed.swift",
        files: files
      ) == nil
    )
    #expect(CodebaseDiffLayout.automatic.resolved(for: 899) == .unified)
    #expect(CodebaseDiffLayout.automatic.resolved(for: 900) == .split)
    #expect(CodebaseDiffLayout.unified.resolved(for: 1_400) == .unified)
    #expect(CodebaseDiffLayout.split.resolved(for: 500) == .split)

    try withDefaults { defaults in
      CodebaseDiffLayoutPreference.save(.split, defaults: defaults)
      #expect(CodebaseDiffLayoutPreference.load(defaults: defaults) == .split)
    }
  }

  private func withDefaults(
    _ operation: (UserDefaults) throws -> Void
  ) throws {
    let suiteName = "CodebaseDiffLayoutPreferenceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    try operation(defaults)
  }
}
