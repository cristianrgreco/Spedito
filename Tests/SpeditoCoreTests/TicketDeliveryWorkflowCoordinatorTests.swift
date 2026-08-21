import Foundation
import SpeditoTestSupport
import Testing

@testable import SpeditoCore

@Suite("Ticket delivery workflow coordinator", .serialized)
@MainActor
struct TicketDeliveryWorkflowCoordinatorTests {
  @Test("[D11] Approved review remains bound to one durable candidate")
  func approvedReviewRemainsCandidateBound() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-review-coordinator-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let gitWorkspaceManager = GitWorkspaceManager()
    let productRepository = root.appendingPathComponent("product", isDirectory: true)
    let reviewedSHA = try await gitWorkspaceManager.ensureRepository(at: productRepository)

    let databaseURL = root.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Review authority")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let techLead = try #require(profiles.first { $0.role == .lead })
    var workItem = try await store.createWorkItem(
      productID: product.id,
      title: "Deliver an immutable candidate",
      type: .story,
      body: "Keep review bound to the exact implementation revision.",
      acceptanceCriteria: ["The reviewer attests one candidate revision."],
      priority: .normal
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .refining,
      actor: "Product owner",
      reason: "Refinement started"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready for delivery"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Review one immutable candidate",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: workItem.id, implementerProfileID: implementer.id, reviewerProfileID: techLead.id, estimatedTokens: 1)
      ]
    )
    let plan = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(plan.items.first)
    var implementationRun = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    implementationRun = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .running,
      codexThreadID: "thread-implementation",
      worktreePath: root.appendingPathComponent("ticket").path,
      eventActor: implementer.name,
      eventDetail: "Implementation started"
    )
    _ = try await store.transitionWorkItem(
      id: workItem.id,
      to: .running,
      actor: implementer.name,
      reason: "Implementation started"
    )
    _ = try await store.transitionWorkItem(
      id: workItem.id,
      to: .integrating,
      actor: implementer.name,
      reason: "Candidate prepared"
    )

    let implementation = TicketExecutionResult(
      status: .completed,
      comment: "Delivered the candidate.",
      question: nil,
      options: [],
      summary: "The agreed outcome is complete.",
      changedFiles: ["Sources/Outcome.swift"],
      tests: ["Focused checks passed"],
      knowledgeNotes: [],
      reviewInstructions: ["Inspect the exact candidate revision."],
      demo: DemoLaunchSpecification(
        title: "Reviewed evidence",
        presentation: DemoPresentation(kind: .artifact, path: "evidence/result.txt")
      ),
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    let executionResultJSON = String(
      decoding: try JSONEncoder().encode(implementation),
      as: UTF8.self
    )
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: workItem.id,
        implementationRunID: implementationRun.id,
        version: 1,
        branchName: "ticket/T1",
        baseSHA: reviewedSHA,
        headSHA: reviewedSHA,
        worktreePath: implementationRun.worktreePath ?? root.path,
        status: .queuedForReview,
        commitCount: 1,
        executionResultJSON: executionResultJSON
      )
    )
    let reviewWorkspace = root.appendingPathComponent("review", isDirectory: true)
    try FileManager.default.createDirectory(
      at: reviewWorkspace,
      withIntermediateDirectories: true
    )
    let integration = GitIntegrationSnapshot(
      url: reviewWorkspace,
      integratedSHA: reviewedSHA
    )

    let transport = ScriptedCodexTransport(
      responses: [
        .init(
          method: "initialize",
          result: .object([
            "userAgent": .string("codex-cli/review-journey"),
            "codexHome": .string("/private/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
          ])
        ),
        .init(
          method: "thread/start",
          result: .object(["thread": .object(["id": .string("thread-review")])])
        ),
        .init(
          method: "turn/start",
          result: .object(["turn": .object(["id": .string("turn-review")])])
        ),
      ],
      inboundMessages: [
        .notification(
          CodexNotification(
            method: "turn/completed",
            params: .object([
              "threadId": .string("thread-review"),
              "turn": .object([
                "id": .string("turn-review"),
                "status": .string("completed"),
                "items": .array([
                  .object([
                    "id": .string("message-review"),
                    "type": .string("agentMessage"),
                    "text": .string(
                      #"{"decision":"approved","comment":"Approved the exact candidate.","findings":[],"retrospectiveWentWell":[],"retrospectiveCouldImprove":[],"retrospectiveActions":[]}"#
                    ),
                  ])
                ]),
              ]),
            ])
          )
        )
      ]
    )
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let delegate = CandidateReviewDelegate(
      store: store,
      client: client,
      productID: product.id,
      databaseURL: databaseURL,
      rootURL: root,
      runs: [implementationRun]
    )
    let coordinator = TicketDeliveryWorkflowCoordinator(
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      runtimeCoordinator: TicketDeliveryRuntimeCoordinator(
        prepareScheduler: { _ in },
        drainScheduler: { _ in .finished }
      ),
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )

    await coordinator.reviewCompletedImplementation(
      implementation,
      candidate: candidate,
      implementationRun: implementationRun,
      reviewCycle: 0,
      plan: plan,
      preparedIntegration: integration
    )

    let persistedCandidate = try await store.fetchCandidateRevision(id: candidate.id)
    let persistedItem = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == workItem.id }
    )
    let persistedRuns = try await store.fetchAgentRuns(productID: product.id)
    let reviewRun = try #require(persistedRuns.first { $0.profileID == techLead.id })
    let comments = try await store.fetchComments(workItemID: workItem.id)

    #expect(delegate.errorMessage == nil)

    #expect(persistedCandidate.status == .readyForDemo)
    #expect(persistedCandidate.headSHA == reviewedSHA)
    #expect(persistedCandidate.integratedSHA == reviewedSHA)
    #expect(persistedCandidate.integrationWorktreePath == reviewWorkspace.path)
    #expect(persistedCandidate.reviewedHeadSHA == reviewedSHA)
    #expect(persistedCandidate.reviewRunID == reviewRun.id)
    #expect(persistedItem.state == .acceptance)
    #expect(reviewRun.status == .completed)
    #expect(reviewRun.worktreePath == reviewWorkspace.path)
    #expect(comments.contains { $0.authorName == techLead.name && $0.body == "Approved the exact candidate." })
    #expect(delegate.presentedRuns.contains { $0.id == reviewRun.id && $0.status == .completed })
    #expect(await transport.remainingResponseCount() == 0)

    await client.disconnect()
    await store.close()
  }

  @Test("[D10] Sequential demo contract errors repair to the existing static prototype")
  func d10SequentialDemoContractErrorsRepairToStaticPrototype() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-demo-contract-repair-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let gitWorkspaceManager = GitWorkspaceManager()
    let repository = root.appendingPathComponent("product", isDirectory: true)
    _ = try await gitWorkspaceManager.ensureRepository(at: repository)
    let databaseURL = root.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Demo contract repair")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let designer = try #require(profiles.first { $0.role == .uxDesigner })
    let workItem = try await store.createWorkItem(
      productID: product.id,
      title: "Design an interactive forecast",
      type: .task,
      body: "Create a self-contained browser prototype.",
      acceptanceCriteria: ["The managed Demo opens the interactive prototype."],
      priority: .high
    )
    let runID = UUID()
    let workspace = try await gitWorkspaceManager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: root.appendingPathComponent("tickets", isDirectory: true),
      ticketKey: workItem.key,
      runID: runID,
      authorName: designer.name
    )
    let prototype = workspace.url.appendingPathComponent("prototype", isDirectory: true)
    try FileManager.default.createDirectory(
      at: prototype,
      withIntermediateDirectories: true
    )
    try Data("<!doctype html><title>Forecast prototype</title>".utf8).write(
      to: prototype.appendingPathComponent("index.html")
    )
    let run = try await store.createAgentRun(
      AgentRun(
        id: runID,
        productID: product.id,
        workItemID: workItem.id,
        profileID: designer.id,
        status: .running,
        codexThreadID: "thread-demo-repair",
        worktreePath: workspace.url.path
      )
    )

    func executionResponse(demo: DemoLaunchSpecification) throws -> String {
      let result = TicketExecutionResult(
        status: .completed,
        comment: "Created the interactive forecast prototype.",
        question: nil,
        options: [],
        summary: "The reviewed city-search journey is available.",
        changedFiles: ["prototype/index.html"],
        tests: ["Prototype source check passed"],
        knowledgeNotes: [],
        reviewInstructions: ["Open the managed Demo."],
        demo: demo,
        retrospectiveWentWell: [],
        retrospectiveCouldImprove: [],
        retrospectiveActions: []
      )
      return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    let initialResponse = try executionResponse(
      demo: DemoLaunchSpecification(
        title: "Forecast prototype",
        presentation: DemoPresentation(kind: .artifact, path: ".")
      )
    )
    let firstRepair = try executionResponse(
      demo: DemoLaunchSpecification(
        title: "Forecast prototype",
        launchCommand: DemoCommand(
          executable: "/bin/sh",
          arguments: ["scripts/run.sh"]
        ),
        readiness: DemoReadinessCheck(kind: .http, path: "/"),
        presentation: DemoPresentation(kind: .browser, path: "/")
      )
    )
    let secondRepair = try executionResponse(
      demo: DemoLaunchSpecification(
        title: "Forecast prototype",
        presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
      )
    )

    func completedTurn(id: String, response: String) -> CodexInboundMessage {
      .notification(
        CodexNotification(
          method: "turn/completed",
          params: .object([
            "threadId": .string("thread-demo-repair"),
            "turn": .object([
              "id": .string(id),
              "status": .string("completed"),
              "items": .array([
                .object([
                  "id": .string("message-\(id)"),
                  "type": .string("agentMessage"),
                  "text": .string(response),
                ])
              ]),
            ]),
          ])
        )
      )
    }

    let transport = ScriptedCodexTransport(
      responses: [
        .init(
          method: "initialize",
          result: .object([
            "userAgent": .string("codex-cli/demo-repair"),
            "codexHome": .string("/private/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
          ])
        ),
        .init(
          method: "turn/start",
          result: .object(["turn": .object(["id": .string("repair-one")])])
        ),
        .init(
          method: "turn/start",
          result: .object(["turn": .object(["id": .string("repair-two")])])
        ),
      ],
      inboundMessages: [
        completedTurn(id: "repair-one", response: firstRepair),
        completedTurn(id: "repair-two", response: secondRepair),
      ]
    )
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let delegate = CandidateReviewDelegate(
      store: store,
      client: client,
      productID: product.id,
      databaseURL: databaseURL,
      rootURL: root,
      runs: [run]
    )
    let coordinator = TicketDeliveryWorkflowCoordinator(
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      runtimeCoordinator: TicketDeliveryRuntimeCoordinator(
        prepareScheduler: { _ in },
        drainScheduler: { _ in .finished }
      ),
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )

    let validated = try await coordinator.validatedExecutionResult(
      initialResponse,
      client: client,
      threadID: "thread-demo-repair",
      runID: run.id,
      productID: product.id,
      assignee: designer,
      workspaceURL: workspace.url,
      canonicalKnowledgePages: []
    )

    #expect(validated.deliveryKind == .repositoryChange)
    #expect(validated.result.demo?.presentation.kind == .staticWeb)
    #expect(validated.result.demo?.presentation.path == "prototype")
    #expect(
      await transport.recordedRequests().filter { $0.method == "turn/start" }.count == 2
    )
    #expect(await transport.remainingResponseCount() == 0)

    await client.disconnect()
    await store.close()
  }

  @Test("Clean reintegration retains approval for the unchanged candidate")
  func cleanReintegrationRetainsCandidateApproval() async throws {
    let harness = try await makeAcceptanceHarness(
      deliveryKind: .repositoryChange,
      demo: DemoLaunchSpecification(
        title: "Reviewed product change",
        presentation: DemoPresentation(kind: .artifact, path: "feature.txt")
      )
    )
    defer { try? FileManager.default.removeItem(at: harness.root) }

    _ = try await harness.store.updateCandidateRevision(
      id: harness.candidate.id,
      status: .readyForDemo,
      reviewedHeadSHA: harness.candidate.headSHA
    )
    let runCountBeforeReintegration = try await harness.store.fetchAgentRuns(
      productID: harness.product.id
    ).count
    let repository = harness.root.appendingPathComponent("product", isDirectory: true)
    try Data("accepted parallel change\n".utf8).write(
      to: repository.appendingPathComponent("parallel.txt")
    )
    _ = try await harness.gitWorkspaceManager.checkpointTrunk(
      at: repository,
      message: "Advance accepted trunk without touching the reviewed candidate"
    )

    #expect(
      !(await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      ))
    )
    let queued = try await harness.store.fetchCandidateRevision(id: harness.candidate.id)
    #expect(queued.status == .queuedForIntegration)
    #expect(queued.reviewedHeadSHA == harness.candidate.headSHA)

    let context = try #require(await harness.coordinator.context(productID: harness.product.id))
    #expect(await harness.coordinator.processIntegrationCandidates(context: context))
    await harness.delegate.waitForReadyCandidate(id: harness.candidate.id)

    let reintegrated = try await harness.store.fetchCandidateRevision(id: harness.candidate.id)
    let item = try await harness.store.fetchWorkItem(id: harness.workItem.id)
    #expect(reintegrated.status == .readyForDemo)
    #expect(reintegrated.reviewedHeadSHA == harness.candidate.headSHA)
    #expect(reintegrated.integratedSHA != harness.candidate.integratedSHA)
    #expect(item.state == .acceptance)
    #expect(
      try await harness.store.fetchAgentRuns(productID: harness.product.id).count
        == runCountBeforeReintegration
    )
    #expect(harness.delegate.errorMessage == nil)

    await harness.store.close()
  }

  @Test("Conflict resolution that changes the result requires focused re-review")
  func changedConflictResolutionRequiresFocusedRereview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-conflict-rereview-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("product", isDirectory: true)
    let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
    let integrations = root.appendingPathComponent("integrations", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try Data("baseline\n".utf8).write(
      to: repository.appendingPathComponent("shared.txt")
    )

    let gitWorkspaceManager = GitWorkspaceManager()
    _ = try await gitWorkspaceManager.ensureRepository(at: repository)
    let databaseURL = root.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Conflict re-review")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let techLead = try #require(profiles.first { $0.role == .lead })
    var workItem = try await store.createWorkItem(
      productID: product.id,
      title: "Resolve overlapping delivery changes",
      type: .story,
      body: "Keep the resolved result behind focused review.",
      acceptanceCriteria: ["The changed integrated result receives fresh tech lead approval."],
      priority: .normal
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .refining,
      actor: "Product owner",
      reason: "Refinement started"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready for delivery"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Resolve and review one conflict",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: workItem.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: techLead.id,
          estimatedTokens: 1
        )
      ]
    )
    let plan = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(plan.items.first)
    var implementationRun = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    let workspace = try await gitWorkspaceManager.prepareTicketWorkspace(
      repositoryURL: repository,
      worktreesRootURL: ticketWorktrees,
      ticketKey: workItem.key,
      runID: implementationRun.id,
      authorName: implementer.name
    )
    implementationRun = try await store.updateAgentRun(
      id: implementationRun.id,
      status: .running,
      worktreePath: workspace.url.path,
      eventActor: implementer.name,
      eventDetail: "Implementation started"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .running,
      actor: implementer.name,
      reason: "Implementation started"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .integrating,
      actor: implementer.name,
      reason: "Candidate prepared"
    )
    try Data("ticket behavior\n".utf8).write(
      to: workspace.url.appendingPathComponent("shared.txt")
    )
    let snapshot = try await gitWorkspaceManager.createCandidate(
      ticketWorkspaceURL: workspace.url,
      ticketKey: workItem.key,
      version: 1,
      authorName: implementer.name,
      summary: "Deliver ticket behavior"
    )
    try Data("accepted trunk behavior\n".utf8).write(
      to: repository.appendingPathComponent("shared.txt")
    )
    _ = try await gitWorkspaceManager.checkpointTrunk(
      at: repository,
      message: "Advance accepted trunk"
    )

    let candidateID = UUID()
    let conflictWorkspace: URL
    do {
      _ = try await gitWorkspaceManager.integrateCandidate(
        repositoryURL: repository,
        integrationsRootURL: integrations,
        candidateID: candidateID,
        headSHA: snapshot.headSHA
      )
      Issue.record("Expected the candidate and accepted trunk to conflict")
      await store.close()
      return
    } catch GitWorkspaceError.mergeConflict(let worktreePath, let files, _) {
      conflictWorkspace = URL(fileURLWithPath: worktreePath, isDirectory: true)
      #expect(files == ["shared.txt"])
    }
    try Data("accepted trunk behavior\nticket behavior\n".utf8).write(
      to: conflictWorkspace.appendingPathComponent("shared.txt")
    )
    _ = try runGit(["add", "-A"], at: conflictWorkspace)

    let implementation = TicketExecutionResult(
      status: .completed,
      comment: "Delivered the candidate.",
      question: nil,
      options: [],
      summary: "The resolved result is complete.",
      changedFiles: ["shared.txt"],
      tests: ["Focused conflict checks passed"],
      knowledgeNotes: [],
      reviewInstructions: ["Review the resolved integrated result."],
      demo: DemoLaunchSpecification(
        title: "Resolved candidate evidence",
        presentation: DemoPresentation(kind: .artifact, path: "shared.txt")
      ),
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    let executionResultJSON = String(
      decoding: try JSONEncoder().encode(implementation),
      as: UTF8.self
    )
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        id: candidateID,
        productID: product.id,
        sprintID: plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: workItem.id,
        implementationRunID: implementationRun.id,
        version: 1,
        branchName: snapshot.branchName,
        baseSHA: snapshot.baseSHA,
        headSHA: snapshot.headSHA,
        worktreePath: workspace.url.path,
        integrationWorktreePath: conflictWorkspace.path,
        status: .resolvingConflict,
        commitCount: snapshot.commitCount,
        executionResultJSON: executionResultJSON
      )
    )
    let resolutionRun = try await store.createAgentRun(
      AgentRun(
        productID: product.id,
        sprintID: plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: workItem.id,
        profileID: techLead.id,
        status: .running,
        worktreePath: conflictWorkspace.path
      )
    )

    let transport = ScriptedCodexTransport(
      responses: [
        .init(
          method: "initialize",
          result: .object([
            "userAgent": .string("codex-cli/conflict-rereview"),
            "codexHome": .string("/private/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
          ])
        ),
        .init(
          method: "thread/start",
          result: .object(["thread": .object(["id": .string("thread-rereview")])])
        ),
        .init(
          method: "turn/start",
          result: .object(["turn": .object(["id": .string("turn-rereview")])])
        ),
      ],
      inboundMessages: [
        .notification(
          CodexNotification(
            method: "turn/completed",
            params: .object([
              "threadId": .string("thread-rereview"),
              "turn": .object([
                "id": .string("turn-rereview"),
                "status": .string("completed"),
                "items": .array([
                  .object([
                    "id": .string("message-rereview"),
                    "type": .string("agentMessage"),
                    "text": .string(
                      #"{"decision":"approved","comment":"Approved the conflict-resolved result.","findings":[],"retrospectiveWentWell":[],"retrospectiveCouldImprove":[],"retrospectiveActions":[]}"#
                    ),
                  ])
                ]),
              ]),
            ])
          )
        )
      ]
    )
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let delegate = CandidateReviewDelegate(
      store: store,
      client: client,
      productID: product.id,
      databaseURL: databaseURL,
      rootURL: root,
      runs: try await store.fetchAgentRuns(productID: product.id)
    )
    let runtimeCoordinator = TicketDeliveryRuntimeCoordinator(
      prepareScheduler: { _ in },
      drainScheduler: { _ in .finished }
    )
    let coordinator = TicketDeliveryWorkflowCoordinator(
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      runtimeCoordinator: runtimeCoordinator,
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )
    let context = try #require(await coordinator.context(productID: product.id))

    #expect(await coordinator.processIntegrationCandidates(context: context))
    await delegate.waitForReadyCandidate(id: candidate.id)

    let persistedCandidate = try await store.fetchCandidateRevision(id: candidate.id)
    let persistedItem = try #require(
      try await store.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == workItem.id })
    )
    let persistedRuns = try await store.fetchAgentRuns(productID: product.id)
    let focusedReview = try #require(
      persistedRuns.first {
        $0.profileID == techLead.id && $0.id != resolutionRun.id
          && $0.worktreePath == conflictWorkspace.path
      }
    )
    let comments = try await store.fetchComments(workItemID: workItem.id)

    #expect(delegate.errorMessage == nil)
    #expect(persistedCandidate.status == .readyForDemo)
    #expect(persistedCandidate.integratedSHA != candidate.headSHA)
    #expect(persistedCandidate.integrationWorktreePath == conflictWorkspace.path)
    #expect(persistedItem.state == .acceptance)
    #expect(
      try String(
        contentsOf: conflictWorkspace.appendingPathComponent("shared.txt"),
        encoding: .utf8
      ) == "accepted trunk behavior\nticket behavior\n"
    )
    #expect(focusedReview.status == .completed)
    #expect(
      comments.contains {
        $0.authorName == techLead.name
          && $0.body == "Approved the conflict-resolved result."
      }
    )
    #expect(await transport.remainingResponseCount() == 0)

    await client.disconnect()
    await store.close()
  }

  @Test("[D17] Repository approval promotes the exact reviewed revision before Done")
  @MainActor
  func repositoryAcceptancePromotesExactRevision() async throws {
    let harness = try await makeAcceptanceHarness(deliveryKind: .repositoryChange)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    #expect(
      await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      )
    )
    #expect(harness.delegate.errorMessage == nil)

    let candidate = try await harness.store.fetchCandidateRevision(id: harness.candidate.id)
    let item = try #require(
      try await harness.store.fetchWorkItems(productID: harness.product.id)
        .first(where: { $0.id == harness.workItem.id })
    )
    let repository = harness.root.appendingPathComponent("product", isDirectory: true)
    let acceptedSHA = try await harness.gitWorkspaceManager.currentSHA(at: repository)
    let comments = try await harness.store.fetchComments(workItemID: harness.workItem.id)

    #expect(candidate.status == .accepted)
    #expect(item.state == .released)
    #expect(acceptedSHA == harness.candidate.integratedSHA)
    #expect(
      comments.filter { $0.body.contains("is now the accepted trunk") }.count == 1
    )

    await harness.store.close()
  }

  @Test("[D18] Failed acceptance preserves one reviewed result and retries once")
  @MainActor
  func failedAcceptanceRetriesWithoutDuplicateCompletion() async throws {
    let harness = try await makeAcceptanceHarness(deliveryKind: .localOutcome)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let proposalParent = try await harness.store.createKnowledgePage(
      productID: harness.product.id,
      parentID: nil,
      title: "Delivery notes"
    )
    let proposal = KnowledgePageProposal(
      productID: harness.product.id,
      sprintID: harness.candidate.sprintID,
      workItemID: harness.workItem.id,
      candidateRevisionID: harness.candidate.id,
      operation: .create,
      parentPageID: proposalParent.id,
      title: "Rejected proposal",
      proposedBodyMarkdown: "This must not become product truth.",
      rationale: "Exercise recoverable completion."
    )
    try await harness.store.createKnowledgePageProposals([proposal])

    #expect(
      !(await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      ))
    )
    #expect(
      try await harness.store.fetchCandidateRevision(id: harness.candidate.id).status
        == .readyForDemo
    )
    _ = try await harness.store.recordKnowledgePageProposalDecision(
      id: proposal.id,
      accept: false,
      authorName: "Product owner"
    )

    #expect(
      await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      )
    )
    let comments = try await harness.store.fetchComments(workItemID: harness.workItem.id)
    #expect(comments.filter { $0.body.contains("Ticket completion stopped:") }.count == 1)
    #expect(
      comments.filter { $0.body.contains("approved local outcome") }.count == 1
    )
    #expect(
      try await harness.store.fetchCandidateRevision(id: harness.candidate.id).status
        == .accepted
    )

    await harness.store.close()
  }

  @Test("[D19] Repository-free outcome publishes its handoff without Git")
  @MainActor
  func repositoryFreeAcceptanceCompletesWithoutGit() async throws {
    let harness = try await makeAcceptanceHarness(deliveryKind: .localOutcome)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let repository = harness.root.appendingPathComponent("product", isDirectory: true)
    let knowledgePages = try await harness.store.seedKnowledgeBase(
      productID: harness.product.id
    )
    let deliveryHistory = try #require(
      knowledgePages.first { $0.slug == "delivery-history" }
    )
    let knowledgeProposal = KnowledgePageProposal(
      productID: harness.product.id,
      sprintID: harness.candidate.sprintID,
      workItemID: harness.workItem.id,
      candidateRevisionID: harness.candidate.id,
      operation: .create,
      parentPageID: deliveryHistory.id,
      title: "Reviewed recommendation",
      proposedBodyMarkdown: "The durable reviewed recommendation.",
      rationale: "Dependants need the approved outcome.",
      status: .reviewed
    )
    try await harness.store.createKnowledgePageProposals([knowledgeProposal])
    #expect(!FileManager.default.fileExists(atPath: repository.path))

    #expect(
      await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      )
    )
    #expect(harness.delegate.errorMessage == nil)

    let candidate = try await harness.store.fetchCandidateRevision(id: harness.candidate.id)
    let item = try #require(
      try await harness.store.fetchWorkItems(productID: harness.product.id)
        .first(where: { $0.id == harness.workItem.id })
    )
    let comments = try await harness.store.fetchComments(workItemID: harness.workItem.id)
    let publishedKnowledge = try #require(
      try await harness.store.fetchKnowledgePages(productID: harness.product.id)
        .first(where: { $0.title == knowledgeProposal.title })
    )
    #expect(candidate.status == .accepted)
    #expect(candidate.commitCount == 0)
    #expect(item.state == .released)
    #expect(!FileManager.default.fileExists(atPath: repository.path))
    #expect(publishedKnowledge.bodyMarkdown == "The durable reviewed recommendation.")
    #expect(publishedKnowledge.sourceWorkItemID == harness.workItem.id)
    #expect(comments.contains { $0.body.contains("Completion handoff:") })
    #expect(
      comments.contains {
        $0.body
          == "Product owner approved local outcome v1. No repository revision was created or promoted."
      }
    )

    await harness.store.close()
  }

  @Test("[D20] Reviewed research follow-ups publish once with source provenance")
  @MainActor
  func d20ReviewedResearchFollowUpsPublishWithProvenance() async throws {
    let proposals = [
      FollowUpTicketProposalDraft(
        reference: "F1",
        title: "Design provider failure states",
        type: .task,
        body: "Define the unavailable and partial-data owner experience.",
        acceptanceCriteria: ["Every state is reviewable"],
        suggestedRole: .uxDesigner,
        priority: .high,
        rationale: "The approved research identified provider failure behavior."
      ),
      FollowUpTicketProposalDraft(
        reference: "F2",
        title: "Integrate the approved provider",
        type: .story,
        body: "Implement the approved provider contract.",
        acceptanceCriteria: ["The approved provider supplies product data"],
        suggestedRole: .implementer,
        priority: .normal,
        rationale: "This delivers the approved recommendation.",
        dependsOnReferences: ["F1"]
      ),
    ]
    let harness = try await makeAcceptanceHarness(
      deliveryKind: .localOutcome,
      epicOutcome: "Customers receive reliable external data",
      followUpTicketProposals: proposals
    )
    defer { try? FileManager.default.removeItem(at: harness.root) }

    _ = try await harness.store.updateCandidateRevision(
      id: harness.candidate.id,
      status: .reviewing
    )
    #expect(
      !(await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      ))
    )
    #expect(
      try await harness.store.fetchLatestTicketSuggestionBatch(
        productID: harness.product.id
      ) == nil
    )

    _ = try await harness.store.updateCandidateRevision(
      id: harness.candidate.id,
      status: .readyForDemo
    )
    #expect(
      await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      )
    )
    let batch = try #require(
      try await harness.store.fetchLatestTicketSuggestionBatch(
        productID: harness.product.id
      )
    )
    let acceptedWorkItems = try await harness.store.fetchWorkItems(
      productID: harness.product.id
    )

    #expect(batch.session.sourceWorkItemID == harness.workItem.id)
    #expect(batch.session.epicID == harness.workItem.epicID)
    #expect(batch.suggestions.map(\.status).allSatisfy { $0 == .proposed })
    #expect(batch.suggestions.map(\.reference) == ["S1", "S2"])
    #expect(batch.suggestions[0].existingDependencyWorkItemIDs == [harness.workItem.id])
    #expect(batch.suggestions[1].existingDependencyWorkItemIDs == [harness.workItem.id])
    #expect(batch.suggestions[1].dependencyIDs == [batch.suggestions[0].id])
    #expect(acceptedWorkItems.map(\.id) == [harness.workItem.id])
    await harness.store.close()
  }

  @Test("[D21] Final acceptance completes Sprint report evidence durably")
  @MainActor
  func d21FinalAcceptanceCompletesSprintReportEvidence() async throws {
    let harness = try await makeAcceptanceHarness(deliveryKind: .localOutcome)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    #expect(
      await harness.coordinator.completeSprintTicketAcceptance(
        workItemID: harness.workItem.id,
        productID: harness.product.id
      )
    )
    let completed = try #require(
      try await harness.store.fetchSprintHistory(productID: harness.product.id).first
    )
    let completedAt = try #require(completed.sprint.completedAt)
    let startedAt = try #require(completed.sprint.startedAt)
    let acceptedCandidates = try await harness.store
      .fetchCandidateRevisions(productID: harness.product.id)
      .filter { $0.sprintID == completed.sprint.id && $0.status == .accepted }
    let recordedRuns = try await harness.store.fetchAgentRuns(productID: harness.product.id)
      .filter { $0.sprintID == completed.sprint.id }

    #expect(completed.sprint.state == .completed)
    #expect(completed.items.map(\.workItemID) == [harness.workItem.id])
    #expect(completedAt >= startedAt)
    #expect(Set(acceptedCandidates.map(\.workItemID)) == Set([harness.workItem.id]))
    #expect(!recordedRuns.isEmpty)
    await harness.store.close()

    let recoveredStore = try SQLiteStore(
      url: harness.root.appendingPathComponent("product.sqlite")
    )
    let recovered = try #require(
      try await recoveredStore.fetchSprintHistory(productID: harness.product.id).first
    )
    let recoveredCandidates = try await recoveredStore
      .fetchCandidateRevisions(productID: harness.product.id)
      .filter { $0.sprintID == recovered.sprint.id && $0.status == .accepted }
    let recoveredRuns = try await recoveredStore.fetchAgentRuns(productID: harness.product.id)
      .filter { $0.sprintID == recovered.sprint.id }

    #expect(recovered.sprint.state == .completed)
    #expect(recovered.sprint.completedAt == completedAt)
    #expect(recovered.sprint.startedAt == startedAt)
    #expect(recoveredCandidates.map(\.id) == acceptedCandidates.map(\.id))
    #expect(recoveredRuns.map(\.id) == recordedRuns.map(\.id))
    await recoveredStore.close()
  }

  @Test("[D04] Paused delivery relaunches and resumes the same durable run")
  @MainActor
  func pausedDeliveryResumesExistingRun() async throws {
    let harness = try await makeRecoveryHarness(workspaceExists: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    #expect(await harness.coordinator.pauseSprint(harness.plan.sprint))
    let pausedPlan = try #require(
      try await harness.store.fetchCurrentSprint(productID: harness.product.id)
    )
    #expect(pausedPlan.sprint.state == .paused)

    let relaunched = TicketDeliveryWorkflowCoordinator(
      delegate: harness.delegate,
      gitWorkspaceManager: harness.gitWorkspaceManager,
      runtimeCoordinator: TicketDeliveryRuntimeCoordinator(
        prepareScheduler: { _ in },
        drainScheduler: { _ in .finished }
      ),
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )
    let pausedRun = try await harness.store.fetchAgentRun(id: harness.run.id)
    #expect(pausedRun.status == .running)
    #expect(await relaunched.resumeSprint(pausedPlan.sprint))
    await relaunched.recoverDelivery(productID: harness.product.id)
    let recoveredRun = try await harness.store.fetchAgentRun(id: harness.run.id)
    #expect(recoveredRun.status == .queued)
    #expect(try await harness.store.fetchAgentRuns(productID: harness.product.id).count == 1)

    #expect(
      try await harness.store.fetchCurrentSprint(productID: harness.product.id)?.sprint.state
        == .active
    )
    await harness.store.close()
  }

  @Test("[D05] Stopping delivery supersedes the unaccepted candidate")
  @MainActor
  func stoppedDeliveryPreservesAuditAndReturnsTicketToReady() async throws {
    let harness = try await makeRecoveryHarness(workspaceExists: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let sprintItem = try #require(
      harness.plan.items.first { $0.workItemID == harness.workItem.id }
    )
    let candidate = try await harness.store.createCandidateRevision(
      CandidateRevision(
        productID: harness.product.id,
        sprintID: harness.plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: harness.workItem.id,
        implementationRunID: harness.run.id,
        version: 1,
        branchName: "ticket/\(harness.workItem.key)",
        baseSHA: "base",
        headSHA: "head",
        integratedSHA: "integrated",
        worktreePath: harness.run.worktreePath ?? harness.root.path,
        status: .readyForDemo,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )

    #expect(await harness.coordinator.stopSprint(harness.plan.sprint))
    let storedItem = try #require(
      try await harness.store.fetchWorkItems(productID: harness.product.id)
        .first(where: { $0.id == harness.workItem.id })
    )
    let storedRun = try await harness.store.fetchAgentRun(id: harness.run.id)
    let storedCandidate = try await harness.store.fetchCandidateRevision(id: candidate.id)
    let comments = try await harness.store.fetchComments(workItemID: harness.workItem.id)
    #expect(try await harness.store.fetchCurrentSprint(productID: harness.product.id) == nil)
    #expect(storedItem.state == .ready)
    #expect(storedRun.status == .cancelled)
    #expect(storedCandidate.status == .superseded)
    #expect(comments.last?.body.contains("returned to Ready for replanning") == true)
    await harness.store.close()
  }

  @Test(
    "[A11] Crash recovery reuses a durable workspace and explains a missing one",
    arguments: [true, false]
  )
  @MainActor
  func crashRecoveryUsesLastDurableMilestone(workspaceExists: Bool) async throws {
    let harness = try await makeRecoveryHarness(workspaceExists: workspaceExists)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let relaunched = TicketDeliveryWorkflowCoordinator(
      delegate: harness.delegate,
      gitWorkspaceManager: harness.gitWorkspaceManager,
      runtimeCoordinator: TicketDeliveryRuntimeCoordinator(
        prepareScheduler: { _ in },
        drainScheduler: { _ in .finished }
      ),
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )

    await relaunched.recoverDelivery(productID: harness.product.id)

    let recoveredRun = try await harness.store.fetchAgentRun(id: harness.run.id)
    let comments = try await harness.store.fetchComments(workItemID: harness.workItem.id)
    #expect(recoveredRun.id == harness.run.id)
    #expect(recoveredRun.codexThreadID == harness.run.codexThreadID)
    #expect(recoveredRun.worktreePath == harness.run.worktreePath)
    #expect(recoveredRun.status == (workspaceExists ? .queued : .awaitingOwner))
    #expect(comments.last?.body.contains("Recovery after restart") == true)
    #expect(comments.last?.body.contains("is missing") == !workspaceExists)
    #expect(try await harness.store.fetchAgentRuns(productID: harness.product.id).count == 1)
    await harness.store.close()
  }

  @Test("Recovery accepts a run that completed while its stale snapshot was being reconciled")
  @MainActor
  func completedRunRecoveryDoesNotPresentAStaleConflict() async throws {
    let harness = try await makeRecoveryHarness(
      workspaceExists: true,
      recoversCompletedResponse: true
    )
    defer { try? FileManager.default.removeItem(at: harness.root) }

    await harness.coordinator.recoverDelivery(productID: harness.product.id)

    let recoveredRun = try await harness.store.fetchAgentRun(id: harness.run.id)
    let candidates = try await harness.store.fetchCandidateRevisions(
      productID: harness.product.id
    )
    let recoveredItem = try #require(
      try await harness.store.fetchWorkItems(productID: harness.product.id)
        .first(where: { $0.id == harness.workItem.id })
    )
    #expect(recoveredRun.status == .completed)
    #expect(candidates.count == 1)
    #expect(candidates.first?.implementationRunID == recoveredRun.id)
    #expect(candidates.first?.status == .queuedForIntegration)
    #expect(recoveredItem.state == .integrating)
    #expect(harness.delegate.errorMessage == nil)

    await harness.client.disconnect()
    await harness.store.close()
  }

  @Test("Completed run conflicts require a matching active delivery candidate")
  func completedRunConflictPolicyRequiresValidCandidate() throws {
    let productID = UUID()
    let workItemID = UUID()
    let run = AgentRun(
      productID: productID,
      workItemID: workItemID,
      profileID: UUID(),
      status: .completed
    )
    let result = TicketExecutionResult(
      status: .completed,
      comment: "Completed.",
      question: nil,
      options: [],
      summary: "Completed delivery.",
      changedFiles: ["result.txt"],
      tests: ["Verified"],
      knowledgeNotes: [],
      reviewInstructions: ["Review the recovered result."],
      demo: DemoLaunchSpecification(
        title: "Result",
        presentation: DemoPresentation(kind: .artifact, path: "result.txt")
      ),
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    var candidate = CandidateRevision(
      productID: productID,
      sprintID: UUID(),
      sprintItemID: UUID(),
      workItemID: workItemID,
      implementationRunID: run.id,
      version: 1,
      branchName: "ticket/T1",
      baseSHA: "base",
      headSHA: "head",
      worktreePath: "/tmp/T1",
      status: .queuedForIntegration,
      commitCount: 1,
      executionResultJSON: String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    )

    #expect(
      TicketDeliveryRecoveryRunConflictPolicy.disposition(
        run: run,
        productID: productID,
        workItemID: workItemID,
        candidates: [candidate]
      ) == .alreadyRecovered
    )
    #expect(
      TicketDeliveryRecoveryRunConflictPolicy.disposition(
        run: run,
        productID: productID,
        workItemID: workItemID,
        candidates: []
      ) == .failure(.contradictoryRunState)
    )

    candidate.status = .failed
    #expect(
      TicketDeliveryRecoveryRunConflictPolicy.disposition(
        run: run,
        productID: productID,
        workItemID: workItemID,
        candidates: [candidate]
      ) == .failure(.contradictoryRunState)
    )
  }


  @MainActor
  private func makeAcceptanceHarness(
    deliveryKind: CandidateDeliveryKind,
    demo: DemoLaunchSpecification? = nil,
    epicOutcome: String? = nil,
    followUpTicketProposals: [FollowUpTicketProposalDraft] = []
  ) async throws -> AcceptanceHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-acceptance-coordinator-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = root.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Acceptance authority")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let techLead = try #require(profiles.first { $0.role == .lead })
    let epic =
      if let epicOutcome {
        try await store.createEpic(productID: product.id, outcome: epicOutcome)
      } else {
        Optional<Epic>.none
      }
    var workItem = try await store.createWorkItem(
      productID: product.id,
      title: deliveryKind == .localOutcome
        ? "Approve the reviewed recommendation"
        : "Approve the reviewed product change",
      type: .story,
      body: "Complete only the exact reviewed result.",
      acceptanceCriteria: ["The accepted result becomes durable exactly once."],
      priority: .normal,
      epicID: epic?.id
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .refining,
      actor: "Product owner",
      reason: "Refinement started"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready for delivery"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Complete one reviewed result",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: workItem.id, implementerProfileID: implementer.id, reviewerProfileID: techLead.id, estimatedTokens: 1)
      ]
    )
    let plan = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(plan.items.first)
    let implementationRun = try #require(
      try await store.fetchAgentRuns(productID: product.id).first
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .running,
      actor: implementer.name,
      reason: "Implementation started"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .integrating,
      actor: implementer.name,
      reason: "Reviewed result produced"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .verifying,
      actor: techLead.name,
      reason: "Exact result reviewed"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .acceptance,
      actor: techLead.name,
      reason: "Ready for product owner approval"
    )

    let result = TicketExecutionResult(
      status: .completed,
      comment: "Delivered the accepted outcome.",
      question: nil,
      options: [],
      summary: "The reviewed outcome is complete.",
      changedFiles: deliveryKind == .repositoryChange ? ["feature.txt"] : [],
      tests: ["Acceptance journey fixture"],
      knowledgeNotes: [],
      reviewInstructions: ["Approve the exact reviewed result."],
      demo: demo,
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: [],
      followUpTicketProposals: followUpTicketProposals
    )
    let encodedResult = try JSONEncoder().encode(result)
    var resultObject = try #require(
      JSONSerialization.jsonObject(with: encodedResult) as? [String: Any]
    )
    resultObject["followUpTicketProposals"] = followUpTicketProposals.map { proposal in
      let priority = switch proposal.priority {
      case .urgent: "urgent"
      case .high: "high"
      case .normal: "normal"
      case .low: "low"
      }
      return [
        "reference": proposal.reference,
        "title": proposal.title,
        "type": proposal.type.rawValue,
        "body": proposal.body,
        "acceptanceCriteria": proposal.acceptanceCriteria,
        "role": proposal.suggestedRole.rawValue,
        "priority": priority,
        "rationale": proposal.rationale,
        "dependsOn": proposal.dependsOnReferences,
      ] as [String: Any]
    }
    let resultData = try JSONSerialization.data(withJSONObject: resultObject)
    let resultJSON = try #require(String(data: resultData, encoding: .utf8))
    let gitWorkspaceManager = GitWorkspaceManager()
    let candidateID = UUID()
    let candidate: CandidateRevision
    if deliveryKind == .repositoryChange {
      let repository = root.appendingPathComponent("product", isDirectory: true)
      let ticketWorktrees = root.appendingPathComponent("tickets", isDirectory: true)
      let integrations = root.appendingPathComponent("integrations", isDirectory: true)
      try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true
      )
      _ = try await gitWorkspaceManager.ensureRepository(at: repository)
      let workspace = try await gitWorkspaceManager.prepareTicketWorkspace(
        repositoryURL: repository,
        worktreesRootURL: ticketWorktrees,
        ticketKey: workItem.key,
        runID: implementationRun.id,
        authorName: implementer.name
      )
      try Data("reviewed product change\n".utf8).write(
        to: workspace.url.appendingPathComponent("feature.txt")
      )
      let snapshot = try await gitWorkspaceManager.createCandidate(
        ticketWorkspaceURL: workspace.url,
        ticketKey: workItem.key,
        version: 1,
        authorName: implementer.name,
        summary: "Deliver the reviewed product change"
      )
      let integration = try await gitWorkspaceManager.integrateCandidate(
        repositoryURL: repository,
        integrationsRootURL: integrations,
        candidateID: candidateID,
        headSHA: snapshot.headSHA
      )
      candidate = CandidateRevision(
        id: candidateID,
        productID: product.id,
        sprintID: plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: workItem.id,
        implementationRunID: implementationRun.id,
        version: 1,
        branchName: snapshot.branchName,
        baseSHA: snapshot.baseSHA,
        headSHA: snapshot.headSHA,
        integratedSHA: integration.integratedSHA,
        worktreePath: workspace.url.path,
        integrationWorktreePath: integration.url.path,
        status: .readyForDemo,
        commitCount: snapshot.commitCount,
        executionResultJSON: resultJSON
      )
    } else {
      candidate = CandidateRevision(
        id: candidateID,
        productID: product.id,
        sprintID: plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: workItem.id,
        implementationRunID: implementationRun.id,
        version: 1,
        deliveryKind: .localOutcome,
        branchName: "ticket/\(workItem.key)",
        baseSHA: "local-outcome",
        headSHA: "local-outcome",
        worktreePath: root.appendingPathComponent("ticket", isDirectory: true).path,
        status: .readyForDemo,
        commitCount: 0,
        executionResultJSON: resultJSON
      )
    }
    _ = try await store.createCandidateRevision(candidate)
    _ = try await store.appendComment(
      workItemID: workItem.id,
      authorKind: .agent,
      authorName: implementer.name,
      body: result.workLogComment
    )

    let client = CodexAppServerClient(
      transport: ScriptedCodexTransport(responses: [])
    )
    let delegate = CandidateReviewDelegate(
      store: store,
      client: client,
      productID: product.id,
      databaseURL: databaseURL,
      rootURL: root,
      runs: [implementationRun]
    )
    let coordinator = TicketDeliveryWorkflowCoordinator(
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      runtimeCoordinator: TicketDeliveryRuntimeCoordinator(
        prepareScheduler: { _ in },
        drainScheduler: { _ in .finished }
      ),
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )
    return AcceptanceHarness(
      root: root,
      store: store,
      product: product,
      workItem: workItem,
      candidate: candidate,
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      coordinator: coordinator
    )
  }

  /// Existing partial coverage:
  /// - `SQLiteStoreTests.agentPermissionRequests`
  /// - `AgentPermissionResolutionTests.persistenceFailureFailsClosed`
  /// - `AgentPermissionGrantPolicyTests.structuredCoverage`
  /// This test covers only D08's three owner review actions through the permission workflow.
  @Test("D08 permission review supports Deny Allow once and Always allow")
  @MainActor
  func d08PermissionReviewActionsPersistDistinctDecisions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-d08-permissions-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Permission review")
    let profile = try #require(
      try await store.seedDefaultProfiles(productID: product.id)
        .first { $0.role == .implementer }
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Review three capabilities"
    )
    let run = try await store.createAgentRun(
      AgentRun(
        productID: product.id,
        workItemID: item.id,
        profileID: profile.id,
        status: .awaitingOwner
      )
    )
    let decisions: [(String, Bool, Bool)] = [
      ("deny", false, false),
      ("once", true, false),
      ("always", true, true),
    ]
    var requests: [AgentPermissionRequest] = []
    for (label, _, _) in decisions {
      let request = AgentPermissionRequest(
        productID: product.id,
        workItemID: item.id,
        agentRunID: run.id,
        threadID: "thread-d08",
        turnID: "turn-\(label)",
        serverRequestID: "request-\(label)",
        method: "item/commandExecution/requestApproval",
        kind: .command,
        title: "Allow this command?",
        detail: "command-\(label)",
        signature: "command|\(label)",
        productGrantSignature: "product-command|\(label)",
        status: .interrupted
      )
      requests.append(try await store.saveAgentPermissionRequest(request))
    }
    let client = CodexAppServerClient(transport: ScriptedCodexTransport(responses: []))
    let delegate = CandidateReviewDelegate(
      store: store,
      client: client,
      productID: product.id,
      databaseURL: databaseURL,
      rootURL: root,
      runs: [run]
    )
    let coordinator = TicketDeliveryPermissionWorkflowCoordinator(
      delegate: delegate,
      runtimeCoordinator: TicketDeliveryRuntimeCoordinator(
        prepareScheduler: { _ in },
        drainScheduler: { _ in .finished }
      )
    )

    for (index, decision) in decisions.enumerated() {
      await coordinator.decidePermissionRequest(
        requests[index],
        allow: decision.1,
        rememberForProduct: decision.2
      )
    }

    let stored = try await store.fetchAgentPermissionRequests(productID: product.id)
    let statuses = Dictionary(uniqueKeysWithValues: stored.map { ($0.serverRequestID, $0.status) })
    #expect(statuses["request-deny"] == .denyPendingDelivery)
    #expect(statuses["request-once"] == .allowOncePendingDelivery)
    #expect(statuses["request-always"] == .allowProductPendingDelivery)
    let grants = try await store.fetchAgentPermissionGrants(productID: product.id)
    #expect(grants.count == 1)
    #expect(grants.first?.signature == "product-command|always")
    #expect(delegate.presentedPermissionRequests.count == 3)
    #expect(delegate.presentedPermissionGrants == grants)
    await store.close()
  }

  /// Existing partial coverage:
  /// - `SprintTicketWorkLogHistoryTests.selectedAnswerRemainsOnQuestionAndInWorkLog`
  /// - `SprintTicketWorkLogHistoryTests.customAnswerRemainsOnQuestionAndInWorkLog`
  /// - `SprintTicketWorkLogHistoryTests.activeTicketQuestionRouting`
  /// This test covers only D09's Submit-answers boundary from durable answer to exact-run resume.
  @Test("D09 submitting answers resumes the exact paused run")
  @MainActor
  func d09SubmittedAnswersResumeExactRun() async throws {
    let harness = try await makeRecoveryHarness(workspaceExists: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let awaitingRun = try await harness.store.updateAgentRun(
      id: harness.run.id,
      status: .awaitingOwner,
      eventActor: "Implementer",
      eventDetail: "Waiting for one product decision"
    )
    harness.delegate.runs = [awaitingRun]
    let question = TicketRefinementQuestion(
      prompt: "Which runtime should be used?",
      options: ["Bundled", "System"]
    )
    let answer = TicketAnsweredQuestion(
      question: question,
      selectedOption: "Bundled",
      answer: "Bundled"
    )
    _ = try await harness.store.appendComment(
      workItemID: harness.workItem.id,
      authorKind: .owner,
      authorName: "Product owner",
      body: "Use the bundled runtime.",
      answeredQuestions: [answer]
    )

    await harness.coordinator.handleSprintOwnerComment(
      productID: harness.product.id,
      workItemID: harness.workItem.id,
      body: "Use the bundled runtime."
    )

    let resumed = try await harness.store.fetchAgentRun(id: awaitingRun.id)
    #expect(resumed.id == awaitingRun.id)
    #expect(resumed.status == .queued)
    #expect(harness.delegate.scheduledProductIDs == [harness.product.id])
    let comments = try await harness.store.fetchComments(workItemID: harness.workItem.id)
    #expect(comments.last?.answeredQuestions == [answer])
    await harness.store.close()
  }

  /// Existing partial coverage:
  /// - `SprintWorkRecoveryTests.failedPostReviewDemoIsRecoverable`
  /// - `MacOSDemoLauncherTests.hostFailureDisposition`
  /// This test covers only D14's command composition that retries demo preparation on the
  /// immutable reviewed candidate without repeating implementation or tech lead review.
  @Test("D14 demo preparation retry reuses the reviewed candidate")
  @MainActor
  func d14DemoRetryReusesReviewedCandidate() async throws {
    let demo = DemoLaunchSpecification(
      title: "Reviewed preview",
      presentation: DemoPresentation(kind: .macApplication, path: "Preview.app")
    )
    let harness = try await makeAcceptanceHarness(
      deliveryKind: .repositoryChange,
      demo: demo
    )
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let profiles = try await harness.store.fetchAgentProfiles(productID: harness.product.id)
    let techLead = try #require(profiles.first { $0.role == .lead })
    let implementationRun = try #require(
      try await harness.store.fetchAgentRuns(productID: harness.product.id)
        .first { $0.id == harness.candidate.implementationRunID }
    )
    let awaitingRun = try await harness.store.updateAgentRun(
      id: implementationRun.id,
      status: .awaitingOwner,
      eventActor: "Spedito",
      eventDetail: "Demo preparation failed after review"
    )
    let reviewRun = try await harness.store.createAgentRun(
      AgentRun(
        productID: harness.product.id,
        sprintID: harness.candidate.sprintID,
        sprintItemID: harness.candidate.sprintItemID,
        workItemID: harness.workItem.id,
        profileID: techLead.id,
        status: .running,
        worktreePath: harness.candidate.integrationWorktreePath
      )
    )
    let completedReview = try await harness.store.updateAgentRun(
      id: reviewRun.id,
      status: .completed,
      eventActor: techLead.name,
      eventDetail: "Reviewed exact integrated revision"
    )
    _ = try await harness.store.updateCandidateRevision(
      id: harness.candidate.id,
      status: .failed
    )
    _ = try await harness.store.transitionWorkItem(
      id: harness.workItem.id,
      to: .running,
      actor: "Spedito",
      reason: "Preserving reviewed candidate after demo failure"
    )
    harness.delegate.runs = [awaitingRun, completedReview]

    let context = try #require(
      await harness.coordinator.context(productID: harness.product.id)
    )
    #expect(context.workItems.first { $0.id == harness.workItem.id }?.state == .running)
    #expect(context.candidates.first { $0.id == harness.candidate.id }?.status == .failed)
    #expect(context.runs.first { $0.id == awaitingRun.id }?.status == .awaitingOwner)
    #expect(context.runs.first { $0.id == completedReview.id }?.status == .completed)
    let failedCandidate = try #require(
      context.candidates.first { $0.id == harness.candidate.id }
    )
    #expect(failedCandidate.integratedSHA != nil)
    #expect(failedCandidate.integrationWorktreePath != nil)
    #expect(
      context.runs.first { $0.id == awaitingRun.id }?.id
        == failedCandidate.implementationRunID
    )
    #expect(
      context.runs.first { $0.id == completedReview.id }?.worktreePath
        == failedCandidate.integrationWorktreePath
    )
    #expect(
      try CodexTicketExecutor.decode(failedCandidate.executionResultJSON).demo == demo
    )
    #expect(
      SprintWorkRecoveryPolicy().failedPostReviewDemoCandidate(
        workItemID: harness.workItem.id,
        workItems: context.workItems,
        candidates: context.candidates,
        runs: context.runs,
        profiles: context.profiles
      )?.id == harness.candidate.id
    )

    let retried = await harness.coordinator.retryFailedPostReviewDemo(
      productID: harness.product.id,
      workItemID: harness.workItem.id
    )

    #expect(retried)
    #expect(harness.delegate.preparedDemoCandidateIDs == [harness.candidate.id])
    #expect(
      try await harness.store.fetchCandidateRevision(id: harness.candidate.id).status
        == .readyForDemo
    )
    #expect(
      try await harness.store.fetchAgentRun(id: implementationRun.id).status == .completed
    )
    #expect(
      try await harness.store.fetchWorkItems(productID: harness.product.id)
        .first { $0.id == harness.workItem.id }?.state == .acceptance
    )
    #expect(try await harness.store.fetchAgentRuns(productID: harness.product.id).count == 2)
    await harness.store.close()
  }

  @Test("A reviewing candidate held by its integration task is not reviewed a second time")
  func reviewingCandidateUnderIntegrationIsNotResumed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-review-race-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let gitWorkspaceManager = GitWorkspaceManager()
    let productRepository = root.appendingPathComponent("product", isDirectory: true)
    let reviewedSHA = try await gitWorkspaceManager.ensureRepository(at: productRepository)

    let databaseURL = root.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Review race authority")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let techLead = try #require(profiles.first { $0.role == .lead })
    var workItem = try await store.createWorkItem(
      productID: product.id,
      title: "Review exactly once",
      acceptanceCriteria: ["One candidate receives one tech lead review."]
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .refining,
      actor: "Product owner",
      reason: "Refined"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Review one candidate once",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: workItem.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: techLead.id,
          estimatedTokens: 1
        )
      ]
    )
    let plan = try await store.startSprint(id: draft.sprint.id)
    let sprintItem = try #require(plan.items.first)
    let implementationRun = try #require(
      try await store.fetchAgentRuns(productID: product.id)
        .first(where: { $0.workItemID == workItem.id })
    )
    let integrationWorkspace = root.appendingPathComponent("integration", isDirectory: true)
    try FileManager.default.createDirectory(
      at: integrationWorkspace,
      withIntermediateDirectories: true
    )

    // integrateCandidateBeforeReview leaves the candidate in .reviewing for the whole
    // review it performs itself, while holding only the integration task.
    let candidate = try await store.createCandidateRevision(
      CandidateRevision(
        productID: product.id,
        sprintID: plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: workItem.id,
        implementationRunID: implementationRun.id,
        version: 1,
        branchName: "ticket/T1",
        baseSHA: reviewedSHA,
        headSHA: reviewedSHA,
        integratedSHA: reviewedSHA,
        worktreePath: implementationRun.worktreePath ?? root.path,
        integrationWorktreePath: integrationWorkspace.path,
        status: .reviewing,
        commitCount: 1,
        executionResultJSON: "{}"
      )
    )
    _ = try await store.createAgentRun(
      AgentRun(
        productID: product.id,
        sprintID: plan.sprint.id,
        sprintItemID: sprintItem.id,
        workItemID: workItem.id,
        profileID: techLead.id,
        status: .running,
        codexThreadID: "thread-review-race",
        worktreePath: integrationWorkspace.path,
        createdAt: candidate.updatedAt.addingTimeInterval(1),
        updatedAt: candidate.updatedAt.addingTimeInterval(1)
      )
    )

    let transport = ScriptedCodexTransport(
      responses: [
        .init(
          method: "initialize",
          result: .object([
            "userAgent": .string("codex-cli/review-race"),
            "codexHome": .string("/private/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
          ])
        )
      ],
      inboundMessages: []
    )
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.connect()
    let delegate = CandidateReviewDelegate(
      store: store,
      client: client,
      productID: product.id,
      databaseURL: databaseURL,
      rootURL: root,
      runs: try await store.fetchAgentRuns(productID: product.id)
    )
    let runtimeCoordinator = TicketDeliveryRuntimeCoordinator(
      prepareScheduler: { _ in },
      drainScheduler: { _ in .finished }
    )
    let coordinator = TicketDeliveryWorkflowCoordinator(
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      runtimeCoordinator: runtimeCoordinator,
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )
    let context = try #require(await coordinator.context(productID: product.id))

    let (holdStream, holdContinuation) = AsyncStream<Void>.makeStream()
    #expect(
      runtimeCoordinator.startIntegration(
        candidateID: candidate.id,
        productID: product.id
      ) {
        for await _ in holdStream {}
      }
    )

    // The in-flight integration owns this candidate's review, so the sweeper must skip it.
    let startedWhileIntegrating = await coordinator.processIntegrationCandidates(
      context: context
    )
    #expect(startedWhileIntegrating == false)
    #expect(runtimeCoordinator.isReviewInProgress(candidateID: candidate.id) == false)

    // Once nothing owns the candidate, the same sweep still recovers an orphaned review,
    // which is what this loop exists to do after a relaunch.
    holdContinuation.finish()
    while runtimeCoordinator.isIntegrationInProgress(candidateID: candidate.id) {
      await Task.yield()
    }
    let startedAfterIntegration = await coordinator.processIntegrationCandidates(
      context: context
    )
    #expect(startedAfterIntegration)

    await runtimeCoordinator.cancel(productID: product.id)
    await store.close()
  }

  @MainActor
  private func makeRecoveryHarness(
    workspaceExists: Bool,
    recoversCompletedResponse: Bool = false
  ) async throws -> RecoveryHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-recovery-coordinator-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = root.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Recovery authority")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    var workItem = try await store.createWorkItem(
      productID: product.id,
      title: "Resume preserved delivery",
      acceptanceCriteria: ["Recovery reuses the durable run."]
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .refining,
      actor: "Product owner",
      reason: "Refined"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Recover without replacement work",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: workItem.id, implementerProfileID: implementer.id, estimatedTokens: 1)
      ]
    )
    let plan = try await store.startSprint(id: draft.sprint.id)
    var run = try #require(
      try await store.fetchAgentRuns(productID: product.id)
        .first(where: { $0.workItemID == workItem.id })
    )
    let gitWorkspaceManager = GitWorkspaceManager()
    let productWorkspace = root.appendingPathComponent("product", isDirectory: true)
    _ = try await gitWorkspaceManager.ensureRepository(at: productWorkspace)
    let ticketWorkspace: URL
    if recoversCompletedResponse {
      let prepared = try await gitWorkspaceManager.prepareTicketWorkspace(
        repositoryURL: productWorkspace,
        worktreesRootURL: root.appendingPathComponent("tickets", isDirectory: true),
        ticketKey: workItem.key,
        runID: run.id,
        authorName: implementer.name
      )
      ticketWorkspace = prepared.url
      try Data("Recovered delivery evidence.\n".utf8).write(
        to: ticketWorkspace.appendingPathComponent("recovered.txt")
      )
    } else {
      ticketWorkspace = root.appendingPathComponent("ticket", isDirectory: true)
      if workspaceExists {
        try FileManager.default.createDirectory(
          at: ticketWorkspace,
          withIntermediateDirectories: true
        )
      }
    }
    run = try await store.updateAgentRun(
      id: run.id,
      status: .running,
      codexThreadID: "thread-recovery",
      worktreePath: ticketWorkspace.path,
      eventActor: implementer.name,
      eventDetail: "Delivery was active"
    )
    workItem = try await store.transitionWorkItem(
      id: workItem.id,
      to: .running,
      actor: implementer.name,
      reason: "Delivery started"
    )
    let transport: ScriptedCodexTransport
    if recoversCompletedResponse {
      let result = TicketExecutionResult(
        status: .completed,
        comment: "Recovered the completed delivery.",
        question: nil,
        options: [],
        summary: "The preserved implementation completed successfully.",
        changedFiles: ["recovered.txt"],
        tests: ["Recovery fixture verified"],
        knowledgeNotes: [],
        reviewInstructions: ["Review the recovered candidate."],
        demo: DemoLaunchSpecification(
          title: "Recovered result",
          presentation: DemoPresentation(kind: .artifact, path: "recovered.txt")
        ),
        retrospectiveWentWell: [],
        retrospectiveCouldImprove: [],
        retrospectiveActions: []
      )
      let resultJSON = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
      transport = ScriptedCodexTransport(
        responses: [
          .init(
            method: "initialize",
            result: .object([
              "userAgent": .string("codex-cli/recovery-journey"),
              "codexHome": .string("/private/tmp/codex"),
              "platformFamily": .string("unix"),
              "platformOs": .string("macos"),
            ])
          ),
          .init(
            method: "thread/resume",
            result: .object([
              "thread": .object(["id": .string("thread-recovery")])
            ])
          ),
          .init(
            method: "thread/read",
            result: .object([
              "thread": .object([
                "id": .string("thread-recovery"),
                "turns": .array([
                  .object([
                    "id": .string("turn-recovery"),
                    "status": .string("completed"),
                    "items": .array([
                      .object([
                        "id": .string("message-recovery"),
                        "type": .string("agentMessage"),
                        "phase": .string("final_answer"),
                        "text": .string(resultJSON),
                      ])
                    ]),
                  ])
                ]),
              ])
            ])
          ),
        ]
      )
    } else {
      transport = ScriptedCodexTransport(responses: [])
    }
    let client = CodexAppServerClient(transport: transport)
    if recoversCompletedResponse {
      _ = try await client.connect()
    }
    let delegate = CandidateReviewDelegate(
      store: store,
      client: client,
      productID: product.id,
      databaseURL: databaseURL,
      rootURL: root,
      runs: [run]
    )
    let coordinator = TicketDeliveryWorkflowCoordinator(
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      runtimeCoordinator: TicketDeliveryRuntimeCoordinator(
        prepareScheduler: { _ in },
        drainScheduler: { _ in .finished }
      ),
      recoveryPolicy: SprintWorkRecoveryPolicy()
    )
    return RecoveryHarness(
      root: root,
      store: store,
      product: product,
      plan: plan,
      workItem: workItem,
      run: run,
      client: client,
      delegate: delegate,
      gitWorkspaceManager: gitWorkspaceManager,
      coordinator: coordinator
    )
  }


  @MainActor
  private struct AcceptanceHarness {
    let root: URL
    let store: SQLiteStore
    let product: Product
    let workItem: WorkItem
    let candidate: CandidateRevision
    let delegate: CandidateReviewDelegate
    let gitWorkspaceManager: GitWorkspaceManager
    let coordinator: TicketDeliveryWorkflowCoordinator
  }

  @MainActor
  private struct RecoveryHarness {
    let root: URL
    let store: SQLiteStore
    let product: Product
    let plan: SprintPlan
    let workItem: WorkItem
    let run: AgentRun
    let client: CodexAppServerClient
    let delegate: CandidateReviewDelegate
    let gitWorkspaceManager: GitWorkspaceManager
    let coordinator: TicketDeliveryWorkflowCoordinator
  }
  private func runGit(_ arguments: [String], at directory: URL) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw GitWorkspaceError.commandFailed(arguments: arguments, output: output)
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

}

@MainActor
private final class CandidateReviewDelegate: TicketDeliveryWorkflowDelegate {
  let store: SQLiteStore
  let client: CodexAppServerClient
  let productID: UUID
  let databaseURL: URL
  let rootURL: URL
  var runs: [AgentRun]
  var errorMessage: String?
  var knowledgeContext: [AgentRunKnowledgePage] = []
  var knowledgeDestinations: [AgentRunKnowledgeDestination] = []
  var presentedRuns: [AgentRun] = []
  var presentedPermissionRequests: [AgentPermissionRequest] = []
  var presentedPermissionGrants: [AgentPermissionGrant] = []
  var scheduledProductIDs: [UUID] = []
  var preparedDemoCandidateIDs: [UUID] = []
  private let readyCandidateIDs: AsyncStream<UUID>
  private let readyCandidateContinuation: AsyncStream<UUID>.Continuation

  init(
    store: SQLiteStore,
    client: CodexAppServerClient,
    productID: UUID,
    databaseURL: URL,
    rootURL: URL,
    runs: [AgentRun]
  ) {
    let readyCandidatePair = AsyncStream<UUID>.makeStream()
    readyCandidateIDs = readyCandidatePair.stream
    readyCandidateContinuation = readyCandidatePair.continuation
    self.store = store
    self.client = client
    self.productID = productID
    self.databaseURL = databaseURL
    self.rootURL = rootURL
    self.runs = runs
  }


  func waitForReadyCandidate(id: UUID) async {
    for await candidateID in readyCandidateIDs where candidateID == id {
      return
    }
    preconditionFailure("The candidate update stream ended before ready for demo")
  }

  func deliveryStore(for productID: UUID) -> SQLiteStore? {
    productID == self.productID ? store : nil
  }

  func deliveryStore(containingAgentRun runID: UUID) async -> SQLiteStore? {
    store
  }

  var deliveryCodexClient: CodexAppServerClient? { client }
  var deliverySelectedProductID: UUID? { productID }
  var deliveryIsShuttingDown: Bool { false }
  var deliveryRuns: [AgentRun] { runs }

  var deliveryErrorMessage: String? {
    get { errorMessage }
    set { errorMessage = newValue }
  }

  var deliveryAgentRunKnowledgeContext: [AgentRunKnowledgePage] {
    get { knowledgeContext }
    set { knowledgeContext = newValue }
  }

  var deliveryAgentRunKnowledgeDestinations: [AgentRunKnowledgeDestination] {
    get { knowledgeDestinations }
    set { knowledgeDestinations = newValue }
  }

  func deliveryProductWorkspaceURL(productID: UUID) throws -> URL {
    rootURL.appendingPathComponent("product", isDirectory: true)
  }

  func deliveryTicketWorktreesRootURL(productID: UUID) throws -> URL {
    rootURL.appendingPathComponent("tickets", isDirectory: true)
  }

  func deliveryProductDatabaseURL(productID: UUID) throws -> URL {
    databaseURL
  }

  func deliveryIntegrationWorktreesRootURL(productID: UUID) throws -> URL {
    rootURL.appendingPathComponent("integrations", isDirectory: true)
  }

  func deliveryIntegrateLatestGitHubChanges(
    candidate: CandidateRevision,
    integration: GitIntegrationSnapshot
  ) async throws -> TicketDeliveryRemoteIntegration {
    TicketDeliveryRemoteIntegration(
      snapshot: integration,
      incorporatedChanges: false,
      remoteSHA: nil
    )
  }

  var deliveryRequiresKnowledgeApproval: Bool { false }
  var deliveryDemoSessions: [DemoSession] { [] }

  func deliveryRemoteRepositoryState(productID: UUID) async -> GitHubRemoteRepositoryState? {
    nil
  }

  func deliverySyncTicketPullRequestForDelivery(
    productID: UUID,
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync {
    throw GitHubRemoteRepositoryServiceError.notConfigured
  }

  func deliveryHandleGitHubPullRequestSync(
    _ sync: GitHubTicketPullRequestSync,
    productID: UUID
  ) async {}

  func deliveryCheckRemoteRepositoryForDelivery(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState? {
    nil
  }

  func deliveryAcceptSafeRemoteSync(syncID: UUID, productID: UUID) async throws {
    throw GitHubRemoteRepositoryServiceError.notConfigured
  }

  func deliveryMergeTicketPullRequest(
    publicationID: UUID,
    productID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult? {
    nil
  }

  func deliveryReturnTicketPullRequestToDraft(
    publicationID: UUID,
    productID: UUID
  ) async throws {
    throw GitHubRemoteRepositoryServiceError.notConfigured
  }

  func deliveryPrepareTicketPullRequestIfConnected(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> RemotePublication? {
    nil
  }

  func deliveryMarkTicketPullRequestReadyIfNeeded(
    _ publication: RemotePublication?
  ) async throws {}

  func deliveryPrepareDemoForAcceptance(
    candidate: CandidateRevision,
    integratedSHA: String,
    specification: DemoLaunchSpecification
  ) async throws {
    preparedDemoCandidateIDs.append(candidate.id)
  }


  func deliveryDemoPreparationShouldCorrectCandidate(_ error: Error) -> Bool {
    error is DemoLaunchValidationError
  }
  func deliveryStopManagedSession(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    removesPreview: Bool
  ) async {}

  func deliveryStopDemoSessions(productID: UUID, includesPreparation: Bool) async {}

  func deliveryScheduleRetrospectiveSyntheses() {}

  func deliveryInheritedAgentInstructions(
    for product: Product,
    includesMandatoryKnowledge: Bool
  ) -> String {
    "Review only the supplied candidate."
  }

  func deliveryAgentRunDidUpdate(previous: AgentRun, updated: AgentRun) async {
    runs.removeAll { $0.id == updated.id }
    runs.append(updated)
    presentedRuns.append(updated)
  }

  func deliveryReloadSelectedProductIfCurrent(productID: UUID) async {
    guard
      let candidate = try? await store.fetchCandidateRevisions(productID: productID)
        .first(where: { $0.status == .readyForDemo }),
      let workItem = try? await store.fetchWorkItems(productID: productID)
        .first(where: { $0.id == candidate.workItemID }),
      workItem.state == .acceptance
    else { return }
    readyCandidateContinuation.yield(candidate.id)
  }
  func deliveryReplacePermissionRequest(_ request: AgentPermissionRequest) {
    presentedPermissionRequests.append(request)
  }
  func deliveryReplacePermissionGrant(_ grant: AgentPermissionGrant) {
    presentedPermissionGrants.append(grant)
  }
  func deliveryScheduleSprintExecution(productID: UUID) {
    scheduledProductIDs.append(productID)
  }

  func deliveryMonitorLiveActivity(
    runID: UUID,
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String,
    initialText: String
  ) {}

  func deliveryStopLiveActivityMonitoring(runID: UUID) {}

  func deliveryPresentExecutionError(_ error: Error, productID: UUID) {
    errorMessage = error.localizedDescription
  }

  func deliveryStopDemoSession(
    _ candidate: CandidateRevision,
    removesPreview: Bool
  ) async {}

}
