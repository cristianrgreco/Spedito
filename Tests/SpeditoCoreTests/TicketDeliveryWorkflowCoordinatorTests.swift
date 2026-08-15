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
        SprintDraftItemInput(
          workItemID: workItem.id,
          implementerProfileID: implementer.id,
          reviewerProfileID: techLead.id
        )
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
        baseSHA: "base-sha",
        headSHA: "candidate-sha",
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
      integratedSHA: "integrated-sha"
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
      gitWorkspaceManager: GitWorkspaceManager(),
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

    #expect(persistedCandidate.status == .reviewing)
    #expect(persistedCandidate.headSHA == "candidate-sha")
    #expect(persistedCandidate.integratedSHA == "integrated-sha")
    #expect(persistedCandidate.integrationWorktreePath == reviewWorkspace.path)
    #expect(persistedItem.state == .verifying)
    #expect(reviewRun.status == .completed)
    #expect(reviewRun.worktreePath == reviewWorkspace.path)
    #expect(comments.contains { $0.authorName == techLead.name && $0.body == "Approved the exact candidate." })
    #expect(delegate.finalizedCandidateID == candidate.id)
    #expect(delegate.presentedRuns.contains { $0.id == reviewRun.id && $0.status == .completed })
    #expect(await transport.remainingResponseCount() == 0)

    await client.disconnect()
    await store.close()
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
  var finalizedCandidateID: UUID?

  init(
    store: SQLiteStore,
    client: CodexAppServerClient,
    productID: UUID,
    databaseURL: URL,
    rootURL: URL,
    runs: [AgentRun]
  ) {
    self.store = store
    self.client = client
    self.productID = productID
    self.databaseURL = databaseURL
    self.rootURL = rootURL
    self.runs = runs
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

  func deliveryReloadSelectedProductIfCurrent(productID: UUID) async {}
  func deliveryReplacePermissionRequest(_ request: AgentPermissionRequest) {}
  func deliveryReplacePermissionGrant(_ grant: AgentPermissionGrant) {}
  func deliveryScheduleSprintExecution(productID: UUID) {}

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

  func deliveryFinalizeReviewedIntegration(
    candidateID: UUID,
    implementation: TicketExecutionResult,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    finalizedCandidateID = candidateID
  }

  func deliveryFinalizeReviewedLocalOutcome(
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    finalizedCandidateID = candidate.id
  }

  func deliveryAdoptIntegratedBaselineForRevision(
    candidate: CandidateRevision,
    integratedSHA: String
  ) async throws -> TicketRevisionBaseline {
    TicketRevisionBaseline(candidateHeadSHA: candidate.headSHA, integratedSHA: integratedSHA)
  }
}
