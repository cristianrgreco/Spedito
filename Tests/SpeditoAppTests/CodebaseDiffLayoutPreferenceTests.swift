import Foundation
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
