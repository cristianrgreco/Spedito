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

  @Test("C08 notifications choose in-app foreground or macOS background delivery")
  func c08ForegroundAndBackgroundNotificationDelivery() async throws {
    #expect(
      OwnerNotificationDeliveryPolicy.presentsInApp(applicationIsActive: true)
    )
    #expect(
      !OwnerNotificationDeliveryPolicy.postsToSystem(applicationIsActive: true)
    )
    #expect(
      !OwnerNotificationDeliveryPolicy.presentsInApp(applicationIsActive: false)
    )
    #expect(
      OwnerNotificationDeliveryPolicy.postsToSystem(applicationIsActive: false)
    )

    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Delivery policy")
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
    let foreground = OwnerNotification(
      productID: product.id,
      kind: .newReply,
      target: OwnerNotificationTarget(kind: .conversationThread, id: UUID()),
      title: "Business analyst replied",
      body: "Review the answer in Product Chat."
    )
    #expect(await coordinator.publish(foreground, productName: product.name))
    #expect(coordinator.presentedNotification?.id == foreground.id)
    #expect(sound.playCount == 0)

    coordinator.dismissPresented(id: foreground.id)
    await coordinator.setApplicationActive(false)
    // The question row needs a real unanswered wait to survive the load sweep.
    let questionItem = try await store.createWorkItem(
      productID: product.id,
      title: "Choose the delivery behavior"
    )
    _ = try await store.appendComment(
      workItemID: questionItem.id,
      authorKind: .agent,
      authorName: "Implementer",
      body: "I need one decision.",
      ownerQuestion: TicketOwnerQuestion(
        prompt: "Which delivery behavior applies?",
        options: ["Keep the current result", "Use the reviewed fallback"]
      )
    )
    let background = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .ticket, id: questionItem.id),
      title: "T8 needs your input",
      body: "Choose the delivery behavior."
    )
    #expect(await coordinator.publish(background, productName: product.name))
    #expect(coordinator.presentedNotification == nil)
    #expect(sound.playCount == 1)
    let posted = try #require(system.posted.last)
    #expect(posted.id == background.id)
    #expect(
      OwnerNotificationRoute(
        userInfo: OwnerNotificationRoute.userInfo(for: posted)
      )?.target == background.target
    )

    let recoveredCoordinator = OwnerNotificationCoordinator(
      storeProvider: { productID in
        productID == product.id ? store : nil
      },
      soundPlayer: NotificationSoundSpy(),
      systemNotifier: NotificationSystemSpy()
    )
    await recoveredCoordinator.load(products: [product])
    let recoveredBackground = try #require(
      recoveredCoordinator.notifications(productID: product.id)
        .first(where: { $0.id == background.id })
    )
    #expect(recoveredBackground.target == background.target)
    #expect(recoveredBackground.isUnread)

    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("C11 declined system notifications preserve in-app attention without launch prompts")
  func c11DeclinedSystemNotificationsPreserveInAppAttention() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Declined notifications")
    let store = try #require(registry.store(for: product.id))
    let firstSound = NotificationSoundSpy()
    let declinedSystem = DecliningNotificationSystemNotifier()
    let firstCoordinator = OwnerNotificationCoordinator(
      storeProvider: { productID in
        productID == product.id ? store : nil
      },
      soundPlayer: firstSound,
      systemNotifier: declinedSystem
    )
    // The question row needs a real unanswered wait to survive the load sweep.
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Answer the declined clarification"
    )
    try await store.saveEpicPlanningConversation(
      EpicPlanningConversationSnapshot(
        epicID: epic.id,
        messages: [],
        questions: [
          TicketRefinementQuestion(
            prompt: "Which outcome should the epic deliver?",
            options: ["Keep drafts local", "Publish drafts"]
          )
        ],
        isComplete: false,
        threadID: nil
      )
    )
    let notification = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .epic, id: epic.id),
      title: "Epic needs your input",
      body: "The macOS notification was declined."
    )

    #expect(await firstCoordinator.publish(notification, productName: product.name))
    #expect(firstCoordinator.presentedNotification?.id == notification.id)
    #expect(firstSound.playCount == 1)
    #expect(declinedSystem.postCount == 1)
    #expect(
      try await store.fetchActiveOwnerNotifications(productID: product.id).map(\.id)
        == [notification.id]
    )

    let relaunchedSound = NotificationSoundSpy()
    let relaunchedSystem = DecliningNotificationSystemNotifier()
    let relaunchedCoordinator = OwnerNotificationCoordinator(
      storeProvider: { productID in
        productID == product.id ? store : nil
      },
      soundPlayer: relaunchedSound,
      systemNotifier: relaunchedSystem
    )
    await relaunchedCoordinator.load(products: [product])
    await relaunchedCoordinator.load(products: [product])

    #expect(relaunchedCoordinator.notifications(productID: product.id).map(\.id) == [
      notification.id
    ])
    #expect(relaunchedCoordinator.presentedNotification == nil)
    #expect(relaunchedSound.playCount == 0)
    #expect(relaunchedSystem.postCount == 0)

    for productStore in registry.allStores {
      await productStore.close()
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

  /// Existing partial coverage:
  /// - `reloadAggregatesBackgroundProductAttention`
  /// - `openingAttentionTargetsTicket`
  /// - `ProductScopedPersistenceTests.productSelectionPreservesOwnerAgentTurns`
  /// This test covers only B02's close-switch-return composition for one incomplete Ticket.
  @Test("B02 closing an incomplete Ticket can return from another Product to that Ticket")
  func b02IncompleteTicketAttentionReturnsToExactTicket() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let sourceProduct = try await registry.createProduct(name: "Incomplete ticket")
    let otherProduct = try await registry.createProduct(name: "Other product")
    let sourceStore = try #require(registry.store(for: sourceProduct.id))
    let profile = try #require(
      try await sourceStore.seedDefaultProfiles(productID: sourceProduct.id).first
    )
    let item = try await sourceStore.createWorkItem(
      productID: sourceProduct.id,
      title: "Finish refinement"
    )
    _ = try await sourceStore.transitionWorkItem(
      id: item.id,
      to: .refining,
      actor: "Test",
      reason: "Keep the Ticket incomplete"
    )
    _ = try await sourceStore.createAgentRun(
      AgentRun(
        productID: sourceProduct.id,
        workItemID: item.id,
        profileID: profile.id,
        status: .awaitingOwner
      )
    )
    let model = AppModel(storeRegistry: registry, selectedProductID: sourceProduct.id)
    await model.reload()

    await model.openTicketAttentions(for: sourceProduct)
    let firstOpen = try #require(model.ticketAttentionNavigationRequest)
    #expect(firstOpen.openWorkItemID == item.id)
    model.consumeTicketAttentionNavigationRequest(id: firstOpen.id)
    #expect(model.ticketAttentionNavigationRequest == nil)

    await model.selectProduct(otherProduct)
    #expect(model.selectedProductID == otherProduct.id)
    await model.openTicketAttentions(for: sourceProduct)
    let returned = try #require(model.ticketAttentionNavigationRequest)
    #expect(model.selectedProductID == sourceProduct.id)
    #expect(returned.productID == sourceProduct.id)
    #expect(returned.workItemIDs == [item.id])
    #expect(returned.openWorkItemID == item.id)
    #expect(
      try await sourceStore.fetchWorkItems(productID: sourceProduct.id)
        .first { $0.id == item.id }?.state == .refining
    )

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  /// Existing partial coverage:
  /// - `productAttentionRoutesSingleBackgroundResult`
  /// - `notificationRouteRoundTrips`
  /// This test covers only C07's cross-Product Chat focus and target-scoped unread clearing.
  @Test("C07 background Chat opens its exact thread and clears only that unread target")
  func c07BackgroundChatRoutesAndClearsOnlyTarget() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(productWorkspacesRootURL: fixture.workspacesURL)
    let sourceProduct = try await registry.createProduct(name: "Chat source")
    let selectedProduct = try await registry.createProduct(name: "Current product")
    let sourceStore = try #require(registry.store(for: sourceProduct.id))
    let recipient = try #require(
      try await sourceStore.seedDefaultProfiles(productID: sourceProduct.id).first
    )
    let firstThread = ProductConversationThread(
      productID: sourceProduct.id,
      recipientProfileID: recipient.id,
      subject: "First reply"
    )
    let secondThread = ProductConversationThread(
      productID: sourceProduct.id,
      recipientProfileID: recipient.id,
      subject: "Second reply"
    )
    for thread in [firstThread, secondThread] {
      _ = try await sourceStore.createConversationThread(
        thread,
        initialMessage: ProductConversationMessage(
          threadID: thread.id,
          authorKind: .owner,
          authorName: "Product owner",
          body: thread.subject
        )
      )
    }
    let firstNotification = OwnerNotification(
      productID: sourceProduct.id,
      kind: .newReply,
      target: OwnerNotificationTarget(kind: .conversationThread, id: firstThread.id),
      title: "First Chat reply",
      body: "Open the first thread"
    )
    let secondNotification = OwnerNotification(
      productID: sourceProduct.id,
      kind: .newReply,
      target: OwnerNotificationTarget(kind: .conversationThread, id: secondThread.id),
      title: "Second Chat reply",
      body: "Keep the second thread unread"
    )
    #expect(try await sourceStore.createOwnerNotification(firstNotification))
    #expect(try await sourceStore.createOwnerNotification(secondNotification))
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: selectedProduct.id,
      ownerNotificationSoundPlayer: NotificationSoundSpy(),
      ownerNotificationSystemNotifier: NotificationSystemSpy()
    )
    await model.reload()

    await model.openOwnerNotification(
      OwnerNotificationPresentation(
        notification: firstNotification,
        productName: sourceProduct.name
      )
    )
    let request = try #require(model.ownerNotificationNavigationRequest)
    #expect(model.selectedProductID == sourceProduct.id)
    #expect(request.target == firstNotification.target)
    let active = try await sourceStore.fetchActiveOwnerNotifications(productID: sourceProduct.id)
    #expect(active.map(\.id) == [secondNotification.id])
    #expect(model.ownerAttentionCount(excluding: nil) == 1)

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  /// Existing partial coverage:
  /// - `ProductExecutionLifecycleTests.productSelectionDoesNotSuspendDelivery`
  /// - `SprintTicketWorkLogHistoryTests.activeTicketQuestionRouting`
  /// This test covers only D03's active-run Product switch and exact Ticket route.
  @Test("D03 switching Products keeps the active question and routes back to its exact Ticket")
  func d03ProductSwitchPreservesActiveQuestionRoute() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let deliveryProduct = try await registry.createProduct(name: "Delivery product")
    let otherProduct = try await registry.createProduct(name: "Other product")
    let deliveryStore = try #require(registry.store(for: deliveryProduct.id))
    let profile = try #require(
      try await deliveryStore.seedDefaultProfiles(productID: deliveryProduct.id).first
    )
    let item = try await deliveryStore.createWorkItem(
      productID: deliveryProduct.id,
      title: "Resolve the active delivery decision"
    )
    let run = try await deliveryStore.createAgentRun(
      AgentRun(
        productID: deliveryProduct.id,
        workItemID: item.id,
        profileID: profile.id,
        status: .awaitingOwner
      )
    )
    _ = try await deliveryStore.appendComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: profile.name,
      body: "Delivery needs one decision.",
      ownerQuestion: TicketOwnerQuestion(
        prompt: "Which fallback should this Ticket use?",
        options: ["Keep the current result", "Use the reviewed fallback"]
      )
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: deliveryProduct.id
    )
    await model.reload()

    await model.selectProduct(otherProduct)
    let durableRun = try #require(
      try await deliveryStore.fetchAgentRuns(productID: deliveryProduct.id)
        .first { $0.id == run.id }
    )
    #expect(durableRun.status == .awaitingOwner)
    let attention = try #require(
      model.ticketAttentionsByProductID[deliveryProduct.id]?.first
    )
    #expect(attention.summary == "Which fallback should this Ticket use?")

    let presentation = OwnerNotificationPresentation(attention: attention)
    await model.openOwnerNotification(
      try #require(
        OwnerNotificationRoute(
          userInfo: OwnerNotificationRoute.userInfo(for: presentation)
        )
      )
    )

    #expect(model.selectedProductID == deliveryProduct.id)
    let request = try #require(model.ownerNotificationNavigationRequest)
    #expect(request.productID == deliveryProduct.id)
    #expect(request.target == OwnerNotificationTarget(kind: .ticket, id: item.id))

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  /// Existing partial coverage:
  /// - `notificationKindControlsSoundAndResolution`
  /// - `reloadAggregatesBackgroundProductAttention`
  /// This test covers only C09's visible suppression, read, resolution, and count deduplication.
  @Test("C09 visible Chat updates deduplicate, become read, and resolve only their target")
  func c09VisibleTargetReadResolutionAndCounts() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Visible Chat")
    let store = try #require(registry.store(for: product.id))
    let sound = NotificationSoundSpy()
    let system = NotificationSystemSpy()
    let coordinator = OwnerNotificationCoordinator(
      storeProvider: { productID in productID == product.id ? store : nil },
      soundPlayer: sound,
      systemNotifier: system
    )
    let target = OwnerNotificationTarget(kind: .conversationThread, id: UUID())
    let firstNotification = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: target,
      title: "Business analyst needs input in Chat",
      body: "Choose the next step."
    )
    let repeatedTargetNotification = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: target,
      title: "Business analyst still needs input in Chat",
      body: "The same conversation is waiting."
    )
    await coordinator.setVisible(productID: product.id, target: target)

    #expect(await coordinator.publish(firstNotification, productName: product.name))
    #expect(await coordinator.publish(repeatedTargetNotification, productName: product.name))
    #expect(coordinator.presentedNotification == nil)
    #expect(system.posted.isEmpty)
    #expect(sound.playCount == 0)
    #expect(
      coordinator.activeTargetCount(
        productID: product.id,
        targetKinds: [.conversationThread]
      ) == 1
    )
    #expect(
      coordinator.unreadTargetCount(
        productID: product.id,
        targetKinds: [.conversationThread]
      ) == 0
    )

    await coordinator.markRead(productID: product.id, target: target)
    #expect(
      coordinator.unreadTargetCount(
        productID: product.id,
        targetKinds: [.conversationThread]
      ) == 0
    )
    await coordinator.resolve(productID: product.id, target: target)
    #expect(
      coordinator.activeTargetCount(
        productID: product.id,
        targetKinds: [.conversationThread]
      ) == 0
    )
    #expect(
      try await store.fetchActiveOwnerNotifications(productID: product.id).isEmpty
    )

    for productStore in registry.allStores {
      await productStore.close()
    }
  }

  @Test("Acceptance entry and approval keep selected-product attention fresh without a product switch")
  func acceptanceApprovalRefreshesSelectedProductAttention() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Fresh attention")
    let store = try #require(registry.store(for: product.id))
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Demo the completed ticket"
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )
    await model.reload()
    #expect(model.ticketAttentionCount(for: product.id) == 0)

    // Delivery finalization transitions the ticket into acceptance, then
    // reloads through the same delegate hook the coordinator uses.
    _ = try await moveToAcceptance(item, in: store)
    await model.deliveryReloadSelectedProductIfCurrent(productID: product.id)

    #expect(model.selectedProductID == product.id)
    let attention = try #require(model.ticketAttentionsByProductID[product.id]?.first)
    #expect(attention.workItemID == item.id)
    #expect(attention.summary == "Ready for demo")

    // Owner approval promotes the ticket out of acceptance, same hook.
    for state: WorkItemState in [.readyToRelease, .released] {
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: "Product owner",
        reason: "Demo approved"
      )
    }
    await model.deliveryReloadSelectedProductIfCurrent(productID: product.id)

    #expect(model.selectedProductID == product.id)
    #expect(model.ticketAttentionCount(for: product.id) == 0)

    // A fresh instance derives the same attention state from durable records.
    let recovered = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )
    await recovered.reload()
    #expect(recovered.ticketAttentionCount(for: product.id) == 0)

    await model.shutdown()
    await recovered.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("A stale ready-for-demo click refreshes and drops instead of navigating")
  func staleAcceptanceAttentionClickDropsNavigation() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Stale attention")
    let store = try #require(registry.store(for: product.id))
    let item = try await moveToAcceptance(
      try await store.createWorkItem(
        productID: product.id,
        title: "Approve elsewhere before clicking"
      ),
      in: store
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id
    )
    await model.reload()
    let attention = try #require(model.ticketAttentionsByProductID[product.id]?.first)
    #expect(attention.summary == "Ready for demo")

    // The ticket is approved while the cached row is still on screen.
    for state: WorkItemState in [.readyToRelease, .released] {
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: state,
        actor: "Product owner",
        reason: "Demo approved"
      )
    }

    await model.openOwnerNotification(
      try #require(
        OwnerNotificationRoute(
          userInfo: OwnerNotificationRoute.userInfo(
            for: OwnerNotificationPresentation(attention: attention)
          )
        )
      )
    )

    #expect(model.ownerNotificationNavigationRequest == nil)
    #expect(model.ticketAttentionNavigationRequest == nil)
    #expect(model.ticketAttentionCount(for: product.id) == 0)

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("A ticket question resolves when its run stops awaiting the owner")
  func runLeavingAwaitingOwnerResolvesTicketQuestion() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Run resolution")
    let store = try #require(registry.store(for: product.id))
    let profile = try #require(
      try await store.seedDefaultProfiles(productID: product.id).first
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Answer the delivery question"
    )
    let run = try await store.createAgentRun(
      AgentRun(
        productID: product.id,
        workItemID: item.id,
        profileID: profile.id,
        status: .awaitingOwner
      )
    )
    let questionRow = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .ticket, id: item.id),
      title: "\(item.key) needs your input",
      body: "Choose the delivery behavior."
    )
    #expect(try await store.createOwnerNotification(questionRow))
    let system = NotificationSystemSpy()
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: NotificationSoundSpy(),
      ownerNotificationSystemNotifier: system
    )
    await model.reload()
    // The load sweep keeps the question while the run awaits the owner.
    #expect(
      try await store.fetchActiveOwnerNotifications(productID: product.id)
        .map(\.id) == [questionRow.id]
    )

    let updated = try await store.updateAgentRun(id: run.id, status: .completed)
    await model.deliveryAgentRunDidUpdate(previous: run, updated: updated)

    #expect(
      try await store.fetchActiveOwnerNotifications(productID: product.id).isEmpty
    )
    #expect(system.dismissedIDs.contains(questionRow.id))

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("The load sweep retires ended waits and keeps owed decisions")
  func loadSweepRetiresEndedWaitsIdempotently() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Sweep product")
    let store = try #require(registry.store(for: product.id))

    // A plan landed while this epic's question row stayed active.
    let landedEpic = try await store.createEpic(
      productID: product.id,
      outcome: "Land the plan while the question row is stuck"
    )
    let landedSession = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: landedEpic.id
    )
    _ = try await store.completeTicketSuggestionSession(
      sessionID: landedSession.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "T1",
          title: "Deliver the landed plan",
          body: "The plan landed without resolving the question row.",
          acceptanceCriteria: ["The stale row retires on load"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "This fixture reproduces the stuck epic row."
        )
      ]
    )
    let stuckEpicRow = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .epic, id: landedEpic.id),
      title: "Epic needs your input",
      body: "This wait ended when the plan landed."
    )
    #expect(try await store.createOwnerNotification(stuckEpicRow))

    // A failed plan still owes the owner a retry decision.
    let failedEpic = try await store.createEpic(
      productID: product.id,
      outcome: "Keep the retry decision visible"
    )
    let failedSession = try await store.beginTicketSuggestionSession(
      productID: product.id,
      epicID: failedEpic.id
    )
    try await store.failTicketSuggestionSession(
      sessionID: failedSession.id,
      message: "Planning timed out."
    )
    let retryRow = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .epic, id: failedEpic.id),
      title: "Planning needs another try",
      body: "Planning timed out."
    )
    #expect(try await store.createOwnerNotification(retryRow))

    // An unanswered refinement question keeps its row.
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Answer the refinement question"
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .agent,
      authorName: "Business analyst",
      body: "I need one decision.",
      ownerQuestion: TicketOwnerQuestion(
        prompt: "Which boundary applies?",
        options: ["Local", "Repository"]
      )
    )
    let questionRow = OwnerNotification(
      productID: product.id,
      kind: .needsInput,
      target: OwnerNotificationTarget(kind: .ticket, id: item.id),
      title: "\(item.key) needs your input",
      body: "Which boundary applies?"
    )
    #expect(try await store.createOwnerNotification(questionRow))

    let coordinator = OwnerNotificationCoordinator(
      storeProvider: { productID in
        productID == product.id ? store : nil
      },
      soundPlayer: NotificationSoundSpy(),
      systemNotifier: NotificationSystemSpy()
    )
    await coordinator.load(products: [product])

    let expectedActiveIDs: Set<UUID> = [retryRow.id, questionRow.id]
    #expect(
      Set(
        try await store.fetchActiveOwnerNotifications(productID: product.id)
          .map(\.id)
      ) == expectedActiveIDs
    )
    #expect(
      Set(coordinator.notifications(productID: product.id).map(\.id))
        == expectedActiveIDs
    )

    // The sweep is idempotent: a repeat load changes nothing.
    await coordinator.load(products: [product])
    #expect(
      Set(
        try await store.fetchActiveOwnerNotifications(productID: product.id)
          .map(\.id)
      ) == expectedActiveIDs
    )

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Making a ticket target visible marks its pending updates read")
  func visibleTicketTargetMarksExistingUpdatesRead() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Sheet visibility")
    let store = try #require(registry.store(for: product.id))
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Read the reply from the sprint board"
    )
    let reply = OwnerNotification(
      productID: product.id,
      kind: .newReply,
      target: OwnerNotificationTarget(kind: .ticket, id: item.id),
      title: "Implementer replied on \(item.key)",
      body: "The requested change is ready."
    )
    #expect(try await store.createOwnerNotification(reply))
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: NotificationSoundSpy(),
      ownerNotificationSystemNotifier: NotificationSystemSpy()
    )
    await model.reload()
    #expect(
      try await store.fetchActiveOwnerNotifications(productID: product.id)
        .map(\.id) == [reply.id]
    )

    // The sprint ticket sheet registers the same visibility as the backlog
    // ticket sheet, so reading a ticket anywhere counts as reading it.
    await model.setOwnerNotificationTargetVisible(
      productID: product.id,
      target: OwnerNotificationTarget(kind: .ticket, id: item.id)
    )

    #expect(
      try await store.fetchActiveOwnerNotifications(productID: product.id).isEmpty
    )
    model.clearOwnerNotificationTargetVisible(
      productID: product.id,
      target: OwnerNotificationTarget(kind: .ticket, id: item.id)
    )

    await model.shutdown()
    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("A system notification click refreshes stale caches before deciding")
  func staleSystemNotificationClickRefreshesBeforeGuard() async throws {
    let fixture = try TicketAttentionFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Stale cache click")
    let store = try #require(registry.store(for: product.id))
    let epic = try await store.createEpic(
      productID: product.id,
      outcome: "Open the plan from a cold notification"
    )
    let model = AppModel(
      storeRegistry: registry,
      selectedProductID: product.id,
      ownerNotificationSoundPlayer: NotificationSoundSpy(),
      ownerNotificationSystemNotifier: NotificationSystemSpy()
    )
    await model.reload()

    // The notification lands after the caches loaded, so the click arrives
    // with a stale in-memory view.
    let notification = OwnerNotification(
      productID: product.id,
      kind: .refinementComplete,
      target: OwnerNotificationTarget(kind: .epic, id: epic.id),
      title: "Plan ready for review",
      body: "The proposed tickets are ready."
    )
    #expect(try await store.createOwnerNotification(notification))

    await model.openOwnerNotification(
      try #require(
        OwnerNotificationRoute(
          userInfo: OwnerNotificationRoute.userInfo(
            for: OwnerNotificationPresentation(
              notification: notification,
              productName: product.name
            )
          )
        )
      )
    )

    let request = try #require(model.ownerNotificationNavigationRequest)
    #expect(request.target == notification.target)

    await model.shutdown()
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

@MainActor
private final class DecliningNotificationSystemNotifier: OwnerNotificationSystemNotifying {
  private(set) var postCount = 0

  func post(_ presentation: OwnerNotificationPresentation) {
    postCount += 1
  }

  func dismiss(ids: [UUID]) {}
}
