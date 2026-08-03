import Darwin
import Foundation

public enum CodexPermissionProfiles {
  public static let readOnly = ":read-only"
  public static let delivery = "spedito-delivery"
  public static let demo = "spedito-demo"
  public static let requestPermissionsFeature = "request_permissions_tool"
  public static let requestPermissionsFeatureOverride =
    "features.\(requestPermissionsFeature)=true"
  public static var agentProcessEnvironment: [String: String] {
    agentProcessEnvironment(
      developerDirectory: activeDeveloperDirectory(),
      inheritedPath: ProcessInfo.processInfo.environment["PATH"]
    )
  }

  static func agentProcessEnvironment(
    developerDirectory: String?,
    inheritedPath: String? = nil
  ) -> [String: String] {
    var environment = [
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_OPTIONAL_LOCKS": "0",
      "GIT_PAGER": "cat",
    ]
    if let developerDirectory {
      environment["DEVELOPER_DIR"] = developerDirectory
      let developerGitDirectory = URL(
        fileURLWithPath: developerDirectory,
        isDirectory: true
      ).appendingPathComponent("usr/libexec/git-core", isDirectory: true).path
      let remainingPath = (inheritedPath ?? "")
        .split(separator: ":")
        .map(String.init)
        .filter { $0 != developerGitDirectory }
      environment["PATH"] = ([developerGitDirectory] + remainingPath)
        .joined(separator: ":")
    }
    return environment
  }

  public static var appServerArguments: [String] {
    appServerArguments(
      demoWorkspaceRoot: nil,
      writableTransientStorageRoots: macOSUserTransientStorageRoots
    )
  }

  public static func appServerArguments(demoWorkspaceRoot: URL) -> [String] {
    appServerArguments(
      demoWorkspaceRoot: demoWorkspaceRoot,
      writableTransientStorageRoots: macOSUserTransientStorageRoots
    )
  }

  static func appServerArguments(
    demoWorkspaceRoot: URL?,
    writableTransientStorageRoots: [URL]
  ) -> [String] {
    let demoTransientStorageRoots = managedDemoTransientStorageRoots(
      from: writableTransientStorageRoots,
      demoWorkspaceRoot: demoWorkspaceRoot
    )
    return [
      "-c",
      #"default_permissions=":read-only""#,
      "-c",
      requestPermissionsFeatureOverride,
      "-c",
      deliveryProfileOverrideValue(
        readOnlyGitDirectory: nil,
        readOnlyProductDirectory: nil,
        writableTransientStorageRoots: writableTransientStorageRoots
      ),
      "-c",
      demoProfileOverride(
        workspaceRootPath: demoWorkspaceRoot?.standardizedFileURL.path,
        writableTransientStorageRoots: demoTransientStorageRoots
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

  public static var macOSUserTransientStorageRoots: [URL] {
    normalizedStorageRoots(
      darwinTemporaryDirectory: darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR),
      darwinCacheDirectory: darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR),
      foundationCacheDirectory: FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    )
  }

  static func normalizedStorageRoots(
    darwinTemporaryDirectory: URL?,
    darwinCacheDirectory: URL?,
    foundationCacheDirectory: URL?
  ) -> [URL] {
    var seen: Set<String> = []
    return [
      darwinTemporaryDirectory,
      darwinCacheDirectory,
      foundationCacheDirectory,
    ].compactMap { candidate in
      guard let candidate else { return nil }
      let normalized = canonicalStorageURL(candidate)
      guard normalized.path.hasPrefix("/"), normalized.path != "/" else { return nil }
      guard seen.insert(normalized.path).inserted else { return nil }
      return normalized
    }
  }

  private static func canonicalStorageURL(_ candidate: URL) -> URL {
    let standardized = candidate.standardizedFileURL
    let path: String
    if standardized.path == "/var" {
      path = "/private/var"
    } else if standardized.path.hasPrefix("/var/") {
      path = "/private" + standardized.path
    } else {
      path = standardized.path
    }
    return URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
  }

  public static var protectedSpeditoDeliveryStorageRoots: [URL] {
    let fileManager = FileManager.default
    var roots: [URL] = []
    if let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first {
      let spedito = applicationSupport.appendingPathComponent("Spedito", isDirectory: true)
      roots.append(contentsOf: [
        spedito.appendingPathComponent("Product Workspaces", isDirectory: true),
        spedito.appendingPathComponent("Run Worktrees", isDirectory: true),
        spedito.appendingPathComponent("Integration Worktrees", isDirectory: true),
      ])
    }
    if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
      roots.append(
        caches
          .appendingPathComponent("Spedito", isDirectory: true)
          .appendingPathComponent("PreviewWorktrees", isDirectory: true)
      )
    }
    return roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
  }

  static func managedDemoTransientStorageRoots(
    from writableTransientStorageRoots: [URL],
    demoWorkspaceRoot: URL? = nil,
    protectedStorageRoots: [URL] = protectedSpeditoDeliveryStorageRoots
  ) -> [URL] {
    let protectedPaths = (protectedStorageRoots + [demoWorkspaceRoot].compactMap { $0 }).map {
      $0.standardizedFileURL.resolvingSymlinksInPath().path
    }
    return writableTransientStorageRoots.filter { candidate in
      let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
      let prefix = path.hasSuffix("/") ? path : "\(path)/"
      return !protectedPaths.contains { protectedPath in
        protectedPath == path || protectedPath.hasPrefix(prefix)
      }
    }
  }

  private static func deliveryProtectedFilesystemEntries(
    readOnlyGitDirectory: URL?,
    readOnlyProductDirectory: URL?,
    writableTransientStorageRoots: [URL]
  ) -> String {
    let gitEntry = readOnlyGitDirectory.map {
      #""\#(tomlEscaped($0.standardizedFileURL.path))"="read","#
    } ?? ""
    let productEntry = readOnlyProductDirectory.map {
      #""\#(tomlEscaped($0.standardizedFileURL.path))"="read","#
    } ?? ""
    let transientEntries = writableTransientStorageRoots.map {
      #""\#(tomlEscaped($0.standardizedFileURL.path))"="write","#
    }.joined()
    let protectedPreviewEntries = protectedSpeditoDeliveryStorageRoots
      .filter { $0.path.contains("/Library/Caches/Spedito/PreviewWorktrees") }
      .map { #""\#(tomlEscaped($0.path))"="deny","# }
      .joined()
    return normalizedFilesystemEntries(
      #"":minimal"="read","#
        + credentialDenyEntries + ","
        + #""~/Library/Application Support/Spedito/spedito.sqlite"="deny","#
        + #""~/Library/Application Support/Spedito/spedito.sqlite-wal"="deny","#
        + #""~/Library/Application Support/Spedito/spedito.sqlite-shm"="deny","#
        + #""~/Library/Application Support/Spedito/storypointless.sqlite"="deny","#
        + #""~/Library/Application Support/Spedito/storypointless.sqlite-wal"="deny","#
        + #""~/Library/Application Support/Spedito/storypointless.sqlite-shm"="deny","#
        + #""~/Library/Application Support/StoryPointless/storypointless.sqlite"="deny","#
        + #""~/Library/Application Support/StoryPointless/storypointless.sqlite-wal"="deny","#
        + #""~/Library/Application Support/StoryPointless/storypointless.sqlite-shm"="deny","#
        + transientEntries
        + protectedPreviewEntries
        + gitEntry
        + productEntry
        + workspaceRootEntries
    )
  }

  static var deliveryProfileOverride: String {
    deliveryProfileOverrideValue(
      readOnlyGitDirectory: nil,
      readOnlyProductDirectory: nil,
      writableTransientStorageRoots: macOSUserTransientStorageRoots
    )
  }

  static func deliveryThreadConfiguration(
    readOnlyGitDirectory: URL?,
    readOnlyProductDirectory: URL? = nil,
    writableTransientStorageRoots: [URL] = macOSUserTransientStorageRoots,
    protectedStorageRoots: [URL] = protectedSpeditoDeliveryStorageRoots
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
      "~/Library/Application Support/Spedito/spedito.sqlite": .string("deny"),
      "~/Library/Application Support/Spedito/spedito.sqlite-wal": .string("deny"),
      "~/Library/Application Support/Spedito/spedito.sqlite-shm": .string("deny"),
      "~/Library/Application Support/Spedito/storypointless.sqlite": .string("deny"),
      "~/Library/Application Support/Spedito/storypointless.sqlite-wal": .string("deny"),
      "~/Library/Application Support/Spedito/storypointless.sqlite-shm": .string("deny"),
      "~/Library/Application Support/StoryPointless/storypointless.sqlite": .string("deny"),
      "~/Library/Application Support/StoryPointless/storypointless.sqlite-wal": .string("deny"),
      "~/Library/Application Support/StoryPointless/storypointless.sqlite-shm": .string("deny"),
      ":workspace_roots": .object([
        ".": .string("write"),
        "**/.env": .string("deny"),
        "**/.env.*": .string("deny"),
      ]),
    ]
    for root in writableTransientStorageRoots {
      filesystem[root.standardizedFileURL.resolvingSymlinksInPath().path] = .string("write")
    }
    for root in protectedStorageRoots where
      root.path.contains("/Library/Caches/Spedito/PreviewWorktrees")
    {
      filesystem[root.standardizedFileURL.resolvingSymlinksInPath().path] = .string("deny")
    }
    if let readOnlyGitDirectory {
      filesystem[readOnlyGitDirectory.standardizedFileURL.path] = .string("read")
    }
    if let readOnlyProductDirectory {
      filesystem[readOnlyProductDirectory.standardizedFileURL.path] = .string("read")
    }
    return .object([
      "permissions.\(delivery)": .object([
        "description": .string(
          "Ticket worktree and macOS transient storage writes with read-only product Git"
        ),
        "filesystem": .object(filesystem),
        "network": .object(["enabled": .bool(false)]),
      ])
    ])
  }

  static func deliveryProfileOverrideValue(
    readOnlyGitDirectory: URL?,
    readOnlyProductDirectory: URL? = nil,
    writableTransientStorageRoots: [URL] = macOSUserTransientStorageRoots
  ) -> String {
    #"permissions.\#(delivery)={description="Ticket worktree and macOS transient storage writes with read-only product Git",filesystem={\#(deliveryProtectedFilesystemEntries(readOnlyGitDirectory: readOnlyGitDirectory, readOnlyProductDirectory: readOnlyProductDirectory, writableTransientStorageRoots: writableTransientStorageRoots))},network={enabled=false}}"#
  }

  private static func demoProtectedFilesystemEntries(
    writableTransientStorageRoots: [URL]
  ) -> String {
    let transientEntries = writableTransientStorageRoots.map {
      #""\#(tomlEscaped($0.standardizedFileURL.path))"="write","#
    }.joined()
    return normalizedFilesystemEntries(
      #"":root"="read","#
        + credentialDenyEntries + ","
        + #""~/Library/Application Support/Spedito"="deny","#
        + #""~/Library/Application Support/StoryPointless"="deny","#
        + transientEntries
        + workspaceRootEntries
    )
  }

  private static func demoProfileOverride(
    workspaceRootPath: String?,
    writableTransientStorageRoots: [URL]
  ) -> String {
    let workspaceRoots = workspaceRootPath.map {
      #",workspace_roots={"\#(tomlEscaped($0))"=true}"#
    } ?? ""
    return #"permissions.\#(demo)={description="Reviewed demo with macOS transient storage and loopback-only network",filesystem={\#(demoProtectedFilesystemEntries(writableTransientStorageRoots: writableTransientStorageRoots))},network={enabled=true,domains={"localhost"="allow","127.0.0.1"="allow"}}\#(workspaceRoots)}"#
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

  private static func darwinUserDirectory(_ name: Int32) -> URL? {
    let requiredSize = confstr(name, nil, 0)
    guard requiredSize > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: requiredSize)
    guard confstr(name, &buffer, requiredSize) > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(
      fileURLWithPath: String(decoding: bytes, as: UTF8.self),
      isDirectory: true
    )
  }

  private static func activeDeveloperDirectory() -> String? {
    let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
    guard FileManager.default.isExecutableFile(atPath: xcodeSelect.path) else {
      return nil
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = xcodeSelect
    process.arguments = ["--print-path"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard
      process.terminationStatus == 0,
      let selectedPath = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !selectedPath.isEmpty
    else {
      return nil
    }
    let developerDirectory = URL(
      fileURLWithPath: selectedPath,
      isDirectory: true
    ).standardizedFileURL
    let gitExecutable = developerDirectory
      .appendingPathComponent("usr/libexec/git-core", isDirectory: true)
      .appendingPathComponent("git")
    guard FileManager.default.isExecutableFile(atPath: gitExecutable.path) else {
      return nil
    }
    return developerDirectory.path
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
  case existingAccess = "existing_access"
  case policyDenied = "policy_denied"
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
