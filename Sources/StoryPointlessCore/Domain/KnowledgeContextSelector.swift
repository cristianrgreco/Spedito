import Foundation

public struct KnowledgeContextSelection: Equatable, Sendable {
  public let referencePages: [KnowledgePage]
  public let directoryPages: [KnowledgePage]
  public let writablePageIDs: Set<UUID>

  public init(
    referencePages: [KnowledgePage],
    directoryPages: [KnowledgePage],
    writablePageIDs: Set<UUID>
  ) {
    self.referencePages = referencePages
    self.directoryPages = directoryPages
    self.writablePageIDs = writablePageIDs
  }
}

public enum KnowledgeContextSelector {
  private static let inheritedSlugs = [
    "overview",
    "product-principles",
    "glossary",
    "ways-of-working",
  ]

  private static let ignoredTerms = Set([
    "about", "after", "against", "also", "been", "before", "being", "between",
    "could", "does", "from", "have", "into", "only", "other", "should", "than",
    "that", "their", "there", "these", "they", "this", "those", "through", "using",
    "when", "where", "which", "while", "with", "would",
  ])

  public static func select(
    pages: [KnowledgePage],
    item: WorkItem,
    prerequisites: [WorkItem],
    referenceLimit: Int = 8
  ) -> KnowledgeContextSelection {
    let verified = pages.filter { $0.verificationStatus == .verified }
    let directory = verified
      .filter { $0.kind != .deliveryNote }
      .sorted { directoryPath(for: $0, pages: verified) < directoryPath(for: $1, pages: verified) }
    let readable = verified.filter {
      !KnowledgeMarkdown.normalizedBody($0.bodyMarkdown).isEmpty
    }
    let prerequisiteIDs = Set(prerequisites.map(\.id))
    let inheritedOrder = Dictionary(
      uniqueKeysWithValues: inheritedSlugs.enumerated().map { ($0.element, $0.offset) }
    )
    let direct = readable
      .filter {
        $0.sourceWorkItemID == item.id
          || $0.sourceWorkItemID.map(prerequisiteIDs.contains) == true
      }
      .sorted { lhs, rhs in
        let lhsIsCurrent = lhs.sourceWorkItemID == item.id
        let rhsIsCurrent = rhs.sourceWorkItemID == item.id
        if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
    let inherited = readable
      .filter { inheritedOrder[$0.slug] != nil }
      .sorted { lhs, rhs in
        let lhsOrder = inheritedOrder[lhs.slug] ?? Int.max
        let rhsOrder = inheritedOrder[rhs.slug] ?? Int.max
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }

    let queryTerms = terms(
      [
        item.title,
        item.body,
        item.acceptanceCriteria.joined(separator: " "),
      ].joined(separator: " ")
    )
    let pagesByID = Dictionary(uniqueKeysWithValues: verified.map { ($0.id, $0) })
    let scoredEntries = readable
      .compactMap { page -> (page: KnowledgePage, score: Int, destinationRelevant: Bool)? in
        let titleMatches = queryTerms.intersection(terms(page.title)).count
        let ancestorText = ancestorTitles(for: page, pagesByID: pagesByID)
          .joined(separator: " ")
        let ancestorMatches = queryTerms.intersection(terms(ancestorText)).count
        let purposeMatches = queryTerms.intersection(
          terms(purpose(for: page.slug, kind: page.kind))
        ).count
        let bodyMatches = min(
          queryTerms.intersection(terms(page.bodyMarkdown)).count,
          4
        )
        let destinationScore = (titleMatches * 6) + (ancestorMatches * 3) + (purposeMatches * 5)
        let score = destinationScore + bodyMatches
        return score > 0 ? (page, score, destinationScore > 0) : nil
      }
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.page.title.localizedCaseInsensitiveCompare(rhs.page.title) == .orderedAscending
      }
    let scored = scoredEntries.map(\.page)
    let destinationRelevantIDs = Set(
      scoredEntries
        .filter { $0.destinationRelevant }
        .map { $0.page.id }
    )

    var references: [KnowledgePage] = []
    var referenceIDs: Set<UUID> = []
    for page in direct + scored + inherited where references.count < max(0, referenceLimit) {
      if referenceIDs.insert(page.id).inserted {
        references.append(page)
      }
    }

    let writablePageIDs = Set(
      directory.compactMap { page -> UUID? in
        switch page.kind {
        case .section:
          return isWithinDeliveryHistory(page, pagesByID: pagesByID) ? nil : page.id
        case .page:
          if page.slug == "ways-of-working" { return nil }
          let isEmpty = KnowledgeMarkdown.normalizedBody(page.bodyMarkdown).isEmpty
          if isEmpty { return page.id }
          let isDirectHandoff =
            page.sourceWorkItemID == item.id
            || page.sourceWorkItemID.map(prerequisiteIDs.contains) == true
          return referenceIDs.contains(page.id)
            && (destinationRelevantIDs.contains(page.id) || isDirectHandoff)
            ? page.id
            : nil
        case .deliveryNote:
          return nil
        }
      }
    )

    return KnowledgeContextSelection(
      referencePages: references,
      directoryPages: directory,
      writablePageIDs: writablePageIDs
    )
  }

  public static func purpose(for slug: String, kind: KnowledgePageKind) -> String {
    if kind == .section {
      if slug == "delivery-history" {
        return "Generated ticket delivery evidence; StoryPointless maintains this section."
      }
      return "Create a focused child page here when no existing canonical page fits."
    }
    switch slug {
    case "home":
      return "A concise entry point to the product's verified knowledge."
    case "overview":
      return "The product's purpose, value, scope, and current capabilities."
    case "users-and-journeys":
      return "Product users, their needs, and end-to-end journeys."
    case "product-principles":
      return "Durable product guardrails and owner-approved principles."
    case "glossary":
      return "Stable product and domain terminology."
    case "architecture":
      return "High-level architecture, boundaries, and major design constraints."
    case "components-and-data":
      return "Internal components, data models, storage, ownership, and state contracts."
    case "integrations":
      return "External services, providers, APIs, attribution, privacy, and failure contracts."
    case "environments":
      return "Runtime environments, configuration, and operating requirements."
    case "runbooks":
      return "Repeatable operating, support, diagnosis, and recovery procedures."
    case "release-and-rollback":
      return "Release, deployment, rollback, and restoration procedures."
    case "ways-of-working":
      return "Product Owner-approved team delivery practices only."
    case "known-limitations":
      return "Current caveats, unsupported cases, incidents, and recurring failure patterns."
    default:
      return "Verified reusable knowledge within this page's existing subject."
    }
  }

  public static func directoryPath(
    for page: KnowledgePage,
    pages: [KnowledgePage]
  ) -> String {
    let pagesByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
    return (ancestorTitles(for: page, pagesByID: pagesByID) + [page.title])
      .joined(separator: " > ")
  }

  private static func ancestorTitles(
    for page: KnowledgePage,
    pagesByID: [UUID: KnowledgePage]
  ) -> [String] {
    var titles: [String] = []
    var parentID = page.parentID
    var visited: Set<UUID> = []
    while let id = parentID, visited.insert(id).inserted, let parent = pagesByID[id] {
      titles.insert(parent.title, at: 0)
      parentID = parent.parentID
    }
    return titles
  }

  private static func isWithinDeliveryHistory(
    _ page: KnowledgePage,
    pagesByID: [UUID: KnowledgePage]
  ) -> Bool {
    if page.slug == "delivery-history" { return true }
    var parentID = page.parentID
    var visited: Set<UUID> = []
    while let id = parentID, visited.insert(id).inserted, let parent = pagesByID[id] {
      if parent.slug == "delivery-history" { return true }
      parentID = parent.parentID
    }
    return false
  }

  private static func terms(_ value: String) -> Set<String> {
    Set(
      value.lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { $0.count >= 4 && !ignoredTerms.contains($0) }
        .map(termKey)
    )
  }

  private static func termKey(_ term: String) -> String {
    term.count > 7 ? String(term.prefix(7)) : term
  }
}
