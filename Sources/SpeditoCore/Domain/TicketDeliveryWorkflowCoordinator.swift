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
  func deliveryFinalizeReviewedIntegration(
    candidateID: UUID,
    implementation: TicketExecutionResult,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws
  func deliveryFinalizeReviewedLocalOutcome(
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws
  func deliveryAdoptIntegratedBaselineForRevision(
    candidate: CandidateRevision,
    integratedSHA: String
  ) async throws -> TicketRevisionBaseline
}

@MainActor
public final class TicketDeliveryWorkflowCoordinator {
  private weak var delegate: (any TicketDeliveryWorkflowDelegate)?
  private let gitWorkspaceManager: GitWorkspaceManager
  private let runtimeCoordinator: TicketDeliveryRuntimeCoordinator
  private let recoveryPolicy: SprintWorkRecoveryPolicy

  public init(
    delegate: any TicketDeliveryWorkflowDelegate,
    gitWorkspaceManager: GitWorkspaceManager,
    runtimeCoordinator: TicketDeliveryRuntimeCoordinator,
    recoveryPolicy: SprintWorkRecoveryPolicy
  ) {
    self.delegate = delegate
    self.gitWorkspaceManager = gitWorkspaceManager
    self.runtimeCoordinator = runtimeCoordinator
    self.recoveryPolicy = recoveryPolicy
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

  private func finalizeReviewedIntegration(
    candidateID: UUID,
    implementation: TicketExecutionResult,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    guard let delegate else { throw CodexClientError.notConnected }
    try await delegate.deliveryFinalizeReviewedIntegration(
      candidateID: candidateID,
      implementation: implementation,
      implementationRun: implementationRun,
      workItem: workItem,
      reviewerName: reviewerName
    )
  }

  private func finalizeReviewedLocalOutcome(
    candidate: CandidateRevision,
    implementationRun: AgentRun,
    workItem: WorkItem,
    reviewerName: String
  ) async throws {
    guard let delegate else { throw CodexClientError.notConnected }
    try await delegate.deliveryFinalizeReviewedLocalOutcome(
      candidate: candidate,
      implementationRun: implementationRun,
      workItem: workItem,
      reviewerName: reviewerName
    )
  }

  private func adoptIntegratedBaselineForRevision(
    candidate: CandidateRevision,
    integratedSHA: String
  ) async throws -> TicketRevisionBaseline {
    guard let delegate else { throw CodexClientError.notConnected }
    return try await delegate.deliveryAdoptIntegratedBaselineForRevision(
      candidate: candidate,
      integratedSHA: integratedSHA
    )
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
    do {
      let result = try CodexTicketExecutor.decode(response)
      try CodexTicketExecutor.validateKnowledgePageProposals(
        in: result,
        canonicalPages: canonicalKnowledgePages
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
        initialText: "Completing the missing delivery evidence…"
      )
      do {
        let repairedResponse = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: repairTurnID,
          timeout: .seconds(900)
        )
        stopLiveActivityMonitoring(runID: runID)
        ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: runID)
        let repairedResult = try CodexTicketExecutor.decode(repairedResponse)
        try CodexTicketExecutor.validateKnowledgePageProposals(
          in: repairedResult,
          canonicalPages: canonicalKnowledgePages
        )
        try CodexTicketExecutor.validateFollowUpTicketProposals(
          in: repairedResult,
          assignee: assignee
        )
        let deliveryKind = try await validateDeliveryEvidence(
          repairedResult,
          assignee: assignee,
          workspaceURL: workspaceURL
        )
        return (repairedResult, deliveryKind)
      } catch {
        stopLiveActivityMonitoring(runID: runID)
        ticketDeliveryRuntimeCoordinator.removeActiveTurn(runID: runID)
        throw error
      }
    }
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

    _ = try? await store.appendComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: assignee.name,
      body: result.workLogComment,
      ownerQuestion:
        result.status == .awaitingOwner
        ? result.question.map {
          TicketOwnerQuestion(
            prompt: $0,
            options: result.options,
            decisionArtifact: result.decisionArtifact
          )
        }
        : nil
    )

    if result.status == .completed {
      try? await store.saveRetrospectiveNotes(
        makeRetrospectiveNotes(
          productID: item.productID,
          sprintID: plan.sprint.id,
          workItemID: item.id,
          profile: assignee,
          wentWell: result.retrospectiveWentWell,
          couldImprove: result.retrospectiveCouldImprove,
          actions: result.retrospectiveActions
        )
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
        let deliveryNote = deliveryNoteMarkdown(
          item: item,
          result: result,
          authorName: assignee.name
        )
        _ = try await store.upsertDeliveryNote(
          productID: item.productID,
          sprint: plan.sprint,
          item: item,
          bodyMarkdown: deliveryNote,
          authorName: assignee.name
        )

        let version = try await store.nextCandidateRevisionVersion(workItemID: item.id)
        let workspaceURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let snapshot =
          if deliveryKind.changesRepository {
            try await gitWorkspaceManager.createCandidate(
              ticketWorkspaceURL: workspaceURL,
              ticketKey: item.key,
              version: version,
              authorName: assignee.name,
              summary: result.summary
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
        let candidate = try await store.createCandidateRevision(
          CandidateRevision(
            productID: item.productID,
            sprintID: plan.sprint.id,
            sprintItemID: sprintItemID,
            workItemID: item.id,
            implementationRunID: run.id,
            version: version,
            deliveryKind: deliveryKind,
            branchName: snapshot.branchName,
            baseSHA: snapshot.baseSHA,
            headSHA: snapshot.headSHA,
            worktreePath: worktreePath,
            commitCount: snapshot.commitCount,
            executionResultJSON: resultJSON
          )
        )
        let proposals = try await makeKnowledgePageProposals(
          drafts: result.knowledgePageProposals,
          candidate: candidate,
          runID: run.id
        )
        try await store.createKnowledgePageProposals(proposals)
        let currentState = (try await store.fetchWorkItems(productID: item.productID))
          .first { $0.id == item.id }?.state
        if currentState == .running {
          _ = try await store.transitionWorkItem(
            id: item.id,
            to: .integrating,
            actor: assignee.name,
            reason: deliveryKind.changesRepository
              ? "Candidate v\(candidate.version) queued for integration"
              : "Outcome v\(candidate.version) queued for review"
          )
        }
        _ = try await updateAgentRun(
          id: run.id,
          status: .completed,
          eventActor: assignee.name,
          eventDetail: deliveryKind.changesRepository
            ? "Candidate v\(candidate.version) queued for integration"
            : "Outcome v\(candidate.version) queued for review"
        )
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
      if let integrationPath = candidate.integrationWorktreePath {
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
      if let failedCandidate = try? await store.fetchCandidateRevision(id: candidate.id),
        let integrationPath = failedCandidate.integrationWorktreePath
      {
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
}
