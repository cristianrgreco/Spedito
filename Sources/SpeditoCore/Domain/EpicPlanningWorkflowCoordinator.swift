import Foundation

public struct EpicPlanningWorkflowAvailability: Equatable, Sendable {
  public let canAutosuggestTickets: Bool
  public let canPlanEpic: Bool

  public init(canAutosuggestTickets: Bool, canPlanEpic: Bool) {
    self.canAutosuggestTickets = canAutosuggestTickets
    self.canPlanEpic = canPlanEpic
  }
}

public struct EpicPlanningWorkflowSnapshot: Equatable, Sendable {
  public var conversations: [UUID: EpicPlanningConversationState]
  public var suggestionBatches: [TicketSuggestionBatch]
  public var isDecidingSuggestions: Bool

  public init(
    conversations: [UUID: EpicPlanningConversationState] = [:],
    suggestionBatches: [TicketSuggestionBatch] = [],
    isDecidingSuggestions: Bool = false
  ) {
    self.conversations = conversations
    self.suggestionBatches = suggestionBatches
    self.isDecidingSuggestions = isDecidingSuggestions
  }

  public func conversation(for epicID: UUID) -> EpicPlanningConversationState? {
    conversations[epicID]
  }

  public var isPlanning: Bool {
    conversations.values.contains { $0.isRunning || $0.isGeneratingPlan }
  }

  public var isAnyConversationRunning: Bool {
    conversations.values.contains { $0.isRunning }
  }

  public var isAnyPlanGenerating: Bool {
    conversations.values.contains { $0.isGeneratingPlan }
  }

  public var isSuggestionGenerationRunning: Bool {
    suggestionBatches.contains { $0.session.status == .generating }
  }
}

@MainActor
public final class EpicPlanningWorkflowCoordinator {
  private enum Operation: Hashable {
    case planning(UUID)
    case suggestionGeneration
    case persistence(UUID)
    case interruption(UUID)
  }

  public private(set) var snapshot = EpicPlanningWorkflowSnapshot()

  private let storeProvider: (UUID) -> SQLiteStore?
  private let clientProvider: () -> CodexAppServerClient?
  private let productProvider: (UUID) -> Product?
  private let selectedProductID: () -> UUID?
  private let availabilityProvider: () -> EpicPlanningWorkflowAvailability
  private let isShuttingDown: () -> Bool
  private let workspaceProvider: (UUID) throws -> URL
  private let inheritedInstructions: (Product) -> String
  private let onSnapshotChange: (EpicPlanningWorkflowSnapshot) -> Void
  private let onOwnerNotification: (OwnerNotification) async -> Void
  private let onResolveOwnerNotification: (UUID, OwnerNotificationTarget) async -> Void
  private let onReloadSelectedProduct: (UUID) async -> Void
  private let onError: (Error, UUID) -> Void
  private let recoveryPolicy: TicketSuggestionRecoveryPolicy

  private let operations = FeatureOperationRegistry<Operation>()
  private let ownerCommands = FeatureOperationRegistry<UUID>()
  private var threadIDs: [UUID: String] = [:]
  private var recoveredSessionIDs: Set<UUID> = []
  /// Epics whose current plan-generation cycle already used its one silent
  /// retry. Cleared when a plan completes, so the next cycle gets its own.
  /// Transient on purpose: after a relaunch, recovery owns interrupted
  /// sessions and the owner-facing retry takes over.
  private var autoRetriedPlanEpicIDs: Set<UUID> = []

  public init(
    storeProvider: @escaping (UUID) -> SQLiteStore?,
    clientProvider: @escaping () -> CodexAppServerClient?,
    productProvider: @escaping (UUID) -> Product?,
    selectedProductID: @escaping () -> UUID?,
    availabilityProvider: @escaping () -> EpicPlanningWorkflowAvailability,
    isShuttingDown: @escaping () -> Bool,
    workspaceProvider: @escaping (UUID) throws -> URL,
    inheritedInstructions: @escaping (Product) -> String,
    recoveryPolicy: TicketSuggestionRecoveryPolicy = TicketSuggestionRecoveryPolicy(),
    onSnapshotChange: @escaping (EpicPlanningWorkflowSnapshot) -> Void,
    onOwnerNotification: @escaping (OwnerNotification) async -> Void,
    onResolveOwnerNotification: @escaping (UUID, OwnerNotificationTarget) async -> Void,
    onReloadSelectedProduct: @escaping (UUID) async -> Void,
    onError: @escaping (Error, UUID) -> Void
  ) {
    self.storeProvider = storeProvider
    self.clientProvider = clientProvider
    self.productProvider = productProvider
    self.selectedProductID = selectedProductID
    self.availabilityProvider = availabilityProvider
    self.isShuttingDown = isShuttingDown
    self.workspaceProvider = workspaceProvider
    self.inheritedInstructions = inheritedInstructions
    self.recoveryPolicy = recoveryPolicy
    self.onSnapshotChange = onSnapshotChange
    self.onOwnerNotification = onOwnerNotification
    self.onResolveOwnerNotification = onResolveOwnerNotification
    self.onReloadSelectedProduct = onReloadSelectedProduct
    self.onError = onError
  }

  public var isBusy: Bool {
    !activePlanningEpicIDs.isEmpty || operations.isActive(.suggestionGeneration)
  }

  public var isPlanning: Bool {
    !activePlanningEpicIDs.isEmpty
  }

  private var activePlanningEpicIDs: [UUID] {
    operations.activeKeys.compactMap {
      if case .planning(let epicID) = $0 { return epicID }
      return nil
    }
  }

  private var activePersistenceEpicIDs: [UUID] {
    operations.activeKeys.compactMap {
      if case .persistence(let epicID) = $0 { return epicID }
      return nil
    }
  }

  public func loadSuggestionBatches(_ batches: [TicketSuggestionBatch]) {
    updateSnapshot { $0.suggestionBatches = batches }
  }

  private func suggestionBatch(sessionID: UUID) -> TicketSuggestionBatch? {
    snapshot.suggestionBatches.first { $0.session.id == sessionID }
  }


  private func suggestionBatch(containing suggestionID: UUID) -> TicketSuggestionBatch? {
    snapshot.suggestionBatches.first {
      $0.suggestions.contains { $0.id == suggestionID }
    }
  }

  private func replaceSuggestionBatch(_ batch: TicketSuggestionBatch) {
    updateSnapshot {
      if let index = $0.suggestionBatches.firstIndex(where: {
        $0.session.id == batch.session.id
      }) {
        $0.suggestionBatches[index] = batch
      } else {
        $0.suggestionBatches.append(batch)
        $0.suggestionBatches.sort {
          if $0.session.createdAt == $1.session.createdAt {
            return $0.session.id.uuidString < $1.session.id.uuidString
          }
          return $0.session.createdAt < $1.session.createdAt
        }
      }
    }
  }

  private func removeSuggestionBatch(sessionID: UUID) {
    updateSnapshot {
      $0.suggestionBatches.removeAll { $0.session.id == sessionID }
    }
  }

  public func loadConversationProjection(
    _ conversation: EpicPlanningConversationState,
    threadID: String?
  ) {
    threadIDs[conversation.epicID] = threadID
    updateSnapshot { $0.conversations[conversation.epicID] = conversation }
  }

  public func awaitPersistence() async {
    for epicID in activePersistenceEpicIDs {
      await operations.settle(.persistence(epicID))
    }
    await ownerCommands.settleAll()
  }
  public func clearSelectedProductProjection() {
    updateSnapshot {
      $0.suggestionBatches = []
      $0.isDecidingSuggestions = false
    }
  }

  public func restoreEpicPlanningConversation(for epic: Epic) async {
    guard snapshot.conversations[epic.id] == nil else { return }
    await operations.settle(.persistence(epic.id))
    guard
      !Task.isCancelled,
      snapshot.conversations[epic.id] == nil,
      let store = storeProvider(epic.productID)
    else { return }

    do {
      guard var durable = try await store.fetchEpicPlanningConversation(epicID: epic.id) else {
        threadIDs[epic.id] = nil
        return
      }
      let planningSession = try await store.fetchLatestEpicPlanningSuggestionSession(
        epicID: epic.id
      )
      let hasCompletedPlan = durable.isComplete || planningSession?.status == .ready
      if hasCompletedPlan && !durable.isComplete {
        durable.isComplete = true
        durable.updatedAt = Date()
        try await store.saveEpicPlanningConversation(durable)
      }
      guard
        !Task.isCancelled,
        snapshot.conversations[epic.id] == nil
      else { return }
      threadIDs[epic.id] = durable.threadID
      let hasStartedPlanning = durable.hasStartedPlanning ?? true
      updateSnapshot {
        $0.conversations[epic.id] = EpicPlanningConversationState(
          productID: epic.productID,
          epicID: durable.epicID,
          messages: durable.messages,
          questions: durable.questions,
          hasStartedPlanning: hasStartedPlanning,
          isRunning: false,
          isGeneratingPlan: false,
          isComplete: hasCompletedPlan,
          errorMessage:
            !hasStartedPlanning || hasCompletedPlan || !durable.questions.isEmpty
            ? nil
            : "Epic planning was paused when the app closed. You can safely try again."
        )
      }
    } catch {
      onError(error, epic.productID)
    }
  }

  public func planEpic(_ epic: Epic) {
    guard
      availabilityProvider().canPlanEpic,
      selectedProductID() == epic.productID,
      snapshot.conversations[epic.id]?.isRunning != true,
      snapshot.conversations[epic.id]?.isGeneratingPlan != true,
      let product = productProvider(epic.productID),
      epic.status == .open,
      let store = storeProvider(epic.productID)
    else { return }

    let existingMessages = snapshot.conversations[epic.id]?.messages ?? []
    updateSnapshot {
      $0.conversations[epic.id] = EpicPlanningConversationState(
        productID: epic.productID,
        epicID: epic.id,
        messages: existingMessages,
        questions: [],
        hasStartedPlanning: true,
        isRunning: true,
        isGeneratingPlan: false,
        isComplete: false,
        errorMessage: nil
      )
    }
    persistConversation(epicID: epic.id)
    operations.start(
      .planning(epic.id),
      productID: product.id,
      replacing: true
    ) { [weak self] token in
      guard let self else { return }
      do {
        guard let client = clientProvider() else { throw CodexClientError.notConnected }
        if existingMessages.isEmpty,
          let durable = try await store.fetchEpicPlanningConversation(epicID: epic.id),
          !durable.messages.isEmpty
        {
          updateConversation(for: epic.id) { $0.messages = durable.messages }
        }
        let analyst = try await store.fetchAgentProfiles(productID: product.id)
          .first { $0.role == .businessAnalyst }
        let existingItems = try await store.fetchWorkItems(productID: product.id)
          .filter { $0.state != .cancelled }
        let planningKnowledge = KnowledgeContextSelector.selectForEpic(
          pages: try await store.fetchKnowledgePages(productID: product.id),
          epic: epic
        )
        let newThreadID = try await client.startReadOnlyThread(
          workingDirectory: try workspaceProvider(product.id),
          developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
            productInstructions: inheritedInstructions(product),
            customInstructions: analyst?.customInstructionText ?? ""
          ),
          model: analyst?.model
        )
        threadIDs[epic.id] = newThreadID
        persistConversation(epicID: epic.id)
        let turnID = try await client.startStructuredTurn(
          threadID: newThreadID,
          prompt: CodexEpicClarificationGenerator.initialPrompt(
            product: product,
            epic: epic,
            existingItems: existingItems,
            verifiedKnowledge: planningKnowledge
          ),
          effort: analyst?.reasoningEffort ?? "medium",
          outputSchema: CodexEpicClarificationGenerator.outputSchema
        )
        operations.recordTurn(
          CodexTurnIdentity(threadID: newThreadID, turnID: turnID),
          for: token
        )
        let response = try await client.waitForFinalAgentMessage(
          threadID: newThreadID,
          turnID: turnID
        )
        try Task.checkCancellation()
        let reply = try CodexEpicClarificationGenerator.decode(response)
        operations.clearTurn(for: token)
        await receiveEpicClarification(reply, for: epic)
      } catch is CancellationError {
        operations.clearTurn(for: token)
        updateConversation(for: epic.id) {
          $0.isRunning = false
          $0.errorMessage = "Epic planning was interrupted. You can safely continue."
        }
      } catch {
        operations.clearTurn(for: token)
        updateConversation(for: epic.id) {
          $0.isRunning = false
          $0.errorMessage =
            if Task.isCancelled {
              "Epic planning was interrupted. You can safely continue."
            } else {
              error.localizedDescription
            }
        }
      }
    }
  }

  public func continueEpicPlanning(
    _ epic: Epic,
    answers: [String],
    answeredQuestions: [EpicPlanningAnsweredQuestion]
  ) {
    continueEpicPlanning(
      epic,
      answers: answers,
      answeredQuestions: answeredQuestions,
      recordsAnswers: true,
      requiresReplacementThread: false
    )
  }

  public func retryEpicPlanning(_ epic: Epic) {
    guard
      let conversation = snapshot.conversations[epic.id],
      !conversation.isRunning,
      !conversation.isGeneratingPlan
    else { return }

    let failedBatch = snapshot.suggestionBatches.first {
      $0.session.epicID == epic.id && $0.session.status == .failed
    }
    switch EpicPlanningPolicy.retryAction(
      for: conversation,
      hasFailedPlan: failedBatch != nil
    ) {
    case .retryFailedPlan:
      if let failedBatch {
        retryEpicPlan(sessionID: failedBatch.session.id)
      }
    case .retryClarification(let answeredQuestions):
      continueEpicPlanning(
        epic,
        answers: answeredQuestions.map { "\($0.question.prompt)\nAnswer: \($0.answer)" },
        answeredQuestions: answeredQuestions,
        recordsAnswers: false,
        requiresReplacementThread: true
      )
    case .restartClarification:
      threadIDs[epic.id] = nil
      updateConversation(for: epic.id) {
        $0.questions = []
        $0.hasStartedPlanning = false
        $0.errorMessage = nil
      }
      planEpic(epic)
    }
  }

  public func cancelEpicPlanning(epicID: UUID) {
    operations.cancelTask(.planning(epicID))
    guard let turn = operations.turn(for: .planning(epicID)) else { return }
    operations.start(
      .interruption(epicID),
      productID: nil,
      replacing: true
    ) { [weak self] _ in
      guard let self, let client = clientProvider() else { return }
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
  }

  public func clearEpicPlanningConversation(for epicID: UUID) {
    guard let conversation = snapshot.conversations[epicID] else { return }
    cancelEpicPlanning(epicID: epicID)
    threadIDs[epicID] = nil
    updateSnapshot { $0.conversations[epicID] = nil }
    guard let store = storeProvider(conversation.productID) else { return }
    operations.enqueue(
      .persistence(epicID),
      productID: conversation.productID
    ) { [weak self] in
      do {
        try await store.deleteEpicPlanningConversation(epicID: epicID)
      } catch {
        self?.onError(error, conversation.productID)
      }
    }
  }

  public func settlePlanning() async {
    while let epicID = activePlanningEpicIDs.first {
      await operations.settle(.planning(epicID))
    }
  }

  private func continueEpicPlanning(
    _ epic: Epic,
    answers: [String],
    answeredQuestions: [EpicPlanningAnsweredQuestion],
    recordsAnswers: Bool,
    requiresReplacementThread: Bool
  ) {
    guard
      !answers.isEmpty,
      answers.count == answeredQuestions.count,
      snapshot.conversations[epic.id]?.isRunning == false,
      snapshot.conversations[epic.id]?.isGeneratingPlan == false,
      let client = clientProvider(),
      selectedProductID() == epic.productID,
      let product = productProvider(epic.productID),
      let store = storeProvider(epic.productID)
    else { return }

    updateConversation(for: epic.id) {
      if recordsAnswers {
        $0.messages.append(
          EpicPlanningConversationMessage(
            author: .owner,
            body: "",
            answeredQuestions: answeredQuestions
          )
        )
      }
      $0.questions = []
      $0.isRunning = true
      $0.errorMessage = nil
    }
    let messages = snapshot.conversations[epic.id]?.messages ?? []
    let preferredThreadID = requiresReplacementThread ? nil : threadIDs[epic.id]
    operations.start(
      .planning(epic.id),
      productID: product.id,
      replacing: true
    ) { [weak self] token in
      guard let self else { return }
      await onResolveOwnerNotification(
        product.id,
        OwnerNotificationTarget(kind: .epic, id: epic.id)
      )
      do {
        guard
          let analyst = try await store.fetchAgentProfiles(productID: product.id)
            .first(where: { $0.role == .businessAnalyst })
        else { throw CodexClientError.notConnected }
        let planningKnowledge = KnowledgeContextSelector.selectForEpic(
          pages: try await store.fetchKnowledgePages(productID: product.id),
          epic: epic
        )
        let response = try await runEpicClarificationTurn(
          token: token,
          client: client,
          epicID: epic.id,
          preferredThreadID: preferredThreadID,
          prompt: CodexEpicClarificationGenerator.followUpPrompt(answers: answers),
          recoveryPrompt: CodexEpicClarificationGenerator.recoveryPrompt(
            product: product,
            epic: epic,
            existingItems: try await store.fetchWorkItems(productID: product.id)
              .filter { $0.state != .cancelled },
            messages: messages,
            verifiedKnowledge: planningKnowledge
          ),
          product: product,
          analyst: analyst
        )
        try Task.checkCancellation()
        let reply = try CodexEpicClarificationGenerator.decode(response)
        operations.clearTurn(for: token)
        await receiveEpicClarification(reply, for: epic)
      } catch is CancellationError {
        operations.clearTurn(for: token)
        updateConversation(for: epic.id) {
          $0.isRunning = false
          $0.errorMessage = "The business analyst stopped. Your answers are still visible."
        }
      } catch {
        operations.clearTurn(for: token)
        updateConversation(for: epic.id) {
          $0.isRunning = false
          $0.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func runEpicClarificationTurn(
    token: FeatureOperationToken<Operation>,
    client: CodexAppServerClient,
    epicID: UUID,
    preferredThreadID: String?,
    prompt: String,
    recoveryPrompt: String,
    product: Product,
    analyst: AgentProfile
  ) async throws -> String {
    if let preferredThreadID {
      do {
        return try await runEpicStructuredTurn(
          token: token,
          client: client,
          threadID: preferredThreadID,
          prompt: prompt,
          effort: analyst.reasoningEffort
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        operations.clearTurn(for: token)
      }
    }

    let replacementThreadID = try await client.startReadOnlyThread(
      workingDirectory: try workspaceProvider(product.id),
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: inheritedInstructions(product),
        customInstructions: analyst.customInstructionText
      ),
      model: analyst.model
    )
    threadIDs[epicID] = replacementThreadID
    persistConversation(epicID: epicID)
    return try await runEpicStructuredTurn(
      token: token,
      client: client,
      threadID: replacementThreadID,
      prompt: recoveryPrompt,
      effort: analyst.reasoningEffort
    )
  }

  private func runEpicStructuredTurn(
    token: FeatureOperationToken<Operation>,
    client: CodexAppServerClient,
    threadID: String,
    prompt: String,
    effort: String
  ) async throws -> String {
    let turnID = try await client.startStructuredTurn(
      threadID: threadID,
      prompt: prompt,
      effort: effort,
      outputSchema: CodexEpicClarificationGenerator.outputSchema
    )
    operations.recordTurn(CodexTurnIdentity(threadID: threadID, turnID: turnID), for: token)
    return try await client.waitForFinalAgentMessage(threadID: threadID, turnID: turnID)
  }

  private func receiveEpicClarification(
    _ reply: EpicClarificationReply,
    for epic: Epic
  ) async {
    let message = EpicPlanningConversationMessage(
      author: .businessAnalyst,
      body: reply.message
    )
    updateConversation(for: epic.id) {
      $0.messages.append(message)
      $0.questions = reply.questions
      $0.isRunning = false
    }
    await operations.settle(.persistence(epic.id))
    if let firstQuestion = reply.questions.first {
      await onOwnerNotification(
        OwnerNotification(
          id: message.id,
          productID: epic.productID,
          kind: .needsInput,
          target: OwnerNotificationTarget(kind: .epic, id: epic.id),
          title: "\(epic.displayTitle) needs your input",
          body: firstQuestion.prompt,
          createdAt: message.createdAt
        )
      )
    }
    if reply.readyToPlan {
      generateEpicPlan(epic)
    }
  }
}


public enum EpicPlanningRetryAction: Equatable {
  case retryFailedPlan
  case retryClarification([EpicPlanningAnsweredQuestion])
  case restartClarification
}

public struct EpicPlanningPolicy {
  public static func retryAction(
    for conversation: EpicPlanningConversationState,
    hasFailedPlan: Bool
  ) -> EpicPlanningRetryAction {
    if hasFailedPlan {
      return .retryFailedPlan
    }
    if let answeredQuestions = conversation.messages.last?.answeredQuestions,
      !answeredQuestions.isEmpty
    {
      return .retryClarification(answeredQuestions)
    }
    return .restartClarification
  }

  /// Whether a failed plan-generation turn should be retried once without
  /// involving the product owner.
  ///
  /// A turn that stalls or ends without output can succeed cleanly on the next
  /// attempt, and the owner has nothing to decide, so notifying them first is
  /// noise. Every other failure — a usage limit that would fail again
  /// immediately, an invalid result the repair turn already could not fix —
  /// goes to the owner, and so does a second transient failure.
  public static func shouldAutoRetryPlanGeneration(
    after error: Error,
    hasAutoRetried: Bool
  ) -> Bool {
    guard !hasAutoRetried else { return false }
    switch error as? CodexClientError {
    case .turnTimedOut, .turnEndedWithoutOutput: return true
    default: return false
    }
  }
}

extension EpicPlanningWorkflowCoordinator {
  private func generateEpicPlan(
    _ epic: Epic,
    recovering recoveredSession: SuggestionSession? = nil
  ) {
    guard
      let client = clientProvider(),
      let product = productProvider(epic.productID),
      let store = storeProvider(epic.productID)
    else { return }
    updateConversation(for: epic.id) {
      $0.isRunning = false
      $0.isGeneratingPlan = true
      $0.errorMessage = nil
    }
    operations.start(
      .planning(epic.id),
      productID: product.id,
      replacing: true
    ) { [weak self] token in
      guard let self else { return }
      var session: SuggestionSession?
      do {
        let analyst = try await store.fetchAgentProfiles(productID: product.id)
          .first { $0.role == .businessAnalyst }
        let existingItems = try await store.fetchWorkItems(productID: product.id)
          .filter { $0.state != .cancelled }
        let latestBatch = try await store.fetchLatestTicketSuggestionBatch(
          productID: product.id
        )
        let previouslyRejectedSuggestions =
          latestBatch?.session.epicID == epic.id
          ? latestBatch?.suggestions.filter { $0.status == .rejected } ?? []
          : []
        let durableMessages =
          try await store.fetchEpicPlanningConversation(epicID: epic.id)?.messages ?? []
        let planningKnowledge = KnowledgeContextSelector.selectForEpic(
          pages: try await store.fetchKnowledgePages(productID: product.id),
          epic: epic
        )
        let startedSession = try await store.beginTicketSuggestionSession(
          productID: product.id,
          epicID: epic.id
        )
        session = startedSession
        if selectedProductID() == product.id {
          replaceSuggestionBatch(
            TicketSuggestionBatch(
              session: startedSession,
              suggestions: []
            )
          )
        }

        let response = try await runEpicPlanTurn(
          token: token,
          client: client,
          store: store,
          session: startedSession,
          recoveredSession: recoveredSession,
          product: product,
          epic: epic,
          existingItems: existingItems,
          rejectedSuggestions: previouslyRejectedSuggestions,
          durableMessages: durableMessages,
          analyst: analyst,
          planningKnowledge: planningKnowledge
        )
        try Task.checkCancellation()
        let reply: EpicPlanReply
        do {
          reply = try CodexTicketSuggestionGenerator.decodeEpicPlan(
            response,
            existingItems: existingItems
          )
        } catch let validationError as TicketSuggestionGenerationError {
          guard let repairThreadID = threadIDs[epic.id] else {
            throw CodexClientError.invalidThreadResponse
          }
          let repairedResponse = try await runEpicPlanStructuredTurn(
            token: token,
            client: client,
            store: store,
            sessionID: startedSession.id,
            threadID: repairThreadID,
            prompt:
              CodexTicketSuggestionGenerator.repairPrompt(
                validationError: validationError.localizedDescription,
                existingItems: existingItems
              )
              + "\nReturn the complete corrected epic metadata and ticket plan.",
            effort: analyst?.reasoningEffort ?? "medium"
          )
          try Task.checkCancellation()
          reply = try CodexTicketSuggestionGenerator.decodeEpicPlan(
            repairedResponse,
            existingItems: existingItems
          )
        }

        let plan: EpicPlanDraft
        switch reply {
        case .questions(let message, let questions):
          operations.clearTurn(for: token)
          try await escapeEpicPlanningToQuestions(
            for: epic,
            sessionID: startedSession.id,
            message: message,
            questions: questions,
            fallbackMessages: durableMessages
          )
          return
        case .plan(let decodedPlan):
          plan = decodedPlan
        }

        let ownerReviewedMetadata = epic.hasAnalyzedMetadata
        let updatedEpic = try await store.updateEpic(
          id: epic.id,
          title: ownerReviewedMetadata ? epic.title : plan.title,
          goal: ownerReviewedMetadata ? epic.goal : plan.goal,
          successCriteria: ownerReviewedMetadata
            ? epic.successCriteria
            : plan.successCriteria,
          constraints: ownerReviewedMetadata ? epic.constraints : plan.constraints
        )
        let completedBatch = try await store.completeTicketSuggestionSession(
          sessionID: startedSession.id,
          drafts: plan.ticketSuggestions
        )
        if selectedProductID() == product.id {
          replaceSuggestionBatch(completedBatch)
        }
        operations.clearTurn(for: token)
        autoRetriedPlanEpicIDs.remove(epic.id)
        await onReloadSelectedProduct(product.id)
        try await completeEpicPlanningConversation(
          for: epic,
          proposalCount: plan.ticketSuggestions.count,
          threadID: completedBatch.session.codexThreadID,
          fallbackMessages: durableMessages
        )
        await onOwnerNotification(
          OwnerNotification(
            id: completedBatch.session.id,
            productID: product.id,
            kind: .refinementComplete,
            target: OwnerNotificationTarget(kind: .epic, id: epic.id),
            title: "\(updatedEpic.title) plan ready for review",
            body:
              "\(plan.ticketSuggestions.count) proposed "
              + (plan.ticketSuggestions.count == 1 ? "ticket is" : "tickets are")
              + " ready to review."
          )
        )
      } catch is CancellationError {
        operations.clearTurn(for: token)
        if let session, !isShuttingDown() {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: "Epic planning was interrupted. You can safely try again."
          )
        }
        if !isShuttingDown() {
          updateConversation(for: epic.id) {
            $0.isGeneratingPlan = false
            $0.errorMessage = "Epic planning was interrupted. You can safely try again."
          }
        }
      } catch {
        operations.clearTurn(for: token)
        if let session {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: error.localizedDescription
          )
          let failedBatch = try? await store.fetchTicketSuggestionBatch(sessionID: session.id)
          if selectedProductID() == product.id, let failedBatch {
            replaceSuggestionBatch(failedBatch)
          }
        }
        // A transient turn failure gets one silent retry: the owner has
        // nothing to decide yet, so a notification would be noise. The failed
        // session stays durable for audit; the retry restarts it.
        if let session,
          selectedProductID() == product.id,
          EpicPlanningPolicy.shouldAutoRetryPlanGeneration(
            after: error,
            hasAutoRetried: autoRetriedPlanEpicIDs.contains(epic.id)
          )
        {
          autoRetriedPlanEpicIDs.insert(epic.id)
          updateConversation(for: epic.id) {
            $0.isGeneratingPlan = false
            $0.errorMessage = nil
          }
          retryEpicPlan(sessionID: session.id)
          return
        }
        updateConversation(for: epic.id) {
          $0.isGeneratingPlan = false
          $0.errorMessage = error.localizedDescription
        }
        // Success posts "plan ready for review", so failure must post too. A
        // live run generated for half an hour, timed out, and recorded the
        // failure durably — while the owner surface stayed silent unless the
        // epic screen happened to be open. Waiting for a plan is exactly when
        // an owner walks away. The id must stay distinct from the session id:
        // a retried session completes under its own id, and reusing it here
        // silently swallowed both the repeat failure and the later success.
        await onOwnerNotification(
          OwnerNotification(
            productID: product.id,
            kind: .needsInput,
            target: OwnerNotificationTarget(kind: .epic, id: epic.id),
            title: "Planning needs another try",
            body: error.localizedDescription
          )
        )
      }
    }
  }

  private func runEpicPlanTurn(
    token: FeatureOperationToken<Operation>,
    client: CodexAppServerClient,
    store: SQLiteStore,
    session: SuggestionSession,
    recoveredSession: SuggestionSession?,
    product: Product,
    epic: Epic,
    existingItems: [WorkItem],
    rejectedSuggestions: [TicketSuggestion],
    durableMessages: [EpicPlanningConversationMessage],
    analyst: AgentProfile?,
    planningKnowledge: [KnowledgePage]
  ) async throws -> String {
    let developerInstructions = CodexTicketSuggestionGenerator.developerInstructions(
      productInstructions: inheritedInstructions(product),
      customInstructions: analyst?.customInstructionText ?? ""
    )
    let workingDirectory = try workspaceProvider(product.id)
    var preferredThreadID = threadIDs[epic.id]

    if let recoveredThreadID = recoveredSession?.codexThreadID {
      do {
        let resumedThreadID = try await client.resumeReadOnlyThread(
          threadID: recoveredThreadID,
          workingDirectory: workingDirectory,
          developerInstructions: developerInstructions,
          model: analyst?.model
        )
        preferredThreadID = resumedThreadID
        threadIDs[epic.id] = resumedThreadID
        persistConversation(epicID: epic.id)
        if let recoveredTurnID = recoveredSession?.codexTurnID,
          let recoveredResponse = try? await client.completedAgentMessage(
            threadID: resumedThreadID,
            turnID: recoveredTurnID
          )
        {
          return recoveredResponse
        }
      } catch let error as CodexRPCError where error.isThreadNotFound {
        preferredThreadID = nil
      }
    }

    let standardPrompt = CodexEpicClarificationGenerator.finalPlanPrompt(
      product: product,
      epic: epic,
      existingItems: existingItems,
      rejectedSuggestions: rejectedSuggestions,
      verifiedKnowledge: planningKnowledge
    )
    if let preferredThreadID {
      do {
        return try await runEpicPlanStructuredTurn(
          token: token,
          client: client,
          store: store,
          sessionID: session.id,
          threadID: preferredThreadID,
          prompt: standardPrompt,
          effort: analyst?.reasoningEffort ?? "medium"
        )
      } catch let error as CodexRPCError where error.isThreadNotFound {
        operations.clearTurn(for: token)
      }
    }

    let replacementThreadID = try await client.startReadOnlyThread(
      workingDirectory: workingDirectory,
      developerInstructions: developerInstructions,
      model: analyst?.model
    )
    threadIDs[epic.id] = replacementThreadID
    persistConversation(epicID: epic.id)
    return try await runEpicPlanStructuredTurn(
      token: token,
      client: client,
      store: store,
      sessionID: session.id,
      threadID: replacementThreadID,
      prompt: CodexEpicClarificationGenerator.finalPlanRecoveryPrompt(
        product: product,
        epic: epic,
        existingItems: existingItems,
        rejectedSuggestions: rejectedSuggestions,
        messages: durableMessages,
        verifiedKnowledge: planningKnowledge
      ),
      effort: analyst?.reasoningEffort ?? "medium"
    )
  }

  private func runEpicPlanStructuredTurn(
    token: FeatureOperationToken<Operation>,
    client: CodexAppServerClient,
    store: SQLiteStore,
    sessionID: UUID,
    threadID: String,
    prompt: String,
    effort: String
  ) async throws -> String {
    let turnID = try await client.startStructuredTurn(
      threadID: threadID,
      prompt: prompt,
      effort: effort,
      outputSchema: CodexTicketSuggestionGenerator.epicOutputSchema
    )
    operations.recordTurn(CodexTurnIdentity(threadID: threadID, turnID: turnID), for: token)
    try await store.attachCodexTurn(
      sessionID: sessionID,
      threadID: threadID,
      turnID: turnID
    )
    return try await client.waitForFinalAgentMessage(threadID: threadID, turnID: turnID)
  }

  /// Handles the sanctioned final-plan escape: the turn returned outstanding
  /// questions instead of a plan, so the durable clarification conversation
  /// resumes with those questions and the placeholder suggestion session ends
  /// without a suggestion set. The durable write happens before the snapshot
  /// projection so an interruption can only lose presentation, never the
  /// questions.
  private func escapeEpicPlanningToQuestions(
    for epic: Epic,
    sessionID: UUID,
    message: String,
    questions: [TicketRefinementQuestion],
    fallbackMessages: [EpicPlanningConversationMessage]
  ) async throws {
    await operations.settle(.persistence(epic.id))
    guard let store = storeProvider(epic.productID) else {
      throw PersistenceError.recordNotFound("product store \(epic.productID)")
    }
    try await store.escapeTicketSuggestionSessionToQuestions(sessionID: sessionID)
    if selectedProductID() == epic.productID {
      removeSuggestionBatch(sessionID: sessionID)
    }

    let analystMessage = EpicPlanningConversationMessage(
      author: .businessAnalyst,
      body: message
    )
    var durable =
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
      ?? EpicPlanningConversationSnapshot(
        epicID: epic.id,
        messages: fallbackMessages,
        questions: [],
        isComplete: false,
        threadID: threadIDs[epic.id]
      )
    durable.messages.append(analystMessage)
    durable.questions = questions
    durable.isComplete = false
    durable.threadID = threadIDs[epic.id] ?? durable.threadID
    durable.updatedAt = Date()
    try await store.saveEpicPlanningConversation(durable)

    if var conversation = snapshot.conversations[epic.id] {
      conversation.messages = durable.messages
      conversation.questions = questions
      conversation.isRunning = false
      conversation.isGeneratingPlan = false
      conversation.isComplete = false
      conversation.errorMessage = nil
      updateSnapshot { $0.conversations[epic.id] = conversation }
    }

    await onOwnerNotification(
      OwnerNotification(
        id: analystMessage.id,
        productID: epic.productID,
        kind: .needsInput,
        target: OwnerNotificationTarget(kind: .epic, id: epic.id),
        title: "\(epic.displayTitle) needs your input",
        body: questions.first?.prompt ?? message,
        createdAt: analystMessage.createdAt
      )
    )
  }

  private func completeEpicPlanningConversation(
    for epic: Epic,
    proposalCount: Int,
    threadID: String?,
    fallbackMessages: [EpicPlanningConversationMessage]
  ) async throws {
    await operations.settle(.persistence(epic.id))
    guard let store = storeProvider(epic.productID) else {
      throw PersistenceError.recordNotFound("product store \(epic.productID)")
    }

    var durable =
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
      ?? EpicPlanningConversationSnapshot(
        epicID: epic.id,
        messages: fallbackMessages,
        questions: [],
        isComplete: false,
        threadID: threadID
      )
    if !durable.isComplete {
      durable.messages.append(
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body:
            "I’ve prepared the epic and \(proposalCount) proposed "
            + (proposalCount == 1 ? "ticket" : "tickets")
            + " for you to review in the tickets section."
        )
      )
    }
    durable.questions = []
    durable.isComplete = true
    durable.threadID = threadID ?? durable.threadID
    durable.updatedAt = Date()
    try await store.saveEpicPlanningConversation(durable)

    guard var conversation = snapshot.conversations[epic.id] else { return }
    conversation.messages = durable.messages
    conversation.questions = []
    conversation.hasStartedPlanning = durable.hasStartedPlanning ?? true
    conversation.isRunning = false
    conversation.isGeneratingPlan = false
    conversation.isComplete = true
    conversation.errorMessage = nil
    threadIDs[epic.id] = durable.threadID
    updateSnapshot { $0.conversations[epic.id] = conversation }
  }

  private func updateConversation(
    for epicID: UUID,
    _ update: (inout EpicPlanningConversationState) -> Void
  ) {
    guard var conversation = snapshot.conversations[epicID] else { return }
    update(&conversation)
    updateSnapshot { $0.conversations[epicID] = conversation }
    persistConversation(epicID: epicID)
  }

  private func persistConversation(epicID: UUID) {
    guard let conversation = snapshot.conversations[epicID] else { return }
    let capturedThreadID = threadIDs[epicID]
    operations.enqueue(
      .persistence(epicID),
      productID: conversation.productID
    ) { [weak self] in
      guard let self else { return }
      do {
        try await saveEpicPlanningConversation(
          conversation,
          threadID: capturedThreadID
        )
      } catch {
        onError(error, conversation.productID)
      }
    }
  }

  public func saveEpicPlanningConversation(
    _ conversation: EpicPlanningConversationState,
    threadID: String?
  ) async throws {
    guard let store = storeProvider(conversation.productID) else {
      throw PersistenceError.recordNotFound("product store \(conversation.productID)")
    }
    try await store.saveEpicPlanningConversation(
      EpicPlanningConversationSnapshot(
        epicID: conversation.epicID,
        messages: conversation.messages,
        questions: conversation.questions,
        isComplete: conversation.isComplete,
        threadID: threadID,
        hasStartedPlanning: conversation.hasStartedPlanning
      )
    )
  }
}

extension EpicPlanningWorkflowCoordinator {
  public func retryEpicPlan(sessionID: UUID) {
    guard
      availabilityProvider().canPlanEpic,
      let failedSession = suggestionBatch(sessionID: sessionID)?.session,
      let store = storeProvider(failedSession.productID),
      failedSession.status == .failed,
      let epicID = failedSession.epicID
    else { return }

    ownerCommands.start(UUID(), productID: failedSession.productID) { [weak self] _ in
      guard let self else { return }
      do {
        let restartedSession = try await store.retryTicketSuggestionSession(
          sessionID: failedSession.id
        )
        guard selectedProductID() == failedSession.productID else {
          try? await store.failTicketSuggestionSession(
            sessionID: restartedSession.id,
            message: "Epic planning was interrupted by a product change. You can safely try again."
          )
          return
        }
        guard let epic = try await store.fetchEpics(productID: failedSession.productID)
          .first(where: { $0.id == epicID })
        else {
          throw PersistenceError.recordNotFound("epic \(epicID)")
        }
        replaceSuggestionBatch(
          TicketSuggestionBatch(
            session: restartedSession,
            suggestions: []
          )
        )
        await restoreEpicPlanningConversation(for: epic)
        generateEpicPlan(epic)
      } catch {
        onError(error, failedSession.productID)
      }
    }
  }

  public func autosuggestTickets() {
    guard
      availabilityProvider().canAutosuggestTickets,
      let productID = selectedProductID(),
      let store = storeProvider(productID),
      let client = clientProvider(),
      let product = productProvider(productID)
    else { return }

    let previouslyRejectedSuggestions = snapshot.suggestionBatches
      .flatMap(\.suggestions)
      .filter { $0.status == .rejected }
    operations.start(
      .suggestionGeneration,
      productID: product.id,
      replacing: true
    ) { [weak self] token in
      guard let self else { return }
      var session: SuggestionSession?
      do {
        let existingItems = try await store.fetchWorkItems(productID: product.id)
          .filter { $0.state != .cancelled }
        let analyst = try await store.fetchAgentProfiles(productID: product.id)
          .first { $0.role == .businessAnalyst }
        let verifiedKnowledge = KnowledgeContextSelector.mandatoryPages(
          in: try await store.fetchKnowledgePages(productID: product.id)
        )
        let startedSession = try await store.beginTicketSuggestionSession(
          productID: product.id
        )
        session = startedSession
        if selectedProductID() == product.id {
          replaceSuggestionBatch(
            TicketSuggestionBatch(
              session: startedSession,
              suggestions: []
            )
          )
        }

        let threadID = try await client.startReadOnlyThread(
          workingDirectory: try workspaceProvider(product.id),
          developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
            productInstructions: inheritedInstructions(product),
            customInstructions: analyst?.customInstructionText ?? ""
          ),
          model: analyst?.model
        )
        let turnID = try await client.startStructuredTurn(
          threadID: threadID,
          prompt: CodexTicketSuggestionGenerator.prompt(
            product: product,
            existingItems: existingItems,
            rejectedSuggestions: previouslyRejectedSuggestions,
            verifiedKnowledge: verifiedKnowledge
          ),
          effort: analyst?.reasoningEffort ?? "medium",
          outputSchema: CodexTicketSuggestionGenerator.outputSchema
        )
        operations.recordTurn(
          CodexTurnIdentity(threadID: threadID, turnID: turnID),
          for: token
        )
        try await store.attachCodexTurn(
          sessionID: startedSession.id,
          threadID: threadID,
          turnID: turnID
        )

        let response = try await client.waitForFinalAgentMessage(
          threadID: threadID,
          turnID: turnID
        )
        try Task.checkCancellation()
        let drafts: [TicketSuggestionDraft]
        do {
          drafts = try CodexTicketSuggestionGenerator.decode(
            response,
            existingItems: existingItems
          )
        } catch let validationError as TicketSuggestionGenerationError {
          let repairTurnID = try await client.startStructuredTurn(
            threadID: threadID,
            prompt: CodexTicketSuggestionGenerator.repairPrompt(
              validationError: validationError.localizedDescription,
              existingItems: existingItems
            ),
            effort: analyst?.reasoningEffort ?? "medium",
            outputSchema: CodexTicketSuggestionGenerator.outputSchema
          )
          operations.recordTurn(
            CodexTurnIdentity(threadID: threadID, turnID: repairTurnID),
            for: token
          )
          try await store.attachCodexTurn(
            sessionID: startedSession.id,
            threadID: threadID,
            turnID: repairTurnID
          )
          let repairedResponse = try await client.waitForFinalAgentMessage(
            threadID: threadID,
            turnID: repairTurnID
          )
          try Task.checkCancellation()
          drafts = try CodexTicketSuggestionGenerator.decode(
            repairedResponse,
            existingItems: existingItems
          )
        }
        let completedBatch = try await store.completeTicketSuggestionSession(
          sessionID: startedSession.id,
          drafts: drafts
        )
        operations.clearTurn(for: token)
        if selectedProductID() == product.id {
          replaceSuggestionBatch(completedBatch)
        }
        await onReloadSelectedProduct(product.id)
      } catch is CancellationError {
        operations.clearTurn(for: token)
        if let session, !isShuttingDown() {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: "Ticket suggestion was interrupted. You can safely try again."
          )
          let failedBatch = try? await store.fetchTicketSuggestionBatch(sessionID: session.id)
          if selectedProductID() == product.id, let failedBatch {
            replaceSuggestionBatch(failedBatch)
          }
        }
      } catch {
        operations.clearTurn(for: token)
        if let session {
          try? await store.failTicketSuggestionSession(
            sessionID: session.id,
            message: error.localizedDescription
          )
          let failedBatch = try? await store.fetchTicketSuggestionBatch(sessionID: session.id)
          if selectedProductID() == product.id, let failedBatch {
            replaceSuggestionBatch(failedBatch)
          }
        } else if selectedProductID() == product.id {
          onError(error, product.id)
        }
      }
    }
  }

  public func updateTicketSuggestion(
    _ suggestion: TicketSuggestion,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    suggestedRole: AgentRole,
    priority: WorkItemPriority,
    rationale: String,
    completion: ((TicketSuggestion?) -> Void)? = nil
  ) {
    guard
      let batch = suggestionBatch(containing: suggestion.id),
      let store = storeProvider(batch.session.productID),
      suggestion.status == .proposed,
      !snapshot.isDecidingSuggestions
    else {
      completion?(nil)
      return
    }
    let productID = batch.session.productID
    updateSnapshot { $0.isDecidingSuggestions = true }
    ownerCommands.start(UUID(), productID: productID) { [weak self] _ in
      guard let self else { return }
      defer { updateSnapshot { $0.isDecidingSuggestions = false } }
      do {
        let updatedBatch = try await store.updateTicketSuggestion(
          id: suggestion.id,
          title: title,
          type: type,
          body: body,
          acceptanceCriteria: acceptanceCriteria,
          suggestedRole: suggestedRole,
          priority: priority,
          rationale: rationale
        )
        if selectedProductID() == productID {
          replaceSuggestionBatch(updatedBatch)
        }
        await onReloadSelectedProduct(productID)
        completion?(updatedBatch.suggestions.first { $0.id == suggestion.id })
      } catch {
        onError(error, productID)
        completion?(nil)
      }
    }
  }

  public func decideTicketSuggestion(
    _ suggestion: TicketSuggestion,
    accept: Bool,
    completion: ((WorkItem?) -> Void)? = nil
  ) {
    guard
      let batch = suggestionBatch(containing: suggestion.id),
      let store = storeProvider(batch.session.productID),
      !snapshot.isDecidingSuggestions
    else { return }
    let productID = batch.session.productID
    let previouslyProposedIDs = Set(
      batch.suggestions
        .filter { $0.status == .proposed }
        .map(\.id)
    )
    updateSnapshot { $0.isDecidingSuggestions = true }
    ownerCommands.start(UUID(), productID: productID) { [weak self] _ in
      guard let self else { return }
      defer { updateSnapshot { $0.isDecidingSuggestions = false } }
      do {
        let productProfiles = try await store.fetchAgentProfiles(productID: productID)
        let decidedBatch = try await store.decideTicketSuggestion(
          id: suggestion.id,
          decision: accept ? .accepted : .rejected
        )
        if selectedProductID() == productID {
          replaceSuggestionBatch(decidedBatch)
        }
        var acceptedItemsBySuggestionID: [UUID: WorkItem] = [:]
        if accept {
          let createdItems = try await store.fetchWorkItems(productID: productID)
          let createdItemsByID = Dictionary(uniqueKeysWithValues: createdItems.map { ($0.id, $0) })
          for acceptedSuggestion in decidedBatch.suggestions
          where previouslyProposedIDs.contains(acceptedSuggestion.id)
            && acceptedSuggestion.status == .accepted
          {
            guard
              let acceptedID = acceptedSuggestion.acceptedWorkItemID,
              var created = createdItemsByID[acceptedID]
            else { continue }
            if let owner = TicketOwnerRouter.owner(
              for: created,
              profiles: productProfiles,
              suggestedRole: acceptedSuggestion.suggestedRole
            ) {
              created = try await store.assignWorkItemOwner(
                id: created.id,
                profileID: owner.id
              )
            }
            acceptedItemsBySuggestionID[acceptedSuggestion.id] = created
          }
        }
        await onReloadSelectedProduct(productID)
        completion?(acceptedItemsBySuggestionID[suggestion.id])
      } catch {
        onError(error, productID)
        completion?(nil)
      }
    }
  }

  public func rejectTicketSuggestion(
    _ suggestion: TicketSuggestion,
    completion: (() -> Void)? = nil
  ) {
    guard
      let batch = suggestionBatch(containing: suggestion.id),
      let store = storeProvider(batch.session.productID),
      !snapshot.isDecidingSuggestions
    else { return }
    let productID = batch.session.productID
    updateSnapshot { $0.isDecidingSuggestions = true }
    ownerCommands.start(UUID(), productID: productID) { [weak self] _ in
      guard let self else { return }
      defer { updateSnapshot { $0.isDecidingSuggestions = false } }
      do {
        let decidedBatch = try await store.rejectTicketSuggestionCascade(id: suggestion.id)
        if selectedProductID() == productID {
          replaceSuggestionBatch(decidedBatch)
        }
        await onReloadSelectedProduct(productID)
        completion?()
      } catch {
        onError(error, productID)
      }
    }
  }

  public func decideAllTicketSuggestions(
    sessionID: UUID,
    accept: Bool,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard let batch = suggestionBatch(sessionID: sessionID) else {
      completion?(false)
      return
    }
    let suggestions = batch.suggestions
      .filter { $0.status == .proposed }
      .sorted { $0.position < $1.position }
    decideTicketSuggestionGroup(
      suggestions,
      accept: accept,
      completion: completion
    )
  }

  public func decideTicketSuggestionGroup(
    _ suggestions: [TicketSuggestion],
    accept: Bool,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard
      let firstSuggestion = suggestions.first,
      let batch = suggestionBatch(containing: firstSuggestion.id),
      suggestions.allSatisfy({ $0.sessionID == batch.session.id }),
      let store = storeProvider(batch.session.productID),
      !snapshot.isDecidingSuggestions
    else {
      completion?(false)
      return
    }
    let productID = batch.session.productID
    let proposedIDs = Set(
      batch.suggestions
        .filter { $0.status == .proposed }
        .map(\.id)
    )
    let decisions =
      suggestions
      .filter { proposedIDs.contains($0.id) }
      .sorted { $0.position < $1.position }
    guard !decisions.isEmpty else {
      completion?(false)
      return
    }

    updateSnapshot { $0.isDecidingSuggestions = true }
    ownerCommands.start(UUID(), productID: productID) { [weak self] _ in
      guard let self else { return }
      defer { updateSnapshot { $0.isDecidingSuggestions = false } }
      do {
        let productProfiles = try await store.fetchAgentProfiles(productID: productID)
        let decidedBatch = try await store.decideTicketSuggestionGroup(
          ids: decisions.map(\.id),
          decision: accept ? .accepted : .rejected
        )
        if selectedProductID() == productID {
          replaceSuggestionBatch(decidedBatch)
        }
        if accept {
          let createdItems = try await store.fetchWorkItems(productID: productID)
          let createdItemsByID = Dictionary(uniqueKeysWithValues: createdItems.map { ($0.id, $0) })
          for acceptedSuggestion in decidedBatch.suggestions
          where proposedIDs.contains(acceptedSuggestion.id)
            && acceptedSuggestion.status == .accepted
          {
            guard
              let acceptedID = acceptedSuggestion.acceptedWorkItemID,
              let created = createdItemsByID[acceptedID],
              let owner = TicketOwnerRouter.owner(
                for: created,
                profiles: productProfiles,
                suggestedRole: acceptedSuggestion.suggestedRole
              )
            else { continue }
            _ = try await store.assignWorkItemOwner(id: created.id, profileID: owner.id)
          }
        }
        await onReloadSelectedProduct(productID)
        completion?(true)
      } catch {
        onError(error, productID)
        completion?(false)
      }
    }
  }

  public func dismissFailedTicketSuggestions(sessionID: UUID) {
    guard
      let session = suggestionBatch(sessionID: sessionID)?.session,
      let store = storeProvider(session.productID),
      session.status == .failed
    else { return }
    ownerCommands.start(UUID(), productID: session.productID) { [weak self] _ in
      guard let self else { return }
      do {
        try await store.dismissTicketSuggestionSession(sessionID: session.id)
        if selectedProductID() == session.productID {
          removeSuggestionBatch(sessionID: session.id)
        }
      } catch {
        onError(error, session.productID)
      }
    }
  }
}

extension EpicPlanningWorkflowCoordinator {
  public func recoverTicketSuggestionSessionIfNeeded() async {
    guard
      let batch = snapshot.suggestionBatches.first(where: { candidate in
        guard let epicID = candidate.session.epicID else { return false }
        return !recoveredSessionIDs.contains(candidate.session.id)
          && recoveryPolicy.action(
            for: candidate.session,
            hasLiveRun: operations.isActive(.planning(epicID))
          ) != .none
      }),
      let store = storeProvider(batch.session.productID),
      clientProvider() != nil,
      let epicID = batch.session.epicID,
      let epic = try? await store.fetchEpics(productID: batch.session.productID)
        .first(where: { $0.id == epicID })
    else { return }
    recoveredSessionIDs.insert(batch.session.id)
    let session = batch.session
    let productID = session.productID

    switch recoveryPolicy.action(
      for: session,
      hasLiveRun: operations.isActive(.planning(epicID))
    ) {
    case .none:
      return
    case .resumeInterruptedGeneration:
      break
    case .retryLegacyInterruption:
      do {
        let restartedSession = try await store.retryTicketSuggestionSession(
          sessionID: session.id
        )
        guard selectedProductID() == productID else {
          try? await store.failTicketSuggestionSession(
            sessionID: restartedSession.id,
            message: "Epic planning recovery was interrupted by a product change."
          )
          return
        }
        replaceSuggestionBatch(
          TicketSuggestionBatch(
            session: restartedSession,
            suggestions: []
          )
        )
      } catch {
        onError(error, productID)
        return
      }
    }

    guard selectedProductID() == productID else { return }
    await restoreEpicPlanningConversation(for: epic)
    generateEpicPlan(epic, recovering: session)
  }

  public func cancel(
    productID: UUID,
    preservingEpicPlanning: Bool
  ) async {
    await ownerCommands.cancel(productID: productID)
    if operations.productID(for: .suggestionGeneration) == productID {
      await operations.cancel(.suggestionGeneration) { [weak self] turn in
        guard let client = self?.clientProvider() else { return }
        try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
      }
    }
    guard !preservingEpicPlanning else { return }
    for key in operations.activeKeys(productID: productID) {
      switch key {
      case .planning:
        await operations.cancel(key) { [weak self] turn in
          guard let client = self?.clientProvider() else { return }
          try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
        }
      case .persistence:
        await operations.cancel(key)
      case .suggestionGeneration, .interruption:
        break
      }
    }
    for epicID in Array(threadIDs.keys)
    where snapshot.conversations[epicID]?.productID == productID {
      threadIDs[epicID] = nil
    }
  }

  public func shutdown() async {
    await ownerCommands.shutdown()
    await operations.shutdown { [weak self] turn in
      guard let client = self?.clientProvider() else { return }
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
    await operations.settleAll()
    threadIDs = [:]
  }

  public func settleAll() async {
    await ownerCommands.settleAll()
    await operations.settleAll()
  }

  private func updateSnapshot(
    _ update: (inout EpicPlanningWorkflowSnapshot) -> Void
  ) {
    var updated = snapshot
    update(&updated)
    guard updated != snapshot else { return }
    snapshot = updated
    onSnapshotChange(updated)
  }
}