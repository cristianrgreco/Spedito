import Foundation

public enum PlanningDropConstraint: Equatable, Sendable {
  case sprintScope
  case rank
  case unavailable
}

public enum PlanningDropRankAction: Equatable, Sendable {
  case preserve
  case move(before: UUID?)
}

public struct PlanningDropEvaluation: Equatable, Sendable {
  public let rankAction: PlanningDropRankAction?
  public let blockingConstraint: PlanningDropConstraint?
  public let message: String?

  public var isValid: Bool {
    blockingConstraint == nil
  }

  public static func valid(_ rankAction: PlanningDropRankAction) -> Self {
    PlanningDropEvaluation(
      rankAction: rankAction,
      blockingConstraint: nil,
      message: nil
    )
  }

  public static func invalid(
    _ constraint: PlanningDropConstraint,
    message: String
  ) -> Self {
    PlanningDropEvaluation(
      rankAction: nil,
      blockingConstraint: constraint,
      message: message
    )
  }
}

public struct PlanningDropPolicy {
  private static let planningStates: Set<WorkItemState> = [
    .backlog,
    .refining,
    .ready,
  ]

  public static func evaluate(
    workItems: [WorkItem],
    dependencies: [WorkItemDependency],
    candidateIDs: Set<UUID>,
    externalCandidatePrerequisiteIDs: Set<UUID>,
    movingIDs requestedMovingIDs: Set<UUID>,
    intoCandidateSprint: Bool,
    before requestedTargetID: UUID?
  ) -> PlanningDropEvaluation {
    let planningItems = workItems.filter { planningStates.contains($0.state) }
    let planningIDs = Set(planningItems.map(\.id))
    let movingIDs = requestedMovingIDs.intersection(planningIDs)
    guard !movingIDs.isEmpty, movingIDs == requestedMovingIDs else {
      return .invalid(
        .unavailable,
        message: "These tickets are no longer available for planning"
      )
    }

    let desiredCandidateIDs =
      intoCandidateSprint
      ? candidateIDs.union(movingIDs)
      : candidateIDs.subtracting(movingIDs)
    let availableCandidateIDs =
      desiredCandidateIDs.union(externalCandidatePrerequisiteIDs)
    let itemsByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    let sortedDependencies = dependencies.sorted { lhs, rhs in
      let lhsDependent = itemsByID[lhs.workItemID]
      let rhsDependent = itemsByID[rhs.workItemID]
      if lhsDependent?.rank != rhsDependent?.rank {
        return (lhsDependent?.rank ?? .max) < (rhsDependent?.rank ?? .max)
      }
      if lhsDependent?.key != rhsDependent?.key {
        return (lhsDependent?.key ?? "") < (rhsDependent?.key ?? "")
      }
      return (itemsByID[lhs.dependsOnWorkItemID]?.key ?? "")
        < (itemsByID[rhs.dependsOnWorkItemID]?.key ?? "")
    }

    if let edge = sortedDependencies.first(where: {
      desiredCandidateIDs.contains($0.workItemID)
        && !availableCandidateIDs.contains($0.dependsOnWorkItemID)
    }) {
      let dependentKey = itemsByID[edge.workItemID]?.key ?? "The dependant ticket"
      let prerequisiteKey =
        itemsByID[edge.dependsOnWorkItemID]?.key ?? "its prerequisite"
      let message =
        intoCandidateSprint
        ? "Move \(prerequisiteKey) too; \(dependentKey) depends on it"
        : "Move \(dependentKey) too; it depends on \(prerequisiteKey)"
      return .invalid(.sprintScope, message: message)
    }

    let nonMovingDestinationItems = planningItems.filter { item in
      !movingIDs.contains(item.id)
        && desiredCandidateIDs.contains(item.id) == intoCandidateSprint
    }
    if let requestedTargetID,
      !nonMovingDestinationItems.contains(where: { $0.id == requestedTargetID })
    {
      return .invalid(
        .unavailable,
        message: "That drop position is no longer available"
      )
    }

    let movingItems = planningItems.filter { movingIDs.contains($0.id) }
    var desiredDestinationIDs = nonMovingDestinationItems.map(\.id)
    let destinationInsertionIndex =
      requestedTargetID.flatMap { targetID in
        desiredDestinationIDs.firstIndex(of: targetID)
      } ?? desiredDestinationIDs.endIndex
    desiredDestinationIDs.insert(
      contentsOf: movingItems.map(\.id),
      at: destinationInsertionIndex
    )

    let currentDestinationIDs = planningItems.compactMap { item -> UUID? in
      guard desiredCandidateIDs.contains(item.id) == intoCandidateSprint else {
        return nil
      }
      return item.id
    }

    let rankAction: PlanningDropRankAction
    if currentDestinationIDs == desiredDestinationIDs {
      rankAction = .preserve
    } else if let requestedTargetID {
      rankAction = .move(before: requestedTargetID)
    } else if let lastDestinationID = nonMovingDestinationItems.last?.id {
      let remainingItems = planningItems.filter { !movingIDs.contains($0.id) }
      let lastDestinationIndex = remainingItems.firstIndex {
        $0.id == lastDestinationID
      }
      let anchorID = lastDestinationIndex.flatMap { index in
        remainingItems.dropFirst(index + 1).first?.id
      }
      rankAction = .move(before: anchorID)
    } else {
      rankAction = .preserve
    }

    let reorderedItems: [WorkItem]
    switch rankAction {
    case .preserve:
      reorderedItems = planningItems
    case .move(let targetID):
      var remainingItems = planningItems.filter { !movingIDs.contains($0.id) }
      let insertionIndex =
        targetID.flatMap { targetID in
          remainingItems.firstIndex(where: { $0.id == targetID })
        } ?? remainingItems.endIndex
      remainingItems.insert(contentsOf: movingItems, at: insertionIndex)
      reorderedItems = remainingItems
    }

    let positions = Dictionary(
      uniqueKeysWithValues: reorderedItems.enumerated().map { ($0.element.id, $0.offset) }
    )
    if let invalidEdge = sortedDependencies.first(where: { edge in
      guard
        let dependentPosition = positions[edge.workItemID],
        let prerequisitePosition = positions[edge.dependsOnWorkItemID]
      else { return false }
      return dependentPosition < prerequisitePosition
    }) {
      let dependentKey = itemsByID[invalidEdge.workItemID]?.key ?? "The dependant ticket"
      let prerequisiteKey =
        itemsByID[invalidEdge.dependsOnWorkItemID]?.key ?? "its prerequisite"
      let message =
        movingIDs.contains(invalidEdge.dependsOnWorkItemID)
          && !movingIDs.contains(invalidEdge.workItemID)
        ? "Place \(prerequisiteKey) above \(dependentKey)"
        : "Place \(dependentKey) below \(prerequisiteKey)"
      return .invalid(.rank, message: message)
    }

    return .valid(rankAction)
  }
}

public struct SprintPlanningWorkflowSnapshot: Equatable, Sendable {
  public var isSendingMessage: Bool
  public var isGeneratingGoal: Bool
  public var readinessIssues: [SprintReadinessIssue]

  public init(
    isSendingMessage: Bool = false,
    isGeneratingGoal: Bool = false,
    readinessIssues: [SprintReadinessIssue] = []
  ) {
    self.isSendingMessage = isSendingMessage
    self.isGeneratingGoal = isGeneratingGoal
    self.readinessIssues = readinessIssues
  }
}

public struct SprintPlanningWorkflowAvailability: Equatable, Sendable {
  public let isSuggestionGenerationRunning: Bool
  public let isTicketConversationRunning: Bool
  public let isEpicConversationRunning: Bool
  public let refiningWorkItemID: UUID?
  public let isEpicPlanningRunning: Bool
  public let isEpicPlanGenerating: Bool

  public init(
    isSuggestionGenerationRunning: Bool,
    isTicketConversationRunning: Bool,
    isEpicConversationRunning: Bool,
    refiningWorkItemID: UUID?,
    isEpicPlanningRunning: Bool,
    isEpicPlanGenerating: Bool
  ) {
    self.isSuggestionGenerationRunning = isSuggestionGenerationRunning
    self.isTicketConversationRunning = isTicketConversationRunning
    self.isEpicConversationRunning = isEpicConversationRunning
    self.refiningWorkItemID = refiningWorkItemID
    self.isEpicPlanningRunning = isEpicPlanningRunning
    self.isEpicPlanGenerating = isEpicPlanGenerating
  }
}

public struct SprintPlanningWorkflowContext: Sendable {
  public let product: Product?
  public let workItems: [WorkItem]
  public let dependencies: [WorkItemDependency]
  public let profiles: [AgentProfile]
  public let sprintPlan: SprintPlan?
  public let sprintHistory: [SprintPlan]
  public let modelOptions: [CodexModelOption]

  public init(
    product: Product?,
    workItems: [WorkItem],
    dependencies: [WorkItemDependency],
    profiles: [AgentProfile],
    sprintPlan: SprintPlan?,
    sprintHistory: [SprintPlan],
    modelOptions: [CodexModelOption]
  ) {
    self.product = product
    self.workItems = workItems
    self.dependencies = dependencies
    self.profiles = profiles
    self.sprintPlan = sprintPlan
    self.sprintHistory = sprintHistory
    self.modelOptions = modelOptions
  }
}

@MainActor
public final class SprintPlanningWorkflowCoordinator {
  private enum Operation: Hashable {
    case conversation
    case goal
    case interruption
    case mutation(UUID)
  }

  private struct ConversationKey: Hashable {
    let workItemID: UUID
    let profileID: UUID
  }

  private let storeProvider: (UUID) -> SQLiteStore?
  private let clientProvider: () -> CodexAppServerClient?
  private let selectedProductID: () -> UUID?
  private let contextProvider: (UUID) -> SprintPlanningWorkflowContext?
  private let availabilityProvider: () -> SprintPlanningWorkflowAvailability
  private let workspaceURLProvider: (UUID) throws -> URL
  private let inheritedInstructions: (Product) -> String
  private let onReloadActivity: (UUID) async throws -> Void
  private let onReloadSelectedProduct: (UUID) async -> Void
  private let onScheduleSprintExecution: (UUID) -> Void
  private let onError: (Error, UUID) -> Void
  private let onErrorMessage: (String, UUID) -> Void
  private let onSnapshotChange: (SprintPlanningWorkflowSnapshot) -> Void
  private let operations: FeatureOperationRegistry<Operation>
  private var planningThreadIDs: [ConversationKey: String]
  private var isConversationInterruptionPending: Bool

  public private(set) var snapshot: SprintPlanningWorkflowSnapshot

  public init(
    storeProvider: @escaping (UUID) -> SQLiteStore?,
    clientProvider: @escaping () -> CodexAppServerClient?,
    selectedProductID: @escaping () -> UUID?,
    contextProvider: @escaping (UUID) -> SprintPlanningWorkflowContext?,
    availabilityProvider: @escaping () -> SprintPlanningWorkflowAvailability,
    workspaceURLProvider: @escaping (UUID) throws -> URL,
    inheritedInstructions: @escaping (Product) -> String,
    onReloadActivity: @escaping (UUID) async throws -> Void,
    onReloadSelectedProduct: @escaping (UUID) async -> Void,
    onScheduleSprintExecution: @escaping (UUID) -> Void,
    onError: @escaping (Error, UUID) -> Void,
    onErrorMessage: @escaping (String, UUID) -> Void,
    onSnapshotChange: @escaping (SprintPlanningWorkflowSnapshot) -> Void
  ) {
    operations = FeatureOperationRegistry<Operation>()
    planningThreadIDs = [:]
    isConversationInterruptionPending = false
    snapshot = SprintPlanningWorkflowSnapshot(
      isSendingMessage: false,
      isGeneratingGoal: false,
      readinessIssues: []
    )
    self.storeProvider = storeProvider
    self.clientProvider = clientProvider
    self.selectedProductID = selectedProductID
    self.contextProvider = contextProvider
    self.availabilityProvider = availabilityProvider
    self.workspaceURLProvider = workspaceURLProvider
    self.inheritedInstructions = inheritedInstructions
    self.onReloadActivity = onReloadActivity
    self.onReloadSelectedProduct = onReloadSelectedProduct
    self.onScheduleSprintExecution = onScheduleSprintExecution
    self.onError = onError
    self.onErrorMessage = onErrorMessage
    self.onSnapshotChange = onSnapshotChange
  }

  public var isBusy: Bool {
    operations.isBusy
  }

  public var canEditCandidateSprint: Bool {
    selectedProductID() != nil
  }

  public func loadReadinessProjection(_ issues: [SprintReadinessIssue]) {
    updateSnapshot { $0.readinessIssues = issues }
  }

  public func clearSelectedProductProjection() {
    updateSnapshot { $0.readinessIssues = [] }
  }

  public func candidateSprintPlan() -> SprintPlan? {
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID)
    else { return nil }
    return Self.candidateSprintPlan(in: context)
  }

  public func canGenerateSprintGoal(isCodexConnected: Bool) -> Bool {
    guard isCodexConnected else { return false }
    guard
      let plan = candidateSprintPlan(),
      [.draft, .active, .paused].contains(plan.sprint.state),
      !plan.items.isEmpty
    else { return false }
    let availability = availabilityProvider()
    guard !availability.isSuggestionGenerationRunning else { return false }
    guard !snapshot.isSendingMessage, !snapshot.isGeneratingGoal else { return false }
    guard !availability.isTicketConversationRunning else { return false }
    guard !availability.isEpicConversationRunning else { return false }
    guard availability.refiningWorkItemID == nil else { return false }
    guard !availability.isEpicPlanningRunning else { return false }
    return !availability.isEpicPlanGenerating
  }

  public func planningDropEvaluation(
    ids: Set<UUID>,
    intoCandidateSprint: Bool,
    before targetID: UUID?
  ) -> PlanningDropEvaluation {
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID)
    else {
      return .invalid(.unavailable, message: "Sprint planning is not available")
    }
    let candidatePlan = Self.candidateSprintPlan(in: context)
    return PlanningDropPolicy.evaluate(
      workItems: context.workItems,
      dependencies: context.dependencies,
      candidateIDs: Set(candidatePlan?.items.map(\.workItemID) ?? []),
      externalCandidatePrerequisiteIDs: Self.externalCandidatePrerequisiteIDs(in: context),
      movingIDs: ids,
      intoCandidateSprint: intoCandidateSprint,
      before: targetID
    )
  }

  public func addToCandidateSprint(_ selectedItems: [WorkItem]) {
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID),
      let store = storeProvider(productID),
      canEditCandidateSprint,
      !selectedItems.isEmpty,
      selectedItems.allSatisfy({ $0.productID == productID })
    else { return }

    let candidatePlan = Self.candidateSprintPlan(in: context)
    let existingIDs = Set(candidatePlan?.items.map(\.workItemID) ?? [])
    let selectedIDs = Set(selectedItems.map(\.id)).subtracting(existingIDs)
    guard !selectedIDs.isEmpty else { return }
    let availableIDs =
      existingIDs
      .union(selectedIDs)
      .union(Self.externalCandidatePrerequisiteIDs(in: context))
    if let missingEdge = context.dependencies.first(where: {
      selectedIDs.contains($0.workItemID) && !availableIDs.contains($0.dependsOnWorkItemID)
    }),
      let dependent = context.workItems.first(where: { $0.id == missingEdge.workItemID }),
      let prerequisite = context.workItems.first(where: {
        $0.id == missingEdge.dependsOnWorkItemID
      })
    {
      onErrorMessage("Also select \(prerequisite.key); \(dependent.key) depends on it.", productID)
      return
    }

    let currentInputs: [SprintDraftItemInput] =
      candidatePlan?.items.map { sprintItem in
        let workItem = context.workItems.first { $0.id == sprintItem.workItemID }
        return SprintDraftItemInput(
          workItemID: sprintItem.workItemID,
          implementerProfileID: sprintItem.implementerProfileID
            ?? workItem?.ownerProfileID,
          reviewerProfileID: sprintItem.reviewerProfileID,
          estimatedTokens: sprintItem.estimatedTokens
        )
      } ?? []
    let newInputs: [SprintDraftItemInput] =
      context.workItems
      .filter { selectedIDs.contains($0.id) }
      .map { item in
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: item.ownerProfileID,
          estimatedTokens: 0
        )
      }
    let inputs = currentInputs + newInputs
    startMutation(productID: productID) { [weak self] in
      do {
        _ = try await store.saveDraftSprint(
          productID: productID,
          goal: candidatePlan?.sprint.goal ?? "",
          tokenBudgetLimit: nil,
          items: inputs
        )
        await self?.onReloadSelectedProduct(productID)
      } catch {
        self?.onError(error, productID)
      }
    }
  }

  public func removeFromCandidateSprint(_ selectedItems: [WorkItem]) {
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID),
      let store = storeProvider(productID),
      let plan = Self.candidateSprintPlan(in: context),
      !selectedItems.isEmpty,
      selectedItems.allSatisfy({ $0.productID == productID })
    else { return }

    let candidateIDs = Set(plan.items.map(\.workItemID))
    let selectedIDs = Set(selectedItems.map(\.id)).intersection(candidateIDs)
    guard !selectedIDs.isEmpty else { return }
    let remainingIDs = candidateIDs.subtracting(selectedIDs)
    if let dependentEdge = context.dependencies.first(where: {
      selectedIDs.contains($0.dependsOnWorkItemID) && remainingIDs.contains($0.workItemID)
    }),
      let dependent = context.workItems.first(where: { $0.id == dependentEdge.workItemID }),
      let prerequisite = context.workItems.first(where: {
        $0.id == dependentEdge.dependsOnWorkItemID
      })
    {
      onErrorMessage("Also select \(dependent.key); it depends on \(prerequisite.key).", productID)
      return
    }

    let inputs = plan.items.compactMap { item -> SprintDraftItemInput? in
      guard !selectedIDs.contains(item.workItemID) else { return nil }
      return SprintDraftItemInput(
        workItemID: item.workItemID,
        implementerProfileID: item.implementerProfileID
          ?? context.workItems.first(where: { $0.id == item.workItemID })?.ownerProfileID,
        reviewerProfileID: item.reviewerProfileID,
        estimatedTokens: item.estimatedTokens
      )
    }
    startMutation(productID: productID) { [weak self] in
      do {
        _ = try await store.saveDraftSprint(
          productID: productID,
          goal: plan.sprint.goal,
          tokenBudgetLimit: nil,
          items: inputs
        )
        await self?.onReloadSelectedProduct(productID)
      } catch {
        self?.onError(error, productID)
      }
    }
  }

  public func dropPlanningItems(
    _ selectedItems: [WorkItem],
    intoCandidateSprint: Bool,
    before targetID: UUID?
  ) {
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID),
      let store = storeProvider(productID),
      canEditCandidateSprint,
      !selectedItems.isEmpty,
      selectedItems.allSatisfy({ $0.productID == productID })
    else { return }

    let movingIDs = Set(selectedItems.map(\.id))
    let candidatePlan = Self.candidateSprintPlan(in: context)
    let existingCandidateIDs = Set(candidatePlan?.items.map(\.workItemID) ?? [])
    let evaluation = planningDropEvaluation(
      ids: movingIDs,
      intoCandidateSprint: intoCandidateSprint,
      before: targetID
    )
    guard evaluation.isValid, let rankAction = evaluation.rankAction else { return }
    let desiredCandidateIDs =
      intoCandidateSprint
      ? existingCandidateIDs.union(movingIDs)
      : existingCandidateIDs.subtracting(movingIDs)
    let existingItemsByID = Dictionary(
      uniqueKeysWithValues: (candidatePlan?.items ?? []).map { ($0.workItemID, $0) }
    )
    let shouldSaveSprint = desiredCandidateIDs != existingCandidateIDs
    let capturedWorkItems = context.workItems

    startMutation(productID: productID) { [weak self] in
      do {
        let reorderedItems: [WorkItem]
        switch rankAction {
        case .preserve:
          reorderedItems = capturedWorkItems
        case .move(let resolvedTargetID):
          reorderedItems = try await store.moveWorkItems(
            ids: selectedItems.map(\.id),
            before: resolvedTargetID
          )
        }
        if shouldSaveSprint {
          let inputs = reorderedItems.compactMap { item -> SprintDraftItemInput? in
            guard desiredCandidateIDs.contains(item.id) else { return nil }
            let existing = existingItemsByID[item.id]
            return SprintDraftItemInput(
              workItemID: item.id,
              implementerProfileID: existing?.implementerProfileID
                ?? item.ownerProfileID,
              reviewerProfileID: existing?.reviewerProfileID,
              estimatedTokens: existing?.estimatedTokens ?? 0
            )
          }
          _ = try await store.saveDraftSprint(
            productID: productID,
            goal: candidatePlan?.sprint.goal ?? "",
            tokenBudgetLimit: nil,
            items: inputs
          )
        }
        await self?.onReloadSelectedProduct(productID)
      } catch {
        self?.onError(error, productID)
        await self?.onReloadSelectedProduct(productID)
      }
    }
  }

  public func sendSprintPlanningMessage(
    for item: WorkItem,
    to recipient: AgentProfile,
    ownerMessage: String,
    ticketSnapshot: SprintPlanningTicketSnapshot,
    proposedAssignee: AgentProfile?
  ) async throws -> SprintPlanningConversationReply {
    let availability = availabilityProvider()
    guard
      !snapshot.isSendingMessage,
      !availability.isSuggestionGenerationRunning,
      availability.refiningWorkItemID == nil,
      !availability.isTicketConversationRunning,
      !availability.isEpicConversationRunning
    else {
      throw SprintPlanningConversationError.anotherCodexTaskIsRunning
    }
    guard
      let store = storeProvider(item.productID),
      let client = clientProvider(),
      let context = contextProvider(item.productID),
      let product = context.product,
      selectedProductID() == item.productID
    else {
      throw CodexClientError.notConnected
    }
    guard
      recipient.productID == product.id,
      context.profiles.contains(where: { $0.id == recipient.id })
    else {
      throw CodexClientError.notConnected
    }
    let trimmedMessage = ownerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      throw SprintPlanningConversationError.invalidResponse("Enter a message first.")
    }
    guard let token = operations.claim(.conversation, productID: product.id) else {
      throw SprintPlanningConversationError.anotherCodexTaskIsRunning
    }
    updateSnapshot { $0.isSendingMessage = true }
    defer {
      isConversationInterruptionPending = false
      operations.finish(token)
      updateSnapshot { $0.isSendingMessage = false }
    }

    let comments = try await store.fetchComments(workItemID: item.id)
    let currentMessageBody = "@\(recipient.name) \(trimmedMessage)"
    let priorComments =
      comments.last?.authorKind == .owner
      && comments.last?.body == currentMessageBody
      ? Array(comments.dropLast())
      : comments
    let prerequisiteIDs = Set(
      context.dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    let prerequisites = context.workItems.filter { prerequisiteIDs.contains($0.id) }
    let sprintItemIDs = Set(Self.candidateSprintPlan(in: context)?.items.map(\.workItemID) ?? [])
    let scopedItems = context.workItems.filter { sprintItemIDs.contains($0.id) }
    let key = ConversationKey(workItemID: item.id, profileID: recipient.id)
    do {
      let threadID: String
      if let existingThreadID = planningThreadIDs[key] {
        threadID = existingThreadID
      } else {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: try workspaceURLProvider(product.id),
          developerInstructions: CodexSprintPlanningConversation.developerInstructions(
            productInstructions: inheritedInstructions(product),
            customInstructions: recipient.customInstructionText,
            recipient: recipient
          ),
          model: recipient.model
        )
        planningThreadIDs[key] = threadID
      }
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexSprintPlanningConversation.prompt(
          product: product,
          itemKey: item.key,
          snapshot: ticketSnapshot,
          prerequisites: prerequisites,
          sprintItems: scopedItems,
          proposedAssignee: proposedAssignee,
          previousComments: priorComments,
          ownerMessage: trimmedMessage
        ),
        effort: recipient.reasoningEffort,
        outputSchema: CodexSprintPlanningConversation.outputSchema
      )
      operations.recordTurn(
        CodexTurnIdentity(threadID: threadID, turnID: turnID),
        for: token
      )
      interruptConversationIfPending()
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let reply = try CodexSprintPlanningConversation.decode(response)
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: recipient.name,
        body: reply.ticketCommentBody
      )
      if selectedProductID() == product.id {
        try await onReloadActivity(product.id)
      }
      return reply
    } catch {
      planningThreadIDs.removeValue(forKey: key)
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body: "\(recipient.name) couldn't reply: \(error.localizedDescription)"
      )
      throw error
    }
  }

  public func cancelSprintPlanningMessage() {
    guard operations.isActive(.conversation) else { return }
    isConversationInterruptionPending = true
    interruptConversationIfPending()
  }

  public func generateAndSaveSprintGoal(
    for sprintID: UUID,
    planVersion: Int
  ) async throws -> String {
    let availability = availabilityProvider()
    guard
      !snapshot.isGeneratingGoal,
      !availability.isSuggestionGenerationRunning,
      !snapshot.isSendingMessage,
      !availability.isTicketConversationRunning,
      !availability.isEpicConversationRunning,
      availability.refiningWorkItemID == nil,
      !availability.isEpicPlanningRunning,
      !availability.isEpicPlanGenerating
    else {
      throw SprintGoalGenerationError.anotherCodexTaskIsRunning
    }
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID),
      let product = context.product,
      let client = clientProvider(),
      let analyst = context.profiles.first(where: { $0.role == .businessAnalyst }),
      let store = storeProvider(productID)
    else {
      throw CodexClientError.notConnected
    }
    guard
      let plan = Self.planForGoalGeneration(id: sprintID, in: context),
      plan.sprint.planVersion == planVersion
    else {
      throw SprintPlanningError.planChanged
    }
    let scopedIDs = Set(plan.items.map(\.workItemID))
    let titles =
      context.workItems
      .filter { scopedIDs.contains($0.id) }
      .sorted {
        if $0.rank == $1.rank { return $0.key < $1.key }
        return $0.rank < $1.rank
      }
      .map(\.title)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !titles.isEmpty else {
      throw SprintGoalGenerationError.noTickets
    }
    let supportedEfforts =
      context.modelOptions.first(where: { $0.model == analyst.model })?
      .supportedReasoningEfforts
      .map(\.id) ?? []
    let reasoningEffort = CodexSprintGoalGenerator.lightestReasoningEffort(
      supportedEfforts: supportedEfforts,
      fallback: analyst.reasoningEffort
    )
    let deadline = ContinuousClock.now + CodexSprintGoalGenerator.totalTimeout
    guard let token = operations.claim(.goal, productID: productID) else {
      throw SprintGoalGenerationError.anotherCodexTaskIsRunning
    }
    updateSnapshot { $0.isGeneratingGoal = true }
    defer {
      operations.finish(token)
      updateSnapshot { $0.isGeneratingGoal = false }
    }

    do {
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: try workspaceURLProvider(productID),
        developerInstructions: CodexSprintGoalGenerator.developerInstructions,
        model: analyst.model,
        responseTimeout: try remainingSprintGoalGenerationTime(until: deadline)
      )
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexSprintGoalGenerator.prompt(
          productName: product.name,
          sprintNumber: plan.sprint.number,
          ticketTitles: titles
        ),
        effort: reasoningEffort,
        outputSchema: CodexSprintGoalGenerator.outputSchema,
        responseTimeout: try remainingSprintGoalGenerationTime(until: deadline)
      )
      operations.recordTurn(
        CodexTurnIdentity(threadID: threadID, turnID: turnID),
        for: token
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID,
        timeout: .seconds(180),
        totalTimeout: try remainingSprintGoalGenerationTime(until: deadline)
      )
      let suggestion = try CodexSprintGoalGenerator.decode(response)
      let savedPlan = try await store.saveGeneratedSprintGoal(
        id: sprintID,
        goal: suggestion,
        expectedPlanVersion: planVersion
      )
      await onReloadSelectedProduct(productID)
      return savedPlan.sprint.goal
    } catch let error as SprintGoalGenerationError {
      if error == .timedOut, let turn = operations.turn(for: .goal) {
        try? await client.interruptTurn(
          threadID: turn.threadID,
          turnID: turn.turnID
        )
      }
      throw error
    } catch let error as CodexClientError {
      guard case .turnTimedOut = error else { throw error }
      throw SprintGoalGenerationError.timedOut
    } catch let error as CodexTransportError {
      guard case .requestTimedOut = error else { throw error }
      throw SprintGoalGenerationError.timedOut
    }
  }

  public func saveSprintPlan(
    goal: String,
    items: [SprintDraftItemInput]
  ) async -> Bool {
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID),
      let store = storeProvider(productID)
    else { return false }
    do {
      for input in items {
        let savedOwnerID = context.workItems.first(where: { $0.id == input.workItemID })?
          .ownerProfileID
        guard savedOwnerID != input.implementerProfileID else { continue }
        _ = try await store.assignWorkItemOwner(
          id: input.workItemID,
          profileID: input.implementerProfileID
        )
      }
      _ = try await store.saveDraftSprint(
        productID: productID,
        goal: goal,
        tokenBudgetLimit: nil,
        items: items
      )
      await onReloadSelectedProduct(productID)
      return true
    } catch {
      onError(error, productID)
      return false
    }
  }

  public func reassignDraftTicket(
    productID: UUID,
    workItemID: UUID,
    to profileID: UUID?
  ) async -> Bool {
    guard let store = storeProvider(productID) else { return false }
    guard
      let plan = try? await store.fetchDraftSprint(productID: productID),
      plan.items.contains(where: { $0.workItemID == workItemID })
    else { return false }
    if let profileID {
      let productProfiles = (try? await store.fetchAgentProfiles(productID: productID)) ?? []
      guard productProfiles.contains(where: { $0.id == profileID && $0.role.canOwnDelivery })
      else { return false }
    }
    let inputs = plan.items.map { sprintItem in
      SprintDraftItemInput(
        workItemID: sprintItem.workItemID,
        implementerProfileID: sprintItem.workItemID == workItemID
          ? profileID
          : sprintItem.implementerProfileID,
        reviewerProfileID: sprintItem.reviewerProfileID,
        estimatedTokens: sprintItem.estimatedTokens
      )
    }
    do {
      _ = try await store.assignWorkItemOwner(id: workItemID, profileID: profileID)
      _ = try await store.saveDraftSprint(
        productID: productID,
        goal: plan.sprint.goal,
        tokenBudgetLimit: nil,
        items: inputs
      )
      await onReloadSelectedProduct(productID)
      return true
    } catch {
      onError(error, productID)
      return false
    }
  }

  public func startSprint() async -> Bool {
    guard
      let productID = selectedProductID(),
      let context = contextProvider(productID),
      let store = storeProvider(productID),
      let plan = Self.candidateSprintPlan(in: context),
      plan.sprint.state == .draft
    else { return false }
    let sprintID = plan.sprint.id
    do {
      let issues = try await store.sprintReadinessIssues(sprintID: sprintID)
      if selectedProductID() == productID {
        updateSnapshot { $0.readinessIssues = issues }
      }
      guard issues.isEmpty else { return false }
      _ = try await store.startSprint(id: sprintID)
      await onReloadSelectedProduct(productID)
      onScheduleSprintExecution(productID)
      return true
    } catch {
      onError(error, productID)
      return false
    }
  }

  public func cancel(productID: UUID) async {
    if operations.productID(for: .conversation) == productID,
      operations.turn(for: .conversation) == nil
    {
      isConversationInterruptionPending = true
    }
    await operations.cancel(productID: productID) { [weak self] turn in
      guard let client = self?.clientProvider() else { return }
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
    planningThreadIDs = planningThreadIDs.filter { key, _ in
      guard let context = contextProvider(productID) else { return true }
      return !context.workItems.contains(where: { $0.id == key.workItemID })
    }
  }

  public func shutdown() async {
    if operations.isActive(.conversation),
      operations.turn(for: .conversation) == nil
    {
      isConversationInterruptionPending = true
    }
    await operations.shutdown { [weak self] turn in
      guard let client = self?.clientProvider() else { return }
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
    planningThreadIDs.removeAll()
  }

  public func settleAll() async {
    await operations.settleAll()
  }

  public func settleMutations() async {
    let mutationKeys = operations.activeKeys.filter { key in
      if case .mutation = key { return true }
      return false
    }
    for key in mutationKeys {
      await operations.settle(key)
    }
  }

  private func interruptConversationIfPending() {
    guard
      isConversationInterruptionPending,
      let productID = operations.productID(for: .conversation),
      let turn = operations.turn(for: .conversation),
      let client = clientProvider()
    else { return }
    isConversationInterruptionPending = false
    operations.start(.interruption, productID: productID, replacing: true) { _ in
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
  }

  private func startMutation(
    productID: UUID,
    operation: @escaping @MainActor () async -> Void
  ) {
    operations.start(.mutation(UUID()), productID: productID) { _ in
      await operation()
    }
  }

  private func remainingSprintGoalGenerationTime(
    until deadline: ContinuousClock.Instant
  ) throws -> Duration {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw SprintGoalGenerationError.timedOut
    }
    return remaining
  }

  private static func candidateSprintPlan(
    in context: SprintPlanningWorkflowContext
  ) -> SprintPlan? {
    if let sprintPlan = context.sprintPlan, sprintPlan.sprint.state == .draft {
      return sprintPlan
    }
    return context.sprintHistory.first { $0.sprint.state == .draft }
  }

  private static func planForGoalGeneration(
    id: UUID,
    in context: SprintPlanningWorkflowContext
  ) -> SprintPlan? {
    if let candidate = candidateSprintPlan(in: context), candidate.sprint.id == id {
      return candidate
    }
    if let sprintPlan = context.sprintPlan, sprintPlan.sprint.id == id {
      return sprintPlan
    }
    return context.sprintHistory.first { $0.sprint.id == id }
  }

  private static func externalCandidatePrerequisiteIDs(
    in context: SprintPlanningWorkflowContext
  ) -> Set<UUID> {
    var ids = Set(
      context.workItems
        .filter { $0.state == .released }
        .map(\.id)
    )
    if let activePlan = context.sprintPlan, activePlan.sprint.state.isInProgress {
      ids.formUnion(activePlan.items.map(\.workItemID))
    }
    return ids
  }

  private func updateSnapshot(
    _ update: (inout SprintPlanningWorkflowSnapshot) -> Void
  ) {
    var updated = snapshot
    update(&updated)
    guard updated != snapshot else { return }
    snapshot = updated
    onSnapshotChange(updated)
  }
}
