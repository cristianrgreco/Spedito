import Foundation
import SpeditoTestSupport
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

@Suite("Epic planning journeys", .serialized)
@MainActor
struct EpicPlanningJourneyTests {
  /// Existing partial coverage:
  /// - `SQLiteStoreTests.newEpicsPersistOnlyOwnerOutcomeUntilAnalysis`
  /// - `EpicPlanningJourneyTests.e02ClarificationNeedsInputAcrossProducts`
  /// This test covers only E01's owner create-and-clarify composition before analysis completes.
  @Test("E01 creating an Epic persists only owner scope while clarification begins")
  func e01CreateEpicStartsClarificationWithoutInventedMetadata() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Initial Epic scope")
    let store = try #require(registry.store(for: product.id))
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e01")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e01")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )
    await model.load()
    let ownerOutcome = "Let product owners recover unsent release notes"

    let created = try #require(await model.createEpicAndPlan(outcome: ownerOutcome))
    await transport.waitForRequest("turn/start")

    let persisted = try #require(
      try await store.fetchEpics(productID: product.id).first { $0.id == created.id }
    )
    #expect(persisted.title.isEmpty)
    #expect(persisted.goal == ownerOutcome)
    #expect(persisted.successCriteria.isEmpty)
    #expect(persisted.constraints.isEmpty)
    #expect(persisted.status == .open)
    #expect(model.epicPlanningWorkflowCoordinator.isPlanning)
    #expect(try await store.fetchWorkItems(productID: product.id).isEmpty)
    #expect(try await store.fetchLatestTicketSuggestionBatch(productID: product.id) == nil)

    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e01",
        turnID: "turn-e01",
        text: #"{"message":"I need one decision.","questions":[{"prompt":"Where should drafts live?","options":["On this Mac","In the repository"]}],"readyToPlan":false}"#
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()
    let clarified = try #require(
      try await store.fetchEpicPlanningConversation(epicID: created.id)
    )
    #expect(clarified.questions.map(\.prompt) == ["Where should drafts live?"])
    let unchanged = try #require(
      try await store.fetchEpics(productID: product.id).first { $0.id == created.id }
    )
    #expect(unchanged == persisted)

    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("E02 clarification needs input returns to the exact Epic across Products")
  func e02ClarificationNeedsInputAcrossProducts() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let firstProduct = try await registry.createProduct(name: "First product")
    let secondProduct = try await registry.createProduct(name: "Second product")
    let firstStore = try #require(registry.store(for: firstProduct.id))
    let secondStore = try #require(registry.store(for: secondProduct.id))
    let epic = try await firstStore.createEpic(
      productID: firstProduct.id,
      outcome: "Let owners preserve draft notes"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e02")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e02")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: firstProduct.id,
      transport: transport
    )

    await model.load()
    model.planEpic(epic)
    await transport.waitForRequest("turn/start")
    await model.selectProduct(secondProduct)

    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e02",
        turnID: "turn-e02",
        text: #"{"message":"I need one product decision.","questions":[{"prompt":"Where should drafts be retained?","options":["On this Mac","In the repository"]}],"readyToPlan":false}"#
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()

    let storedConversation = try #require(
      try await firstStore.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(storedConversation.questions.map(\.prompt) == ["Where should drafts be retained?"])
    let firstNotifications = try await firstStore.fetchActiveOwnerNotifications(
      productID: firstProduct.id
    )
    let notification = try #require(firstNotifications.first)
    #expect(notification.kind == .needsInput)
    #expect(notification.target == OwnerNotificationTarget(kind: .epic, id: epic.id))
    #expect(
      try await secondStore.fetchActiveOwnerNotifications(productID: secondProduct.id).isEmpty
    )
    #expect(try await secondStore.fetchEpicPlanningConversation(epicID: epic.id) == nil)
    #expect(model.selectedProductID == secondProduct.id)

    let presentation = try #require(model.presentedOwnerNotification)
    await model.openOwnerNotification(presentation)

    #expect(model.selectedProductID == firstProduct.id)
    #expect(model.ownerNotificationNavigationRequest?.productID == firstProduct.id)
    #expect(model.ownerNotificationNavigationRequest?.target.kind == .epic)
    #expect(model.ownerNotificationNavigationRequest?.target.id == epic.id)
    #expect(model.epicPlanningConversation?.questions == storedConversation.questions)

    await model.shutdown()

    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: firstProduct.id,
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
    await recoveredModel.reload()
    await recoveredModel.restoreEpicPlanningConversation(for: epic)

    #expect(recoveredModel.epicPlanningConversation?.questions == storedConversation.questions)
    let recoveredNotification = try #require(
      recoveredModel.ownerNotificationsByProductID[firstProduct.id]?.first
    )
    #expect(!recoveredNotification.isUnread)
    #expect(recoveredNotification.resolvedAt == nil)
    #expect(recoveredModel.ownerNotificationsByProductID[secondProduct.id] == nil)

    await recoveredModel.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("E05 a plan ready in the background returns to the exact Epic")
  func e05PlanReadyAcrossProducts() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let firstProduct = try await registry.createProduct(name: "Planning product")
    let secondProduct = try await registry.createProduct(name: "Current product")
    let firstStore = try #require(registry.store(for: firstProduct.id))
    let secondStore = try #require(registry.store(for: secondProduct.id))
    let epic = try await firstStore.createEpic(
      productID: firstProduct.id,
      outcome: "Let owners preserve draft notes"
    )
    let secondSession = try await secondStore.beginTicketSuggestionSession(
      productID: secondProduct.id
    )
    let secondBatch = try await secondStore.completeTicketSuggestionSession(
      sessionID: secondSession.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Keep Product B suggestion visible",
          body: "Protect the selected Product from a stale Product A result.",
          acceptanceCriteria: ["Product B remains selected and unchanged"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "This fixture exposes stale presentation replacement."
        )
      ]
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e05")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e05-ready")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e05-plan")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: firstProduct.id,
      transport: transport
    )

    await model.load()
    model.planEpic(epic)
    await transport.waitForRequest("turn/start")
    await model.selectProduct(secondProduct)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e05",
        turnID: "turn-e05-ready",
        text: #"{"message":"The outcome is ready to plan.","questions":[],"readyToPlan":true}"#
      )
    )
    await transport.waitForRequest("turn/start", count: 2)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e05",
        turnID: "turn-e05-plan",
        text: Self.epicPlanResponse
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()

    let updatedEpic = try #require(
      try await firstStore.fetchEpics(productID: firstProduct.id)
        .first(where: { $0.id == epic.id })
    )
    #expect(updatedEpic.title == "Durable draft notes")
    #expect(updatedEpic.successCriteria == ["A draft can be reopened after relaunch"])
    let batch = try #require(
      try await firstStore.fetchLatestTicketSuggestionBatch(productID: firstProduct.id)
    )
    #expect(batch.session.epicID == epic.id)
    #expect(batch.session.status == .ready)
    #expect(batch.suggestions.map(\.title) == ["Preserve and reopen draft notes"])
    #expect(try await firstStore.fetchWorkItems(productID: firstProduct.id).isEmpty)
    #expect(
      try await secondStore.fetchLatestTicketSuggestionBatch(productID: secondProduct.id)?
        .session.id == secondBatch.session.id
    )
    #expect(try await secondStore.fetchWorkItems(productID: secondProduct.id).isEmpty)

    let notification = try #require(
      try await firstStore.fetchActiveOwnerNotifications(productID: firstProduct.id).first
    )
    #expect(notification.kind == .refinementComplete)
    #expect(notification.target == OwnerNotificationTarget(kind: .epic, id: epic.id))
    #expect(
      try await secondStore.fetchActiveOwnerNotifications(productID: secondProduct.id).isEmpty
    )
    #expect(model.selectedProductID == secondProduct.id)
    #expect(model.suggestionBatch?.session.id == secondBatch.session.id)
    #expect(model.epics.allSatisfy { $0.productID == secondProduct.id })
    #expect(model.workItems.allSatisfy { $0.productID == secondProduct.id })

    let presentation = try #require(model.presentedOwnerNotification)
    await model.openOwnerNotification(presentation)

    #expect(model.selectedProductID == firstProduct.id)
    #expect(model.ownerNotificationNavigationRequest?.target.id == epic.id)
    #expect(model.epics.first(where: { $0.id == epic.id })?.title == "Durable draft notes")
    #expect(model.suggestionBatch?.session.id == batch.session.id)
    #expect(model.epicPlanningConversation?.isComplete == true)
    #expect(model.epicPlanningConversation?.isGeneratingPlan == false)
    #expect(model.workItems.isEmpty)
    await model.shutdown()

    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: firstProduct.id,
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
    await recoveredModel.reload()
    let recoveredEpic = try #require(
      recoveredModel.epics.first(where: { $0.id == epic.id })
    )
    await recoveredModel.restoreEpicPlanningConversation(for: recoveredEpic)

    #expect(recoveredEpic.title == "Durable draft notes")
    #expect(recoveredModel.suggestionBatch?.session.id == batch.session.id)
    #expect(recoveredModel.epicPlanningConversation?.isComplete == true)
    #expect(recoveredModel.epicPlanningConversation?.questions.isEmpty == true)
    #expect(recoveredModel.workItems.isEmpty)
    await recoveredModel.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("E06 relaunch replaces an expired Epic thread without repeating answers")
  func e06ExpiredThreadRecovery() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Recovered product")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Let owners preserve draft notes"
    )
    let originalQuestion = TicketRefinementQuestion(
      prompt: "Where should drafts be retained?",
      options: ["On this Mac", "In the repository"]
    )
    try await store.saveEpicPlanningConversation(
      EpicPlanningConversationSnapshot(
        epicID: epic.id,
        messages: [
          EpicPlanningConversationMessage(
            author: .businessAnalyst,
            body: "I need one product decision."
          )
        ],
        questions: [originalQuestion],
        isComplete: false,
        threadID: "expired-thread-e06",
        hasStartedPlanning: true
      )
    )

    let interruptedModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
    await interruptedModel.reload()
    await interruptedModel.restoreEpicPlanningConversation(for: epic)
    #expect(interruptedModel.epicPlanningConversation?.questions == [originalQuestion])
    await interruptedModel.shutdown()

    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "turn/start",
            error: CodexRPCError(code: -32_600, message: "Thread not found")
          ),
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("replacement-thread-e06")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("replacement-turn-e06")])])
          ),
        ]
    )
    let recoveredModel = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )
    await recoveredModel.load()
    await recoveredModel.restoreEpicPlanningConversation(for: epic)

    recoveredModel.continueEpicPlanning(
      epic,
      answers: ["Where should drafts be retained?\nAnswer: On this Mac"],
      answeredQuestions: [
        EpicPlanningAnsweredQuestion(
          question: originalQuestion,
          selectedOption: "On this Mac",
          answer: "On this Mac"
        )
      ]
    )
    await transport.waitForRequest("turn/start", count: 2)
    await transport.emit(
      Self.completedTurn(
        threadID: "replacement-thread-e06",
        turnID: "replacement-turn-e06",
        text: #"{"message":"One final decision is needed.","questions":[{"prompt":"When should a draft be removed?","options":["Only when the owner deletes it","After it is published"]}],"readyToPlan":false}"#
      )
    )
    await recoveredModel.epicPlanningWorkflowCoordinator.settlePlanning()

    let recoveredSnapshot = try #require(
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
    )
    let ownerAnswers = recoveredSnapshot.messages.flatMap(\.answeredQuestions)
    #expect(ownerAnswers.map(\.answer) == ["On this Mac"])
    #expect(recoveredSnapshot.questions.map(\.prompt) == ["When should a draft be removed?"])
    #expect(recoveredSnapshot.threadID == "replacement-thread-e06")
    let turnRequests = await transport.recordedRequests().filter { $0.method == "turn/start" }
    #expect(turnRequests.count == 2)
    #expect(turnRequests[0].params["threadId"]?.stringValue == "expired-thread-e06")
    #expect(turnRequests[1].params["threadId"]?.stringValue == "replacement-thread-e06")
    let recoveryPrompt =
      turnRequests[1].params["input"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    #expect(recoveryPrompt.contains("On this Mac"))
    #expect(recoveredModel.epicPlanningConversation?.questions == recoveredSnapshot.questions)

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }


  private static let epicPlanResponse = #"""
    {
      "epic": {
        "title": "Durable draft notes",
        "goal": "Owners can preserve and return to draft notes.",
        "successCriteria": ["A draft can be reopened after relaunch"],
        "constraints": "Keep draft content local.",
        "environmentAssessment": {
          "readiness": "sufficient",
          "rationale": "The verified application environment covers this work.",
          "foundationTicketReference": null
        }
      },
      "suggestions": [
        {
          "reference": "T1",
          "title": "Preserve and reopen draft notes",
          "type": "story",
          "body": "Persist draft notes and restore them after relaunch.",
          "acceptanceCriteria": ["A draft can be reopened after relaunch"],
          "role": "implementer",
          "priority": "high",
          "rationale": "This delivers the agreed owner outcome.",
          "dependsOn": [],
          "environmentRelationship": "independent"
        }
      ]
    }
    """#

  private static func connectionResponses() -> [ScriptedCodexTransport.Response] {
    [
      .init(
        method: "initialize",
        result: .object([
          "userAgent": .string("codex-cli/epic-journey-test"),
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
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
  }
}

private struct EpicPlanningJourneyFixture {
  let rootURL: URL
  let workspacesURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-epic-journey-\(UUID())",
      isDirectory: true
    )
    workspacesURL = rootURL.appendingPathComponent("workspaces", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

@MainActor
private final class EpicJourneyNotificationSound: OwnerNotificationSoundPlaying {
  func play() {}
}

@MainActor
private final class EpicJourneySystemNotifier: OwnerNotificationSystemNotifying {
  func post(_ presentation: OwnerNotificationPresentation) {}
  func dismiss(ids: [UUID]) {}
}
