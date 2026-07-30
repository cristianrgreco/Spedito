import Foundation
import Testing

@testable import StoryPointlessCore

@Suite("Knowledge page proposal validation")
struct KnowledgePageProposalValidationTests {
  @Test("Canonical page updates keep the existing leaf title")
  func updateKeepsExistingLeafTitle() throws {
    let productID = UUID()
    let operations = KnowledgePage(
      productID: productID,
      title: "Operations",
      slug: "operations",
      kind: .section
    )
    let environments = KnowledgePage(
      productID: productID,
      parentID: operations.id,
      title: "Environments",
      slug: "environments"
    )
    let validResult = result(
      proposalTitle: "Environments",
      targetPageID: environments.id
    )

    try CodexTicketExecutor.validateKnowledgePageProposals(
      in: validResult,
      canonicalPages: [operations, environments]
    )

    let breadcrumbResult = result(
      proposalTitle: "Operations > Environments",
      targetPageID: environments.id
    )
    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.validateKnowledgePageProposals(
        in: breadcrumbResult,
        canonicalPages: [operations, environments]
      )
    }
  }

  @Test("Canonical page updates must target an existing page")
  func updateTargetsExistingPage() {
    let result = result(
      proposalTitle: "Environments",
      targetPageID: UUID()
    )

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.validateKnowledgePageProposals(
        in: result,
        canonicalPages: []
      )
    }
  }

  private func result(
    proposalTitle: String,
    targetPageID: UUID
  ) -> TicketExecutionResult {
    TicketExecutionResult(
      status: .completed,
      comment: "Prepared verified environment guidance.",
      question: nil,
      options: [],
      summary: "Prepared verified environment guidance.",
      changedFiles: ["README.md"],
      tests: ["Readiness check passed."],
      knowledgeNotes: [],
      reviewInstructions: ["Review the environment guidance."],
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: [],
      knowledgePageProposals: [
        KnowledgePageProposalDraft(
          operation: .update,
          targetPageID: targetPageID,
          title: proposalTitle,
          proposedBodyMarkdown: "Verified environment guidance.",
          rationale: "The ticket verified the maintained workflow."
        )
      ]
    )
  }
}
