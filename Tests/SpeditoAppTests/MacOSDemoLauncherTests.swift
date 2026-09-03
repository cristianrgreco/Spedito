import AppKit
import Foundation
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

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
    let request = try #require(
      await executor.completedRequests().first {
        $0.command.first?.hasSuffix("printf") == true
      }
    )
    #expect(request.command == ["/usr/bin/printf", "A one-click result\\n"])
    #expect(request.permissionProfile == CodexPermissionProfiles.demo)
    await launcher.stop(candidateID: candidateID)
  }

  @Test("A browser service becomes ready and is stopped after its smoke test")
  func webSmokeTest() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executor = DemoCommandExecutorStub()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadyLoopbackURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)
    defer { urlSession.invalidateAndCancel() }
    let launcher = MacOSDemoLauncher(executor: executor, urlSession: urlSession)
    let specification = DemoLaunchSpecification(
      title: "Local page",
      launchCommand: DemoCommand(
        executable: "test-browser-service",
        arguments: ["{{PORT}}"],
        timeoutSeconds: 30
      ),
      portEnvironmentVariable: "PORT",
      readiness: DemoReadinessCheck(kind: .http, path: "/", timeoutSeconds: 30),
      presentation: DemoPresentation(kind: .browser, path: "/index.html")
    )

    ReadyLoopbackURLProtocol.resetProbedPorts()
    _ = try await launcher.smokeTest(
      candidateID: UUID(),
      specification: specification,
      workspaceURL: workspace
    )
    #expect(await executor.runningProcessCount() == 0)
    let request = try #require(await executor.startedRequests().first)
    let port = try #require(request.environment["PORT"])
    let injectedPort = try #require(Int(port))
    #expect(request.command == ["test-browser-service", port])
    #expect(request.permissionProfile == CodexPermissionProfiles.demo)
    let probedPorts = Set(ReadyLoopbackURLProtocol.probedPorts)
    #expect(probedPorts == [injectedPort])
  }

  @Test("D14 static web prototype is served, reopened, and stopped without a product runtime")
  func d14StaticWebPrototypeUsesHostOwnedServer() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let prototype = workspace.appendingPathComponent("prototype", isDirectory: true)
    try FileManager.default.createDirectory(at: prototype, withIntermediateDirectories: true)
    try Data(
      """
      <!doctype html>
      <html><body><button id="choose">Choose Manchester</button><script src="app.js"></script></body></html>
      """.utf8
    ).write(to: prototype.appendingPathComponent("index.html"))
    try Data("document.querySelector('#choose').dataset.ready = 'true';".utf8)
      .write(to: prototype.appendingPathComponent("app.js"))

    let opener = DemoURLOpenerStub()
    let launcher = MacOSDemoLauncher(urlOpener: opener)
    let candidateID = UUID()
    let specification = DemoLaunchSpecification(
      title: "Forecast interaction prototype",
      presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
    )

    let first = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    let firstURL = try #require(opener.openedURLs.first)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (pageData, pageResponse) = try await session.data(from: firstURL)
    let http = try #require(pageResponse as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(String(decoding: pageData, as: UTF8.self).contains("Choose Manchester"))
    #expect(
      http.value(forHTTPHeaderField: "Content-Security-Policy")?
        .contains("connect-src 'none'") == true
    )
    let (scriptData, scriptResponse) = try await session.data(
      from: firstURL.appendingPathComponent("app.js")
    )
    #expect((scriptResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: scriptData, as: UTF8.self).contains("dataset.ready"))

    let reopened = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    #expect(first.allocatedPort != nil)
    #expect(reopened.allocatedPort == first.allocatedPort)
    #expect(opener.openedURLs == [firstURL, firstURL])

    await launcher.stop(candidateID: candidateID)
  }

  @Test("Static web resources cannot leave the prototype directory")
  func staticWebResourcesStayInsidePrototype() throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let prototype = workspace.appendingPathComponent("prototype", isDirectory: true)
    try FileManager.default.createDirectory(at: prototype, withIntermediateDirectories: true)
    let index = prototype.appendingPathComponent("index.html")
    try Data("prototype".utf8).write(to: index)
    let secret = workspace.appendingPathComponent("secret.txt")
    try Data("secret".utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(
      at: prototype.appendingPathComponent("escape.txt"),
      withDestinationURL: secret
    )

    #expect(
      try StaticWebResourcePolicy.resolve(requestTarget: "/", in: prototype) == index
    )
    #expect(throws: StaticWebResourcePolicy.Error.self) {
      try StaticWebResourcePolicy.resolve(
        requestTarget: "/%2E%2E/secret.txt",
        in: prototype
      )
    }
    #expect(throws: StaticWebResourcePolicy.Error.self) {
      try StaticWebResourcePolicy.resolve(requestTarget: "/escape.txt", in: prototype)
    }
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

  @Test("A macOS app is opened by Spedito instead of as a managed command")
  func macApplicationPresentation() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let applicationURL = try makeApplication(at: workspace)
    let executor = DemoCommandExecutorStub()
    let application = DemoRunningApplicationStub()
    let opener = DemoApplicationOpenerStub(application: application)
    let launcher = MacOSDemoLauncher(
      executor: executor,
      applicationOpener: opener
    )
    let candidateID = UUID()
    let specification = DemoLaunchSpecification(
      title: "Native editor",
      presentation: DemoPresentation(kind: .macApplication, path: "Demo.app")
    )

    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )

    #expect(opener.openedApplicationURLs == [applicationURL])
    #expect(application.activationCount == 2)
    #expect(await executor.startedRequests().isEmpty)

    await launcher.stop(candidateID: candidateID)
    #expect(application.terminationCount == 1)
  }

  @Test("A closed macOS demo can be opened again")
  func closedMacApplicationPresentation() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let applicationURL = try makeApplication(at: workspace)
    let executor = DemoCommandExecutorStub()
    let firstApplication = DemoRunningApplicationStub()
    let replacementApplication = DemoRunningApplicationStub()
    let opener = DemoApplicationOpenerStub(
      applications: [firstApplication, replacementApplication]
    )
    let launcher = MacOSDemoLauncher(
      executor: executor,
      applicationOpener: opener
    )
    let candidateID = UUID()
    let specification = DemoLaunchSpecification(
      title: "Native editor",
      presentation: DemoPresentation(kind: .macApplication, path: "Demo.app")
    )

    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    firstApplication.isTerminated = true
    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )

    #expect(opener.openedApplicationURLs == [applicationURL, applicationURL])
    #expect(firstApplication.activationCount == 1)
    #expect(replacementApplication.activationCount == 1)
    #expect(await executor.startedRequests().isEmpty)

    await launcher.stop(candidateID: candidateID)
    #expect(replacementApplication.terminationCount == 1)
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

  @Test("An unusable assigned preview is a host failure before candidate execution")
  func managedWorkspaceFailure() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executor = DemoCommandExecutorStub(failsManagedWorkspaceCheck: true)
    let launcher = MacOSDemoLauncher(executor: executor)
    let specification = DemoLaunchSpecification(
      title: "Candidate result",
      launchCommand: DemoCommand(executable: "/usr/bin/printf", arguments: ["ready"]),
      presentation: DemoPresentation(kind: .commandOutput)
    )

    do {
      _ = try await launcher.smokeTest(
        candidateID: UUID(),
        specification: specification,
        workspaceURL: workspace
      )
      Issue.record("Expected the managed workspace check to fail")
    } catch let error as DemoLauncherError {
      guard case .managedWorkspaceUnavailable(let detail) = error else {
        Issue.record("Expected a managed workspace failure, received \(error)")
        return
      }
      #expect(detail.contains("Operation not permitted"))
      #expect(
        DemoPreparationFailurePolicy.disposition(for: error) == .retryPreparation
      )
    }
    #expect(
      await executor.completedRequests().allSatisfy {
        DemoCommandExecutorStub.isAccessCheck($0)
      }
    )
  }

  @Test("A workspace that allows creation but denies deletion fails before preparation")
  func managedWorkspaceDeletionDenied() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executor = DemoCommandExecutorStub(deniesManagedWorkspaceDeletion: true)
    let launcher = MacOSDemoLauncher(executor: executor)
    let specification = DemoLaunchSpecification(
      title: "Candidate result",
      preparationCommands: [
        DemoCommand(executable: "scripts/prepare-demo.sh", timeoutSeconds: 30)
      ],
      launchCommand: DemoCommand(executable: "/usr/bin/printf", arguments: ["ready"]),
      presentation: DemoPresentation(kind: .commandOutput)
    )

    do {
      _ = try await launcher.smokeTest(
        candidateID: UUID(),
        specification: specification,
        workspaceURL: workspace
      )
      Issue.record("Expected the managed workspace deletion check to fail")
    } catch let error as DemoLauncherError {
      guard case .managedWorkspaceUnavailable = error else {
        Issue.record("Expected a managed workspace failure, received \(error)")
        return
      }
      #expect(error.localizedDescription.contains("Operation not permitted"))
      #expect(!error.localizedDescription.contains(workspace.path))
      #expect(!error.localizedDescription.lowercased().contains("worktree"))
      #expect(
        DemoPreparationFailurePolicy.disposition(for: error) == .retryPreparation
      )
    }
    let requests = await executor.completedRequests()
    #expect(requests.count == 1)
    #expect(requests.allSatisfy { DemoCommandExecutorStub.isAccessCheck($0) })
    let accessCheck = try #require(requests.first)
    #expect(accessCheck.command.contains { $0.contains("rm -rf") })
  }

  @Test("Preparation failure text rewrites workspace paths as relative paths")
  func preparationFailureTextHidesWorkspacePaths() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let executor = DemoCommandExecutorStub(
      failingPreparationOutput: """
        rm: \(workspace.path)/.demo/App.app/Contents/MacOS: Operation not permitted
        rm: \(workspace.path)/.demo: Operation not permitted
        """
    )
    let launcher = MacOSDemoLauncher(executor: executor)
    let specification = DemoLaunchSpecification(
      title: "Native preview",
      preparationCommands: [
        DemoCommand(executable: "failing-preparation", timeoutSeconds: 30)
      ],
      launchCommand: DemoCommand(executable: "/usr/bin/printf", arguments: ["ready"]),
      presentation: DemoPresentation(kind: .commandOutput)
    )

    do {
      _ = try await launcher.smokeTest(
        candidateID: UUID(),
        specification: specification,
        workspaceURL: workspace
      )
      Issue.record("Expected the preparation to fail")
    } catch let error as DemoLauncherError {
      guard case .commandFailed(let detail) = error else {
        Issue.record("Expected a preparation failure, received \(error)")
        return
      }
      #expect(detail.contains("rm: .demo/App.app/Contents/MacOS: Operation not permitted"))
      #expect(!detail.contains(workspace.path))
      #expect(!detail.lowercased().contains("worktree"))
      #expect(
        DemoPreparationFailurePolicy.disposition(for: error) == .correctCandidate
      )
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
        for: DemoLauncherError.managedWorkspaceUnavailable(
          "mkdir: Operation not permitted"
        )
      ) == .retryPreparation
    )
    #expect(
      DemoPreparationFailurePolicy.disposition(
        for: CocoaError(.fileReadUnknown)
      ) == .retryPreparation
    )
  }

  /// Existing partial coverage:
  /// - `DemoLaunchTests.acceptedMacApplicationHistory`
  /// - `MacOSDemoLauncherTests.macApplicationPresentation`
  /// This test covers only V06's historical-version selection through the managed launch command.
  @Test("V06 selecting an accepted historical App version launches that exact revision")
  func v06HistoricalAcceptedVersionLaunchesExactRevision() async throws {
    let databaseRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-v06-\(UUID())",
      isDirectory: true
    )
    let store = try SQLiteStore(url: databaseRoot.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Version history")
    let supportRoot = try appApplicationSupportURL()
    let workspace = supportRoot
      .appendingPathComponent("Product Workspaces", isDirectory: true)
      .appendingPathComponent(product.id.uuidString, isDirectory: true)
    let cachesRoot = try #require(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    )
    let previewsRoot = cachesRoot
      .appendingPathComponent("Spedito", isDirectory: true)
      .appendingPathComponent("PreviewWorktrees", isDirectory: true)
      .appendingPathComponent(product.id.uuidString, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: databaseRoot)
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: previewsRoot)
    }
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    var item = try await store.createWorkItem(
      productID: product.id,
      title: "Ship the native preview",
      acceptanceCriteria: ["The accepted app opens"]
    )
    item = try await store.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine"
    )
    item = try await store.transitionWorkItem(
      id: item.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready for delivery"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Ship two accepted versions",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: implementer.id,
          estimatedTokens: 1
        )
      ]
    )
    let plan = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(plan.items.first)
    let run = try #require(try await store.fetchAgentRuns(productID: product.id).first)
    let git = GitWorkspaceManager()
    let baseSHA = try await git.ensureRepository(at: workspace)
    let applicationURL = try makeApplication(at: workspace)
    let executableURL = applicationURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent("Demo")
    try Data("#!/bin/sh\n# historical accepted build\n".utf8).write(to: executableURL)
    let historicalSHA = try await git.checkpointTrunk(
      at: workspace,
      message: "Accept historical version"
    )
    try Data("#!/bin/sh\n# newer accepted build\n".utf8).write(to: executableURL)
    let newerSHA = try await git.checkpointTrunk(
      at: workspace,
      message: "Accept newer version"
    )
    let specification = DemoLaunchSpecification(
      title: "Native preview",
      presentation: DemoPresentation(kind: .macApplication, path: "Demo.app")
    )
    let result = TicketExecutionResult(
      status: .completed,
      comment: "Accepted app version.",
      question: nil,
      options: [],
      summary: "The native preview is ready.",
      changedFiles: ["Demo.app"],
      tests: ["Managed App version journey"],
      knowledgeNotes: [],
      reviewInstructions: ["Open the accepted native preview."],
      demo: specification,
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    let resultData = try JSONEncoder().encode(result)
    let resultJSON = try #require(String(data: resultData, encoding: .utf8))
    let historicalID = UUID()
    let newerID = UUID()
    let historical = CandidateRevision(
      id: historicalID,
      productID: product.id,
      sprintID: plan.sprint.id,
      sprintItemID: sprintItem.id,
      workItemID: item.id,
      implementationRunID: run.id,
      version: 1,
      branchName: "ticket/\(item.key)",
      baseSHA: baseSHA,
      headSHA: historicalSHA,
      integratedSHA: historicalSHA,
      worktreePath: workspace.path,
      integrationWorktreePath: workspace.path,
      status: .accepted,
      commitCount: 1,
      executionResultJSON: resultJSON,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let newer = CandidateRevision(
      id: newerID,
      productID: product.id,
      sprintID: plan.sprint.id,
      sprintItemID: sprintItem.id,
      workItemID: item.id,
      implementationRunID: run.id,
      version: 2,
      branchName: "ticket/\(item.key)",
      baseSHA: historicalSHA,
      headSHA: newerSHA,
      integratedSHA: newerSHA,
      worktreePath: workspace.path,
      integrationWorktreePath: workspace.path,
      status: .accepted,
      commitCount: 1,
      executionResultJSON: resultJSON,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    #expect(
      AcceptedAppLaunchPolicy.all(in: [historical, newer]).map(\.candidate.id)
        == [newerID, historicalID]
    )
    _ = try await store.createCandidateRevision(historical)
    _ = try await store.createCandidateRevision(newer)
    #expect(try await store.fetchCandidateRevisions(productID: product.id).count == 2)
    let application = DemoRunningApplicationStub()
    let opener = DemoApplicationOpenerStub(application: application)
    let launcher = MacOSDemoLauncher(
      executor: DemoCommandExecutorStub(),
      applicationOpener: opener
    )
    let model = AppModel(store: store, selectedProductID: product.id)
    model.demoSessionFeature.launcher = launcher
    await model.reload()
    #expect(model.selectedProductID == product.id)
    #expect(model.errorMessage == nil)
    #expect(model.candidateRevisions.map(\.id) == [historicalID, newerID])
    #expect(model.candidateRevisions.map(\.status) == [.accepted, .accepted])

    #expect(model.appVersions.map(\.id) == [newerID, historicalID])
    #expect(await model.openAppVersion(id: historicalID))
    let session = try #require(model.currentAppVersionSession(id: historicalID))
    let previewExecutable = URL(
      fileURLWithPath: try #require(session.previewWorktreePath),
      isDirectory: true
    )
    .appendingPathComponent("Demo.app/Contents/MacOS/Demo")
    .path
    #expect(session.status == .ready)
    #expect(model.currentAppVersionSession(id: newerID) == nil)
    #expect(
      try String(contentsOfFile: previewExecutable, encoding: .utf8)
        == "#!/bin/sh\n# historical accepted build\n"
    )
    #expect(opener.openedApplicationURLs.count == 1)

    await model.stopAppVersion(id: historicalID)
    await model.shutdown()
    await store.close()
  }

  /// Real-sandbox parity: preparation scripts that create, overwrite, and
  /// delete their own files and directories — including artifacts left by an
  /// earlier preparation run in a separate sandbox instance — must succeed
  /// against the real Codex runtime in the real preview worktree location.
  ///
  /// This is the executable form of the live failures where `rm` was denied
  /// `file-write-unlink` on directories the product's own scripts created.
  ///
  /// It resolves the runtime the application itself resolves, and fails rather
  /// than skips when none is found. The two tests this replaced did neither: a
  /// hardcoded binary the app need not use, and a `SPEDITO_PILOT`-gated twin
  /// the documented validation never ran. Both returned early — and so passed
  /// — whenever the binary was absent, which is why CI reported green
  /// throughout the outage.
  @Test("Demo preparation can create and delete its own artifacts in the real sandbox")
  func realSandboxCreateDeleteParity() async throws {
    try await assertCreateDeleteParity(
      codexURL: CodexSandboxRuntimeLocator.resolve()
    )
  }

  /// The canonical demo recipe page must hand a downstream ticket a recipe
  /// that actually executes, not one that is merely well-formed. This reuses
  /// the create/delete parity fixture and round-trips the specification
  /// through the published page body before smoke-testing it in the real
  /// sandbox.
  @Test("An inherited canonical recipe is executable in the real sandbox")
  func inheritedCanonicalRecipeIsExecutable() async throws {
    let codexURL = try CodexSandboxRuntimeLocator.resolve()
    try await assertCreateDeleteParity(codexURL: codexURL) { accepted in
      let body = try CanonicalDemoRecipeKnowledge.bodyMarkdown(for: accepted)
      let inherited = try #require(
        CanonicalDemoRecipeKnowledge.specification(fromBody: body)
      )
      #expect(inherited == accepted)
      return inherited
    }
  }

  private func assertCreateDeleteParity(
    codexURL: URL,
    transformingSpecification:
      (DemoLaunchSpecification) throws -> DemoLaunchSpecification = { $0 }
  ) async throws {
    let cachesRoot = try #require(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    )
    let parityRoot = cachesRoot
      .appendingPathComponent("Spedito", isDirectory: true)
      .appendingPathComponent("PreviewWorktrees", isDirectory: true)
      .appendingPathComponent("parity-test-\(UUID().uuidString.lowercased())", isDirectory: true)
    let workspace = parityRoot.appendingPathComponent("ws", isDirectory: true)
    let scriptsDirectory = workspace.appendingPathComponent("scripts", isDirectory: true)
    try FileManager.default.createDirectory(
      at: scriptsDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: parityRoot) }
    func writeScript(named name: String, body: String) throws {
      let scriptURL = scriptsDirectory.appendingPathComponent(name)
      try Data("#!/bin/sh\nset -e\n\(body)\n".utf8).write(to: scriptURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: scriptURL.path
      )
    }
    // A first sandbox instance builds a bundle-shaped artifact.
    try writeScript(
      named: "build-demo.sh",
      body: """
        mkdir -p .demo/App.app/Contents/MacOS
        cp /bin/ls .demo/App.app/Contents/MacOS/App
        printf x > .demo/App.app/Contents/Info.plist
        """
    )
    // A later sandbox instance must be able to delete and rebuild it.
    try writeScript(
      named: "clean-demo.sh",
      body: """
        rm -rf .demo
        test ! -e .demo
        """
    )
    // The provided TMPDIR supports the mktemp build-directory pattern.
    try writeScript(
      named: "temp-build.sh",
      body: """
        build_dir="$(mktemp -d "$TMPDIR/parity-build.XXXXXX")"
        touch "$build_dir/artifact"
        rm -rf "$build_dir"
        test ! -e "$build_dir"
        """
    )
    let launcher = MacOSDemoLauncher(
      executor: CodexWorkspaceCommandExecutor(executableURL: codexURL)
    )
    let specification = try transformingSpecification(
      DemoLaunchSpecification(
        title: "Sandbox parity",
        preparationCommands: [
          DemoCommand(executable: "scripts/build-demo.sh", timeoutSeconds: 120),
          DemoCommand(executable: "scripts/clean-demo.sh", timeoutSeconds: 120),
          DemoCommand(executable: "scripts/temp-build.sh", timeoutSeconds: 120),
        ],
        launchCommand: DemoCommand(
          executable: "/usr/bin/printf",
          arguments: ["parity"],
          timeoutSeconds: 120
        ),
        presentation: DemoPresentation(kind: .commandOutput)
      )
    )

    let output = try await launcher.smokeTest(
      candidateID: UUID(),
      specification: specification,
      workspaceURL: workspace
    )

    #expect(output == "parity", "codex at \(codexURL.path)")
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent(".demo").path
      ),
      "codex at \(codexURL.path)"
    )
  }

  // MARK: - Terminal app demos (D24)

  private func terminalSpecification(
    title: String = "Dog finder",
    executable: String = "bin/tui",
    arguments: [String] = [],
    preparation: [DemoCommand] = [DemoCommand(executable: "scripts/build.sh", timeoutSeconds: 30)]
  ) -> DemoLaunchSpecification {
    DemoLaunchSpecification(
      title: title,
      preparationCommands: preparation,
      launchCommand: DemoCommand(executable: executable, arguments: arguments),
      presentation: DemoPresentation(kind: .terminalApplication)
    )
  }

  private func writeExecutable(at url: URL, body: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func resolvedRuntimeRoot(of workspace: URL) -> (workspace: URL, runtime: URL) {
    let resolved = workspace.standardizedFileURL.resolvingSymlinksInPath()
    return (
      resolved,
      resolved.appendingPathComponent(".spedito-demo-runtime", isDirectory: true)
    )
  }

  @Test("D24 a terminal app launch prepares in the sandbox, writes the script, and opens Terminal")
  func terminalLaunchWritesScriptAndOpensTerminal() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try writeExecutable(at: workspace.appendingPathComponent("bin/tui"), body: "#!/bin/sh\nexit 0\n")
    let executor = DemoCommandExecutorStub()
    let opener = DemoTerminalOpenerStub(behaviour: .writesProcessID(4242))
    let signaler = DemoProcessSignalerStub(alive: [4242])
    let launcher = MacOSDemoLauncher(
      executor: executor,
      terminalOpener: opener,
      processSignaler: signaler
    )
    let candidateID = UUID()
    let specification = terminalSpecification(arguments: ["--breed", "Great Dane"])

    let outcome = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )

    #expect(outcome == DemoLaunchOutcome(output: nil, allocatedPort: nil))
    let scriptURL = try #require(opener.openedScriptURLs.first)
    let (resolvedWorkspace, runtimeRoot) = resolvedRuntimeRoot(of: workspace)
    #expect(
      scriptURL.deletingLastPathComponent().path
        == runtimeRoot.appendingPathComponent("terminal", isDirectory: true).path
    )
    #expect(scriptURL.pathExtension == "command")
    let launchID = try #require(
      UUID(uuidString: scriptURL.deletingPathExtension().lastPathComponent)
    )
    let permissions = try FileManager.default.attributesOfItem(atPath: scriptURL.path)[
      .posixPermissions
    ] as? Int
    #expect(permissions == 0o755)
    #expect(
      try String(contentsOf: scriptURL, encoding: .utf8)
        == TerminalDemoLaunchScript.text(
          specification: specification,
          workspaceURL: resolvedWorkspace,
          runtimeDirectoryURL: runtimeRoot,
          launchID: launchID
        )
    )
    for directory in TerminalDemoLaunchScript.requiredDirectories(runtimeDirectoryURL: runtimeRoot) {
      var isDirectory: ObjCBool = false
      #expect(
        FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
          && isDirectory.boolValue,
        "\(directory.path)"
      )
    }
    // Preparation ran through the sandboxed executor; the program itself was
    // never a managed command.
    let build = try #require(
      await executor.completedRequests().first { $0.command.first == "scripts/build.sh" }
    )
    #expect(build.permissionProfile == CodexPermissionProfiles.demo)
    #expect(await executor.startedRequests().isEmpty)
    let processIDFile = TerminalDemoLaunchScript.processIDURL(
      runtimeDirectoryURL: runtimeRoot,
      launchID: launchID
    )
    #expect(FileManager.default.fileExists(atPath: processIDFile.path))

    // The runtime holds the pid: Open demo brings Terminal forward instead
    // of starting a second copy.
    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    #expect(opener.openedScriptURLs.count == 1)
    #expect(opener.activationCount == 1)

    await launcher.stop(candidateID: candidateID)
    #expect(signaler.terminated == [4242])
    #expect(signaler.killed.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: processIDFile.path))
  }

  /// Runs the generated script for real through `/bin/zsh` against a program
  /// that records what it received, so the script contract — working
  /// directory, arguments, exported variables, and the pid record — is proven
  /// by execution rather than by string comparison alone.
  private func launchRealTerminalProgram(
    workspace: URL,
    launcher: MacOSDemoLauncher,
    opener: DemoTerminalOpenerStub,
    candidateID: UUID
  ) async throws -> (record: [String: String], process: Process) {
    let recordURL = workspace.appendingPathComponent("record.txt")
    try writeExecutable(
      at: workspace.appendingPathComponent("bin/tui"),
      body: """
        #!/bin/sh
        {
          printf 'cwd=%s\\n' "$PWD"
          for argument in "$@"; do printf 'arg=%s\\n' "$argument"; done
          printf 'TMPDIR=%s\\n' "$TMPDIR"
          printf 'XDG_CACHE_HOME=%s\\n' "$XDG_CACHE_HOME"
          printf 'SPEDITO_DEMO_DATA_DIRECTORY=%s\\n' "$SPEDITO_DEMO_DATA_DIRECTORY"
          printf 'pid=%s\\n' "$$"
        } > '\(recordURL.path)'
        exec /bin/sleep 60
        """
    )
    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: terminalSpecification(arguments: ["--breed", "Great Dane", "it's"]),
      workspaceURL: workspace
    )
    let process = try #require(opener.launchedProcesses.first)
    // The script records the pid before it execs the program, so the launch
    // can return before the program's own record is complete.
    var recordText = ""
    for _ in 0..<100 {
      if let text = try? String(contentsOf: recordURL, encoding: .utf8),
        text.contains("pid=")
      {
        recordText = text
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    var record: [String: String] = [:]
    var arguments: [String] = []
    for line in recordText.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      if parts[0] == "arg" {
        arguments.append(parts[1])
      } else {
        record[parts[0]] = parts[1]
      }
    }
    record["arguments"] = arguments.joined(separator: "\u{1F}")
    return (record, process)
  }

  @Test("D24 the launcher script runs the program from the workspace with the isolated variables")
  func terminalScriptRunsTheProgramFromTheWorkspace() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let opener = DemoTerminalOpenerStub(behaviour: .runsScript)
    let launcher = MacOSDemoLauncher(executor: DemoCommandExecutorStub(), terminalOpener: opener)
    let candidateID = UUID()
    defer { Task { await launcher.stop(candidateID: candidateID) } }

    let (record, process) = try await launchRealTerminalProgram(
      workspace: workspace,
      launcher: launcher,
      opener: opener,
      candidateID: candidateID
    )

    let (resolvedWorkspace, runtimeRoot) = resolvedRuntimeRoot(of: workspace)
    #expect(record["cwd"] == resolvedWorkspace.path)
    #expect(record["arguments"] == ["--breed", "Great Dane", "it's"].joined(separator: "\u{1F}"))
    #expect(record["TMPDIR"] == runtimeRoot.appendingPathComponent("tmp").path)
    #expect(record["XDG_CACHE_HOME"] == runtimeRoot.appendingPathComponent("cache/xdg").path)
    #expect(
      record["SPEDITO_DEMO_DATA_DIRECTORY"] == runtimeRoot.appendingPathComponent("data").path
    )
    // exec keeps the shell's pid, so the recorded pid is the program's and
    // equals the pid file the launcher read.
    #expect(record["pid"] == String(process.processIdentifier))
    let scriptURL = try #require(opener.openedScriptURLs.first)
    let processIDFile = scriptURL.deletingPathExtension().appendingPathExtension("pid")
    #expect(
      try String(contentsOf: processIDFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) == String(process.processIdentifier)
    )
    #expect(process.isRunning)

    await launcher.stop(candidateID: candidateID)
    process.waitUntilExit()
    #expect(!process.isRunning)
  }

  @Test("D24 Stop demo ends the program within its bound and removes the pid file; a second stop is a no-op")
  func terminalStopTerminatesTheProgram() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let opener = DemoTerminalOpenerStub(behaviour: .runsScript)
    let launcher = MacOSDemoLauncher(executor: DemoCommandExecutorStub(), terminalOpener: opener)
    let candidateID = UUID()
    let (_, process) = try await launchRealTerminalProgram(
      workspace: workspace,
      launcher: launcher,
      opener: opener,
      candidateID: candidateID
    )
    let scriptURL = try #require(opener.openedScriptURLs.first)
    let processIDFile = scriptURL.deletingPathExtension().appendingPathExtension("pid")
    #expect(process.isRunning)

    let started = ContinuousClock.now
    await launcher.stop(candidateID: candidateID)
    process.waitUntilExit()

    #expect(!process.isRunning)
    #expect(process.terminationReason == .uncaughtSignal)
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(!FileManager.default.fileExists(atPath: processIDFile.path))
    #expect(Darwin.kill(process.processIdentifier, 0) != 0)

    await launcher.stop(candidateID: candidateID)
    #expect(!FileManager.default.fileExists(atPath: processIDFile.path))
  }

  @Test("D24 Open demo activates Terminal while the program lives and relaunches once it has died")
  func terminalReopenActivatesWhileAliveAndRelaunchesWhenDead() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try writeExecutable(at: workspace.appendingPathComponent("bin/tui"), body: "#!/bin/sh\nexit 0\n")
    let opener = DemoTerminalOpenerStub(behaviour: .writesProcessID(100))
    let signaler = DemoProcessSignalerStub(alive: [100, 101])
    let launcher = MacOSDemoLauncher(
      executor: DemoCommandExecutorStub(),
      terminalOpener: opener,
      processSignaler: signaler
    )
    let candidateID = UUID()
    let specification = terminalSpecification()

    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    #expect(opener.openedScriptURLs.count == 1)
    #expect(opener.activationCount == 1)
    let firstPIDFile = try #require(opener.openedScriptURLs.first)
      .deletingPathExtension().appendingPathExtension("pid")
    #expect(FileManager.default.fileExists(atPath: firstPIDFile.path))

    // The owner closed the window: the program is gone, so Open demo
    // relaunches from the reviewed checkout instead of activating nothing.
    signaler.markDead(100)
    opener.behaviour = .writesProcessID(101)
    _ = try await launcher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    #expect(opener.openedScriptURLs.count == 2)
    #expect(opener.activationCount == 1)
    #expect(!FileManager.default.fileExists(atPath: firstPIDFile.path))
    #expect(signaler.terminated.isEmpty, "a dead pid is never signalled")

    await launcher.stop(candidateID: candidateID)
    #expect(signaler.terminated == [101])
  }

  @Test("D24 the smoke test builds through the sandbox but never runs the interactive program")
  func terminalSmokeTestNeverRunsTheProgram() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let marker = workspace.appendingPathComponent("invoked.txt")
    try writeExecutable(
      at: workspace.appendingPathComponent("bin/tui"),
      body: "#!/bin/sh\nprintf invoked > '\(marker.path)'\nexit 0\n"
    )
    let executor = DemoCommandExecutorStub()
    let opener = DemoTerminalOpenerStub(behaviour: .runsScript)
    let launcher = MacOSDemoLauncher(executor: executor, terminalOpener: opener)

    let output = try await launcher.smokeTest(
      candidateID: UUID(),
      specification: terminalSpecification(),
      workspaceURL: workspace
    )

    #expect(output == nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(opener.openedScriptURLs.isEmpty)
    #expect(await executor.completedRequests().contains { $0.command.first == "scripts/build.sh" })
    #expect(await executor.startedRequests().isEmpty)
  }

  @Test("D24 a missing or non-executable program after preparation is a candidate failure")
  func terminalMissingExecutableIsACandidateFailure() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let opener = DemoTerminalOpenerStub(behaviour: .runsScript)
    let launcher = MacOSDemoLauncher(executor: DemoCommandExecutorStub(), terminalOpener: opener)
    let specification = terminalSpecification()

    func expectCandidateFailure(_ operation: () async throws -> Void) async {
      do {
        try await operation()
        Issue.record("Expected the terminal program check to fail")
      } catch let error as DemoLauncherError {
        guard case .missingPresentation(let path) = error else {
          Issue.record("Expected a missing program, received \(error)")
          return
        }
        #expect(path == "bin/tui")
        #expect(DemoPreparationFailurePolicy.disposition(for: error) == .correctCandidate)
      } catch {
        Issue.record("Unexpected error \(error)")
      }
    }

    // Nothing built.
    await expectCandidateFailure {
      _ = try await launcher.smokeTest(
        candidateID: UUID(),
        specification: specification,
        workspaceURL: workspace
      )
    }
    // Built without the execute bit.
    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent("bin"),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: workspace.appendingPathComponent("bin/tui"))
    await expectCandidateFailure {
      _ = try await launcher.launch(
        candidateID: UUID(),
        specification: specification,
        workspaceURL: workspace
      )
    }
    // A directory where the program should be.
    try FileManager.default.removeItem(at: workspace.appendingPathComponent("bin/tui"))
    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent("bin/tui"),
      withIntermediateDirectories: true
    )
    await expectCandidateFailure {
      _ = try await launcher.smokeTest(
        candidateID: UUID(),
        specification: specification,
        workspaceURL: workspace
      )
    }
    #expect(opener.openedScriptURLs.isEmpty)
  }

  @Test("D24 Terminal failing to open or to record the program's pid is a host failure")
  func terminalOpenFailureIsAHostFailure() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try writeExecutable(at: workspace.appendingPathComponent("bin/tui"), body: "#!/bin/sh\nexit 0\n")
    let opener = DemoTerminalOpenerStub(behaviour: .throwsOnOpen)
    let launcher = MacOSDemoLauncher(
      executor: DemoCommandExecutorStub(),
      terminalOpener: opener,
      processSignaler: DemoProcessSignalerStub(alive: []),
      terminalTiming: TerminalDemoLaunchTiming(
        processIDTimeout: .milliseconds(300),
        pollInterval: .milliseconds(20),
        stopTimeout: .milliseconds(200)
      )
    )
    let candidateID = UUID()
    let specification = terminalSpecification(title: "Dog finder")

    func expectHostFailure(_ operation: () async throws -> Void) async {
      do {
        try await operation()
        Issue.record("Expected the Terminal launch to fail")
      } catch let error as DemoLauncherError {
        guard case .couldNotOpen(let title) = error else {
          Issue.record("Expected a host open failure, received \(error)")
          return
        }
        #expect(title == "Dog finder")
        #expect(DemoPreparationFailurePolicy.disposition(for: error) == .retryPreparation)
      } catch {
        Issue.record("Unexpected error \(error)")
      }
    }

    await expectHostFailure {
      _ = try await launcher.launch(
        candidateID: candidateID,
        specification: specification,
        workspaceURL: workspace
      )
    }
    #expect(opener.openedScriptURLs.count == 1)

    // Terminal opened the script but the program never recorded its pid.
    opener.behaviour = .neverWritesProcessID
    await expectHostFailure {
      _ = try await launcher.launch(
        candidateID: candidateID,
        specification: specification,
        workspaceURL: workspace
      )
    }
    #expect(opener.openedScriptURLs.count == 2)
    // No runtime was retained, so the next Demo tries again from scratch.
    opener.behaviour = .writesProcessID(7)
    let signalerAfterRetry = DemoProcessSignalerStub(alive: [7])
    let retryLauncher = MacOSDemoLauncher(
      executor: DemoCommandExecutorStub(),
      terminalOpener: opener,
      processSignaler: signalerAfterRetry
    )
    _ = try await retryLauncher.launch(
      candidateID: candidateID,
      specification: specification,
      workspaceURL: workspace
    )
    #expect(opener.openedScriptURLs.count == 3)
    await retryLauncher.stop(candidateID: candidateID)
  }

  @Test("D24 a program that resolves outside the reviewed checkout is rejected before Terminal opens")
  func terminalLaunchRejectsExecutableOutsideWorkspace() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let binDirectory = workspace.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: binDirectory.appendingPathComponent("tui"),
      withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
    )
    let opener = DemoTerminalOpenerStub(behaviour: .runsScript)
    let launcher = MacOSDemoLauncher(executor: DemoCommandExecutorStub(), terminalOpener: opener)

    do {
      _ = try await launcher.launch(
        candidateID: UUID(),
        specification: terminalSpecification(),
        workspaceURL: workspace
      )
      Issue.record("Expected the escaping program to be rejected")
    } catch let error as DemoLaunchValidationError {
      #expect(error.localizedDescription.contains("outside the reviewed preview"))
      #expect(DemoPreparationFailurePolicy.disposition(for: error) == .correctCandidate)
    }

    // A symlink that stays inside the checkout is still not the program.
    try FileManager.default.removeItem(at: binDirectory.appendingPathComponent("tui"))
    try writeExecutable(
      at: workspace.appendingPathComponent("real/tui"),
      body: "#!/bin/sh\nexit 0\n"
    )
    try FileManager.default.createSymbolicLink(
      at: binDirectory.appendingPathComponent("tui"),
      withDestinationURL: workspace.appendingPathComponent("real/tui")
    )
    do {
      _ = try await launcher.smokeTest(
        candidateID: UUID(),
        specification: terminalSpecification(),
        workspaceURL: workspace
      )
      Issue.record("Expected the symlinked program to be rejected")
    } catch let error as DemoLauncherError {
      guard case .missingPresentation = error else {
        Issue.record("Expected a missing program, received \(error)")
        return
      }
      #expect(DemoPreparationFailurePolicy.disposition(for: error) == .correctCandidate)
    }
    #expect(opener.openedScriptURLs.isEmpty)
  }

  /// Real-sandbox proof for the terminal kind: preparation compiles a Swift
  /// terminal program with `swiftc` inside the `spedito-demo` profile and the
  /// smoke test resolves the built executable without running it. Fails, never
  /// skips, when no Codex runtime is found.
  @Test("D24 a terminal recipe builds with swiftc in the real sandbox and resolves its program")
  func realSandboxTerminalRecipeBuildsAndResolves() async throws {
    let codexURL = try CodexSandboxRuntimeLocator.resolve()
    let cachesRoot = try #require(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    )
    let parityRoot = cachesRoot
      .appendingPathComponent("Spedito", isDirectory: true)
      .appendingPathComponent("PreviewWorktrees", isDirectory: true)
      .appendingPathComponent(
        "terminal-parity-test-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
    let workspace = parityRoot.appendingPathComponent("ws", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parityRoot) }
    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data(
      """
      print("Ledgerline menu")
      while let line = readLine() {
        if line == "q" { break }
        print("Unknown entry")
      }
      """.utf8
    ).write(to: workspace.appendingPathComponent("Sources/main.swift"))
    try writeExecutable(
      at: workspace.appendingPathComponent("scripts/build.sh"),
      body: """
        #!/bin/sh
        set -e
        mkdir -p bin
        swiftc -o bin/menu Sources/main.swift
        """
    )
    let opener = DemoTerminalOpenerStub(behaviour: .throwsOnOpen)
    let launcher = MacOSDemoLauncher(
      executor: CodexWorkspaceCommandExecutor(executableURL: codexURL),
      terminalOpener: opener
    )

    let output = try await launcher.smokeTest(
      candidateID: UUID(),
      specification: terminalSpecification(
        executable: "bin/menu",
        preparation: [DemoCommand(executable: "scripts/build.sh", timeoutSeconds: 300)]
      ),
      workspaceURL: workspace
    )

    #expect(output == nil, "codex at \(codexURL.path)")
    #expect(
      FileManager.default.isExecutableFile(
        atPath: workspace.appendingPathComponent("bin/menu").path
      ),
      "codex at \(codexURL.path)"
    )
    #expect(opener.openedScriptURLs.isEmpty)
  }

  private func makeWorkspace() throws -> URL {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-demo-launch-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    return workspace
  }

  private func makeApplication(at workspace: URL) throws -> URL {
    let applicationURL = workspace.appendingPathComponent("Demo.app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let executableDirectoryURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    let executableURL = executableDirectoryURL.appendingPathComponent("Demo")
    try FileManager.default.createDirectory(
      at: executableDirectoryURL,
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )
    let info: [String: Any] = [
      "CFBundleExecutable": "Demo",
      "CFBundleIdentifier": "local.spedito.demo-test",
      "CFBundlePackageType": "APPL",
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return applicationURL
  }
}

@MainActor
private final class DemoRunningApplicationStub: DemoRunningApplication {
  var isTerminated = false
  private(set) var activationCount = 0
  private(set) var terminationCount = 0

  func activateForDemo() {
    activationCount += 1
  }

  func terminateForDemo() {
    isTerminated = true
    terminationCount += 1
  }
}

@MainActor
private final class DemoApplicationOpenerStub: DemoApplicationOpening {
  private var applications: [any DemoRunningApplication]
  private(set) var openedApplicationURLs: [URL] = []

  init(application: any DemoRunningApplication) {
    applications = [application]
  }

  init(applications: [any DemoRunningApplication]) {
    self.applications = applications
  }

  func openApplication(at applicationURL: URL) async throws -> any DemoRunningApplication {
    openedApplicationURLs.append(applicationURL)
    guard !applications.isEmpty else {
      throw CocoaError(.executableNotLoadable)
    }
    return applications.removeFirst()
  }
}

@MainActor
private final class DemoURLOpenerStub: DemoURLOpening {
  private(set) var openedURLs: [URL] = []

  func open(_ url: URL) -> Bool {
    openedURLs.append(url)
    return true
  }
}

/// Stands in for Terminal.app. `writesProcessID` mimics the script's own pid
/// record without running anything; `runsScript` executes the generated
/// script through `/bin/zsh` exactly as Terminal would, as a child of the
/// test process.
@MainActor
private final class DemoTerminalOpenerStub: DemoTerminalOpening {
  enum Behaviour {
    case writesProcessID(pid_t)
    case runsScript
    case throwsOnOpen
    case neverWritesProcessID
  }

  var behaviour: Behaviour
  private(set) var openedScriptURLs: [URL] = []
  private(set) var activationCount = 0
  private(set) var launchedProcesses: [Process] = []

  init(behaviour: Behaviour) {
    self.behaviour = behaviour
  }

  func openScript(at scriptURL: URL) async throws {
    openedScriptURLs.append(scriptURL)
    switch behaviour {
    case .throwsOnOpen:
      throw CocoaError(.fileNoSuchFile)
    case .neverWritesProcessID:
      return
    case .writesProcessID(let processID):
      let processIDFile = scriptURL.deletingPathExtension().appendingPathExtension("pid")
      try Data("\(processID)".utf8).write(to: processIDFile)
    case .runsScript:
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = [scriptURL.path]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      launchedProcesses.append(process)
    }
  }

  func activateTerminal() {
    activationCount += 1
  }
}

private final class DemoProcessSignalerStub: DemoProcessSignaling, @unchecked Sendable {
  private let lock = NSLock()
  private var alive: Set<pid_t>
  private var terminatedStorage: [pid_t] = []
  private var killedStorage: [pid_t] = []

  init(alive: Set<pid_t>) {
    self.alive = alive
  }

  var terminated: [pid_t] { lock.withLock { terminatedStorage } }
  var killed: [pid_t] { lock.withLock { killedStorage } }

  func markDead(_ processID: pid_t) {
    lock.withLock { _ = alive.remove(processID) }
  }

  func isAlive(_ processID: pid_t) -> Bool {
    lock.withLock { alive.contains(processID) }
  }

  func terminate(_ processID: pid_t) {
    lock.withLock {
      terminatedStorage.append(processID)
      alive.remove(processID)
    }
  }

  func kill(_ processID: pid_t) {
    lock.withLock {
      killedStorage.append(processID)
      alive.remove(processID)
    }
  }
}

private final class ReadyLoopbackURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static nonisolated(unsafe) var probedPortsStorage: [Int] = []

  static var probedPorts: [Int] {
    lock.withLock { probedPortsStorage }
  }

  static func resetProbedPorts() {
    lock.withLock { probedPortsStorage = [] }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    guard request.url?.host == "127.0.0.1", request.url?.path == "/" else { return false }
    if let port = request.url?.port {
      lock.withLock { probedPortsStorage.append(port) }
    }
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("ready".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private actor DemoCommandExecutorStub: CodexManagedCommandExecuting {
  private struct RunningProcess {
    let process: Process
    let outputURL: URL
    let outputHandle: FileHandle
  }

  private var completed: [CodexManagedCommandRequest] = []
  private var started: [CodexManagedCommandRequest] = []
  private var processes: [String: RunningProcess] = [:]
  private let failsManagedWorkspaceCheck: Bool
  private let deniesManagedWorkspaceDeletion: Bool
  private let failingPreparationOutput: String?

  init(
    failsManagedWorkspaceCheck: Bool = false,
    deniesManagedWorkspaceDeletion: Bool = false,
    failingPreparationOutput: String? = nil
  ) {
    self.failsManagedWorkspaceCheck = failsManagedWorkspaceCheck
    self.deniesManagedWorkspaceDeletion = deniesManagedWorkspaceDeletion
    self.failingPreparationOutput = failingPreparationOutput
  }

  static func isAccessCheck(_ request: CodexManagedCommandRequest) -> Bool {
    request.command.first == "/bin/sh"
      && request.command.contains { $0.contains("access-check") }
  }

  func runManagedCommand(
    _ request: CodexManagedCommandRequest
  ) async throws -> CodexManagedCommandResult {
    completed.append(request)
    if Self.isAccessCheck(request), failsManagedWorkspaceCheck {
      return CodexManagedCommandResult(
        exitCode: 1,
        standardOutput: "",
        standardError: "mkdir: Operation not permitted"
      )
    }
    if Self.isAccessCheck(request), deniesManagedWorkspaceDeletion {
      let accessCheckRoot = request.workspaceRoot
        .appendingPathComponent(".spedito-demo-runtime/access-check")
        .path
      return CodexManagedCommandResult(
        exitCode: 1,
        standardOutput: "",
        standardError: "rm: \(accessCheckRoot): Operation not permitted"
      )
    }
    if request.command.first == "failing-preparation", let failingPreparationOutput {
      return CodexManagedCommandResult(
        exitCode: 1,
        standardOutput: "",
        standardError: failingPreparationOutput
      )
    }
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
    started.append(request)
    let processID = UUID().uuidString
    let process = Process()
    let executable =
      if request.command.first == "test-browser-service" {
        "/bin/sleep"
      } else {
        request.command.first ?? ""
      }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments =
      request.command.first == "test-browser-service"
      ? ["60"]
      : Array(request.command.dropFirst())
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

  func startedRequests() -> [CodexManagedCommandRequest] {
    started
  }

  func runningProcessCount() -> Int {
    processes.values.filter(\.process.isRunning).count
  }
}
