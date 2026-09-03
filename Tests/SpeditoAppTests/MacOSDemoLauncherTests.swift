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
