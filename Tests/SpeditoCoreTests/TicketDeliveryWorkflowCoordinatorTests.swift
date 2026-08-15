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
    #expect(persistedItem.state == .acceptance)
    #expect(reviewRun.status == .completed)
    #expect(reviewRun.worktreePath == reviewWorkspace.path)
    #expect(comments.contains { $0.authorName == techLead.name && $0.body == "Approved the exact candidate." })
    #expect(delegate.presentedRuns.contains { $0.id == reviewRun.id && $0.status == .completed })
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

  @MainActor
  private func makeAcceptanceHarness(
    deliveryKind: CandidateDeliveryKind
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
    var workItem = try await store.createWorkItem(
      productID: product.id,
      title: deliveryKind == .localOutcome
        ? "Approve the reviewed recommendation"
        : "Approve the reviewed product change",
      type: .story,
      body: "Complete only the exact reviewed result.",
      acceptanceCriteria: ["The accepted result becomes durable exactly once."],
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
      goal: "Complete one reviewed result",
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
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    let resultData = try JSONEncoder().encode(result)
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
  ) async throws {}


  func deliveryDemoPreparationShouldCorrectCandidate(_ error: Error) -> Bool {
    error is DemoLaunchValidationError
  }
  func deliveryStopManagedSession(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    removesPreview: Bool
  ) async {}

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

}
