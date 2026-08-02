import Foundation

public struct CodexRuntimeCandidate: Equatable, Sendable {
  public enum Source: String, Equatable, Sendable {
    case bundled
    case officialApplication = "official_application"
    case custom
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
  case missingRequiredFeature(name: String, path: String)

  public var errorDescription: String? {
    switch self {
    case .notFound:
      "Codex is not installed. Install the Codex app or add another Codex installation."
    case .couldNotInspect(let path):
      "Spedito could not inspect the Codex installation at \(path)."
    case .missingRequiredFeature(let name, _):
      "This Codex installation does not support the required \(name) capability."
    }
  }
}

public struct CodexRuntimeResolver: Sendable {
  public static let requiredFeatures: Set<String> = [
    CodexPermissionProfiles.requestPermissionsFeature
  ]

  public let requiredFeatures: Set<String>

  public init(requiredFeatures: Set<String> = Self.requiredFeatures) {
    self.requiredFeatures = requiredFeatures
  }

  public func resolve(candidates: [CodexRuntimeCandidate]) throws -> CodexRuntimeDescriptor {
    var firstInspectionError: CodexRuntimeError?

    for candidate in candidates {
      guard FileManager.default.isExecutableFile(atPath: candidate.executableURL.path) else {
        continue
      }

      do {
        let version = try inspectVersion(at: candidate.executableURL)
        let enabledFeatures = try inspectEnabledFeatures(at: candidate.executableURL)
        if let missingFeature = requiredFeatures.subtracting(enabledFeatures).sorted().first {
          if firstInspectionError == nil {
            firstInspectionError = .missingRequiredFeature(
              name: missingFeature,
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
      } catch let error as CodexRuntimeError {
        if firstInspectionError == nil {
          firstInspectionError = error
        }
      } catch {
        if firstInspectionError == nil {
          firstInspectionError = .couldNotInspect(
            candidate.executableURL.path
          )
        }
      }
    }

    if let firstInspectionError { throw firstInspectionError }
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
