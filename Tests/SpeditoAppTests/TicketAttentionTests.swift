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

  @Test("Notification routing preserves the product and ticket destination")
  func notificationRouteRoundTrips() throws {
    let attention = TicketAttention(
      id: UUID(),
      productID: UUID(),
      productName: "Routing product",
      sprintID: UUID(),
      workItemID: UUID(),
      itemKey: "T12",
      title: "Route the notification",
      summary: "Choose an option",
      updatedAt: Date()
    )

    let route = try #require(
      TicketAttentionNotificationRoute(
        userInfo: TicketAttentionNotificationRoute.userInfo(for: attention)
      )
    )

    #expect(route.productID == attention.productID)
    #expect(route.workItemID == attention.workItemID)
    #expect(TicketAttentionNotificationRoute(userInfo: [:]) == nil)
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
