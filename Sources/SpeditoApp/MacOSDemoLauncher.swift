import AppKit
import CFNetwork
import Darwin
import Foundation
import SpeditoCore

enum DemoLauncherError: Error, LocalizedError {
  case appServerUnavailable
  case managedWorkspaceUnavailable(String)
  case commandFailed(String)
  case commandTimedOut(String)
  case serviceStopped(String)
  case readinessTimedOut(String)
  case missingPresentation(String)
  case couldNotOpen(String)
  case couldNotAllocatePort
  case staticWebServerUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .appServerUnavailable:
      "The managed Codex runtime is not connected. Reconnect it before opening this demo."
    case .managedWorkspaceUnavailable(let detail):
      "Spedito could not create and clean up files inside the assigned managed demo workspace. If this repeats, check the Codex installation selected in settings.\(detail.isEmpty ? "" : " \(detail)")"
    case .commandFailed(let detail):
      "The demo preparation did not finish successfully.\(detail.isEmpty ? "" : " \(detail)")"
    case .commandTimedOut(let name):
      "The demo preparation took too long while running \(name)."
    case .serviceStopped(let detail):
      "The demo service stopped before it was ready.\(detail.isEmpty ? "" : " \(detail)")"
    case .readinessTimedOut(let detail):
      "The demo service did not become ready in time.\(detail.isEmpty ? "" : " \(detail)")"
    case .staticWebServerUnavailable(let detail):
      "Spedito could not serve the interactive prototype.\(detail.isEmpty ? "" : " \(detail)")"
    case .missingPresentation(let path):
      "The reviewed demo file is missing at \(path)."
    case .couldNotOpen(let title):
      "macOS could not open \(title)."
    case .couldNotAllocatePort:
      "Spedito could not reserve a local address for the demo."
    }
  }
}

enum DemoPreparationFailureDisposition: Equatable {
  case correctCandidate
  case retryPreparation
}

enum DemoPreparationFailurePolicy {
  static func disposition(for error: Error) -> DemoPreparationFailureDisposition {
    if error is DemoLaunchValidationError {
      return .correctCandidate
    }
    guard let launcherError = error as? DemoLauncherError else {
      return .retryPreparation
    }
    return switch launcherError {
    case .commandFailed, .commandTimedOut, .serviceStopped,
      .readinessTimedOut, .missingPresentation:
      .correctCandidate
    case .appServerUnavailable, .managedWorkspaceUnavailable, .couldNotOpen,
      .couldNotAllocatePort, .staticWebServerUnavailable:
      .retryPreparation
    }
  }
}

struct DemoLaunchOutcome: Equatable {
  let output: String?
  let allocatedPort: Int?
}

@MainActor
protocol DemoRunningApplication: AnyObject {
  var isTerminated: Bool { get }

  func activateForDemo()
  func terminateForDemo()
}

extension NSRunningApplication: DemoRunningApplication {
  func activateForDemo() {
    activate()
  }

  func terminateForDemo() {
    terminate()
  }
}

@MainActor
protocol DemoApplicationOpening {
  func openApplication(at applicationURL: URL) async throws -> any DemoRunningApplication
}

@MainActor
protocol DemoURLOpening {
  func open(_ url: URL) -> Bool
}

/// Opens a Spedito-authored launcher script in Terminal.app and brings
/// Terminal forward for a program that is still running.
@MainActor
protocol DemoTerminalOpening {
  func openScript(at scriptURL: URL) async throws
  func activateTerminal()
}

/// Liveness and termination for the reviewed program running in Terminal.
/// The program is a host process outside the managed sandbox, so the launcher
/// signals it directly rather than through the Codex runtime.
protocol DemoProcessSignaling: Sendable {
  func isAlive(_ processID: pid_t) -> Bool
  func terminate(_ processID: pid_t)
  func kill(_ processID: pid_t)
}

/// How long the launcher waits for the terminal program to record its process
/// id after the script opens, and how long a stop waits before escalating.
struct TerminalDemoLaunchTiming: Sendable {
  var processIDTimeout: Duration = .seconds(5)
  var pollInterval: Duration = .milliseconds(100)
  var stopTimeout: Duration = .seconds(2)

  static let standard = TerminalDemoLaunchTiming()
}

@MainActor
private final class WorkspaceDemoTerminalOpener: DemoTerminalOpening {
  private static let terminalBundleIdentifier = "com.apple.Terminal"
  private let workspace: NSWorkspace

  init(workspace: NSWorkspace) {
    self.workspace = workspace
  }

  func openScript(at scriptURL: URL) async throws {
    guard
      let terminalURL = workspace.urlForApplication(
        withBundleIdentifier: Self.terminalBundleIdentifier
      )
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      workspace.open(
        [scriptURL],
        withApplicationAt: terminalURL,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func activateTerminal() {
    NSRunningApplication
      .runningApplications(withBundleIdentifier: Self.terminalBundleIdentifier)
      .first?
      .activate()
  }
}

private struct DarwinDemoProcessSignaler: DemoProcessSignaling {
  func isAlive(_ processID: pid_t) -> Bool {
    Darwin.kill(processID, 0) == 0
  }

  func terminate(_ processID: pid_t) {
    _ = Darwin.kill(processID, SIGTERM)
  }

  func kill(_ processID: pid_t) {
    _ = Darwin.kill(processID, SIGKILL)
  }
}

@MainActor
private final class WorkspaceDemoApplicationOpener: DemoApplicationOpening {
  private let workspace: NSWorkspace

  init(workspace: NSWorkspace) {
    self.workspace = workspace
  }

  func openApplication(at applicationURL: URL) async throws -> any DemoRunningApplication {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    return try await withCheckedThrowingContinuation { continuation in
      workspace.openApplication(at: applicationURL, configuration: configuration) {
        application,
        error in
        if let application {
          continuation.resume(returning: application)
        } else {
          continuation.resume(
            throwing: error ?? CocoaError(.executableNotLoadable)
          )
        }
      }
    }
  }
}

@MainActor
private final class WorkspaceDemoURLOpener: DemoURLOpening {
  private let workspace: NSWorkspace

  init(workspace: NSWorkspace) {
    self.workspace = workspace
  }

  func open(_ url: URL) -> Bool {
    workspace.open(url)
  }
}

@MainActor
final class MacOSDemoLauncher {
  private struct Runtime {
    let processID: String?
    let application: (any DemoRunningApplication)?
    let staticWebServer: StaticWebDemoServer?
    let presentationURL: URL?
    let output: String?
    let allocatedPort: Int?
    /// The reviewed program running in Terminal, identified by the pid its
    /// launcher script recorded before `exec`. Transient operation state.
    var terminalProcessID: pid_t? = nil
    var terminalProcessIDFileURL: URL? = nil
  }

  private var runtimes: [UUID: Runtime] = [:]
  private var executor: (any CodexManagedCommandExecuting)?
  private let fileManager: FileManager
  private let urlOpener: any DemoURLOpening
  private let applicationOpener: any DemoApplicationOpening
  private let terminalOpener: any DemoTerminalOpening
  private let processSignaler: any DemoProcessSignaling
  private let terminalTiming: TerminalDemoLaunchTiming
  private let urlSession: URLSession

  init(
    executor: (any CodexManagedCommandExecuting)? = nil,
    fileManager: FileManager = .default,
    workspace: NSWorkspace = .shared,
    applicationOpener: (any DemoApplicationOpening)? = nil,
    urlOpener: (any DemoURLOpening)? = nil,
    terminalOpener: (any DemoTerminalOpening)? = nil,
    processSignaler: (any DemoProcessSignaling)? = nil,
    terminalTiming: TerminalDemoLaunchTiming = .standard,
    urlSession: URLSession? = nil
  ) {
    self.executor = executor
    self.fileManager = fileManager
    self.urlOpener = urlOpener ?? WorkspaceDemoURLOpener(workspace: workspace)
    self.applicationOpener =
      applicationOpener
      ?? WorkspaceDemoApplicationOpener(workspace: workspace)
    self.terminalOpener = terminalOpener ?? WorkspaceDemoTerminalOpener(workspace: workspace)
    self.processSignaler = processSignaler ?? DarwinDemoProcessSignaler()
    self.terminalTiming = terminalTiming
    self.urlSession = urlSession ?? Self.makeReadinessURLSession()
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
    if specification.presentation.kind != .staticWeb {
      try await verifyManagedWorkspaceAccess(workspaceURL: workspaceURL)
      try await runPreparation(
        specification.preparationCommands,
        workspaceURL: workspaceURL
      )
    }
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
    case .staticWeb:
      let runtime = try await startStaticWebPrototype(
        specification: specification,
        workspaceURL: workspaceURL,
        opensBrowser: false
      )
      runtimes[candidateID] = runtime
      await stop(candidateID: candidateID)
      return nil
    case .macApplication:
      _ = try applicationURL(
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
    case .terminalApplication:
      // An interactive program would hang a bounded smoke test, so the smoke
      // proves only that preparation left the reviewed program in place.
      _ = try terminalExecutableURL(
        specification: specification,
        workspaceURL: workspaceURL
      )
      return nil
    }
  }

  func launch(
    candidateID: UUID,
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) async throws -> DemoLaunchOutcome {
    try DemoLaunchSpecificationValidator.validate(specification)
    if let existing = runtimes[candidateID] {
      if let terminalProcessID = existing.terminalProcessID {
        if processSignaler.isAlive(terminalProcessID) {
          terminalOpener.activateTerminal()
          return DemoLaunchOutcome(output: nil, allocatedPort: nil)
        }
        // The owner closed the window or the program exited: drop the dead
        // runtime and relaunch from the reviewed checkout.
        if let pidFileURL = existing.terminalProcessIDFileURL {
          try? fileManager.removeItem(at: pidFileURL)
        }
        runtimes.removeValue(forKey: candidateID)
      } else if let processID = existing.processID {
        if await isRunning(processID: processID) {
          if let presentationURL = existing.presentationURL {
            _ = urlOpener.open(presentationURL)
          }
          return DemoLaunchOutcome(
            output: existing.output,
            allocatedPort: existing.allocatedPort
          )
        }
        await executor?.terminateManagedCommand(processID: processID)
        runtimes.removeValue(forKey: candidateID)
      } else if let application = existing.application {
        if !application.isTerminated {
          application.activateForDemo()
          return DemoLaunchOutcome(
            output: existing.output,
            allocatedPort: existing.allocatedPort
          )
        }
        runtimes.removeValue(forKey: candidateID)
      } else {
        if let presentationURL = existing.presentationURL {
          _ = urlOpener.open(presentationURL)
        }
        return DemoLaunchOutcome(
          output: existing.output,
          allocatedPort: existing.allocatedPort
        )
      }
    }

    if specification.presentation.kind != .staticWeb {
      try await verifyManagedWorkspaceAccess(workspaceURL: workspaceURL)
      try await runPreparation(
        specification.preparationCommands,
        workspaceURL: workspaceURL
      )
    }

    switch specification.presentation.kind {
    case .browser:
      let runtime = try await startBrowserService(
        specification: specification,
        workspaceURL: workspaceURL,
        opensBrowser: true
      )
      runtimes[candidateID] = runtime
      return DemoLaunchOutcome(output: nil, allocatedPort: runtime.allocatedPort)
    case .staticWeb:
      let runtime = try await startStaticWebPrototype(
        specification: specification,
        workspaceURL: workspaceURL,
        opensBrowser: true
      )
      runtimes[candidateID] = runtime
      return DemoLaunchOutcome(output: nil, allocatedPort: runtime.allocatedPort)
    case .macApplication:
      let applicationURL = try applicationURL(
        specification: specification,
        workspaceURL: workspaceURL
      )
      let application: any DemoRunningApplication
      do {
        application = try await applicationOpener.openApplication(at: applicationURL)
      } catch {
        throw DemoLauncherError.couldNotOpen(specification.title)
      }
      application.activateForDemo()
      runtimes[candidateID] = Runtime(
        processID: nil,
        application: application,
        staticWebServer: nil,
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
      guard urlOpener.open(url) else {
        throw DemoLauncherError.couldNotOpen(specification.title)
      }
      runtimes[candidateID] = Runtime(
        processID: nil,
        application: nil,
        staticWebServer: nil,
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
        staticWebServer: nil,
        presentationURL: nil,
        output: output,
        allocatedPort: nil
      )
      return DemoLaunchOutcome(output: output, allocatedPort: nil)
    case .terminalApplication:
      let runtime = try await startTerminalProgram(
        specification: specification,
        workspaceURL: workspaceURL
      )
      runtimes[candidateID] = runtime
      return DemoLaunchOutcome(output: nil, allocatedPort: nil)
    }
  }

  func stop(candidateID: UUID) async {
    guard let runtime = runtimes.removeValue(forKey: candidateID) else { return }
    if let terminalProcessID = runtime.terminalProcessID {
      await stopTerminalProgram(
        processID: terminalProcessID,
        processIDFileURL: runtime.terminalProcessIDFileURL
      )
    }
    if let processID = runtime.processID {
      await executor?.terminateManagedCommand(processID: processID)
      for _ in 0..<20 where await isRunning(processID: processID) {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    runtime.staticWebServer?.stop()
    if runtime.application?.isTerminated == false {
      runtime.application?.terminateForDemo()
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
        port: port,
        workspaceURL: workspaceURL
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
    if opensBrowser, !urlOpener.open(url) {
      await executor?.terminateManagedCommand(processID: processID)
      throw DemoLauncherError.couldNotOpen(specification.title)
    }
    return Runtime(
      processID: processID,
      application: nil,
      staticWebServer: nil,
      presentationURL: url,
      output: nil,
      allocatedPort: port
    )
  }

  private func startStaticWebPrototype(
    specification: DemoLaunchSpecification,
    workspaceURL: URL,
    opensBrowser: Bool
  ) async throws -> Runtime {
    let rootURL = try staticWebRootURL(
      specification: specification,
      workspaceURL: workspaceURL
    )
    let server: StaticWebDemoServer
    do {
      server = try StaticWebDemoServer(rootURL: rootURL, fileManager: fileManager)
    } catch {
      throw DemoLauncherError.staticWebServerUnavailable(error.localizedDescription)
    }
    let port: Int
    do {
      port = try await server.start()
    } catch {
      server.stop()
      if let launcherError = error as? DemoLauncherError {
        throw launcherError
      }
      throw DemoLauncherError.staticWebServerUnavailable(error.localizedDescription)
    }
    guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
      server.stop()
      throw DemoLauncherError.staticWebServerUnavailable("The loopback URL is invalid.")
    }
    do {
      try await verifyStaticWebPrototypeReady(at: url)
    } catch {
      server.stop()
      throw error
    }
    if opensBrowser, !urlOpener.open(url) {
      server.stop()
      throw DemoLauncherError.couldNotOpen(specification.title)
    }
    return Runtime(
      processID: nil,
      application: nil,
      staticWebServer: server,
      presentationURL: url,
      output: nil,
      allocatedPort: port
    )
  }

  private func staticWebRootURL(
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) throws -> URL {
    guard let path = specification.presentation.path else {
      throw DemoLaunchValidationError.invalid("the prototype directory is missing.")
    }
    let rootURL = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
      path,
      in: workspaceURL
    )
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DemoLauncherError.missingPresentation(path)
    }
    let indexPath = path.hasSuffix("/") ? "\(path)index.html" : "\(path)/index.html"
    let indexURL = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
      indexPath,
      in: workspaceURL
    )
    let values = try? indexURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
      throw DemoLauncherError.missingPresentation(indexPath)
    }
    return rootURL
  }

  private func verifyStaticWebPrototypeReady(at url: URL) async throws {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.timeoutInterval = 2
    do {
      let (_, response) = try await urlSession.data(for: request)
      guard
        let http = response as? HTTPURLResponse,
        (200...299).contains(http.statusCode)
      else {
        throw DemoLauncherError.staticWebServerUnavailable(
          "The prototype did not return a successful response."
        )
      }
    } catch let error as DemoLauncherError {
      throw error
    } catch {
      throw DemoLauncherError.staticWebServerUnavailable(error.localizedDescription)
    }
  }

  private func runPreparation(
    _ commands: [DemoCommand],
    workspaceURL: URL
  ) async throws {
    for command in commands {
      _ = try await runToCompletion(command, workspaceURL: workspaceURL)
    }
  }

  /// Proves the managed sandbox honors the full lifecycle preparation scripts
  /// rely on: creating directories and files inside the workspace and deleting
  /// them again. Deleting is checked explicitly because live failures have
  /// shown environments that allow creation while denying directory removal.
  private func verifyManagedWorkspaceAccess(workspaceURL: URL) async throws {
    guard let executor else { throw DemoLauncherError.appServerUnavailable }
    let accessCheckRoot =
      workspaceURL
      .appendingPathComponent(".spedito-demo-runtime", isDirectory: true)
      .appendingPathComponent("access-check", isDirectory: true)
    let nestedDirectory =
      accessCheckRoot
      .appendingPathComponent("nested", isDirectory: true)
    defer { try? fileManager.removeItem(at: accessCheckRoot) }
    let script = """
      set -e
      mkdir -p "\(nestedDirectory.path)"
      printf probe > "\(nestedDirectory.path)/probe"
      rm -rf "\(accessCheckRoot.path)"
      test ! -e "\(accessCheckRoot.path)"
      """
    let request = try managedRequest(
      DemoCommand(
        executable: "/bin/sh",
        arguments: ["-c", script],
        workingDirectory: ".",
        timeoutSeconds: 10
      ),
      workspaceURL: workspaceURL,
      port: nil,
      hasTimeout: true
    )
    let result = try await executor.runManagedCommand(request)
    guard result.exitCode == 0 else {
      throw DemoLauncherError.managedWorkspaceUnavailable(
        ownerFacingLogSummary(result.combinedOutput, workspaceURL: workspaceURL)
      )
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
      throw DemoLauncherError.commandFailed(
        ownerFacingLogSummary(output, workspaceURL: workspaceURL)
      )
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
    let runtimeRoot =
      workspaceURL
      .appendingPathComponent(".spedito-demo-runtime", isDirectory: true)
    let temporaryDirectory = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let cacheRoot = runtimeRoot.appendingPathComponent("cache", isDirectory: true)
    try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    var environment = [
      "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8",
      "TMPDIR": temporaryDirectory.path,
      "CFFIXED_USER_HOME": runtimeRoot.appendingPathComponent("home").path,
      "SPEDITO_DEMO_DATA_DIRECTORY": runtimeRoot.appendingPathComponent("data").path,
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
    port: Int,
    workspaceURL: URL
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(readiness.timeoutSeconds)
    var lastReadinessDetail = ""
    while ContinuousClock.now < deadline {
      guard await isRunning(processID: processID) else {
        throw DemoLauncherError.serviceStopped(
          await outputSummary(processID: processID, workspaceURL: workspaceURL)
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
          request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
          request.timeoutInterval = 1
          do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
              if (200...399).contains(http.statusCode) {
                return
              }
              lastReadinessDetail = "The loopback endpoint returned HTTP \(http.statusCode)."
            } else {
              lastReadinessDetail = "The loopback endpoint returned an invalid response."
            }
          } catch {
            lastReadinessDetail = "The loopback request failed: \(error.localizedDescription)"
          }
        }
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    let processDetail = await outputSummary(processID: processID, workspaceURL: workspaceURL)
    throw DemoLauncherError.readinessTimedOut(
      [processDetail, lastReadinessDetail]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    )
  }

  private static func makeReadinessURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    configuration.connectionProxyDictionary = [
      kCFNetworkProxiesHTTPEnable as String: false,
      kCFNetworkProxiesHTTPSEnable as String: false,
      kCFNetworkProxiesSOCKSEnable as String: false,
    ]
    return URLSession(configuration: configuration)
  }

  private func isRunning(processID: String) async -> Bool {
    guard let snapshot = await executor?.managedCommandSnapshot(processID: processID) else {
      return false
    }
    if case .running = snapshot { return true }
    return false
  }

  private func outputSummary(processID: String, workspaceURL: URL) async -> String {
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
    return ownerFacingLogSummary(output, workspaceURL: workspaceURL)
  }

  /// The reviewed program a terminal app demo runs: a regular, non-symlink,
  /// executable file inside the preview checkout. Both the smoke test and the
  /// launch resolve it here, so a program that preparation did not build, or
  /// one that escapes the workspace, is a candidate failure before any
  /// Terminal window opens.
  private func terminalExecutableURL(
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) throws -> URL {
    guard let command = specification.launchCommand else {
      throw DemoLaunchValidationError.invalid("the terminal app launch command is missing.")
    }
    let executableURL = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
      command.executable,
      in: workspaceURL
    )
    let unresolvedURL = workspaceURL.appendingPathComponent(command.executable)
    let unresolvedValues = try? unresolvedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    let values = try? executableURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard
      unresolvedValues?.isSymbolicLink != true,
      values?.isRegularFile == true,
      values?.isSymbolicLink != true,
      fileManager.isExecutableFile(atPath: executableURL.path)
    else {
      throw DemoLauncherError.missingPresentation(command.executable)
    }
    return executableURL
  }

  /// Writes the Spedito-authored launcher script into the preview's runtime
  /// directory and opens it with Terminal.app. The script records the
  /// program's pid before `exec`, and the launch is complete only once that
  /// pid has been read back; the pid is the launcher's handle on the program
  /// for reuse and Stop demo.
  private func startTerminalProgram(
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) async throws -> Runtime {
    guard let command = specification.launchCommand else {
      throw DemoLaunchValidationError.invalid("the terminal app launch command is missing.")
    }
    _ = try terminalExecutableURL(specification: specification, workspaceURL: workspaceURL)
    let workingDirectoryURL = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
      command.workingDirectory,
      in: workspaceURL
    )
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: workingDirectoryURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DemoLauncherError.missingPresentation(command.workingDirectory)
    }
    let resolvedWorkspaceURL = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    let runtimeRoot =
      resolvedWorkspaceURL
      .appendingPathComponent(".spedito-demo-runtime", isDirectory: true)
    let launchID = UUID()
    let scriptURL = TerminalDemoLaunchScript.scriptURL(
      runtimeDirectoryURL: runtimeRoot,
      launchID: launchID
    )
    let processIDFileURL = TerminalDemoLaunchScript.processIDURL(
      runtimeDirectoryURL: runtimeRoot,
      launchID: launchID
    )
    do {
      for directory in TerminalDemoLaunchScript.requiredDirectories(
        runtimeDirectoryURL: runtimeRoot
      ) {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      let script = try TerminalDemoLaunchScript.text(
        specification: specification,
        workspaceURL: resolvedWorkspaceURL,
        runtimeDirectoryURL: runtimeRoot,
        launchID: launchID
      )
      try Data(script.utf8).write(to: scriptURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: scriptURL.path
      )
    } catch let error as DemoLaunchValidationError {
      throw error
    } catch {
      throw DemoLauncherError.couldNotOpen(specification.title)
    }
    do {
      try await terminalOpener.openScript(at: scriptURL)
    } catch {
      throw DemoLauncherError.couldNotOpen(specification.title)
    }
    guard let processID = await waitForTerminalProcessID(at: processIDFileURL) else {
      throw DemoLauncherError.couldNotOpen(specification.title)
    }
    return Runtime(
      processID: nil,
      application: nil,
      staticWebServer: nil,
      presentationURL: nil,
      output: nil,
      allocatedPort: nil,
      terminalProcessID: processID,
      terminalProcessIDFileURL: processIDFileURL
    )
  }

  private func waitForTerminalProcessID(at url: URL) async -> pid_t? {
    let deadline = ContinuousClock.now + terminalTiming.processIDTimeout
    while true {
      if let data = try? Data(contentsOf: url),
        let value = pid_t(
          String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        value > 0
      {
        return value
      }
      guard ContinuousClock.now < deadline else { return nil }
      try? await Task.sleep(for: terminalTiming.pollInterval)
    }
  }

  /// Ends the reviewed program: SIGTERM, a bounded wait, then SIGKILL. The
  /// Terminal window is never closed — like a browser tab, it may belong to
  /// the owner. The pid file goes with the runtime so a stale pid is never
  /// signalled later.
  private func stopTerminalProgram(processID: pid_t, processIDFileURL: URL?) async {
    if processSignaler.isAlive(processID) {
      processSignaler.terminate(processID)
      let deadline = ContinuousClock.now + terminalTiming.stopTimeout
      while processSignaler.isAlive(processID), ContinuousClock.now < deadline {
        try? await Task.sleep(for: terminalTiming.pollInterval)
      }
      if processSignaler.isAlive(processID) {
        processSignaler.kill(processID)
      }
    }
    if let processIDFileURL {
      try? fileManager.removeItem(at: processIDFileURL)
    }
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
    try DemoArtifactPolicy.validateExistingFile(at: url, fileManager: fileManager)
    return url
  }

  private func applicationURL(
    specification: DemoLaunchSpecification,
    workspaceURL: URL
  ) throws -> URL {
    guard let path = specification.presentation.path else {
      throw DemoLaunchValidationError.invalid("the application path is missing.")
    }
    let applicationURL = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
      path,
      in: workspaceURL
    )
    guard
      applicationURL.pathExtension.lowercased() == "app",
      let executable = Bundle(url: applicationURL)?.executableURL,
      fileManager.isExecutableFile(atPath: executable.path)
    else {
      throw DemoLauncherError.missingPresentation(path)
    }
    return applicationURL
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

  /// Absolute paths inside the assigned workspace are internal machinery, so
  /// they are rewritten as workspace-relative paths before the text can reach
  /// the owner in an alert or a work log entry.
  private func ownerFacingLogSummary(_ value: String, workspaceURL: URL) -> String {
    let workspacePrefixes = Self.ownerHiddenPathPrefixes(workspaceURL: workspaceURL)
    var sanitized = value
    for prefix in workspacePrefixes {
      sanitized = sanitized.replacingOccurrences(of: prefix + "/", with: "")
      sanitized = sanitized.replacingOccurrences(of: prefix, with: "the demo workspace")
    }
    let lines =
      sanitized
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard lines.count > 10 else {
      return lines.joined(separator: " ")
    }
    return (Array(lines.prefix(6)) + ["…"] + Array(lines.suffix(4)))
      .joined(separator: " ")
  }

  private static func ownerHiddenPathPrefixes(workspaceURL: URL) -> [String] {
    let standardized = workspaceURL.standardizedFileURL
    var candidates = [
      standardized.path,
      standardized.resolvingSymlinksInPath().path,
    ]
    // Tool output frequently reports /var and /tmp under their /private form.
    for path in candidates where !path.hasPrefix("/private/") {
      candidates.append("/private" + path)
    }
    var seen: Set<String> = []
    return candidates.filter { $0 != "/" && seen.insert($0).inserted }
  }
}
