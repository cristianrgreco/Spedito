import Foundation
import Testing

@testable import SpeditoCore

@Suite("Accepted workspace knowledge export policy")
struct AcceptedWorkspaceKnowledgeExportPolicyTests {
  @Test("Unsourced verified knowledge remains exportable")
  func unsourcedVerifiedKnowledgeExports() {
    let page = KnowledgePage(
      productID: UUID(),
      title: "Product overview",
      slug: "overview"
    )

    #expect(
      AcceptedWorkspaceKnowledgeExportPolicy.shouldExport(
        page,
        acceptedSourceWorkItemIDs: []
      )
    )
  }

  @Test("Ticket knowledge exports only after its source candidate is accepted")
  func ticketKnowledgeWaitsForAcceptance() {
    let workItemID = UUID()
    let page = KnowledgePage(
      productID: UUID(),
      title: "Delivery outcome",
      slug: "delivery-outcome",
      sourceWorkItemID: workItemID
    )

    #expect(
      !AcceptedWorkspaceKnowledgeExportPolicy.shouldExport(
        page,
        acceptedSourceWorkItemIDs: []
      )
    )
    #expect(
      AcceptedWorkspaceKnowledgeExportPolicy.shouldExport(
        page,
        acceptedSourceWorkItemIDs: [workItemID]
      )
    )
  }

  @Test("Unverified knowledge never exports")
  func unverifiedKnowledgeDoesNotExport() {
    let workItemID = UUID()
    let page = KnowledgePage(
      productID: UUID(),
      title: "Proposed outcome",
      slug: "proposed-outcome",
      verificationStatus: .proposed,
      sourceWorkItemID: workItemID
    )

    #expect(
      !AcceptedWorkspaceKnowledgeExportPolicy.shouldExport(
        page,
        acceptedSourceWorkItemIDs: [workItemID]
      )
    )
  }
}
