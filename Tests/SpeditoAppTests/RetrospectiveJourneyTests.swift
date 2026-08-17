import Foundation
import SpeditoCore
import SpeditoTestSupport
import Testing

@testable import SpeditoApp

@Suite("Retrospective owner journeys")
struct RetrospectiveJourneyTests {
  /// Existing evidence:
  /// - `SQLiteStoreTests.retrospectiveEvidenceLifecycle` proves the atomic action-to-Ticket write.
  /// - `TicketConversationHistoryTests.completeHistory` proves normal refinement history ordering.
  /// This journey adds the missing AppModel composition from the accepted action to the exact
  /// normal refinement operation, plus fresh-instance recovery of its durable result.
  @Test("[I07] Accepted Backlog action opens refinement for its exact durable Ticket")
  @MainActor
  func i07AcceptedBacklogActionOpensExactTicketRefinement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Spedito-I07-\(UUID().uuidString)",
      isDirectory: true
    )
    let workspacesURL = directory.appendingPathComponent("workspaces", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = try ProductStoreRegistry(productWorkspacesRootURL: workspacesURL)
    let product = try await registry.createProduct(name: "Retrospective refinement")
    let store = try #require(registry.store(for: product.id))
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let analyst = try #require(profiles.first { $0.role == .businessAnalyst })
    let deliveredItem = try await readyItem(
      in: store,
      productID: product.id,
      title: "Source delivery"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Turn evidence into action",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: deliveredItem.id,
          implementerProfileID: implementer.id,
          estimatedTokens: 1
        )
      ]
    )
    _ = try await store.startSprint(id: draft.sprint.id)
    if let run = try await store.fetchAgentRuns(productID: product.id).first {
      _ = try await store.updateAgentRun(id: run.id, status: .completed)
    }
    try await complete(deliveredItem, in: store)
    _ = try await store.completeSprintIfFinished(id: draft.sprint.id)
    let synthesis = try #require(
      try await store.fetchRetrospectiveSyntheses(productID: product.id)
        .first { $0.sprintID == draft.sprint.id }
    )
    _ = try await store.skipRetrospectiveSynthesis(id: synthesis.id)
    let action = RetrospectiveNote(
      productID: product.id,
      sprintID: draft.sprint.id,
      workItemID: deliveredItem.id,
      profileID: analyst.id,
      authorName: analyst.name,
      category: .suggestedAction,
      body: "Document the exact owner review path",
      isActionCandidate: false,
      actionStatus: .proposed,
      actionDestination: .backlog,
      expectedEffect: "The accepted action enters normal Business Analyst refinement.",
      synthesisID: synthesis.id
    )
    try await store.saveRetrospectiveNotes([action])

    let transport = ScriptedCodexTransport(
      responses: Self.connectionResponses()
        + [
          .init(
            method: "thread/start",
            result: .object(["thread": .object(["id": .string("thread-i07")])])
          ),
          .init(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-i07")])])
          ),
        ]
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      codexTransportFactory: { _ in
        CodexTransportFactoryOutput(
          descriptor: CodexRuntimeDescriptor(
            executableURL: URL(fileURLWithPath: "/private/tmp/codex-i07-test"),
            version: "test",
            source: .custom
          ),
          transport: transport
        )
      },
      ownerNotificationSoundPlayer: RetrospectiveJourneyNotificationSound(),
      ownerNotificationSystemNotifier: RetrospectiveJourneySystemNotifier()
    )
    await model.load()
    let loadedAction = try #require(model.retrospectiveNotes.first { $0.id == action.id })
    let createdItem = try #require(
      await model.decideRetrospectiveAction(loadedAction, accept: true)
    )
    let refinement = Task { @MainActor in
      try await model.refineTicket(createdItem)
    }
    await transport.waitForRequest("turn/start")

    #expect(model.refiningWorkItemID == createdItem.id)
    #expect(createdItem.title == action.body)
    #expect(createdItem.state == .backlog)
    let storedAction = try #require(
      try await store.fetchRetrospectiveNotes(productID: product.id)
        .first { $0.id == action.id }
    )
    #expect(storedAction.actionStatus == .accepted)
    #expect(storedAction.acceptedWorkItemID == createdItem.id)

    await transport.emit(
      Self.completedTurn(
        threadID: "thread-i07",
        turnID: "turn-i07",
        text: #"""
          {
            "message": "I need one product decision before completing refinement.",
            "proposal": {
              "baseVersion": \#(createdItem.version),
              "title": "Document the exact owner review path",
              "type": "task",
              "body": "",
              "acceptanceCriteria": [],
              "priority": "normal",
              "role": "business_analyst",
              "rationale": "Confirm the durable refinement boundary.",
              "dependencies": [],
              "potentialDuplicates": [],
              "splitRecommendation": null,
              "missingQuestions": [
                {
                  "prompt": "Which owner review should this document?",
                  "options": ["Ticket review", "Sprint review"]
                }
              ]
            }
          }
          """#
      )
    )
    let reply = try await refinement.value
    #expect(reply.proposal.baseVersion == createdItem.version)
    #expect(model.ticketRefinementResults[createdItem.id]?.reply != nil)
    await model.shutdown()

    let recoveredModel = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: RetrospectiveJourneyNotificationSound(),
      ownerNotificationSystemNotifier: RetrospectiveJourneySystemNotifier()
    )
    await recoveredModel.reload()
    let recoveredAction = try #require(
      recoveredModel.retrospectiveNotes.first { $0.id == action.id }
    )
    #expect(recoveredAction.actionStatus == .accepted)
    #expect(recoveredAction.acceptedWorkItemID == createdItem.id)
    #expect(recoveredModel.workItems.contains { $0.id == createdItem.id })
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
          "userAgent": .string("codex-cli/i07-test"),
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

  private func readyItem(
    in store: SQLiteStore,
    productID: UUID,
    title: String
  ) async throws -> WorkItem {
    let item = try await store.createWorkItem(
      productID: productID,
      title: title,
      acceptanceCriteria: ["The delivered outcome is observable."]
    )
    _ = try await store.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Business analyst",
      reason: "Refine source delivery"
    )
    return try await store.transitionWorkItem(
      id: item.id,
      to: .ready,
      actor: "Product owner",
      reason: "Ready for delivery"
    )
  }

  private func complete(_ item: WorkItem, in store: SQLiteStore) async throws {
    for state in [
      WorkItemState.running,
      .integrating,
      .verifying,
      .acceptance,
      .readyToRelease,
      .released,
    ] {
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: "Journey fixture",
        reason: "Complete source delivery"
      )
    }
  }
}

@MainActor
private final class RetrospectiveJourneyNotificationSound: OwnerNotificationSoundPlaying {
  func play() {}
}

@MainActor
private final class RetrospectiveJourneySystemNotifier: OwnerNotificationSystemNotifying {
  func post(_: OwnerNotificationPresentation) {}
  func dismiss(ids _: [UUID]) {}
}
