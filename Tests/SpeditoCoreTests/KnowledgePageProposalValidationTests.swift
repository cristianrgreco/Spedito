import Foundation
import Testing

@testable import SpeditoCore

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
      canonicalPages: [operations, environments],
      writablePageIDs: [environments.id]
    )

    let breadcrumbResult = result(
      proposalTitle: "Operations > Environments",
      targetPageID: environments.id
    )
    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.validateKnowledgePageProposals(
        in: breadcrumbResult,
        canonicalPages: [operations, environments],
        writablePageIDs: [environments.id]
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
        canonicalPages: [],
        writablePageIDs: []
      )
    }
  }

  @Test("Canonical page creation requires a writable section parent")
  func creationRequiresWritableSectionParent() throws {
    let productID = UUID()
    let integrations = KnowledgePage(
      productID: productID,
      title: "Integrations",
      slug: "integrations"
    )
    let invalidKindResult = creationResult(parentPageID: integrations.id)

    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.validateKnowledgePageProposals(
        in: invalidKindResult,
        canonicalPages: [integrations],
        writablePageIDs: [integrations.id]
      )
    }

    let features = KnowledgePage(
      productID: productID,
      title: "Features",
      slug: "features",
      kind: .section
    )
    let validResult = creationResult(parentPageID: features.id)
    try CodexTicketExecutor.validateKnowledgePageProposals(
      in: validResult,
      canonicalPages: [features],
      writablePageIDs: [features.id]
    )
    #expect(throws: TicketExecutionGenerationError.self) {
      try CodexTicketExecutor.validateKnowledgePageProposals(
        in: validResult,
        canonicalPages: [features],
        writablePageIDs: []
      )
    }
  }

  private func creationResult(parentPageID: UUID) -> TicketExecutionResult {
    TicketExecutionResult(
      status: .completed,
      comment: "Recorded an integration decision.",
      question: nil,
      options: [],
      summary: "Recorded an integration decision.",
      changedFiles: [],
      tests: ["Provider comparison completed."],
      knowledgeNotes: [],
      reviewInstructions: ["Review the provider decision."],
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: [],
      knowledgePageProposals: [
        KnowledgePageProposalDraft(
          operation: .create,
          parentPageID: parentPageID,
          title: "Provider decision",
          proposedBodyMarkdown: "The selected provider meets the ticket contract.",
          rationale: "Dependants need the approved provider contract."
        )
      ]
    )
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
