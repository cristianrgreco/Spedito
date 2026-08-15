import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Planning drop policy")
struct PlanningDropPolicyTests {
  @Test("Bulk move targets selected section tickets, or every ticket without a selection")
  func bulkMoveTargetsSelectionOrWholeSection() {
    let productID = UUID()
    let first = WorkItem(
      productID: productID,
      key: "T1",
      title: "First"
    )
    let second = WorkItem(
      productID: productID,
      key: "T2",
      title: "Second"
    )
    let unrelatedSelection = UUID()

    let allToSprint = PlanningBulkMoveAction(
      items: [first, second],
      selectedWorkItemIDs: [unrelatedSelection],
      destination: .candidateSprint
    )
    let selectedToBacklog = PlanningBulkMoveAction(
      items: [first, second],
      selectedWorkItemIDs: [second.id, unrelatedSelection],
      destination: .backlog
    )
    let selectedToSprint = PlanningBulkMoveAction(
      items: [first, second],
      selectedWorkItemIDs: [first.id, second.id],
      destination: .candidateSprint
    )

    #expect(allToSprint.targetItems.map(\.id) == [first.id, second.id])
    #expect(allToSprint.title == "Move all to next sprint")
    #expect(selectedToBacklog.targetItems.map(\.id) == [second.id])
    #expect(selectedToBacklog.title == "Move 1 to backlog")
    #expect(selectedToSprint.title == "Move 2 to next sprint")
  }

  @Test("Moving a prerequisite into an empty sprint preserves backlog rank")
  func prerequisiteCanEnterEmptySprint() {
    let fixture = Fixture()

    let evaluation = fixture.evaluate(
      moving: [fixture.prerequisite.id],
      intoCandidateSprint: true
    )

    #expect(evaluation.isValid)
    #expect(evaluation.rankAction == .preserve)
  }

  @Test("Moving a dependant without its unfinished prerequisite is blocked")
  func dependantNeedsPrerequisiteInSprint() {
    let fixture = Fixture()

    let evaluation = fixture.evaluate(
      moving: [fixture.dependant.id],
      intoCandidateSprint: true
    )

    #expect(!evaluation.isValid)
    #expect(evaluation.blockingConstraint == .sprintScope)
    #expect(evaluation.message == "Move T1 too; T2 depends on it")
  }

  @Test("A prerequisite cannot leave a sprint while its dependant remains")
  func prerequisiteCannotLeaveDependantInSprint() {
    let fixture = Fixture(candidateIDs: [])

    let evaluation = fixture.evaluate(
      candidateIDs: [fixture.prerequisite.id, fixture.dependant.id],
      moving: [fixture.prerequisite.id],
      intoCandidateSprint: false
    )

    #expect(!evaluation.isValid)
    #expect(evaluation.blockingConstraint == .sprintScope)
    #expect(evaluation.message == "Move T2 too; it depends on T1")
  }

  @Test("A complete dependency branch can enter the sprint atomically")
  func completeBranchCanEnterSprint() {
    let fixture = Fixture()

    let evaluation = fixture.evaluate(
      moving: [fixture.prerequisite.id, fixture.dependant.id],
      intoCandidateSprint: true
    )

    #expect(evaluation.isValid)
    #expect(evaluation.rankAction == .preserve)
  }

  @Test("Placement previews identify the valid dependency range")
  func placementPreviewsIdentifyValidRange() {
    let fixture = Fixture(includesDownstream: true)

    let abovePrerequisite = fixture.evaluate(
      moving: [fixture.dependant.id],
      intoCandidateSprint: false,
      before: fixture.prerequisite.id
    )
    let beforeDownstream = fixture.evaluate(
      moving: [fixture.dependant.id],
      intoCandidateSprint: false,
      before: fixture.downstream?.id
    )
    let belowDownstream = fixture.evaluate(
      moving: [fixture.dependant.id],
      intoCandidateSprint: false
    )

    #expect(!abovePrerequisite.isValid)
    #expect(abovePrerequisite.blockingConstraint == .rank)
    #expect(abovePrerequisite.message == "Place T2 below T1")
    #expect(beforeDownstream.isValid)
    #expect(beforeDownstream.rankAction == .preserve)
    #expect(!belowDownstream.isValid)
    #expect(belowDownstream.blockingConstraint == .rank)
    #expect(belowDownstream.message == "Place T2 above T3")
  }

  @Test("Returning through a no-op target retains the active drag target")
  func noOpTargetRetainsDragState() {
    let invalidTarget = PlanningDropTarget(section: .backlog, index: 3)
    let noOpTarget = PlanningDropTarget(section: .backlog, index: 2)

    var currentTarget: PlanningDropTarget? = invalidTarget
    currentTarget = PlanningDropTargetState.updated(
      current: currentTarget,
      target: noOpTarget,
      isTargeted: true
    )
    currentTarget = PlanningDropTargetState.updated(
      current: currentTarget,
      target: invalidTarget,
      isTargeted: false
    )

    #expect(currentTarget == noOpTarget)
  }

  @Test("Drop previews retain the table's resting geometry")
  func dropPreviewsRetainTableGeometry() {
    #expect(
      PlanningTicketDropSlotLayout.height(showsRestingDivider: false) == 0
    )
    #expect(
      PlanningTicketDropSlotLayout.height(showsRestingDivider: true)
        == PlanningTicketDropSlotLayout.dividerHeight
    )
  }

  @Test("Repeated invalid previews do not relax after visiting the valid position")
  func repeatedInvalidPreviewRemainsInvalid() {
    let fixture = Fixture()

    let invalidBefore = fixture.evaluate(
      moving: [fixture.prerequisite.id],
      intoCandidateSprint: false
    )
    let valid = fixture.evaluate(
      moving: [fixture.prerequisite.id],
      intoCandidateSprint: false,
      before: fixture.dependant.id
    )
    let invalidAfter = fixture.evaluate(
      moving: [fixture.prerequisite.id],
      intoCandidateSprint: false
    )

    #expect(!invalidBefore.isValid)
    #expect(valid.isValid)
    #expect(!invalidAfter.isValid)
    #expect(invalidAfter.message == invalidBefore.message)
  }

  @Test("Completed prerequisites satisfy sprint scope")
  func completedPrerequisiteSatisfiesScope() {
    let productID = UUID()
    let completed = WorkItem(
      productID: productID,
      key: "T1",
      title: "Complete the contract",
      state: .released,
      rank: 1_000
    )
    let dependant = WorkItem(
      productID: productID,
      key: "T2",
      title: "Use the contract",
      rank: 2_000
    )
    let evaluation = PlanningDropPolicy.evaluate(
      workItems: [completed, dependant],
      dependencies: [
        WorkItemDependency(
          workItemID: dependant.id,
          dependsOnWorkItemID: completed.id
        )
      ],
      candidateIDs: [],
      externalCandidatePrerequisiteIDs: [completed.id],
      movingIDs: [dependant.id],
      intoCandidateSprint: true,
      before: nil
    )

    #expect(evaluation.isValid)
    #expect(evaluation.rankAction == .preserve)
  }

  @Test("Dropping a prerequisite into an empty sprint persists scope without reranking")
  @MainActor
  func prerequisiteDropPersistsWithoutReranking() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SpeditoPlanningDrop-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteStore(
      url: directory.appendingPathComponent("planning-drop.sqlite")
    )
    let product = try await store.createProduct(
      name: "Dependency planning"
    )
    let prerequisite = try await store.createWorkItem(
      productID: product.id,
      title: "Define the contract"
    )
    let dependant = try await store.createWorkItem(
      productID: product.id,
      title: "Use the contract",
      dependsOnWorkItemIDs: [prerequisite.id]
    )
    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()

    model.dropPlanningItems(
      [prerequisite],
      intoCandidateSprint: true,
      before: nil
    )

    await model.settleOwnerCommands()

    #expect(model.candidateSprintPlan?.items.map(\.workItemID) == [prerequisite.id])
    #expect(
      try await store.fetchWorkItems(productID: product.id).map(\.id)
        == [prerequisite.id, dependant.id]
    )
    await store.close()
  }

  @Test("Visible bulk actions persist whole-section moves in both directions")
  @MainActor
  func bulkActionsPersistWholeSectionMoves() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SpeditoPlanningBulkMove-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteStore(
      url: directory.appendingPathComponent("planning-bulk-move.sqlite")
    )
    let product = try await store.createProduct(
      name: "Bulk planning"
    )
    let prerequisite = try await store.createWorkItem(
      productID: product.id,
      title: "Define the contract"
    )
    let dependant = try await store.createWorkItem(
      productID: product.id,
      title: "Use the contract",
      dependsOnWorkItemIDs: [prerequisite.id]
    )
    let model = AppModel(store: store, selectedProductID: product.id)
    await model.reloadSelectedProduct()

    let moveAllToSprint = PlanningBulkMoveAction(
      items: model.workItems,
      selectedWorkItemIDs: [],
      destination: .candidateSprint
    )
    model.addToCandidateSprint(moveAllToSprint.targetItems)

    await model.settleOwnerCommands()

    #expect(
      Set(model.candidateSprintPlan?.items.map(\.workItemID) ?? [])
        == [prerequisite.id, dependant.id]
    )

    let moveAllToBacklog = PlanningBulkMoveAction(
      items: model.workItems,
      selectedWorkItemIDs: [],
      destination: .backlog
    )
    model.removeFromCandidateSprint(moveAllToBacklog.targetItems)

    await model.settleOwnerCommands()

    #expect(model.candidateSprintPlan?.items.isEmpty == true)
    await store.close()
  }

  /// Existing partial coverage:
  /// - `completeBranchCanEnterSprint`
  /// - `dependantNeedsPrerequisiteInSprint`
  /// - `bulkActionsPersistWholeSectionMoves`
  /// This test covers only B09's partial-selection composition and exact explanation.
  @Test("B09 partial sprint scope names the missing prerequisite relationship")
  func b09PartialSprintScopeExplainsMissingRelationship() {
    let fixture = Fixture()
    let action = PlanningBulkMoveAction(
      items: fixture.workItems,
      selectedWorkItemIDs: [fixture.dependant.id],
      destination: .candidateSprint
    )

    let evaluation = fixture.evaluate(
      moving: Set(action.targetItems.map(\.id)),
      intoCandidateSprint: true
    )

    #expect(action.targetItems.map(\.id) == [fixture.dependant.id])
    #expect(evaluation.blockingConstraint == .sprintScope)
    #expect(evaluation.message == "Move T1 too; T2 depends on it")
  }

  private struct Fixture {
    let workItems: [WorkItem]
    let dependencies: [WorkItemDependency]
    let candidateIDs: Set<UUID>
    let prerequisite: WorkItem
    let dependant: WorkItem
    let downstream: WorkItem?

    init(
      candidateIDs: Set<UUID> = [],
      includesDownstream: Bool = false
    ) {
      let productID = UUID()
      let prerequisite = WorkItem(
        productID: productID,
        key: "T1",
        title: "Define the contract",
        rank: 1_000
      )
      let dependant = WorkItem(
        productID: productID,
        key: "T2",
        title: "Use the contract",
        rank: 2_000
      )
      let downstream =
        includesDownstream
        ? WorkItem(
          productID: productID,
          key: "T3",
          title: "Verify the outcome",
          rank: 3_000
        )
        : nil
      self.prerequisite = prerequisite
      self.dependant = dependant
      self.downstream = downstream
      self.workItems = [prerequisite, dependant] + (downstream.map { [$0] } ?? [])
      self.dependencies =
        [
          WorkItemDependency(
            workItemID: dependant.id,
            dependsOnWorkItemID: prerequisite.id
          )
        ]
        + (downstream.map {
          [
            WorkItemDependency(
              workItemID: $0.id,
              dependsOnWorkItemID: dependant.id
            )
          ]
        } ?? [])
      self.candidateIDs = candidateIDs
    }

    func evaluate(
      candidateIDs overrideCandidateIDs: Set<UUID>? = nil,
      moving movingIDs: Set<UUID>,
      intoCandidateSprint: Bool,
      before targetID: UUID? = nil
    ) -> PlanningDropEvaluation {
      PlanningDropPolicy.evaluate(
        workItems: workItems,
        dependencies: dependencies,
        candidateIDs: overrideCandidateIDs ?? candidateIDs,
        externalCandidatePrerequisiteIDs: [],
        movingIDs: movingIDs,
        intoCandidateSprint: intoCandidateSprint,
        before: targetID
      )
    }
  }
}
