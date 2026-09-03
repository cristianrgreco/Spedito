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

  /// The first alert a product owner ever receives comes from clarification,
  /// before the business analyst has named the Epic. A live pilot run delivered
  /// three macOS notifications titled " needs your input", because the title
  /// interpolated the Epic's unset title instead of what the owner asked for.
  @Test("An Epic still being analysed is named by the outcome the owner asked for")
  func clarificationAlertNamesTheEpicBeforeAnalysis() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Unnamed Epic alerts")
    let store = try #require(registry.store(for: product.id))
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-alert")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-alert")])])
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
    let beforeAnalysis = try await store.fetchEpics(productID: product.id)
      .first { $0.id == created.id }
    #expect(beforeAnalysis?.title.isEmpty == true)

    await transport.emit(
      Self.completedTurn(
        threadID: "thread-alert",
        turnID: "turn-alert",
        text: #"{"message":"I need one decision.","questions":[{"prompt":"Where should drafts live?","options":["On this Mac","In the repository"]}],"readyToPlan":false}"#
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()

    let notification = try #require(
      try await store.fetchActiveOwnerNotifications(productID: product.id).first
    )
    #expect(notification.kind == .needsInput)
    #expect(notification.target == OwnerNotificationTarget(kind: .epic, id: created.id))
    #expect(notification.title == "\(ownerOutcome) needs your input")

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
    #expect(model.epicPlanningConversation(for: epic.id)?.questions == storedConversation.questions)

    await model.shutdown()

    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: firstProduct.id,
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
    await recoveredModel.reload()
    await recoveredModel.restoreEpicPlanningConversation(for: epic)

    #expect(recoveredModel.epicPlanningConversation(for: epic.id)?.questions == storedConversation.questions)
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

  @Test("E07 stopped Epic clarification recovers one contextual retry")
  func e07StoppedClarificationRecoversContextualRetry() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Interrupted clarification")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Keep interrupted clarification owner-controlled"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e07-stop")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e07-stop")])])
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
    model.planEpic(epic)
    await transport.waitForRequest("turn/start")

    model.cancelEpicPlanning(epicID: epic.id)
    await transport.waitForRequest("turn/interrupt")
    await transport.emit(
      .notification(
        CodexNotification(
          method: "turn/completed",
          params: .object([
            "threadId": .string("thread-e07-stop"),
            "turn": .object([
              "id": .string("turn-e07-stop"),
              "status": .string("interrupted"),
              "items": .array([]),
            ]),
          ])
        )
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()
    await model.epicPlanningWorkflowCoordinator.awaitPersistence()

    let stopped = try #require(model.epicPlanningConversation(for: epic.id))
    #expect(!stopped.isRunning)
    #expect(stopped.errorMessage == "Epic planning was interrupted. You can safely continue.")
    #expect(
      EpicPlanningPolicy.retryAction(for: stopped, hasFailedPlan: false)
        == .restartClarification
    )
    #expect(
      await transport.recordedRequests().filter { $0.method == "turn/start" }.count == 1
    )
    let durable = try #require(
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(durable.hasStartedPlanning == true)
    #expect(!durable.isComplete)
    await model.shutdown()

    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
    await recoveredModel.reload()
    await recoveredModel.restoreEpicPlanningConversation(for: epic)
    let recovered = try #require(recoveredModel.epicPlanningConversation(for: epic.id))
    #expect(!recovered.isRunning)
    #expect(
      recovered.errorMessage
        == "Epic planning was paused when the app closed. You can safely try again."
    )
    #expect(
      EpicPlanningPolicy.retryAction(for: recovered, hasFailedPlan: false)
        == .restartClarification
    )

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
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
    #expect(model.suggestionBatches.map(\.session.id) == [secondBatch.session.id])
    #expect(model.epics.allSatisfy { $0.productID == secondProduct.id })
    #expect(model.workItems.allSatisfy { $0.productID == secondProduct.id })

    let presentation = try #require(model.presentedOwnerNotification)
    await model.openOwnerNotification(presentation)

    #expect(model.selectedProductID == firstProduct.id)
    #expect(model.ownerNotificationNavigationRequest?.target.id == epic.id)
    #expect(model.epics.first(where: { $0.id == epic.id })?.title == "Durable draft notes")
    #expect(model.suggestionBatches.map(\.session.id) == [batch.session.id])
    #expect(model.epicPlanningConversation(for: epic.id)?.isComplete == true)
    #expect(model.epicPlanningConversation(for: epic.id)?.isGeneratingPlan == false)
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
    #expect(recoveredModel.suggestionBatches.map(\.session.id) == [batch.session.id])
    #expect(recoveredModel.epicPlanningConversation(for: epic.id)?.isComplete == true)
    #expect(recoveredModel.epicPlanningConversation(for: epic.id)?.questions.isEmpty == true)
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
    #expect(interruptedModel.epicPlanningConversation(for: epic.id)?.questions == [originalQuestion])
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
    #expect(recoveredModel.epicPlanningConversation(for: epic.id)?.questions == recoveredSnapshot.questions)

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }


  @Test("E08 owner Epic edits survive invalid planning and retry")
  func e08OwnerEpicEditsSurvivePlanningRetry() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Invalid plan recovery")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Keep invalid plans out of the Backlog"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e08")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e08-clarification")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e08-plan")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e08-repair")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )
    await model.load()
    model.planEpic(epic)
    await transport.waitForRequest("turn/start")
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e08",
        turnID: "turn-e08-clarification",
        text: #"{"message":"The outcome is clear.","questions":[],"readyToPlan":true}"#
      )
    )
    await transport.waitForRequest("turn/start", count: 2)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e08",
        turnID: "turn-e08-plan",
        text: #"{"reply":{"epic":{"title":42},"suggestions":"invalid"}}"#
      )
    )
    await transport.waitForRequest("turn/start", count: 3)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e08",
        turnID: "turn-e08-repair",
        text: #"{"still":"not a valid epic plan"}"#
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()
    await model.epicPlanningWorkflowCoordinator.awaitPersistence()

    let turnRequests = await transport.recordedRequests().filter { $0.method == "turn/start" }
    #expect(turnRequests.count == 3)
    let batches = try await store.fetchOutstandingTicketSuggestionBatches(
      productID: product.id
    )
    let failed = try #require(batches.first)
    #expect(batches.count == 1)
    #expect(failed.session.status == .failed)
    #expect(!(failed.session.errorMessage ?? "").isEmpty)
    #expect(failed.suggestions.isEmpty)
    #expect(try await store.fetchWorkItems(productID: product.id).isEmpty)
    let unchangedEpic = try #require(
      try await store.fetchEpics(productID: product.id).first { $0.id == epic.id }
    )
    #expect(unchangedEpic.title.isEmpty)
    #expect(unchangedEpic.goal == epic.goal)
    let terminal = try #require(model.epicPlanningConversation(for: epic.id))
    #expect(!terminal.isGeneratingPlan)
    #expect(!(terminal.errorMessage ?? "").isEmpty)
    #expect(
      EpicPlanningPolicy.retryAction(for: terminal, hasFailedPlan: true)
        == .retryFailedPlan
    )
    // Failure must notify like success does. A live run generated for half an
    // hour, timed out, recorded the failed session durably, and told the owner
    // nothing unless the epic screen happened to be open.
    let failureNotification = try #require(
      try await store.fetchActiveOwnerNotifications(productID: product.id)
        .first { $0.target == OwnerNotificationTarget(kind: .epic, id: epic.id) }
    )
    #expect(failureNotification.kind == .needsInput)
    #expect(failureNotification.title == "Planning needs another try")
    let ownerEdited = try await store.updateEpic(
      id: epic.id,
      title: "Owner-reviewed recovery plan",
      goal: "Keep the owner's corrected goal through retry",
      successCriteria: ["The corrected outcome reaches review"],
      constraints: "Do not restore invalid generated metadata."
    )
    await model.shutdown()

    let retryTransport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e08-retry")])])
          ),
        ]
    )
    let recoveredModel = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: retryTransport
    )
    await recoveredModel.load()
    // The relaunch sweep keeps the retry decision: its wait still exists.
    let keptRetryRow = try #require(
      try await store.fetchActiveOwnerNotifications(productID: product.id)
        .first { $0.target == OwnerNotificationTarget(kind: .epic, id: epic.id) }
    )
    #expect(keptRetryRow.kind == .needsInput)
    await recoveredModel.restoreEpicPlanningConversation(for: ownerEdited)
    let recovered = try #require(recoveredModel.epicPlanningConversation(for: epic.id))
    #expect(recoveredModel.suggestionBatches.map(\.session.id) == [failed.session.id])
    #expect(
      EpicPlanningPolicy.retryAction(for: recovered, hasFailedPlan: true)
        == .retryFailedPlan
    )
    recoveredModel.retryEpicPlan(sessionID: failed.session.id)
    await retryTransport.waitForRequest("turn/start")
    let retryTurn = try #require(
      await retryTransport.recordedRequests().first { $0.method == "turn/start" }
    )
    let retryPrompt = retryTurn.params["input"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    #expect(retryPrompt.contains(ownerEdited.title))
    #expect(retryPrompt.contains(ownerEdited.goal))
    #expect(retryPrompt.contains(ownerEdited.successCriteria[0]))
    #expect(retryPrompt.contains(ownerEdited.constraints))
    #expect(try await store.fetchWorkItems(productID: product.id).isEmpty)
    await retryTransport.emit(
      Self.completedTurn(
        threadID: "thread-e08",
        turnID: "turn-e08-retry",
        text: Self.epicPlanResponse
      )
    )
    await recoveredModel.epicPlanningWorkflowCoordinator.settlePlanning()
    let retried = try await store.fetchTicketSuggestionBatch(sessionID: failed.session.id)
    #expect(retried.session.errorMessage == nil)
    #expect(retried.session.status == .ready)
    #expect(retried.suggestions.map(\.reference) == ["T1"])
    let retainedEpic = try #require(
      try await store.fetchEpics(productID: product.id).first { $0.id == epic.id }
    )
    #expect(retainedEpic.title == ownerEdited.title)
    #expect(retainedEpic.goal == ownerEdited.goal)
    #expect(retainedEpic.successCriteria == ownerEdited.successCriteria)
    #expect(retainedEpic.constraints == ownerEdited.constraints)
    #expect(try await store.fetchWorkItems(productID: product.id).isEmpty)
    // The landed plan ends the retry wait and delivers the plan-ready update.
    let afterRetry = try await store.fetchActiveOwnerNotifications(productID: product.id)
      .filter { $0.target == OwnerNotificationTarget(kind: .epic, id: epic.id) }
    #expect(afterRetry.map(\.kind) == [.refinementComplete])

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("A transiently failed plan generation retries once silently before notifying")
  func transientPlanFailureRetriesSilentlyOnce() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Transient plan recovery")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Survive one stalled generation turn"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-transient")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-transient-clarify")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-transient-empty")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-transient-plan")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )
    await model.load()
    model.planEpic(epic)
    await transport.waitForRequest("turn/start")
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-transient",
        turnID: "turn-transient-clarify",
        text: #"{"message":"The outcome is clear.","questions":[],"readyToPlan":true}"#
      )
    )
    // The generation turn completes with no output at all, which the client
    // reports as a transient failure — the live shape was a turn that stalled
    // and was aborted by the inactivity timeout.
    await transport.waitForRequest("turn/start", count: 2)
    await transport.emit(
      .notification(
        CodexNotification(
          method: "turn/completed",
          params: .object([
            "threadId": .string("thread-transient"),
            "turn": .object([
              "id": .string("turn-transient-empty"),
              "status": .string("completed"),
              "items": .array([]),
            ]),
          ])
        )
      )
    )
    // The silent retry starts a fresh generation turn without the owner.
    await transport.waitForRequest("turn/start", count: 3)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-transient",
        turnID: "turn-transient-plan",
        text: Self.epicPlanResponse
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()
    await model.epicPlanningWorkflowCoordinator.awaitPersistence()

    let batches = try await store.fetchOutstandingTicketSuggestionBatches(
      productID: product.id
    )
    let recovered = try #require(batches.first)
    #expect(batches.count == 1)
    #expect(recovered.session.status == .ready)
    #expect(!recovered.suggestions.isEmpty)
    let conversation = try #require(model.epicPlanningConversation(for: epic.id))
    #expect(conversation.errorMessage == nil)
    let notifications = try await store.fetchActiveOwnerNotifications(productID: product.id)
    #expect(!notifications.contains { $0.title == "Planning needs another try" })
    #expect(notifications.contains { $0.kind == .refinementComplete })
    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("E09 edited suggested ticket stays isolated and accepts with its details")
  func e09EditedSuggestionAcceptsWithoutChangingUnrelatedProposals() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Reviewed suggestions")
    let otherProduct = try await registry.createProduct(name: "Unrelated suggestions")
    let store = try #require(registry.store(for: product.id))
    let otherStore = try #require(registry.store(for: otherProduct.id))
    _ = try await store.seedDefaultProfiles(productID: product.id)
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Review one suggested ticket before acceptance"
    )
    let session = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    let ready = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        Self.suggestionDraft(
          reference: "S1",
          title: "Define the rollout contract",
          type: .task,
          role: .businessAnalyst,
          priority: .high
        ),
        Self.suggestionDraft(
          reference: "S2",
          title: "Build the rollout controls",
          body: "Implement the proposed controls.",
          criteria: ["The proposed controls work"],
          role: .implementer,
          dependsOn: ["S1"]
        ),
        Self.suggestionDraft(
          reference: "S3",
          title: "Document the rollout",
          type: .task,
          role: .knowledgeCurator
        ),
      ]
    )
    let otherSession = try await otherStore.beginTicketSuggestionSession(
      productID: otherProduct.id
    )
    let otherBatch = try await otherStore.completeTicketSuggestionSession(
      sessionID: otherSession.id,
      drafts: [
        Self.suggestionDraft(
          reference: "S1",
          title: "Keep another Product unchanged",
          role: .implementer
        )
      ]
    )
    let target = try #require(ready.suggestions.first { $0.reference == "T2" })
    let unrelated = try #require(ready.suggestions.first { $0.reference == "T3" })
    #expect(target.rationale == "Required by the agreed Epic outcome.")
    #expect(target.dependencyIDs.count == 1)
    #expect(
      transitiveSuggestedPrerequisites(of: target, in: ready.suggestions)
        .map(\.reference) == ["T1"]
    )

    let model = AppModel(storeRegistry: registry, selectedProductID: product.id)
    await model.reload()
    let updateResult: TicketSuggestion? = await withCheckedContinuation { continuation in
      model.updateTicketSuggestion(
        target,
        title: "Build owner-reviewed rollout controls",
        type: .story,
        body: "Implement the controls exactly as reviewed.",
        acceptanceCriteria: [
          "The owner can advance one cohort",
          "Paused rollout remains visible",
        ],
        suggestedRole: .uxDesigner,
        priority: .high,
        rationale: "The owner needs explicit rollout control."
      ) {
        continuation.resume(returning: $0)
      }
    }
    #expect(updateResult?.id == target.id)
    #expect(model.errorMessage == nil)
    let afterEdit = try await store.fetchTicketSuggestionBatch(sessionID: session.id)
    let edited = try #require(afterEdit.suggestions.first { $0.id == target.id })
    #expect(edited.title == "Build owner-reviewed rollout controls")
    #expect(edited.body == "Implement the controls exactly as reviewed.")
    #expect(edited.acceptanceCriteria == [
      "The owner can advance one cohort",
      "Paused rollout remains visible",
    ])
    #expect(edited.suggestedRole == .uxDesigner)
    #expect(edited.priority == .high)
    #expect(edited.rationale == "The owner needs explicit rollout control.")
    #expect(edited.dependencyIDs == target.dependencyIDs)
    #expect(afterEdit.suggestions.first { $0.id == unrelated.id } == unrelated)
    #expect(
      try await otherStore.fetchTicketSuggestionBatch(sessionID: otherSession.id) == otherBatch
    )
    await model.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }

    let recoveredRegistry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    try await recoveredRegistry.prepare()
    let recoveredStore = try #require(recoveredRegistry.store(for: product.id))
    let recoveredOtherStore = try #require(recoveredRegistry.store(for: otherProduct.id))
    let recoveredModel = AppModel(
      storeRegistry: recoveredRegistry,
      selectedProductID: product.id
    )
    await recoveredModel.reload()
    let recoveredBatch = try #require(
      recoveredModel.suggestionBatches.first { $0.session.id == session.id }
    )
    let recoveredEdit = try #require(
      recoveredBatch.suggestions.first { $0.id == target.id }
    )
    #expect(recoveredEdit.title == edited.title)
    let acceptedResult: WorkItem? = await withCheckedContinuation { continuation in
      recoveredModel.decideTicketSuggestion(recoveredEdit, accept: true) {
        continuation.resume(returning: $0)
      }
    }
    #expect(acceptedResult?.title == edited.title)

    let decided = try await recoveredStore.fetchTicketSuggestionBatch(sessionID: session.id)
    #expect(
      decided.suggestions
        .filter { ["T1", "T2"].contains($0.reference) }
        .allSatisfy { $0.status == .accepted }
    )
    #expect(decided.suggestions.first { $0.reference == "T3" }?.status == .proposed)
    let acceptedItem = try #require(
      try await recoveredStore.fetchWorkItems(productID: product.id)
        .first { $0.title == edited.title }
    )
    #expect(acceptedItem.type == edited.type)
    #expect(acceptedItem.body == edited.body)
    #expect(acceptedItem.acceptanceCriteria == edited.acceptanceCriteria)
    #expect(acceptedItem.priority == edited.priority)
    #expect(acceptedItem.epicID == epic.id)
    #expect(try await recoveredStore.fetchCurrentSprint(productID: product.id) == nil)
    #expect(
      try await recoveredOtherStore.fetchTicketSuggestionBatch(sessionID: otherSession.id)
        == otherBatch
    )

    await recoveredModel.shutdown()
    for productStore in recoveredRegistry.allStores {
      await productStore.close()
    }
  }

  @Test("E10 Accept all and Reject all persist their exact reviewed scope")
  func e10AllSuggestionDecisionsPersistWithoutStartingSprint() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Batch decisions")
    let otherProduct = try await registry.createProduct(name: "Other batch decisions")
    let store = try #require(registry.store(for: product.id))
    let otherStore = try #require(registry.store(for: otherProduct.id))
    _ = try await store.seedDefaultProfiles(productID: product.id)
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Decide reviewed suggestions in one command"
    )
    let acceptedSession = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    let acceptedReady = try await store.completeTicketSuggestionSession(
      sessionID: acceptedSession.id,
      drafts: [
        Self.suggestionDraft(
          reference: "S1",
          title: "Define the contract",
          type: .task,
          role: .businessAnalyst
        ),
        Self.suggestionDraft(
          reference: "S2",
          title: "Build the reviewed contract",
          body: "Preserve the complete proposal.",
          criteria: ["The proposal is delivered"],
          role: .implementer,
          priority: .high,
          dependsOn: ["S1"]
        ),
      ]
    )
    let otherSession = try await otherStore.beginTicketSuggestionSession(
      productID: otherProduct.id
    )
    let otherReady = try await otherStore.completeTicketSuggestionSession(
      sessionID: otherSession.id,
      drafts: [
        Self.suggestionDraft(
          reference: "S1",
          title: "Do not decide this Product",
          role: .implementer
        )
      ]
    )

    let model = AppModel(storeRegistry: registry, selectedProductID: product.id)
    await model.reload()
    try await store.execute(
      """
      CREATE TRIGGER fail_e10_batch_acceptance
      BEFORE INSERT ON activity_events
      WHEN NEW.kind = 'ticket_suggestion.accepted'
        AND NEW.detail = 'Build the reviewed contract'
      BEGIN
        SELECT RAISE(ABORT, 'injected E10 batch interruption');
      END;
      """
    )
    let interruptedAll = await withCheckedContinuation { continuation in
      model.decideAllTicketSuggestions(
        sessionID: acceptedSession.id,
        accept: true
      ) {
        continuation.resume(returning: $0)
      }
    }
    #expect(!interruptedAll)
    let afterInterruption = try await store.fetchTicketSuggestionBatch(
      sessionID: acceptedSession.id
    )
    #expect(afterInterruption.suggestions.allSatisfy { $0.status == .proposed })
    #expect(try await store.fetchWorkItems(productID: product.id).isEmpty)
    try await store.execute("DROP TRIGGER fail_e10_batch_acceptance;")
    let acceptedAll = await withCheckedContinuation { continuation in
      model.decideAllTicketSuggestions(
        sessionID: acceptedSession.id,
        accept: true
      ) {
        continuation.resume(returning: $0)
      }
    }
    #expect(acceptedAll)
    let accepted = try await store.fetchTicketSuggestionBatch(
      sessionID: acceptedSession.id
    )
    #expect(accepted.suggestions.allSatisfy { $0.status == .accepted })
    let acceptedItems = try await store.fetchWorkItems(productID: product.id)
    #expect(acceptedItems.count == acceptedReady.suggestions.count)
    let prerequisite = try #require(
      accepted.suggestions.first { $0.reference == "T1" }?.acceptedWorkItemID
    )
    let dependent = try #require(
      accepted.suggestions.first { $0.reference == "T2" }?.acceptedWorkItemID
    )
    #expect(
      try await store.fetchWorkItemDependencies(productID: product.id)
        .contains(
          WorkItemDependency(
            workItemID: dependent,
            dependsOnWorkItemID: prerequisite
          )
        )
    )
    #expect(try await store.fetchCurrentSprint(productID: product.id) == nil)

    let rejectedSession = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    _ = try await store.completeTicketSuggestionSession(
      sessionID: rejectedSession.id,
      drafts: [
        Self.suggestionDraft(
          reference: "S1",
          title: "Decline the first proposal",
          role: .implementer
        ),
        Self.suggestionDraft(
          reference: "S2",
          title: "Decline the second proposal",
          role: .qualityAssurance
        ),
      ]
    )
    await model.reload()
    let rejectedAll = await withCheckedContinuation { continuation in
      model.decideAllTicketSuggestions(
        sessionID: rejectedSession.id,
        accept: false
      ) {
        continuation.resume(returning: $0)
      }
    }
    #expect(rejectedAll)
    let rejected = try await store.fetchTicketSuggestionBatch(
      sessionID: rejectedSession.id
    )
    #expect(rejected.suggestions.allSatisfy { $0.status == .rejected })
    #expect(try await store.fetchWorkItems(productID: product.id).count == 2)
    #expect(try await store.fetchCurrentSprint(productID: product.id) == nil)
    #expect(
      try await otherStore.fetchTicketSuggestionBatch(sessionID: otherSession.id) == otherReady
    )
    await model.shutdown()

    for productStore in registry.allStores {
      await productStore.close()
    }

    let recoveredRegistry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    try await recoveredRegistry.prepare()
    let recoveredStore = try #require(recoveredRegistry.store(for: product.id))
    let recoveredOtherStore = try #require(recoveredRegistry.store(for: otherProduct.id))
    #expect(
      try await recoveredStore.fetchTicketSuggestionBatch(sessionID: acceptedSession.id)
        .suggestions.allSatisfy { $0.status == .accepted }
    )
    #expect(
      try await recoveredStore.fetchTicketSuggestionBatch(sessionID: rejectedSession.id)
        .suggestions.allSatisfy { $0.status == .rejected }
    )
    #expect(try await recoveredStore.fetchWorkItems(productID: product.id).count == 2)
    #expect(try await recoveredStore.fetchCurrentSprint(productID: product.id) == nil)
    #expect(
      try await recoveredOtherStore.fetchTicketSuggestionBatch(sessionID: otherSession.id)
        == otherReady
    )

    for productStore in recoveredRegistry.allStores {
      await productStore.close()
    }
  }

  @Test("E13 interrupted generation retries without duplicates or Product leakage")
  func e13InterruptedGenerationRetriesWithoutDuplicatesOrProductLeakage() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let firstProduct = try await registry.createProduct(name: "Interrupted planning")
    let secondProduct = try await registry.createProduct(name: "Unrelated planning")
    let firstStore = try #require(registry.store(for: firstProduct.id))
    let secondStore = try #require(registry.store(for: secondProduct.id))
    let firstEpic = try await firstStore.createEpic(
      productID: firstProduct.id,
      outcome: "Recover one interrupted plan"
    )
    let secondEpic = try await secondStore.createEpic(
      productID: secondProduct.id,
      outcome: "Keep another Product isolated"
    )
    let earlierSession = try await firstStore.beginTicketSuggestionSession(
      productID: firstProduct.id,
      epicID: firstEpic.id
    )
    _ = try await firstStore.completeTicketSuggestionSession(
      sessionID: earlierSession.id,
      drafts: [
        Self.suggestionDraft(
          reference: "S1",
          title: "Preserve an earlier proposal",
          role: .businessAnalyst
        )
      ]
    )
    let interruptedSession = try await firstStore.beginTicketSuggestionSession(
      productID: firstProduct.id,
      epicID: firstEpic.id
    )
    let otherSession = try await secondStore.beginTicketSuggestionSession(
      productID: secondProduct.id,
      epicID: secondEpic.id
    )
    _ = try await secondStore.completeTicketSuggestionSession(
      sessionID: otherSession.id,
      drafts: [
        Self.suggestionDraft(
          reference: "S1",
          title: "Unrelated Product proposal",
          role: .implementer
        )
      ]
    )

    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e13-retry")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e13-retry")])])
          ),
        ]
    )
    let recoveredModel = Self.makeModel(
      registry: registry,
      selectedProductID: firstProduct.id,
      transport: transport
    )
    await recoveredModel.load()
    await transport.waitForRequest("turn/start")
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e13-retry",
        turnID: "turn-e13-retry",
        text: Self.epicPlanResponse
      )
    )
    await recoveredModel.epicPlanningWorkflowCoordinator.settlePlanning()

    let firstBatches = try await firstStore.fetchOutstandingTicketSuggestionBatches(
      productID: firstProduct.id
    )
    #expect(firstBatches.map(\.session.id) == [earlierSession.id, interruptedSession.id])
    #expect(firstBatches.allSatisfy { $0.session.status == .ready })
    #expect(Set(firstBatches.flatMap(\.suggestions).map(\.id)).count == 2)
    #expect(recoveredModel.suggestionBatches.map(\.session.id) == [
      earlierSession.id, interruptedSession.id,
    ])
    let secondBatches = try await secondStore.fetchOutstandingTicketSuggestionBatches(
      productID: secondProduct.id
    )
    #expect(secondBatches.map(\.session.id) == [otherSession.id])
    #expect(secondBatches.flatMap(\.suggestions).map(\.title) == ["Unrelated Product proposal"])
    #expect(recoveredModel.suggestionBatches.allSatisfy {
      $0.session.productID == firstProduct.id
    })

    await recoveredModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("E16 an unresolved final plan escapes to durable questions and recovers")
  func e16FinalPlanEscapesToQuestionsAndRecovers() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Escaped planning")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Let owners preserve draft notes"
    )

    let escapeQuestion = TicketRefinementQuestion(
      prompt: "Where should draft notes be retained?",
      options: ["On this Mac (Recommended)", "In the repository"]
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e16")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e16-ready")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e16-escape")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: transport
    )
    await model.load()
    model.planEpic(epic)
    await transport.waitForRequest("turn/start")
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e16",
        turnID: "turn-e16-ready",
        text: #"{"message":"The outcome is ready to plan.","questions":[],"readyToPlan":true}"#
      )
    )
    await transport.waitForRequest("turn/start", count: 2)
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e16",
        turnID: "turn-e16-escape",
        text: #"""
          {"reply":{"message":"One product decision must be made before I can plan.","questions":[{"prompt":"Where should draft notes be retained?","options":["On this Mac (Recommended)","In the repository"]}]}}
          """#
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()

    let escapedConversation = try #require(
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(escapedConversation.questions == [escapeQuestion])
    #expect(escapedConversation.isComplete == false)
    #expect(escapedConversation.messages.last?.author == .businessAnalyst)
    #expect(
      escapedConversation.messages.last?.body
        == "One product decision must be made before I can plan."
    )
    let escapedSession = try #require(
      try await store.fetchLatestEpicPlanningSuggestionSession(epicID: epic.id)
    )
    #expect(escapedSession.status == .cancelled)
    #expect(
      try await store.fetchOutstandingTicketSuggestionBatches(productID: product.id).isEmpty
    )
    #expect(model.suggestionBatches.isEmpty)
    #expect(model.epicPlanningConversation(for: epic.id)?.questions == [escapeQuestion])
    #expect(model.epicPlanningConversation(for: epic.id)?.isGeneratingPlan == false)
    #expect(model.epicPlanningConversation(for: epic.id)?.errorMessage == nil)
    let notification = try #require(
      try await store.fetchActiveOwnerNotifications(productID: product.id).first
    )
    #expect(notification.kind == .needsInput)
    #expect(notification.target == OwnerNotificationTarget(kind: .epic, id: epic.id))
    #expect(notification.body == "Where should draft notes be retained?")
    #expect(try await store.fetchWorkItems(productID: product.id).isEmpty)
    await model.shutdown()

    let interruptedModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
    await interruptedModel.reload()
    let restoredEpic = try #require(
      interruptedModel.epics.first(where: { $0.id == epic.id })
    )
    await interruptedModel.restoreEpicPlanningConversation(for: restoredEpic)
    #expect(interruptedModel.epicPlanningConversation(for: epic.id)?.questions == [escapeQuestion])
    #expect(interruptedModel.epicPlanningConversation(for: epic.id)?.isComplete == false)
    #expect(interruptedModel.epicPlanningConversation(for: epic.id)?.errorMessage == nil)
    await interruptedModel.shutdown()

    let answeringTransport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e16-settled")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e16-plan")])])
          ),
        ]
    )
    let answeringModel = Self.makeModel(
      registry: registry,
      selectedProductID: product.id,
      transport: answeringTransport
    )
    await answeringModel.load()
    await answeringModel.restoreEpicPlanningConversation(for: restoredEpic)
    answeringModel.continueEpicPlanning(
      restoredEpic,
      answers: ["Where should draft notes be retained?\nAnswer: On this Mac (Recommended)"],
      answeredQuestions: [
        EpicPlanningAnsweredQuestion(
          question: escapeQuestion,
          selectedOption: "On this Mac (Recommended)",
          answer: "On this Mac (Recommended)"
        )
      ]
    )
    await answeringTransport.waitForRequest("turn/start")
    await answeringTransport.emit(
      Self.completedTurn(
        threadID: "thread-e16",
        turnID: "turn-e16-settled",
        text: #"{"message":"That settles the outstanding decision.","questions":[],"readyToPlan":true}"#
      )
    )
    await answeringTransport.waitForRequest("turn/start", count: 2)
    await answeringTransport.emit(
      Self.completedTurn(
        threadID: "thread-e16",
        turnID: "turn-e16-plan",
        text: Self.epicPlanResponse
      )
    )
    await answeringModel.epicPlanningWorkflowCoordinator.settlePlanning()

    let plannedEpic = try #require(
      try await store.fetchEpics(productID: product.id)
        .first(where: { $0.id == epic.id })
    )
    #expect(plannedEpic.title == "Durable draft notes")
    let batch = try #require(
      try await store.fetchLatestTicketSuggestionBatch(productID: product.id)
    )
    #expect(batch.session.status == .ready)
    #expect(batch.suggestions.map(\.title) == ["Preserve and reopen draft notes"])
    let completedConversation = try #require(
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(completedConversation.isComplete == true)
    #expect(completedConversation.questions.isEmpty)
    #expect(
      completedConversation.messages.flatMap(\.answeredQuestions).map(\.answer)
        == ["On this Mac (Recommended)"]
    )
    await answeringModel.shutdown()
    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("E17 concurrent Epic planning across Products keeps each conversation intact")
  func e17ConcurrentPlanningAcrossProducts() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let firstProduct = try await registry.createProduct(name: "First product")
    let secondProduct = try await registry.createProduct(name: "Second product")
    let firstStore = try #require(registry.store(for: firstProduct.id))
    let secondStore = try #require(registry.store(for: secondProduct.id))
    let firstEpic = try await firstStore.createEpic(
      productID: firstProduct.id,
      outcome: "Let owners preserve draft notes"
    )
    let secondEpic = try await secondStore.createEpic(
      productID: secondProduct.id,
      outcome: "Show a seven day forecast"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e17-a")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e17-a")])])
          ),
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e17-b")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e17-b")])])
          ),
        ]
    )
    let model = Self.makeModel(
      registry: registry,
      selectedProductID: firstProduct.id,
      transport: transport
    )

    await model.load()
    model.planEpic(firstEpic)
    await transport.waitForRequest("turn/start")
    await model.selectProduct(secondProduct)
    model.planEpic(secondEpic)
    await transport.waitForRequest("turn/start", count: 2)

    #expect(model.epicPlanningConversation(for: firstEpic.id)?.isRunning == true)
    #expect(model.epicPlanningConversation(for: secondEpic.id)?.isRunning == true)

    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e17-a",
        turnID: "turn-e17-a",
        text: #"{"message":"I need one product decision.","questions":[{"prompt":"Where should drafts be retained?","options":["On this Mac","In the repository"]}],"readyToPlan":false}"#
      )
    )
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e17-b",
        turnID: "turn-e17-b",
        text: #"{"message":"I need one forecast decision.","questions":[{"prompt":"Which provider supplies the forecast?","options":["Provider A","Provider B"]}],"readyToPlan":false}"#
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()

    let firstDurable = try #require(
      try await firstStore.fetchEpicPlanningConversation(epicID: firstEpic.id)
    )
    let secondDurable = try #require(
      try await secondStore.fetchEpicPlanningConversation(epicID: secondEpic.id)
    )
    #expect(firstDurable.questions.map(\.prompt) == ["Where should drafts be retained?"])
    #expect(secondDurable.questions.map(\.prompt) == ["Which provider supplies the forecast?"])
    #expect(firstDurable.threadID == "thread-e17-a")
    #expect(secondDurable.threadID == "thread-e17-b")

    #expect(model.epicPlanningConversation(for: firstEpic.id)?.isRunning == false)
    #expect(
      model.epicPlanningConversation(for: firstEpic.id)?.questions
        == firstDurable.questions
    )
    #expect(model.epicPlanningConversation(for: secondEpic.id)?.isRunning == false)
    #expect(
      model.epicPlanningConversation(for: secondEpic.id)?.questions
        == secondDurable.questions
    )

    let firstNotification = try #require(
      try await firstStore.fetchActiveOwnerNotifications(productID: firstProduct.id).first
    )
    #expect(firstNotification.kind == .needsInput)
    #expect(firstNotification.target == OwnerNotificationTarget(kind: .epic, id: firstEpic.id))
    let secondNotification = try #require(
      try await secondStore.fetchActiveOwnerNotifications(productID: secondProduct.id).first
    )
    #expect(secondNotification.kind == .needsInput)
    #expect(
      secondNotification.target == OwnerNotificationTarget(kind: .epic, id: secondEpic.id)
    )

    await model.shutdown()

    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: secondProduct.id,
      ownerNotificationSoundPlayer: EpicJourneyNotificationSound(),
      ownerNotificationSystemNotifier: EpicJourneySystemNotifier()
    )
    await recoveredModel.reload()
    await recoveredModel.restoreEpicPlanningConversation(for: firstEpic)
    await recoveredModel.restoreEpicPlanningConversation(for: secondEpic)

    #expect(
      recoveredModel.epicPlanningConversation(for: firstEpic.id)?.questions
        == firstDurable.questions
    )
    #expect(
      recoveredModel.epicPlanningConversation(for: secondEpic.id)?.questions
        == secondDurable.questions
    )
    await recoveredModel.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("E18 a Product round-trip during plan generation keeps the live run")
  func e18ProductRoundTripKeepsLivePlanGeneration() async throws {
    let fixture = try EpicPlanningJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let firstProduct = try await registry.createProduct(name: "Planning product")
    let secondProduct = try await registry.createProduct(name: "Visited product")
    let firstStore = try #require(registry.store(for: firstProduct.id))
    let epic = try await firstStore.createEpic(
      productID: firstProduct.id,
      outcome: "Let owners preserve draft notes"
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-e18")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e18-ready")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-e18-plan")])])
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
    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e18",
        turnID: "turn-e18-ready",
        text: #"{"message":"The outcome is ready to plan.","questions":[],"readyToPlan":true}"#
      )
    )
    await transport.waitForRequest("turn/start", count: 2)
    let generatingSession = try #require(
      try await firstStore.fetchLatestTicketSuggestionBatch(productID: firstProduct.id)
    ).session
    #expect(generatingSession.status == .generating)

    await model.selectProduct(secondProduct)
    await model.selectProduct(firstProduct)

    #expect(model.suggestionBatches.map(\.session.id) == [generatingSession.id])
    #expect(model.suggestionBatches.first?.session.status == .generating)
    #expect(model.epicPlanningConversation(for: epic.id)?.errorMessage == nil)
    #expect(model.epicPlanningConversation(for: epic.id)?.isGeneratingPlan == true)

    await transport.emit(
      Self.completedTurn(
        threadID: "thread-e18",
        turnID: "turn-e18-plan",
        text: Self.epicPlanResponse
      )
    )
    await model.epicPlanningWorkflowCoordinator.settlePlanning()

    let outstanding = try await firstStore.fetchOutstandingTicketSuggestionBatches(
      productID: firstProduct.id
    )
    #expect(outstanding.map(\.session.id) == [generatingSession.id])
    #expect(outstanding.first?.session.status == .ready)
    #expect(outstanding.first?.session.errorMessage == nil)
    #expect(outstanding.first?.suggestions.map(\.title) == ["Preserve and reopen draft notes"])
    #expect(model.suggestionBatches.map(\.session.id) == [generatingSession.id])
    #expect(model.epicPlanningConversation(for: epic.id)?.errorMessage == nil)
    #expect(model.epicPlanningConversation(for: epic.id)?.isComplete == true)
    let turnStarts = await transport.recordedRequests()
      .filter { $0.method == "turn/start" }
    #expect(turnStarts.count == 2)
    #expect(await transport.remainingResponseCount() == 0)

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  private static func suggestionDraft(
    reference: String,
    title: String,
    type: WorkItemType = .story,
    body: String = "Deliver the agreed outcome.",
    criteria: [String] = ["The agreed outcome is complete"],
    role: AgentRole,
    priority: WorkItemPriority = .normal,
    dependsOn: [String] = []
  ) -> TicketSuggestionDraft {
    TicketSuggestionDraft(
      reference: reference,
      title: title,
      type: type,
      body: body,
      acceptanceCriteria: criteria,
      suggestedRole: role,
      priority: priority,
      rationale: "Required by the agreed Epic outcome.",
      dependsOnReferences: dependsOn
    )
  }

  private static let epicPlanResponse = #"""
    {
      "reply": {
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
          "environmentRelationship": "independent",
          "demoKind": "mac_application"
        }
      ]
      }
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
