import Foundation

public enum CodexPermissionProfiles {
  public static let readOnly = ":read-only"
  public static let delivery = "storypointless-delivery"
  public static let demo = "storypointless-demo"
  public static let requestPermissionsFeature = "request_permissions_tool"
  public static let requestPermissionsFeatureOverride =
    "features.\(requestPermissionsFeature)=true"
  public static let agentProcessEnvironment = [
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_PAGER": "cat",
  ]

  public static let appServerArguments = [
    "-c",
    #"default_permissions=":read-only""#,
    "-c",
    requestPermissionsFeatureOverride,
    "-c",
    deliveryProfileOverride,
    "-c",
    demoProfileOverride(workspaceRootPath: nil),
    "app-server",
    "--listen",
    "stdio://",
  ]

  public static func appServerArguments(demoWorkspaceRoot: URL) -> [String] {
    [
      "-c",
      #"default_permissions=":read-only""#,
      "-c",
      requestPermissionsFeatureOverride,
      "-c",
      deliveryProfileOverride,
      "-c",
      demoProfileOverride(
        workspaceRootPath: demoWorkspaceRoot.standardizedFileURL.path
      ),
      "app-server",
      "--listen",
      "stdio://",
    ]
  }

  private static let credentialDenyEntries = #"""
    "~/.codex"="deny",
    "~/.ssh"="deny",
    "~/.aws"="deny",
    "~/.gnupg"="deny",
    "~/.config/gh"="deny",
    "~/.docker"="deny",
    "~/.git-credentials"="deny",
    "~/.netrc"="deny",
    "~/Library/Keychains"="deny"
    """#

  private static let workspaceRootEntries = #"""
    ":workspace_roots"={"."="write","**/.env"="deny","**/.env.*"="deny"}
    """#

  private static func deliveryProtectedFilesystemEntries(
    readOnlyGitDirectory: URL?
  ) -> String {
    let gitEntry = readOnlyGitDirectory.map {
      #""\#(tomlEscaped($0.standardizedFileURL.path))"="read","#
    } ?? ""
    return normalizedFilesystemEntries(
      #"":minimal"="read","#
        + credentialDenyEntries + ","
        + #""~/Library/Application Support/StoryPointless/storypointless.sqlite"="deny","#
        + #""~/Library/Application Support/StoryPointless/storypointless.sqlite-wal"="deny","#
        + #""~/Library/Application Support/StoryPointless/storypointless.sqlite-shm"="deny","#
        + gitEntry
        + workspaceRootEntries
    )
  }

  static let deliveryProfileOverride =
    deliveryProfileOverrideValue(readOnlyGitDirectory: nil)

  static func deliveryThreadConfiguration(
    readOnlyGitDirectory: URL
  ) -> JSONValue {
    var filesystem: [String: JSONValue] = [
      ":minimal": .string("read"),
      "~/.codex": .string("deny"),
      "~/.ssh": .string("deny"),
      "~/.aws": .string("deny"),
      "~/.gnupg": .string("deny"),
      "~/.config/gh": .string("deny"),
      "~/.docker": .string("deny"),
      "~/.git-credentials": .string("deny"),
      "~/.netrc": .string("deny"),
      "~/Library/Keychains": .string("deny"),
      "~/Library/Application Support/StoryPointless/storypointless.sqlite": .string("deny"),
      "~/Library/Application Support/StoryPointless/storypointless.sqlite-wal": .string("deny"),
      "~/Library/Application Support/StoryPointless/storypointless.sqlite-shm": .string("deny"),
      ":workspace_roots": .object([
        ".": .string("write"),
        "**/.env": .string("deny"),
        "**/.env.*": .string("deny"),
      ]),
    ]
    filesystem[readOnlyGitDirectory.standardizedFileURL.path] = .string("read")
    return .object([
      "permissions.\(delivery)": .object([
        "description": .string(
          "Ticket worktree writes with read-only product Git and scoped runtime opt-in"
        ),
        "filesystem": .object(filesystem),
        "network": .object(["enabled": .bool(false)]),
      ])
    ])
  }

  static func deliveryProfileOverrideValue(
    readOnlyGitDirectory: URL?
  ) -> String {
    #"permissions.\#(delivery)={description="Ticket worktree writes with read-only product Git and scoped runtime opt-in",filesystem={\#(deliveryProtectedFilesystemEntries(readOnlyGitDirectory: readOnlyGitDirectory))},network={enabled=false}}"#
  }

  private static let demoProtectedFilesystemEntries = normalizedFilesystemEntries(
    #"":root"="read","#
      + credentialDenyEntries + ","
      + #""~/Library/Application Support/StoryPointless"="deny","#
      + workspaceRootEntries
  )

  private static func demoProfileOverride(workspaceRootPath: String?) -> String {
    let workspaceRoots = workspaceRootPath.map {
      #",workspace_roots={"\#(tomlEscaped($0))"=true}"#
    } ?? ""
    return #"permissions.\#(demo)={description="Reviewed demo with loopback-only network",filesystem={\#(demoProtectedFilesystemEntries)},network={enabled=true,domains={"localhost"="allow","127.0.0.1"="allow"}}\#(workspaceRoots)}"#
  }

  private static func normalizedFilesystemEntries(_ value: String) -> String {
    value
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined()
  }

  private static func tomlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: #"\"#, with: #"\\"#)
      .replacingOccurrences(of: #"""#, with: #"\""#)
      .replacingOccurrences(of: "\n", with: #"\n"#)
      .replacingOccurrences(of: "\r", with: #"\r"#)
  }
}

public struct CodexManagedCommandRequest: Equatable, Sendable {
  public let command: [String]
  public let workingDirectory: URL
  public let workspaceRoot: URL
  public let environment: [String: String]
  public let timeoutSeconds: Int?
  public let outputBytesCap: Int
  public let permissionProfile: String

  public init(
    command: [String],
    workingDirectory: URL,
    workspaceRoot: URL? = nil,
    environment: [String: String] = [:],
    timeoutSeconds: Int? = nil,
    outputBytesCap: Int = 80_000,
    permissionProfile: String = CodexPermissionProfiles.demo
  ) {
    self.command = command
    self.workingDirectory = workingDirectory
    self.workspaceRoot = workspaceRoot ?? workingDirectory
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
    self.outputBytesCap = outputBytesCap
    self.permissionProfile = permissionProfile
  }
}

public struct CodexManagedCommandResult: Equatable, Sendable {
  public let exitCode: Int
  public let standardOutput: String
  public let standardError: String

  public init(exitCode: Int, standardOutput: String, standardError: String) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  public var combinedOutput: String {
    [standardOutput, standardError]
      .filter { !$0.isEmpty }
      .joined(separator: standardOutput.isEmpty || standardError.isEmpty ? "" : "\n")
  }
}

public enum CodexManagedCommandSnapshot: Equatable, Sendable {
  case running(standardOutput: String, standardError: String)
  case exited(CodexManagedCommandResult)
  case failed(String)
}

public protocol CodexManagedCommandExecuting: Sendable {
  func runManagedCommand(
    _ request: CodexManagedCommandRequest
  ) async throws -> CodexManagedCommandResult

  func startManagedCommand(_ request: CodexManagedCommandRequest) async throws -> String

  func managedCommandSnapshot(processID: String) async -> CodexManagedCommandSnapshot?

  func terminateManagedCommand(processID: String) async
}

public actor CodexWorkspaceCommandExecutor: CodexManagedCommandExecuting {
  private struct ManagedProcess {
    var client: CodexAppServerClient?
    var terminalSnapshot: CodexManagedCommandSnapshot?
  }

  private let executableURL: URL
  private var managedProcesses: [String: ManagedProcess] = [:]

  public init(executableURL: URL) {
    self.executableURL = executableURL
  }

  public func runManagedCommand(
    _ request: CodexManagedCommandRequest
  ) async throws -> CodexManagedCommandResult {
    let client = try await makeClient(workspaceRoot: request.workspaceRoot)
    do {
      let result = try await client.runManagedCommand(request)
      await client.disconnect()
      return result
    } catch {
      await client.disconnect()
      throw error
    }
  }

  public func startManagedCommand(
    _ request: CodexManagedCommandRequest
  ) async throws -> String {
    let client = try await makeClient(workspaceRoot: request.workspaceRoot)
    do {
      let processID = try await client.startManagedCommand(request)
      managedProcesses[processID] = ManagedProcess(
        client: client,
        terminalSnapshot: nil
      )
      return processID
    } catch {
      await client.disconnect()
      throw error
    }
  }

  public func managedCommandSnapshot(
    processID: String
  ) async -> CodexManagedCommandSnapshot? {
    guard var process = managedProcesses[processID] else { return nil }
    if let terminalSnapshot = process.terminalSnapshot {
      return terminalSnapshot
    }
    guard let client = process.client else { return nil }
    let snapshot = await client.managedCommandSnapshot(processID: processID)
    switch snapshot {
    case .exited, .failed:
      process.terminalSnapshot = snapshot
      process.client = nil
      managedProcesses[processID] = process
      await client.disconnect()
    case .running, nil:
      break
    }
    return snapshot
  }

  public func terminateManagedCommand(processID: String) async {
    guard let process = managedProcesses.removeValue(forKey: processID) else {
      return
    }
    if let client = process.client {
      await client.terminateManagedCommand(processID: processID)
      await client.disconnect()
    }
  }

  private func makeClient(workspaceRoot: URL) async throws -> CodexAppServerClient {
    let transport = CodexJSONLTransport(
      configuration: .init(
        executableURL: executableURL,
        arguments: CodexPermissionProfiles.appServerArguments(
          demoWorkspaceRoot: workspaceRoot
        ),
        currentDirectoryURL: workspaceRoot
      )
    )
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    return client
  }
}

public enum CodexApprovalRequestKind: String, Codable, Sendable {
  case command
  case permissions
  case fileChange = "file_change"
}

public struct CodexApprovalPresentation: Equatable, Sendable {
  public let kind: CodexApprovalRequestKind
  public let threadID: String
  public let turnID: String
  public let title: String
  public let detail: String
  public let reason: String?
  public let signature: String
  public let productGrantSignature: String?

  public init(
    kind: CodexApprovalRequestKind,
    threadID: String,
    turnID: String,
    title: String,
    detail: String,
    reason: String?,
    signature: String,
    productGrantSignature: String? = nil
  ) {
    self.kind = kind
    self.threadID = threadID
    self.turnID = turnID
    self.title = title
    self.detail = detail
    self.reason = reason
    self.signature = signature
    self.productGrantSignature = productGrantSignature
  }
}

public enum CodexApprovalError: Error, Equatable, LocalizedError, Sendable {
  case unsupportedRequest(String)
  case malformedRequest(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedRequest(let method):
      "Codex requested an unsupported approval action: \(method)."
    case .malformedRequest(let detail):
      "Codex sent an incomplete approval request: \(detail)."
    }
  }
}

public enum AgentPermissionRequestStatus: String, Codable, Sendable {
  case pending
  case allowed
  case denied
  case interrupted

  public var needsOwnerDecision: Bool {
    self == .pending || self == .interrupted
  }
}

public struct AgentPermissionRequest: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let workItemID: UUID
  public let agentRunID: UUID
  public let threadID: String
  public let turnID: String
  public let serverRequestID: String
  public let method: String
  public let kind: CodexApprovalRequestKind
  public let title: String
  public let detail: String
  public let reason: String?
  public let signature: String
  public let productGrantSignature: String?
  public var status: AgentPermissionRequestStatus
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    workItemID: UUID,
    agentRunID: UUID,
    threadID: String,
    turnID: String,
    serverRequestID: String,
    method: String,
    kind: CodexApprovalRequestKind,
    title: String,
    detail: String,
    reason: String? = nil,
    signature: String,
    productGrantSignature: String? = nil,
    status: AgentPermissionRequestStatus = .pending,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.workItemID = workItemID
    self.agentRunID = agentRunID
    self.threadID = threadID
    self.turnID = turnID
    self.serverRequestID = serverRequestID
    self.method = method
    self.kind = kind
    self.title = title
    self.detail = detail
    self.reason = reason
    self.signature = signature
    self.productGrantSignature = productGrantSignature
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct AgentPermissionGrant: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let sourceRequestID: UUID?
  public let method: String
  public let kind: CodexApprovalRequestKind
  public let title: String
  public let detail: String
  public let signature: String
  public let createdAt: Date
  public var revokedAt: Date?

  public init(
    id: UUID = UUID(),
    productID: UUID,
    sourceRequestID: UUID? = nil,
    method: String,
    kind: CodexApprovalRequestKind,
    title: String,
    detail: String,
    signature: String,
    createdAt: Date = Date(),
    revokedAt: Date? = nil
  ) {
    self.id = id
    self.productID = productID
    self.sourceRequestID = sourceRequestID
    self.method = method
    self.kind = kind
    self.title = title
    self.detail = detail
    self.signature = signature
    self.createdAt = createdAt
    self.revokedAt = revokedAt
  }

  public var isActive: Bool {
    revokedAt == nil
  }
}
