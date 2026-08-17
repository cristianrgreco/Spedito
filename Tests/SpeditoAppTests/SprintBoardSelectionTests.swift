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

  /// Existing evidence:
  /// - `PlanningDropPolicyTests.bulkActionsMoveExactRequestedScope`
  /// - `SQLiteStoreTests.candidateSprintDefinesPlanningScope`
  /// This test adds only P01's open-and-relaunch composition for the complete
  /// Next sprint scope.
  @Test("P01 Sprint planning opens and recovers its complete Next sprint scope")
  @MainActor
  func p01PlanningScopeMatchesNextSprintAcrossRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-sprint-planning-p01-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Complete sprint scope")
    let first = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver the first outcome"
    )
    let second = try await readyItem(
      in: store,
      productID: product.id,
      title: "Deliver the second outcome"
    )
    let backlogOnly = try await store.createWorkItem(
      productID: product.id,
      title: "Keep this outcome in the backlog"
    )
    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reload()

    model.addToCandidateSprint([first, second])
    await model.settleOwnerCommands()

    let plan = try #require(model.candidateSprintPlan)
    #expect(Set(plan.items.map(\.workItemID)) == [first.id, second.id])
    #expect(
      SprintPlanningScope.items(in: plan, from: model.workItems).map(\.id)
        == [first.id, second.id]
    )
    #expect(!plan.items.map(\.workItemID).contains(backlogOnly.id))

    await model.shutdown()
    await store.close()
    let reopened = try SQLiteStore(url: databaseURL)
    let recoveredModel = AppModel(store: reopened, selectedProductID: product.id)
    await recoveredModel.reload()
    let recoveredPlan = try #require(recoveredModel.candidateSprintPlan)
    #expect(
      SprintPlanningScope.items(in: recoveredPlan, from: recoveredModel.workItems).map(\.id)
        == [first.id, second.id]
    )
    await recoveredModel.shutdown()
    await reopened.close()
  }

  /// Existing evidence:
  /// - `SprintForecastTests` validates the per-Ticket estimate boundaries.
  /// - `SQLiteStoreTests.sprintPlanningHasNoConcurrencySetting` protects elastic execution.
  /// This P04 presentation proof adds dependency waves, aggregate forecast,
  /// owner acceptance load, and the most constrained Codex usage window.
  @Test("P04 planning summary exposes order forecast usage and owner review load")
  func p04PlanningSummaryPresentsAllDecisionSignals() {
    let productID = UUID()
    let prerequisite = WorkItem(
      productID: productID,
      key: "T1",
      title: "Prepare the owner-visible foundation",
      acceptanceCriteria: ["The foundation is reviewable"],
      state: .ready,
      rank: 1
    )
    let dependant = WorkItem(
      productID: productID,
      key: "T2",
      title: "Deliver the dependant owner outcome",
      acceptanceCriteria: ["The complete outcome is demonstrable"],
      state: .ready,
      rank: 2
    )
    let groups = SprintPlanningWavePolicy.groups(
      items: [prerequisite, dependant],
      dependencies: [
        WorkItemDependency(
          workItemID: dependant.id,
          dependsOnWorkItemID: prerequisite.id
        )
      ]
    )
    #expect(groups.map { $0.map(\.id) } == [[prerequisite.id], [dependant.id]])

    let waves = groups.enumerated().map { index, items in
      items.map { item in
        SprintPlanningLine(
          item: item,
          owner: nil,
          forecast: SprintForecast.estimate(for: item),
          wave: index + 1,
          risks: item.id == dependant.id ? ["Owner decision required"] : []
        )
      }
    }
    let summary = SprintPlanningSummaryPresentation(
      waves: waves,
      rateLimits: CodexRateLimitsSnapshot(
        windows: [
          CodexRateLimitWindow(
            id: "short",
            usedPercent: 20,
            windowDurationMinutes: 300,
            resetsAt: nil
          ),
          CodexRateLimitWindow(
            id: "long",
            usedPercent: 74.5,
            windowDurationMinutes: 10_080,
            resetsAt: nil
          ),
        ],
        reachedLimitType: nil
      )
    )
    let forecasts = [prerequisite, dependant].map(SprintForecast.estimate(for:))
    #expect(summary.scopeCount == 2)
    #expect(summary.waveCount == 2)
    #expect(summary.tokenLow == forecasts.reduce(0) { $0 + $1.tokenLow })
    #expect(summary.tokenHigh == forecasts.reduce(0) { $0 + $1.tokenHigh })
    #expect(summary.ownerReviewCount == 2)
    #expect(summary.riskCount == 1)
    #expect(summary.remainingUsagePercent == 25)
  }

  /// Existing evidence:
  /// - `p03PartialPlanAndDiscardedPickerState` proves the save/discard boundary.
  /// - `newlyPlannedSprintBecomesSelected` proves Product-scoped selection writes.
  /// P07 adds a fresh store and model plus valid/fallback board-context recovery.
  @Test("P07 relaunch restores the saved draft and valid board context only")
  @MainActor
  func p07SavedDraftAndBoardContextRecoverWithoutUnsavedChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-sprint-planning-p07-\(UUID())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Recovered sprint draft")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let implementers = profiles.filter(\.role.canOwnDelivery)
    let savedImplementer = try #require(implementers.first)
    let unsavedImplementer = try #require(implementers.dropFirst().first)
    let item = try await readyItem(
      in: store,
      productID: product.id,
      title: "Recover the selected sprint"
    )
    let draft = try await store.saveDraftSprint(
      productID: product.id,
      goal: "Restore only durable planning",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: item.id,
          implementerProfileID: savedImplementer.id,
          estimatedTokens: 1
        )
      ]
    )
    SprintBoardSelectionDefaults.select(draft.sprint.id, for: product.id)
    defer { SprintBoardSelectionDefaults.select(nil, for: product.id) }

    var assignments = SprintPlanningDraftAssignments(
      saved: [item.id: savedImplementer.id]
    )
    assignments.select(unsavedImplementer.id, for: item.id)
    #expect(assignments.hasUnsavedChanges)

    await store.close()
    let reopened = try SQLiteStore(url: databaseURL)
    let recoveredModel = AppModel(store: reopened, selectedProductID: product.id)
    await recoveredModel.reload()
    let recoveredPlan = try #require(recoveredModel.candidateSprintPlan)
    let recoveredAssignments = SprintPlanningDraftAssignments(
      saved: Dictionary(
        uniqueKeysWithValues: recoveredPlan.items.compactMap { sprintItem in
          sprintItem.implementerProfileID.map { (sprintItem.workItemID, $0) }
        }
      )
    )
    #expect(!recoveredAssignments.hasUnsavedChanges)
    #expect(recoveredAssignments.selected[item.id] == savedImplementer.id)
    #expect(
      SprintBoardSelectionPolicy.resolvedSelection(
        availablePlans: [recoveredPlan],
        currentID: nil,
        restoredID: SprintBoardSelectionDefaults.selectedSprintID(for: product.id),
        isLoading: false
      ) == draft.sprint.id
    )
    #expect(
      SprintBoardSelectionPolicy.resolvedSelection(
        availablePlans: [recoveredPlan],
        currentID: nil,
        restoredID: UUID(),
        isLoading: false
      ) == draft.sprint.id
    )
    await recoveredModel.shutdown()
    await reopened.close()
  }

  private func readyItem(
    in store: SQLiteStore,
    productID: UUID,
    title: String
  ) async throws -> WorkItem {
    var item = try await store.createWorkItem(
      productID: productID,
      title: title,
      acceptanceCriteria: ["The outcome is visible"]
    )
    for state: WorkItemState in [.refining, .ready] {
      item = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: "Product owner",
        reason: "Prepare sprint planning journey"
      )
    }
    return item
  }
}
