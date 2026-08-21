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
  public var conversation: EpicPlanningConversationState?
  public var suggestionBatches: [TicketSuggestionBatch]
  public var isDecidingSuggestions: Bool

  public init(
    conversation: EpicPlanningConversationState? = nil,
    suggestionBatches: [TicketSuggestionBatch] = [],
    isDecidingSuggestions: Bool = false
  ) {
    self.conversation = conversation
    self.suggestionBatches = suggestionBatches
    self.isDecidingSuggestions = isDecidingSuggestions
  }

  public var isPlanning: Bool {
    conversation?.isRunning == true || conversation?.isGeneratingPlan == true
  }

  public var isSuggestionGenerationRunning: Bool {
    suggestionBatches.contains { $0.session.status == .generating }
  }
}

@MainActor
public final class EpicPlanningWorkflowCoordinator {
  private enum Operation: Hashable {
    case planning
    case suggestionGeneration
    case persistence
    case interruption
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
  private var threadID: String?
  private var recoveredSessionIDs: Set<UUID> = []

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
    operations.isActive(.planning) || operations.isActive(.suggestionGeneration)
  }

  public var isPlanning: Bool {
    operations.isActive(.planning)
  }

  public var activePlanningTurn: CodexTurnIdentity? {
    operations.turn(for: .planning)
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
    self.threadID = threadID
    updateSnapshot { $0.conversation = conversation }
  }

  public func awaitPersistence() async {
    await operations.settle(.persistence)
    await ownerCommands.settleAll()
  }
  public func clearSelectedProductProjection() {
    updateSnapshot {
      $0.suggestionBatches = []
      $0.isDecidingSuggestions = false
    }
  }

  public func restoreEpicPlanningConversation(for epic: Epic) async {
    guard snapshot.conversation?.epicID != epic.id else { return }
    guard
      snapshot.conversation?.isRunning != true,
      snapshot.conversation?.isGeneratingPlan != true
    else { return }
    await operations.settle(.persistence)
    guard
      !Task.isCancelled,
      selectedProductID() == epic.productID,
      snapshot.conversation?.isRunning != true,
      snapshot.conversation?.isGeneratingPlan != true,
      let store = storeProvider(epic.productID)
    else { return }

    do {
      guard var durable = try await store.fetchEpicPlanningConversation(epicID: epic.id) else {
        threadID = nil
        updateSnapshot { $0.conversation = nil }
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
        selectedProductID() == epic.productID,
        snapshot.conversation?.isRunning != true,
        snapshot.conversation?.isGeneratingPlan != true
      else { return }
      threadID = durable.threadID
      let hasStartedPlanning = durable.hasStartedPlanning ?? true
      updateSnapshot {
        $0.conversation = EpicPlanningConversationState(
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
      let product = productProvider(epic.productID),
      epic.status == .open,
      let store = storeProvider(epic.productID)
    else { return }

    let existingMessages =
      snapshot.conversation?.epicID == epic.id
      ? snapshot.conversation?.messages ?? []
      : []
    updateSnapshot {
      $0.conversation = EpicPlanningConversationState(
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
    persistConversation()
    operations.start(.planning, productID: product.id, replacing: true) { [weak self] token in
      guard let self else { return }
      do {
        guard let client = clientProvider() else { throw CodexClientError.notConnected }
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
        threadID = newThreadID
        persistConversation()
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
      let conversation = snapshot.conversation,
      conversation.epicID == epic.id,
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
      threadID = nil
      updateConversation(for: epic.id) {
        $0.questions = []
        $0.hasStartedPlanning = false
        $0.errorMessage = nil
      }
      planEpic(epic)
    }
  }

  public func cancelEpicPlanning() {
    operations.cancelTask(.planning)
    guard let turn = operations.turn(for: .planning) else { return }
    operations.start(.interruption, productID: nil, replacing: true) { [weak self] _ in
      guard let self, let client = clientProvider() else { return }
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
  }

  public func clearEpicPlanningConversation(for epicID: UUID) {
    guard
      let conversation = snapshot.conversation,
      conversation.epicID == epicID
    else { return }
    cancelEpicPlanning()
    threadID = nil
    updateSnapshot { $0.conversation = nil }
    guard let store = storeProvider(conversation.productID) else { return }
    operations.enqueue(.persistence, productID: conversation.productID) { [weak self] in
      do {
        try await store.deleteEpicPlanningConversation(epicID: epicID)
      } catch {
        self?.onError(error, conversation.productID)
      }
    }
  }

  public func settlePlanning() async {
    await operations.settle(.planning)
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
      snapshot.conversation?.epicID == epic.id,
      snapshot.conversation?.isRunning == false,
      snapshot.conversation?.isGeneratingPlan == false,
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
    let messages = snapshot.conversation?.messages ?? []
    let preferredThreadID = requiresReplacementThread ? nil : threadID
    operations.start(.planning, productID: product.id, replacing: true) { [weak self] token in
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
    threadID = replacementThreadID
    persistConversation()
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
    await operations.settle(.persistence)
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
    operations.start(.planning, productID: product.id, replacing: true) { [weak self] token in
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
        let plan: EpicPlanDraft
        do {
          plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(
            response,
            existingItems: existingItems
          )
        } catch let validationError as TicketSuggestionGenerationError {
          guard let repairThreadID = threadID else {
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
          plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(
            repairedResponse,
            existingItems: existingItems
          )
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
        updateConversation(for: epic.id) {
          $0.isGeneratingPlan = false
          $0.errorMessage = error.localizedDescription
        }
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
    var preferredThreadID = threadID

    if let recoveredThreadID = recoveredSession?.codexThreadID {
      do {
        let resumedThreadID = try await client.resumeReadOnlyThread(
          threadID: recoveredThreadID,
          workingDirectory: workingDirectory,
          developerInstructions: developerInstructions,
          model: analyst?.model
        )
        preferredThreadID = resumedThreadID
        threadID = resumedThreadID
        persistConversation()
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
    threadID = replacementThreadID
    persistConversation()
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

  private func completeEpicPlanningConversation(
    for epic: Epic,
    proposalCount: Int,
    threadID: String?,
    fallbackMessages: [EpicPlanningConversationMessage]
  ) async throws {
    await operations.settle(.persistence)
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

    guard
      var conversation = snapshot.conversation,
      conversation.productID == epic.productID,
      conversation.epicID == epic.id
    else { return }
    conversation.messages = durable.messages
    conversation.questions = []
    conversation.hasStartedPlanning = durable.hasStartedPlanning ?? true
    conversation.isRunning = false
    conversation.isGeneratingPlan = false
    conversation.isComplete = true
    conversation.errorMessage = nil
    self.threadID = durable.threadID
    updateSnapshot { $0.conversation = conversation }
  }

  private func updateConversation(
    for epicID: UUID,
    _ update: (inout EpicPlanningConversationState) -> Void
  ) {
    guard
      var conversation = snapshot.conversation,
      conversation.epicID == epicID
    else { return }
    update(&conversation)
    updateSnapshot { $0.conversation = conversation }
    persistConversation()
  }

  private func persistConversation() {
    guard let conversation = snapshot.conversation else { return }
    let capturedThreadID = threadID
    operations.enqueue(.persistence, productID: conversation.productID) { [weak self] in
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
      let batch = snapshot.suggestionBatches.first(where: {
        !recoveredSessionIDs.contains($0.session.id)
          && recoveryPolicy.action(for: $0.session) != .none
          && $0.session.epicID != nil
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

    switch recoveryPolicy.action(for: session) {
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
    if operations.productID(for: .planning) == productID {
      await operations.cancel(.planning) { [weak self] turn in
        guard let client = self?.clientProvider() else { return }
        try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
      }
    }
    if operations.productID(for: .persistence) == productID {
      await operations.cancel(.persistence)
    }
    threadID = nil
  }

  public func shutdown() async {
    await ownerCommands.shutdown()
    await operations.shutdown { [weak self] turn in
      guard let client = self?.clientProvider() else { return }
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
    await operations.settleAll()
    threadID = nil
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