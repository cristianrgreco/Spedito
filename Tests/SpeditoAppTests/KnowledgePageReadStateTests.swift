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

  @Test("Reading an updated page clears and persists its unread state")
  func readingUpdatedPagePersists() {
    let productID = UUID()
    let defaultsSuite = isolatedDefaults()
    let defaults = defaultsSuite.defaults
    defer { defaults.removePersistentDomain(forName: defaultsSuite.suiteName) }

    var updatedPage = page(
      productID: productID,
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    var initialState = KnowledgePageReadState()
    initialState.load(productID: productID, pages: [updatedPage], defaults: defaults)

    updatedPage.updatedAt = Date(timeIntervalSince1970: 200)
    #expect(initialState.unreadPageIDs(in: [updatedPage]) == [updatedPage.id])

    initialState.markRead(updatedPage, defaults: defaults)
    #expect(initialState.unreadPageIDs(in: [updatedPage]).isEmpty)

    var relaunchedState = KnowledgePageReadState()
    relaunchedState.load(productID: productID, pages: [updatedPage], defaults: defaults)
    #expect(relaunchedState.unreadPageIDs(in: [updatedPage]).isEmpty)
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
