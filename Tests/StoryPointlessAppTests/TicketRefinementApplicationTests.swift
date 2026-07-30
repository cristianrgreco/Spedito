import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

@Suite("Ticket refinement application")
struct TicketRefinementApplicationTests {
  @Test("A completed refinement updates the ticket, dependencies, and assignee together")
  @MainActor
  func completedRefinementIsAppliedAsOneUpdate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoryPointlessTicketRefinement-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteStore(
      url: directory.appendingPathComponent("ticket-refinement.sqlite")
    )
    let product = try await store.createProduct(
      name: "Refinement",
      vision: "Keep ticket refinement coherent"
    )
    let existingPrerequisite = try await store.createWorkItem(
      productID: product.id,
      title: "Existing prerequisite"
    )
    let suggestedPrerequisite = try await store.createWorkItem(
      productID: product.id,
      title: "Suggested prerequisite"
    )
    let createdItem = try await store.createWorkItem(
      productID: product.id,
      title: "Rough ticket",
      dependsOnWorkItemIDs: [existingPrerequisite.id]
    )
    let item = try await store.updateWorkItem(
      id: createdItem.id,
      title: createdItem.title,
      type: createdItem.type,
      body: createdItem.body,
      acceptanceCriteria: createdItem.acceptanceCriteria,
      priority: createdItem.priority,
      customFields: ["Area": "Checkout"]
    )

    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let proposal = TicketRefinementProposal(
      baseVersion: item.version,
      title: "Complete checkout with a saved address",
      type: .story,
      body: "Let a returning customer use a previously saved delivery address.",
      acceptanceCriteria: [
        "A returning customer can select a saved address",
        "The selected address is used for the order",
      ],
      priority: .high,
      suggestedRole: .uxDesigner,
      rationale: "The refined ticket describes one testable customer outcome.",
      dependencies: [
        TicketRefinementDependencyProposal(
          ticketKey: suggestedPrerequisite.key,
          reason: "The address contract must exist first."
        )
      ],
      potentialDuplicates: [],
      splitRecommendation: nil,
      missingQuestions: []
    )

    let updated = try await model.applyCompletedTicketRefinement(proposal, to: item)
    let dependencyIDs = Set(
      try await store.fetchWorkItemDependencies(productID: product.id)
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )

    #expect(updated.title == proposal.title)
    #expect(updated.type == proposal.type)
    #expect(updated.body == proposal.body)
    #expect(updated.acceptanceCriteria == proposal.acceptanceCriteria)
    #expect(updated.priority == proposal.priority)
    let designer = try #require(model.profiles.first { $0.role == .uxDesigner })
    #expect(updated.ownerProfileID == designer.id)
    #expect(updated.customFields == ["Area": "Checkout"])
    #expect(updated.version == item.version + 1)
    #expect(dependencyIDs == [existingPrerequisite.id, suggestedPrerequisite.id])
    await store.close()
  }

  @Test("A completed refinement assigns an unassigned Next sprint ticket without replacing its plan")
  @MainActor
  func completedRefinementUpdatesDraftSprintAssignee() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoryPointlessTicketRefinementDraft-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteStore(
      url: directory.appendingPathComponent("ticket-refinement-draft.sqlite")
    )
    let product = try await store.createProduct(
      name: "Draft refinement",
      vision: "Keep AI assignment consistent with sprint planning"
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Rough implementation ticket"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Deliver the refined outcome",
      tokenBudgetLimit: nil,
      concurrencyLimit: 2,
      items: [SprintDraftItemInput(workItemID: item.id)]
    )
    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let proposal = TicketRefinementProposal(
      baseVersion: item.version,
      title: "Build the approved account summary",
      type: .story,
      body: "Show a customer the approved account summary.",
      acceptanceCriteria: ["The customer can see the approved account summary"],
      priority: .normal,
      suggestedRole: .implementer,
      rationale: "The implementation outcome is explicit.",
      dependencies: [],
      potentialDuplicates: [],
      splitRecommendation: nil,
      missingQuestions: []
    )

    let updated = try await model.applyCompletedTicketRefinement(proposal, to: item)
    let implementer = try #require(model.profiles.first { $0.role == .implementer })
    let updatedDraft = try #require(try await store.fetchCurrentSprint(productID: product.id))
    let sprintItem = try #require(
      updatedDraft.items.first { $0.workItemID == item.id }
    )

    #expect(updated.ownerProfileID == implementer.id)
    #expect(updatedDraft.sprint.id == draft.sprint.id)
    #expect(sprintItem.implementerProfileID == implementer.id)
    await store.close()
  }

  @Test("A completed refinement preserves an existing Product Owner assignee")
  @MainActor
  func completedRefinementPreservesExistingAssignee() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoryPointlessTicketRefinementAssigned-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteStore(
      url: directory.appendingPathComponent("ticket-refinement-assigned.sqlite")
    )
    let product = try await store.createProduct(
      name: "Assigned refinement",
      vision: "Preserve Product Owner assignment decisions"
    )
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementer = try #require(profiles.first { $0.role == .implementer })
    let created = try await store.createWorkItem(
      productID: product.id,
      title: "Rough experience ticket"
    )
    let item = try await store.assignWorkItemOwner(
      id: created.id,
      profileID: implementer.id
    )
    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let proposal = TicketRefinementProposal(
      baseVersion: item.version,
      title: "Design the account summary experience",
      type: .story,
      body: "Define the account summary interaction.",
      acceptanceCriteria: ["The approved interaction is documented"],
      priority: .normal,
      suggestedRole: .uxDesigner,
      rationale: "The experience outcome is explicit.",
      dependencies: [],
      potentialDuplicates: [],
      splitRecommendation: nil,
      missingQuestions: []
    )

    let updated = try await model.applyCompletedTicketRefinement(proposal, to: item)

    #expect(updated.ownerProfileID == implementer.id)
    await store.close()
  }

  @Test("Clarification questions prevent a ticket update")
  @MainActor
  func unresolvedRefinementIsNotApplied() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StoryPointlessTicketClarification-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteStore(
      url: directory.appendingPathComponent("ticket-clarification.sqlite")
    )
    let product = try await store.createProduct(
      name: "Clarification",
      vision: "Keep Product Owner decisions explicit"
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Choose an audience"
    )
    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()
    let proposal = TicketRefinementProposal(
      baseVersion: item.version,
      title: item.title,
      type: item.type,
      body: item.body,
      acceptanceCriteria: item.acceptanceCriteria,
      priority: item.priority,
      rationale: "The audience changes the outcome.",
      dependencies: [],
      potentialDuplicates: [],
      splitRecommendation: nil,
      missingQuestions: [
        TicketRefinementQuestion(
          prompt: "Which audience should this serve first?",
          options: ["New customers", "Returning customers"]
        )
      ]
    )

    await #expect(throws: TicketRefinementGenerationError.self) {
      try await model.applyCompletedTicketRefinement(proposal, to: item)
    }
    let unchanged = try #require(
      try await store.fetchWorkItems(productID: product.id).first { $0.id == item.id }
    )
    #expect(unchanged.version == item.version)
    await store.close()
  }
}
