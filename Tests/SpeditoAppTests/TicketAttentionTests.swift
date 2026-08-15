import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

@Suite("Cross-product ticket attention", .serialized)
@MainActor
struct TicketAttentionTests {
  @Test("Reload exposes attention from a product that is not selected")
  func reloadAggregatesBackgroundProductAttention() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let sourceProduct = try await registry.createProduct(name: "Source product")
    let selectedProduct = try await registry.createProduct(name: "Selected product")
    let sourceStore = try #require(registry.store(for: sourceProduct.id))
    let profile = try #require(
      try await sourceStore.seedDefaultProfiles(productID: sourceProduct.id).first
    )
    let item = try await sourceStore.createWorkItem(
      productID: sourceProduct.id,
      title: "Choose the delivery behavior"
    )
    let run = AgentRun(
      productID: sourceProduct.id,
      workItemID: item.id,
      profileID: profile.id,
      status: .awaitingOwner,
      updatedAt: Date(timeIntervalSince1970: 2_000)
    )
    _ = try await sourceStore.createAgentRun(run)
    _ = try await sourceStore.appendComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: profile.name,
      body: "I need one product decision.",
      ownerQuestion: TicketOwnerQuestion(
        prompt: "Should this remain visible after switching products?",
        options: ["Keep it visible", "Hide it"]
      )
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: selectedProduct.id
    )

    await model.reload()

    #expect(model.selectedProductID == selectedProduct.id)
    #expect(model.ticketAttentionCount == 1)
    #expect(model.ticketAttentionCount(for: sourceProduct.id) == 1)
    #expect(model.ticketAttentionCount(for: selectedProduct.id) == 0)
    #expect(model.ticketAttentionCount(excluding: selectedProduct.id) == 1)
    #expect(model.ticketAttentionCount(excluding: sourceProduct.id) == 0)
    let attention = try #require(model.ticketAttentionsByProductID[sourceProduct.id]?.first)
    #expect(attention.workItemID == item.id)
    #expect(attention.itemKey == item.key)
    #expect(attention.summary == "Should this remain visible after switching products?")

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Reload exposes ready for demo attention from a product that is not selected")
  func reloadAggregatesBackgroundReadyForDemoAttention() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let sourceProduct = try await registry.createProduct(name: "Ready product")
    let selectedProduct = try await registry.createProduct(name: "Current product")
    let sourceStore = try #require(registry.store(for: sourceProduct.id))
    let item = try await moveToAcceptance(
      try await sourceStore.createWorkItem(
        productID: sourceProduct.id,
        title: "Review the completed ticket"
      ),
      in: sourceStore
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: selectedProduct.id
    )

    await model.reload()

    #expect(model.ownerAttentionCount(excluding: selectedProduct.id) == 1)
    #expect(model.ownerAttentionCount(for: sourceProduct.id) == 1)
    #expect(model.ownerAttentionRequiresAction(productID: sourceProduct.id))
    let attention = try #require(model.ticketAttentionsByProductID[sourceProduct.id]?.first)
    #expect(attention.workItemID == item.id)
    #expect(attention.summary == "Ready for demo")

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Switching products preserves newly ready for demo attention")
  func switchingProductsRefreshesReadyForDemoAttention() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let sourceProduct = try await registry.createProduct(name: "Ready product")
    let selectedProduct = try await registry.createProduct(name: "Next product")
    let sourceStore = try #require(registry.store(for: sourceProduct.id))
    let item = try await sourceStore.createWorkItem(
      productID: sourceProduct.id,
      title: "Review after switching products"
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: sourceProduct.id
    )
    await model.reload()
    _ = try await moveToAcceptance(item, in: sourceStore)

    await model.selectProduct(selectedProduct)

    #expect(model.selectedProductID == selectedProduct.id)
    #expect(model.ownerAttentionCount(excluding: selectedProduct.id) == 1)
    #expect(model.ticketAttentionCount(for: sourceProduct.id) == 1)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Opening one attention request selects its product and targets its ticket")
  func openingAttentionTargetsTicket() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let sourceProduct = try await registry.createProduct(name: "Source product")
    let selectedProduct = try await registry.createProduct(name: "Selected product")
    let sourceStore = try #require(registry.store(for: sourceProduct.id))
    let profile = try #require(
      try await sourceStore.seedDefaultProfiles(productID: sourceProduct.id).first
    )
    let item = try await sourceStore.createWorkItem(
      productID: sourceProduct.id,
      title: "Answer the delivery question"
    )
    _ = try await sourceStore.createAgentRun(
      AgentRun(
        productID: sourceProduct.id,
        workItemID: item.id,
        profileID: profile.id,
        status: .awaitingOwner
      )
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: selectedProduct.id
    )
    await model.reload()
    let attention = try #require(model.ticketAttentionsByProductID[sourceProduct.id]?.first)
    let presentation = OwnerNotificationPresentation(attention: attention)
    await model.openOwnerNotification(
      try #require(
        OwnerNotificationRoute(
          userInfo: OwnerNotificationRoute.userInfo(for: presentation)
        )
      )
    )
    let ownerRequest = try #require(model.ownerNotificationNavigationRequest)
    #expect(ownerRequest.productID == sourceProduct.id)
    #expect(ownerRequest.target == OwnerNotificationTarget(kind: .ticket, id: item.id))
    model.consumeOwnerNotificationNavigationRequest(id: ownerRequest.id)

    await model.openTicketAttentions(for: sourceProduct)

    #expect(model.selectedProductID == sourceProduct.id)
    let request = try #require(model.ticketAttentionNavigationRequest)
    #expect(request.productID == sourceProduct.id)
    #expect(request.workItemIDs == [item.id])
    #expect(request.openWorkItemID == item.id)

    let secondItem = try await sourceStore.createWorkItem(
      productID: sourceProduct.id,
      title: "Answer another delivery question"
    )
    _ = try await sourceStore.createAgentRun(
      AgentRun(
        productID: sourceProduct.id,
        workItemID: secondItem.id,
        profileID: profile.id,
        status: .awaitingOwner
      )
    )
    await model.reload()

    await model.openTicketAttentions(for: sourceProduct)

    let multipleRequest = try #require(model.ticketAttentionNavigationRequest)
    #expect(multipleRequest.workItemIDs == [item.id, secondItem.id])
    #expect(multipleRequest.openWorkItemID == nil)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Notification routing preserves every destination kind")
  func notificationRouteRoundTrips() throws {
    for targetKind in OwnerNotificationTargetKind.allCases {
      let notification = OwnerNotification(
        productID: UUID(),
        kind: targetKind == .conversationThread ? .newReply : .refinementComplete,
        target: OwnerNotificationTarget(kind: targetKind, id: UUID()),
        title: "Open the completed work",
        body: "The agent result is ready."
      )
      let presentation = OwnerNotificationPresentation(
        notification: notification,
        productName: "Routing product"
      )

      let route = try #require(
        OwnerNotificationRoute(
          userInfo: OwnerNotificationRoute.userInfo(for: presentation)
        )
      )

      #expect(route.notificationID == notification.id)
      #expect(route.productID == notification.productID)
      #expect(route.target == notification.target)
    }
    #expect(OwnerNotificationRoute(userInfo: [:]) == nil)
  }
  @Test("A visible source records an update without interrupting the owner")
  func visibleSourceSuppressesPresentation() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Visible product")
    let store = try #require(registry.store(for: product.id))
    let sound = NotificationSoundSpy()
    let system = NotificationSystemSpy()
    let coordinator = OwnerNotificationCoordinator(
      storeProvider: { productID in
        productID == product.id ? store : nil
      },
      soundPlayer: sound,
      systemNotifier: system
    )
    let target = OwnerNotificationTarget(kind: .ticket, id: UUID())
    await coordinator.setVisible(productID: product.id, target: target)
    let notification = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: target,
      title: "T1 needs your input",
      body: "Choose an option."
    )

    let published = await coordinator.publish(
      notification,
      productName: product.name
    )

    #expect(published)
    #expect(coordinator.presentedNotification == nil)
    #expect(sound.playCount == 0)
    #expect(system.posted.isEmpty)
    let stored = try #require(
      try await store.fetchActiveOwnerNotifications(productID: product.id).first
    )
    #expect(stored.isUnread == false)
    #expect(stored.resolvedAt == nil)

    coordinator.clearVisible(productID: product.id, target: target)
    await coordinator.setApplicationActive(false)
    let backgroundReply = OwnerNotification(
      productID: product.id,
      kind: .newReply,
      target: OwnerNotificationTarget(kind: .conversationThread, id: UUID()),
      title: "Business analyst replied",
      body: "The requested result is ready."
    )
    #expect(await coordinator.publish(backgroundReply, productName: product.name))
    #expect(coordinator.presentedNotification == nil)
    #expect(system.posted.map(\.id) == [backgroundReply.id])

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Updates stay quiet while owner questions chime and resolution dismisses")
  func notificationKindControlsSoundAndResolution() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Background product")
    let store = try #require(registry.store(for: product.id))
    let sound = NotificationSoundSpy()
    let system = NotificationSystemSpy()
    let coordinator = OwnerNotificationCoordinator(
      storeProvider: { productID in
        productID == product.id ? store : nil
      },
      soundPlayer: sound,
      systemNotifier: system
    )
    let reply = OwnerNotification(
      productID: product.id,
      kind: .newReply,
      target: OwnerNotificationTarget(kind: .conversationThread, id: UUID()),
      title: "Business analyst replied",
      body: "Here is the result."
    )
    let question = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .epic, id: UUID()),
      title: "Epic needs your input",
      body: "Choose an option."
    )

    #expect(await coordinator.publish(reply, productName: product.name))
    #expect(sound.playCount == 0)
    #expect(await coordinator.publish(question, productName: product.name))
    #expect(sound.playCount == 1)
    #expect(system.posted.map(\.id) == [reply.id, question.id])

    await coordinator.resolve(productID: product.id, target: question.target)

    #expect(coordinator.presentedNotification == nil)
    #expect(system.dismissedIDs.contains(question.id))
    #expect(
      try await store.fetchActiveOwnerNotifications(productID: product.id)
        .contains(where: { $0.id == question.id }) == false
    )

    for store in registry.allStores {
      await store.close()
    }
  }
  @Test("Opening a notification for an archived target fails closed")
  func archivedTargetDoesNotNavigate() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Archived target")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Retire this notification target"
    )
    try await store.archiveEpic(id: epic.id)
    let notification = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .epic, id: epic.id),
      title: "Epic needs your input",
      body: "This source has since been archived."
    )
    #expect(try await store.createOwnerNotification(notification))
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: NotificationSoundSpy(),
      ownerNotificationSystemNotifier: NotificationSystemSpy()
    )
    await model.reload()
    let presentation = OwnerNotificationPresentation(
      notification: notification,
      productName: product.name
    )

    await model.openOwnerNotification(
      try #require(
        OwnerNotificationRoute(
          userInfo: OwnerNotificationRoute.userInfo(for: presentation)
        )
      )
    )

    #expect(model.ownerNotificationNavigationRequest == nil)
    #expect(try await store.fetchActiveOwnerNotifications(productID: product.id).isEmpty)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("A single background result routes from the product attention count")
  func productAttentionRoutesSingleBackgroundResult() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let sourceProduct = try await registry.createProduct(name: "Background result")
    let selectedProduct = try await registry.createProduct(name: "Current product")
    let store = try #require(registry.store(for: sourceProduct.id))
    let epic = try await store.createEpic(
      productID: sourceProduct.id,
      outcome: "Review the proposed delivery plan"
    )
    let notification = OwnerNotification(
      productID: sourceProduct.id,
      kind: .refinementComplete,
      target: OwnerNotificationTarget(kind: .epic, id: epic.id),
      title: "Plan ready for review",
      body: "The proposed tickets are ready."
    )
    #expect(try await store.createOwnerNotification(notification))
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: selectedProduct.id,
      ownerNotificationSoundPlayer: NotificationSoundSpy(),
      ownerNotificationSystemNotifier: NotificationSystemSpy()
    )
    await model.reload()

    #expect(model.ownerAttentionCount(excluding: selectedProduct.id) == 1)
    await model.openOwnerAttentions(for: sourceProduct)

    #expect(model.selectedProductID == sourceProduct.id)
    let request = try #require(model.ownerNotificationNavigationRequest)
    #expect(request.target == notification.target)

    for store in registry.allStores {
      await store.close()
    }
  }

  private func moveToAcceptance(
    _ item: WorkItem,
    in store: SQLiteStore
  ) async throws -> WorkItem {
    var item = item
    for state: WorkItemState in [
      .refining,
      .ready,
      .queued,
      .running,
      .integrating,
      .verifying,
      .acceptance,
    ] {
      item = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: "Test",
        reason: "Set up ready for demo attention"
      )
    }
    return item
  }

}

private struct TicketAttentionFixture {
  let directoryURL: URL
  let workspacesURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-ticket-attention-\(UUID())",
      isDirectory: true
    )
    workspacesURL = directoryURL.appendingPathComponent(
      "Product Workspaces",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

@MainActor
private final class NotificationSoundSpy: OwnerNotificationSoundPlaying {
  private(set) var playCount = 0

  func play() {
    playCount += 1
  }
}

@MainActor
private final class NotificationSystemSpy: OwnerNotificationSystemNotifying {
  private(set) var posted: [OwnerNotificationPresentation] = []
  private(set) var dismissedIDs: Set<UUID> = []

  func post(_ presentation: OwnerNotificationPresentation) {
    posted.append(presentation)
  }

  func dismiss(ids: [UUID]) {
    dismissedIDs.formUnion(ids)
  }
}
