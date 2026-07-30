import Foundation

public enum KnowledgePageProposalMaterializationError: Error, LocalizedError {
  case invalidTarget(String)
  case staleTarget(String)

  public var errorDescription: String? {
    switch self {
    case .invalidTarget(let message), .staleTarget(let message):
      message
    }
  }
}

public enum KnowledgePageProposalMaterializer {
  public static func applying(
    _ proposals: [KnowledgePageProposal],
    to canonicalPages: [KnowledgePage]
  ) throws -> [KnowledgePage] {
    var pages = canonicalPages

    for proposal in proposals {
      switch proposal.operation {
      case .update:
        guard
          let targetPageID = proposal.targetPageID,
          let targetIndex = pages.firstIndex(where: { $0.id == targetPageID }),
          pages[targetIndex].productID == proposal.productID
        else {
          throw KnowledgePageProposalMaterializationError.invalidTarget(
            "A Product knowledge update targets a page outside this product."
          )
        }
        let target = pages[targetIndex]
        guard
          let baseTitle = proposal.basePageTitle,
          let baseBody = proposal.basePageBodyMarkdown,
          let baseUpdatedAt = proposal.basePageUpdatedAt,
          target.title == baseTitle,
          target.bodyMarkdown == baseBody,
          abs(target.updatedAt.timeIntervalSince(baseUpdatedAt)) < 0.001
        else {
          throw KnowledgePageProposalMaterializationError.staleTarget(
            "The canonical page changed after this proposal was prepared. Review a fresh proposal instead of overwriting the newer page."
          )
        }
        pages[targetIndex].title = proposal.title
        pages[targetIndex].bodyMarkdown = KnowledgeMarkdown.normalizedBody(
          proposal.proposedBodyMarkdown
        )
        pages[targetIndex].verificationStatus = .verified
        pages[targetIndex].sourceWorkItemID = proposal.workItemID
        pages[targetIndex].updatedAt = proposal.updatedAt

      case .create:
        guard
          let parentPageID = proposal.parentPageID,
          pages.contains(where: {
            $0.id == parentPageID && $0.productID == proposal.productID
          })
        else {
          throw KnowledgePageProposalMaterializationError.invalidTarget(
            "A Product knowledge creation targets a section outside this product."
          )
        }
        let siblingPages = pages.filter { $0.parentID == parentPageID }
        let baseSlug = slug(for: proposal.title)
        var slug = baseSlug
        var suffix = 2
        while siblingPages.contains(where: { $0.slug == slug }) {
          slug = "\(baseSlug)-\(suffix)"
          suffix += 1
        }
        pages.append(
          KnowledgePage(
            id: proposal.id,
            productID: proposal.productID,
            parentID: parentPageID,
            title: proposal.title,
            slug: slug,
            bodyMarkdown: KnowledgeMarkdown.normalizedBody(
              proposal.proposedBodyMarkdown
            ),
            verificationStatus: .verified,
            sortOrder: (siblingPages.map(\.sortOrder).max() ?? -1) + 1,
            sourceWorkItemID: proposal.workItemID,
            createdAt: proposal.createdAt,
            updatedAt: proposal.updatedAt
          )
        )
      }
    }

    return pages
  }

  static func slug(for title: String) -> String {
    let slug = title
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .joined(separator: "-")
    return slug.isEmpty ? "page" : slug
  }
}
