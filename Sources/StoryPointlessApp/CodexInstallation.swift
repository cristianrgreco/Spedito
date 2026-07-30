import AppKit
import Foundation
import StoryPointlessCore

struct CodexInstallation: Identifiable, Equatable, Sendable {
  enum Kind: String, Codable, Equatable, Sendable {
    case officialApplication
    case bundled
    case custom
  }

  static let officialApplicationID = "official-codex-application"
  static let bundledID = "bundled-codex"

  let id: String
  let name: String
  let executableURL: URL
  let kind: Kind

  var runtimeCandidate: CodexRuntimeCandidate {
    let source: CodexRuntimeCandidate.Source =
      switch kind {
      case .officialApplication: .officialApplication
      case .bundled: .bundled
      case .custom: .custom
      }
    return CodexRuntimeCandidate(executableURL: executableURL, source: source)
  }
}

struct StoredCodexInstallation: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let executablePath: String

  var installation: CodexInstallation {
    CodexInstallation(
      id: id,
      name: name,
      executableURL: URL(fileURLWithPath: executablePath),
      kind: .custom
    )
  }
}

struct CodexInstallationPreferences {
  private static let customInstallationsKey = "codex.customInstallations"
  private static let selectedInstallationKey = "codex.selectedInstallationID"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func customInstallations() -> [StoredCodexInstallation] {
    guard
      let data = defaults.data(forKey: Self.customInstallationsKey),
      let installations = try? JSONDecoder().decode(
        [StoredCodexInstallation].self,
        from: data
      )
    else {
      return []
    }
    return installations
  }

  func saveCustomInstallations(_ installations: [StoredCodexInstallation]) {
    guard let data = try? JSONEncoder().encode(installations) else { return }
    defaults.set(data, forKey: Self.customInstallationsKey)
  }

  func selectedInstallationID() -> String? {
    defaults.string(forKey: Self.selectedInstallationKey)
  }

  func saveSelectedInstallationID(_ id: String?) {
    if let id {
      defaults.set(id, forKey: Self.selectedInstallationKey)
    } else {
      defaults.removeObject(forKey: Self.selectedInstallationKey)
    }
  }
}

enum CodexInstallationDiscovery {
  static let officialBundleIdentifier = "com.openai.codex"

  static func discover(
    officialApplicationURL: URL?,
    bundledExecutableURL: URL?,
    customInstallations: [StoredCodexInstallation]
  ) -> [CodexInstallation] {
    var installations: [CodexInstallation] = []

    if let officialApplicationURL,
      Bundle(url: officialApplicationURL)?.bundleIdentifier == officialBundleIdentifier
    {
      let executableURL = executableURL(forApplication: officialApplicationURL)
      installations.append(
        CodexInstallation(
          id: CodexInstallation.officialApplicationID,
          name: "Codex app",
          executableURL: executableURL,
          kind: .officialApplication
        )
      )
    }

    if let bundledExecutableURL {
      installations.append(
        CodexInstallation(
          id: CodexInstallation.bundledID,
          name: "Included Codex",
          executableURL: bundledExecutableURL,
          kind: .bundled
        )
      )
    }

    let occupiedPaths = Set(
      installations.map { normalizedPath($0.executableURL) }
    )
    var seenPaths = occupiedPaths
    for stored in customInstallations {
      let installation = stored.installation
      let path = normalizedPath(installation.executableURL)
      guard seenPaths.insert(path).inserted else { continue }
      installations.append(installation)
    }

    return installations
  }

  static func executableURL(forSelection selectionURL: URL) -> URL {
    if selectionURL.pathExtension.lowercased() == "app" {
      return executableURL(forApplication: selectionURL)
    }
    return selectionURL
  }

  static func executableURL(forApplication applicationURL: URL) -> URL {
    applicationURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("codex", isDirectory: false)
  }

  static func customInstallation(
    forSelection selectionURL: URL,
    existing: [StoredCodexInstallation]
  ) -> StoredCodexInstallation {
    let executableURL = executableURL(forSelection: selectionURL)
    if let match = existing.first(where: {
      normalizedPath(URL(fileURLWithPath: $0.executablePath))
        == normalizedPath(executableURL)
    }) {
      return match
    }

    return StoredCodexInstallation(
      id: UUID().uuidString,
      name: customDisplayName(selectionURL: selectionURL, executableURL: executableURL),
      executablePath: executableURL.path
    )
  }

  private static func customDisplayName(selectionURL: URL, executableURL: URL) -> String {
    if selectionURL.pathExtension.lowercased() == "app" {
      let bundleName =
        Bundle(url: selectionURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName")
          as? String
      return bundleName ?? selectionURL.deletingPathExtension().lastPathComponent
    }

    let parent = executableURL.deletingLastPathComponent().lastPathComponent
    return parent.isEmpty
      ? executableURL.lastPathComponent
      : "\(executableURL.lastPathComponent) — \(parent)"
  }

  private static func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}
