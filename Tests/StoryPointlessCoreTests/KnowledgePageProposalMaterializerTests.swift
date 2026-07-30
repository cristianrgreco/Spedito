import Foundation
import Testing

@testable import StoryPointlessCore

@Suite("Knowledge page proposal materializer")
struct KnowledgePageProposalMaterializerTests {
  @Test("Reviewed changes materialize without changing canonical pages")
  func materializesCandidatePages() throws {
    let productID = UUID()
    let workItemID = UUID()
    let sprintID = UUID()
    let candidateID = UUID()
    let baseDate = Date(timeIntervalSince1970: 1_000)
    let section = KnowledgePage(
      productID: productID,
      title: "Technical",
      slug: "technical",
      kind: .section,
      updatedAt: baseDate
    )
    let overview = KnowledgePage(
      productID: productID,
      parentID: section.id,
      title: "Overview",
      slug: "overview",
      bodyMarkdown: "Original truth.",
      updatedAt: baseDate
    )
    let existingContract = KnowledgePage(
      productID: productID,
      parentID: section.id,
      title: "API contract",
      slug: "api-contract",
      bodyMarkdown: "Existing contract.",
      sortOrder: 1,
      updatedAt: baseDate
    )
    let update = KnowledgePageProposal(
      productID: productID,
      sprintID: sprintID,
      workItemID: workItemID,
      candidateRevisionID: candidateID,
      operation: .update,
      targetPageID: overview.id,
      basePageTitle: overview.title,
      basePageBodyMarkdown: overview.bodyMarkdown,
      basePageUpdatedAt: overview.updatedAt,
      title: overview.title,
      proposedBodyMarkdown: "# Overview\n\nCandidate truth.",
      rationale: "The candidate changes the contract.",
      status: .reviewed,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(1)
    )
    let creation = KnowledgePageProposal(
      productID: productID,
      sprintID: sprintID,
      workItemID: workItemID,
      candidateRevisionID: candidateID,
      operation: .create,
      parentPageID: section.id,
      title: "API contract",
      proposedBodyMarkdown: "# API contract\n\nCandidate contract.",
      rationale: "Downstream work needs this contract.",
      status: .reviewed,
      createdAt: baseDate,
      updatedAt: baseDate.addingTimeInterval(1)
    )
    let canonicalPages = [section, overview, existingContract]

    let candidatePages = try KnowledgePageProposalMaterializer.applying(
      [update, creation],
      to: canonicalPages
    )

    #expect(canonicalPages.first { $0.id == overview.id }?.bodyMarkdown == "Original truth.")
    let candidateOverview = try #require(
      candidatePages.first { $0.id == overview.id }
    )
    #expect(candidateOverview.bodyMarkdown == "Candidate truth.")
    #expect(candidateOverview.sourceWorkItemID == workItemID)
    let createdPage = try #require(
      candidatePages.first { $0.id == creation.id }
    )
    #expect(createdPage.slug == "api-contract-2")
    #expect(createdPage.bodyMarkdown == "Candidate contract.")
    #expect(createdPage.sourceWorkItemID == workItemID)
  }

  @Test("A stale canonical target cannot be materialized")
  func rejectsStaleTarget() {
    let productID = UUID()
    let page = KnowledgePage(
      productID: productID,
      title: "Overview",
      slug: "overview",
      bodyMarkdown: "Current truth."
    )
    let proposal = KnowledgePageProposal(
      productID: productID,
      sprintID: UUID(),
      workItemID: UUID(),
      candidateRevisionID: UUID(),
      operation: .update,
      targetPageID: page.id,
      basePageTitle: page.title,
      basePageBodyMarkdown: "Older truth.",
      basePageUpdatedAt: page.updatedAt,
      title: page.title,
      proposedBodyMarkdown: "Candidate truth.",
      rationale: "This proposal is stale.",
      status: .reviewed
    )

    #expect(throws: KnowledgePageProposalMaterializationError.self) {
      _ = try KnowledgePageProposalMaterializer.applying(
        [proposal],
        to: [page]
      )
    }
  }
}
