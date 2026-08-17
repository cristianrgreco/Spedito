import Foundation

public struct TicketRefinementSessionResult: Equatable, Sendable {
  public let base: SprintPlanningTicketSnapshot
  public let reply: TicketRefinementReply?
  public let errorMessage: String?

  public init(
    base: SprintPlanningTicketSnapshot,
    reply: TicketRefinementReply?,
    errorMessage: String?
  ) {
    self.base = base
    self.reply = reply
    self.errorMessage = errorMessage
  }
}

public struct TicketConversationSessionResult: Equatable, Sendable {
  public let base: SprintPlanningTicketSnapshot
  public let recipientID: UUID
  public let reply: TicketConversationReply

  public init(
    base: SprintPlanningTicketSnapshot,
    recipientID: UUID,
    reply: TicketConversationReply
  ) {
    self.base = base
    self.recipientID = recipientID
    self.reply = reply
  }
}

public struct EpicPlanningConversationState: Equatable, Sendable {
  public let productID: UUID
  public let epicID: UUID
  public var messages: [EpicPlanningConversationMessage]
  public var questions: [TicketRefinementQuestion]
  public var hasStartedPlanning: Bool
  public var isRunning: Bool
  public var isGeneratingPlan: Bool
  public var isComplete: Bool
  public var errorMessage: String?

  public init(
    productID: UUID,
    epicID: UUID,
    messages: [EpicPlanningConversationMessage],
    questions: [TicketRefinementQuestion],
    hasStartedPlanning: Bool,
    isRunning: Bool,
    isGeneratingPlan: Bool,
    isComplete: Bool,
    errorMessage: String?
  ) {
    self.productID = productID
    self.epicID = epicID
    self.messages = messages
    self.questions = questions
    self.hasStartedPlanning = hasStartedPlanning
    self.isRunning = isRunning
    self.isGeneratingPlan = isGeneratingPlan
    self.isComplete = isComplete
    self.errorMessage = errorMessage
  }
}

public struct PlanningConversationWorkflowAvailability: Equatable, Sendable {
  public let isCodexConnected: Bool
  public let isSprintPlanningMessageRunning: Bool
  public let isGeneratingSprintGoal: Bool
  public let isSuggestionGenerationRunning: Bool
  public let isEpicPlanningRunning: Bool
  public let isEpicPlanGenerationRunning: Bool

  public init(
    isCodexConnected: Bool,
    isSprintPlanningMessageRunning: Bool,
    isGeneratingSprintGoal: Bool,
    isSuggestionGenerationRunning: Bool,
    isEpicPlanningRunning: Bool,
    isEpicPlanGenerationRunning: Bool
  ) {
    self.isCodexConnected = isCodexConnected
    self.isSprintPlanningMessageRunning = isSprintPlanningMessageRunning
    self.isGeneratingSprintGoal = isGeneratingSprintGoal
    self.isSuggestionGenerationRunning = isSuggestionGenerationRunning
    self.isEpicPlanningRunning = isEpicPlanningRunning
    self.isEpicPlanGenerationRunning = isEpicPlanGenerationRunning
  }
}

public struct PlanningConversationWorkflowContext: Sendable {
  public let product: Product
  public let profiles: [AgentProfile]
  public let workItems: [WorkItem]
  public let epics: [Epic]
  public let suggestionBatches: [TicketSuggestionBatch]

  public init(
    product: Product,
    profiles: [AgentProfile],
    workItems: [WorkItem],
    epics: [Epic],
    suggestionBatches: [TicketSuggestionBatch]
  ) {
    self.product = product
    self.profiles = profiles
    self.workItems = workItems
    self.epics = epics
    self.suggestionBatches = suggestionBatches
  }
}

public struct PlanningConversationWorkflowSnapshot: Equatable, Sendable {
  public var refiningWorkItemID: UUID?
  public var ticketConversationWorkItemID: UUID?
  public var ticketConversationRecipientID: UUID?
  public var ticketConversationActivity: CodexLiveActivity?
  public var epicConversationEpicID: UUID?
  public var epicConversationRecipientID: UUID?
  public var ticketRefinementResults: [UUID: TicketRefinementSessionResult]
  public var ticketConversationResults: [UUID: TicketConversationSessionResult]

  public init(
    refiningWorkItemID: UUID? = nil,
    ticketConversationWorkItemID: UUID? = nil,
    ticketConversationRecipientID: UUID? = nil,
    ticketConversationActivity: CodexLiveActivity? = nil,
    epicConversationEpicID: UUID? = nil,
    epicConversationRecipientID: UUID? = nil,
    ticketRefinementResults: [UUID: TicketRefinementSessionResult] = [:],
    ticketConversationResults: [UUID: TicketConversationSessionResult] = [:]
  ) {
    self.refiningWorkItemID = refiningWorkItemID
    self.ticketConversationWorkItemID = ticketConversationWorkItemID
    self.ticketConversationRecipientID = ticketConversationRecipientID
    self.ticketConversationActivity = ticketConversationActivity
    self.epicConversationEpicID = epicConversationEpicID
    self.epicConversationRecipientID = epicConversationRecipientID
    self.ticketRefinementResults = ticketRefinementResults
    self.ticketConversationResults = ticketConversationResults
  }

  public var isTicketConversationMessageRunning: Bool {
    ticketConversationWorkItemID != nil
  }

  public var isEpicConversationMessageRunning: Bool {
    epicConversationEpicID != nil
  }

  public var hasActiveOperation: Bool {
    refiningWorkItemID != nil
      || ticketConversationWorkItemID != nil
      || epicConversationEpicID != nil
  }
}

@MainActor
public final class PlanningConversationWorkflowCoordinator {
  private struct SourceRecipientKey: Hashable {
    let productID: UUID
    let sourceID: UUID
    let profileID: UUID
  }

  private enum TurnKind: Hashable {
    case ticketRefinement
    case ticketConversation
    case epicConversation
  }
  private struct TurnIdentity {
    let threadID: String
    let turnID: String
  }


  private struct ActiveTurn {
    let operationID: UUID
    let productID: UUID
    let identity: TurnIdentity
    let client: CodexAppServerClient
  }

  private struct InterruptionOperation {
    let token: UUID
    let productID: UUID
    let task: Task<Void, Never>
  }

  private struct ActivityOperation {
    let token: UUID
    let productID: UUID
    let task: Task<Void, Never>
  }

  public private(set) var snapshot = PlanningConversationWorkflowSnapshot()

  private let storeProvider: (UUID) -> SQLiteStore?
  private let clientProvider: () -> CodexAppServerClient?
  private let selectedProductID: () -> UUID?
  private let contextProvider: (UUID) -> PlanningConversationWorkflowContext?
  private let availabilityProvider: () -> PlanningConversationWorkflowAvailability
  private let workspaceProvider: (UUID) throws -> URL
  private let inheritedInstructions: (Product) -> String
  private let awaitEpicPersistence: () async -> Void
  private let onSnapshotChange: (PlanningConversationWorkflowSnapshot) -> Void
  private let onEpicConversationChange: (EpicPlanningConversationState, String?) -> Void
  private let onOwnerNotification: (OwnerNotification) async -> Void
  private let onSelectedActivityChange: (UUID, [ActivityEvent]) -> Void
  private let onReloadSelectedProduct: (UUID) async -> Void

  private var activeTurns: [TurnKind: ActiveTurn] = [:]
  private var interruptionOperations: [TurnKind: InterruptionOperation] = [:]
  private var ticketThreadIDs: [SourceRecipientKey: String] = [:]
  private var epicThreadIDs: [SourceRecipientKey: String] = [:]
  private var ticketActivityOperation: ActivityOperation?

  public init(
    storeProvider: @escaping (UUID) -> SQLiteStore?,
    clientProvider: @escaping () -> CodexAppServerClient?,
    selectedProductID: @escaping () -> UUID?,
    contextProvider: @escaping (UUID) -> PlanningConversationWorkflowContext?,
    availabilityProvider: @escaping () -> PlanningConversationWorkflowAvailability,
    workspaceProvider: @escaping (UUID) throws -> URL,
    inheritedInstructions: @escaping (Product) -> String,
    awaitEpicPersistence: @escaping () async -> Void,
    onSnapshotChange: @escaping (PlanningConversationWorkflowSnapshot) -> Void,
    onEpicConversationChange: @escaping (EpicPlanningConversationState, String?) -> Void,
    onOwnerNotification: @escaping (OwnerNotification) async -> Void,
    onSelectedActivityChange: @escaping (UUID, [ActivityEvent]) -> Void,
    onReloadSelectedProduct: @escaping (UUID) async -> Void
  ) {
    self.storeProvider = storeProvider
    self.clientProvider = clientProvider
    self.selectedProductID = selectedProductID
    self.contextProvider = contextProvider
    self.availabilityProvider = availabilityProvider
    self.workspaceProvider = workspaceProvider
    self.inheritedInstructions = inheritedInstructions
    self.awaitEpicPersistence = awaitEpicPersistence
    self.onSnapshotChange = onSnapshotChange
    self.onEpicConversationChange = onEpicConversationChange
    self.onOwnerNotification = onOwnerNotification
    self.onSelectedActivityChange = onSelectedActivityChange
    self.onReloadSelectedProduct = onReloadSelectedProduct
  }

  public var isBusy: Bool {
    snapshot.hasActiveOperation
      || !activeTurns.isEmpty
      || !interruptionOperations.isEmpty
      || ticketActivityOperation != nil
  }

  public func refineTicket(_ item: WorkItem) async throws -> TicketRefinementReply {
    let availability = availabilityProvider()
    guard
      availability.isCodexConnected,
      !availability.isSuggestionGenerationRunning,
      !availability.isSprintPlanningMessageRunning,
      !availability.isGeneratingSprintGoal,
      !snapshot.isTicketConversationMessageRunning,
      !snapshot.isEpicConversationMessageRunning,
      snapshot.refiningWorkItemID == nil,
      let store = storeProvider(item.productID),
      let client = clientProvider(),
      let context = contextProvider(item.productID),
      context.product.id == item.productID,
      let analyst = context.profiles.first(where: { $0.role == .businessAnalyst })
    else {
      if snapshot.hasActiveOperation
        || availability.isSprintPlanningMessageRunning
        || availability.isSuggestionGenerationRunning
      {
        throw TicketRefinementGenerationError.anotherCodexTaskIsRunning
      }
      throw CodexClientError.notConnected
    }

    let operationID = UUID()
    let refinementBase = Self.ticketSnapshot(for: item)
    updateSnapshot {
      $0.ticketRefinementResults.removeValue(forKey: item.id)
      $0.ticketConversationResults.removeValue(forKey: item.id)
      $0.refiningWorkItemID = item.id
    }
    defer {
      finishTurn(.ticketRefinement, operationID: operationID)
      updateSnapshot {
        if $0.refiningWorkItemID == item.id {
          $0.refiningWorkItemID = nil
        }
      }
    }

    do {
      let workingDirectory = try workspaceProvider(context.product.id)
      let conversation = try await store.fetchComments(workItemID: item.id)
      let activeItems = try await store.fetchWorkItems(productID: context.product.id)
        .filter { $0.state != .cancelled }
      let activeItemIDs = Set(activeItems.map(\.id))
      let activeDependencies = try await store.fetchWorkItemDependencies(
        productID: context.product.id
      ).filter {
        activeItemIDs.contains($0.workItemID)
          && activeItemIDs.contains($0.dependsOnWorkItemID)
      }
      let productEpics = try await store.fetchEpics(productID: context.product.id)
      let threadID = try await client.startReadOnlyThread(
        workingDirectory: workingDirectory,
        developerInstructions: CodexTicketRefinementGenerator.developerInstructions(
          productInstructions: inheritedInstructions(context.product),
          customInstructions: analyst.customInstructionText
        ),
        model: analyst.model
      )
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketRefinementGenerator.prompt(
          product: context.product,
          item: item,
          epic: item.epicID.flatMap { epicID in
            productEpics.first { $0.id == epicID }
          },
          existingItems: activeItems,
          dependencies: activeDependencies,
          conversation: conversation
        ),
        effort: analyst.reasoningEffort,
        outputSchema: CodexTicketRefinementGenerator.outputSchema
      )
      recordTurn(
        .ticketRefinement,
        operationID: operationID,
        productID: context.product.id,
        client: client,
        threadID: threadID,
        turnID: turnID
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let reply = try CodexTicketRefinementGenerator.decode(
        response,
        currentItem: item,
        validRelatedItems: activeItems
      )
      let sourceComment: TicketComment?
      if reply.proposal.missingQuestions.isEmpty {
        _ = try await applyCompletedTicketRefinement(
          reply.proposal,
          to: item,
          store: store
        )
        sourceComment = try? await store.appendComment(
          workItemID: item.id,
          authorKind: .agent,
          authorName: analyst.name,
          body: reply.ticketCommentBody
        )
      } else {
        sourceComment = try await store.appendComment(
          workItemID: item.id,
          authorKind: .agent,
          authorName: analyst.name,
          body: reply.ticketCommentBody
        )
      }
      if let sourceComment {
        let firstQuestion = reply.proposal.missingQuestions.first
        await onOwnerNotification(
          OwnerNotification(
            id: sourceComment.id,
            productID: context.product.id,
            kind: firstQuestion == nil ? .refinementComplete : .needsInput,
            target: OwnerNotificationTarget(kind: .ticket, id: item.id),
            title: firstQuestion == nil
              ? "\(item.key) refinement complete"
              : "\(item.key) needs your input",
            body: firstQuestion?.prompt
              ?? "The business analyst updated \(reply.proposal.title).",
            createdAt: sourceComment.createdAt
          )
        )
      }
      await refreshSelectedActivity(store: store, productID: context.product.id)
      updateSnapshot {
        $0.ticketRefinementResults[item.id] = TicketRefinementSessionResult(
          base: refinementBase,
          reply: reply,
          errorMessage: nil
        )
      }
      return reply
    } catch {
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body: "The business analyst couldn't refine this ticket: \(error.localizedDescription)"
      )
      updateSnapshot {
        $0.ticketRefinementResults[item.id] = TicketRefinementSessionResult(
          base: refinementBase,
          reply: nil,
          errorMessage: error.localizedDescription
        )
      }
      throw error
    }
  }

  @discardableResult
  public func applyCompletedTicketRefinement(
    _ proposal: TicketRefinementProposal,
    to item: WorkItem
  ) async throws -> WorkItem {
    guard let store = storeProvider(item.productID) else {
      throw PersistenceError.recordNotFound("Spedito database")
    }
    return try await applyCompletedTicketRefinement(proposal, to: item, store: store)
  }

  public func cancelTicketRefinement() {
    requestInterrupt(.ticketRefinement)
  }

  public func sendTicketConversationMessage(
    for item: WorkItem,
    to recipient: AgentProfile,
    ownerMessage: String,
    allowsProposal: Bool = true
  ) async throws -> TicketConversationReply {
    let availability = availabilityProvider()
    guard
      !snapshot.isTicketConversationMessageRunning,
      !snapshot.isEpicConversationMessageRunning,
      !availability.isSprintPlanningMessageRunning,
      snapshot.refiningWorkItemID == nil,
      !availability.isSuggestionGenerationRunning
    else {
      throw TicketConversationGenerationError.anotherCodexTaskIsRunning
    }
    guard
      let store = storeProvider(item.productID),
      let client = clientProvider(),
      let context = contextProvider(item.productID),
      context.product.id == item.productID,
      recipient.productID == context.product.id,
      context.profiles.contains(where: { $0.id == recipient.id })
    else {
      throw CodexClientError.notConnected
    }
    let trimmedMessage = ownerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      throw TicketConversationGenerationError.invalidResponse("Enter a message first.")
    }

    let operationID = UUID()
    let conversationBase = Self.ticketSnapshot(for: item)
    updateSnapshot {
      $0.ticketConversationResults.removeValue(forKey: item.id)
      $0.ticketConversationWorkItemID = item.id
      $0.ticketConversationRecipientID = recipient.id
    }
    defer {
      stopTicketActivity()
      finishTurn(.ticketConversation, operationID: operationID)
      updateSnapshot {
        if $0.ticketConversationWorkItemID == item.id {
          $0.ticketConversationWorkItemID = nil
          $0.ticketConversationRecipientID = nil
        }
      }
    }

    let comments = try await store.fetchComments(workItemID: item.id)
    let currentMessageBody = "@\(recipient.name) \(trimmedMessage)"
    let priorComments = comments.last?.authorKind == .owner
      && comments.last?.body == currentMessageBody
      ? Array(comments.dropLast())
      : comments
    let productItems = try await store.fetchWorkItems(productID: context.product.id)
    let activeItemIDs = Set(productItems.filter { $0.state != .cancelled }.map(\.id))
    let productDependencies = try await store.fetchWorkItemDependencies(
      productID: context.product.id
    )
    let prerequisiteIDs = Set(
      productDependencies
        .filter {
          $0.workItemID == item.id
            && activeItemIDs.contains($0.dependsOnWorkItemID)
        }
        .map(\.dependsOnWorkItemID)
    )
    let prerequisites = productItems.filter { prerequisiteIDs.contains($0.id) }
    let key = SourceRecipientKey(
      productID: context.product.id,
      sourceID: item.id,
      profileID: recipient.id
    )

    do {
      let threadID: String
      if let existingThreadID = ticketThreadIDs[key] {
        threadID = existingThreadID
      } else {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: try workspaceProvider(context.product.id),
          developerInstructions: CodexTicketConversation.developerInstructions(
            productInstructions: inheritedInstructions(context.product),
            customInstructions: recipient.customInstructionText,
            recipient: recipient
          ),
          model: recipient.model
        )
        ticketThreadIDs[key] = threadID
      }
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexTicketConversation.prompt(
          product: context.product,
          item: item,
          prerequisites: prerequisites,
          previousComments: priorComments,
          ownerMessage: trimmedMessage,
          allowsProposal: allowsProposal
        ),
        effort: recipient.reasoningEffort,
        outputSchema: CodexTicketConversation.outputSchema
      )
      recordTurn(
        .ticketConversation,
        operationID: operationID,
        productID: context.product.id,
        client: client,
        threadID: threadID,
        turnID: turnID
      )
      startTicketActivity(client: client, productID: context.product.id, threadID: threadID)
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let generatedReply = try CodexTicketConversation.decode(response, currentItem: item)
      let reply = allowsProposal
        ? generatedReply
        : TicketConversationReply(message: generatedReply.message)
      let replyComment = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: recipient.name,
        body: reply.ticketCommentBody
      )
      await onOwnerNotification(
        OwnerNotification(
          id: replyComment.id,
          productID: context.product.id,
          kind: .newReply,
          target: OwnerNotificationTarget(kind: .ticket, id: item.id),
          title: "\(recipient.name) replied on \(item.key)",
          body: reply.message,
          createdAt: replyComment.createdAt
        )
      )
      await refreshSelectedActivity(store: store, productID: context.product.id)
      updateSnapshot {
        $0.ticketConversationResults[item.id] = TicketConversationSessionResult(
          base: conversationBase,
          recipientID: recipient.id,
          reply: reply
        )
      }
      return reply
    } catch {
      ticketThreadIDs.removeValue(forKey: key)
      _ = try? await store.appendComment(
        workItemID: item.id,
        authorKind: .system,
        authorName: "Spedito",
        body: "\(recipient.name) couldn't reply: \(error.localizedDescription)"
      )
      throw error
    }
  }

  public func cancelTicketConversationMessage() {
    updateSnapshot {
      $0.ticketConversationActivity = CodexLiveActivity(
        text: "Stopping this response…",
        kind: .thinking
      )
    }
    requestInterrupt(.ticketConversation)
  }

  public func sendEpicConversationMessage(
    for epic: Epic,
    to recipient: AgentProfile,
    ownerMessage: String
  ) async throws -> EpicConversationReply {
    let availability = availabilityProvider()
    guard
      !snapshot.isEpicConversationMessageRunning,
      !snapshot.isTicketConversationMessageRunning,
      !availability.isSprintPlanningMessageRunning,
      snapshot.refiningWorkItemID == nil,
      !availability.isSuggestionGenerationRunning,
      !availability.isEpicPlanningRunning,
      !availability.isEpicPlanGenerationRunning
    else {
      throw EpicConversationGenerationError.anotherCodexTaskIsRunning
    }
    guard
      let store = storeProvider(epic.productID),
      let client = clientProvider(),
      let initialContext = contextProvider(epic.productID),
      initialContext.product.id == epic.productID,
      epic.status == .open,
      recipient.productID == initialContext.product.id,
      initialContext.profiles.contains(where: { $0.id == recipient.id })
    else {
      throw CodexClientError.notConnected
    }
    let trimmedMessage = ownerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      throw EpicConversationGenerationError.invalidResponse("Enter a message first.")
    }

    let operationID = UUID()
    updateSnapshot {
      $0.epicConversationEpicID = epic.id
      $0.epicConversationRecipientID = recipient.id
    }
    defer {
      finishTurn(.epicConversation, operationID: operationID)
      updateSnapshot {
        if $0.epicConversationEpicID == epic.id {
          $0.epicConversationEpicID = nil
          $0.epicConversationRecipientID = nil
        }
      }
    }
    await awaitEpicPersistence()
    guard
      !Task.isCancelled,
      selectedProductID() == epic.productID,
      let context = contextProvider(epic.productID)
    else {
      throw CodexClientError.notConnected
    }

    var durableConversation = try await store.fetchEpicPlanningConversation(epicID: epic.id)
      ?? EpicPlanningConversationSnapshot(
        epicID: epic.id,
        messages: [],
        questions: [],
        isComplete: false,
        threadID: nil,
        hasStartedPlanning: false
      )
    let previousMessages = durableConversation.messages
    durableConversation.messages.append(
      EpicPlanningConversationMessage(
        author: .owner,
        body: "@\(recipient.name) \(trimmedMessage)",
        kind: .chat,
        participantID: recipient.id,
        participantName: recipient.name
      )
    )
    durableConversation.updatedAt = Date()
    try await store.saveEpicPlanningConversation(durableConversation)
    publishEpicConversation(durableConversation, productID: epic.productID)


    let currentEpic = context.epics.first(where: { $0.id == epic.id }) ?? epic
    let relatedItems = context.workItems.filter {
      $0.epicID == epic.id && $0.state != .cancelled
    }
    let proposedItems = context.suggestionBatches
      .filter { $0.session.epicID == epic.id }
      .flatMap(\.suggestions)
      .filter { $0.status == .proposed }
    let key = SourceRecipientKey(
      productID: context.product.id,
      sourceID: epic.id,
      profileID: recipient.id
    )

    do {
      let threadID: String
      if let existingThreadID = epicThreadIDs[key] {
        threadID = existingThreadID
      } else {
        threadID = try await client.startReadOnlyThread(
          workingDirectory: try workspaceProvider(context.product.id),
          developerInstructions: CodexEpicConversation.developerInstructions(
            productInstructions: inheritedInstructions(context.product),
            customInstructions: recipient.customInstructionText,
            recipient: recipient
          ),
          model: recipient.model
        )
        epicThreadIDs[key] = threadID
      }
      let turnID = try await client.startStructuredTurn(
        threadID: threadID,
        prompt: CodexEpicConversation.prompt(
          product: context.product,
          epic: currentEpic,
          relatedItems: relatedItems,
          proposedItems: proposedItems,
          previousMessages: previousMessages,
          ownerMessage: trimmedMessage
        ),
        effort: recipient.reasoningEffort,
        outputSchema: CodexEpicConversation.outputSchema
      )
      recordTurn(
        .epicConversation,
        operationID: operationID,
        productID: context.product.id,
        client: client,
        threadID: threadID,
        turnID: turnID
      )
      let response = try await client.waitForFinalAgentMessage(
        threadID: threadID,
        turnID: turnID
      )
      let reply = try CodexEpicConversation.decode(response)
      let agentMessage = EpicPlanningConversationMessage(
        author: .agent,
        body: reply.message,
        kind: .chat,
        participantID: recipient.id,
        participantName: recipient.name
      )
      durableConversation.messages.append(agentMessage)
      durableConversation.updatedAt = Date()
      try await store.saveEpicPlanningConversation(durableConversation)
      publishEpicConversation(durableConversation, productID: epic.productID)
      await onOwnerNotification(
        OwnerNotification(
          id: agentMessage.id,
          productID: context.product.id,
          kind: .newReply,
          target: OwnerNotificationTarget(kind: .epic, id: epic.id),
          title: "\(recipient.name) replied on \(epic.title)",
          body: reply.message,
          createdAt: agentMessage.createdAt
        )
      )
      return reply
    } catch {
      epicThreadIDs.removeValue(forKey: key)
      durableConversation.messages.append(
        EpicPlanningConversationMessage(
          author: .system,
          body: "\(recipient.name) couldn't reply: \(error.localizedDescription)",
          kind: .chat
        )
      )
      durableConversation.updatedAt = Date()
      try? await store.saveEpicPlanningConversation(durableConversation)
      publishEpicConversation(durableConversation, productID: epic.productID)
      throw error
    }
  }

  public func cancelEpicConversationMessage() {
    requestInterrupt(.epicConversation)
  }

  public func dismissTicketAssistantResult(workItemID: UUID) {
    updateSnapshot {
      $0.ticketRefinementResults.removeValue(forKey: workItemID)
      $0.ticketConversationResults.removeValue(forKey: workItemID)
    }
  }

  public func cancel(productID: UUID) async {
    stopTicketActivity(productID: productID)
    let kinds = activeTurns.compactMap { kind, turn in
      turn.productID == productID ? kind : nil
    }
    for kind in kinds {
      requestInterrupt(kind)
    }
    let tasks = interruptionOperations.values
      .filter { $0.productID == productID }
      .map(\.task)
    for task in tasks {
      await task.value
    }
    ticketThreadIDs = ticketThreadIDs.filter { $0.key.productID != productID }
    epicThreadIDs = epicThreadIDs.filter { $0.key.productID != productID }
  }

  public func shutdown() async {
    stopTicketActivity()
    for kind in Array(activeTurns.keys) {
      requestInterrupt(kind)
    }
    let tasks = interruptionOperations.values.map(\.task)
    for task in tasks {
      await task.value
    }
    ticketThreadIDs.removeAll()
    epicThreadIDs.removeAll()
  }

  private func applyCompletedTicketRefinement(
    _ proposal: TicketRefinementProposal,
    to item: WorkItem,
    store: SQLiteStore
  ) async throws -> WorkItem {
    guard proposal.missingQuestions.isEmpty else {
      throw TicketRefinementGenerationError.invalidResponse(
        "The ticket cannot be updated while product owner questions remain."
      )
    }

    let activeItems = try await store.fetchWorkItems(productID: item.productID)
      .filter { $0.state != .cancelled }
    let productDependencies = try await store.fetchWorkItemDependencies(
      productID: item.productID
    )
    let productProfiles = try await store.fetchAgentProfiles(productID: item.productID)
    let activeItemIDs = Set(activeItems.map(\.id))
    let activeItemsByKey = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.key, $0) })
    let suggestedDependencyIDs = try Set(
      proposal.dependencies.map { dependency in
        guard
          let relatedItem = activeItemsByKey[dependency.ticketKey],
          relatedItem.id != item.id
        else {
          throw TicketRefinementGenerationError.invalidResponse(
            "The suggested dependency \(dependency.ticketKey) is not active."
          )
        }
        return relatedItem.id
      }
    )
    let existingDependencyIDs = Set(
      productDependencies
        .filter {
          $0.workItemID == item.id
            && activeItemIDs.contains($0.dependsOnWorkItemID)
        }
        .map(\.dependsOnWorkItemID)
    )

    var updated = try await store.updateWorkItem(
      id: item.id,
      title: proposal.title,
      type: proposal.type,
      body: proposal.body,
      acceptanceCriteria: proposal.acceptanceCriteria,
      priority: proposal.priority,
      customFields: item.customFields,
      dependsOnWorkItemIDs: existingDependencyIDs.union(suggestedDependencyIDs),
      expectedVersion: proposal.baseVersion
    )
    let currentPlan = try await store.fetchCurrentSprint(productID: item.productID)
    let draftPlan = currentPlan?.sprint.state == .draft ? currentPlan : nil
    let draftItem = draftPlan?.items.first { $0.workItemID == item.id }
    if updated.ownerProfileID == nil,
      draftItem?.implementerProfileID == nil,
      let owner = TicketOwnerRouter.owner(
        for: updated,
        profiles: productProfiles,
        suggestedRole: proposal.suggestedRole
      )
    {
      updated = try await store.assignWorkItemOwner(id: updated.id, profileID: owner.id)
      if let draftPlan, draftItem != nil {
        _ = try await store.saveDraftSprint(
          productID: updated.productID,
          goal: draftPlan.sprint.goal,
          tokenBudgetLimit: draftPlan.sprint.tokenBudgetLimit,
          items: draftPlan.items.map { sprintItem in
            SprintDraftItemInput(
              workItemID: sprintItem.workItemID,
              implementerProfileID: sprintItem.workItemID == updated.id
                ? owner.id
                : sprintItem.implementerProfileID,
              reviewerProfileID: sprintItem.reviewerProfileID,
              estimatedTokens: sprintItem.estimatedTokens
            )
          }
        )
      }
    }
    await onReloadSelectedProduct(item.productID)
    return updated
  }

  private func publishEpicConversation(
    _ snapshot: EpicPlanningConversationSnapshot,
    productID: UUID
  ) {
    guard selectedProductID() == productID else { return }
    onEpicConversationChange(
      EpicPlanningConversationState(
        productID: productID,
        epicID: snapshot.epicID,
        messages: snapshot.messages,
        questions: snapshot.questions,
        hasStartedPlanning: snapshot.hasStartedPlanning ?? true,
        isRunning: false,
        isGeneratingPlan: false,
        isComplete: snapshot.isComplete,
        errorMessage: nil
      ),
      snapshot.threadID
    )
  }

  private func refreshSelectedActivity(store: SQLiteStore, productID: UUID) async {
    guard selectedProductID() == productID,
      let activity = try? await store.fetchActivity(productID: productID)
    else { return }
    onSelectedActivityChange(productID, activity)
  }

  private static func ticketSnapshot(for item: WorkItem) -> SprintPlanningTicketSnapshot {
    SprintPlanningTicketSnapshot(
      version: item.version,
      title: item.title,
      type: item.type,
      body: item.body,
      acceptanceCriteria: item.acceptanceCriteria,
      priority: item.priority
    )
  }

  private func recordTurn(
    _ kind: TurnKind,
    operationID: UUID,
    productID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    turnID: String
  ) {
    activeTurns[kind] = ActiveTurn(
      operationID: operationID,
      productID: productID,
      identity: TurnIdentity(threadID: threadID, turnID: turnID),
      client: client
    )
  }

  private func finishTurn(_ kind: TurnKind, operationID: UUID) {
    guard activeTurns[kind]?.operationID == operationID else { return }
    activeTurns.removeValue(forKey: kind)
  }

  private func requestInterrupt(_ kind: TurnKind) {
    guard let turn = activeTurns[kind] else { return }
    interruptionOperations[kind]?.task.cancel()
    let token = UUID()
    let task = Task { @MainActor [weak self] in
      try? await turn.client.interruptTurn(
        threadID: turn.identity.threadID,
        turnID: turn.identity.turnID
      )
      self?.finishInterruption(kind, token: token)
    }
    interruptionOperations[kind] = InterruptionOperation(
      token: token,
      productID: turn.productID,
      task: task
    )
  }

  private func finishInterruption(_ kind: TurnKind, token: UUID) {
    guard interruptionOperations[kind]?.token == token else { return }
    interruptionOperations.removeValue(forKey: kind)
  }

  private func startTicketActivity(
    client: CodexAppServerClient,
    productID: UUID,
    threadID: String
  ) {
    stopTicketActivity()
    updateSnapshot {
      $0.ticketConversationActivity = CodexLiveActivity(
        text: "Thinking through your question…",
        kind: .thinking
      )
    }
    let token = UUID()
    let task = Task { @MainActor [weak self] in
      var accumulator = CodexLiveActivityAccumulator()
      let messages = await client.inboundMessages(replayRecent: false)
      for await message in messages {
        guard !Task.isCancelled else { break }
        guard case .notification(let notification) = message else { continue }
        guard notification.params["threadId"]?.stringValue == threadID else { continue }
        guard self?.ticketActivityOperation?.token == token else { return }

        switch accumulator.consume(notification) {
        case .activity(let activity):
          self?.updateSnapshot { $0.ticketConversationActivity = activity }
        case .turnFinished:
          self?.finishTicketActivity(token: token)
          return
        case nil:
          continue
        }
      }
      self?.finishTicketActivity(token: token)
    }
    ticketActivityOperation = ActivityOperation(token: token, productID: productID, task: task)
  }

  private func stopTicketActivity(productID: UUID? = nil) {
    guard let operation = ticketActivityOperation else {
      if productID == nil {
        updateSnapshot { $0.ticketConversationActivity = nil }
      }
      return
    }
    guard productID == nil || operation.productID == productID else { return }
    operation.task.cancel()
    ticketActivityOperation = nil
    updateSnapshot { $0.ticketConversationActivity = nil }
  }

  private func finishTicketActivity(token: UUID) {
    guard ticketActivityOperation?.token == token else { return }
    ticketActivityOperation = nil
    updateSnapshot { $0.ticketConversationActivity = nil }
  }

  private func updateSnapshot(
    _ update: (inout PlanningConversationWorkflowSnapshot) -> Void
  ) {
    var updated = snapshot
    update(&updated)
    guard updated != snapshot else { return }
    snapshot = updated
    onSnapshotChange(updated)
  }
}
