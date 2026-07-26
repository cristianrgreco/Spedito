import Foundation

public struct CodexRuntimeCandidate: Equatable, Sendable {
  public enum Source: String, Equatable, Sendable {
    case bundled
    case developmentFixture = "development_fixture"
  }

  public let executableURL: URL
  public let source: Source

  public init(executableURL: URL, source: Source) {
    self.executableURL = executableURL
    self.source = source
  }
}

public struct CodexRuntimeDescriptor: Equatable, Sendable {
  public let executableURL: URL
  public let version: String
  public let source: CodexRuntimeCandidate.Source

  public init(executableURL: URL, version: String, source: CodexRuntimeCandidate.Source) {
    self.executableURL = executableURL
    self.version = version
    self.source = source
  }
}

public enum CodexRuntimeError: Error, Equatable, LocalizedError, Sendable {
  case notFound
  case couldNotInspect(String)
  case incompatible(expected: String, actual: String, path: String)
  case missingRequiredFeature(name: String, path: String)

  public var errorDescription: String? {
    switch self {
    case .notFound:
      "The StoryPointless Codex runtime is not installed."
    case .couldNotInspect(let path):
      "Could not inspect the Codex runtime at \(path)."
    case .incompatible(let expected, let actual, _):
      "Codex runtime \(actual) is incompatible with this build; expected \(expected)."
    case .missingRequiredFeature(let name, _):
      "The StoryPointless Codex runtime does not support the required \(name) capability."
    }
  }
}

public struct CodexRuntimeResolver: Sendable {
  public static let pinnedVersion = "0.144.0-alpha.4"

  public let expectedVersion: String

  public init(expectedVersion: String = Self.pinnedVersion) {
    self.expectedVersion = expectedVersion
  }

  public func resolve(candidates: [CodexRuntimeCandidate]) throws -> CodexRuntimeDescriptor {
    var firstIncompatible: CodexRuntimeError?

    for candidate in candidates {
      guard FileManager.default.isExecutableFile(atPath: candidate.executableURL.path) else {
        continue
      }

      let version = try inspectVersion(at: candidate.executableURL)
      guard version == expectedVersion else {
        if firstIncompatible == nil {
          firstIncompatible = .incompatible(
            expected: expectedVersion,
            actual: version,
            path: candidate.executableURL.path
          )
        }
        continue
      }
      let enabledFeatures = try inspectEnabledFeatures(at: candidate.executableURL)
      guard enabledFeatures.contains(CodexPermissionProfiles.requestPermissionsFeature) else {
        if firstIncompatible == nil {
          firstIncompatible = .missingRequiredFeature(
            name: CodexPermissionProfiles.requestPermissionsFeature,
            path: candidate.executableURL.path
          )
        }
        continue
      }

      return CodexRuntimeDescriptor(
        executableURL: candidate.executableURL,
        version: version,
        source: candidate.source
      )
    }

    if let firstIncompatible { throw firstIncompatible }
    throw CodexRuntimeError.notFound
  }

  public func parseVersionOutput(_ output: String) -> String? {
    output
      .split(whereSeparator: \Character.isWhitespace)
      .last
      .map(String.init)
  }

  public func parseEnabledFeatures(_ output: String) -> Set<String> {
    Set(
      output
        .split(whereSeparator: \.isNewline)
        .compactMap { line in
          let fields = line.split(whereSeparator: \.isWhitespace)
          guard fields.count >= 2, fields.last == "true" else { return nil }
          return String(fields[0])
        }
    )
  }

  private func inspectVersion(at executableURL: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = ["--version"]
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw CodexRuntimeError.couldNotInspect(executableURL.path)
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard
      process.terminationStatus == 0,
      let text = String(data: data, encoding: .utf8),
      let version = parseVersionOutput(text)
    else {
      throw CodexRuntimeError.couldNotInspect(executableURL.path)
    }
    return version
  }

  private func inspectEnabledFeatures(at executableURL: URL) throws -> Set<String> {
    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = [
      "-c",
      CodexPermissionProfiles.requestPermissionsFeatureOverride,
      "features",
      "list",
    ]
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw CodexRuntimeError.couldNotInspect(executableURL.path)
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard
      process.terminationStatus == 0,
      let text = String(data: data, encoding: .utf8)
    else {
      throw CodexRuntimeError.couldNotInspect(executableURL.path)
    }
    return parseEnabledFeatures(text)
  }
}
