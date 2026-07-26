import Foundation
import StoryPointlessCore
import Testing
@testable import StoryPointlessApp

@Suite("Epic planning presentation")
struct EpicPlanningPresentationTests {
  @Test("Open and completed epics are separated while archived epics stay hidden")
  func epicsAreSeparatedByStatus() {
    let productID = UUID()
    let openEpic = Epic(
      productID: productID,
      title: "Open",
      goal: "Deliver an open outcome",
      status: .active
    )
    let completedEpic = Epic(
      productID: productID,
      title: "Complete",
      goal: "Deliver a completed outcome",
      status: .complete
    )
    let archivedEpic = Epic(
      productID: productID,
      title: "Archived",
      goal: "Preserve an archived outcome",
      status: .archived
    )

    let sections = EpicPlanningSections(
      epics: [completedEpic, archivedEpic, openEpic],
      workItems: []
    )

    #expect(sections.allEpics.map(\.id) == [completedEpic.id, openEpic.id])
    #expect(sections.openEpics.map(\.id) == [openEpic.id])
    #expect(sections.completedEpics.map(\.id) == [completedEpic.id])
  }

  @Test("Completed summary counts only delivered tickets from completed epics")
  func completedSummaryCountsDeliveredTickets() {
    let productID = UUID()
    let openEpic = Epic(
      productID: productID,
      title: "Open",
      goal: "Deliver an open outcome",
      status: .active
    )
    let completedEpic = Epic(
      productID: productID,
      title: "Complete",
      goal: "Deliver a completed outcome",
      status: .complete
    )
    let tickets = [
      WorkItem(
        productID: productID,
        key: "T1",
        title: "Delivered",
        state: .released,
        epicID: completedEpic.id
      ),
      WorkItem(
        productID: productID,
        key: "T2",
        title: "Archived",
        state: .cancelled,
        epicID: completedEpic.id
      ),
      WorkItem(
        productID: productID,
        key: "T3",
        title: "Delivered elsewhere",
        state: .released,
        epicID: openEpic.id
      ),
    ]

    let sections = EpicPlanningSections(
      epics: [openEpic, completedEpic],
      workItems: tickets
    )

    #expect(sections.deliveredTicketCount == 1)
  }

  @Test("Completed disclosure defaults to collapsed and persists per product")
  func completedDisclosurePersistsPerProduct() throws {
    let suiteName = "EpicPlanningPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let firstProductID = UUID()
    let secondProductID = UUID()

    #expect(
      !EpicPlanningDisclosureDefaults.isExpanded(
        for: firstProductID,
        defaults: defaults
      )
    )

    EpicPlanningDisclosureDefaults.setExpanded(
      true,
      for: firstProductID,
      defaults: defaults
    )

    #expect(
      EpicPlanningDisclosureDefaults.isExpanded(
        for: firstProductID,
        defaults: defaults
      )
    )
    #expect(
      !EpicPlanningDisclosureDefaults.isExpanded(
        for: secondProductID,
        defaults: defaults
      )
    )
  }
}
