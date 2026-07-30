import Foundation
import Testing

@testable import StoryPointlessApp

@Suite("Codex installation selection", .serialized)
struct CodexInstallationTests {
  @Test("Official application discovery and custom installations are ordered and deduplicated")
  func discovery() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Codex.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(
      at: resourcesURL,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let info: [String: Any] = [
      "CFBundleIdentifier": CodexInstallationDiscovery.officialBundleIdentifier,
      "CFBundleName": "Codex",
      "CFBundlePackageType": "APPL",
      "CFBundleVersion": "1",
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

    let officialExecutableURL =
      CodexInstallationDiscovery.executableURL(forApplication: applicationURL)
    try Data().write(to: officialExecutableURL)
    let customURL = temporaryDirectory.appendingPathComponent("custom-codex")
    try Data().write(to: customURL)

    let installations = CodexInstallationDiscovery.discover(
      officialApplicationURL: applicationURL,
      bundledExecutableURL: nil,
      customInstallations: [
        StoredCodexInstallation(
          id: "duplicate",
          name: "Duplicate",
          executablePath: officialExecutableURL.path
        ),
        StoredCodexInstallation(
          id: "custom",
          name: "Custom Codex",
          executablePath: customURL.path
        ),
      ]
    )

    #expect(installations.map(\.id) == [
      CodexInstallation.officialApplicationID,
      "custom",
    ])
  }

  @Test("Custom installations and the selected installation are persisted")
  func preferencesRoundTrip() throws {
    let suiteName = "CodexInstallationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let preferences = CodexInstallationPreferences(defaults: defaults)
    let stored = StoredCodexInstallation(
      id: "custom",
      name: "Custom Codex",
      executablePath: "/opt/example/codex"
    )

    preferences.saveCustomInstallations([stored])
    preferences.saveSelectedInstallationID(stored.id)

    #expect(preferences.customInstallations() == [stored])
    #expect(preferences.selectedInstallationID() == stored.id)
  }
}
