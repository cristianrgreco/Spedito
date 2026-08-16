import Foundation
import SpeditoCore
import SpeditoTestSupport
import Testing

@testable import SpeditoApp

@Suite("Sprint planning workflow journeys", .serialized)
@MainActor
struct SprintPlanningWorkflowJourneyTests {
  @Test("A generated goal completing after Product switch stays with its exact plan")
  func generatedGoalStaysWithOwningPlanAcrossProductSwitchAndRelaunch() async throws {
    let fixture = try SprintPlanningWorkflowJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let firstProduct = try await registry.createProduct(name: "Planning product")
    let secondProduct = try await registry.createProduct(name: "Current product")
    let firstStore = try #require(registry.store(for: firstProduct.id))
    _ = try await firstStore.seedDefaultProfiles(productID: firstProduct.id)
    let ticket = try await firstStore.createWorkItem(
      productID: firstProduct.id,
      title: "Give owners a durable sprint outcome",
      acceptanceCriteria: ["The outcome survives a relaunch"]
    )
    let draft = try await firstStore.saveDraftSprint(
      productID: firstProduct.id,
      goal: "",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: ticket.id, estimatedTokens: 1)
      ]
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("sprint-goal-thread")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("sprint-goal-turn")])])
          ),
        ]
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: firstProduct.id,
      codexTransportFactory: { _ in
        CodexTransportFactoryOutput(
          descriptor: CodexRuntimeDescriptor(
            executableURL: URL(fileURLWithPath: "/private/tmp/codex-test"),
            version: "test",
            source: .custom
          ),
          transport: transport
        )
      }
    )
    await model.load()

    let generation = Task { @MainActor in
      try await model.generateAndSaveSprintGoal(
        for: draft.sprint.id,
        planVersion: draft.sprint.planVersion
      )
    }
    await transport.waitForRequest("turn/start")
    await model.selectProduct(secondProduct)
    await transport.emit(
      Self.completedTurn(
        threadID: "sprint-goal-thread",
        turnID: "sprint-goal-turn",
        text: #"{"goal":"Give owners a durable sprint outcome"}"#
      )
    )

    #expect(try await generation.value == "Give owners a durable sprint outcome")
    #expect(model.selectedProductID == secondProduct.id)
    #expect(model.sprintPlan?.sprint.productID == secondProduct.id || model.sprintPlan == nil)
    let saved = try #require(
      try await firstStore.fetchCurrentSprint(productID: firstProduct.id)
    )
    #expect(saved.sprint.goal == "Give owners a durable sprint outcome")
    #expect(saved.sprint.planVersion == draft.sprint.planVersion + 1)

    await model.shutdown()
    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: firstProduct.id
    )
    await recoveredModel.reload()
    #expect(recoveredModel.candidateSprintPlan?.sprint.goal == saved.sprint.goal)
    #expect(recoveredModel.candidateSprintPlan?.sprint.planVersion == saved.sprint.planVersion)
    await recoveredModel.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Stopping a sprint planning reply records a durable labelled failure")
  func stoppedPlanningReplySettlesDurably() async throws {
    let fixture = try SprintPlanningWorkflowJourneyFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Planning product")
    let store = try #require(registry.store(for: product.id))
    _ = try await store.seedDefaultProfiles(productID: product.id)
    let ticket = try await store.createWorkItem(
      productID: product.id,
      title: "Review the sprint ticket",
      acceptanceCriteria: ["The reply is recorded in the work log"]
    )
    _ = try await store.saveDraftSprint(
      productID: product.id,
      goal: "",
      tokenBudgetLimit: nil,
      items: [SprintDraftItemInput(workItemID: ticket.id, estimatedTokens: 1)]
    )
    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("planning-thread")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("planning-turn")])])
          ),
          .init(method: "turn/interrupt", result: .object([:])),
        ]
    )
    let model = AppModel(
      storeRegistry: registry,
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
      }
    )
    await model.load()
    let recipient = try #require(model.profiles.first { $0.role == .businessAnalyst })
    let ownerMessage = "Check whether this ticket is ready"
    _ = try await store.appendComment(
      workItemID: ticket.id,
      authorKind: .owner,
      authorName: "Me",
      body: "@\(recipient.name) \(ownerMessage)"
    )
    let reply = Task { @MainActor in
      try await model.sendSprintPlanningMessage(
        for: ticket,
        to: recipient,
        ownerMessage: ownerMessage,
        ticketSnapshot: SprintPlanningTicketSnapshot(
          version: ticket.version,
          title: ticket.title,
          type: ticket.type,
          body: ticket.body,
          acceptanceCriteria: ticket.acceptanceCriteria,
          priority: ticket.priority
        ),
        proposedAssignee: nil
      )
    }
    await transport.waitForRequest("turn/start")
    model.cancelSprintPlanningMessage()
    await transport.waitForRequest("turn/interrupt")
    await transport.emit(
      Self.interruptedTurn(
        threadID: "planning-thread",
        turnID: "planning-turn"
      )
    )
    do {
      _ = try await reply.value
      Issue.record("Expected the stopped planning reply to fail")
    } catch {}

    let comments = try await store.fetchComments(workItemID: ticket.id)
    let failure = try #require(comments.last)
    #expect(failure.authorKind == .system)
    #expect(failure.authorName == "Spedito")
    #expect(failure.body.contains("\(recipient.name) couldn't reply"))
    #expect(!model.isPlanningMessageRunning)

    await model.shutdown()
    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )
    await recoveredModel.reload()
    #expect(try await store.fetchComments(workItemID: ticket.id).last == failure)
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
          "userAgent": .string("codex-cli/sprint-planning-journey-test"),
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

  private static func interruptedTurn(
    threadID: String,
    turnID: String
  ) -> CodexInboundMessage {
    .notification(
      CodexNotification(
        method: "turn/completed",
        params: .object([
          "threadId": .string(threadID),
          "turn": .object([
            "id": .string(turnID),
            "status": .string("interrupted"),
            "items": .array([]),
          ]),
        ])
      )
    )
  }
}

private struct SprintPlanningWorkflowJourneyFixture {
  let rootURL: URL
  let workspacesURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-sprint-planning-workflow-\(UUID())",
      isDirectory: true
    )
    workspacesURL = rootURL.appendingPathComponent("Product Workspaces", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
