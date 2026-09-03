import Darwin
import Foundation

public enum CodexPermissionProfiles {
  public static let readOnly = ":read-only"
  public static let delivery = "spedito-delivery"
  public static let demo = "spedito-demo"
  public static let repositoryAnalysis = "spedito-repository-analysis"
  public static let requestPermissionsFeature = "request_permissions_tool"
  public static let requestPermissionsFeatureOverride =
    "features.\(requestPermissionsFeature)=true"
  public static var agentProcessEnvironment: [String: String] {
    agentProcessEnvironment(
      inherited: ProcessInfo.processInfo.environment,
      developerDirectory: activeDeveloperDirectory()
    )
  }

  static func agentProcessEnvironment(
    inherited: [String: String],
    developerDirectory: String?
  ) -> [String: String] {
    let allowedKeys = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG"])
    var environment = inherited.filter {
      allowedKeys.contains($0.key) || $0.key.hasPrefix("LC_")
    }
    if let developerDirectory {
      environment["DEVELOPER_DIR"] = developerDirectory
      let developerGitDirectory = URL(
        fileURLWithPath: developerDirectory,
        isDirectory: true
      ).appendingPathComponent("usr/libexec/git-core", isDirectory: true).path
      let remainingPath = (environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
        .filter { $0 != developerGitDirectory }
      environment["PATH"] = ([developerGitDirectory] + remainingPath)
        .joined(separator: ":")
    }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_ATTR_NOSYSTEM"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_ASKPASS"] = "/usr/bin/false"
    environment["SSH_ASKPASS"] = "/usr/bin/false"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_PAGER"] = "cat"
    environment["GIT_EDITOR"] = "/usr/bin/true"
    environment["GIT_CONFIG_COUNT"] = "0"
    return environment
  }

  public static var repositoryAnalysisProcessEnvironment: [String: String] {
    repositoryAnalysisProcessEnvironment(
      inherited: ProcessInfo.processInfo.environment,
      developerDirectory: activeDeveloperDirectory()
    )
  }

  static func repositoryAnalysisProcessEnvironment(
    inherited: [String: String],
    developerDirectory: String?
  ) -> [String: String] {
    let allowedKeys = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG"])
    var environment = inherited.filter {
      allowedKeys.contains($0.key) || $0.key.hasPrefix("LC_")
    }
    if let developerDirectory {
      environment["DEVELOPER_DIR"] = developerDirectory
    }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_ATTR_NOSYSTEM"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_ASKPASS"] = "/usr/bin/false"
    environment["SSH_ASKPASS"] = "/usr/bin/false"
    environment["GIT_PAGER"] = "cat"
    environment["GIT_EDITOR"] = "/usr/bin/true"
    environment["GIT_CONFIG_COUNT"] = "0"
    return environment
  }

  public static func repositoryAnalysisAppServerArguments(
    snapshotURL: URL
  ) -> [String] {
    [
      "-c",
      #"default_permissions="spedito-repository-analysis""#,
      "-c",
      repositoryAnalysisProfileOverride(snapshotURL: snapshotURL),
      "app-server",
      "--listen",
      "stdio://",
    ]
  }

  static func repositoryAnalysisThreadConfiguration(snapshotURL: URL) -> JSONValue {
    .object([
      "permissions.\(repositoryAnalysis)": .object([
        "description": .string("Read-only sanitized repository analysis snapshot"),
        "filesystem": .object([
          ":root": .string("deny"),
          snapshotURL.standardizedFileURL.path: .string("read"),
        ]),
        "network": .object(["enabled": .bool(false)]),
        "workspace_roots": .object([
          snapshotURL.standardizedFileURL.path: .bool(true)
        ]),
      ])
    ])
  }

  private static func repositoryAnalysisProfileOverride(snapshotURL: URL) -> String {
    let path = tomlEscaped(snapshotURL.standardizedFileURL.path)
    return
      #"permissions.\#(repositoryAnalysis)={description="Read-only sanitized repository analysis snapshot",filesystem={":root"="deny","\#(path)"="read"},network={enabled=false},workspace_roots={"\#(path)"=true}}"#
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

  /// Spedito's own control plane, denied to every delivery run.
  ///
  /// These are directories, not database filenames. Each product keeps its
  /// database at `Product Workspaces/<id>/.spedito/product.sqlite`, so naming
  /// files here would go stale the next time the layout moves — as the earlier
  /// `spedito.sqlite` entries did, leaving the live databases uncovered.
  /// Denying `Product Workspaces` also keeps one delivery run out of every
  /// other product's repository.
  ///
  /// The current product's Git directory is re-granted as a more specific
  /// `read`, the way the repository-analysis profile re-grants its snapshot
  /// under `":root"="deny"`.
  ///
  /// Run and integration worktrees are deliberately absent: a delivery run's
  /// own workspace lives under `Run Worktrees`, so a deny here would remove the
  /// agent's own ticket worktree. Cross-worktree access stays an
  /// approval-policy concern in `AgentPermissionGrantPolicy`.
  static let speditoControlPlaneDenyPaths = [
    "~/Library/Application Support/Spedito/Product Workspaces",
    "~/Library/Application Support/StoryPointless",
  ]

  private static func speditoControlPlaneDenyEntries(
    _ paths: [String]
  ) -> String {
    paths
      .map { #""\#(tomlEscaped($0))"="deny","# }
      .joined()
  }

  /// System typeface directories, readable by every delivery run.
  ///
  /// Codex's `:minimal` read set does not include them, so CoreText could not
  /// load Helvetica, Courier, or any other installed face inside the sandbox.
  /// Every rasteriser a team member can reach — `sips`, `qlmanage`, CoreText
  /// from `swift` — then drew text as nothing. A designer checking its own PDF
  /// saw blank pages, concluded the environment had no fonts, and shipped
  /// hand-drawn 3×5 pixel glyphs instead of real type; three products' design
  /// screen sets were delivered that way. Fonts hold no secrets and no product
  /// state, so reading them keeps the profile least-privilege while letting
  /// the sandbox render what the product owner will see.
  ///
  /// Rendered as TOML by `deliveryProtectedFilesystemEntries` and as JSON by
  /// `deliveryThreadConfiguration`, so the launch-time and thread-time
  /// profiles cannot drift apart.
  public static let systemFontReadPaths = ["/System/Library/Fonts", "/Library/Fonts"]

  private static var systemFontReadEntries: String {
    systemFontReadPaths
      .map { #""\#(tomlEscaped($0))"="read","# }
      .joined()
  }

  /// Paths denied inside every workspace root, relative to that root.
  ///
  /// A deny pattern must never contain a wildcard in a **directory**
  /// component. Codex compiles each deny pattern into additional
  /// `deny file-write-unlink` rules for every ancestor of the pattern, so a
  /// pattern such as `**/.env` expands to an ancestor matching every
  /// directory and makes the whole workspace undeletable while files still
  /// unlink. A wildcard in the final filename component is safe, because it
  /// produces no wildcard ancestor.
  ///
  /// The cost of that rule is depth: these entries are workspace-root
  /// relative, so a `.env` nested below the root is not denied. Delivery runs
  /// have no network and demos reach loopback only, which bounds the
  /// consequence.
  static let workspaceDenyPaths = [".env", ".env.*"]

  /// One definition, rendered as TOML here and as JSON in
  /// `deliveryThreadConfiguration`, so the launch-time and thread-time
  /// profiles cannot drift apart.
  private static var workspaceRootEntries: String {
    let entries =
      [#""."="write""#]
      + workspaceDenyPaths.map { #""\#(tomlEscaped($0))"="deny""# }
    return #"":workspace_roots"={\#(entries.joined(separator: ","))}"#
  }

  static var workspaceRootsFilesystemEntries: [String: JSONValue] {
    var entries: [String: JSONValue] = [".": .string("write")]
    for path in workspaceDenyPaths {
      entries[path] = .string("deny")
    }
    return entries
  }

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
    writableTransientStorageRoots: [URL],
    controlPlaneDenyPaths: [String]
  ) -> String {
    let gitEntry =
      readOnlyGitDirectory.map {
        #""\#(tomlEscaped($0.standardizedFileURL.path))"="read","#
      } ?? ""
    let transientEntries = writableTransientStorageRoots.map {
      #""\#(tomlEscaped($0.standardizedFileURL.path))"="write","#
    }.joined()
    let protectedPreviewEntries =
      protectedSpeditoDeliveryStorageRoots
      .filter { $0.path.contains("/Library/Caches/Spedito/PreviewWorktrees") }
      .map { #""\#(tomlEscaped($0.path))"="deny","# }
      .joined()
    return normalizedFilesystemEntries(
      #"":minimal"="read","#
        + systemFontReadEntries
        + credentialDenyEntries + ","
        + speditoControlPlaneDenyEntries(controlPlaneDenyPaths)
        + transientEntries
        + protectedPreviewEntries
        + gitEntry
        + workspaceRootEntries
    )
  }

  static var deliveryProfileOverride: String {
    deliveryProfileOverrideValue(
      readOnlyGitDirectory: nil,
      writableTransientStorageRoots: macOSUserTransientStorageRoots
    )
  }

  static func deliveryThreadConfiguration(
    readOnlyGitDirectory: URL?,
    writableTransientStorageRoots: [URL] = macOSUserTransientStorageRoots,
    protectedStorageRoots: [URL] = protectedSpeditoDeliveryStorageRoots,
    controlPlaneDenyPaths: [String] = speditoControlPlaneDenyPaths
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
      ":workspace_roots": .object(workspaceRootsFilesystemEntries),
    ]
    for path in systemFontReadPaths {
      filesystem[path] = .string("read")
    }
    for path in controlPlaneDenyPaths {
      filesystem[path] = .string("deny")
    }
    for root in writableTransientStorageRoots {
      filesystem[root.standardizedFileURL.resolvingSymlinksInPath().path] = .string("write")
    }
    for root in protectedStorageRoots
    where
      root.path.contains("/Library/Caches/Spedito/PreviewWorktrees")
    {
      filesystem[root.standardizedFileURL.resolvingSymlinksInPath().path] = .string("deny")
    }
    if let readOnlyGitDirectory {
      filesystem[readOnlyGitDirectory.standardizedFileURL.path] = .string("read")
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
    writableTransientStorageRoots: [URL] = macOSUserTransientStorageRoots,
    controlPlaneDenyPaths: [String] = speditoControlPlaneDenyPaths
  ) -> String {
    #"permissions.\#(delivery)={description="Ticket worktree and macOS transient storage writes with read-only product Git",filesystem={\#(deliveryProtectedFilesystemEntries(readOnlyGitDirectory: readOnlyGitDirectory, writableTransientStorageRoots: writableTransientStorageRoots, controlPlaneDenyPaths: controlPlaneDenyPaths))},network={enabled=false}}"#
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
    let workspaceRoots =
      workspaceRootPath.map {
        #",workspace_roots={"\#(tomlEscaped($0))"=true}"#
      } ?? ""
    return
      #"permissions.\#(demo)={description="Reviewed demo with macOS transient storage and loopback-only network",filesystem={\#(demoProtectedFilesystemEntries(writableTransientStorageRoots: writableTransientStorageRoots))},network={enabled=true,domains={"localhost"="allow","127.0.0.1"="allow"}}\#(workspaceRoots)}"#
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
    let gitExecutable =
      developerDirectory
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
        currentDirectoryURL: workspaceRoot,
        environmentOverrides: CodexPermissionProfiles.agentProcessEnvironment,
        environmentMode: .replace
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
  case allowOncePendingDelivery = "allow_once_pending_delivery"
  case allowProductPendingDelivery = "allow_product_pending_delivery"
  case existingAccessPendingDelivery = "existing_access_pending_delivery"
  case grantAccessPendingDelivery = "grant_access_pending_delivery"
  case denyPendingDelivery = "deny_pending_delivery"
  case policyDenyPendingDelivery = "policy_deny_pending_delivery"
  case allowed
  case existingAccess = "existing_access"
  case policyDenied = "policy_denied"
  case denied
  case interrupted

  public var needsOwnerDecision: Bool {
    self == .pending || self == .interrupted
  }

  public var isPendingDelivery: Bool {
    switch self {
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .existingAccessPendingDelivery, .grantAccessPendingDelivery,
      .denyPendingDelivery, .policyDenyPendingDelivery:
      true
    case .pending, .allowed, .existingAccess, .policyDenied, .denied, .interrupted:
      false
    }
  }

  public var allowsRequest: Bool? {
    switch self {
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .existingAccessPendingDelivery, .grantAccessPendingDelivery,
      .allowed, .existingAccess:
      true
    case .denyPendingDelivery, .policyDenyPendingDelivery, .policyDenied, .denied:
      false
    case .pending, .interrupted:
      nil
    }
  }

  public var acknowledgedStatus: Self? {
    switch self {
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .grantAccessPendingDelivery:
      .allowed
    case .existingAccessPendingDelivery:
      .existingAccess
    case .denyPendingDelivery:
      .denied
    case .policyDenyPendingDelivery:
      .policyDenied
    case .pending, .allowed, .existingAccess, .policyDenied, .denied, .interrupted:
      nil
    }
  }

  public var replayIntent: Self? {
    switch self {
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .existingAccessPendingDelivery, .grantAccessPendingDelivery,
      .denyPendingDelivery, .policyDenyPendingDelivery:
      self
    case .allowed:
      .allowOncePendingDelivery
    case .existingAccess:
      .existingAccessPendingDelivery
    case .policyDenied:
      .policyDenyPendingDelivery
    case .denied:
      .denyPendingDelivery
    case .pending, .interrupted:
      nil
    }
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
