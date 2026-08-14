import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Product execution lifecycle")
struct ProductExecutionLifecycleTests {
  @Test("Switching products leaves every delivery scheduler running")
  func productSelectionDoesNotSuspendDelivery() {
    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .productSelectionChanged
      ) == .none
    )
  }

  @Test("Archiving stops only the archived product")
  func productArchivalHasProductScope() {
    let productID = UUID()

    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .productArchived(productID)
      ) == .product(productID)
    )
  }

  @Test("App shutdown stops delivery across products")
  func appShutdownHasGlobalScope() {
    #expect(
      ProductExecutionLifecyclePolicy.suspensionScope(
        for: .appShutdown
      ) == .all
    )
  }


  @Test("Business analyst can deliver a reviewed outcome without repository changes")
  func businessAnalystLocalOutcomePolicy() throws {
    #expect(
      try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: .businessAnalyst,
        changedPaths: []
      ) == .localOutcome
    )
    #expect(
      try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: .businessAnalyst,
        changedPaths: ["docs/recommendation.md"]
      ) == .repositoryChange
    )
  }

  @Test("Product-changing roles still require repository evidence")
  func productChangingRoleEvidencePolicy() {
    #expect(throws: TicketDeliveryEvidencePolicyError.self) {
      try TicketDeliveryEvidencePolicy.deliveryKind(
        assigneeRole: .implementer,
        changedPaths: []
      )
    }
  }
  @Test("Ticket approval starts background completion without holding the detail view")
  @MainActor
  func ticketApprovalStartsInBackground() async {
    let model = AppModel(store: nil)
    let item = WorkItem(
      productID: UUID(),
      key: "T1",
      title: "Complete in the background",
      state: .acceptance
    )

    #expect(model.beginSprintTicketAcceptance(item))
    #expect(model.ticketAcceptanceInProgressWorkItemIDs == Set([item.id]))

    await Task.yield()

    #expect(model.ticketAcceptanceInProgressWorkItemIDs.isEmpty)
  }
}
