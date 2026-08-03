import Foundation
import SpeditoCore
import Testing
@testable import SpeditoApp

@Suite("Product-scoped persistence", .serialized)
@MainActor
struct ProductScopedPersistenceTests {
  @Test("A ready Epic plan repairs an interrupted conversation snapshot")
  func readyEpicPlanRepairsInterruptedConversation() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Recovered product")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Recover an interrupted Epic plan"
    )
    let interruptedSnapshot = EpicPlanningConversationSnapshot(
      epicID: epic.id,
      messages: [
        EpicPlanningConversationMessage(
          author: .businessAnalyst,
          body: "The outcome is ready to plan."
        )
      ],
      questions: [],
      isComplete: false,
      threadID: "recovered-thread"
    )
    try await store.saveEpicPlanningConversation(interruptedSnapshot)
    let session = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: epic.id
    )
    _ = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Deliver the recovered outcome",
          body: "Complete the planned Product change.",
          acceptanceCriteria: ["The recovered plan remains reviewable"],
          suggestedRole: .implementer,
          priority: .high,
          rationale: "The durable plan completed before the interruption."
        )
      ]
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )

    await model.restoreEpicPlanningConversation(for: epic)

    let conversation = try #require(model.epicPlanningConversation)
    #expect(conversation.epicID == epic.id)
    #expect(conversation.isComplete)
    #expect(conversation.errorMessage == nil)
    let repairedSnapshot = try #require(
      try await store.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(repairedSnapshot.isComplete)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Epic planning snapshots stay with their Epic after product selection changes")
  func epicPlanningSnapshotUsesOwningProductStore() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(name: "First product")
    let second = try await registry.createProduct(name: "Second product")
    let firstStore = try #require(registry.store(for: first.id))
    let secondStore = try #require(registry.store(for: second.id))
    let epic = try await firstStore.createEpic(
      productID: first.id,
      outcome: "Keep planning in the first product"
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: second.id
    )
    let conversation = EpicPlanningConversationState(
      productID: first.id,
      epicID: epic.id,
      messages: [
        EpicPlanningConversationMessage(
          author: .owner,
          body: "Plan this Epic"
        )
      ],
      questions: [],
      hasStartedPlanning: true,
      isRunning: false,
      isGeneratingPlan: true,
      isComplete: false,
      errorMessage: nil
    )

    try await model.saveEpicPlanningConversation(
      conversation,
      threadID: "first-product-thread"
    )

    let saved = try #require(
      try await firstStore.fetchEpicPlanningConversation(epicID: epic.id)
    )
    #expect(saved.messages == conversation.messages)
    #expect(saved.threadID == "first-product-thread")
    #expect(try await secondStore.fetchEpicPlanningConversation(epicID: epic.id) == nil)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Epic, Ticket, and Work log writes use the entity's owning product")
  func entityWritesUseOwningProductStore() async throws {
    let fixture = try ProductScopedPersistenceFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(name: "First product")
    let second = try await registry.createProduct(name: "Second product")
    let firstStore = try #require(registry.store(for: first.id))
    let secondStore = try #require(registry.store(for: second.id))
    let epic = try await firstStore.createEpic(
      productID: first.id,
      outcome: "Original outcome"
    )
    let item = try await firstStore.createWorkItem(
      productID: first.id,
      title: "Original Ticket",
      epicID: epic.id
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: second.id
    )

    let updatedEpic = await model.updateEpic(
      epic,
      title: "Updated Epic",
      goal: "Keep the Product boundary",
      successCriteria: ["Writes reach the owning database"],
      constraints: "No selection-dependent routing"
    )
    let didUpdateTicket = await model.updateWorkItem(
      productID: first.id,
      id: item.id,
      title: "Updated Ticket",
      type: item.type,
      body: "Updated while another Product is selected",
      acceptanceCriteria: ["The first Product owns the change"],
      priority: item.priority,
      customFields: item.customFields,
      dependsOnWorkItemIDs: [],
      expectedVersion: item.version
    )
    let comment = await model.appendOwnerComment(
      workItemID: item.id,
      productID: first.id,
      body: "This comment belongs to the first Product."
    )

    #expect(updatedEpic?.title == "Updated Epic")
    #expect(didUpdateTicket)
    #expect(comment?.workItemID == item.id)
    #expect(try await firstStore.fetchEpics(productID: first.id).first?.title == "Updated Epic")
    #expect(
      try await firstStore.fetchWorkItems(productID: first.id).first?.title
        == "Updated Ticket"
    )
    #expect(try await firstStore.fetchComments(workItemID: item.id).map(\.body) == [
      "This comment belongs to the first Product."
    ])
    #expect(try await secondStore.fetchEpics(productID: second.id).isEmpty)
    #expect(try await secondStore.fetchWorkItems(productID: second.id).isEmpty)

    for store in registry.allStores {
      await store.close()
    }
  }
}

private struct ProductScopedPersistenceFixture {
  let directoryURL: URL
  let workspacesURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-product-scoped-persistence-\(UUID())",
        isDirectory: true
      )
    workspacesURL = directoryURL.appendingPathComponent(
      "Product Workspaces",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
