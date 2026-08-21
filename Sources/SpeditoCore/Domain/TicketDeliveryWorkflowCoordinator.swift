import Foundation

public enum TicketDeliveryEvidencePolicyError: Error, LocalizedError {
  case repositoryChangeRequired

  public var errorDescription: String? {
    switch self {
    case .repositoryChangeRequired:
      "Completed product-changing work must create or modify an inspectable repository artefact."
    }
  }
}

public struct TicketDeliveryEvidencePolicy {
  public static func deliveryKind(
    assigneeRole: AgentRole,
    changedPaths: [String]
  ) throws -> CandidateDeliveryKind {
    if !changedPaths.isEmpty {
      return .repositoryChange
    }
    guard assigneeRole == .businessAnalyst else {
      throw TicketDeliveryEvidencePolicyError.repositoryChangeRequired
    }
    return .localOutcome
  }
}

enum TicketDeliveryRecoveryResolutionError: Error, Equatable, LocalizedError, Sendable {
  case contradictoryRunState

  var errorDescription: String? {
    switch self {
    case .contradictoryRunState:
      "Spedito could not safely reconcile the preserved delivery work with its review candidate. No recovery changes were applied."
    }
  }
}

enum TicketDeliveryRecoveryRunConflictDisposition: Equatable, Sendable {
  case alreadyRecovered
  case failure(TicketDeliveryRecoveryResolutionError)
}

enum TicketDeliveryRecoveryRunConflictPolicy {
  private static let recoveredCandidateStatuses: Set<CandidateRevisionStatus> = [
    .queuedForReview,
    .reviewing,
    .queuedForIntegration,
    .integrating,
    .resolvingConflict,
    .readyForDemo,
    .promoting,
    .accepted,
  ]

  static func disposition(
    run: AgentRun,
    productID: UUID,
    workItemID: UUID,
    candidates: [CandidateRevision]
  ) -> TicketDeliveryRecoveryRunConflictDisposition {
    guard
      run.productID == productID,
      run.workItemID == workItemID,
      run.status == .completed,
      candidates.contains(where: { candidate in
        guard
          candidate.productID == productID,
          candidate.workItemID == workItemID,
          candidate.implementationRunID == run.id,
          recoveredCandidateStatuses.contains(candidate.status),
          let result = try? CodexTicketExecutor.decode(candidate.executionResultJSON)
        else {
          return false
        }
        return result.status == .completed
      })
    else {
      return .failure(.contradictoryRunState)
    }
    return .alreadyRecovered
  }
}

public struct TicketDeliveryWorkflowContext: Sendable {
  public let product: Product
  public let plan: SprintPlan
  public let workItems: [WorkItem]
  public let dependencies: [WorkItemDependency]
  public let profiles: [AgentProfile]
  public let runs: [AgentRun]
  public let candidates: [CandidateRevision]
  public let permissionRequests: [AgentPermissionRequest]
  public let permissionGrants: [AgentPermissionGrant]
  public let knowledgePages: [KnowledgePage]

  public init(
    product: Product,
    plan: SprintPlan,
    workItems: [WorkItem],
    dependencies: [WorkItemDependency],
    profiles: [AgentProfile],
    runs: [AgentRun],
    candidates: [CandidateRevision],
    permissionRequests: [AgentPermissionRequest],
    permissionGrants: [AgentPermissionGrant],
    knowledgePages: [KnowledgePage]
  ) {
    self.product = product
    self.plan = plan
    self.workItems = workItems
    self.dependencies = dependencies
    self.profiles = profiles
    self.runs = runs
    self.candidates = candidates
    self.permissionRequests = permissionRequests
    self.permissionGrants = permissionGrants
    self.knowledgePages = knowledgePages
  }
}

public struct TicketDeliveryRemoteIntegration: Sendable {
  public let snapshot: GitIntegrationSnapshot
  public let incorporatedChanges: Bool
  public let remoteSHA: String?

  public init(
    snapshot: GitIntegrationSnapshot,
    incorporatedChanges: Bool,
    remoteSHA: String?
  ) {
    self.snapshot = snapshot
    self.incorporatedChanges = incorporatedChanges
    self.remoteSHA = remoteSHA
  }
}

@MainActor
public protocol TicketDeliveryWorkflowDelegate: AnyObject {
  func deliveryStore(for productID: UUID) -> SQLiteStore?
  func deliveryStore(containingAgentRun runID: UUID) async -> SQLiteStore?
  var deliveryCodexClient: CodexAppServerClient? { get }
  var deliverySelectedProductID: UUID? { get }
  var deliveryIsShuttingDown: Bool { get }
  var deliveryRuns: [AgentRun] { get }
  var deliveryErrorMessage: String? { get set }
  var deliveryAgentRunKnowledgeContext: [AgentRunKnowledgePage] { get set }
  var deliveryAgentRunKnowledgeDestinations: [AgentRunKnowledgeDestination] { get set }
  func deliveryProductWorkspaceURL(productID: UUID) throws -> URL
  func deliveryTicketWorktreesRootURL(productID: UUID) throws -> URL
  func deliveryProductDatabaseURL(productID: UUID) throws -> URL
  func deliveryIntegrationWorktreesRootURL(productID: UUID) throws -> URL
  func deliveryIntegrateLatestGitHubChanges(
    candidate: CandidateRevision,
    integration: GitIntegrationSnapshot
  ) async throws -> TicketDeliveryRemoteIntegration
  var deliveryRequiresKnowledgeApproval: Bool { get }
  var deliveryDemoSessions: [DemoSession] { get }
  func deliveryRemoteRepositoryState(productID: UUID) async -> GitHubRemoteRepositoryState?
  func deliverySyncTicketPullRequestForDelivery(
    productID: UUID,
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync
  func deliveryHandleGitHubPullRequestSync(
    _ sync: GitHubTicketPullRequestSync,
    productID: UUID
  ) async
  func deliveryCheckRemoteRepositoryForDelivery(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState?
  func deliveryAcceptSafeRemoteSync(syncID: UUID, productID: UUID) async throws
  func deliveryMergeTicketPullRequest(
    publicationID: UUID,
    productID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult?
  func deliveryReturnTicketPullRequestToDraft(
    publicationID: UUID,
    productID: UUID
  ) async throws
  func deliveryPrepareTicketPullRequestIfConnected(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> RemotePublication?
  func deliveryMarkTicketPullRequestReadyIfNeeded(
    _ publication: RemotePublication?
  ) async throws
  func deliveryPrepareDemoForAcceptance(
    candidate: CandidateRevision,
    integratedSHA: String,
    specification: DemoLaunchSpecification
  ) async throws
  func deliveryDemoPreparationShouldCorrectCandidate(_ error: Error) -> Bool
  func deliveryStopManagedSession(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    removesPreview: Bool
  ) async
  func deliveryScheduleRetrospectiveSyntheses()
  func deliveryInheritedAgentInstructions(
    for product: Product,
    includesMandatoryKnowledge: Bool
  ) -> String
  func deliveryAgentRunDidUpdate(previous: AgentRun, updated: AgentRun) async
  func deliveryReloadSelectedProductIfCurrent(productID: UUID) async
  func deliveryReplacePermissionRequest(_ request: AgentPermissionRequest)
  func deliveryReplacePermissionGrant(_ grant: AgentPermissionGrant)
  func deliveryScheduleSprintExecution(productID: UUID)
  func deliveryMonitorLiveActivity(
    runID: UUID,
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String,
    initialText: String
  )
  func deliveryStopLiveActivityMonitoring(runID: UUID)
  func deliveryPresentExecutionError(_ error: Error, productID: UUID)
  func deliveryStopDemoSession(
    _ candidate: CandidateRevision,
    removesPreview: Bool
  ) async
  func deliveryStopDemoSessions(productID: UUID, includesPreparation: Bool) async
}

@MainActor
public final class TicketDeliveryWorkflowCoordinator {
  public typealias AcceptancePreparation = @MainActor (UUID, UUID) async -> Void

  private weak var delegate: (any TicketDeliveryWorkflowDelegate)?
  private let gitWorkspaceManager: GitWorkspaceManager
  private let runtimeCoordinator: TicketDeliveryRuntimeCoordinator
  private let recoveryPolicy: SprintWorkRecoveryPolicy
  private let prepareAcceptance: AcceptancePreparation

  public init(
    delegate: any TicketDeliveryWorkflowDelegate,
    gitWorkspaceManager: GitWorkspaceManager,
    runtimeCoordinator: TicketDeliveryRuntimeCoordinator,
    recoveryPolicy: SprintWorkRecoveryPolicy,
    prepareAcceptance: @escaping AcceptancePreparation = { _, _ in }
  ) {
    self.delegate = delegate
    self.gitWorkspaceManager = gitWorkspaceManager
    self.runtimeCoordinator = runtimeCoordinator
    self.recoveryPolicy = recoveryPolicy
    self.prepareAcceptance = prepareAcceptance
  }

  private func store(for productID: UUID) -> SQLiteStore? {
    delegate?.deliveryStore(for: productID)
  }

  private var codexClient: CodexAppServerClient? { delegate?.deliveryCodexClient }
  private var selectedProductID: UUID? { delegate?.deliverySelectedProductID }
  private var isShuttingDown: Bool { delegate?.deliveryIsShuttingDown ?? true }
  private var ticketDeliveryRuntimeCoordinator: TicketDeliveryRuntimeCoordinator {
    runtimeCoordinator
  }
  private var sprintWorkRecoveryPolicy: SprintWorkRecoveryPolicy { recoveryPolicy }

  private var errorMessage: String? {
    get { delegate?.deliveryErrorMessage }
    set { delegate?.deliveryErrorMessage = newValue }
  }

  private func scheduleSprintExecution(productID: UUID) {
    delegate?.deliveryScheduleSprintExecution(productID: productID)
  }

  private var agentRunKnowledgeContext: [AgentRunKnowledgePage] {
    get { delegate?.deliveryAgentRunKnowledgeContext ?? [] }
    set { delegate?.deliveryAgentRunKnowledgeContext = newValue }
  }

  private var agentRunKnowledgeDestinations: [AgentRunKnowledgeDestination] {
    get { delegate?.deliveryAgentRunKnowledgeDestinations ?? [] }
    set { delegate?.deliveryAgentRunKnowledgeDestinations = newValue }
  }

  private func productWorkspaceURL(productID: UUID) throws -> URL {
    guard let delegate else { throw CodexClientError.notConnected }
    return try delegate.deliveryProductWorkspaceURL(productID: productID)
  }

  private func ticketWorktreesRootURL(productID: UUID) throws -> URL {
    guard let delegate else { throw CodexClientError.notConnected }
    return try delegate.deliveryTicketWorktreesRootURL(productID: productID)
  }

  private func productDatabaseURL(productID: UUID) throws -> URL {
    guard let delegate else { throw CodexClientError.notConnected }
    return try delegate.deliveryProductDatabaseURL(productID: productID)
  }

  private func integrationWorktreesRootURL(productID: UUID) throws -> URL {
    guard let delegate else { throw CodexClientError.notConnected }
    return try delegate.deliveryIntegrationWorktreesRootURL(productID: productID)
  }

  private func integrateLatestGitHubChanges(
    candidate: CandidateRevision,
    integration: GitIntegrationSnapshot
  ) async throws -> TicketDeliveryRemoteIntegration {
    guard let delegate else { throw CodexClientError.notConnected }
    return try await delegate.deliveryIntegrateLatestGitHubChanges(
      candidate: candidate,
      integration: integration
    )
  }

  private var requiresKnowledgeApproval: Bool {
    delegate?.deliveryRequiresKnowledgeApproval ?? false
  }

  private var demoSessions: [DemoSession] {
    delegate?.deliveryDemoSessions ?? []
  }

  private func remoteRepositoryState(
    productID: UUID
  ) async -> GitHubRemoteRepositoryState? {
    await delegate?.deliveryRemoteRepositoryState(productID: productID)
  }

  private func syncTicketPullRequestForDelivery(
    productID: UUID,
    publicationID: UUID
  ) async throws -> GitHubTicketPullRequestSync {
    guard let delegate else { throw CodexClientError.notConnected }
    return try await delegate.deliverySyncTicketPullRequestForDelivery(
      productID: productID,
      publicationID: publicationID
    )
  }

  private func handleGitHubPullRequestSync(
    _ sync: GitHubTicketPullRequestSync,
    productID: UUID
  ) async {
    await delegate?.deliveryHandleGitHubPullRequestSync(sync, productID: productID)
  }

  private func checkRemoteRepositoryForDelivery(
    productID: UUID
  ) async throws -> GitHubRemoteRepositoryState? {
    guard let delegate else { throw CodexClientError.notConnected }
    return try await delegate.deliveryCheckRemoteRepositoryForDelivery(productID: productID)
  }

  private func acceptSafeRemoteSync(syncID: UUID, productID: UUID) async throws {
    guard let delegate else { throw CodexClientError.notConnected }
    try await delegate.deliveryAcceptSafeRemoteSync(syncID: syncID, productID: productID)
  }

  private func mergeTicketPullRequest(
    publicationID: UUID,
    productID: UUID
  ) async throws -> GitHubTicketPullRequestMergeResult? {
    guard let delegate else { throw CodexClientError.notConnected }
    return try await delegate.deliveryMergeTicketPullRequest(
      publicationID: publicationID,
      productID: productID
    )
  }

  private func returnTicketPullRequestToDraft(
    publicationID: UUID,
    productID: UUID
  ) async throws {
    guard let delegate else { throw CodexClientError.notConnected }
    try await delegate.deliveryReturnTicketPullRequestToDraft(
      publicationID: publicationID,
      productID: productID
    )
  }

  private func prepareTicketPullRequestIfConnected(
    productID: UUID,
    workItemID: UUID,
    candidateRevisionID: UUID
  ) async throws -> RemotePublication? {
    guard let delegate else { throw CodexClientError.notConnected }
    return try await delegate.deliveryPrepareTicketPullRequestIfConnected(
      productID: productID,
      workItemID: workItemID,
      candidateRevisionID: candidateRevisionID
    )
  }

  private func markTicketPullRequestReadyIfNeeded(
    _ publication: RemotePublication?
  ) async throws {
    guard let delegate else { throw CodexClientError.notConnected }
    try await delegate.deliveryMarkTicketPullRequestReadyIfNeeded(publication)
  }

  private func prepareDemoForAcceptance(
    candidate: CandidateRevision,
    integratedSHA: String,
    specification: DemoLaunchSpecification
  ) async throws {
    guard let delegate else { throw CodexClientError.notConnected }
    try await delegate.deliveryPrepareDemoForAcceptance(
      candidate: candidate,
      integratedSHA: integratedSHA,
      specification: specification
    )
  }

  private func demoPreparationShouldCorrectCandidate(_ error: Error) -> Bool {
    delegate?.deliveryDemoPreparationShouldCorrectCandidate(error) ?? false
  }

  private func stopManagedSession(
    productID: UUID,
    sourceKind: DemoSessionSourceKind,
    launchID: UUID,
    removesPreview: Bool
  ) async {
    await delegate?.deliveryStopManagedSession(
      productID: productID,
      sourceKind: sourceKind,
      launchID: launchID,
      removesPreview: removesPreview
    )
  }

  private func scheduleRetrospectiveSyntheses() {
    delegate?.deliveryScheduleRetrospectiveSyntheses()
  }

  private func inheritedAgentInstructions(
    for product: Product,
    includesMandatoryKnowledge: Bool = true
  ) -> String {
    delegate?.deliveryInheritedAgentInstructions(
      for: product,
      includesMandatoryKnowledge: includesMandatoryKnowledge
    ) ?? ""
  }

  private func reloadSelectedProductIfCurrent(productID: UUID) async {
    await delegate?.deliveryReloadSelectedProductIfCurrent(productID: productID)
  }

  private func monitorLiveActivity(
    runID: UUID,
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String,
    initialText: String
  ) {
    delegate?.deliveryMonitorLiveActivity(
      runID: runID,
      productID: productID,
      client: client,
      threadID: threadID,
      turnID: turnID,
      initialText: initialText
    )
  }

  private func stopLiveActivityMonitoring(runID: UUID) {
    delegate?.deliveryStopLiveActivityMonitoring(runID: runID)
  }

  private func presentExecutionError(_ error: Error, productID: UUID) {
    delegate?.deliveryPresentExecutionError(error, productID: productID)
  }

  private func stopDemoSession(
    _ candidate: CandidateRevision,
    removesPreview: Bool
  ) async {
    await delegate?.deliveryStopDemoSession(candidate, removesPreview: removesPreview)
  }

  /// A review failure may land long after the candidate moved on, so the teardown reads
  /// the current row first. Only a candidate still awaiting this review belongs to the
  /// failure; one that already reached a demo, promotion, or acceptance was advanced by
  /// another task and must keep its state, worktree, and knowledge proposals.
  private func candidateAwaitingReviewOutcome(
    id: UUID,
    productID: UUID
  ) async -> CandidateRevision? {
    guard
      let store = store(for: productID),
      let current = try? await store.fetchCandidateRevision(id: id)
    else { return nil }
    switch current.status {
    case .queuedForReview, .reviewing, .queuedForIntegration, .integrating, .resolvingConflict:
      return current
    case .changesRequested, .readyForDemo, .promoting, .accepted, .superseded, .failed:
      return nil
    }
  }


  @discardableResult
  public func updateAgentRun(
    id: UUID,
    status: AgentRunStatus,
    codexThreadID: String? = nil,
    worktreePath: String? = nil,
    eventActor: String? = nil,
    eventDetail: String? = nil
  ) async throws -> AgentRun {
    guard let runStore = await delegate?.deliveryStore(containingAgentRun: id) else {
      throw PersistenceError.recordNotFound("Spedito database")
    }
    let previousRun = try await runStore.fetchAgentRun(id: id)
    let updatedRun = try await runStore.updateAgentRun(
      id: id,
      status: status,
      codexThreadID: codexThreadID,
      worktreePath: worktreePath,
      eventActor: eventActor,
      eventDetail: eventDetail
    )
    await delegate?.deliveryAgentRunDidUpdate(previous: previousRun, updated: updatedRun)
    return updatedRun
  }

  public func context(productID: UUID) async -> TicketDeliveryWorkflowContext? {
    guard let store = store(for: productID) else { return nil }
    do {
      guard
        let snapshot = try await store.fetchSprintExecutionSnapshot(productID: productID)
      else { return nil }
      guard !snapshot.profiles.isEmpty else {
        throw PersistenceError.corruptData(
          "The active product has no configured team profiles."
        )
      }
      return TicketDeliveryWorkflowContext(
        product: snapshot.product,
        plan: snapshot.plan,
        workItems: snapshot.workItems,
        dependencies: snapshot.dependencies,
        profiles: snapshot.profiles,
        runs: snapshot.runs,
        candidates: snapshot.candidates,
        permissionRequests: snapshot.permissionRequests,
        permissionGrants: snapshot.permissionGrants,
        knowledgePages: snapshot.knowledgePages
      )
    } catch {
      presentExecutionError(error, productID: productID)
      return nil
    }
  }

  public func executeImplementationRun(
    _ queuedRun: AgentRun,
    context: TicketDeliveryWorkflowContext
  ) async {
    guard
      let store = store(for: context.product.id),
      let client = codexClient,
      let item = context.workItems.first(where: { $0.id == queuedRun.workItemID }),
      let assignee = context.profiles.first(where: { $0.id == queuedRun.profileID })
    else { return }
    let product = context.product
    let plan = context.plan
    let workItems = context.workItems
    let dependencies = context.dependencies
    let knowledgePages = context.knowledgePages
    let permissionRequests = context.permissionRequests

    var run = queuedRun
    do {
      let productWorkspace = try productWorkspaceURL(productID: product.id)
      var recoveredExistingWorkspace = false
      let workspace: URL
      if let storedPath = run.worktreePath,
        storedPath != productWorkspace.path,
        FileManager.default.fileExists(atPath: storedPath)
      {
        workspace = URL(fileURLWithPath: storedPath, isDirectory: true)
        recoveredExistingWorkspace = true
      } else {
        if run.codexThreadID != nil || run.worktreePath != nil {
          run = try await store.resetAgentRunExecutionContext(id: run.id)
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body:
              "The previous ticket workspace was unavailable. Spedito prepared a fresh isolated \(item.key) workspace, so work that was not captured in a durable candidate could not be recovered."
          )
        }
        let prepared = try await gitWorkspaceManager.prepareTicketWorkspace(
          repositoryURL: productWorkspace,
          worktreesRootURL: try ticketWorktreesRootURL(productID: product.id),
          ticketKey: item.key,
          runID: run.id,
          authorName: assignee.name
        )
        workspace = prepared.url
      }
      let isContinuation =
        recoveredExistingWorkspace
        && (item.state == .running || run.codexThreadID != nil || run.worktreePath != nil)
      try await gitWorkspaceManager.configureAgentIdentity(
        at: workspace,
        authorName: assignee.name
      )
      let currentCandidates = try await store.fetchCandidateRevisions(
        productID: product.id
      )
      let latestCandidate =
        currentCandidates
        .filter { $0.workItemID == item.id }
        .max(by: { $0.version < $1.version })
      let adoptedBaseline: TicketRevisionBaseline? =
        if let latestCandidate,
          let integratedSHA = latestCandidate.integratedSHA,
          (try? await gitWorkspaceManager.currentSHA(at: workspace)) == integratedSHA
        {
          TicketRevisionBaseline(
            candidateHeadSHA: latestCandidate.headSHA,
            integratedSHA: integratedSHA
          )
        } else {
          nil
        }

      if item.state == .queued {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: assignee.name,
          reason: "Picked up the authorised ticket"
        )
      }

      let developerInstructions = CodexTicketExecutor.developerInstructions(
        productInstructions: inheritedAgentInstructions(
          for: product,
          includesMandatoryKnowledge: false
        ),
        customInstructions: assignee.customInstructionText,
        assignee: assignee,
        savedPermissionGrants: context.permissionGrants
      )
      let existingThreadID = run.codexThreadID
      var replacedUnavailableThread = false
      let threadID: String
      if let existingThreadID {
        do {
          threadID = try await client.resumeWorkspaceThread(
            threadID: existingThreadID,
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: assignee.model,
            readOnlyGitDirectory: productWorkspace.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          threadID = try await client.startWorkspaceThread(
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: assignee.model,
            readOnlyGitDirectory: productWorkspace.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
          replacedUnavailableThread = true
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body:
              "The previous conversation could not be recovered. I started a replacement in the preserved ticket workspace and continued the work."
          )
        }
      } else {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: assignee.model,
          readOnlyGitDirectory: productWorkspace.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        )
      }
      run = try await updateAgentRun(
        id: run.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path,
        eventActor: replacedUnavailableThread ? "Spedito" : nil,
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable conversation and preserved the ticket workspace"
          : nil
      )
      await reloadSelectedProductIfCurrent(productID: product.id)

      let currentItem = workItems.first(where: { $0.id == item.id }) ?? item
      let prerequisiteIDs = Set(
        dependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
      )
      let prerequisites = workItems.filter { prerequisiteIDs.contains($0.id) }
      let dependantIDs = Set(
        dependencies.filter { $0.dependsOnWorkItemID == item.id }.map(\.workItemID)
      )
      let dependants = workItems.filter {
        dependantIDs.contains($0.id) && $0.state != .cancelled
      }
      var prerequisiteComments: [UUID: [TicketComment]] = [:]
      for prerequisite in prerequisites {
        prerequisiteComments[prerequisite.id] = try await store.fetchComments(
          workItemID: prerequisite.id
        )
      }
      let comments = try await store.fetchComments(workItemID: item.id)
      let knowledgeSelection = KnowledgeContextSelector.select(
        pages: knowledgePages,
        item: currentItem,
        prerequisites: prerequisites
      )
      let knowledgeContext = knowledgeSelection.referencePages
      try await recordKnowledgeContext(
        runID: run.id,
        productID: product.id,
        pages: knowledgeContext
      )
      try await store.setAgentRunKnowledgeDestinations(
        runID: run.id,
        pageIDs: Array(knowledgeSelection.writablePageIDs)
      )
      agentRunKnowledgeDestinations.removeAll { $0.runID == run.id }
      agentRunKnowledgeDestinations.append(
        contentsOf: knowledgeSelection.writablePageIDs.map {
          AgentRunKnowledgeDestination(runID: run.id, pageID: $0)
        }
      )
      let interruptedPermission = sprintWorkRecoveryPolicy.latestPermissionContinuation(
        for: run.id,
        permissionRequests: permissionRequests
      )
      let continuationPrompt = CodexTicketExecutor.recoveryPrompt(
        item: currentItem,
        interruptedPermission: interruptedPermission,
        recentComments: comments,
        adoptedBaseline: adoptedBaseline
      )
      let replacementContinuationPrompt = CodexTicketExecutor.recoveryPrompt(
        item: currentItem,
        interruptedPermission: interruptedPermission,
        recentComments: [],
        conversationIsAvailable: false,
        adoptedBaseline: adoptedBaseline
      )
      let executionPrompt = CodexTicketExecutor.prompt(
        product: product,
        item: currentItem,
        assignee: assignee,
        prerequisites: prerequisites,
        dependants: dependants,
        prerequisiteComments: prerequisiteComments,
        ticketComments: comments,
        knowledgeContext: knowledgeContext,
        knowledgeDirectory: knowledgeSelection.directoryPages,
        knowledgeDestinationIDs: knowledgeSelection.writablePageIDs,
        existingItems: workItems,
        continuationMessage: isContinuation
          ? replacementContinuationPrompt
          : nil
      )
      var activeThreadID = threadID
      var turnPrompt =
        existingThreadID != nil && !replacedUnavailableThread
        ? continuationPrompt
        : executionPrompt
      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: activeThreadID,
          prompt: turnPrompt,
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [
            workspace,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        activeThreadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: assignee.model,
          readOnlyGitDirectory: productWorkspace.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        )
        run = try await updateAgentRun(
          id: run.id,
          status: .running,
          codexThreadID: activeThreadID,
          worktreePath: workspace.path,
          eventActor: "Spedito",
          eventDetail: "Replaced a stale Codex thread and preserved the ticket workspace"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The previous Codex session was no longer available. I started a replacement session in the preserved ticket workspace and continued the work."
        )
        turnPrompt = executionPrompt
        turnID = try await client.startStructuredTurn(
          threadID: activeThreadID,
          prompt: turnPrompt,
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [
            workspace,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      }
      ticketDeliveryRuntimeCoordinator.registerActiveTurn(
        runID: run.id,
        productID: product.id,
        threadID: activeThreadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: run.id,
        productID: product.id,
        client: client,
        threadID: activeThreadID,
        turnID: turnID,
        initialText: isContinuation
          ? "Continuing work in the ticket workspace…"
          : "Getting oriented in the ticket workspace…"
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: activeThreadID,
        turnID: turnID,
        timeout: .seconds(900)
      )
      stopLiveActivityMonitoring(runID: run.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: run.id)
      let validated = try await validatedExecutionResult(
        response,
        client: client,
        threadID: activeThreadID,
        runID: run.id,
        productID: product.id,
        assignee: assignee,
        workspaceURL: workspace,
        canonicalKnowledgePages: knowledgeSelection.directoryPages
      )
      await processExecutionResult(
        validated.result,
        deliveryKind: validated.deliveryKind,
        implementationRunID: run.id,
        reviewCycle: 0,
        plan: plan
      )
    } catch {
      if let activeExecutionTurn =
        ticketDeliveryRuntimeCoordinator.activeTurn(runID: run.id)
      {
        try? await client.interruptTurn(
          threadID: activeExecutionTurn.threadID,
          turnID: activeExecutionTurn.turnID
        )
      }
      stopLiveActivityMonitoring(runID: run.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: run.id)
      let wasManuallyStopped =
        ticketDeliveryRuntimeCoordinator.consumeManuallyStopped(runID: run.id)
      let currentPermissionRequests =
        (try? await store.fetchAgentPermissionRequests(productID: product.id))
        ?? permissionRequests
      let wasAwaitingPermission =
        currentPermissionRequests
        .filter { $0.agentRunID == run.id }
        .max(by: { $0.updatedAt < $1.updatedAt })?
        .status.needsOwnerDecision == true
      let sprintCancellationIntent =
        ticketDeliveryRuntimeCoordinator.sprintCancellationIntent(productID: product.id)
      let wasPausedBySprint =
        Task.isCancelled && sprintCancellationIntent == .pause
      let wasStoppedBySprint =
        Task.isCancelled && sprintCancellationIntent == .stop
      let status: AgentRunStatus =
        if wasStoppedBySprint {
          .cancelled
        } else {
          sprintWorkRecoveryPolicy.implementationRunStatusAfterTurnStops(
            taskWasCancelled: Task.isCancelled,
            wasManuallyStopped: wasManuallyStopped,
            wasAwaitingPermission: wasAwaitingPermission
          )
        }
      let wasSuspendedByApp =
        Task.isCancelled && !wasManuallyStopped && !wasPausedBySprint
        && !wasStoppedBySprint
      let wasSuspendedAtPermission = wasSuspendedByApp && wasAwaitingPermission
      let eventDetail: String
      let workLogBody: String
      if wasStoppedBySprint {
        eventDetail = "Sprint stopped; ticket workspace preserved"
        workLogBody =
          "The product owner stopped this sprint. This run will not continue automatically. Its conversation and ticket workspace are preserved for audit, and the ticket will return to ready for replanning."
      } else if wasPausedBySprint && wasAwaitingPermission {
        eventDetail = "Sprint paused; permission request remains paused for product owner input"
        workLogBody =
          "The product owner paused this sprint while this run was waiting for a permission decision. Its conversation and ticket workspace are preserved. The decision remains available, but work will not continue until the sprint resumes."
      } else if wasPausedBySprint {
        eventDetail = "Sprint paused; preserved work queued to continue"
        workLogBody =
          "The product owner paused this sprint. This run's conversation and ticket workspace are preserved, and work is queued to continue when the sprint resumes."
      } else if wasSuspendedAtPermission {
        eventDetail = "App stopped; permission request remains paused for product owner input"
        workLogBody =
          "Spedito stopped while this run was waiting for a permission decision. Its conversation and ticket workspace are preserved, and work will remain paused after relaunch until the product owner chooses Allow or Deny."
      } else if wasSuspendedByApp {
        eventDetail = "App stopped; preserved work queued to continue"
        workLogBody =
          "Spedito paused this run while stopping. Its conversation and ticket workspace are preserved, and it is queued to continue automatically."
      } else if wasManuallyStopped {
        eventDetail = "Stopped manually; ticket workspace preserved"
        workLogBody =
          "This run was stopped by the product owner. Its ticket workspace has been preserved and can be resumed with a new comment."
      } else {
        eventDetail = error.localizedDescription
        workLogBody = "The agent run stopped unexpectedly: \(error.localizedDescription)"
      }
      _ = try? await updateAgentRun(
        id: run.id,
        status: status,
        eventActor: "Spedito",
        eventDetail: eventDetail
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body: workLogBody
      )
      if !Task.isCancelled && !wasManuallyStopped {
        presentExecutionError(error, productID: product.id)
      }
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }

  public func validatedExecutionResult(
    _ response: String,
    client: CodexAppServerClient,
    threadID: String,
    runID: UUID,
    productID: UUID,
    assignee: AgentProfile,
    workspaceURL: URL,
    canonicalKnowledgePages: [KnowledgePage]
  ) async throws -> (result: TicketExecutionResult, deliveryKind: CandidateDeliveryKind) {
    guard let validationStore = store(for: productID) else {
      throw PersistenceError.recordNotFound("knowledge destinations for agent run \(runID)")
    }
    let writableKnowledgePageIDs = Set(
      try await validationStore.fetchAgentRunKnowledgeDestinations(productID: productID)
        .lazy
        .filter { $0.runID == runID }
        .map(\.pageID)
    )
    let maximumRepairAttempts = 2
    var responseToValidate = response

    for repairAttempt in 0...maximumRepairAttempts {
      do {
        let result = try CodexTicketExecutor.decode(responseToValidate)
        try CodexTicketExecutor.validateKnowledgePageProposals(
          in: result,
          canonicalPages: canonicalKnowledgePages,
          writablePageIDs: writableKnowledgePageIDs
        )
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: result,
          assignee: assignee
        )
        let deliveryKind = try await validateDeliveryEvidence(
          result,
          assignee: assignee,
          workspaceURL: workspaceURL
        )
        return (result, deliveryKind)
      } catch let validationError as TicketExecutionGenerationError {
        guard repairAttempt < maximumRepairAttempts else {
          throw validationError
        }
        let repairTurnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexTicketExecutor.repairPrompt(
            validationError: validationError.localizedDescription
          ),
          effort: assignee.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [
            workspaceURL,
            try productDatabaseURL(productID: productID).deletingLastPathComponent(),
          ]
        )
        ticketDeliveryRuntimeCoordinator.registerActiveTurn(
          runID: runID,
          productID: productID,
          threadID: threadID,
          turnID: repairTurnID
        )
        monitorLiveActivity(
          runID: runID,
          productID: productID,
          client: client,
          threadID: threadID,
          turnID: repairTurnID,
          initialText:
            "Correcting the delivery result (\(repairAttempt + 1) of \(maximumRepairAttempts))…"
        )
        do {
          responseToValidate = try await client.waitForFinalAgentMessage(
            threadID: threadID,
            turnID: repairTurnID,
            timeout: .seconds(900)
          )
          stopLiveActivityMonitoring(runID: runID)
          ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: runID)
        } catch {
          stopLiveActivityMonitoring(runID: runID)
          ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: runID)
          throw error
        }
      }
    }

    preconditionFailure("The bounded delivery-result repair loop did not settle.")
  }

  public func validateDeliveryEvidence(
    _ result: TicketExecutionResult,
    assignee: AgentProfile,
    workspaceURL: URL
  ) async throws -> CandidateDeliveryKind {
    let actualChangePaths: [String]
    if result.status == .completed || result.decisionArtifact != nil {
      actualChangePaths = try await gitWorkspaceManager.ticketChangePaths(
        ticketWorkspaceURL: workspaceURL
      )
    } else {
      actualChangePaths = []
    }
    if let decisionArtifact = result.decisionArtifact {
      _ = try TicketDecisionArtifactValidator.resolveExistingFile(
        decisionArtifact,
        in: workspaceURL
      )
      guard actualChangePaths.contains(decisionArtifact.path) else {
        throw TicketExecutionGenerationError.invalidResponse(
          "decisionArtifact must reference a file created or changed by this ticket."
        )
      }
    }
    guard result.status == .completed else { return .repositoryChange }
    let reportedChangePaths = Set(
      result.changedFiles.map {
        $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0
      }
    )
    guard reportedChangePaths.isSubset(of: Set(actualChangePaths)) else {
      let missing = reportedChangePaths.subtracting(actualChangePaths).sorted()
      throw TicketExecutionGenerationError.invalidResponse(
        "Reported changed files were not present in the ticket workspace: \(missing.joined(separator: ", "))."
      )
    }
    let deliveryKind: CandidateDeliveryKind
    do {
      deliveryKind = try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: assignee.role,
        changedPaths: actualChangePaths
      )
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(error.localizedDescription)
    }
    if deliveryKind == .localOutcome {
      guard result.demo == nil else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Repository-free research uses its in-app outcome review and must not supply a managed demo."
        )
      }
      return deliveryKind
    }
    guard let demo = result.demo else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Repository-changing work needs a managed demo recipe for the product owner."
      )
    }
    do {
      try DemoLaunchSpecificationValidator.validate(demo)
      let commands = demo.preparationCommands + [demo.launchCommand].compactMap { $0 }
      for command in commands {
        let directory = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
          command.workingDirectory,
          in: workspaceURL
        )
        var isDirectory: ObjCBool = false
        guard
          FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue
        else {
          throw DemoLaunchValidationError.invalid(
            "the working directory “\(command.workingDirectory)” does not exist."
          )
        }
      }
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(error.localizedDescription)
    }
    guard !reportedChangePaths.isDisjoint(with: Set(actualChangePaths)) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "The reported changed files do not identify an inspectable ticket artefact."
      )
    }
    return deliveryKind
  }

  public func processExecutionResult(
    _ result: TicketExecutionResult,
    deliveryKind: CandidateDeliveryKind,
    implementationRunID: UUID,
    reviewCycle: Int,
    plan: SprintPlan
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
      let context = await context(productID: plan.sprint.productID),
      let run = try? await store.fetchAgentRun(id: implementationRunID),
      let item = context.workItems.first(where: { $0.id == run.workItemID }),
      let assignee = context.profiles.first(where: { $0.id == run.profileID })
    else { return }
    let productID = context.product.id

    if result.status == .awaitingOwner {
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: assignee.name,
        body: result.workLogComment,
        ownerQuestion: result.question.map {
          TicketOwnerQuestion(
            prompt: $0,
            options: result.options,
            decisionArtifact: result.decisionArtifact
          )
        }
      )
    }

    switch result.status {
    case .awaitingOwner:
      _ = try? await updateAgentRun(
        id: run.id,
        status: .awaitingOwner,
        eventActor: assignee.name,
        eventDetail: "Waiting for product owner input"
      )
      await reloadSelectedProductIfCurrent(productID: productID)
    case .completed:
      do {
        guard let worktreePath = run.worktreePath else {
          throw GitWorkspaceError.invalidRepository("The agent run has no ticket workspace.")
        }
        let settlement = try await store.prepareCompletedDeliverySettlement(runID: run.id)
        if settlement.existingCandidate != nil {
          await reloadSelectedProductIfCurrent(productID: productID)
          return
        }

        let deliveryNote = deliveryNoteMarkdown(
          item: item,
          result: result,
          authorName: assignee.name
        )
        let workspaceURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let snapshot =
          if deliveryKind.changesRepository {
            try await gitWorkspaceManager.createCandidate(
              ticketWorkspaceURL: workspaceURL,
              ticketKey: item.key,
              version: settlement.candidateVersion,
              authorName: assignee.name,
              summary: result.summary,
              settlementOperationID: settlement.operationID
            )
          } else {
            try await gitWorkspaceManager.snapshotLocalOutcomeCandidate(
              ticketWorkspaceURL: workspaceURL
            )
          }
        let resultData = try JSONEncoder().encode(result)
        guard let resultJSON = String(data: resultData, encoding: .utf8) else {
          throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let sprintItemID =
          run.sprintItemID
          ?? plan.items.first(where: { $0.workItemID == item.id })?.id
        guard let sprintItemID else {
          throw PersistenceError.corruptData("Candidate revision has no sprint item.")
        }
        let candidate = CandidateRevision(
          productID: item.productID,
          sprintID: plan.sprint.id,
          sprintItemID: sprintItemID,
          workItemID: item.id,
          implementationRunID: run.id,
          version: settlement.candidateVersion,
          deliveryKind: deliveryKind,
          branchName: snapshot.branchName,
          baseSHA: snapshot.baseSHA,
          headSHA: snapshot.headSHA,
          worktreePath: worktreePath,
          commitCount: snapshot.commitCount,
          executionResultJSON: resultJSON
        )
        let proposals = try await makeKnowledgePageProposals(
          drafts: result.knowledgePageProposals,
          candidate: candidate,
          runID: run.id
        )
        let eventDetail =
          deliveryKind.changesRepository
          ? "Candidate v\(candidate.version) queued for integration"
          : "Outcome v\(candidate.version) queued for review"
        let completed = try await store.settleCompletedDelivery(
          candidate: candidate,
          operationID: settlement.operationID,
          comment: TicketComment(
            workItemID: item.id,
            authorKind: .agent,
            authorName: assignee.name,
            body: result.workLogComment
          ),
          deliveryNoteMarkdown: deliveryNote,
          sprint: plan.sprint,
          knowledgePageProposals: proposals,
          retrospectiveNotes: makeRetrospectiveNotes(
            productID: item.productID,
            sprintID: plan.sprint.id,
            workItemID: item.id,
            profile: assignee,
            wentWell: result.retrospectiveWentWell,
            couldImprove: result.retrospectiveCouldImprove,
            actions: result.retrospectiveActions
          ),
          eventActor: assignee.name,
          eventDetail: eventDetail
        )
        await delegate?.deliveryAgentRunDidUpdate(previous: run, updated: completed.run)
        await reloadSelectedProductIfCurrent(productID: productID)
      } catch {
        _ = try? await updateAgentRun(
          id: run.id,
          status: .awaitingOwner,
          eventActor: "Spedito",
          eventDetail: "Could not create an immutable candidate revision"
        )
        _ = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The work is preserved, but Spedito could not prepare it for review: \(error.localizedDescription)"
        )
        presentExecutionError(error, productID: productID)
        await reloadSelectedProductIfCurrent(productID: productID)
      }
    }
  }

  private func makeRetrospectiveNotes(
    productID: UUID,
    sprintID: UUID,
    workItemID: UUID,
    profile: AgentProfile,
    wentWell: [String],
    couldImprove: [String],
    actions: [RetrospectiveActionProposal]
  ) -> [RetrospectiveNote] {
    let observations: [(RetrospectiveNoteCategory, [String])] = [
      (.wentWell, wentWell),
      (.couldImprove, couldImprove),
    ]
    let evidence = observations.flatMap { category, values in
      values.prefix(2).map { body in
        RetrospectiveNote(
          productID: productID,
          sprintID: sprintID,
          workItemID: workItemID,
          profileID: profile.id,
          authorName: profile.name,
          category: category,
          body: body
        )
      }
    }
    let proposedActions = actions.prefix(2).map { action in
      RetrospectiveNote(
        productID: productID,
        sprintID: sprintID,
        workItemID: workItemID,
        profileID: profile.id,
        authorName: profile.name,
        category: .suggestedAction,
        body: action.body,
        isActionCandidate: true,
        actionDestination: action.destination
      )
    }
    return evidence + proposedActions
  }

  private func recordKnowledgeContext(
    runID: UUID,
    productID: UUID,
    pages: [KnowledgePage]
  ) async throws {
    guard let store = store(for: productID) else {
      throw CodexClientError.notConnected
    }
    try await store.setAgentRunKnowledgeContext(
      runID: runID,
      pageIDs: pages.map(\.id)
    )
    guard selectedProductID == productID else { return }
    agentRunKnowledgeContext.removeAll { $0.runID == runID }
    agentRunKnowledgeContext.append(
      contentsOf: pages.map {
        AgentRunKnowledgePage(runID: runID, pageID: $0.id)
      }
    )
  }

  private func deliveryNoteMarkdown(
    item: WorkItem,
    result: TicketExecutionResult,
    authorName: String
  ) -> String {
    let checks =
      result.tests.isEmpty
      ? "- No automated checks were reported."
      : result.tests.map { "- \($0)" }.joined(separator: "\n")
    let review = result.reviewInstructions.map { "- \($0)" }.joined(separator: "\n")
    let knowledge =
      result.knowledgeNotes.isEmpty
      ? "- No durable decision or limitation was reported."
      : result.knowledgeNotes.map { "- \($0)" }.joined(separator: "\n")
    let files =
      result.changedFiles.isEmpty
      ? "- No changed file was reported."
      : result.changedFiles.map { "- `\($0)`" }.joined(separator: "\n")
    let demo =
      result.demo.map {
        "- **\($0.title)** — \($0.presentation.kind.title)"
      } ?? "- No managed demo recipe was recorded."
    let followUps =
      result.followUpTicketProposals.isEmpty
      ? "- No follow-up tickets were recommended."
      : result.followUpTicketProposals.map {
        "- **\($0.reference): \($0.title)** — \($0.rationale)"
      }.joined(separator: "\n")
    return """
      # \(item.key) · \(item.title)

      **Delivery evidence:** Prepared with the candidate revision<br>
      **Prepared by:** \(authorName)

      ## What changed
      \(result.summary.isEmpty ? result.comment : result.summary)

      ## How it works and why
      \(knowledge)

      ## Changed files
      \(files)

      ## Checks performed
      \(checks)

      ## How the product owner can review it
      \(review)

      ## One-click demo
      \(demo)

      ## Recommended follow-up work
      \(followUps)

      ## Known limitations
      \(result.knowledgeNotes.isEmpty ? "- None recorded." : knowledge)
      """
  }

  private func makeKnowledgePageProposals(
    drafts: [KnowledgePageProposalDraft],
    candidate: CandidateRevision,
    runID: UUID
  ) async throws -> [KnowledgePageProposal] {
    guard let store = store(for: candidate.productID) else {
      throw PersistenceError.recordNotFound("knowledge context for agent run \(runID)")
    }
    let productDestinations = try await store.fetchAgentRunKnowledgeDestinations(
      productID: candidate.productID
    )
    let productKnowledgePages = try await store.fetchKnowledgePages(
      productID: candidate.productID
    )
    let destinationPageIDs = Set(
      productDestinations
        .filter { $0.runID == runID }
        .map(\.pageID)
    )
    let pagesByID = Dictionary(
      uniqueKeysWithValues: productKnowledgePages.map { ($0.id, $0) }
    )
    return try drafts.map { draft in
      let basePage = draft.targetPageID.flatMap { pagesByID[$0] }
      switch draft.operation {
      case .update:
        guard
          let targetPageID = draft.targetPageID,
          destinationPageIDs.contains(targetPageID),
          let page = pagesByID[targetPageID],
          page.productID == candidate.productID,
          page.kind == .page
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page update referenced a page that was not writable for this run."
          )
        }
      case .create:
        guard
          let parentPageID = draft.parentPageID,
          destinationPageIDs.contains(parentPageID),
          let parent = pagesByID[parentPageID],
          parent.productID == candidate.productID,
          parent.kind == .section
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page creation referenced a section that was not writable for this run."
          )
        }
      }
      return KnowledgePageProposal(
        productID: candidate.productID,
        sprintID: candidate.sprintID,
        workItemID: candidate.workItemID,
        candidateRevisionID: candidate.id,
        operation: draft.operation,
        targetPageID: draft.targetPageID,
        parentPageID: draft.parentPageID,
        basePageTitle: basePage?.title,
        basePageBodyMarkdown: basePage?.bodyMarkdown,
        basePageUpdatedAt: basePage?.updatedAt,
        title: draft.title,
        proposedBodyMarkdown: draft.proposedBodyMarkdown,
        rationale: draft.rationale
      )
    }
  }
  public func resumeTechLeadReview(
    candidate: CandidateRevision,
    reviewRun: AgentRun,
    plan: SprintPlan
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
      let client = codexClient,
      let context =
        await context(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let implementationRun = try? await store.fetchAgentRun(
        id: candidate.implementationRunID
      ),
      let implementer = context.profiles.first(
        where: { $0.id == implementationRun.profileID }
      ),
      let techLead = context.profiles.first(where: { $0.id == reviewRun.profileID })
    else {
      return
    }
    let product = context.product
    let permissionRequests = context.permissionRequests

    let reviewCycle = max(0, candidate.version - 1)
    do {
      try await recordKnowledgeContext(
        runID: reviewRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      let repositoryURL = try productWorkspaceURL(productID: product.id)
      let integration: GitIntegrationSnapshot?
      let reviewWorkspace: GitIntegrationSnapshot
      if let integratedSHA = candidate.integratedSHA {
        let prepared = try await gitWorkspaceManager.prepareIntegratedWorkspace(
          repositoryURL: repositoryURL,
          integrationsRootURL: integrationWorktreesRootURL(productID: product.id),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA,
          integratedSHA: integratedSHA
        )
        integration = prepared
        reviewWorkspace = prepared
      } else {
        integration = nil
        reviewWorkspace = try await gitWorkspaceManager.prepareCandidateReviewWorkspace(
          repositoryURL: repositoryURL,
          reviewsRootURL: integrationWorktreesRootURL(productID: product.id),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA
        )
      }
      let implementation = try CodexTicketExecutor.decode(candidate.executionResultJSON)
      let candidateKnowledgePageProposals = try await store.fetchKnowledgePageProposals(
        productID: product.id
      ).filter { proposal in
        proposal.candidateRevisionID == candidate.id
      }
      let developerInstructions = CodexTechLeadReviewer.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product),
        customInstructions: techLead.customInstructionText,
        reviewer: techLead
      )
      var resumedReviewThreadID: String?
      var replacedUnavailableThread = false
      if let existingThreadID = reviewRun.codexThreadID {
        do {
          let resumedThreadID = try await client.resumeReadOnlyThread(
            threadID: existingThreadID,
            workingDirectory: reviewWorkspace.url,
            developerInstructions: developerInstructions,
            model: techLead.model,
            allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
            readOnlyProductDirectory: try productDatabaseURL(productID: product.id).deletingLastPathComponent()
          )
          resumedReviewThreadID = resumedThreadID
          if let recoveredResponse = try? await client.latestCompletedAgentMessage(
            threadID: resumedThreadID,
            notBefore: reviewRun.createdAt.addingTimeInterval(-30)
          ),
            let recoveredReview = try? CodexTechLeadReviewer.decode(recoveredResponse)
          {
            try await applyTechLeadReviewResult(
              recoveredReview,
              implementation: implementation,
              candidate: candidate,
              implementationRun: implementationRun,
              reviewRun: reviewRun,
              reviewCycle: reviewCycle,
              plan: plan,
              reviewWorkspace: reviewWorkspace,
              integration: integration
            )
            return
          }
        } catch let error as CodexRPCError where error.isThreadNotFound {
          replacedUnavailableThread = true
        }
      }

      let reviewComments = try await store.fetchComments(workItemID: item.id)
      let priorReviewFeedback =
        reviewCycle > 0
        ? reviewComments.reversed().first {
          $0.authorName == techLead.name
            && !$0.body.hasPrefix("I’m reviewing")
            && !$0.body.hasPrefix("The implementation has not converged")
            && !$0.body.hasPrefix("I still see a material acceptance issue")
        }?.body
        : nil
      let fullReviewPrompt = CodexTechLeadReviewer.prompt(
        product: product,
        item: item,
        implementation: implementation,
        knowledgePageProposals: candidateKnowledgePageProposals,
        assignee: implementer,
        reviewCycle: reviewCycle,
        priorReviewFeedback: priorReviewFeedback,
        recentComments: reviewComments,
        deliveryKind: candidate.deliveryKind,
        baseSHA: candidate.baseSHA,
        candidateHeadSHA: candidate.headSHA,
        integratedSHA: integration?.integratedSHA
      )
      let interruptedPermission = sprintWorkRecoveryPolicy.latestPermissionContinuation(
        for: reviewRun.id,
        permissionRequests: permissionRequests
      )

      var threadID: String
      var turnPrompt: String
      if let resumedReviewThreadID {
        threadID = resumedReviewThreadID
        turnPrompt = """
          \(CodexTechLeadReviewer.recoveryPrompt(
            item: item,
            reviewedSHA: reviewWorkspace.integratedSHA,
            isIntegratedRevision: integration != nil,
            interruptedPermission: interruptedPermission
          ))

          AUTHORITATIVE CANDIDATE REVIEW CONTEXT
          Re-read this complete immutable context before deciding. It supersedes any incomplete
          candidate context from an earlier turn in this conversation.

          \(fullReviewPrompt)
          """
      } else {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: reviewWorkspace.url,
          developerInstructions: developerInstructions,
          model: techLead.model,
          allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
          readOnlyProductDirectory: try productDatabaseURL(productID: product.id).deletingLastPathComponent()
        )
        turnPrompt = fullReviewPrompt
        if replacedUnavailableThread {
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body:
              "The previous tech lead conversation was unavailable. I started a replacement against the same immutable revision; implementation was not repeated."
          )
        }
      }

      _ = try await updateAgentRun(
        id: reviewRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: reviewWorkspace.url.path,
        eventActor: "Spedito",
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable review conversation"
          : "Continuing tech lead review against the same immutable revision"
      )
      await reloadSelectedProductIfCurrent(productID: product.id)

      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: turnPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [
            reviewWorkspace.url,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: reviewWorkspace.url,
          developerInstructions: developerInstructions,
          model: techLead.model,
          allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
          readOnlyProductDirectory: try productDatabaseURL(productID: product.id).deletingLastPathComponent()
        )
        turnPrompt = fullReviewPrompt
        _ = try await updateAgentRun(
          id: reviewRun.id,
          status: .running,
          codexThreadID: threadID,
          worktreePath: reviewWorkspace.url.path,
          eventActor: "Spedito",
          eventDetail: "Replaced an unavailable review conversation"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The previous tech lead conversation was unavailable. I started a replacement against the same immutable revision; implementation was not repeated."
        )
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: turnPrompt,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [
            reviewWorkspace.url,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      }

      ticketDeliveryRuntimeCoordinator.registerActiveTurn(
        runID: reviewRun.id,
        productID: product.id,
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: reviewRun.id,
        productID: product.id,
        client: client,
        threadID: threadID,
        turnID: turnID,
        initialText: "Continuing the tech lead review…"
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(600)
      )
      stopLiveActivityMonitoring(runID: reviewRun.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: reviewRun.id)

      let review: TechLeadReviewResult
      do {
        review = try CodexTechLeadReviewer.decode(response)
      } catch TechLeadReviewGenerationError.changesRequestedWithoutFinding {
        let repairTurnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: """
              Your previous review selected changes_requested but did not identify a blocking finding.
              Correct the structured review now. If there is no concrete material blocker under the
              supplied review policy, approve. Otherwise include one to three small, actionable
              findings that name the violated criterion or defect. Return only the required JSON.
            """,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [
            reviewWorkspace.url,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
        ticketDeliveryRuntimeCoordinator.registerActiveTurn(
          runID: reviewRun.id,
          productID: product.id,
          threadID: threadID,
          turnID: repairTurnID
        )
        monitorLiveActivity(
          runID: reviewRun.id,
          productID: product.id,
          client: client,
          threadID: threadID,
          turnID: repairTurnID,
          initialText: "Clarifying the review decision…"
        )
        let repairedResponse = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: repairTurnID,
          timeout: .seconds(180)
        )
        stopLiveActivityMonitoring(runID: reviewRun.id)
        ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: reviewRun.id)
        review = try CodexTechLeadReviewer.decode(repairedResponse)
      }

      try await applyTechLeadReviewResult(
        review,
        implementation: implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewRun: reviewRun,
        reviewCycle: reviewCycle,
        plan: plan,
        reviewWorkspace: reviewWorkspace,
        integration: integration
      )
    } catch {
      stopLiveActivityMonitoring(runID: reviewRun.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: reviewRun.id)
      if Task.isCancelled {
        _ = try? await updateAgentRun(
          id: reviewRun.id,
          status: .interrupted,
          eventActor: "Spedito",
          eventDetail: "Tech lead review paused when the app stopped"
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }

      // The candidate may have been carried through review by another task while this
      // continuation was still waiting. Failing it then would discard a prepared demo,
      // so leave the applied outcome untouched and drop this stale failure.
      guard
        let currentCandidate = await candidateAwaitingReviewOutcome(
          id: candidate.id,
          productID: product.id
        )
      else {
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }

      _ = try? await updateAgentRun(
        id: reviewRun.id,
        status: .failed,
        eventActor: "Spedito",
        eventDetail: error.localizedDescription
      )
      _ = try? await store.updateCandidateRevision(
        id: candidate.id,
        status: .failed
      )
      try? await store.markKnowledgePageProposals(
        candidateRevisionID: candidate.id,
        status: .superseded
      )
      if let integrationPath = currentCandidate.integrationWorktreePath {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: productWorkspaceURL(productID: product.id),
          worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
        )
      }
      if let currentState = try? await store.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == item.id })?.state,
        currentState == .verifying || currentState == .integrating
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: "Review continuation stopped; preserving work for retry"
        )
      }
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Tech lead review continuation could not complete"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Tech lead review continuation stopped unexpectedly: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved implementation workspace."
      )
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }
  public func reviewCompletedImplementation(
    _ implementation: TicketExecutionResult,
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    preparedIntegration: GitIntegrationSnapshot? = nil
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
      let client = codexClient,
      let context =
        await context(productID: plan.sprint.productID),
      let item = context.workItems.first(
        where: { $0.id == implementationRun.workItemID }
      ),
      let implementer = context.profiles.first(
        where: { $0.id == implementationRun.profileID }
      ),
      let techLead = context.profiles.first(where: { $0.role == .lead })
    else { return }
    let product = context.product

    var failureStage = "Tech lead review"
    var activeReviewRunID: UUID?
    do {
      let currentState = (try await store.fetchWorkItems(productID: product.id))
        .first { $0.id == item.id }?.state
      if currentState == .running {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .integrating,
          actor: implementer.name,
          reason: "Implementation and reported checks completed"
        )
      }
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .completed,
        eventActor: implementer.name,
        eventDetail: preparedIntegration == nil
          ? "Implementation complete; waiting for tech lead review"
          : "Integrated candidate ready for tech lead review"
      )
      let repositoryURL = try productWorkspaceURL(productID: product.id)
      let reviewWorkspace: GitIntegrationSnapshot
      if let preparedIntegration {
        reviewWorkspace = preparedIntegration
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .reviewing,
          integratedSHA: preparedIntegration.integratedSHA,
          integrationWorktreePath: preparedIntegration.url.path
        )
      } else {
        reviewWorkspace = try await gitWorkspaceManager.prepareCandidateReviewWorkspace(
          repositoryURL: repositoryURL,
          reviewsRootURL: integrationWorktreesRootURL(productID: product.id),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA
        )
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .reviewing,
          integrationWorktreePath: reviewWorkspace.url.path
        )
      }
      if currentState == .integrating {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: techLead.name,
          reason: "Independent tech lead review started"
        )
      }

      let reviewRun = try await store.createAgentRun(
        AgentRun(
          productID: product.id,
          sprintID: plan.sprint.id,
          sprintItemID: implementationRun.sprintItemID,
          workItemID: item.id,
          profileID: techLead.id,
          status: .running
        )
      )
      activeReviewRunID = reviewRun.id
      try await recordKnowledgeContext(
        runID: reviewRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      await reloadSelectedProductIfCurrent(productID: product.id)

      let workspace = reviewWorkspace.url
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workspace,
        developerInstructions: CodexTechLeadReviewer.developerInstructions(
          productInstructions: inheritedAgentInstructions(for: product),
          customInstructions: techLead.customInstructionText,
          reviewer: techLead
        ),
        model: techLead.model,
        allowsApprovals: CodexTechLeadReviewer.allowsApprovals,
        readOnlyProductDirectory: try productDatabaseURL(productID: product.id).deletingLastPathComponent()
      )
      _ = try await updateAgentRun(
        id: reviewRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path
      )
      let reviewComments = try await store.fetchComments(workItemID: item.id)
      let candidateKnowledgePageProposals = try await store.fetchKnowledgePageProposals(
        productID: product.id
      ).filter { proposal in
        proposal.candidateRevisionID == candidate.id
      }
      let priorReviewFeedback =
        reviewCycle > 0
        ? reviewComments.reversed().first {
          $0.authorName == techLead.name
            && !$0.body.hasPrefix("I’m reviewing")
            && !$0.body.hasPrefix("The implementation has not converged")
            && !$0.body.hasPrefix("I still see a material acceptance issue")
        }?.body
        : nil
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTechLeadReviewer.prompt(
          product: product,
          item: item,
          implementation: implementation,
          knowledgePageProposals: candidateKnowledgePageProposals,
          assignee: implementer,
          reviewCycle: reviewCycle,
          priorReviewFeedback: priorReviewFeedback,
          recentComments: reviewComments,
          deliveryKind: candidate.deliveryKind,
          baseSHA: candidate.baseSHA,
          candidateHeadSHA: candidate.headSHA,
          integratedSHA: preparedIntegration?.integratedSHA
        ),
        effort: techLead.reasoningEffort,
        outputSchema: CodexTechLeadReviewer.outputSchema,
        runtimeWorkspaceRoots: [
          workspace,
          try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
        ]
      )
      ticketDeliveryRuntimeCoordinator.registerActiveTurn(
        runID: reviewRun.id,
        productID: product.id,
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: reviewRun.id,
        productID: product.id,
        client: client,
        threadID: threadID,
        turnID: turnID,
        initialText: "Reviewing the delivery evidence…"
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(600)
      )
      stopLiveActivityMonitoring(runID: reviewRun.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: reviewRun.id)
      let review: TechLeadReviewResult
      do {
        review = try CodexTechLeadReviewer.decode(response)
      } catch TechLeadReviewGenerationError.changesRequestedWithoutFinding {
        let repairTurnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: """
              Your previous review selected changes_requested but did not identify a blocking finding.
              Correct the structured review now. If there is no concrete material blocker under the
              supplied review policy, approve. Otherwise include one to three small, actionable
              findings that name the violated criterion or defect. Return only the required JSON.
            """,
          effort: techLead.reasoningEffort,
          outputSchema: CodexTechLeadReviewer.outputSchema,
          runtimeWorkspaceRoots: [
            workspace,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
        ticketDeliveryRuntimeCoordinator.registerActiveTurn(
          runID: reviewRun.id,
          productID: product.id,
          threadID: threadID,
          turnID: repairTurnID
        )
        monitorLiveActivity(
          runID: reviewRun.id,
          productID: product.id,
          client: client,
          threadID: threadID,
          turnID: repairTurnID,
          initialText: "Clarifying the review decision…"
        )
        let repairedResponse = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: repairTurnID,
          timeout: .seconds(180)
        )
        stopLiveActivityMonitoring(runID: reviewRun.id)
        ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: reviewRun.id)
        review = try CodexTechLeadReviewer.decode(repairedResponse)
      }
      activeReviewRunID = nil
      failureStage = "Post-review handoff"
      try await applyTechLeadReviewResult(
        review,
        implementation: implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewRun: reviewRun,
        reviewCycle: reviewCycle,
        plan: plan,
        reviewWorkspace: reviewWorkspace,
        integration: preparedIntegration
      )
    } catch {
      if Task.isCancelled {
        if let activeReviewRunID {
          stopLiveActivityMonitoring(runID: activeReviewRunID)
          ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: activeReviewRunID)
          _ = try? await updateAgentRun(
            id: activeReviewRunID,
            status: .interrupted,
            eventActor: "Spedito",
            eventDetail: "Tech lead review paused when the app stopped"
          )
        }
        stopLiveActivityMonitoring(runID: implementationRun.id)
        ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: implementationRun.id)
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      // The candidate may have been carried through review by another task while this
      // review was still waiting. Tearing it down then would stop a prepared demo and
      // fail an accepted candidate, so drop this stale failure instead.
      guard
        let currentCandidate = await candidateAwaitingReviewOutcome(
          id: candidate.id,
          productID: product.id
        )
      else {
        if let activeReviewRunID {
          stopLiveActivityMonitoring(runID: activeReviewRunID)
          ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: activeReviewRunID)
        }
        stopLiveActivityMonitoring(runID: implementationRun.id)
        ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: implementationRun.id)
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      await stopDemoSession(candidate, removesPreview: true)
      if let activeReviewRunID {
        stopLiveActivityMonitoring(runID: activeReviewRunID)
        ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: activeReviewRunID)
        _ = try? await updateAgentRun(
          id: activeReviewRunID,
          status: Task.isCancelled ? .interrupted : .failed,
          eventActor: "Spedito",
          eventDetail: error.localizedDescription
        )
      }
      stopLiveActivityMonitoring(runID: implementationRun.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: implementationRun.id)
      _ = try? await store.updateCandidateRevision(
        id: candidate.id,
        status: .failed
      )
      try? await store.markKnowledgePageProposals(
        candidateRevisionID: candidate.id,
        status: .superseded
      )
      if let integrationPath = currentCandidate.integrationWorktreePath {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: productWorkspaceURL(productID: product.id),
          worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
        )
      }
      if let currentState = try? await store.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == item.id })?.state,
        currentState == .verifying || currentState == .integrating
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: "Review stopped; preserving work for retry"
        )
      }
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "\(failureStage) could not complete"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "\(failureStage) stopped unexpectedly: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved workspace."
      )
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }
  private func applyTechLeadReviewResult(
    _ review: TechLeadReviewResult,
    implementation: TicketExecutionResult,
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    reviewRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    reviewWorkspace: GitIntegrationSnapshot,
    integration: GitIntegrationSnapshot?
  ) async throws {
    guard
      let store = store(for: plan.sprint.productID),
      let client = codexClient,
      let context =
        await context(productID: plan.sprint.productID),
      let item = context.workItems.first(
        where: { $0.id == implementationRun.workItemID }
      ),
      let implementer = context.profiles.first(
        where: { $0.id == implementationRun.profileID }
      ),
      let techLead = context.profiles.first(where: { $0.id == reviewRun.profileID })
    else {
      throw CodexClientError.notConnected
    }
    let product = context.product

    let existingComments = try await store.fetchComments(workItemID: item.id)
    if !existingComments.contains(where: {
      $0.authorKind == .agent
        && $0.authorName == techLead.name
        && $0.body == review.workLogComment
        && $0.createdAt >= reviewRun.createdAt
    }) {
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: techLead.name,
        body: review.workLogComment
      )
    }
    let reviewWasAlreadyCompleted = reviewRun.status == .completed
    _ = try await updateAgentRun(id: reviewRun.id, status: .completed)
    if !reviewWasAlreadyCompleted {
      try await store.saveRetrospectiveNotes(
        makeRetrospectiveNotes(
          productID: item.productID,
          sprintID: plan.sprint.id,
          workItemID: item.id,
          profile: techLead,
          wentWell: review.retrospectiveWentWell,
          couldImprove: review.retrospectiveCouldImprove,
          actions: review.retrospectiveActions
        )
      )
    }

    let repositoryURL = try productWorkspaceURL(productID: product.id)
    switch review.decision {
    case .approved:
      let currentCandidate = try await store.fetchCandidateRevision(id: candidate.id)
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: currentCandidate.status,
        reviewedHeadSHA: candidate.headSHA,
        reviewRunID: reviewRun.id
      )
      try await store.verifyDeliveryNote(workItemID: item.id, authorName: techLead.name)
      try await store.markKnowledgePageProposals(
        candidateRevisionID: candidate.id,
        status: .reviewed
      )
      if candidate.deliveryKind == .localOutcome {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: reviewWorkspace.url
        )
        try await finalizeReviewedLocalOutcome(
          candidate: candidate,
          implementationRun: implementationRun,
          workItem: item,
          reviewerName: techLead.name
        )
        return
      }
      guard integration != nil else {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: reviewWorkspace.url
        )
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .queuedForIntegration
        )
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .completed,
          eventActor: techLead.name,
          eventDetail: "Tech lead review passed; candidate queued for integration"
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      try await finalizeReviewedIntegration(
        candidateID: candidate.id,
        implementation: implementation,
        implementationRun: implementationRun,
        workItem: item,
        reviewerName: techLead.name
      )
    case .changesRequested:
      let adoptedBaseline: TicketRevisionBaseline?
      if let integration {
        adoptedBaseline = try await adoptIntegratedBaselineForRevision(
          candidate: candidate,
          integratedSHA: integration.integratedSHA
        )
      } else {
        adoptedBaseline = nil
      }
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .changesRequested
      )
      try await store.markKnowledgePageProposals(
        candidateRevisionID: candidate.id,
        status: .superseded
      )
      try? await gitWorkspaceManager.removeWorktree(
        repositoryURL: repositoryURL,
        worktreeURL: reviewWorkspace.url
      )
      if let currentState = try await store.fetchWorkItems(productID: item.productID)
        .first(where: { $0.id == item.id })?.state,
        currentState == .verifying || currentState == .integrating
      {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: techLead.name,
          reason: "Review changes requested"
        )
      }
      let changeRequestNumber = SprintReviewCorrectionPolicy.changeRequestNumber(
        reviewCycle: reviewCycle
      )
      guard
        SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(
          reviewCycle: reviewCycle
        )
      else {
        let remainingFindings = review.findings.prefix(3)
          .map { "- \($0)" }
          .joined(separator: "\n")
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .awaitingOwner,
          eventActor: techLead.name,
          eventDetail:
            "\(review.findings.count) material review finding\(review.findings.count == 1 ? "" : "s") remain after \(changeRequestNumber) review returns"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .agent,
          authorName: techLead.name,
          body: """
            I paused automatic revisions after \(changeRequestNumber) review returns because these findings remain:

            \(remainingFindings.isEmpty ? "- The review did not provide a concrete finding." : remainingFindings)

            Ask the assigned specialist a question without restarting work, or add product owner direction and choose Submit answers.
            """
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .running,
        eventActor: implementer.name,
        eventDetail: "Resuming after \(techLead.name) requested changes"
      )
      await reloadSelectedProductIfCurrent(productID: product.id)
      let comments = try await store.fetchComments(workItemID: item.id)
      let revisionWorkspace = URL(
        fileURLWithPath: candidate.worktreePath,
        isDirectory: true
      )
      let developerInstructions = CodexTicketExecutor.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product),
        customInstructions: implementer.customInstructionText,
        assignee: implementer,
        savedPermissionGrants: context.permissionGrants
      )
      let revisionPrompt = CodexTicketExecutor.revisionPrompt(
        item: item,
        reviewer: techLead,
        feedback: review.workLogComment,
        recentComments: comments,
        adoptedBaseline: adoptedBaseline
      )
      var revisionThreadID: String
      if let existingThreadID = implementationRun.codexThreadID {
        do {
          revisionThreadID = try await client.resumeWorkspaceThread(
            threadID: existingThreadID,
            workingDirectory: revisionWorkspace,
            developerInstructions: developerInstructions,
            model: implementer.model,
            readOnlyGitDirectory: repositoryURL.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          revisionThreadID = try await client.startWorkspaceThread(
            workingDirectory: revisionWorkspace,
            developerInstructions: developerInstructions,
            model: implementer.model,
            readOnlyGitDirectory: repositoryURL.appendingPathComponent(
              ".git",
              isDirectory: true
            )
          )
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body:
              "The delivery agent’s previous conversation was unavailable. I started a replacement in the preserved ticket workspace and passed it the tech lead’s feedback."
          )
        }
      } else {
        revisionThreadID = try await client.startWorkspaceThread(
          workingDirectory: revisionWorkspace,
          developerInstructions: developerInstructions,
          model: implementer.model,
          readOnlyGitDirectory: repositoryURL.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        )
      }
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .running,
        codexThreadID: revisionThreadID,
        worktreePath: revisionWorkspace.path
      )

      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: revisionThreadID,
          prompt: revisionPrompt,
          effort: implementer.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [
            revisionWorkspace,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        revisionThreadID = try await client.startWorkspaceThread(
          workingDirectory: revisionWorkspace,
          developerInstructions: developerInstructions,
          model: implementer.model,
          readOnlyGitDirectory: repositoryURL.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        )
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .running,
          codexThreadID: revisionThreadID,
          worktreePath: revisionWorkspace.path,
          eventActor: "Spedito",
          eventDetail: "Replaced a stale Codex thread before applying review feedback"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The delivery agent’s previous Codex session was unavailable. I started a replacement session in the preserved ticket workspace and passed it the tech lead’s feedback."
        )
        turnID = try await client.startStructuredTurn(
          threadID: revisionThreadID,
          prompt: revisionPrompt,
          effort: implementer.reasoningEffort,
          outputSchema: CodexTicketExecutor.outputSchema,
          runtimeWorkspaceRoots: [
            revisionWorkspace,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      }
      ticketDeliveryRuntimeCoordinator.registerActiveTurn(
        runID: implementationRun.id,
        productID: product.id,
        threadID: revisionThreadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: implementationRun.id,
        productID: product.id,
        client: client,
        threadID: revisionThreadID,
        turnID: turnID,
        initialText: "Applying the review feedback…"
      )
      let revisionResponse = try await client.waitForFinalAgentMessage(
        threadID: revisionThreadID,
        turnID: turnID,
        timeout: .seconds(900)
      )
      stopLiveActivityMonitoring(runID: implementationRun.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: implementationRun.id)
      let revision = try await validatedExecutionResult(revisionResponse,
      client: client,
      threadID: revisionThreadID,
      runID: implementationRun.id,
      productID: product.id,
      assignee: implementer,
      workspaceURL: revisionWorkspace,
      canonicalKnowledgePages: context.knowledgePages)
      await processExecutionResult(revision.result,
      deliveryKind: revision.deliveryKind,
      implementationRunID: implementationRun.id,
      reviewCycle: reviewCycle + 1,
      plan: plan)
    }
  }
  @discardableResult
  public func processIntegrationCandidates(
    context: TicketDeliveryWorkflowContext
  ) async -> Bool {
    let plan = context.plan
    let profiles = context.profiles
    let runs = context.runs
    let workItems = context.workItems
    let productID = plan.sprint.productID
    guard let store = store(for: productID) else { return false }
    do {
      try await requeueStaleReadyCandidates(productID: productID)
      let candidates = try await store.fetchCandidateRevisions(productID: productID)
      var startedTask = false
      let techLeadID = profiles.first(where: { $0.role == .lead })?.id
      let reviewerProfileIDs = Set(
        profiles
          .filter { $0.role == .lead }
          .map(\.id)
      )
      let reviewingCandidates =
        candidates
        .filter {
          $0.sprintID == plan.sprint.id
            && $0.status == .reviewing
            && $0.integratedSHA != nil
        }
        .sorted { $0.createdAt < $1.createdAt }
      for reviewingCandidate in reviewingCandidates {
        // A candidate reaches .reviewing from inside integrateCandidateBeforeReview,
        // which owns the whole integrate → review → apply chain under the integration
        // task. That in-flight review is not registered as a review task, so resuming
        // on .reviewing alone would start a second review on the same Codex thread.
        // The in-memory registry is empty after a relaunch, so orphan recovery still runs.
        guard
          !ticketDeliveryRuntimeCoordinator.isReviewInProgress(
            candidateID: reviewingCandidate.id
          ),
          !ticketDeliveryRuntimeCoordinator.isIntegrationInProgress(
            candidateID: reviewingCandidate.id
          )
        else { continue }
        guard
          let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
            for: reviewingCandidate,
            runs: runs,
            reviewerProfileIDs: reviewerProfileIDs
          ),
          reviewRun.status == .queued
            || reviewRun.status == .running
            || reviewRun.status == .completed
        else { continue }
        let started = ticketDeliveryRuntimeCoordinator.startReview(
          candidateID: reviewingCandidate.id,
          productID: productID
        ) { [weak self] in
          guard let self else { return }
          await self.resumeTechLeadReview(
            candidate: reviewingCandidate,
            reviewRun: reviewRun,
            plan: plan
          )
        }
        startedTask = startedTask || started
      }
      let resolvingCandidates =
        candidates
        .filter {
          $0.sprintID == plan.sprint.id && $0.status == .resolvingConflict
        }
        .sorted { $0.createdAt < $1.createdAt }
      for resolvingCandidate in resolvingCandidates {
        guard
          !ticketDeliveryRuntimeCoordinator.isIntegrationInProgress(
            candidateID: resolvingCandidate.id
          )
        else { continue }
        let resolutionRuns =
          runs
          .filter {
            $0.workItemID == resolvingCandidate.workItemID
              && $0.profileID == techLeadID
              && $0.worktreePath == resolvingCandidate.integrationWorktreePath
          }
        if let resolutionRun = resolutionRuns.max(by: { $0.createdAt < $1.createdAt }),
          let worktreePath = resolvingCandidate.integrationWorktreePath,
          try await gitWorkspaceManager.conflictResolutionIsReadyToCommit(
            integrationWorkspaceURL: URL(
              fileURLWithPath: worktreePath,
              isDirectory: true
            )
          )
        {
          let started = ticketDeliveryRuntimeCoordinator.startIntegration(
            candidateID: resolvingCandidate.id,
            productID: productID
          ) { [weak self] in
            guard let self else { return }
            await self.completePreservedIntegrationConflict(
              candidate: resolvingCandidate,
              resolutionRun: resolutionRun,
              plan: plan
            )
          }
          startedTask = startedTask || started
          continue
        }
        if let resolutionRun =
          resolutionRuns
          .filter({ $0.status == .queued })
          .max(by: { $0.createdAt < $1.createdAt })
        {
          let started = ticketDeliveryRuntimeCoordinator.startIntegration(
            candidateID: resolvingCandidate.id,
            productID: productID
          ) { [weak self] in
            guard let self else { return }
            await self.resumeIntegrationConflictResolution(
              candidate: resolvingCandidate,
              resolutionRun: resolutionRun,
              plan: plan
            )
          }
          startedTask = startedTask || started
        }
      }
      let integrationCandidates = SprintCandidateAdmission.integrationQueue(
        candidates: candidates,
        sprintID: plan.sprint.id,
        workItems: workItems
      )
      for candidate in integrationCandidates {
        guard
          !ticketDeliveryRuntimeCoordinator.isIntegrationInProgress(candidateID: candidate.id)
        else { continue }
        _ = try await store.updateCandidateRevision(
          id: candidate.id,
          status: .integrating
        )
        let started = ticketDeliveryRuntimeCoordinator.startIntegration(
          candidateID: candidate.id,
          productID: productID
        ) { [weak self] in
          guard let self else { return }
          await self.integrateCandidateBeforeReview(candidate, plan: plan)
        }
        startedTask = startedTask || started
      }
      if !integrationCandidates.isEmpty {
        await reloadSelectedProductIfCurrent(productID: context.product.id)
      }
      return startedTask
    } catch {
      presentExecutionError(error, productID: context.product.id)
      return false
    }
  }

  public func requeueStaleReadyCandidates(
    productID: UUID,
    excluding excludedCandidateID: UUID? = nil
  ) async throws {
    guard let store = store(for: productID) else { return }
    let repositoryURL = try productWorkspaceURL(productID: productID)
    let candidates = try await store.fetchCandidateRevisions(productID: productID)
    for candidate in candidates
    where
      candidate.id != excludedCandidateID
      && candidate.deliveryKind.changesRepository
      && candidate.status == .readyForDemo
    {
      guard
        let integratedSHA = candidate.integratedSHA,
        !(try await gitWorkspaceManager.integratedRevisionContainsCurrentTrunk(
          repositoryURL: repositoryURL,
          integratedSHA: integratedSHA
        ))
      else { continue }
      try await requeueStaleReadyCandidate(
        candidate,
        reason:
          "Accepted trunk advanced after this demo revision was prepared."
      )
    }
  }

  public func requeueStaleReadyCandidate(
    _ candidate: CandidateRevision,
    reason: String
  ) async throws {
    guard let store = store(for: candidate.productID) else { return }
    await stopDemoSession(candidate, removesPreview: true)
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .queuedForIntegration
    )
    if let item = try await store.fetchWorkItems(productID: candidate.productID)
      .first(where: { $0.id == candidate.workItemID })
    {
      if item.state == .acceptance {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: String(reason.prefix(160))
        )
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .integrating,
          actor: "Spedito",
          reason: "The reviewed candidate is queued to integrate again"
        )
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: "Spedito",
          reason: "The reviewed candidate is waiting to integrate"
        )
      } else if item.state == .integrating {
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .verifying,
          actor: "Spedito",
          reason: "The reviewed candidate is waiting to integrate"
        )
      }
    }
    _ = try await store.appendComment(
      workItemID: candidate.workItemID,
      authorKind: .system,
      authorName: "Spedito",
      body:
        "\(reason)\n\nCandidate v\(candidate.version) kept its tech lead approval and returned to the integration queue. A clean local merge will only repeat demo preparation; incorporated GitHub changes or a conflict will receive focused tech lead re-review."
    )
  }
  public func integrateCandidateBeforeReview(
    _ candidate: CandidateRevision,
    plan: SprintPlan
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
      let context =
        await context(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let implementationRun = try? await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
    else { return }
    let product = context.product
    do {
      if candidate.deliveryKind == .localOutcome {
        let implementation = try CodexTicketExecutor.decode(candidate.executionResultJSON)
        await reviewCompletedImplementation(
          implementation,
          candidate: candidate,
          implementationRun: implementationRun,
          reviewCycle: max(0, candidate.version - 1),
          plan: plan
        )
        return
      }
      let repositoryURL = try productWorkspaceURL(productID: product.id)
      var integration: GitIntegrationSnapshot
      do {
        integration = try await gitWorkspaceManager.integrateCandidate(
          repositoryURL: repositoryURL,
          integrationsRootURL: integrationWorktreesRootURL(productID: product.id),
          candidateID: candidate.id,
          headSHA: candidate.headSHA,
          commitMessage: "Integrate \(item.key): \(item.title)"
        )
      } catch GitWorkspaceError.mergeConflict(
        let worktreePath,
        let conflictedFiles,
        _
      ) {
        await beginIntegrationConflictResolution(
          candidate: candidate,
          implementationRun: implementationRun,
          reviewCycle: max(0, candidate.version - 1),
          plan: plan,
          worktreePath: worktreePath,
          conflictedFiles: conflictedFiles,
          includesGitHubChanges: false
        )
        return
      }

      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .integrating,
        integratedSHA: integration.integratedSHA,
        integrationWorktreePath: integration.url.path
      )

      let remoteIntegration: TicketDeliveryRemoteIntegration
      do {
        remoteIntegration = try await integrateLatestGitHubChanges(
          candidate: candidate,
          integration: integration
        )
      } catch GitWorkspaceError.mergeConflict(
        let worktreePath,
        let conflictedFiles,
        _
      ) {
        await beginIntegrationConflictResolution(
          candidate: candidate,
          implementationRun: implementationRun,
          reviewCycle: max(0, candidate.version - 1),
          plan: plan,
          worktreePath: worktreePath,
          conflictedFiles: conflictedFiles,
          includesGitHubChanges: true
        )
        return
      }
      integration = remoteIntegration.snapshot
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .integrating,
        integratedSHA: integration.integratedSHA,
        integrationWorktreePath: integration.url.path
      )

      let implementation = try CodexTicketExecutor.decode(
        candidate.executionResultJSON
      )
      if
        candidate.reviewedHeadSHA == candidate.headSHA,
        !remoteIntegration.incorporatedChanges
      {
        let reviewerName: String
        if
          let reviewRunID = candidate.reviewRunID,
          let retainedReviewRun = try? await store.fetchAgentRun(id: reviewRunID),
          let retainedReviewer = context.profiles.first(where: {
            $0.id == retainedReviewRun.profileID
          })
        {
          reviewerName = retainedReviewer.name
        } else {
          reviewerName = "Tech lead"
        }
        try await finalizeReviewedIntegration(
          candidateID: candidate.id,
          implementation: implementation,
          implementationRun: implementationRun,
          workItem: item,
          reviewerName: reviewerName
        )
        return
      }
      if remoteIntegration.incorporatedChanges, let remoteSHA = remoteIntegration.remoteSHA {
        let message =
          "Integrated verified GitHub changes at \(String(remoteSHA.prefix(8))) into this ticket before final review."
        let comments = try await store.fetchComments(workItemID: item.id)
        if !comments.contains(where: { $0.body == message }) {
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body: message
          )
        }
      }
      await reviewCompletedImplementation(
        implementation,
        candidate: candidate,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan,
        preparedIntegration: integration
      )
    } catch {
      if Task.isCancelled {
        await reloadSelectedProductIfCurrent(productID: product.id)
        return
      }
      _ = try? await store.updateCandidateRevision(
        id: candidate.id,
        status: .failed
      )
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Candidate integration could not complete"
      )
      if let currentState = try? await store.fetchWorkItems(productID: product.id)
        .first(where: { $0.id == item.id })?.state,
        currentState == .integrating || currentState == .verifying
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: "Integration stopped; preserving the candidate"
        )
      }
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "The candidate could not be integrated or prepared for review: \(error.localizedDescription)\n\nThe candidate revision and ticket workspace are preserved for retry."
      )
      presentExecutionError(error, productID: product.id)
      await reloadSelectedProductIfCurrent(productID: product.id)
    }
  }
  private func beginIntegrationConflictResolution(
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    worktreePath: String,
    conflictedFiles: [String],
    includesGitHubChanges: Bool
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
      let context =
        await context(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let techLead = context.profiles.first(where: { $0.role == .lead })
    else { return }
    let product = context.product

    var resolutionRunID: UUID?
    do {
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .resolvingConflict,
        integrationWorktreePath: worktreePath
      )
      let resolutionRun = try await store.createAgentRun(
        AgentRun(
          productID: product.id,
          sprintID: plan.sprint.id,
          sprintItemID: candidate.sprintItemID,
          workItemID: item.id,
          profileID: techLead.id,
          status: .running,
          worktreePath: worktreePath
        )
      )
      resolutionRunID = resolutionRun.id
      try await recordKnowledgeContext(
        runID: resolutionRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Integrator",
        body:
          includesGitHubChanges
          ? "The ticket overlaps verified GitHub changes in \(conflictedFiles.count) file(s). I’m resolving the integration before final tech lead review."
          : "The ticket overlaps newer accepted work in \(conflictedFiles.count) file(s). I’m resolving the integration before final tech lead review."
      )
      await reloadSelectedProductIfCurrent(productID: product.id)
      await runIntegrationConflictResolution(
        candidate: candidate,
        resolutionRun: resolutionRun,
        implementationRun: implementationRun,
        reviewCycle: reviewCycle,
        plan: plan,
        conflictedFiles: conflictedFiles,
        continuationMessage: nil
      )
    } catch {
      await recordIntegrationResolutionFailure(
        error,
        candidate: candidate,
        workItemID: item.id,
        resolutionRunID: resolutionRunID
      )
    }
  }

  private func resumeIntegrationConflictResolution(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    plan: SprintPlan
  ) async {
    guard
      let store = store(for: candidate.productID),
      let worktreePath = candidate.integrationWorktreePath
    else { return }
    do {
      let implementationRun = try await store.fetchAgentRun(
        id: candidate.implementationRunID
      )
      let conflictedFiles = try await gitWorkspaceManager.unmergedFiles(
        at: URL(fileURLWithPath: worktreePath, isDirectory: true)
      )
      _ = try await updateAgentRun(
        id: resolutionRun.id,
        status: .running,
        eventActor: "Integrator",
        eventDetail: "Product owner response received; conflict resolution resumed"
      )
      await reloadSelectedProductIfCurrent(productID: plan.sprint.productID)
      await runIntegrationConflictResolution(
        candidate: candidate,
        resolutionRun: resolutionRun,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan,
        conflictedFiles: conflictedFiles,
        continuationMessage:
          "Use the latest product owner comment to resolve the open integration decision."
      )
    } catch {
      await recordIntegrationResolutionFailure(
        error,
        candidate: candidate,
        workItemID: candidate.workItemID,
        resolutionRunID: resolutionRun.id
      )
    }
  }

  private func runIntegrationConflictResolution(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    conflictedFiles: [String],
    continuationMessage: String?
  ) async {
    guard
      let store = store(for: plan.sprint.productID),
      let client = codexClient,
      let context =
        await context(productID: plan.sprint.productID),
      let item = context.workItems.first(where: { $0.id == candidate.workItemID }),
      let techLead = context.profiles.first(where: { $0.role == .lead }),
      let worktreePath = candidate.integrationWorktreePath
        ?? resolutionRun.worktreePath
    else { return }
    let product = context.product

    do {
      try await recordKnowledgeContext(
        runID: resolutionRun.id,
        productID: product.id,
        pages: KnowledgeContextSelector.mandatoryPages(in: context.knowledgePages)
      )
      let workspace = URL(fileURLWithPath: worktreePath, isDirectory: true)
      let productGitDirectory = try productWorkspaceURL(
        productID: product.id
      ).appendingPathComponent(".git", isDirectory: true)
      let developerInstructions = CodexConflictIntegrator.developerInstructions(
        productInstructions: inheritedAgentInstructions(for: product)
      )
      var replacedUnavailableThread = false
      var threadID: String
      if let existingThreadID = resolutionRun.codexThreadID {
        do {
          threadID = try await client.resumeWorkspaceThread(
            threadID: existingThreadID,
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: techLead.model,
            readOnlyGitDirectory: productGitDirectory
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          threadID = try await client.startWorkspaceThread(
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: techLead.model,
            readOnlyGitDirectory: productGitDirectory
          )
          replacedUnavailableThread = true
          _ = try await store.appendComment(
            workItemID: item.id,
            authorKind: .system,
            authorName: "Spedito",
            body:
              "The integrator’s previous conversation was unavailable. I started a replacement in the preserved conflict workspace."
          )
        }
      } else {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: techLead.model,
          readOnlyGitDirectory: productGitDirectory
        )
      }
      _ = try await updateAgentRun(
        id: resolutionRun.id,
        status: .running,
        codexThreadID: threadID,
        worktreePath: workspace.path,
        eventActor: replacedUnavailableThread ? "Spedito" : nil,
        eventDetail: replacedUnavailableThread
          ? "Replaced an unavailable integrator conversation"
          : nil
      )
      let comments = try await store.fetchComments(workItemID: item.id)
      let resolutionPrompt = CodexConflictIntegrator.prompt(
        product: product,
        item: item,
        conflictedFiles: conflictedFiles,
        recentComments: comments,
        continuationMessage: continuationMessage
      )
      let turnID: String
      do {
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: resolutionPrompt,
          effort: "medium",
          outputSchema: CodexConflictIntegrator.outputSchema,
          runtimeWorkspaceRoots: [
            workspace,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        threadID = try await client.startWorkspaceThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: techLead.model,
          readOnlyGitDirectory: productGitDirectory
        )
        _ = try await updateAgentRun(
          id: resolutionRun.id,
          status: .running,
          codexThreadID: threadID,
          worktreePath: workspace.path,
          eventActor: "Spedito",
          eventDetail: "Replaced a stale integrator Codex thread"
        )
        _ = try await store.appendComment(
          workItemID: item.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "The integrator’s previous Codex session was unavailable. I started a replacement session in the preserved conflict workspace."
        )
        turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: resolutionPrompt,
          effort: "medium",
          outputSchema: CodexConflictIntegrator.outputSchema,
          runtimeWorkspaceRoots: [
            workspace,
            try productDatabaseURL(productID: product.id).deletingLastPathComponent(),
          ]
        )
      }
      ticketDeliveryRuntimeCoordinator.registerActiveTurn(
        runID: resolutionRun.id,
        productID: product.id,
        threadID: threadID,
        turnID: turnID
      )
      monitorLiveActivity(
        runID: resolutionRun.id,
        productID: product.id,
        client: client,
        threadID: threadID,
        turnID: turnID,
        initialText: "Resolving the integration conflict…"
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(900)
      )
      stopLiveActivityMonitoring(runID: resolutionRun.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: resolutionRun.id)
      let result = try CodexConflictIntegrator.decode(response)
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: "Integrator",
        body: result.workLogComment,
        ownerQuestion:
          result.status == .awaitingOwner
          ? result.question.map {
            TicketOwnerQuestion(prompt: $0, options: result.options)
          }
          : nil
      )

      switch result.status {
      case .awaitingOwner:
        _ = try await updateAgentRun(
          id: resolutionRun.id,
          status: .awaitingOwner,
          eventActor: "Integrator",
          eventDetail: "Waiting for product owner input"
        )
        await reloadSelectedProductIfCurrent(productID: product.id)
      case .resolved:
        try await completeResolvedIntegrationConflict(
          candidate: candidate,
          resolutionRun: resolutionRun,
          implementationRun: implementationRun,
          reviewCycle: reviewCycle,
          plan: plan,
          workspace: workspace
        )
      }
    } catch {
      stopLiveActivityMonitoring(runID: resolutionRun.id)
      ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: resolutionRun.id)
      await recordIntegrationResolutionFailure(
        error,
        candidate: candidate,
        workItemID: item.id,
        resolutionRunID: resolutionRun.id
      )
    }
  }

  private func completePreservedIntegrationConflict(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    plan: SprintPlan
  ) async {
    guard
      let store = store(for: candidate.productID),
      let implementationRun = try? await store.fetchAgentRun(
        id: candidate.implementationRunID
      ),
      let worktreePath = candidate.integrationWorktreePath
    else { return }
    do {
      try await completeResolvedIntegrationConflict(
        candidate: candidate,
        resolutionRun: resolutionRun,
        implementationRun: implementationRun,
        reviewCycle: max(0, candidate.version - 1),
        plan: plan,
        workspace: URL(fileURLWithPath: worktreePath, isDirectory: true)
      )
    } catch {
      await recordIntegrationResolutionFailure(
        error,
        candidate: candidate,
        workItemID: candidate.workItemID,
        resolutionRunID: resolutionRun.id
      )
    }
  }

  private func completeResolvedIntegrationConflict(
    candidate: CandidateRevision,
    resolutionRun: AgentRun,
    implementationRun: AgentRun,
    reviewCycle: Int,
    plan: SprintPlan,
    workspace: URL
  ) async throws {
    guard let store = store(for: candidate.productID) else { return }
    var integration = try await gitWorkspaceManager.completeConflictResolution(
      integrationWorkspaceURL: workspace,
      candidateHeadSHA: candidate.headSHA
    )
    _ = try await updateAgentRun(
      id: resolutionRun.id,
      status: .completed,
      eventActor: "Integrator",
      eventDetail: "Conflict resolution completed"
    )
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .integrating,
      integratedSHA: integration.integratedSHA,
      integrationWorktreePath: integration.url.path
    )

    let remoteIntegration: TicketDeliveryRemoteIntegration
    do {
      remoteIntegration = try await integrateLatestGitHubChanges(
        candidate: candidate,
        integration: integration
      )
    } catch GitWorkspaceError.mergeConflict(
      let worktreePath,
      let conflictedFiles,
      _
    ) {
      await beginIntegrationConflictResolution(
        candidate: candidate,
        implementationRun: implementationRun,
        reviewCycle: reviewCycle,
        plan: plan,
        worktreePath: worktreePath,
        conflictedFiles: conflictedFiles,
        includesGitHubChanges: true
      )
      return
    }
    integration = remoteIntegration.snapshot
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .integrating,
      integratedSHA: integration.integratedSHA,
      integrationWorktreePath: integration.url.path
    )
    if remoteIntegration.incorporatedChanges, let remoteSHA = remoteIntegration.remoteSHA {
      let message =
        "Integrated verified GitHub changes at \(String(remoteSHA.prefix(8))) into this ticket before final review."
      let comments = try await store.fetchComments(workItemID: candidate.workItemID)
      if !comments.contains(where: { $0.body == message }) {
        _ = try await store.appendComment(
          workItemID: candidate.workItemID,
          authorKind: .system,
          authorName: "Spedito",
          body: message
        )
      }
    }
    let implementation = try CodexTicketExecutor.decode(candidate.executionResultJSON)
    await reloadSelectedProductIfCurrent(productID: candidate.productID)
    await reviewCompletedImplementation(
      implementation,
      candidate: candidate,
      implementationRun: implementationRun,
      reviewCycle: reviewCycle,
      plan: plan,
      preparedIntegration: integration
    )
  }

  private func recordIntegrationResolutionFailure(
    _ error: Error,
    candidate: CandidateRevision,
    workItemID: UUID,
    resolutionRunID: UUID?
  ) async {
    guard let store = store(for: candidate.productID) else { return }
    if let resolutionRunID {
      _ = try? await updateAgentRun(
        id: resolutionRunID,
        status: Task.isCancelled ? .interrupted : .awaitingOwner,
        eventActor: "Integrator",
        eventDetail: error.localizedDescription
      )
    }
    _ = try? await store.updateCandidateRevision(
      id: candidate.id,
      status: .resolvingConflict
    )
    _ = try? await store.appendComment(
      workItemID: workItemID,
      authorKind: .system,
      authorName: "Spedito",
      body: Task.isCancelled
        ? "Integration was interrupted. The conflict workspace is preserved."
        : "Integration needs attention: \(error.localizedDescription)\n\nComment on this ticket to retry from the preserved conflict workspace."
    )
    if !Task.isCancelled {
      presentExecutionError(error, productID: candidate.productID)
    }
    await reloadSelectedProductIfCurrent(productID: candidate.productID)
  }
  private func finalizeReviewedIntegration(
    candidateID: UUID,
    implementation: TicketExecutionResult,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    guard let store = store(for: workItem.productID) else { return }
    let integratedCandidate = try await store.fetchCandidateRevision(id: candidateID)
    guard
      let integratedSHA = integratedCandidate.integratedSHA,
      let demo = implementation.demo
    else {
      throw DemoLaunchValidationError.invalid(
        "the reviewed candidate has no managed demo recipe."
      )
    }
    let ticketPublication: RemotePublication?
    do {
      ticketPublication = try await prepareTicketPullRequestIfConnected(
        productID: workItem.productID,
        workItemID: workItem.id,
        candidateRevisionID: integratedCandidate.id
      )
    } catch GitHubRemoteRepositoryServiceError.ticketIntegrationRequired {
      try await requeueStaleReadyCandidate(
        integratedCandidate,
        reason:
          "GitHub changed while this ticket was being prepared for review. Spedito will integrate the latest verified changes and review the ticket again."
      )
      await reloadSelectedProductIfCurrent(productID: workItem.productID)
      scheduleSprintExecution(productID: workItem.productID)
      return
    }
    do {
      try await prepareDemoForAcceptance(
        candidate: integratedCandidate,
        integratedSHA: integratedSHA,
        specification: demo
      )
    } catch {
      guard
        demoPreparationShouldCorrectCandidate(error)
      else {
        throw error
      }
      try await returnDemoFailureForCorrection(
        candidateID: candidateID,
        implementationRun: implementationRun,
        workItem: workItem,
        error: error
      )
      return
    }
    let repositoryURL = try productWorkspaceURL(productID: workItem.productID)
    guard
      try await gitWorkspaceManager.integratedRevisionContainsCurrentTrunk(
        repositoryURL: repositoryURL,
        integratedSHA: integratedSHA
      )
    else {
      try await requeueStaleReadyCandidate(
        integratedCandidate,
        reason: "Accepted trunk advanced while this demo revision was being prepared."
      )
      return
    }
    _ = try await store.updateCandidateRevision(
      id: candidateID,
      status: .readyForDemo
    )
    try await markTicketPullRequestReadyIfNeeded(ticketPublication)
    _ = try await updateAgentRun(
      id: implementationRun.id,
      status: .completed,
      eventActor: reviewerName,
      eventDetail: "Reviewed candidate integrated and prepared for demo"
    )
    if let currentState = try await store.fetchWorkItems(productID: workItem.productID)
      .first(where: { $0.id == workItem.id })?.state
    {
      if currentState == .integrating {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .verifying,
          actor: reviewerName,
          reason: "Recovered the reviewed candidate"
        )
      }
      if currentState == .integrating || currentState == .verifying {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .acceptance,
          actor: reviewerName,
          reason: "Reviewed candidate integrated; ready for product owner demo"
        )
      }
    }
    await reloadSelectedProductIfCurrent(productID: workItem.productID)
  }

  private func finalizeReviewedLocalOutcome(
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    guard let store = store(for: workItem.productID) else { return }
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .readyForDemo
    )
    _ = try await updateAgentRun(
      id: implementationRun.id,
      status: .completed,
      eventActor: reviewerName,
      eventDetail: "Reviewed local outcome ready for product owner review"
    )
    if let currentState = try await store.fetchWorkItems(productID: workItem.productID)
      .first(where: { $0.id == workItem.id })?.state
    {
      if currentState == .integrating {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .verifying,
          actor: reviewerName,
          reason: "Recovered the reviewed local outcome"
        )
      }
      if currentState == .integrating || currentState == .verifying {
        _ = try await store.transitionWorkItem(
          id: workItem.id,
          to: .acceptance,
          actor: reviewerName,
          reason: "Reviewed local outcome ready for product owner review"
        )
      }
    }
    await reloadSelectedProductIfCurrent(productID: workItem.productID)
  }

  public func returnDemoFailureForCorrection(
    candidateID: UUID,
    implementationRun: AgentRun,
    workItem: WorkItem,
    error: Error
  ) async throws {
    guard let store = store(for: workItem.productID) else { return }
    let candidate = try await store.fetchCandidateRevision(id: candidateID)
    guard let integratedSHA = candidate.integratedSHA else {
      throw PersistenceError.corruptData(
        "The failed demo candidate has no integrated revision to preserve."
      )
    }

    let errorDetail = error.localizedDescription
    await stopDemoSession(candidate, removesPreview: true)
    _ = try await adoptIntegratedBaselineForRevision(
      candidate: candidate,
      integratedSHA: integratedSHA
    )
    _ = try await store.updateCandidateRevision(
      id: candidate.id,
      status: .changesRequested
    )
    try await store.markKnowledgePageProposals(
      candidateRevisionID: candidate.id,
      status: .superseded
    )
    if let integrationPath = candidate.integrationWorktreePath {
      try? await gitWorkspaceManager.removeWorktree(
        repositoryURL: productWorkspaceURL(productID: workItem.productID),
        worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
      )
    }
    if let currentState = try await store.fetchWorkItems(
      productID: workItem.productID
    ).first(where: { $0.id == workItem.id })?.state,
      currentState == .integrating || currentState == .verifying
    {
      _ = try await store.transitionWorkItem(
        id: workItem.id,
        to: .running,
        actor: "Spedito",
        reason: "Demo verification failed; correction queued"
      )
    }

    let reviewCycle = max(0, candidate.version - 1)
    let automaticallyRevises = SprintReviewCorrectionPolicy.shouldAutomaticallyRevise(
      reviewCycle: reviewCycle
    )
    _ = try await updateAgentRun(
      id: implementationRun.id,
      status: automaticallyRevises ? .queued : .awaitingOwner,
      eventActor: "Spedito",
      eventDetail: automaticallyRevises
        ? "Demo verification failed; correction queued for the implementer"
        : "Automatic corrections paused after repeated demo verification failures"
    )
    _ = try await store.appendComment(
      workItemID: workItem.id,
      authorKind: .system,
      authorName: "Spedito",
      body:
        automaticallyRevises
        ? """
        The reviewed candidate failed its managed demo verification, so I returned it to the implementer automatically. No product owner decision is needed.

        Error:
        \(errorDetail)

        The reviewed integrated revision is now the ticket workspace baseline. The correction must produce a new candidate and pass tech lead review again.
        """
        : """
        The reviewed candidate failed its managed demo verification:

        \(errorDetail)

        I preserved the integrated revision but paused automatic correction after \(SprintReviewCorrectionPolicy.changeRequestNumber(reviewCycle: reviewCycle)) revision attempts. Add product owner direction to resume the implementer.
        """
    )
    await reloadSelectedProductIfCurrent(productID: workItem.productID)
    if automaticallyRevises {
      scheduleSprintExecution(productID: workItem.productID)
    }
  }



  public func adoptIntegratedBaselineForRevision(
    candidate: CandidateRevision,
    integratedSHA: String
  ) async throws -> TicketRevisionBaseline {
    let workspace = URL(
      fileURLWithPath: candidate.worktreePath,
      isDirectory: true
    )
    try await gitWorkspaceManager.adoptIntegratedRevision(
      ticketWorkspaceURL: workspace,
      candidateHeadSHA: candidate.headSHA,
      integratedSHA: integratedSHA
    )
    return TicketRevisionBaseline(
      candidateHeadSHA: candidate.headSHA,
      integratedSHA: integratedSHA
    )
  }
  public func completeSprintTicketAcceptance(
    workItemID: UUID,
    productID: UUID
  ) async -> Bool {
    guard let store = store(for: productID) else { return false }
    do {
      guard
        let current = try await store.fetchWorkItems(productID: productID)
          .first(where: { $0.id == workItemID }),
        current.state == .acceptance || current.state == .readyToRelease
      else {
        return false
      }
      let candidates = try await store.fetchCandidateRevisions(productID: productID)
      let resumableCandidates = candidates.filter { candidate in
        candidate.workItemID == workItemID
          && (candidate.status == .readyForDemo
            || candidate.status == .promoting
            || candidate.status == .accepted)
      }
      guard
        let candidate = resumableCandidates.max(by: { $0.version < $1.version })
      else {
        throw PersistenceError.corruptData(
          "This ticket has no reviewed candidate revision ready to promote."
        )
      }
      var ticketPublication: RemotePublication?
      if candidate.deliveryKind.changesRepository,
        let remoteState = await remoteRepositoryState(productID: productID),
        remoteState.connection?.status == .connected
      {
        guard
          let publication = remoteState.publications.first(where: {
            $0.workItemID == workItemID && $0.candidateRevisionID == candidate.id
              && ($0.status.isActive || $0.status == .merged)
          })
        else {
          throw PersistenceError.corruptData(
            "This reviewed ticket has no GitHub pull request."
          )
        }
        if publication.status == .merged {
          ticketPublication = publication
        } else {
          let sync = try await syncTicketPullRequestForDelivery(
            productID: productID,
            publicationID: publication.id
          )
          if sync.changesRequested {
            await handleGitHubPullRequestSync(sync, productID: productID)
            return false
          }
          guard !sync.closedWithoutMerge,
            let refreshed = sync.state.publications.first(where: { $0.id == publication.id }),
            refreshed.status == .open,
            refreshed.pullRequest?.isDraft == false
          else {
            throw PersistenceError.corruptData(
              "The GitHub pull request must be open and ready for review before approval."
            )
          }
          ticketPublication = refreshed
        }
      }
      let executionResult = try CodexTicketExecutor.decode(candidate.executionResultJSON)
      let allProposals = try await store.fetchKnowledgePageProposals(productID: productID)
      let proposals = allProposals.filter { $0.candidateRevisionID == candidate.id }
      let publishableProposals: [KnowledgePageProposal]
      if requiresKnowledgeApproval {
        guard
          !proposals.contains(where: {
            $0.status == .proposed || $0.status == .reviewed
          })
        else {
          throw PersistenceError.corruptData(
            "Accept or reject every product knowledge proposal before completing the ticket."
          )
        }
        publishableProposals = proposals.filter { $0.status == .accepted }
      } else {
        guard !proposals.contains(where: { $0.status == .proposed }) else {
          throw PersistenceError.corruptData(
            "Tech lead review must finish every product knowledge proposal before completing the ticket."
          )
        }
        publishableProposals = proposals.filter {
          $0.status == .reviewed || $0.status == .accepted
        }
      }
      let canonicalPages = try await store.fetchKnowledgePages(productID: productID)
      _ = try KnowledgePageProposalMaterializer.applying(
        publishableProposals,
        to: canonicalPages
      )

      if candidate.status == .readyForDemo {
        _ = try await store.updateCandidateRevision(id: candidate.id, status: .promoting)
      }
      await stopDemoSession(candidate, removesPreview: true)
      let repositoryURL = try productWorkspaceURL(productID: productID)
      if candidate.deliveryKind.changesRepository {
        guard let integratedSHA = candidate.integratedSHA else {
          throw PersistenceError.corruptData(
            "This repository-changing ticket has no reviewed integrated revision."
          )
        }
        if let ticketPublication {
          let mergedSHA: String
          if ticketPublication.status == .merged,
            let existingMergedSHA = ticketPublication.pullRequest?.mergedSHA
          {
            guard
              let checked = try await checkRemoteRepositoryForDelivery(
                productID: productID
              )
            else {
              throw GitHubRemoteRepositoryServiceError.notConfigured
            }
            if let sync = checked.safeSync, sync.status == .awaitingConfirmation {
              try await acceptSafeRemoteSync(
                syncID: sync.id,
                productID: productID
              )
            }
            mergedSHA = existingMergedSHA
          } else {
            do {
              guard
                let result = try await mergeTicketPullRequest(
                  publicationID: ticketPublication.id,
                  productID: productID
                )
              else {
                throw GitHubRemoteRepositoryServiceError.notConfigured
              }
              mergedSHA = result.mergedSHA
            } catch GitHubRemoteRepositoryServiceError.ticketIntegrationRequired {
              if ticketPublication.pullRequest?.isDraft == false {
                try await returnTicketPullRequestToDraft(
                  publicationID: ticketPublication.id,
                  productID: productID
                )
              }
              try await requeueStaleReadyCandidate(
                candidate,
                reason:
                  "GitHub changed after this demo revision was prepared. Spedito will integrate the latest verified changes and review the ticket again."
              )
              await reloadSelectedProductIfCurrent(productID: productID)
              scheduleSprintExecution(productID: productID)
              return false
            }
          }
          let acceptedSHA = try await gitWorkspaceManager.acceptedTrunkSHA(at: repositoryURL)
          let acceptedTree = try await gitWorkspaceManager.revisionTreeSHA(
            repositoryURL: repositoryURL,
            revisionSHA: acceptedSHA
          )
          let integratedTree = try await gitWorkspaceManager.revisionTreeSHA(
            repositoryURL: repositoryURL,
            revisionSHA: integratedSHA
          )
          guard acceptedSHA == mergedSHA, acceptedTree == integratedTree else {
            throw PersistenceError.corruptData(
              "The merged GitHub revision did not reconcile to the reviewed ticket result."
            )
          }
        } else {
          let acceptedTrunkSHA = try await gitWorkspaceManager.acceptedTrunkSHA(at: repositoryURL)
          if acceptedTrunkSHA != integratedSHA {
            guard
              try await gitWorkspaceManager.integratedRevisionContainsCurrentTrunk(
                repositoryURL: repositoryURL,
                integratedSHA: integratedSHA
              )
            else {
              try await requeueStaleReadyCandidate(
                candidate,
                reason: "Accepted trunk advanced after this demo revision was prepared."
              )
              await reloadSelectedProductIfCurrent(productID: productID)
              scheduleSprintExecution(productID: productID)
              return false
            }
            try await gitWorkspaceManager.promote(
              repositoryURL: repositoryURL,
              integratedSHA: integratedSHA
            )
          }
        }
      }

      if let specification = executionResult.demo,
        specification.presentation.kind == .browser
          || specification.presentation.kind == .macApplication,
        (try? DemoLaunchSpecificationValidator.validate(specification)) != nil
      {
        let previousLatestCandidateID = AcceptedAppLaunchPolicy.latest(in: candidates)?.candidate.id
        if let previousLatestCandidateID {
          await stopManagedSession(
            productID: productID,
            sourceKind: .acceptedCandidate,
            launchID: previousLatestCandidateID,
            removesPreview: true
          )
        }
        let activeStatuses: Set<DemoSessionStatus> = [.preparing, .starting, .ready]
        for session in demoSessions
        where activeStatuses.contains(session.status)
          && !(session.sourceKind == .acceptedCandidate
            && session.launchID == previousLatestCandidateID)
        {
          await stopManagedSession(
            productID: session.productID,
            sourceKind: session.sourceKind,
            launchID: session.launchID,
            removesPreview: false
          )
        }
      }
      for proposal in publishableProposals {
        _ = try await store.publishKnowledgePageProposal(
          id: proposal.id,
          authorName: requiresKnowledgeApproval ? "Me" : "Spedito"
        )
      }
      if !publishableProposals.isEmpty {
        _ = try await store.appendComment(
          workItemID: current.id,
          authorKind: .system,
          authorName: "Spedito",
          body:
            "Published \(publishableProposals.count) approved product knowledge change\(publishableProposals.count == 1 ? "" : "s") to this Product's local knowledge."
        )
      }
      if !executionResult.followUpTicketProposals.isEmpty {
        _ = try await store.createFollowUpTicketSuggestionSession(
          sourceWorkItemID: current.id,
          drafts: followUpSuggestionDrafts(
            executionResult.followUpTicketProposals,
            source: current
          )
        )
      }
      _ = try await store.updateCandidateRevision(id: candidate.id, status: .accepted)

      var latest = try await store.fetchWorkItems(productID: productID)
        .first(where: { $0.id == current.id })
      if latest?.state == .acceptance {
        latest = try await store.transitionWorkItem(
          id: current.id,
          to: .readyToRelease,
          actor: "Product owner",
          reason:
            candidate.deliveryKind == .localOutcome
            ? "Reviewed outcome approved"
            : "Demo approved"
        )
      }
      if latest?.state == .readyToRelease {
        latest = try await store.transitionWorkItem(
          id: current.id,
          to: .released,
          actor: "Product owner",
          reason: "Accepted outcome completed"
        )
      }
      guard latest?.state == .released else {
        throw PersistenceError.corruptData(
          "The accepted ticket could not complete its workflow transitions."
        )
      }

      let followUpSuffix =
        executionResult.followUpTicketProposals.isEmpty
        ? ""
        : " \(executionResult.followUpTicketProposals.count) follow-up "
          + (executionResult.followUpTicketProposals.count == 1
            ? "ticket is"
            : "tickets are")
          + " ready for review in the backlog."
      let completionComment: String
      if candidate.deliveryKind == .localOutcome {
        completionComment =
          "Product owner approved local outcome v\(candidate.version). No repository revision was created or promoted."
          + followUpSuffix
      } else if let integratedSHA = candidate.integratedSHA {
        completionComment =
          "Product owner approved candidate v\(candidate.version). Integrated revision "
          + "\(String(integratedSHA.prefix(8))) is now the accepted trunk."
          + followUpSuffix
      } else {
        throw PersistenceError.corruptData(
          "The accepted repository candidate has no integrated revision."
        )
      }
      let existingComments = try await store.fetchComments(workItemID: current.id)
      if !existingComments.contains(where: { $0.body == completionComment }) {
        _ = try await store.appendComment(
          workItemID: current.id,
          authorKind: .system,
          authorName: "Spedito",
          body: completionComment
        )
      }
      try await requeueStaleReadyCandidates(
        productID: productID,
        excluding: candidate.id
      )
      if let activePlan = try await store.fetchCurrentSprint(productID: productID),
        activePlan.sprint.state.isInProgress,
        activePlan.items.contains(where: { $0.workItemID == current.id })
      {
        _ = try await store.completeSprintIfFinished(id: activePlan.sprint.id)
      }
      if let integrationPath = candidate.integrationWorktreePath {
        try? await gitWorkspaceManager.removeWorktree(
          repositoryURL: repositoryURL,
          worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
        )
      }
      try? await gitWorkspaceManager.removeTicketWorkspace(
        repositoryURL: repositoryURL,
        worktreeURL: URL(fileURLWithPath: candidate.worktreePath, isDirectory: true),
        branchName: candidate.branchName
      )
      await reloadSelectedProductIfCurrent(productID: productID)
      scheduleRetrospectiveSyntheses()
      scheduleSprintExecution(productID: productID)
      return true
    } catch {
      if let candidate = try? await store.fetchCandidateRevisions(productID: productID)
        .filter({
          $0.workItemID == workItemID && $0.status == .promoting
        })
        .max(by: { $0.version < $1.version })
      {
        _ = try? await store.updateCandidateRevision(
          id: candidate.id,
          status: .readyForDemo
        )
      }
      _ = try? await store.appendComment(
        workItemID: workItemID,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Ticket completion stopped: \(error.localizedDescription)\n\nThe reviewed result remains ready for approval. Choose Approve and complete to retry."
      )
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: productID)
      return false
    }
  }

  private func followUpSuggestionDrafts(
    _ proposals: [FollowUpTicketProposalDraft],
    source: WorkItem
  ) -> [TicketSuggestionDraft] {
    let referenceMap = Dictionary(
      uniqueKeysWithValues: proposals.enumerated().map { index, proposal in
        (proposal.reference, "S\(index + 1)")
      }
    )
    return proposals.enumerated().map { index, proposal in
      TicketSuggestionDraft(
        reference: "S\(index + 1)",
        title: proposal.title,
        type: proposal.type,
        body: proposal.body,
        acceptanceCriteria: proposal.acceptanceCriteria,
        suggestedRole: proposal.suggestedRole,
        priority: proposal.priority,
        rationale: proposal.rationale,
        dependsOnReferences: proposal.dependsOnReferences.compactMap {
          referenceMap[$0]
        },
        dependsOnExistingWorkItemKeys: [source.key]
      )
    }
  }
  @discardableResult
  public func beginSprintTicketAcceptance(_ item: WorkItem) -> Bool {
    guard item.state == .acceptance || item.state == .readyToRelease else {
      return false
    }
    if ticketDeliveryRuntimeCoordinator.isAcceptanceInProgress(workItemID: item.id) {
      return true
    }
    ticketDeliveryRuntimeCoordinator.startAcceptance(
      workItemID: item.id,
      productID: item.productID
    ) { [weak self] in
      guard let self else { return }
      await self.prepareAcceptance(item.id, item.productID)
      guard !Task.isCancelled else { return }
      _ = await self.completeSprintTicketAcceptance(
        workItemID: item.id,
        productID: item.productID
      )
    }
    return true
  }

  public func recoverInterruptedTicketAcceptances(productIDs: [UUID]) async {
    for productID in productIDs {
      guard let store = store(for: productID) else { continue }
      do {
        let itemsByID = Dictionary(
          uniqueKeysWithValues: try await store.fetchWorkItems(productID: productID).map {
            ($0.id, $0)
          }
        )
        let interrupted = try await store.fetchCandidateRevisions(productID: productID)
          .filter { candidate in
            guard candidate.status == .promoting || candidate.status == .accepted,
              let item = itemsByID[candidate.workItemID]
            else {
              return false
            }
            return item.state == .acceptance || item.state == .readyToRelease
          }
        for candidate in interrupted {
          guard let item = itemsByID[candidate.workItemID] else { continue }
          _ = beginSprintTicketAcceptance(item)
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
  public func pauseSprint(_ sprint: Sprint) async -> Bool {
    guard
      sprint.state == .active,
      let store = store(for: sprint.productID)
    else { return false }

    do {
      _ = try await store.pauseSprint(id: sprint.id)
      ticketDeliveryRuntimeCoordinator.beginSprintCancellation(
        productID: sprint.productID,
        intent: .pause
      )
      await suspendSprintExecution(productID: sprint.productID)
      ticketDeliveryRuntimeCoordinator.endSprintCancellation(
        productID: sprint.productID,
        intent: .pause
      )
      await delegate?.deliveryStopDemoSessions(
        productID: sprint.productID,
        includesPreparation: true
      )
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return true
    } catch {
      ticketDeliveryRuntimeCoordinator.endSprintCancellation(
        productID: sprint.productID,
        intent: .pause
      )
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return false
    }
  }

  public func resumeSprint(_ sprint: Sprint) async -> Bool {
    guard
      sprint.state == .paused,
      let store = store(for: sprint.productID)
    else { return false }

    do {
      _ = try await store.resumeSprint(id: sprint.id)
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      scheduleSprintExecution(productID: sprint.productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return false
    }
  }

  public func stopSprint(_ sprint: Sprint) async -> Bool {
    guard
      sprint.state.isInProgress,
      let store = store(for: sprint.productID)
    else { return false }

    ticketDeliveryRuntimeCoordinator.beginSprintCancellation(
      productID: sprint.productID,
      intent: .stop
    )
    defer {
      ticketDeliveryRuntimeCoordinator.endSprintCancellation(
        productID: sprint.productID,
        intent: .stop
      )
    }
    do {
      if sprint.state == .active {
        _ = try await store.pauseSprint(id: sprint.id)
      }
      await suspendSprintExecution(productID: sprint.productID)
      await delegate?.deliveryStopDemoSessions(
        productID: sprint.productID,
        includesPreparation: true
      )
      _ = try await store.cancelSprint(id: sprint.id)
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: sprint.productID)
      return false
    }
  }
  @discardableResult
  private func performTicketDeliveryRecovery(
    productID: UUID,
    workItemID: UUID,
    store: SQLiteStore,
    mutations: [TicketDeliveryRecoveryMutation]
  ) async -> Bool {
    do {
      try await store.performTicketDeliveryRecovery(
        productID: productID,
        workItemID: workItemID,
        mutations: mutations
      )
      return true
    } catch TicketDeliveryRecoveryError.staleRun {
      do {
        switch try await recoveryRunConflictDisposition(
          productID: productID,
          workItemID: workItemID,
          store: store,
          mutations: mutations
        ) {
        case .alreadyRecovered:
          return true
        case .failure(let error):
          presentExecutionError(error, productID: productID)
        }
      } catch {
        presentExecutionError(error, productID: productID)
      }
      return false
    } catch {
      presentExecutionError(error, productID: productID)
      return false
    }
  }

  private func recoveryRunConflictDisposition(
    productID: UUID,
    workItemID: UUID,
    store: SQLiteStore,
    mutations: [TicketDeliveryRecoveryMutation]
  ) async throws -> TicketDeliveryRecoveryRunConflictDisposition {
    let runIDs = Set(
      mutations.compactMap { mutation -> UUID? in
        guard case .updateRun(let id, _, _, _, _) = mutation else { return nil }
        return id
      }
    )
    guard !runIDs.isEmpty else {
      return .failure(.contradictoryRunState)
    }
    let candidates = try await store.fetchCandidateRevisions(productID: productID)
    for runID in runIDs {
      let run = try await store.fetchAgentRun(id: runID)
      let disposition = TicketDeliveryRecoveryRunConflictPolicy.disposition(
        run: run,
        productID: productID,
        workItemID: workItemID,
        candidates: candidates
      )
      if case .failure = disposition {
        return disposition
      }
    }
    return .alreadyRecovered
  }

  public func recoverDelivery(productID: UUID) async {
    guard
      let store = store(for: productID),
      let client = codexClient,
      let context = await context(productID: productID)
    else { return }
    let plan = context.plan
    let product = context.product
    let workItems = context.workItems
    let profiles = context.profiles
    let runs = context.runs
    let permissionRequests = context.permissionRequests
    let storedCandidates = context.candidates
    let implementerByItemID = Dictionary(
      uniqueKeysWithValues: plan.items.compactMap { item in
        item.implementerProfileID.map { (item.workItemID, $0) }
      }
    )
    let reviewerProfileIDs = Set(
      profiles
        .filter { $0.role == .lead }
        .map(\.id)
    )
    // Recovery adopts runs the database still calls running, on the assumption a
    // process stopped and orphaned them. A scheduler is prepared every time one
    // is created, not only at launch, so this runs repeatedly while delivery is
    // live. Requeuing a run this process is executing interrupts its turn, and
    // the next scheduler does it again: a live pilot run recorded 46 requeues in
    // eight minutes after a tech lead requested changes, and the sprint stopped
    // progressing entirely.
    let executingRunIDs = ticketDeliveryRuntimeCoordinator.executingRunIDs(
      productID: productID
    )

    let expiredPermissionRuns = sprintWorkRecoveryPolicy.runsWithExpiredPermissionDecisions(
      runs: runs.filter { $0.productID == productID },
      permissionRequests: permissionRequests.filter { $0.productID == productID }
    )
    var expiredPermissionRunIDs = Set(expiredPermissionRuns.map(\.id))
    for run in expiredPermissionRuns {
      let isImplementer = implementerByItemID[run.workItemID] == run.profileID
      let latestCandidate =
        storedCandidates
        .filter { $0.workItemID == run.workItemID }
        .max(by: { $0.version < $1.version })
      let canResumeConflict =
        !isImplementer && latestCandidate?.status == .resolvingConflict
      let canResumeReview =
        !isImplementer
        && latestCandidate.flatMap {
          sprintWorkRecoveryPolicy.latestReviewRun(
            for: $0,
            runs: runs,
            reviewerProfileIDs: reviewerProfileIDs
          )
        }?.id == run.id
      if canResumeReview {
        expiredPermissionRunIDs.remove(run.id)
        if run.status != .queued {
          _ = await performTicketDeliveryRecovery(
            productID: productID,
            workItemID: run.workItemID,
            store: store,
            mutations: [
              .updateRun(
                id: run.id,
                expectedStatuses: [run.status],
                status: .queued,
                eventDetail:
                  "Review capability request retired; read-only review queued to continue"
              ),
              .appendComment(
                body:
                  "The earlier tech lead permission request is no longer needed. Review will continue as a read-only inspection of the existing candidate and delivery evidence."
              ),
            ]
          )
        }
        continue
      }
      let canResume = isImplementer || canResumeConflict
      let latestRequest =
        permissionRequests
        .filter { $0.agentRunID == run.id }
        .max(by: { $0.updatedAt < $1.updatedAt })
      let hasSavedDecision = latestRequest?.status.isPendingDelivery == true
      let recoveredStatus: AgentRunStatus =
        if canResume && hasSavedDecision {
          .queued
        } else {
          canResume ? .awaitingOwner : .interrupted
        }
      let recoveryEventDetail: String
      let recoveryComment: String
      if hasSavedDecision {
        recoveryEventDetail = "Saved permission decision queued for recovery"
        recoveryComment =
          "Spedito recovered the saved permission decision without asking again. The preserved conversation and workspace are queued to continue, and the decision will be delivered if the agent requests the same capability again."
      } else if canResume {
        recoveryEventDetail =
          "Expired permission request remains paused for product owner input"
        recoveryComment =
          "The live permission request expired when Spedito stopped. The conversation and workspace are preserved, and the request remains above for your decision. Work will resume only after you choose Allow or Deny."
      } else {
        recoveryEventDetail = "Permission request expired when the app stopped"
        recoveryComment =
          "The previous permission request expired when Spedito stopped. This run cannot continue automatically."
      }
      if run.status != recoveredStatus {
        var mutations: [TicketDeliveryRecoveryMutation] = [
          .updateRun(
            id: run.id,
            expectedStatuses: [run.status],
            status: recoveredStatus,
            eventDetail: recoveryEventDetail
          )
        ]
        if canResume, !hasSavedDecision, let latestRequest {
          mutations.append(
            .updatePermissionRequest(
              id: latestRequest.id,
              expectedStatuses: [latestRequest.status],
              status: .interrupted
            )
          )
        }
        mutations.append(.appendComment(body: recoveryComment))
        _ = await performTicketDeliveryRecovery(
          productID: productID,
          workItemID: run.workItemID,
          store: store,
          mutations: mutations
        )
      }
    }
    for candidate in storedCandidates where candidate.status == .readyForDemo {
      guard
        let item = workItems.first(where: { $0.id == candidate.workItemID }),
        let implementationRun = runs.first(where: {
          $0.id == candidate.implementationRunID
        }),
        let assignee = profiles.first(where: { $0.id == implementationRun.profileID })
      else { continue }
      do {
        let result = try CodexTicketExecutor.decode(candidate.executionResultJSON)
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: result,
          assignee: assignee
        )
        let deliveryKind = try await validateDeliveryEvidence(
          result,
          assignee: assignee,
          workspaceURL: URL(
            fileURLWithPath: candidate.worktreePath,
            isDirectory: true
          )
        )
        guard deliveryKind == candidate.deliveryKind else {
          throw TicketExecutionGenerationError.invalidResponse(
            "The persisted candidate delivery kind no longer matches its evidence."
          )
        }
        switch item.state {
        case .integrating:
          _ = await performTicketDeliveryRecovery(
            productID: productID,
            workItemID: item.id,
            store: store,
            mutations: [
              .transitionWorkItem(
                id: item.id,
                expectedStates: [.integrating, .verifying],
                states: [.verifying, .acceptance],
                reasons: [
                  "Recovered the reviewed candidate after restart",
                  "Recovered the completed tech lead review",
                ]
              )
            ]
          )
        case .verifying:
          _ = await performTicketDeliveryRecovery(
            productID: productID,
            workItemID: item.id,
            store: store,
            mutations: [
              .transitionWorkItem(
                id: item.id,
                expectedStates: [.verifying],
                states: [.acceptance],
                reasons: ["Recovered the completed tech lead review"]
              )
            ]
          )
        default:
          break
        }
        continue
      } catch is TicketExecutionGenerationError {
        let recoveryComment =
          "Candidate v\(candidate.version) contained no inspectable ticket artefact or meaningful review evidence. I returned the preserved workspace to the assigned specialist to complete the actual delivery."
        do {
          if let integrationPath = candidate.integrationWorktreePath {
            try await gitWorkspaceManager.removeWorktree(
              repositoryURL: productWorkspaceURL(productID: productID),
              worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
            )
          }
          try await store.recoverInvalidReadyForDemoCandidate(
            candidateID: candidate.id,
            runEventDetail: "Empty candidate returned to the assigned specialist",
            transitionReason: "The candidate contained no inspectable delivery artefact",
            commentBody: recoveryComment
          )
        } catch {
          errorMessage =
            "Spedito could not safely recover candidate v\(candidate.version). No partial ticket transition was kept. Retry after checking the preserved workspace. \(error.localizedDescription)"
        }
      } catch {
        continue
      }
    }
    for run in runs
    where
      run.productID == productID
      && (run.status == .running || run.status == .failed)
      && implementerByItemID[run.workItemID] == run.profileID
      && !executingRunIDs.contains(run.id)
    {
      guard
        let threadID = run.codexThreadID,
        let workspacePath = run.worktreePath,
        let assignee = profiles.first(where: { $0.id == run.profileID }),
        product.id == productID,
        let productWorkspace = try? productWorkspaceURL(productID: productID)
      else { continue }
      let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
      guard
        let resumedThreadID = try? await client.resumeWorkspaceThread(
          threadID: threadID,
          workingDirectory: workspace,
          developerInstructions: CodexTicketExecutor.developerInstructions(
            productInstructions: inheritedAgentInstructions(for: product),
            customInstructions: assignee.customInstructionText,
            assignee: assignee,
            savedPermissionGrants: context.permissionGrants
          ),
          model: assignee.model,
          readOnlyGitDirectory: productWorkspace.appendingPathComponent(
            ".git",
            isDirectory: true
          )
        ),
        let response = try? await client.latestCompletedAgentMessage(
          threadID: resumedThreadID
        )
      else { continue }
      do {
        let result = try CodexTicketExecutor.decode(response)
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: result,
          assignee: assignee
        )
        let deliveryKind = try await validateDeliveryEvidence(
          result,
          assignee: assignee,
          workspaceURL: workspace
        )
        await processExecutionResult(
          result,
          deliveryKind: deliveryKind,
          implementationRunID: run.id,
          reviewCycle: 0,
          plan: plan
        )
      } catch {
        // Only a valid durable final response can supersede a stale run state.
      }
    }
    for run in runs
    where
      run.productID == productID
      && run.status == .running
      && !executingRunIDs.contains(run.id)
    {
      guard implementerByItemID[run.workItemID] == run.profileID else {
        let runCandidates = storedCandidates.filter {
          $0.workItemID == run.workItemID
        }
        if let candidate = runCandidates.max(by: { $0.version < $1.version }),
          candidate.status == .resolvingConflict
        {
          _ = await performTicketDeliveryRecovery(
            productID: productID,
            workItemID: run.workItemID,
            store: store,
            mutations: [
              .updateRun(
                id: run.id,
                expectedStatuses: [.running],
                status: .queued,
                eventDetail: "Interrupted integration queued to resume"
              )
            ]
          )
          continue
        }
        if let candidate = runCandidates.max(by: { $0.version < $1.version }),
          candidate.status == .reviewing,
          sprintWorkRecoveryPolicy.latestReviewRun(
            for: candidate,
            runs: runs,
            reviewerProfileIDs: reviewerProfileIDs
          )?.id == run.id
        {
          _ = await performTicketDeliveryRecovery(
            productID: productID,
            workItemID: run.workItemID,
            store: store,
            mutations: [
              .updateRun(
                id: run.id,
                expectedStatuses: [.running],
                status: .queued,
                eventDetail: "Interrupted tech lead review queued to continue"
              )
            ]
          )
          continue
        }
        _ = await performTicketDeliveryRecovery(
          productID: productID,
          workItemID: run.workItemID,
          store: store,
          mutations: [
            .updateRun(
              id: run.id,
              expectedStatuses: [.running],
              status: .interrupted,
              eventDetail: "Review interrupted when the app stopped"
            )
          ]
        )
        continue
      }

      var mutations: [TicketDeliveryRecoveryMutation] = []
      if let item = workItems.first(where: { $0.id == run.workItemID }) {
        switch item.state {
        case .verifying:
          mutations.append(
            .transitionWorkItem(
              id: item.id,
              expectedStates: [.verifying],
              states: [.running],
              reasons: ["Recovering an interrupted review"]
            )
          )
        case .integrating:
          mutations.append(
            .transitionWorkItem(
              id: item.id,
              expectedStates: [.integrating],
              states: [.running],
              reasons: ["Recovering an interrupted integration"]
            )
          )
        default:
          break
        }
      }
      let hasWorkspace = run.worktreePath.map {
        FileManager.default.fileExists(atPath: $0)
      } ?? false
      mutations.append(
        .updateRun(
          id: run.id,
          expectedStatuses: [.running],
          status: hasWorkspace ? .queued : .awaitingOwner,
          eventDetail: hasWorkspace
            ? "Interrupted work queued to resume from the existing workspace"
            : "Recovery stopped because the ticket workspace is missing"
        )
      )
      mutations.append(
        .appendComment(
          body: hasWorkspace
            ? "Recovery after restart: Spedito found the last durable delivery milestone and queued the same conversation and ticket workspace to continue."
            : "Recovery after restart needs your input: the ticket workspace recorded for this run is missing. Spedito preserved the conversation, work log, and run identity, but cannot resume delivery until the workspace is restored or you retry the work."
        )
      )
      _ = await performTicketDeliveryRecovery(
        productID: productID,
        workItemID: run.workItemID,
        store: store,
        mutations: mutations
      )
    }

    for candidate in storedCandidates where candidate.status == .integrating {
      do {
        if let integrationPath = candidate.integrationWorktreePath {
          try await gitWorkspaceManager.removeWorktree(
            repositoryURL: productWorkspaceURL(productID: productID),
            worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
          )
        }
      } catch {
        presentExecutionError(error, productID: productID)
        continue
      }
      var mutations: [TicketDeliveryRecoveryMutation] = [
        .updateCandidate(
          id: candidate.id,
          expectedStatuses: [.integrating],
          status: .queuedForIntegration
        )
      ]
      if let item = workItems.first(where: { $0.id == candidate.workItemID }),
        item.state == .running
      {
        mutations.append(
          .transitionWorkItem(
            id: item.id,
            expectedStates: [.running],
            states: [.integrating],
            reasons: ["Candidate restored to the integration queue"]
          )
        )
      }
      _ = await performTicketDeliveryRecovery(
        productID: productID,
        workItemID: candidate.workItemID,
        store: store,
        mutations: mutations
      )
    }

    for candidate in storedCandidates where candidate.status == .reviewing {
      guard
        let item = workItems.first(where: { $0.id == candidate.workItemID })
      else {
        continue
      }

      guard let integratedSHA = candidate.integratedSHA else {
        do {
          if let integrationPath = candidate.integrationWorktreePath {
            try await gitWorkspaceManager.removeWorktree(
              repositoryURL: productWorkspaceURL(productID: productID),
              worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
            )
          }
        } catch {
          presentExecutionError(error, productID: productID)
          continue
        }
        var mutations: [TicketDeliveryRecoveryMutation] = [
          .updateCandidate(
            id: candidate.id,
            expectedStatuses: [.reviewing],
            status: .queuedForIntegration
          )
        ]
        if let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: candidate,
          runs: runs,
          reviewerProfileIDs: reviewerProfileIDs
        ) {
          mutations.append(
            .updateRun(
              id: reviewRun.id,
              expectedStatuses: [reviewRun.status],
              status: .interrupted,
              eventDetail: "Review retired so integration can complete first"
            )
          )
        }
        switch item.state {
        case .verifying:
          mutations.append(
            .transitionWorkItem(
              id: item.id,
              expectedStates: [.verifying, .running],
              states: [.running, .integrating],
              reasons: [
                "Preparing the candidate for integration before review",
                "Candidate queued for integration before review",
              ]
            )
          )
        case .running:
          mutations.append(
            .transitionWorkItem(
              id: item.id,
              expectedStates: [.running],
              states: [.integrating],
              reasons: ["Candidate queued for integration before review"]
            )
          )
        default:
          break
        }
        mutations.append(
          .appendComment(
            body:
              "Spedito preserved this candidate and will integrate the latest accepted local and GitHub changes before restarting tech lead review."
          )
        )
        _ = await performTicketDeliveryRecovery(
          productID: productID,
          workItemID: item.id,
          store: store,
          mutations: mutations
        )
        continue
      }

      do {
        let repositoryURL = try productWorkspaceURL(productID: productID)
        let reviewWorkspace = try await gitWorkspaceManager.prepareIntegratedWorkspace(
          repositoryURL: repositoryURL,
          integrationsRootURL: integrationWorktreesRootURL(productID: productID),
          candidateID: candidate.id,
          candidateHeadSHA: candidate.headSHA,
          integratedSHA: integratedSHA
        )
        var mutations: [TicketDeliveryRecoveryMutation] = [
          .updateCandidate(
            id: candidate.id,
            expectedStatuses: [.reviewing],
            status: .reviewing,
            integratedSHA: integratedSHA,
            integrationWorktreePath: reviewWorkspace.url.path
          )
        ]
        switch item.state {
        case .running:
          mutations.append(
            .transitionWorkItem(
              id: item.id,
              expectedStates: [.running, .integrating],
              states: [.integrating, .verifying],
              reasons: [
                "Recovered the integrated review candidate",
                "Continuing tech lead review after restart",
              ]
            )
          )
        case .integrating:
          mutations.append(
            .transitionWorkItem(
              id: item.id,
              expectedStates: [.integrating],
              states: [.verifying],
              reasons: ["Continuing tech lead review after restart"]
            )
          )
        default:
          break
        }

        if let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: candidate,
          runs: runs,
          reviewerProfileIDs: reviewerProfileIDs
        ) {
          if expiredPermissionRunIDs.contains(reviewRun.id) {
            mutations.append(
              .updateRun(
                id: reviewRun.id,
                expectedStatuses: [reviewRun.status],
                status: .awaitingOwner,
                worktreePath: reviewWorkspace.url.path
              )
            )
          } else if reviewRun.status != .completed {
            mutations.append(
              .updateRun(
                id: reviewRun.id,
                expectedStatuses: [reviewRun.status],
                status: .queued,
                worktreePath: reviewWorkspace.url.path,
                eventDetail: "Tech lead review queued to continue against the same revision"
              )
            )
          }
        } else if let techLead = profiles.first(where: { $0.role == .lead }) {
          mutations.append(
            .createRunIfAbsent(
              AgentRun(
                productID: productID,
                sprintID: plan.sprint.id,
                sprintItemID: candidate.sprintItemID,
                workItemID: candidate.workItemID,
                profileID: techLead.id,
                status: .queued,
                worktreePath: reviewWorkspace.url.path
              ),
              notBefore: candidate.updatedAt
            )
          )
        }
        _ = await performTicketDeliveryRecovery(
          productID: productID,
          workItemID: item.id,
          store: store,
          mutations: mutations
        )
      } catch {
        await restoreCandidateToIntegrationQueue(
          candidate,
          context: context,
          reason:
            "The exact integrated revision could not be restored: \(error.localizedDescription)"
        )
      }
    }

    let latestCandidateByWorkItemID = Dictionary(
      grouping: storedCandidates,
      by: \.workItemID
    ).compactMapValues { candidates in
      candidates.max { $0.version < $1.version }
    }
    for run in runs
    where
      run.productID == productID
      && run.status == .awaitingOwner
      && implementerByItemID[run.workItemID] == run.profileID
    {
      guard
        let failedCandidate = latestCandidateByWorkItemID[run.workItemID],
        failedCandidate.status == .failed
      else {
        continue
      }
      let comments: [TicketComment]
      do {
        comments = try await store.fetchComments(workItemID: run.workItemID)
      } catch {
        presentExecutionError(error, productID: productID)
        continue
      }
      guard let latestSystemFailure = comments.last(where: { $0.authorKind == .system }) else {
        continue
      }
      let reviewContractFailed =
        latestSystemFailure.body.localizedCaseInsensitiveContains(
          "changes-requested reviews need at least one finding"
        )
        || latestSystemFailure.body.localizedCaseInsensitiveContains(
          "requested changes without identifying a concrete blocking finding"
        )
      if reviewContractFailed {
        var mutations: [TicketDeliveryRecoveryMutation] = [
          .updateRun(
            id: run.id,
            expectedStatuses: [.awaitingOwner],
            status: .completed,
            eventDetail: "Implementation preserved; malformed review queued to retry"
          ),
          .updateCandidate(
            id: failedCandidate.id,
            expectedStatuses: [.failed],
            status: .queuedForIntegration
          ),
        ]
        if let item = workItems.first(where: { $0.id == run.workItemID }),
          item.state == .running
        {
          mutations.append(
            .transitionWorkItem(
              id: item.id,
              expectedStates: [.running],
              states: [.integrating],
              reasons: [
                "Retrying a malformed tech lead review against the preserved candidate"
              ]
            )
          )
        }
        mutations.append(
          .appendComment(
            body:
              "The implementation was valid; the tech lead’s structured response was malformed. Candidate v\(failedCandidate.version) has been preserved and queued for integration and review again without repeating the delivery work."
          )
        )
        _ = await performTicketDeliveryRecovery(
          productID: productID,
          workItemID: run.workItemID,
          store: store,
          mutations: mutations
        )
        continue
      }
      guard latestSystemFailure.body.localizedCaseInsensitiveContains("thread not found")
      else { continue }
      _ = await performTicketDeliveryRecovery(
        productID: productID,
        workItemID: run.workItemID,
        store: store,
        mutations: [
          .updateRun(
            id: run.id,
            expectedStatuses: [.awaitingOwner],
            status: .queued,
            eventDetail: "Transient Codex session failure queued to recover automatically"
          ),
          .appendComment(
            body:
              "The previous failure was caused by an expired Codex session rather than the ticket work. Recovery has been queued automatically in the preserved workspace."
          ),
        ]
      )
    }

    if let techLead = profiles.first(where: { $0.role == .lead }) {
      for candidate in storedCandidates where candidate.status == .resolvingConflict {
        let candidateRuns = runs.filter {
          $0.workItemID == candidate.workItemID && $0.profileID == techLead.id
        }
        if let latest = candidateRuns.max(by: { $0.createdAt < $1.createdAt }) {
          if expiredPermissionRunIDs.contains(latest.id) {
            _ = await performTicketDeliveryRecovery(
              productID: productID,
              workItemID: candidate.workItemID,
              store: store,
              mutations: [
                .updateRun(
                  id: latest.id,
                  expectedStatuses: [latest.status],
                  status: .awaitingOwner
                )
              ]
            )
          } else if latest.status == .interrupted || latest.status == .failed {
            _ = await performTicketDeliveryRecovery(
              productID: productID,
              workItemID: candidate.workItemID,
              store: store,
              mutations: [
                .updateRun(
                  id: latest.id,
                  expectedStatuses: [.interrupted, .failed],
                  status: .queued,
                  eventDetail: "Interrupted conflict resolution queued to resume"
                )
              ]
            )
          }
        } else if let worktreePath = candidate.integrationWorktreePath {
          _ = await performTicketDeliveryRecovery(
            productID: productID,
            workItemID: candidate.workItemID,
            store: store,
            mutations: [
              .createRunIfAbsent(
                AgentRun(
                  productID: productID,
                  sprintID: plan.sprint.id,
                  sprintItemID: candidate.sprintItemID,
                  workItemID: candidate.workItemID,
                  profileID: techLead.id,
                  status: .queued,
                  worktreePath: worktreePath
                ),
                notBefore: candidate.updatedAt
              )
            ]
          )
        }
      }
    }
  }

  private func restoreCandidateToIntegrationQueue(
    _ candidate: CandidateRevision,
    context: TicketDeliveryWorkflowContext,
    reason: String
  ) async {
    let productID = context.product.id
    guard let store = store(for: productID) else { return }
    do {
      if let integrationPath = candidate.integrationWorktreePath {
        try await gitWorkspaceManager.removeWorktree(
          repositoryURL: productWorkspaceURL(productID: productID),
          worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
        )
      }
    } catch {
      presentExecutionError(error, productID: productID)
      return
    }
    var mutations: [TicketDeliveryRecoveryMutation] = [
      .updateCandidate(
        id: candidate.id,
        expectedStatuses: [.reviewing],
        status: .queuedForIntegration
      )
    ]
    let reviewerProfileIDs = Set(
      context.profiles
        .filter { $0.role == .lead }
        .map(\.id)
    )
    if let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
      for: candidate,
      runs: context.runs,
      reviewerProfileIDs: reviewerProfileIDs
    ), reviewRun.status != .completed {
      mutations.append(
        .updateRun(
          id: reviewRun.id,
          expectedStatuses: [reviewRun.status],
          status: .interrupted,
          eventDetail: "The exact review workspace could not be recovered"
        )
      )
    }
    if let item = context.workItems.first(where: { $0.id == candidate.workItemID }) {
      switch item.state {
      case .verifying:
        mutations.append(
          .transitionWorkItem(
            id: item.id,
            expectedStates: [.verifying, .running],
            states: [.running, .integrating],
            reasons: [
              "The exact reviewed revision could not be recovered",
              "Candidate restored to the integration queue",
            ]
          )
        )
      case .running:
        mutations.append(
          .transitionWorkItem(
            id: item.id,
            expectedStates: [.running],
            states: [.integrating],
            reasons: ["Candidate restored to the integration queue"]
          )
        )
      default:
        break
      }
    }
    mutations.append(
      .appendComment(
        body:
          "\(reason)\n\nCandidate v\(candidate.version) will be integrated and reviewed again so the product owner never receives an unverified revision."
      )
    )
    _ = await performTicketDeliveryRecovery(
      productID: productID,
      workItemID: candidate.workItemID,
      store: store,
      mutations: mutations
    )
  }
  public func suspendSprintExecution(productID: UUID? = nil) async {
    let liveRunIDs =
      ticketDeliveryRuntimeCoordinator.liveActivityRunIDs(productID: productID)
    await ticketDeliveryRuntimeCoordinator.cancel(productID: productID) { [weak self] in
      guard let self, let client = self.codexClient else { return }
      let turns = self.ticketDeliveryRuntimeCoordinator.activeTurns(productID: productID)
      await withTaskGroup(of: Void.self) { group in
        for turn in turns {
          group.addTask {
            try? await client.interruptTurn(
              threadID: turn.threadID,
              turnID: turn.turnID
            )
          }
        }
      }
    }
    let approvalRequestIDs =
      ticketDeliveryRuntimeCoordinator.liveApprovalRequestIDs(productID: productID)
    for requestID in approvalRequestIDs {
      guard
        let requestProductID =
          ticketDeliveryRuntimeCoordinator.liveApprovalRequestProductID(id: requestID),
        let requestStore = store(for: requestProductID)
      else { continue }
      if let updated = try? await requestStore.updateAgentPermissionRequest(
        id: requestID,
        status: .interrupted
      ) {
        delegate?.deliveryReplacePermissionRequest(updated)
      }
    }
    for requestID in approvalRequestIDs {
      ticketDeliveryRuntimeCoordinator.removeLiveApprovalRequest(id: requestID)
    }
    for runID in liveRunIDs {
      stopLiveActivityMonitoring(runID: runID)
    }
  }
  public func stopAgentRun(_ run: AgentRun) async {
    guard
      run.status == .running,
      let client = codexClient,
      let turn = ticketDeliveryRuntimeCoordinator.activeTurn(runID: run.id)
    else { return }
    ticketDeliveryRuntimeCoordinator.markManuallyStopped(runID: run.id)
    do {
      try await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
      stopLiveActivityMonitoring(runID: run.id)
      _ = try await updateAgentRun(
        id: run.id,
        status: .interrupted,
        eventActor: "Product owner",
        eventDetail: "Stopped manually; ticket workspace preserved"
      )
      await reloadSelectedProductIfCurrent(productID: run.productID)
    } catch {
      ticketDeliveryRuntimeCoordinator.clearManuallyStopped(runID: run.id)
      errorMessage = error.localizedDescription
    }
  }
  public func retryFailedPostReviewDemo(productID: UUID, workItemID: UUID) async -> Bool {
    guard let context = await context(productID: productID) else { return false }
    let runs = context.runs
    let profiles = context.profiles

    guard
      let recoverableCandidate = sprintWorkRecoveryPolicy.failedPostReviewDemoCandidate(
        workItemID: workItemID,
        workItems: context.workItems,
        candidates: context.candidates,
        runs: runs,
        profiles: profiles
      ),
      let integratedSHA = recoverableCandidate.integratedSHA,
      let implementationRun = runs.first(where: {
        $0.id == recoverableCandidate.implementationRunID
      }),
      let result = try? CodexTicketExecutor.decode(
        recoverableCandidate.executionResultJSON
      ),
      let specification = result.demo,
      let store = store(for: recoverableCandidate.productID)
    else {
      return false
    }

    let reviewerName =
      profiles.first { profile in
        guard profile.role == .lead else { return false }
        return runs.contains {
          $0.workItemID == workItemID
            && $0.profileID == profile.id
            && $0.status == .completed
            && $0.worktreePath == recoverableCandidate.integrationWorktreePath
        }
      }?.name ?? "Tech lead"

    do {
      let candidate = try await store.fetchCandidateRevision(
        id: recoverableCandidate.id
      )
      guard
        candidate.status == .failed,
        let item = try await store.fetchWorkItems(productID: candidate.productID)
          .first(where: { $0.id == workItemID }),
        item.state == .running
      else {
        return false
      }

      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .reviewing
      )
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .running,
        eventActor: "Spedito",
        eventDetail: "Retrying demo preparation for the reviewed candidate"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .integrating,
        actor: "Spedito",
        reason: "Retrying the reviewed candidate handoff"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .verifying,
        actor: "Spedito",
        reason: "Re-running demo preparation against the reviewed revision"
      )
      await reloadSelectedProductIfCurrent(productID: recoverableCandidate.productID)
      let ticketPublication = try await prepareTicketPullRequestIfConnected(
        productID: candidate.productID,
        workItemID: item.id,
        candidateRevisionID: candidate.id
      )

      try await prepareDemoForAcceptance(
        candidate: candidate,
        integratedSHA: integratedSHA,
        specification: specification
      )
      _ = try await store.updateCandidateRevision(
        id: candidate.id,
        status: .readyForDemo
      )
      try await markTicketPullRequestReadyIfNeeded(ticketPublication)
      _ = try await updateAgentRun(
        id: implementationRun.id,
        status: .completed,
        eventActor: "Spedito",
        eventDetail: "Demo preparation succeeded on retry"
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .acceptance,
        actor: reviewerName,
        reason: "Reviewed candidate prepared successfully for product owner demo"
      )
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Demo preparation succeeded on retry. The already reviewed candidate was preserved; implementation and tech lead review were not repeated."
      )
      await reloadSelectedProductIfCurrent(productID: recoverableCandidate.productID)
      return true
    } catch {
      if demoPreparationShouldCorrectCandidate(error),
        let item = try? await store.fetchWorkItems(
          productID: recoverableCandidate.productID
        ).first(where: { $0.id == workItemID })
      {
        do {
          try await returnDemoFailureForCorrection(
            candidateID: recoverableCandidate.id,
            implementationRun: implementationRun,
            workItem: item,
            error: error
          )
          return true
        } catch {
          errorMessage = error.localizedDescription
        }
      }
      _ = try? await store.updateCandidateRevision(
        id: recoverableCandidate.id,
        status: .failed
      )
      _ = try? await updateAgentRun(
        id: implementationRun.id,
        status: .awaitingOwner,
        eventActor: "Spedito",
        eventDetail: "Demo preparation retry could not complete"
      )
      if let item = try? await store.fetchWorkItems(
        productID: recoverableCandidate.productID
      ).first(where: { $0.id == workItemID }),
        item.state == .integrating || item.state == .verifying
      {
        _ = try? await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: "Spedito",
          reason: "Demo preparation retry stopped; preserving the reviewed candidate"
        )
      }
      _ = try? await store.appendComment(
        workItemID: workItemID,
        authorKind: .system,
        authorName: "Spedito",
        body:
          "Demo preparation stopped unexpectedly again: \(error.localizedDescription)\n\nChoose Retry demo preparation to try the preserved reviewed candidate again."
      )
      errorMessage = error.localizedDescription
      await reloadSelectedProductIfCurrent(productID: recoverableCandidate.productID)
      return false
    }
  }
  public func handleSprintOwnerComment(
    productID: UUID,
    workItemID: UUID,
    body: String,
    actor: String = "Product owner",
    reasonPrefix: String = "Demo feedback"
  ) async {
    guard
      let store = store(for: productID),
      let plan = try? await store.fetchCurrentSprint(productID: productID),
      plan.sprint.state == .active,
      let sprintItem = plan.items.first(where: { $0.workItemID == workItemID }),
      let implementerID = sprintItem.implementerProfileID
    else { return }

    do {
      let currentItems = try await store.fetchWorkItems(productID: productID)
      guard let item = currentItems.first(where: { $0.id == workItemID }) else { return }
      let currentRuns = try await store.fetchAgentRuns(productID: productID)
      let currentCandidates = try await store.fetchCandidateRevisions(
        productID: productID
      )
      let productProfiles = try await store.fetchAgentProfiles(productID: productID)
      let reviewerProfileIDs = Set(
        productProfiles
          .filter { $0.role == .lead }
          .map(\.id)
      )
      if let reviewingCandidate =
        currentCandidates
        .filter({
          $0.workItemID == workItemID && $0.status == .reviewing
        })
        .max(by: { $0.version < $1.version }),
        let reviewRun = sprintWorkRecoveryPolicy.latestReviewRun(
          for: reviewingCandidate,
          runs: currentRuns,
          reviewerProfileIDs: reviewerProfileIDs
        ),
        reviewRun.status == .interrupted
      {
        _ = try await updateAgentRun(
          id: reviewRun.id,
          status: .queued,
          eventActor: "Product owner",
          eventDetail: "Retry requested; tech lead review queued to continue"
        )
        await reloadSelectedProductIfCurrent(productID: productID)
        scheduleSprintExecution(productID: productID)
        return
      }
      if currentCandidates.contains(where: {
        $0.workItemID == workItemID && $0.status == .resolvingConflict
      }) {
        let techLeadID = productProfiles.first(where: { $0.role == .lead })?.id
        let resolutionRuns = currentRuns.filter {
          $0.workItemID == workItemID
            && $0.profileID == techLeadID
            && $0.status == .awaitingOwner
        }
        if let resolutionRun = resolutionRuns.max(by: { $0.createdAt < $1.createdAt }) {
          _ = try await updateAgentRun(
            id: resolutionRun.id,
            status: .queued,
            eventActor: "Product owner",
            eventDetail: "Response received; integration queued to resume"
          )
          await reloadSelectedProductIfCurrent(productID: productID)
          scheduleSprintExecution(productID: productID)
          return
        }
      }
      let matchingRuns = currentRuns.filter {
        $0.workItemID == workItemID && $0.profileID == implementerID
      }
      guard
        let implementationRun = matchingRuns.max(by: { $0.createdAt < $1.createdAt }),
        implementationRun.codexThreadID != nil
      else { return }

      if implementationRun.status == .awaitingOwner {
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Product owner",
          eventDetail: "Response received; work queued to resume"
        )
      } else if implementationRun.status == .failed || implementationRun.status == .interrupted,
        item.state == .running
      {
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: "Product owner",
          eventDetail: "Retry requested; preserved work queued to resume"
        )
      } else if item.state == .acceptance {
        if let remoteState = await remoteRepositoryState(productID: productID),
          let publication = remoteState.publications.first(where: {
            $0.workItemID == workItemID && $0.status.isActive
              && $0.pullRequest?.state == .open && $0.pullRequest?.isDraft == false
          })
        {
          try await returnTicketPullRequestToDraft(
            publicationID: publication.id,
            productID: productID
          )
        }
        let readyCandidates = currentCandidates.filter { candidate in
          candidate.workItemID == item.id && candidate.status == .readyForDemo
        }
        if let candidate = readyCandidates.max(by: { $0.version < $1.version }) {
          await stopDemoSession(candidate, removesPreview: true)
          if candidate.deliveryKind.changesRepository {
            guard let integratedSHA = candidate.integratedSHA else {
              throw PersistenceError.corruptData(
                "The reviewed demo candidate has no integrated revision."
              )
            }
            _ = try await adoptIntegratedBaselineForRevision(
              candidate: candidate,
              integratedSHA: integratedSHA
            )
          }
          _ = try await store.updateCandidateRevision(
            id: candidate.id,
            status: .superseded
          )
          try await store.markKnowledgePageProposals(
            candidateRevisionID: candidate.id,
            status: .superseded
          )
          if let integrationPath = candidate.integrationWorktreePath {
            try? await gitWorkspaceManager.removeWorktree(
              repositoryURL: productWorkspaceURL(productID: item.productID),
              worktreeURL: URL(fileURLWithPath: integrationPath, isDirectory: true)
            )
          }
        }
        _ = try await store.transitionWorkItem(
          id: item.id,
          to: .running,
          actor: actor,
          reason: "\(reasonPrefix): \(body.prefix(160))"
        )
        _ = try await updateAgentRun(
          id: implementationRun.id,
          status: .queued,
          eventActor: actor,
          eventDetail: "\(reasonPrefix) received; work queued to resume"
        )
      } else {
        return
      }
      await reloadSelectedProductIfCurrent(productID: productID)
      scheduleSprintExecution(productID: productID)
    } catch {
      presentExecutionError(error, productID: productID)
    }
  }
}
