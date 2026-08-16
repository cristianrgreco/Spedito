import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Sprint board selection")
struct SprintBoardSelectionTests {
  @Test("Opening a newly planned sprint replaces the previous board selection")
  func newlyPlannedSprintBecomesSelected() {
    let productID = UUID()
    let previousSprintID = UUID()
    let plannedSprintID = UUID()
    defer {
      SprintBoardSelectionDefaults.select(nil, for: productID)
    }

    SprintBoardSelectionDefaults.select(previousSprintID, for: productID)
    #expect(
      SprintBoardSelectionDefaults.selectedSprintID(for: productID)
        == previousSprintID
    )

    SprintBoardSelectionDefaults.select(plannedSprintID, for: productID)
    #expect(
      SprintBoardSelectionDefaults.selectedSprintID(for: productID)
        == plannedSprintID
    )
  }

  @Test("P03 partial plans persist while discarded picker changes stay local")
  @MainActor
  func p03PartialPlanAndDiscardedPickerState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-sprint-planning-p03-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Planning Product")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementers = profiles.filter(\.role.canOwnDelivery)
    let firstImplementer = try #require(implementers.first)
    let secondImplementer = try #require(implementers.dropFirst().first)

    var firstTicket = try await store.createWorkItem(
      productID: product.id,
      title: "First planned outcome",
      acceptanceCriteria: ["The first outcome is visible"]
    )
    var secondTicket = try await store.createWorkItem(
      productID: product.id,
      title: "Second planned outcome",
      acceptanceCriteria: ["The second outcome is visible"]
    )
    for state: WorkItemState in [.refining, .ready] {
      firstTicket = try await store.transitionWorkItem(
        id: firstTicket.id,
        to: state,
        actor: "Product owner",
        reason: "Prepare P03"
      )
      secondTicket = try await store.transitionWorkItem(
        id: secondTicket.id,
        to: state,
        actor: "Product owner",
        reason: "Prepare P03"
      )
    }
    _ = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Deliver a partial plan",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(workItemID: firstTicket.id, estimatedTokens: 1),
        SprintDraftItemInput(workItemID: secondTicket.id, estimatedTokens: 1),
      ]
    )

    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reload()
    let loadedPlan = try #require(model.candidateSprintPlan)
    var assignments = SprintPlanningDraftAssignments(
      saved: Dictionary(
        uniqueKeysWithValues: loadedPlan.items.compactMap { item in
          item.implementerProfileID.map { (item.workItemID, $0) }
        }
      )
    )

    assignments.select(firstImplementer.id, for: firstTicket.id)
    #expect(assignments.hasUnsavedChanges)
    #expect(
      try await store.fetchCurrentSprint(productID: product.id)?.items
        .allSatisfy { $0.implementerProfileID == nil } == true
    )
    #expect(
      try await store.fetchWorkItems(productID: product.id)
        .allSatisfy { $0.ownerProfileID == nil }
    )
    assignments.discardChanges()
    #expect(!assignments.hasUnsavedChanges)
    #expect(assignments.selected.isEmpty)

    assignments.select(firstImplementer.id, for: firstTicket.id)
    let saved = await model.saveSprintPlan(
      goal: loadedPlan.sprint.goal,
      items: loadedPlan.items.map { item in
        SprintDraftItemInput(
          workItemID: item.workItemID,
          implementerProfileID: assignments.selected[item.workItemID],
          estimatedTokens: item.estimatedTokens
        )
      }
    )
    #expect(saved)
    assignments.markSaved()

    let partialPlan = try #require(
      try await store.fetchCurrentSprint(productID: product.id)
    )
    #expect(partialPlan.items.count == 2)
    #expect(
      partialPlan.items.first { $0.workItemID == firstTicket.id }?.implementerProfileID
        == firstImplementer.id
    )
    #expect(
      partialPlan.items.first { $0.workItemID == secondTicket.id }?.implementerProfileID == nil
    )

    assignments.select(secondImplementer.id, for: secondTicket.id)
    #expect(assignments.hasUnsavedChanges)
    #expect(
      try await store.fetchCurrentSprint(productID: product.id)?.items
        .first { $0.workItemID == secondTicket.id }?.implementerProfileID == nil
    )
    assignments.discardChanges()
    #expect(assignments.selected[firstTicket.id] == firstImplementer.id)
    #expect(assignments.selected[secondTicket.id] == nil)

    await store.close()
    let reopened = try SQLiteStore(url: databaseURL)
    let durablePlan = try #require(
      try await reopened.fetchCurrentSprint(productID: product.id)
    )
    #expect(
      durablePlan.items.first { $0.workItemID == firstTicket.id }?.implementerProfileID
        == firstImplementer.id
    )
    #expect(
      durablePlan.items.first { $0.workItemID == secondTicket.id }?.implementerProfileID == nil
    )
    await reopened.close()
  }
}
