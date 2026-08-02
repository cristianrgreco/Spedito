import Foundation
import Testing
@testable import SpeditoApp

@Suite("App model startup")
@MainActor
struct AppModelStartupTests {
  @Test("Onboarding stays hidden until the initial store load resolves")
  func initialLoadingState() async {
    let model = AppModel(store: nil)

    #expect(model.isLoading)

    await model.reload()

    #expect(!model.isLoading)
  }

  @Test("Legacy application data moves to the Spedito support directory")
  func legacyApplicationSupportMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-app-support-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyURL = root.appendingPathComponent("StoryPointless", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
    let markerURL = legacyURL.appendingPathComponent("existing-product-data")
    try Data("preserved".utf8).write(to: markerURL)

    let migratedURL = try AppModel.migratedApplicationSupportURL(in: root)

    #expect(migratedURL.lastPathComponent == "Spedito")
    #expect(FileManager.default.fileExists(atPath: migratedURL.appendingPathComponent("existing-product-data").path))
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  }

  @Test("Legacy preferences copy only when Spedito has no value")
  func legacyDefaultsMigration() throws {
    let currentDomain = "io.spedito.tests.\(UUID())"
    let legacyDomain = "com.storypointless.tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: currentDomain))
    defer {
      defaults.removePersistentDomain(forName: currentDomain)
      defaults.removePersistentDomain(forName: legacyDomain)
    }
    defaults.setPersistentDomain(
      [
        "selectedProductID": "legacy-product",
        "codex.selectedInstallationID": "legacy-codex",
      ],
      forName: legacyDomain
    )
    defaults.set("current-product", forKey: "selectedProductID")

    AppModel.migrateLegacyDefaults(from: legacyDomain, to: defaults)

    #expect(defaults.string(forKey: "selectedProductID") == "current-product")
    #expect(defaults.string(forKey: "codex.selectedInstallationID") == "legacy-codex")

    defaults.removeObject(forKey: "codex.selectedInstallationID")
    AppModel.migrateLegacyDefaults(from: legacyDomain, to: defaults)
    #expect(defaults.string(forKey: "codex.selectedInstallationID") == nil)
  }
}
