import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Retrospective sprint selection")
struct RetrospectiveSprintSelectionTests {
  @Test("The latest completed sprint is preferred over an active sprint")
  func latestCompletedSprintIsPreferred() {
    let productID = UUID()
    let earlierCompleted = plan(productID: productID, number: 1, state: .completed)
    let latestCompleted = plan(
      productID: productID,
      number: 2,
      state: .completed,
      retrospectiveConcludedAt: Date()
    )
    let active = plan(productID: productID, number: 3, state: .active)

    #expect(
      RetrospectiveSprintSelection.preferredSprintID(
        in: [active, earlierCompleted, latestCompleted]
      ) == latestCompleted.sprint.id
    )
  }

  @Test("An active sprint is used only when no completed sprint exists")
  func activeSprintIsFallback() {
    let productID = UUID()
    let draft = plan(productID: productID, number: 2, state: .draft)
    let active = plan(productID: productID, number: 1, state: .active)

    #expect(
      RetrospectiveSprintSelection.preferredSprintID(in: [draft, active])
        == active.sprint.id
    )
  }

  @Test("A paused sprint remains available when no completed sprint exists")
  func pausedSprintIsFallback() {
    let productID = UUID()
    let draft = plan(productID: productID, number: 2, state: .draft)
    let paused = plan(productID: productID, number: 1, state: .paused)

    #expect(
      RetrospectiveSprintSelection.preferredSprintID(in: [draft, paused])
        == paused.sprint.id
    )
  }

  @Test("Retrospective phases follow the sprint lifecycle")
  func retrospectivePhasesFollowSprintLifecycle() {
    let productID = UUID()
    let active = plan(productID: productID, number: 1, state: .active)
    let paused = plan(productID: productID, number: 1, state: .paused)
    let completed = plan(productID: productID, number: 1, state: .completed)
    let concluded = plan(
      productID: productID,
      number: 1,
      state: .completed,
      retrospectiveConcludedAt: Date()
    )

    #expect(RetrospectivePhase(sprint: active.sprint) == .collecting)
    #expect(RetrospectivePhase(sprint: paused.sprint) == .collecting)
    #expect(RetrospectivePhase(sprint: completed.sprint) == .reviewing)
    #expect(RetrospectivePhase(sprint: concluded.sprint) == .concluded)
  }

  @Test("Retrospective picker labels distinguish unfinished and concluded reviews")
  func retrospectivePickerLabelsDistinguishConclusionState() {
    let productID = UUID()
    let active = plan(productID: productID, number: 3, state: .active)
    let unfinished = plan(productID: productID, number: 2, state: .completed)
    let concluded = plan(
      productID: productID,
      number: 1,
      state: .completed,
      retrospectiveConcludedAt: Date()
    )

    let activePhase = RetrospectivePhase(sprint: active.sprint)
    let unfinishedPhase = RetrospectivePhase(sprint: unfinished.sprint)
    let concludedPhase = RetrospectivePhase(sprint: concluded.sprint)

    #expect(activePhase.pickerTitle == "In progress")
    #expect(unfinishedPhase.pickerTitle == "Needs conclusion")
    #expect(concludedPhase.pickerTitle == "Concluded")
  }

  @Test("Synthesized actions credit each source observation owner once")
  func synthesizedActionAttributionUsesSourceOwners() {
    let productID = UUID()
    let sprintID = UUID()
    let implementerID = UUID()
    let designerID = UUID()
    let sources = [
      note(
        productID: productID,
        sprintID: sprintID,
        profileID: implementerID,
        authorName: "Implementer"
      ),
      note(
        productID: productID,
        sprintID: sprintID,
        profileID: implementerID,
        authorName: "Implementer"
      ),
      note(
        productID: productID,
        sprintID: sprintID,
        profileID: designerID,
        authorName: "UX designer"
      ),
    ]

    let attribution = RetrospectiveActionAttribution.resolve(
      sourceNotes: sources,
      fallbackAuthorName: "Business analyst",
      fallbackProfileID: UUID()
    )

    #expect(attribution.summary == "Implementer, UX designer")
    #expect(attribution.profileIDs == Set([implementerID, designerID]))
  }

  @Test("Actions without source observations retain their original author")
  func actionAttributionFallsBackToOriginalAuthor() {
    let analystID = UUID()
    let attribution = RetrospectiveActionAttribution.resolve(
      sourceNotes: [],
      fallbackAuthorName: "Business analyst",
      fallbackProfileID: analystID
    )

    #expect(attribution.summary == "Business analyst")
    #expect(attribution.profileIDs == Set([analystID]))
  }

  private func plan(
    productID: UUID,
    number: Int,
    state: SprintState,
    retrospectiveConcludedAt: Date? = nil
  ) -> SprintPlan {
    SprintPlan(
      sprint: Sprint(
        productID: productID,
        number: number,
        goal: "Deliver sprint \(number)",
        state: state,
        retrospectiveConcludedAt: retrospectiveConcludedAt
      ),
      items: []
    )
  }

  private func note(
    productID: UUID,
    sprintID: UUID,
    profileID: UUID,
    authorName: String
  ) -> RetrospectiveNote {
    RetrospectiveNote(
      productID: productID,
      sprintID: sprintID,
      profileID: profileID,
      authorName: authorName,
      category: .couldImprove,
      body: "Source observation"
    )
  }
}
