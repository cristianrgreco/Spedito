import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Product knowledge unread state")
struct KnowledgePageReadStateTests {
  @Test("Existing pages start read and later pages remain unread across relaunch")
  func newlyAddedPageIsUnread() {
    let productID = UUID()
    let defaultsSuite = isolatedDefaults()
    let defaults = defaultsSuite.defaults
    defer { defaults.removePersistentDomain(forName: defaultsSuite.suiteName) }

    let existingPage = page(productID: productID, updatedAt: Date(timeIntervalSince1970: 100))
    var initialState = KnowledgePageReadState()
    initialState.load(productID: productID, pages: [existingPage], defaults: defaults)
    #expect(initialState.unreadPageIDs(in: [existingPage]).isEmpty)

    let newPage = page(productID: productID, updatedAt: Date(timeIntervalSince1970: 200))
    var relaunchedState = KnowledgePageReadState()
    relaunchedState.load(
      productID: productID,
      pages: [existingPage, newPage],
      defaults: defaults
    )

    #expect(relaunchedState.unreadPageIDs(in: [existingPage, newPage]) == [newPage.id])
  }

  @Test("K01 changed pages become unread independently and opened pages stay read after relaunch")
  func k01ChangedPagesBecomeUnreadIndependently() {
    let firstProductID = UUID()
    let secondProductID = UUID()
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let initialUpdate = Date(timeIntervalSince1970: 1_000)
    var firstPage = page(productID: firstProductID, updatedAt: initialUpdate)
    var siblingPage = page(productID: firstProductID, updatedAt: initialUpdate)
    var otherProductPage = page(productID: secondProductID, updatedAt: initialUpdate)
    var firstProductState = KnowledgePageReadState()
    var secondProductState = KnowledgePageReadState()

    firstProductState.load(
      productID: firstProductID,
      pages: [firstPage, siblingPage],
      defaults: defaults
    )
    secondProductState.load(
      productID: secondProductID,
      pages: [otherProductPage],
      defaults: defaults
    )

    firstPage.updatedAt = Date(timeIntervalSince1970: 2_000)
    siblingPage.updatedAt = Date(timeIntervalSince1970: 3_000)
    otherProductPage.updatedAt = Date(timeIntervalSince1970: 4_000)
    #expect(
      firstProductState.unreadPageIDs(in: [firstPage, siblingPage])
        == Set([firstPage.id, siblingPage.id])
    )
    #expect(
      secondProductState.unreadPageIDs(in: [otherProductPage])
        == Set([otherProductPage.id])
    )

    firstProductState.markRead(firstPage, defaults: defaults)
    #expect(
      firstProductState.unreadPageIDs(in: [firstPage, siblingPage])
        == Set([siblingPage.id])
    )
    #expect(
      secondProductState.unreadPageIDs(in: [otherProductPage])
        == Set([otherProductPage.id])
    )

    var relaunchedState = KnowledgePageReadState()
    relaunchedState.load(
      productID: firstProductID,
      pages: [firstPage, siblingPage],
      defaults: defaults
    )
    #expect(
      relaunchedState.unreadPageIDs(in: [firstPage, siblingPage])
        == Set([siblingPage.id])
    )
  }

  @Test("K03 Cancel discards a Knowledge edit while Save versions and relaunches it")
  @MainActor
  func k03KnowledgeEditCancelSaveAndRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-k03-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: "Knowledge editing")
    let pages = try await store.seedKnowledgeBase(productID: product.id)
    let technical = try #require(pages.first { $0.slug == "technical" })
    let model = AppModel(
      store: store,
      selectedProductID: product.id,
      codexTransportFactory: { _ in
        throw CodexClientError.notConnected
      }
    )
    await model.load()
    let page = try #require(
      await model.createKnowledgePage(
        productID: product.id,
        parentID: technical.id,
        title: "Delivery contract"
      )
    )
    #expect(page.parentID == technical.id)
    #expect(model.knowledgePages.contains { $0.id == page.id })

    var draft = KnowledgePageDraft(page: page)
    draft.title = "Discarded title"
    draft.bodyMarkdown = "Discarded body"
    draft.cancel(to: page)
    #expect(draft == KnowledgePageDraft(page: page))
    #expect(try await store.fetchKnowledgePageRevisions(pageID: page.id).count == 1)

    draft.title = "Release contract"
    draft.bodyMarkdown = "Saved once."
    #expect(
      await model.saveKnowledgePage(
        productID: product.id,
        id: page.id,
        title: draft.title,
        bodyMarkdown: draft.bodyMarkdown,
        changeSummary: "Recorded release contract"
      )
    )
    #expect(try await store.fetchKnowledgePageRevisions(pageID: page.id).count == 2)

    await model.shutdown()
    await store.close()
    let reopened = try SQLiteStore(url: databaseURL)
    let persistedPage = try #require(
      await reopened.fetchKnowledgePages(productID: product.id).first { $0.id == page.id }
    )
    #expect(persistedPage.title == "Release contract")
    #expect(persistedPage.bodyMarkdown == "Saved once.")
    #expect(try await reopened.fetchKnowledgePageRevisions(pageID: page.id).count == 2)
    await reopened.close()
  }

  @Test("K05 Knowledge answers and Unknown results cite only verified pages")
  func k05KnowledgeAnswersLinkOnlyCitedVerifiedPages() throws {
    let productID = UUID()
    let cited = KnowledgePage(
      productID: productID,
      title: "Release contract",
      slug: "release-contract"
    )
    let uncited = KnowledgePage(
      productID: productID,
      title: "Unrelated decision",
      slug: "unrelated-decision"
    )
    let proposed = KnowledgePage(
      productID: productID,
      title: "Draft evidence",
      slug: "draft-evidence",
      verificationStatus: .proposed
    )
    let answer = KnowledgeAnswer(
      answer: "Use the verified release contract.",
      citationPageIDs: [cited.id, proposed.id, UUID(), cited.id]
    )

    #expect(
      KnowledgeAnswerPresentation.citedVerifiedPages(
        answer: answer,
        pages: [uncited, proposed, cited]
      ).map(\.id) == [cited.id]
    )
    let unknown = try CodexKnowledgeAssistant.decode(
      #"{"answer":"The verified knowledge does not answer this question.","citationPageIDs":[]}"#,
      allowedPageIDs: Set([cited.id])
    )
    #expect(unknown.answer == "The verified knowledge does not answer this question.")
    #expect(
      KnowledgeAnswerPresentation.citedVerifiedPages(
        answer: unknown,
        pages: [cited]
      ).isEmpty
    )
  }

  @Test("K06 accepted Ticket knowledge resolves only to its verified canonical page")
  func k06AcceptedTicketKnowledgeResolvesCanonicalPage() {
    let productID = UUID()
    let workItemID = UUID()
    let canonical = KnowledgePage(
      productID: productID,
      title: "Release contract",
      slug: "release-contract",
      sourceWorkItemID: workItemID
    )
    let unverified = KnowledgePage(
      productID: productID,
      title: "Draft contract",
      slug: "draft-contract",
      verificationStatus: .proposed,
      sourceWorkItemID: workItemID
    )
    let acceptedCreation = knowledgeProposal(
      productID: productID,
      workItemID: workItemID,
      operation: .create,
      title: canonical.title,
      status: .accepted
    )
    let rejectedCreation = knowledgeProposal(
      productID: productID,
      workItemID: workItemID,
      operation: .create,
      title: canonical.title,
      status: .rejected
    )
    let acceptedUpdate = knowledgeProposal(
      productID: productID,
      workItemID: workItemID,
      operation: .update,
      targetPageID: canonical.id,
      title: canonical.title,
      status: .accepted
    )
    let unverifiedUpdate = knowledgeProposal(
      productID: productID,
      workItemID: workItemID,
      operation: .update,
      targetPageID: unverified.id,
      title: unverified.title,
      status: .accepted
    )

    #expect(
      TicketKnowledgeNavigationPolicy.publishedPage(
        for: acceptedCreation,
        pages: [unverified, canonical]
      )?.id == canonical.id
    )
    #expect(
      TicketKnowledgeNavigationPolicy.publishedPage(
        for: acceptedUpdate,
        pages: [unverified, canonical]
      )?.id == canonical.id
    )
    #expect(
      TicketKnowledgeNavigationPolicy.publishedPage(
        for: rejectedCreation,
        pages: [canonical]
      ) == nil
    )
    #expect(
      TicketKnowledgeNavigationPolicy.publishedPage(
        for: unverifiedUpdate,
        pages: [unverified]
      ) == nil
    )
  }

  @Test("[K02] Knowledge navigation preserves a valid page across every navigation path")
  func k02KnowledgeNavigationPreservesValidSelection() throws {
    let productID = UUID()
    let home = KnowledgePage(
      productID: productID,
      title: "Home",
      slug: "home",
      kind: .section,
      sortOrder: 0
    )
    let runbook = KnowledgePage(
      productID: productID,
      parentID: home.id,
      title: "Runbook",
      slug: "runbook",
      bodyMarkdown: "Use the release checklist.",
      sortOrder: 2
    )
    let decision = KnowledgePage(
      productID: productID,
      parentID: home.id,
      title: "Release decision",
      slug: "release-decision",
      bodyMarkdown: "See [[Runbook]] before release.",
      sortOrder: 1
    )
    let pages = [runbook, home, decision]

    #expect(
      KnowledgePageNavigation.search(pages, query: "release").map(\.id)
        == [decision.id, runbook.id]
    )
    #expect(
      KnowledgePageNavigation.children(of: home.id, in: pages).map(\.id)
        == [decision.id, runbook.id]
    )
    #expect(
      KnowledgePageNavigation.breadcrumbs(for: runbook, in: pages).map(\.id)
        == [home.id, runbook.id]
    )
    #expect(
      KnowledgePageNavigation.backlinks(to: runbook, in: pages).map(\.id)
        == [decision.id]
    )
    #expect(
      KnowledgePageNavigation.resolvedSelection(
        requestedID: UUID(),
        currentID: runbook.id,
        pages: pages
      ) == runbook.id
    )
    #expect(
      KnowledgePageNavigation.resolvedSelection(
        requestedID: decision.id,
        currentID: runbook.id,
        pages: pages
      ) == decision.id
    )
    #expect(
      KnowledgePageNavigation.resolvedSelection(
        requestedID: nil,
        currentID: UUID(),
        pages: pages
      ) == home.id
    )
  }

  private func knowledgeProposal(
    productID: UUID,
    workItemID: UUID,
    operation: KnowledgePageProposalOperation,
    targetPageID: UUID? = nil,
    title: String,
    status: KnowledgePageProposalStatus
  ) -> KnowledgePageProposal {
    KnowledgePageProposal(
      productID: productID,
      sprintID: UUID(),
      workItemID: workItemID,
      candidateRevisionID: UUID(),
      operation: operation,
      targetPageID: targetPageID,
      title: title,
      proposedBodyMarkdown: "Proposed canonical body",
      rationale: "Preserve reusable truth",
      status: status
    )
  }

  private func page(productID: UUID, updatedAt: Date) -> KnowledgePage {
    KnowledgePage(
      productID: productID,
      title: "Page",
      slug: UUID().uuidString,
      updatedAt: updatedAt
    )
  }

  private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "KnowledgePageReadStateTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }
}
