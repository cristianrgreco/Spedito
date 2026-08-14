import Darwin
import Foundation

public struct GitCredentialSessionConfiguration: Equatable, Sendable {
  public let gitConfigurationArguments: [String]

  public init(socketPath: String) {
    gitConfigurationArguments = [
      "-c", "credential.helper=",
      "-c", "credential.helper=cache --socket=\(socketPath) --timeout=60",
      "-c", "credential.useHttpPath=true",
    ]
  }
}

public enum GitCredentialSessionError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case unsafeTemporaryPath
  case commandFailed

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "This Mac’s system Git cannot safely authenticate with GitHub."
    case .unsafeTemporaryPath:
      "Spedito cannot create a safe temporary Git credential session on this Mac."
    case .commandFailed:
      "GitHub authentication could not be provided safely to Git. Try again."
    }
  }
}

public actor GitCredentialSession {
  public static let directoryPrefix = "session-"

  private let executableURL: URL
  private let fileManager: FileManager
  public let parentURL: URL
  private var activeSessionURLs: Set<URL> = []
  private var isShuttingDown = false

  public init(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    temporaryDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    self.executableURL = executableURL
    self.fileManager = fileManager
    parentURL = temporaryDirectory.appendingPathComponent(
      "io.spedito.app-git-credentials-\(geteuid())",
      isDirectory: true
    )
  }

  public func cleanupOrphans() throws {
    try ensureParentDirectory()
    let values = try fileManager.contentsOfDirectory(
      at: parentURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    for value in values {
      guard isValidSessionDirectory(value), !activeSessionURLs.contains(value) else {
        continue
      }
      let socketURL = value.appendingPathComponent("s")
      if socketPathIsSafe(socketURL.path) {
        _ = try? runGit(
          ["credential-cache", "--socket=\(socketURL.path)", "exit"],
          at: value,
          input: nil
        )
      }
      try? fileManager.removeItem(at: value)
    }
  }

  public func withCredential<T: Sendable>(
    repositoryURL: URL,
    username: String = "x-access-token",
    accessToken: String,
    operation: @escaping @Sendable (GitCredentialSessionConfiguration) async throws -> T
  ) async throws -> T {
    guard !isShuttingDown else { throw GitCredentialSessionError.unavailable }
    try validateRepositoryURL(repositoryURL)
    guard !username.isEmpty, !username.contains("\n"), !username.contains("\r") else {
      throw GitCredentialSessionError.unavailable
    }
    try ensureCredentialCacheAvailable()
    try ensureParentDirectory()

    let sessionURL = parentURL.appendingPathComponent(
      Self.directoryPrefix + UUID().uuidString.lowercased(),
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: sessionURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    activeSessionURLs.insert(sessionURL)
    let socketURL = sessionURL.appendingPathComponent("s")
    guard socketPathIsSafe(socketURL.path) else {
      activeSessionURLs.remove(sessionURL)
      try? fileManager.removeItem(at: sessionURL)
      throw GitCredentialSessionError.unsafeTemporaryPath
    }

    let configuration = GitCredentialSessionConfiguration(socketPath: socketURL.path)
    let payload = try credentialPayload(
      repositoryURL: repositoryURL,
      username: username,
      password: accessToken
    )
    do {
      let approveStatus = try runGit(
        configuration.gitConfigurationArguments + ["credential", "approve"],
        at: sessionURL,
        input: payload
      )
      guard approveStatus == 0 else { throw GitCredentialSessionError.commandFailed }
      do {
        let result = try await operation(configuration)
        cleanup(
          sessionURL: sessionURL,
          configuration: configuration,
          credentialPayload: payload
        )
        return result
      } catch {
        cleanup(
          sessionURL: sessionURL,
          configuration: configuration,
          credentialPayload: payload
        )
        throw error
      }
    } catch {
      cleanup(
        sessionURL: sessionURL,
        configuration: configuration,
        credentialPayload: payload
      )
      throw error
    }
  }

  public func shutdown() {
    isShuttingDown = true
    for sessionURL in activeSessionURLs {
      let socketURL = sessionURL.appendingPathComponent("s")
      if socketPathIsSafe(socketURL.path) {
        _ = try? runGit(
          ["credential-cache", "--socket=\(socketURL.path)", "exit"],
          at: sessionURL,
          input: nil
        )
      }
      try? fileManager.removeItem(at: sessionURL)
    }
    activeSessionURLs.removeAll()
  }

  private func cleanup(
    sessionURL: URL,
    configuration: GitCredentialSessionConfiguration,
    credentialPayload: Data
  ) {
    _ = try? runGit(
      configuration.gitConfigurationArguments + ["credential", "reject"],
      at: sessionURL,
      input: credentialPayload
    )
    let socketURL = sessionURL.appendingPathComponent("s")
    _ = try? runGit(
      ["credential-cache", "--socket=\(socketURL.path)", "exit"],
      at: sessionURL,
      input: nil
    )
    try? fileManager.removeItem(at: sessionURL)
    activeSessionURLs.remove(sessionURL)
  }

  private func ensureParentDirectory() throws {
    try fileManager.createDirectory(
      at: parentURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let values = try parentURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let attributes = try fileManager.attributesOfItem(atPath: parentURL.path)
    guard values.isDirectory == true, values.isSymbolicLink != true,
      let owner = attributes[.ownerAccountID] as? NSNumber,
      owner.uint32Value == geteuid()
    else {
      throw GitCredentialSessionError.unsafeTemporaryPath
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentURL.path)
    let securedAttributes = try fileManager.attributesOfItem(atPath: parentURL.path)
    guard let permissions = securedAttributes[.posixPermissions] as? NSNumber,
      permissions.intValue & 0o777 == 0o700
    else {
      throw GitCredentialSessionError.unsafeTemporaryPath
    }
  }

  private func ensureCredentialCacheAvailable() throws {
    let directory = parentURL.deletingLastPathComponent()
    let result = try runGit(["--exec-path"], at: directory, input: nil, capturesOutput: true)
    guard result == 0, let execPath = lastCapturedOutput,
      !execPath.isEmpty
    else {
      throw GitCredentialSessionError.unavailable
    }
    let helperURL = URL(fileURLWithPath: execPath)
      .appendingPathComponent("git-credential-cache")
    guard fileManager.isExecutableFile(atPath: helperURL.path) else {
      throw GitCredentialSessionError.unavailable
    }
  }

  private nonisolated func validateRepositoryURL(_ repositoryURL: URL) throws {
    guard
      repositoryURL.scheme?.lowercased() == "https",
      repositoryURL.host?.lowercased() == "github.com",
      repositoryURL.user == nil,
      repositoryURL.password == nil,
      !repositoryURL.path.isEmpty
    else {
      throw GitCredentialSessionError.unavailable
    }
  }

  private nonisolated func credentialPayload(
    repositoryURL: URL,
    username: String,
    password: String
  ) throws -> Data {
    guard
      !password.isEmpty,
      !password.contains("\n"),
      !password.contains("\r")
    else {
      throw GitCredentialSessionError.unavailable
    }
    let path =
      repositoryURL.path.hasPrefix("/")
      ? String(repositoryURL.path.dropFirst())
      : repositoryURL.path
    let value =
      "protocol=https\nhost=github.com\npath=\(path)\nusername=\(username)\npassword=\(password)\n\n"
    return Data(value.utf8)
  }

  private func isValidSessionDirectory(_ url: URL) -> Bool {
    guard url.deletingLastPathComponent().standardizedFileURL == parentURL.standardizedFileURL,
      url.lastPathComponent.hasPrefix(Self.directoryPrefix),
      UUID(uuidString: String(url.lastPathComponent.dropFirst(Self.directoryPrefix.count))) != nil,
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true,
      values.isSymbolicLink != true
    else {
      return false
    }
    return true
  }

  private nonisolated func socketPathIsSafe(_ path: String) -> Bool {
    path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
  }

  private var lastCapturedOutput: String?

  @discardableResult
  private func runGit(
    _ arguments: [String],
    at directoryURL: URL,
    input: Data?,
    capturesOutput: Bool = false
  ) throws -> Int32 {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = directoryURL
    process.environment = [
      "HOME": directoryURL.path,
      "XDG_CONFIG_HOME": directoryURL.path,
      "PATH": "/usr/bin:/bin",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_TERMINAL_PROMPT": "0",
      "GCM_INTERACTIVE": "never",
      "LC_ALL": "C",
    ]
    let inputPipe = Pipe()
    let outputPipe = capturesOutput ? Pipe() : nil
    process.standardInput = inputPipe
    process.standardOutput = outputPipe ?? FileHandle.nullDevice
    process.standardError = outputPipe ?? FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw GitCredentialSessionError.unavailable
    }
    if let input {
      try inputPipe.fileHandleForWriting.write(contentsOf: input)
    }
    try? inputPipe.fileHandleForWriting.close()
    let output = outputPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    process.waitUntilExit()
    if capturesOutput {
      lastCapturedOutput = String(data: output.prefix(4_096), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      lastCapturedOutput = nil
    }
    return process.terminationStatus
  }
}
