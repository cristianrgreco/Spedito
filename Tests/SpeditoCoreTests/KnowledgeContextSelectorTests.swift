import Foundation
import Testing

@testable import SpeditoCore

@Suite("Knowledge context selection")
struct KnowledgeContextSelectorTests {
  @Test("Empty canonical pages are writable destinations, not verified reference content")
  func emptyPagesAreDestinations() throws {
    let productID = UUID()
    let technical = KnowledgePage(
      productID: productID,
      title: "Technical",
      slug: "technical",
      kind: .section
    )
    let architecture = KnowledgePage(
      productID: productID,
      parentID: technical.id,
      title: "Architecture",
      slug: "architecture"
    )
    let waysOfWorking = KnowledgePage(
      productID: productID,
      title: "Ways of working",
      slug: "ways-of-working",
      bodyMarkdown: "Keep delivery evidence concise."
    )
    let deliveryHistory = KnowledgePage(
      productID: productID,
      title: "Delivery history",
      slug: "delivery-history",
      kind: .section
    )
    let item = WorkItem(
      productID: productID,
      key: "T1",
      title: "Describe the application architecture"
    )

    let selection = KnowledgeContextSelector.select(
      pages: [technical, architecture, waysOfWorking, deliveryHistory],
      item: item,
      prerequisites: []
    )

    #expect(selection.referencePages.map(\.id) == [waysOfWorking.id])
    #expect(selection.writablePageIDs.contains(technical.id))
    #expect(selection.writablePageIDs.contains(architecture.id))
    #expect(!selection.writablePageIDs.contains(waysOfWorking.id))
    #expect(!selection.writablePageIDs.contains(deliveryHistory.id))
    #expect(selection.directoryPages.map(\.id).contains(architecture.id))
  }

  @Test("Title and taxonomy relevance outrank repeated terms in a long catch-all page")
  func boundedBodyScoring() throws {
    let productID = UUID()
    let technical = KnowledgePage(
      productID: productID,
      title: "Technical",
      slug: "technical",
      kind: .section
    )
    let architecture = KnowledgePage(
      productID: productID,
      parentID: technical.id,
      title: "Architecture",
      slug: "architecture",
      bodyMarkdown: "The application boundary separates presentation from storage."
    )
    let components = KnowledgePage(
      productID: productID,
      parentID: technical.id,
      title: "Components & data",
      slug: "components-and-data",
      bodyMarkdown: Array(
        repeating: "architecture boundary presentation storage external integration",
        count: 20
      ).joined(separator: " ")
    )
    let item = WorkItem(
      productID: productID,
      key: "T2",
      title: "Document architecture boundaries",
      body: "Record the high-level application architecture."
    )

    let selection = KnowledgeContextSelector.select(
      pages: [technical, architecture, components],
      item: item,
      prerequisites: [],
      referenceLimit: 1
    )

    #expect(selection.referencePages.map(\.id) == [architecture.id])
    #expect(selection.writablePageIDs.contains(architecture.id))
    #expect(!selection.writablePageIDs.contains(components.id))
  }

  @Test("The directory exposes empty specialist pages without exposing unrelated populated bodies")
  func writableDirectoryIsSeparate() throws {
    let productID = UUID()
    let technical = KnowledgePage(
      productID: productID,
      title: "Technical",
      slug: "technical",
      kind: .section
    )
    let integrations = KnowledgePage(
      productID: productID,
      parentID: technical.id,
      title: "Integrations",
      slug: "integrations"
    )
    let limitations = KnowledgePage(
      productID: productID,
      title: "Known limitations",
      slug: "known-limitations",
      bodyMarkdown: "Offline operation is not supported."
    )
    let item = WorkItem(
      productID: productID,
      key: "T3",
      title: "Connect an external provider API"
    )

    let selection = KnowledgeContextSelector.select(
      pages: [technical, integrations, limitations],
      item: item,
      prerequisites: []
    )

    #expect(selection.referencePages.isEmpty)
    #expect(selection.writablePageIDs.contains(integrations.id))
    #expect(!selection.writablePageIDs.contains(limitations.id))
    #expect(
      KnowledgeContextSelector.purpose(for: integrations.slug, kind: integrations.kind)
        .contains("External services")
    )
  }

  @Test("Verified Environments guidance is mandatory and remains updateable by implementation")
  func environmentsIsMandatoryOperationalContext() throws {
    let productID = UUID()
    let environments = KnowledgePage(
      productID: productID,
      title: "Environments",
      slug: "environments",
      bodyMarkdown: """
        Run the repository's maintained validation task from its root.
        """
    )
    let unrelated = KnowledgePage(
      productID: productID,
      title: "Users & journeys",
      slug: "users-and-journeys",
      bodyMarkdown: "Product Owners review completed outcomes."
    )
    let item = WorkItem(
      productID: productID,
      key: "T4",
      title: "Adjust ticket row spacing"
    )

    let selection = KnowledgeContextSelector.select(
      pages: [unrelated, environments],
      item: item,
      prerequisites: []
    )

    #expect(selection.referencePages.map(\.id) == [environments.id])
    #expect(selection.writablePageIDs.contains(environments.id))
    #expect(KnowledgeContextSelector.isMandatory(environments))
    #expect(!KnowledgeContextSelector.isMandatory(unrelated))
  }

  @Test("Epic planning receives mandatory and relevant verified knowledge only")
  func epicPlanningKnowledgeIsBoundedAndRelevant() {
    let productID = UUID()
    let environments = KnowledgePage(
      productID: productID,
      title: "Environments",
      slug: "environments",
      bodyMarkdown: "The browser application has a maintained local demo."
    )
    let integrations = KnowledgePage(
      productID: productID,
      title: "Integrations",
      slug: "integrations",
      bodyMarkdown: "External weather providers require privacy and attribution review."
    )
    let limitations = KnowledgePage(
      productID: productID,
      title: "Known limitations",
      slug: "known-limitations",
      bodyMarkdown: "Exported reports do not support custom fonts."
    )
    let staleIntegrations = KnowledgePage(
      productID: productID,
      title: "Weather provider notes",
      slug: "weather-provider-notes",
      bodyMarkdown: "An old weather provider comparison.",
      verificationStatus: .stale
    )
    let epic = Epic(
      productID: productID,
      title: "Weather provider",
      goal: "Show forecasts from an external weather service with suitable privacy."
    )

    let pages = KnowledgeContextSelector.selectForEpic(
      pages: [limitations, staleIntegrations, integrations, environments],
      epic: epic
    )

    #expect(pages.map(\.id).contains(environments.id))
    #expect(pages.map(\.id).contains(integrations.id))
    #expect(!pages.map(\.id).contains(limitations.id))
    #expect(!pages.map(\.id).contains(staleIntegrations.id))
  }
}
