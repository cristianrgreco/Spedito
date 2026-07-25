import Foundation

public enum DemoPresentationKind: String, Codable, CaseIterable, Sendable {
  case browser
  case macApplication = "mac_application"
  case artifact
  case commandOutput = "command_output"

  public var title: String {
    switch self {
    case .browser: "Web demo"
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

public enum DemoSessionStatus: String, Codable, CaseIterable, Sendable {
  case preparing
  case starting
  case ready
  case failed
  case stopped
}

public struct DemoSession: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let candidateRevisionID: UUID
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
    candidateRevisionID: UUID,
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
    self.candidateRevisionID = candidateRevisionID
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
        try validateBrowserPath(readiness.path ?? "/")
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
      try validateBrowserPath(specification.presentation.path ?? "/")
    case .macApplication, .artifact:
      guard specification.launchCommand == nil else {
        throw DemoLaunchValidationError.invalid(
          "app and artifact demos are opened directly and cannot declare a service command."
        )
      }
      guard let path = specification.presentation.path else {
        throw DemoLaunchValidationError.invalid(
          "the demo needs a workspace-relative artifact path."
        )
      }
      try validateRelativePath(path, allowsCurrentDirectory: false)
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
        "shell and AppleScript command strings are not accepted."
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

  private static func validateBrowserPath(_ path: String) throws {
    guard
      path.hasPrefix("/"),
      !path.hasPrefix("//"),
      !path.contains("\0"),
      !path.contains("\r"),
      !path.contains("\n")
    else {
      throw DemoLaunchValidationError.invalid(
        "browser paths must be a loopback URL path beginning with “/”."
      )
    }
    let components = URLComponents(string: path)
    guard components?.scheme == nil, components?.host == nil else {
      throw DemoLaunchValidationError.invalid(
        "browser demos can open only a StoryPointless-managed loopback URL."
      )
    }
  }
}
