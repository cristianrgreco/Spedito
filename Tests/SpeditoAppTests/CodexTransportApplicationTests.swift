import Foundation
import SpeditoTestSupport
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

@Suite("Codex transport application seam", .serialized)
@MainActor
struct CodexTransportApplicationTests {
  @Test("A scripted Product conversation updates presentation and SQLite")
  func scriptedProductConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-app-codex-transport-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Scripted conversation")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let recipient = try #require(profiles.first)
    let conversation = ProductConversationThread(
      productID: product.id,
      recipientProfileID: recipient.id,
      subject: "Existing conversation",
      status: .complete,
      codexThreadID: "thread-application"
    )
    _ = try await store.createConversationThread(
      conversation,
      initialMessage: ProductConversationMessage(
        threadID: conversation.id,
        authorKind: .owner,
        authorName: "Me",
        body: "Earlier context"
      )
    )

    let transport = ScriptedCodexTransport(
      responses: [
        .init(
          method: "initialize",
          result: .object([
            "userAgent": .string("codex-cli/application-test"),
            "codexHome": .string("/private/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
          ])
        ),
        .init(method: "model/list", result: .object(["data": .array([])])),
        .init(
          method: "account/rateLimits/read",
          result: .object(["rateLimits": .object([:])])
        ),
        .init(
          method: "thread/resume",
          result: .object(["thread": .object(["id": .string("thread-application")])])
        ),
        .init(
          method: "turn/start",
          result: .object(["turn": .object(["id": .string("turn-application")])])
        ),
      ],
      inboundMessages: [
        .notification(
          CodexNotification(
            method: "turn/completed",
            params: .object([
              "threadId": .string("thread-application"),
              "turn": .object([
                "id": .string("turn-application"),
                "status": .string("completed"),
                "items": .array([
                  .object([
                    "id": .string("message-application"),
                    "type": .string("agentMessage"),
                    "text": .string("A deterministic reply."),
                  ])
                ]),
              ]),
            ])
          )
        )
      ]
    )
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      codexTransportFactory: { _ in
        CodexTransportFactoryOutput(
          descriptor: CodexRuntimeDescriptor(
            executableURL: URL(fileURLWithPath: "/private/tmp/codex-test"),
            version: "test",
            source: .custom
          ),
          transport: transport
        )
      },
      ownerNotificationSoundPlayer: CodexTransportNotificationSound(),
      ownerNotificationSystemNotifier: CodexTransportSystemNotifier()
    )

    await model.load()
    let returnedThreadID = await model.sendProductConversationMessage(
      threadID: conversation.id,
      recipientID: recipient.id,
      body: "What changed?"
    )

    #expect(returnedThreadID == conversation.id)
    #expect(
      model.conversationThreads.first(where: { $0.id == conversation.id })?.status == .complete
    )
    #expect(
      model.conversationMessagesByThread[conversation.id]?.map(\.body)
        == ["Earlier context", "What changed?", "A deterministic reply."]
    )

    let storedMessages = try await store.fetchConversationMessages(threadID: conversation.id)
    #expect(storedMessages.map(\.body) == ["Earlier context", "What changed?", "A deterministic reply."])
    #expect(
      await transport.recordedRequests().map(\.method)
        == [
          "initialize",
          "model/list",
          "account/rateLimits/read",
          "thread/resume",
          "turn/start",
        ]
    )
    #expect(await transport.remainingResponseCount() == 0)

    await model.shutdown()
    await store.close()
  }

  @Test("Ticket refinement and conversation survive Product switching and relaunch")
  func ticketRefinementAndConversationJourney() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-ticket-conversation-journey-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: workspaces)
    let product = try await registry.createProduct(name: "Ticket conversation")
    let otherProduct = try await registry.createProduct(name: "Selected elsewhere")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Clarify the saved-search outcome"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-refinement")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-refinement")])])
          ),
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-ticket-chat")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-ticket-chat-1")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-ticket-chat-2")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )

    await model.load()
    let refinementTask = Task { @MainActor in
      try await model.refineTicket(item)
    }
    await transport.waitForRequest("turn/start")
    await model.selectProduct(otherProduct)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-refinement",
        turnID: "turn-refinement",
        text: #"""
          {
            "message": "I need one product decision before completing refinement.",
            "proposal": {
              "baseVersion": \#(item.version),
              "title": "Clarify the saved-search outcome",
              "type": "\#(item.type.rawValue)",
              "body": "",
              "acceptanceCriteria": [],
              "priority": "normal",
              "role": "business_analyst",
              "rationale": "The owner must choose the retention boundary.",
              "dependencies": [],
              "potentialDuplicates": [],
              "splitRecommendation": null,
              "missingQuestions": [
                {
                  "prompt": "Where should saved searches be retained?",
                  "options": ["On this Mac", "In the repository"]
                }
              ]
            }
          }
          """#
      )
    )
    let refinementReply = try await refinementTask.value

    #expect(refinementReply.proposal.missingQuestions.map(\.prompt) == [
      "Where should saved searches be retained?"
    ])
    #expect(model.selectedProductID == otherProduct.id)
    #expect(model.ticketRefinementResults[item.id]?.reply == refinementReply)
    let refinementComments = try await store.fetchComments(workItemID: item.id)
    #expect(
      refinementComments.flatMap {
        TicketRefinementQuestion.parseTicketCommentBody($0.body)
      } == refinementReply.proposal.missingQuestions
    )

    await model.selectProduct(product)
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "@\(analyst.name) Keep the choice reviewable."
    )
    let firstReplyTask = Task { @MainActor in
      try await model.sendTicketConversationMessage(
        for: item,
        to: analyst,
        ownerMessage: "Keep the choice reviewable."
      )
    }
    await transport.waitForRequest("turn/start", count: 2)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-ticket-chat",
        turnID: "turn-ticket-chat-1",
        text: #"{"message":"I will keep the retention choice explicit.","proposal":null}"#
      )
    )
    let firstReply = try await firstReplyTask.value

    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "@\(analyst.name) Does that change the ticket yet?"
    )
    let followUpTask = Task { @MainActor in
      try await model.sendTicketConversationMessage(
        for: item,
        to: analyst,
        ownerMessage: "Does that change the ticket yet?"
      )
    }
    await transport.waitForRequest("turn/start", count: 3)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-ticket-chat",
        turnID: "turn-ticket-chat-2",
        text: #"{"message":"No. A proposal remains reviewable until you apply it.","proposal":null}"#
      )
    )
    let followUp = try await followUpTask.value

    #expect(firstReply.message == "I will keep the retention choice explicit.")
    #expect(followUp.message == "No. A proposal remains reviewable until you apply it.")
    #expect(model.ticketConversationResults[item.id]?.reply == followUp)
    #expect(
      await transport.recordedRequests().filter { $0.method == "thread/start" }.count == 2
    )
    let storedComments = try await store.fetchComments(workItemID: item.id)
    #expect(storedComments.map(\.body).contains(firstReply.message))
    #expect(storedComments.map(\.body).contains(followUp.message))
    let notifications = try await store.fetchActiveOwnerNotifications(productID: product.id)
    #expect(notifications.map(\.kind).contains(.needsInput))
    #expect(notifications.filter { $0.kind == .newReply }.count == 2)

    await model.shutdown()
    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: CodexTransportNotificationSound(),
      ownerNotificationSystemNotifier: CodexTransportSystemNotifier()
    )
    await recoveredModel.reload()
    let recoveredComments = await recoveredModel.comments(
      for: item.id,
      productID: product.id
    )
    #expect(recoveredComments == storedComments)
    #expect(
      recoveredComments.flatMap {
        TicketRefinementQuestion.parseTicketCommentBody($0.body)
      } == refinementReply.proposal.missingQuestions
    )
    #expect(!recoveredModel.isTicketConversationMessageRunning)
    #expect(recoveredModel.refiningWorkItemID == nil)

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("Epic conversation reply remains durable across Product switching and relaunch")
  func epicConversationJourney() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-epic-conversation-journey-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: workspaces)
    let product = try await registry.createProduct(name: "Epic conversation")
    let otherProduct = try await registry.createProduct(name: "Current product")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let designer = try #require(profiles.first { $0.role == .uxDesigner })
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Make a complex setup understandable"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-epic-chat")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-epic-chat")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )

    await model.load()
    let replyTask = Task { @MainActor in
      try await model.sendEpicConversationMessage(
        for: epic,
        to: designer,
        ownerMessage: "Which interaction needs the clearest hierarchy?"
      )
    }
    await transport.waitForRequest("turn/start")
    await model.selectProduct(otherProduct)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-epic-chat",
        turnID: "turn-epic-chat",
        text: #"{"message":"Make the first irreversible choice visually primary."}"#
      )
    )
    let reply = try await replyTask.value

    #expect(reply.message == "Make the first irreversible choice visually primary.")
    #expect(model.selectedProductID == otherProduct.id)
    let storedConversation = try #require(
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(storedConversation.messages.map(\.author) == [.owner, .agent])
    #expect(storedConversation.messages.map(\.body) == [
      "@\(designer.name) Which interaction needs the clearest hierarchy?",
      reply.message,
    ])
    let notification = try #require(
      try await store.fetchActiveOwnerNotifications(productID: product.id)
        .first(where: { $0.kind == .newReply })
    )
    #expect(notification.target == OwnerNotificationTarget(kind: .epic, id: epic.id))

    await model.shutdown()
    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: CodexTransportNotificationSound(),
      ownerNotificationSystemNotifier: CodexTransportSystemNotifier()
    )
    await recoveredModel.reload()
    await recoveredModel.restoreEpicPlanningConversation(for: epic)

    #expect(recoveredModel.epicPlanningConversation?.messages == storedConversation.messages)
    #expect(!recoveredModel.isEpicConversationMessageRunning)
    #expect(recoveredModel.epicConversationEpicID == nil)

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("Stopped ticket conversation records a durable failure and settles after relaunch")
  func stoppedTicketConversationSettlesDurably() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-stopped-ticket-conversation-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaces = root.appendingPathComponent("workspaces", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: workspaces)
    let product = try await registry.createProduct(name: "Stopped conversation")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Keep an interrupted reply recoverable"
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "@\(analyst.name) Stop when I ask."
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-stopped-chat")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-stopped-chat")])])
          ),
          .init(method: "turn/interrupt", result: .object([:])),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )

    await model.load()
    let replyTask = Task { @MainActor in
      try await model.sendTicketConversationMessage(
        for: item,
        to: analyst,
        ownerMessage: "Stop when I ask."
      )
    }
    await transport.waitForRequest("turn/start")
    model.cancelTicketConversationMessage()
    await transport.waitForRequest("turn/interrupt")
    await transport.emit(
      .notification(
        CodexNotification(
          method: "turn/completed",
          params: .object([
            "threadId": .string("thread-stopped-chat"),
            "turn": .object([
              "id": .string("turn-stopped-chat"),
              "status": .string("interrupted"),
              "items": .array([]),
            ]),
          ])
        )
      )
    )
    do {
      _ = try await replyTask.value
      Issue.record("The interrupted ticket conversation unexpectedly returned a reply.")
    } catch {
      #expect(!error.localizedDescription.isEmpty)
    }

    #expect(!model.isTicketConversationMessageRunning)
    #expect(model.ticketConversationActivity == nil)
    let interruptedComments = try await store.fetchComments(workItemID: item.id)
    #expect(
      interruptedComments.last?.body.contains("\(analyst.name) couldn't reply:") == true
    )

    await model.shutdown()
    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: CodexTransportNotificationSound(),
      ownerNotificationSystemNotifier: CodexTransportSystemNotifier()
    )
    await recoveredModel.reload()

    #expect(
      await recoveredModel.comments(for: item.id, productID: product.id)
        == interruptedComments
    )
    #expect(!recoveredModel.isTicketConversationMessageRunning)
    #expect(recoveredModel.ticketConversationActivity == nil)

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  private static func connectionResponses() -> [ScriptedCodexTransport.Response] {
    [
      .init(
        method: "initialize",
        result: .object([
          "userAgent": .string("codex-cli/planning-conversation-test"),
          "codexHome": .string("/private/tmp/codex"),
          "platformFamily": .string("unix"),
          "platformOs": .string("macos"),
        ])
      ),
      .init(method: "model/list", result: .object(["data": .array([])])),
      .init(
        method: "account/rateLimits/read",
        result: .object(["rateLimits": .object([:])])
      ),
    ]
  }

  private static func makeModel(
    registry: ProductStoreRegistry,
    selectedProductID: UUID,
    transport: ScriptedCodexTransport
  ) -> AppModel {
    AppModel(
      storeRegistry: registry,
      selectedProductID: selectedProductID,
      codexTransportFactory: { _ in
        CodexTransportFactoryOutput(
          descriptor: CodexRuntimeDescriptor(
            executableURL: URL(fileURLWithPath: "/private/tmp/codex-test"),
            version: "test",
            source: .custom
          ),
          transport: transport
        )
      },
      ownerNotificationSoundPlayer: CodexTransportNotificationSound(),
      ownerNotificationSystemNotifier: CodexTransportSystemNotifier()
    )
  }

  private static func completedTurn(
    threadID: String,
    turnID: String,
    text: String
  ) -> CodexInboundMessage {
    .notification(
      CodexNotification(
        method: "turn/completed",
        params: .object([
          "threadId": .string(threadID),
          "turn": .object([
            "id": .string(turnID),
            "status": .string("completed"),
            "items": .array([
              .object([
                "id": .string("message-\(turnID)"),
                "type": .string("agentMessage"),
                "text": .string(text),
              ])
            ]),
          ]),
        ])
      )
    )
  }
}

@MainActor
private final class CodexTransportNotificationSound: OwnerNotificationSoundPlaying {
  func play() {}
}

@MainActor
private final class CodexTransportSystemNotifier: OwnerNotificationSystemNotifying {
  func post(_ presentation: OwnerNotificationPresentation) {}
  func dismiss(ids: [UUID]) {}
}
