import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

@Suite("Sprint start availability")
struct SprintStartAvailabilityTests {
  @Test("An active sprint blocks starting the next draft")
  func activeSprintBlocksDraftStart() {
    let productID = UUID()
    let active = plan(productID: productID, number: 1, state: .active)
    let draft = plan(productID: productID, number: 2, state: .draft)

    let availability = SprintStartAvailability(
      draft: draft,
      plans: [draft, active]
    )

    #expect(availability.isBlocked)
    #expect(availability.blockingActiveSprintNumber == 1)
    #expect(
      availability.explanation
        == "Finish Sprint 1 before starting this sprint."
    )
  }

  @Test("Completed sprints do not block starting a draft")
  func completedSprintDoesNotBlockDraftStart() {
    let productID = UUID()
    let completed = plan(productID: productID, number: 1, state: .completed)
    let draft = plan(productID: productID, number: 2, state: .draft)

    let availability = SprintStartAvailability(
      draft: draft,
      plans: [draft, completed]
    )

    #expect(!availability.isBlocked)
    #expect(availability.blockingActiveSprintNumber == nil)
    #expect(availability.explanation == nil)
  }

  private func plan(
    productID: UUID,
    number: Int,
    state: SprintState
  ) -> SprintPlan {
    SprintPlan(
      sprint: Sprint(
        productID: productID,
        number: number,
        goal: "Deliver Sprint \(number)",
        state: state
      ),
      items: []
    )
  }
}
