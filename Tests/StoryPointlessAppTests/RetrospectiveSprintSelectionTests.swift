import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

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

  @Test("Retrospective phases follow the sprint lifecycle")
  func retrospectivePhasesFollowSprintLifecycle() {
    let productID = UUID()
    let active = plan(productID: productID, number: 1, state: .active)
    let completed = plan(productID: productID, number: 1, state: .completed)
    let concluded = plan(
      productID: productID,
      number: 1,
      state: .completed,
      retrospectiveConcludedAt: Date()
    )

    #expect(RetrospectivePhase(sprint: active.sprint) == .collecting)
    #expect(RetrospectivePhase(sprint: completed.sprint) == .reviewing)
    #expect(RetrospectivePhase(sprint: concluded.sprint) == .concluded)
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
        authorName: "UX Designer"
      )
    ]

    let attribution = RetrospectiveActionAttribution.resolve(
      sourceNotes: sources,
      fallbackAuthorName: "Business Analyst",
      fallbackProfileID: UUID()
    )

    #expect(attribution.summary == "Implementer, UX Designer")
    #expect(attribution.profileIDs == Set([implementerID, designerID]))
  }

  @Test("Actions without source observations retain their original author")
  func actionAttributionFallsBackToOriginalAuthor() {
    let analystID = UUID()
    let attribution = RetrospectiveActionAttribution.resolve(
      sourceNotes: [],
      fallbackAuthorName: "Business Analyst",
      fallbackProfileID: analystID
    )

    #expect(attribution.summary == "Business Analyst")
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
        goal: "Deliver Sprint \(number)",
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
