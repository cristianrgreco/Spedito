import Combine
import Foundation
import SpeditoCore

@MainActor
final class ProductConversationFeatureModel: ObservableObject {
  @Published private(set) var threads: [ProductConversationThread] = []
  @Published private(set) var messagesByThread: [UUID: [ProductConversationMessage]] = [:]
  @Published private(set) var respondingThreadIDs: Set<UUID> = []
  @Published private(set) var activities: [UUID: CodexLiveActivity] = [:]
  @Published private(set) var errorsByThread: [UUID: String] = [:]

  private let runtime = ProductConversationRuntime()
  private let selectedProduct: @MainActor () -> Product?
  private let profiles: @MainActor () -> [AgentProfile]
  private let storeProvider: @MainActor (UUID) -> SQLiteStore?
  private let clientProvider: @MainActor () -> CodexAppServerClient?
  private let isConnected: @MainActor () -> Bool
  private let workspaceProvider: @MainActor (UUID) throws -> URL
  private let inheritedInstructions: @MainActor (Product) -> String
  private let modelOptions: @MainActor () -> [CodexModelOption]
  private let isShuttingDown: @MainActor () -> Bool
  private let onError: @MainActor (String) -> Void
  private let onAgentReply:
    @MainActor (ProductConversationThread, ProductConversationMessage) async -> Void
  private var loadedProductID: UUID?

  init(
    selectedProduct: @escaping @MainActor () -> Product?,
    profiles: @escaping @MainActor () -> [AgentProfile],
    storeProvider: @escaping @MainActor (UUID) -> SQLiteStore?,
    clientProvider: @escaping @MainActor () -> CodexAppServerClient?,
    isConnected: @escaping @MainActor () -> Bool,
    workspaceProvider: @escaping @MainActor (UUID) throws -> URL,
    inheritedInstructions: @escaping @MainActor (Product) -> String,
    modelOptions: @escaping @MainActor () -> [CodexModelOption],
    isShuttingDown: @escaping @MainActor () -> Bool,
    onError: @escaping @MainActor (String) -> Void,
    onAgentReply:
      @escaping @MainActor (ProductConversationThread, ProductConversationMessage) async -> Void
  ) {
    self.selectedProduct = selectedProduct
    self.profiles = profiles
    self.storeProvider = storeProvider
    self.clientProvider = clientProvider
    self.isConnected = isConnected
    self.workspaceProvider = workspaceProvider
    self.inheritedInstructions = inheritedInstructions
    self.modelOptions = modelOptions
    self.isShuttingDown = isShuttingDown
    self.onError = onError
    self.onAgentReply = onAgentReply
  }

  var isBusy: Bool { runtime.isBusy }

  func load(productID: UUID, threads: [ProductConversationThread]) {
    if loadedProductID != productID {
      messagesByThread = [:]
      errorsByThread = [:]
    }
    loadedProductID = productID
    self.threads = threads
    respondingThreadIDs = runtime.activeResponseThreadIDs(productID: productID)
    messagesByThread = messagesByThread.filter { threadID, _ in
      threads.contains { $0.id == threadID }
    }
  }

  func clear() {
    loadedProductID = nil
    threads = []
    messagesByThread = [:]
    respondingThreadIDs = []
    activities = [:]
    errorsByThread = [:]
  }

  @discardableResult
  func sendMessage(
    threadID: UUID?,
    recipientID: UUID,
    body: String
  ) async -> UUID? {
    let messageBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !messageBody.isEmpty,
      let product = selectedProduct(),
      let recipient = profiles().first(where: {
        $0.id == recipientID && $0.productID == product.id
      }),
      let store = storeProvider(product.id),
      let client = clientProvider(),
      isConnected()
    else { return nil }

    let thread: ProductConversationThread
    let turnPrompt: String
    let provisionalSubject: String?
    do {
      if let threadID {
        provisionalSubject = nil
        guard
          let existingThread = threads.first(where: {
            $0.id == threadID && $0.productID == product.id
          }),
          !existingThread.isArchived
        else {
          throw PersistenceError.recordNotFound("Conversation thread \(threadID)")
        }
        let switchesRecipient = existingThread.recipientProfileID != recipient.id
        let ownerMessage = ProductConversationMessage(
          threadID: threadID,
          authorKind: .owner,
          authorName: "Me",
          body: messageBody
        )
        thread = try await store.appendConversationMessage(
          ownerMessage,
          threadStatus: .working,
          threadRecipientProfileID: switchesRecipient ? recipient.id : nil,
          resetsCodexThread: switchesRecipient
        )
        if switchesRecipient {
          turnPrompt = CodexProductConversation.handoffPrompt(
            messages: try await store.fetchConversationMessages(threadID: threadID)
          )
        } else if existingThread.codexThreadID == nil {
          turnPrompt = CodexProductConversation.recoveryPrompt(
            messages: try await store.fetchConversationMessages(threadID: threadID)
          )
        } else {
          turnPrompt = CodexProductConversation.resumedThreadPrompt(ownerMessage: messageBody)
        }
      } else {
        let recentMessages = try await store.fetchRecentConversationMessages(
          productID: product.id,
          limit: 100
        )
        let now = Date()
        let createdThread = ProductConversationThread(
          productID: product.id,
          recipientProfileID: recipient.id,
          subject: Self.conversationSubject(from: messageBody),
          createdAt: now,
          updatedAt: now
        )
        provisionalSubject = createdThread.subject
        let ownerMessage = ProductConversationMessage(
          threadID: createdThread.id,
          authorKind: .owner,
          authorName: "Me",
          body: messageBody,
          createdAt: now
        )
        thread = try await store.createConversationThread(
          createdThread,
          initialMessage: ownerMessage
        )
        turnPrompt = CodexProductConversation.newThreadPrompt(
          ownerMessage: messageBody,
          recentRoomMessages: recentMessages
        )
      }
      try await reload(productID: product.id, store: store, messageThreadID: thread.id)
    } catch {
      onError(error.localizedDescription)
      return nil
    }

    respondingThreadIDs.insert(thread.id)
    errorsByThread.removeValue(forKey: thread.id)
    guard
      let responseToken = runtime.claimResponse(
        threadID: thread.id,
        productID: product.id
      )
    else {
      respondingThreadIDs.remove(thread.id)
      onError("This conversation is already waiting for a response.")
      return thread.id
    }
    defer {
      stopActivityMonitoring(threadID: thread.id)
      respondingThreadIDs.remove(thread.id)
      runtime.finish(responseToken)
    }

    do {
      let workspace = try workspaceProvider(product.id)
      if let provisionalSubject {
        startTitleGeneration(
          conversationThreadID: thread.id,
          productID: product.id,
          ownerMessage: messageBody,
          provisionalSubject: provisionalSubject,
          recipient: recipient,
          store: store,
          client: client,
          workspace: workspace
        )
      }
      let developerInstructions = CodexProductConversation.developerInstructions(
        productInstructions: inheritedInstructions(product),
        customInstructions: recipient.customInstructionText,
        recipient: recipient
      )

      var codexThreadID: String
      var prompt = turnPrompt
      if let existingCodexThreadID = thread.codexThreadID {
        do {
          codexThreadID = try await client.resumeReadOnlyThread(
            threadID: existingCodexThreadID,
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: recipient.model
          )
        } catch let error as CodexRPCError where error.isThreadNotFound {
          codexThreadID = try await client.startReadOnlyThread(
            workingDirectory: workspace,
            developerInstructions: developerInstructions,
            model: recipient.model
          )
          prompt = CodexProductConversation.recoveryPrompt(
            messages: try await store.fetchConversationMessages(threadID: thread.id)
          )
        }
      } else {
        codexThreadID = try await client.startReadOnlyThread(
          workingDirectory: workspace,
          developerInstructions: developerInstructions,
          model: recipient.model
        )
      }
      _ = try await store.updateConversationThread(
        id: thread.id,
        status: .working,
        codexThreadID: codexThreadID
      )
      if runtime.isCancelled(thread.id) { throw CancellationError() }
      let turnID = try await client.startTurn(
        threadID: codexThreadID,
        prompt: prompt,
        effort: recipient.reasoningEffort
      )
      runtime.recordTurn(
        CodexTurnIdentity(threadID: codexThreadID, turnID: turnID),
        for: responseToken
      )
      monitorActivity(
        threadID: thread.id,
        client: client,
        codexThreadID: codexThreadID,
        productID: product.id
      )
      if runtime.isCancelled(thread.id) {
        try? await client.interruptTurn(threadID: codexThreadID, turnID: turnID)
        throw CancellationError()
      }
      let response = try await client.waitForFinalAgentMessage(
        threadID: codexThreadID,
        turnID: turnID,
        timeout: .seconds(300)
      )
      let reply = try CodexProductConversation.decodeMessage(response)
      runtime.clearCancellation(thread.id)
      let agentMessage = ProductConversationMessage(
        threadID: thread.id,
        authorKind: .agent,
        authorName: recipient.name,
        body: reply
      )
      _ = try await store.appendConversationMessage(
        agentMessage,
        threadStatus: .complete
      )
      try await reload(productID: product.id, store: store, messageThreadID: thread.id)
      await onAgentReply(thread, agentMessage)
      return thread.id
    } catch is CancellationError {
      runtime.clearCancellation(thread.id)
      _ = try? await store.updateConversationThread(id: thread.id, status: .cancelled)
      try? await reload(productID: product.id, store: store, messageThreadID: thread.id)
      return thread.id
    } catch {
      let wasCancelled = runtime.consumeCancellation(thread.id) || isShuttingDown()
      _ = try? await store.updateConversationThread(
        id: thread.id,
        status: wasCancelled ? .cancelled : .failed
      )
      if wasCancelled {
        errorsByThread.removeValue(forKey: thread.id)
      } else {
        errorsByThread[thread.id] = error.localizedDescription
      }
      try? await reload(productID: product.id, store: store, messageThreadID: thread.id)
      return thread.id
    }
  }

  func cancel(threadID: UUID) {
    guard respondingThreadIDs.contains(threadID) else { return }
    runtime.cancelThread(threadID)
    activities[threadID] = CodexLiveActivity(
      text: "Stopping this response…",
      kind: .thinking
    )
    guard let client = clientProvider() else { return }
    runtime.requestInterrupt(threadID: threadID) { turn in
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
  }

  @discardableResult
  func archive(threadID: UUID) async -> Bool {
    guard
      !respondingThreadIDs.contains(threadID),
      let product = selectedProduct(),
      let thread = threads.first(where: {
        $0.id == threadID && $0.productID == product.id
      }),
      !thread.isArchived,
      let store = storeProvider(product.id)
    else { return false }

    do {
      _ = try await store.archiveConversationThread(id: threadID)
      errorsByThread.removeValue(forKey: threadID)
      try await reload(productID: product.id, store: store)
      return true
    } catch {
      onError(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  func restore(threadID: UUID) async -> Bool {
    guard
      let product = selectedProduct(),
      let thread = threads.first(where: {
        $0.id == threadID && $0.productID == product.id
      }),
      thread.isArchived,
      let store = storeProvider(product.id)
    else { return false }

    do {
      _ = try await store.restoreConversationThread(id: threadID)
      try await reload(productID: product.id, store: store)
      return true
    } catch {
      onError(error.localizedDescription)
      return false
    }
  }

  func loadMessages(threadID: UUID) async {
    guard
      let productID = loadedProductID,
      threads.contains(where: { $0.id == threadID && $0.productID == productID }),
      let store = storeProvider(productID)
    else { return }

    do {
      let messages = try await store.fetchConversationMessages(threadID: threadID)
      guard loadedProductID == productID else { return }
      messagesByThread = [threadID: messages]
    } catch {
      errorsByThread[threadID] = error.localizedDescription
    }
  }

  func settle(productID: UUID) async {
    await runtime.cancel(
      productID: productID,
      interrupt: { [clientProvider] turn in
        try? await clientProvider()?.interruptTurn(
          threadID: turn.threadID,
          turnID: turn.turnID
        )
      },
      markCancelled: { [storeProvider] threadID, productID in
        _ = try? await storeProvider(productID)?.updateConversationThread(
          id: threadID,
          status: .cancelled
        )
      }
    )
    let threadIDs = Set(threads.lazy.filter { $0.productID == productID }.map(\.id))
    respondingThreadIDs.subtract(threadIDs)
    for threadID in threadIDs {
      activities.removeValue(forKey: threadID)
    }
  }

  func shutdown() async {
    await runtime.shutdown(
      interrupt: { [clientProvider] turn in
        try? await clientProvider()?.interruptTurn(
          threadID: turn.threadID,
          turnID: turn.turnID
        )
      },
      markCancelled: { [storeProvider] threadID, productID in
        _ = try? await storeProvider(productID)?.updateConversationThread(
          id: threadID,
          status: .cancelled
        )
      }
    )
    respondingThreadIDs.removeAll()
    activities.removeAll()
  }

  private func startTitleGeneration(
    conversationThreadID: UUID,
    productID: UUID,
    ownerMessage: String,
    provisionalSubject: String,
    recipient: AgentProfile,
    store: SQLiteStore,
    client: CodexAppServerClient,
    workspace: URL
  ) {
    let supportedEfforts =
      modelOptions().first(where: { $0.model == recipient.model })?
      .supportedReasoningEfforts
      .map(\.id) ?? []
    let reasoningEffort = CodexSprintGoalGenerator.lightestReasoningEffort(
      supportedEfforts: supportedEfforts,
      fallback: recipient.reasoningEffort
    )
    _ = runtime.start(.title(conversationThreadID), productID: productID) {
      [weak self] token in
      guard let self else { return }
      await self.generateTitle(
        conversationThreadID: conversationThreadID,
        productID: productID,
        ownerMessage: ownerMessage,
        provisionalSubject: provisionalSubject,
        recipient: recipient,
        reasoningEffort: reasoningEffort,
        store: store,
        client: client,
        workspace: workspace,
        operationToken: token
      )
    }
  }

  private func generateTitle(
    conversationThreadID: UUID,
    productID: UUID,
    ownerMessage: String,
    provisionalSubject: String,
    recipient: AgentProfile,
    reasoningEffort: String,
    store: SQLiteStore,
    client: CodexAppServerClient,
    workspace: URL,
    operationToken: FeatureOperationToken<ProductConversationRuntime.Operation>
  ) async {
    let deadline = ContinuousClock.now + CodexProductConversation.titleGenerationTimeout
    var activeTurn: CodexTurnIdentity?
    do {
      let codexThreadID = try await client.startReadOnlyThread(
        workingDirectory: workspace,
        developerInstructions: CodexProductConversation.titleDeveloperInstructions,
        model: recipient.model,
        ephemeral: true,
        responseTimeout: try remainingTitleGenerationTime(until: deadline)
      )
      try Task.checkCancellation()
      let turnID = try await client.startStructuredTurn(
        threadID: codexThreadID,
        prompt: CodexProductConversation.titlePrompt(ownerMessage: ownerMessage),
        effort: reasoningEffort,
        outputSchema: CodexProductConversation.titleOutputSchema,
        responseTimeout: try remainingTitleGenerationTime(until: deadline)
      )
      let turn = CodexTurnIdentity(threadID: codexThreadID, turnID: turnID)
      activeTurn = turn
      runtime.recordTurn(turn, for: operationToken)
      let response = try await client.waitForFinalAgentMessage(
        threadID: codexThreadID,
        turnID: turnID,
        timeout: CodexProductConversation.titleGenerationTimeout,
        totalTimeout: try remainingTitleGenerationTime(until: deadline)
      )
      try Task.checkCancellation()
      let title = try CodexProductConversation.decodeTitle(response)
      _ = try await store.updateConversationThreadSubject(
        id: conversationThreadID,
        subject: title,
        replacing: provisionalSubject
      )
      if loadedProductID == productID {
        try await reload(productID: productID, store: store)
      }
    } catch {
      if let activeTurn {
        try? await client.interruptTurn(
          threadID: activeTurn.threadID,
          turnID: activeTurn.turnID
        )
      }
    }
  }

  private func remainingTitleGenerationTime(
    until deadline: ContinuousClock.Instant
  ) throws -> Duration {
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else { throw CancellationError() }
    return remaining
  }

  private func monitorActivity(
    threadID: UUID,
    client: CodexAppServerClient,
    codexThreadID: String,
    productID: UUID
  ) {
    stopActivityMonitoring(threadID: threadID)
    activities[threadID] = CodexLiveActivity(
      text: "Thinking through your question…",
      kind: .thinking
    )

    _ = runtime.start(.activity(threadID), productID: productID, replacing: true) {
      [weak self] token in
      guard let self else { return }
      var accumulator = CodexLiveActivityAccumulator()
      let messages = await client.inboundMessages(replayRecent: false)
      for await message in messages {
        guard !Task.isCancelled else { break }
        guard case .notification(let notification) = message else { continue }
        guard
          notification.params["threadId"]?.stringValue == codexThreadID,
          self.runtime.isCurrent(token)
        else { continue }

        switch accumulator.consume(notification) {
        case .activity(let activity):
          self.activities[threadID] = activity
        case .turnFinished:
          self.activities.removeValue(forKey: threadID)
          return
        case nil:
          continue
        }
      }

      guard self.runtime.isCurrent(token) else { return }
      self.activities.removeValue(forKey: threadID)
    }
  }

  private func stopActivityMonitoring(threadID: UUID) {
    runtime.stop(.activity(threadID))
    activities.removeValue(forKey: threadID)
  }

  private func reload(
    productID: UUID,
    store: SQLiteStore,
    messageThreadID: UUID? = nil
  ) async throws {
    let threads = try await store.fetchConversationThreads(productID: productID)
    let messages: [ProductConversationMessage]? =
      if let messageThreadID {
        try await store.fetchConversationMessages(threadID: messageThreadID)
      } else {
        nil
      }
    guard loadedProductID == productID else { return }
    self.threads = threads
    if let messageThreadID, let messages {
      messagesByThread = [messageThreadID: messages]
    } else {
      messagesByThread = messagesByThread.filter { threadID, _ in
        threads.contains { $0.id == threadID }
      }
    }
  }

  private static func conversationSubject(from message: String) -> String {
    let firstLine =
      message
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Conversation"
    guard firstLine.count > 72 else { return firstLine }
    return "\(firstLine.prefix(69))…"
  }
}
