import Foundation
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
}
