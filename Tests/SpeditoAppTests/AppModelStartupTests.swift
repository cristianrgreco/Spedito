import Foundation
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

@Suite("App model startup")
@MainActor
struct AppModelStartupTests {
  @Test("Onboarding stays hidden until the initial store load resolves")
  func initialLoadingState() async {
    let model = AppModel(store: nil)

    #expect(model.isLoading)

    await model.reload()

    #expect(!model.isLoading)
  }

  @Test("Launch query count stays bounded as conversation history grows")
  func launchQueryCountIsBounded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-launch-query-budget-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Bounded launch")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let recipient = try #require(profiles.first)
    let model = AppModel(store: store, selectedProductID: product.id)

    await model.reload()
    #if DEBUG
      await store.resetPreparedStatementCount()
      await model.reload()
      let boundedLaunchQueryCount = await store.currentPreparedStatementCount()

      for index in 0..<20 {
        let thread = ProductConversationThread(
          productID: product.id,
          recipientProfileID: recipient.id,
          subject: "Historical thread \(index)"
        )
        _ = try await store.createConversationThread(
          thread,
          initialMessage: ProductConversationMessage(
            threadID: thread.id,
            authorKind: .owner,
            authorName: "Me",
            body: "Historical message \(index)"
          )
        )
      }

      await store.resetPreparedStatementCount()
      await model.reload()
      #expect(await store.currentPreparedStatementCount() == boundedLaunchQueryCount)
    #endif

    await model.shutdown()
    await store.close()
  }

  @Test("Legacy application data moves to the Spedito support directory")
  func legacyApplicationSupportMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-app-support-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyURL = root.appendingPathComponent("StoryPointless", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
    let markerURL = legacyURL.appendingPathComponent("existing-product-data")
    try Data("preserved".utf8).write(to: markerURL)

    let migratedURL = try AppModel.migratedApplicationSupportURL(in: root)

    #expect(migratedURL.lastPathComponent == "Spedito")
    #expect(
      FileManager.default.fileExists(
        atPath: migratedURL.appendingPathComponent("existing-product-data").path))
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  }

  @Test("Legacy preferences copy only when Spedito has no value")
  func legacyDefaultsMigration() throws {
    let currentDomain = "io.spedito.tests.\(UUID())"
    let legacyDomain = "com.storypointless.tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: currentDomain))
    defer {
      defaults.removePersistentDomain(forName: currentDomain)
      defaults.removePersistentDomain(forName: legacyDomain)
    }
    defaults.setPersistentDomain(
      [
        "selectedProductID": "legacy-product",
        "codex.selectedInstallationID": "legacy-codex",
      ],
      forName: legacyDomain
    )
    defaults.set("current-product", forKey: "selectedProductID")

    AppModel.migrateLegacyDefaults(from: legacyDomain, to: defaults)

    #expect(defaults.string(forKey: "selectedProductID") == "current-product")
    #expect(defaults.string(forKey: "codex.selectedInstallationID") == "legacy-codex")

    defaults.removeObject(forKey: "codex.selectedInstallationID")
    AppModel.migrateLegacyDefaults(from: legacyDomain, to: defaults)
    #expect(defaults.string(forKey: "codex.selectedInstallationID") == nil)
  }

  @Test("Workspace reload defers conversation bodies to the selected thread")
  func conversationBodiesLoadOnSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-conversation-reload-\(UUID())",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(url: root.appendingPathComponent("product.sqlite"))
    let product = try await store.createProduct(name: "Conversation product")
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    let recipient = try #require(profiles.first)
    let first = ProductConversationThread(
      productID: product.id,
      recipientProfileID: recipient.id,
      subject: "First thread"
    )
    let second = ProductConversationThread(
      productID: product.id,
      recipientProfileID: recipient.id,
      subject: "Second thread"
    )
    _ = try await store.createConversationThread(
      first,
      initialMessage: ProductConversationMessage(
        threadID: first.id,
        authorKind: .owner,
        authorName: "Me",
        body: "First message"
      )
    )
    _ = try await store.createConversationThread(
      second,
      initialMessage: ProductConversationMessage(
        threadID: second.id,
        authorKind: .owner,
        authorName: "Me",
        body: "Second message"
      )
    )

    let model = AppModel(store: store, selectedProductID: product.id)
    #if DEBUG
      await store.resetPreparedStatementCount()
    #endif
    await model.reloadSelectedProduct()
    #if DEBUG
      let boundedReloadQueryCount = await store.currentPreparedStatementCount()
      for index in 0..<20 {
        let thread = ProductConversationThread(
          productID: product.id,
          recipientProfileID: recipient.id,
          subject: "Additional thread \(index)"
        )
        _ = try await store.createConversationThread(
          thread,
          initialMessage: ProductConversationMessage(
            threadID: thread.id,
            authorKind: .owner,
            authorName: "Me",
            body: "Additional message \(index)"
          )
        )
      }
      await store.resetPreparedStatementCount()
      await model.reloadSelectedProduct()
      #expect(await store.currentPreparedStatementCount() == boundedReloadQueryCount)
    #endif

    #expect(model.conversationThreads.contains { $0.id == first.id })
    #expect(model.conversationThreads.contains { $0.id == second.id })
    #expect(model.conversationMessagesByThread.isEmpty)

    await model.loadProductConversationMessages(threadID: first.id)
    #expect(Set(model.conversationMessagesByThread.keys) == [first.id])
    #expect(model.conversationMessagesByThread[first.id]?.map(\.body) == ["First message"])

    await model.loadProductConversationMessages(threadID: second.id)
    #expect(Set(model.conversationMessagesByThread.keys) == [second.id])
    #expect(model.conversationMessagesByThread[second.id]?.map(\.body) == ["Second message"])
    await store.close()
  }
}
