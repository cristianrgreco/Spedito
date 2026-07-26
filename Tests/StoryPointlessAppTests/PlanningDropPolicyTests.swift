import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

@Suite("Planning drop policy")
struct PlanningDropPolicyTests {
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
    #expect(evaluation.message == "Move T1 too; T2 depends on it.")
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
    #expect(evaluation.message == "Move T2 too; it depends on T1.")
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
    #expect(abovePrerequisite.message == "Place T2 below T1.")
    #expect(beforeDownstream.isValid)
    #expect(beforeDownstream.rankAction == .preserve)
    #expect(!belowDownstream.isValid)
    #expect(belowDownstream.blockingConstraint == .rank)
    #expect(belowDownstream.message == "Place T2 above T3.")
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
      "StoryPointlessPlanningDrop-\(UUID().uuidString)",
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
      name: "Dependency planning",
      vision: "Plan prerequisites without moving their rank"
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

    for _ in 0..<100 {
      if model.candidateSprintPlan?.items.map(\.workItemID) == [prerequisite.id] {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(model.candidateSprintPlan?.items.map(\.workItemID) == [prerequisite.id])
    #expect(
      try await store.fetchWorkItems(productID: product.id).map(\.id)
        == [prerequisite.id, dependant.id]
    )
    await store.close()
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
      self.dependencies = [
        WorkItemDependency(
          workItemID: dependant.id,
          dependsOnWorkItemID: prerequisite.id
        )
      ] + (
        downstream.map {
          [
            WorkItemDependency(
              workItemID: $0.id,
              dependsOnWorkItemID: dependant.id
            )
          ]
        } ?? []
      )
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
