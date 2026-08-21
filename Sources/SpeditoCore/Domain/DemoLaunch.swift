import Foundation

public enum DemoPresentationKind: String, Codable, CaseIterable, Sendable {
  case browser
  case staticWeb = "static_web"
  case macApplication = "mac_application"
  case artifact
  case commandOutput = "command_output"

  public var title: String {
    switch self {
    case .browser: "Web demo"
    case .staticWeb: "Interactive prototype"
    case .macApplication: "macOS app"
    case .artifact: "Review artifact"
    case .commandOutput: "Demo result"
    }
  }
}

public struct DemoCommand: Codable, Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let workingDirectory: String
  public let timeoutSeconds: Int

  public init(
    executable: String,
    arguments: [String] = [],
    workingDirectory: String = ".",
    timeoutSeconds: Int = 180
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.timeoutSeconds = timeoutSeconds
  }
}

public enum DemoReadinessKind: String, Codable, CaseIterable, Sendable {
  case http
  case process
}

public struct DemoReadinessCheck: Codable, Equatable, Sendable {
  public let kind: DemoReadinessKind
  public let path: String?
  public let timeoutSeconds: Int

  public init(
    kind: DemoReadinessKind,
    path: String? = nil,
    timeoutSeconds: Int = 30
  ) {
    self.kind = kind
    self.path = path
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct DemoPresentation: Codable, Equatable, Sendable {
  public let kind: DemoPresentationKind
  public let path: String?

  public init(kind: DemoPresentationKind, path: String? = nil) {
    self.kind = kind
    self.path = path
  }
}

public struct DemoLaunchSpecification: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let title: String
  public let preparationCommands: [DemoCommand]
  public let launchCommand: DemoCommand?
  public let portEnvironmentVariable: String?
  public let readiness: DemoReadinessCheck?
  public let presentation: DemoPresentation

  public init(
    schemaVersion: Int = 1,
    title: String,
    preparationCommands: [DemoCommand] = [],
    launchCommand: DemoCommand? = nil,
    portEnvironmentVariable: String? = nil,
    readiness: DemoReadinessCheck? = nil,
    presentation: DemoPresentation
  ) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.preparationCommands = preparationCommands
    self.launchCommand = launchCommand
    self.portEnvironmentVariable = portEnvironmentVariable
    self.readiness = readiness
    self.presentation = presentation
  }
}

public struct AcceptedAppLaunch: Equatable, Sendable {
  public let candidate: CandidateRevision
  public let specification: DemoLaunchSpecification

  public init(candidate: CandidateRevision, specification: DemoLaunchSpecification) {
    self.candidate = candidate
    self.specification = specification
  }
}

public enum AcceptedAppLaunchPolicy {
  public static func latest(in candidates: [CandidateRevision]) -> AcceptedAppLaunch? {
    candidates.compactMap(launch(for:)).max(by: isEarlier)
  }

  public static func all(in candidates: [CandidateRevision]) -> [AcceptedAppLaunch] {
    candidates.compactMap(launch(for:)).sorted { lhs, rhs in
      isEarlier(rhs, lhs)
    }
  }

  private static func launch(for candidate: CandidateRevision) -> AcceptedAppLaunch? {
    guard candidate.status == .accepted, candidate.integratedSHA != nil,
      let result = try? CodexTicketExecutor.decode(candidate.executionResultJSON),
      let specification = result.demo,
      specification.presentation.kind == .browser
        || specification.presentation.kind == .staticWeb
        || specification.presentation.kind == .macApplication,
      (try? DemoLaunchSpecificationValidator.validate(specification)) != nil
    else {
      return nil
    }
    return AcceptedAppLaunch(candidate: candidate, specification: specification)
  }

  private static func isEarlier(_ lhs: AcceptedAppLaunch, _ rhs: AcceptedAppLaunch) -> Bool {
    if lhs.candidate.updatedAt != rhs.candidate.updatedAt {
      return lhs.candidate.updatedAt < rhs.candidate.updatedAt
    }
    if lhs.candidate.createdAt != rhs.candidate.createdAt {
      return lhs.candidate.createdAt < rhs.candidate.createdAt
    }
    return lhs.candidate.id.uuidString < rhs.candidate.id.uuidString
  }
}

public struct ImportedAppLaunch: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let productID: UUID
  public let revisionSHA: String
  public let specification: DemoLaunchSpecification
  public let evidence: [RepositoryEvidence]
  public let publishedAt: Date

  public init(
    id: UUID,
    runID: UUID,
    productID: UUID,
    revisionSHA: String,
    specification: DemoLaunchSpecification,
    evidence: [RepositoryEvidence],
    publishedAt: Date
  ) {
    self.id = id
    self.runID = runID
    self.productID = productID
    self.revisionSHA = revisionSHA
    self.specification = specification
    self.evidence = evidence
    self.publishedAt = publishedAt
  }
}

public enum AppVersion: Identifiable, Equatable, Sendable {
  case imported(ImportedAppLaunch)
  case accepted(AcceptedAppLaunch)

  public var id: UUID {
    switch self {
    case .imported(let launch):
      launch.id
    case .accepted(let launch):
      launch.candidate.id
    }
  }

  public var productID: UUID {
    switch self {
    case .imported(let launch):
      launch.productID
    case .accepted(let launch):
      launch.candidate.productID
    }
  }

  public var revisionSHA: String {
    switch self {
    case .imported(let launch):
      launch.revisionSHA
    case .accepted(let launch):
      launch.candidate.integratedSHA ?? ""
    }
  }

  public var sessionSourceKind: DemoSessionSourceKind {
    switch self {
    case .imported:
      .importedRepository
    case .accepted:
      .acceptedCandidate
    }
  }
  public var specification: DemoLaunchSpecification {
    switch self {
    case .imported(let launch):
      launch.specification
    case .accepted(let launch):
      launch.specification
    }
  }

  public var acceptedAt: Date {
    switch self {
    case .imported(let launch):
      launch.publishedAt
    case .accepted(let launch):
      launch.candidate.updatedAt
    }
  }
}

public enum AppVersionPolicy {
  public static func all(
    imported: ImportedAppLaunch?,
    acceptedCandidates: [CandidateRevision]
  ) -> [AppVersion] {
    var versions = AcceptedAppLaunchPolicy.all(in: acceptedCandidates).map(AppVersion.accepted)
    if let imported {
      versions.append(.imported(imported))
    }
    return versions.sorted { lhs, rhs in
      if lhs.acceptedAt != rhs.acceptedAt {
        return lhs.acceptedAt > rhs.acceptedAt
      }
      return lhs.id.uuidString > rhs.id.uuidString
    }
  }
}

public enum DemoSessionStatus: String, Codable, CaseIterable, Sendable {
  case preparing
  case starting
  case ready
  case failed
  case stopped
}

public enum DemoSessionSourceKind: String, Codable, CaseIterable, Sendable {
  case acceptedCandidate = "accepted_candidate"
  case importedRepository = "imported_repository"
}

public struct DemoSession: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sourceKind: DemoSessionSourceKind
  public let launchID: UUID
  public var status: DemoSessionStatus
  public var previewWorktreePath: String?
  public var allocatedPort: Int?
  public var output: String?
  public var errorMessage: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sourceKind: DemoSessionSourceKind = .acceptedCandidate,
    launchID: UUID,
    status: DemoSessionStatus,
    previewWorktreePath: String? = nil,
    allocatedPort: Int? = nil,
    output: String? = nil,
    errorMessage: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.sourceKind = sourceKind
    self.launchID = launchID
    self.status = status
    self.previewWorktreePath = previewWorktreePath
    self.allocatedPort = allocatedPort
    self.output = output
    self.errorMessage = errorMessage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum DemoLaunchValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let detail):
      "The demo could not be prepared safely: \(detail)"
    }
  }
}

public enum DemoArtifactPolicy {
  public static let allowedExtensions: Set<String> = [
    "csv", "gif", "jpeg", "jpg", "json", "log", "markdown", "md", "pdf", "png", "txt",
    "webp",
  ]

  public static func validatePath(_ path: String) throws {
    let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard allowedExtensions.contains(pathExtension) else {
      throw DemoLaunchValidationError.invalid(
        "review artifacts must use an inert text, data, image, or PDF format."
      )
    }
  }

  public static func validateExistingFile(
    at url: URL,
    fileManager: FileManager = .default
  ) throws {
    try validatePath(url.path)
    let values = try url.resourceValues(
      forKeys: [.isAliasFileKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard
      values.isRegularFile == true,
      values.isAliasFile != true,
      values.isPackage != true,
      values.isSymbolicLink != true,
      permissions & 0o111 == 0
    else {
      throw DemoLaunchValidationError.invalid(
        "review artifacts must be regular, non-executable files."
      )
    }
  }
}

public enum DemoLaunchSpecificationValidator {
  public static func validate(_ specification: DemoLaunchSpecification) throws {
    guard specification.schemaVersion == 1 else {
      throw DemoLaunchValidationError.invalid(
        "demo recipe version \(specification.schemaVersion) is not supported."
      )
    }
    guard !specification.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DemoLaunchValidationError.invalid("the demo needs a short owner-facing title.")
    }
    guard specification.preparationCommands.count <= 6 else {
      throw DemoLaunchValidationError.invalid(
        "a demo can contain at most six preparation commands."
      )
    }
    for command in specification.preparationCommands {
      try validate(command)
    }
    if let launchCommand = specification.launchCommand {
      try validate(launchCommand)
    }
    if let name = specification.portEnvironmentVariable {
      try validateEnvironmentVariable(name)
    }
    if let readiness = specification.readiness {
      guard (1...120).contains(readiness.timeoutSeconds) else {
        throw DemoLaunchValidationError.invalid(
          "readiness must time out between 1 and 120 seconds."
        )
      }
      switch readiness.kind {
      case .http:
        try validateLoopbackPath(readiness.path ?? "/", describedAs: "readiness paths")
      case .process:
        guard readiness.path == nil else {
          throw DemoLaunchValidationError.invalid(
            "process readiness cannot contain a URL path."
          )
        }
      }
    }

    switch specification.presentation.kind {
    case .browser:
      guard specification.launchCommand != nil else {
        throw DemoLaunchValidationError.invalid(
          "a web demo needs a managed service command."
        )
      }
      guard specification.readiness?.kind == .http else {
        throw DemoLaunchValidationError.invalid(
          "a web demo needs an HTTP readiness check."
        )
      }
      try validateLoopbackPath(
        specification.presentation.path ?? "/",
        describedAs: "browser paths"
      )
    case .staticWeb:
      guard
        specification.preparationCommands.isEmpty,
        specification.launchCommand == nil,
        specification.portEnvironmentVariable == nil,
        specification.readiness == nil
      else {
        throw DemoLaunchValidationError.invalid(
          "a static web prototype is served by Spedito and cannot declare commands, a port, or readiness."
        )
      }
      guard let path = specification.presentation.path else {
        throw DemoLaunchValidationError.invalid(
          "the prototype needs a workspace-relative directory containing index.html."
        )
      }
      try validateRelativePath(path, allowsCurrentDirectory: false)
    case .macApplication:
      guard
        specification.launchCommand == nil,
        specification.portEnvironmentVariable == nil,
        specification.readiness == nil
      else {
        throw DemoLaunchValidationError.invalid(
          "macOS app demos may build during preparation, but are opened directly without a service command, port, or readiness check."
        )
      }
      guard let path = specification.presentation.path else {
        throw DemoLaunchValidationError.invalid(
          "the demo needs a workspace-relative application path."
        )
      }
      try validateRelativePath(path, allowsCurrentDirectory: false)
    case .artifact:
      guard
        specification.preparationCommands.isEmpty,
        specification.launchCommand == nil,
        specification.portEnvironmentVariable == nil,
        specification.readiness == nil
      else {
        throw DemoLaunchValidationError.invalid(
          "review artifacts must already exist and cannot declare commands, a port, or readiness."
        )
      }
      guard let path = specification.presentation.path else {
        throw DemoLaunchValidationError.invalid(
          "the demo needs a workspace-relative artifact path."
        )
      }
      try validateRelativePath(path, allowsCurrentDirectory: false)
      try DemoArtifactPolicy.validatePath(path)
    case .commandOutput:
      guard specification.launchCommand != nil else {
        throw DemoLaunchValidationError.invalid(
          "a result demo needs a command whose output can be shown."
        )
      }
      guard specification.readiness == nil else {
        throw DemoLaunchValidationError.invalid(
          "a result command exits when complete and cannot declare a readiness check."
        )
      }
      guard specification.portEnvironmentVariable == nil else {
        throw DemoLaunchValidationError.invalid(
          "a result command cannot declare a managed service port."
        )
      }
      guard specification.presentation.path == nil else {
        throw DemoLaunchValidationError.invalid(
          "a result demo cannot contain an artifact path."
        )
      }
    }
  }

  public static func resolveWorkspacePath(
    _ path: String,
    in workspaceURL: URL
  ) throws -> URL {
    try validateRelativePath(path, allowsCurrentDirectory: true)
    let base = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    let basePrefix = base.path.hasSuffix("/") ? base.path : "\(base.path)/"
    var target = base
    for component in path.split(separator: "/").map(String.init) where component != "." {
      target.appendPathComponent(component)
      if FileManager.default.fileExists(atPath: target.path) {
        target = target.standardizedFileURL.resolvingSymlinksInPath()
      } else {
        target = target.standardizedFileURL
      }
      guard target.path == base.path || target.path.hasPrefix(basePrefix) else {
        throw DemoLaunchValidationError.invalid(
          "the path “\(path)” points outside the reviewed preview."
        )
      }
    }
    return target
  }

  private static func validate(_ command: DemoCommand) throws {
    let executable = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !executable.isEmpty, !executable.contains("\0") else {
      throw DemoLaunchValidationError.invalid("a demo command has no executable.")
    }
    let forbiddenExecutables = [
      "sh", "bash", "zsh", "fish", "osascript",
      "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/osascript",
    ]
    guard !forbiddenExecutables.contains(executable) else {
      throw DemoLaunchValidationError.invalid(
        "shell and AppleScript interpreters are not accepted as demo executables; invoke a real executable or executable workspace script directly."
      )
    }
    guard command.arguments.count <= 64 else {
      throw DemoLaunchValidationError.invalid(
        "a demo command can contain at most 64 arguments."
      )
    }
    guard command.arguments.allSatisfy({ !$0.contains("\0") }) else {
      throw DemoLaunchValidationError.invalid("a demo argument contains invalid data.")
    }
    try validateRelativePath(command.workingDirectory, allowsCurrentDirectory: true)
    guard (1...900).contains(command.timeoutSeconds) else {
      throw DemoLaunchValidationError.invalid(
        "commands must time out between 1 and 900 seconds."
      )
    }
  }

  private static func validateEnvironmentVariable(_ name: String) throws {
    let characters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    guard
      !name.isEmpty,
      name.count <= 64,
      name.unicodeScalars.allSatisfy(characters.contains),
      name.first?.isNumber != true
    else {
      throw DemoLaunchValidationError.invalid(
        "the port environment variable name is invalid."
      )
    }
    let forbidden = [
      "PATH", "HOME", "SHELL", "TMPDIR", "DYLD_LIBRARY_PATH",
      "DYLD_INSERT_LIBRARIES", "PYTHONPATH", "NODE_OPTIONS",
    ]
    guard !forbidden.contains(name) else {
      throw DemoLaunchValidationError.invalid(
        "the port cannot be injected through the protected \(name) variable."
      )
    }
  }

  private static func validateRelativePath(
    _ path: String,
    allowsCurrentDirectory: Bool
  ) throws {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      !trimmed.hasPrefix("/"),
      !trimmed.hasPrefix("~"),
      !trimmed.contains("\0")
    else {
      throw DemoLaunchValidationError.invalid(
        "demo paths must be relative to the reviewed preview."
      )
    }
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains("..") else {
      throw DemoLaunchValidationError.invalid(
        "demo paths cannot leave the reviewed preview."
      )
    }
    if !allowsCurrentDirectory, trimmed == "." {
      throw DemoLaunchValidationError.invalid("the demo artifact path is incomplete.")
    }
  }

  /// Every demo kind may declare an HTTP readiness check, so this is not only
  /// reached for browser demos. A native Mac app whose readiness path was
  /// malformed used to tell the product owner about browser paths, which is not
  /// a sentence that means anything about the product they asked for.
  private static func validateLoopbackPath(
    _ path: String,
    describedAs subject: String
  ) throws {
    guard
      path.hasPrefix("/"),
      !path.hasPrefix("//"),
      !path.contains("\0"),
      !path.contains("\r"),
      !path.contains("\n")
    else {
      throw DemoLaunchValidationError.invalid(
        "\(subject) must be a loopback URL path beginning with “/”."
      )
    }
    let components = URLComponents(string: path)
    guard components?.scheme == nil, components?.host == nil else {
      throw DemoLaunchValidationError.invalid(
        "a demo can open only a Spedito-managed loopback URL."
      )
    }
  }
}
