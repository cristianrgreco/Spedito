import Foundation
import Testing

@testable import StoryPointlessApp
@testable import StoryPointlessCore

@Suite("macOS managed demo launcher", .serialized)
@MainActor
struct MacOSDemoLauncherTests {
  @Test("A bounded command is sandboxed and its output is captured")
  func commandOutput() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executor = DemoCommandExecutorStub()
    let launcher = MacOSDemoLauncher(executor: executor)
    let candidateID = UUID()
    let specification = DemoLaunchSpecification(
      title: "Captured result",
      launchCommand: DemoCommand(
        executable: "/usr/bin/printf",
        arguments: ["A one-click result\\n"],
        timeoutSeconds: 5
      ),
      presentation: DemoPresentation(kind: .commandOutput)
    )

    let outcome = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )

    #expect(outcome.output == "A one-click result")
    let request = try #require(await executor.completedRequests().first)
    #expect(request.command == ["/usr/bin/printf", "A one-click result\\n"])
    #expect(request.permissionProfile == CodexPermissionProfiles.demo)
    await launcher.stop(candidateID: candidateID)
  }

  @Test("A loopback web service becomes ready and is stopped after its smoke test")
  func webSmokeTest() async throws {
    guard
      FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
        || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3")
    else {
      return
    }
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try Data("ready\n".utf8).write(to: workspace.appendingPathComponent("index.html"))
    let executor = DemoCommandExecutorStub()
    let launcher = MacOSDemoLauncher(executor: executor)
    let specification = DemoLaunchSpecification(
      title: "Local page",
      launchCommand: DemoCommand(
        executable: "python3",
        arguments: ["-u", "-m", "http.server", "{{PORT}}", "--bind", "127.0.0.1"],
        timeoutSeconds: 30
      ),
      portEnvironmentVariable: "PORT",
      readiness: DemoReadinessCheck(kind: .http, path: "/", timeoutSeconds: 30),
      presentation: DemoPresentation(kind: .browser, path: "/index.html")
    )

    _ = try await launcher.smokeTest(
      candidateID: UUID(),
      specification: specification,
      workspaceURL: workspace
    )
    #expect(await executor.runningProcessCount() == 0)
  }

  @Test("Homebrew Node can read its approved OpenSSL runtime configuration")
  func homebrewNodeCommandOutput() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/node") else {
      return
    }
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executor = DemoCommandExecutorStub()
    let launcher = MacOSDemoLauncher(executor: executor)
    let specification = DemoLaunchSpecification(
      title: "Node checks",
      launchCommand: DemoCommand(
        executable: "node",
        arguments: ["--eval", "process.stdout.write('node ready')"],
        timeoutSeconds: 5
      ),
      presentation: DemoPresentation(kind: .commandOutput)
    )

    let outcome = try await launcher.launch(
      candidateID: UUID(),
      specification: specification,
      workspaceURL: workspace
    )

    #expect(outcome.output == "node ready")
  }

  @Test("Command failures preserve the actionable root error")
  func actionableCommandFailure() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let launcher = MacOSDemoLauncher(executor: DemoCommandExecutorStub())
    let specification = DemoLaunchSpecification(
      title: "Failing checks",
      launchCommand: DemoCommand(executable: "failing-test"),
      presentation: DemoPresentation(kind: .commandOutput)
    )

    do {
      _ = try await launcher.smokeTest(
        candidateID: UUID(),
        specification: specification,
        workspaceURL: workspace
      )
      Issue.record("Expected the command to fail")
    } catch {
      #expect(error.localizedDescription.contains("EPERM: operation not permitted"))
      #expect(error.localizedDescription.contains("test failed"))
    }
  }

  @Test("Candidate-controlled demo failures return for correction")
  func candidateFailureDisposition() {
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: DemoLauncherError.commandFailed("Build failed")
      ) == .correctCandidate
    )
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: DemoLauncherError.serviceStopped("No build found")
      ) == .correctCandidate
    )
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: DemoLauncherError.readinessTimedOut("No response")
      ) == .correctCandidate
    )
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: DemoLaunchValidationError.invalid("Missing launch command")
      ) == .correctCandidate
    )
  }

  @Test("Host demo failures preserve the reviewed candidate for retry")
  func hostFailureDisposition() {
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: DemoLauncherError.appServerUnavailable
      ) == .retryPreparation
    )
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: DemoLauncherError.couldNotAllocatePort
      ) == .retryPreparation
    )
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: CocoaError(.fileReadUnknown)
      ) == .retryPreparation
    )
  }

  private func makeWorkspace() throws -> URL {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("storypointless-demo-launch-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    return workspace
  }
}

private actor DemoCommandExecutorStub: CodexManagedCommandExecuting {
  private struct RunningProcess {
    let process: Process
    let outputURL: URL
    let outputHandle: FileHandle
  }

  private var completed: [CodexManagedCommandRequest] = []
  private var processes: [String: RunningProcess] = [:]

  func runManagedCommand(
    _ request: CodexManagedCommandRequest
  ) async throws -> CodexManagedCommandResult {
    completed.append(request)
    if request.command.first?.hasSuffix("printf") == true {
      return CodexManagedCommandResult(
        exitCode: 0,
        standardOutput: "A one-click result\n",
        standardError: ""
      )
    }
    if request.command.first == "node" {
      return CodexManagedCommandResult(
        exitCode: 0,
        standardOutput: "node ready",
        standardError: ""
      )
    }
    if request.command.first == "failing-test" {
      return CodexManagedCommandResult(
        exitCode: 1,
        standardOutput: """
          node:fs:2787
          const stats = binding.lstat(base)
          Error: EPERM: operation not permitted, lstat '/protected/path'
          at Object.realpathSync
          at toRealPath
          at Module._findPath
          ℹ tests 2
          ℹ pass 0
          ℹ fail 2
          ✖ failing tests:
          test at example.test.mjs:1:1
          'test failed'
          """,
        standardError: ""
      )
    }
    return CodexManagedCommandResult(exitCode: 0, standardOutput: "", standardError: "")
  }

  func startManagedCommand(_ request: CodexManagedCommandRequest) async throws -> String {
    let processID = UUID().uuidString
    let process = Process()
    let executable =
      if request.command.first == "python3" {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") {
          "/opt/homebrew/bin/python3"
        } else {
          "/usr/local/bin/python3"
        }
      } else {
        request.command.first ?? ""
      }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(request.command.dropFirst())
    process.currentDirectoryURL = request.workingDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(request.environment) {
      _, requested in requested
    }
    let outputURL = request.workspaceRoot
      .appendingPathComponent(".demo-test-process-\(processID).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    do {
      try process.run()
    } catch {
      try? outputHandle.close()
      throw error
    }
    processes[processID] = RunningProcess(
      process: process,
      outputURL: outputURL,
      outputHandle: outputHandle
    )
    return processID
  }

  func managedCommandSnapshot(
    processID: String
  ) async -> CodexManagedCommandSnapshot? {
    guard let runningProcess = processes[processID] else { return nil }
    let output = (try? String(contentsOf: runningProcess.outputURL, encoding: .utf8)) ?? ""
    if runningProcess.process.isRunning {
      return .running(standardOutput: output, standardError: "")
    }
    return .exited(
      CodexManagedCommandResult(
        exitCode: Int(runningProcess.process.terminationStatus),
        standardOutput: output,
        standardError: ""
      )
    )
  }

  func terminateManagedCommand(processID: String) async {
    guard let runningProcess = processes.removeValue(forKey: processID) else { return }
    if runningProcess.process.isRunning {
      runningProcess.process.terminate()
      runningProcess.process.waitUntilExit()
    }
    try? runningProcess.outputHandle.close()
  }

  func completedRequests() -> [CodexManagedCommandRequest] {
    completed
  }

  func runningProcessCount() -> Int {
    processes.values.filter(\.process.isRunning).count
  }
}
