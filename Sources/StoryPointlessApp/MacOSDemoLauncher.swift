import AppKit
import Darwin
import Foundation
import StoryPointlessCore

enum DemoLauncherError: Error, LocalizedError {
  case appServerUnavailable
  case commandFailed(String)
  case commandTimedOut(String)
  case serviceStopped(String)
  case readinessTimedOut(String)
  case missingPresentation(String)
  case couldNotOpen(String)
  case couldNotAllocatePort

  var errorDescription: String? {
    switch self {
    case .appServerUnavailable:
      "The managed Codex runtime is not connected. Reconnect it before opening this demo."
    case .commandFailed(let detail):
      "The demo preparation did not finish successfully.\(detail.isEmpty ? "" : " \(detail)")"
    case .commandTimedOut(let name):
      "The demo preparation took too long while running \(name)."
    case .serviceStopped(let detail):
      "The demo service stopped before it was ready.\(detail.isEmpty ? "" : " \(detail)")"
    case .readinessTimedOut(let detail):
      "The demo service did not become ready in time.\(detail.isEmpty ? "" : " \(detail)")"
    case .missingPresentation(let path):
      "The reviewed demo file is missing at \(path)."
    case .couldNotOpen(let title):
      "macOS could not open \(title)."
    case .couldNotAllocatePort:
      "StoryPointless could not reserve a local address for the demo."
    }
  }
}

struct DemoLaunchOutcome: Equatable {
  let output: String?
  let allocatedPort: Int?
}

@MainActor
final class MacOSDemoLauncher {
  private struct Runtime {
    let processID: String?
    let application: NSRunningApplication?
    let presentationURL: URL?
    let output: String?
    let allocatedPort: Int?
  }

  private var runtimes: [UUID: Runtime] = [:]
  private var executor: (any CodexManagedCommandExecuting)?
  private let fileManager: FileManager
  private let workspace: NSWorkspace
  private let urlSession: URLSession

  init(
    executor: (any CodexManagedCommandExecuting)? = nil,
    fileManager: FileManager = .default,
    workspace: NSWorkspace = .shared,
    urlSession: URLSession = .shared
  ) {
    self.executor = executor
    self.fileManager = fileManager
    self.workspace = workspace
    self.urlSession = urlSession
  }

  func useExecutor(_ executor: any CodexManagedCommandExecuting) {
    self.executor = executor
  }

  func clearExecutor() {
    executor = nil
  }

  func smokeTest(
    candidateID: UUID,
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) async throws -> String? {
    try DemoLaunchSpecificationValidator.validate(specification)
    await stop(candidateID: candidateID)
    try await runPreparation(
      specification.preparationCommands,
      workspaceURL: workspaceURL
    )
    switch specification.presentation.kind {
    case .browser:
      let runtime = try await startBrowserService(
        specification: specification,
        workspaceURL: workspaceURL,
        opensBrowser: false
      )
      runtimes[candidateID] = runtime
      await stop(candidateID: candidateID)
      return nil
    case .macApplication:
      _ = try applicationExecutable(
        specification: specification,
        workspaceURL: workspaceURL
      )
      return nil
    case .artifact:
      _ = try artifactURL(
        specification: specification,
        workspaceURL: workspaceURL
      )
      return nil
    case .commandOutput:
      guard let command = specification.launchCommand else {
        throw DemoLaunchValidationError.invalid("the result command is missing.")
      }
      return try await runToCompletion(command, workspaceURL: workspaceURL)
    }
  }

  func launch(
    candidateID: UUID,
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) async throws -> DemoLaunchOutcome {
    try DemoLaunchSpecificationValidator.validate(specification)
    if let existing = runtimes[candidateID] {
      if let processID = existing.processID,
        await isRunning(processID: processID)
      {
        if let presentationURL = existing.presentationURL {
          _ = workspace.open(presentationURL)
        } else {
          existing.application?.activate()
        }
        return DemoLaunchOutcome(
          output: existing.output,
          allocatedPort: existing.allocatedPort
        )
      }
      if let processID = existing.processID {
        await executor?.terminateManagedCommand(processID: processID)
      }
      if existing.processID == nil {
        if let presentationURL = existing.presentationURL {
          _ = workspace.open(presentationURL)
        }
        return DemoLaunchOutcome(
          output: existing.output,
          allocatedPort: existing.allocatedPort
        )
      }
      runtimes.removeValue(forKey: candidateID)
    }

    try await runPreparation(
      specification.preparationCommands,
      workspaceURL: workspaceURL
    )

    switch specification.presentation.kind {
    case .browser:
      let runtime = try await startBrowserService(
        specification: specification,
        workspaceURL: workspaceURL,
        opensBrowser: true
      )
      runtimes[candidateID] = runtime
      return DemoLaunchOutcome(output: nil, allocatedPort: runtime.allocatedPort)
    case .macApplication:
      let executable = try applicationExecutable(
        specification: specification,
        workspaceURL: workspaceURL
      )
      let bundleIdentifier = Bundle(url: executable.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent())?.bundleIdentifier
      let existingApplicationIDs = Set(
        bundleIdentifier.map {
          NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            .map(\.processIdentifier)
        } ?? []
      )
      let processID = try await startProcess(
        DemoCommand(
          executable: executable.path,
          arguments: [],
          workingDirectory: ".",
          timeoutSeconds: 900
        ),
        workspaceURL: workspaceURL,
        port: nil
      )
      try await Task.sleep(for: .milliseconds(500))
      guard await isRunning(processID: processID) else {
        let detail = await outputSummary(processID: processID)
        await executor?.terminateManagedCommand(processID: processID)
        throw DemoLauncherError.serviceStopped(detail)
      }
      let application = bundleIdentifier.flatMap { identifier in
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
          .first { !existingApplicationIDs.contains($0.processIdentifier) }
      }
      application?.activate()
      runtimes[candidateID] = Runtime(
        processID: processID,
        application: application,
        presentationURL: nil,
        output: nil,
        allocatedPort: nil
      )
      return DemoLaunchOutcome(output: nil, allocatedPort: nil)
    case .artifact:
      let url = try artifactURL(
        specification: specification,
        workspaceURL: workspaceURL
      )
      guard workspace.open(url) else {
        throw DemoLauncherError.couldNotOpen(specification.title)
      }
      runtimes[candidateID] = Runtime(
        processID: nil,
        application: nil,
        presentationURL: url,
        output: nil,
        allocatedPort: nil
      )
      return DemoLaunchOutcome(output: nil, allocatedPort: nil)
    case .commandOutput:
      guard let command = specification.launchCommand else {
        throw DemoLaunchValidationError.invalid("the result command is missing.")
      }
      let output = try await runToCompletion(command, workspaceURL: workspaceURL)
      runtimes[candidateID] = Runtime(
        processID: nil,
        application: nil,
        presentationURL: nil,
        output: output,
        allocatedPort: nil
      )
      return DemoLaunchOutcome(output: output, allocatedPort: nil)
    }
  }

  func stop(candidateID: UUID) async {
    guard let runtime = runtimes.removeValue(forKey: candidateID) else { return }
    if let processID = runtime.processID {
      await executor?.terminateManagedCommand(processID: processID)
      for _ in 0..<20 where await isRunning(processID: processID) {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    if runtime.application?.isTerminated == false {
      runtime.application?.terminate()
    }
  }

  func stopAll() async {
    for candidateID in Array(runtimes.keys) {
      await stop(candidateID: candidateID)
    }
  }

  private func startBrowserService(
    specification: DemoLaunchSpecification,
    workspaceURL: URL,
    opensBrowser: Bool
  ) async throws -> Runtime {
    guard
      let command = specification.launchCommand,
      let readiness = specification.readiness
    else {
      throw DemoLaunchValidationError.invalid("the web demo service is incomplete.")
    }
    let port = try allocateLoopbackPort()
    let processID = try await startProcess(
      command,
      workspaceURL: workspaceURL,
      port: (
        value: port,
        environmentVariable: specification.portEnvironmentVariable ?? "PORT"
      )
    )
    do {
      try await waitUntilReady(
        processID: processID,
        readiness: readiness,
        port: port
      )
    } catch {
      await executor?.terminateManagedCommand(processID: processID)
      throw error
    }
    let path = specification.presentation.path ?? "/"
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
      await executor?.terminateManagedCommand(processID: processID)
      throw DemoLaunchValidationError.invalid("the browser path is invalid.")
    }
    if opensBrowser, !workspace.open(url) {
      await executor?.terminateManagedCommand(processID: processID)
      throw DemoLauncherError.couldNotOpen(specification.title)
    }
    return Runtime(
      processID: processID,
      application: nil,
      presentationURL: url,
      output: nil,
      allocatedPort: port
    )
  }

  private func runPreparation(
    _ commands: [DemoCommand],
    workspaceURL: URL
  ) async throws {
    for command in commands {
      _ = try await runToCompletion(command, workspaceURL: workspaceURL)
    }
  }

  private func runToCompletion(
    _ command: DemoCommand,
    workspaceURL: URL
  ) async throws -> String {
    guard let executor else { throw DemoLauncherError.appServerUnavailable }
    let request = try managedRequest(
      command,
      workspaceURL: workspaceURL,
      port: nil,
      hasTimeout: true
    )
    let result = try await executor.runManagedCommand(request)
    let output = result.combinedOutput
    guard result.exitCode == 0 else {
      throw DemoLauncherError.commandFailed(ownerFacingLogSummary(output))
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func startProcess(
    _ command: DemoCommand,
    workspaceURL: URL,
    port: (value: Int, environmentVariable: String)?
  ) async throws -> String {
    guard let executor else { throw DemoLauncherError.appServerUnavailable }
    return try await executor.startManagedCommand(
      managedRequest(
        command,
        workspaceURL: workspaceURL,
        port: port,
        hasTimeout: false
      )
    )
  }

  private func managedRequest(
    _ command: DemoCommand,
    workspaceURL: URL,
    port: (value: Int, environmentVariable: String)?,
    hasTimeout: Bool
  ) throws -> CodexManagedCommandRequest {
    let currentDirectory = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
      command.workingDirectory,
      in: workspaceURL
    )
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: currentDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DemoLauncherError.missingPresentation(command.workingDirectory)
    }
    let runtimeRoot = workspaceURL
      .appendingPathComponent(".storypointless-demo-runtime", isDirectory: true)
    let temporaryDirectory = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let cacheRoot = runtimeRoot.appendingPathComponent("cache", isDirectory: true)
    try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    var environment = [
      "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8",
      "TMPDIR": temporaryDirectory.path,
      "CFFIXED_USER_HOME": runtimeRoot.appendingPathComponent("home").path,
      "STORYPOINTLESS_DEMO_DATA_DIRECTORY": runtimeRoot.appendingPathComponent("data").path,
      "SWIFT_MODULECACHE_PATH": cacheRoot.appendingPathComponent("swift").path,
      "CLANG_MODULE_CACHE_PATH": cacheRoot.appendingPathComponent("clang").path,
      "XDG_CACHE_HOME": cacheRoot.appendingPathComponent("xdg").path,
      "npm_config_cache": cacheRoot.appendingPathComponent("npm").path,
    ]
    if let port {
      environment[port.environmentVariable] = "\(port.value)"
    }
    let arguments = command.arguments.map { argument in
      port.map { argument.replacingOccurrences(of: "{{PORT}}", with: "\($0.value)") }
        ?? argument
    }
    return CodexManagedCommandRequest(
      command: [command.executable] + arguments,
      workingDirectory: currentDirectory,
      workspaceRoot: workspaceURL,
      environment: environment,
      timeoutSeconds: hasTimeout ? command.timeoutSeconds : nil,
      outputBytesCap: 80_000,
      permissionProfile: CodexPermissionProfiles.demo
    )
  }

  private func waitUntilReady(
    processID: String,
    readiness: DemoReadinessCheck,
    port: Int
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(readiness.timeoutSeconds)
    while ContinuousClock.now < deadline {
      guard await isRunning(processID: processID) else {
        throw DemoLauncherError.serviceStopped(
          await outputSummary(processID: processID)
        )
      }
      switch readiness.kind {
      case .process:
        try await Task.sleep(for: .milliseconds(500))
        if await isRunning(processID: processID) { return }
      case .http:
        let path = readiness.path ?? "/"
        if let url = URL(string: "http://127.0.0.1:\(port)\(path)") {
          var request = URLRequest(url: url)
          request.timeoutInterval = 1
          if let (_, response) = try? await urlSession.data(for: request),
            let http = response as? HTTPURLResponse,
            (200...399).contains(http.statusCode)
          {
            return
          }
        }
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw DemoLauncherError.readinessTimedOut(
      await outputSummary(processID: processID)
    )
  }

  private func isRunning(processID: String) async -> Bool {
    guard let snapshot = await executor?.managedCommandSnapshot(processID: processID) else {
      return false
    }
    if case .running = snapshot { return true }
    return false
  }

  private func outputSummary(processID: String) async -> String {
    guard let snapshot = await executor?.managedCommandSnapshot(processID: processID) else {
      return ""
    }
    let output: String
    switch snapshot {
    case .running(let standardOutput, let standardError):
      output = [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
    case .exited(let result):
      output = result.combinedOutput
    case .failed(let message):
      output = message
    }
    return ownerFacingLogSummary(output)
  }

  private func artifactURL(
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) throws -> URL {
    guard let path = specification.presentation.path else {
      throw DemoLaunchValidationError.invalid("the artifact path is missing.")
    }
    let url = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
      path,
      in: workspaceURL
    )
    guard fileManager.fileExists(atPath: url.path) else {
      throw DemoLauncherError.missingPresentation(path)
    }
    return url
  }

  private func applicationExecutable(
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) throws -> URL {
    let applicationURL = try artifactURL(
      specification: specification,
      workspaceURL: workspaceURL
    )
    guard
      applicationURL.pathExtension.lowercased() == "app",
      let executable = Bundle(url: applicationURL)?.executableURL,
      fileManager.isExecutableFile(atPath: executable.path)
    else {
      throw DemoLauncherError.missingPresentation(
        specification.presentation.path ?? "the reviewed app"
      )
    }
    return executable
  }

  private func allocateLoopbackPort() throws -> Int {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw DemoLauncherError.couldNotAllocatePort }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { throw DemoLauncherError.couldNotAllocatePort }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.getsockname(descriptor, $0, &length)
      }
    }
    guard nameResult == 0 else { throw DemoLauncherError.couldNotAllocatePort }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  private func ownerFacingLogSummary(_ value: String) -> String {
    let lines = value
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard lines.count > 10 else {
      return lines.joined(separator: " ")
    }
    return (Array(lines.prefix(6)) + ["…"] + Array(lines.suffix(4)))
      .joined(separator: " ")
  }
}
