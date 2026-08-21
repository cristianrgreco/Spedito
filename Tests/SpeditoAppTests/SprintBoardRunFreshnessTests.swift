import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

/// The sprint board projects durable run state. A live pilot run found the
/// board reporting every ticket as queued for ten minutes while the database
/// recorded one run completing twice and another actively running, because run
/// updates only refreshed the board when owner attention was involved.
@Suite("Sprint board run freshness", .serialized)
@MainActor
struct SprintBoardRunFreshnessTests {
  @Test("A run starting work reaches the board")
  func startingRunRefreshesBoard() async throws {
    let fixture = try SprintBoardRunFreshnessFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Unit converter")
    let store = try #require(registry.store(for: product.id))
    let profile = try #require(
      try await store.seedDefaultProfiles(productID: product.id).first
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Convert everyday metric and imperial units"
    )
    let queued = AgentRun(
      productID: product.id,
      workItemID: item.id,
      profileID: profile.id,
      status: .queued
    )
    _ = try await store.createAgentRun(queued)

    let model = AppModel(storeRegistry: registry, selectedProductID: product.id)
    await model.reload()
    #expect(model.runs.first { $0.id == queued.id }?.status == .queued)

    let running = try await store.updateAgentRun(id: queued.id, status: .running)
    await model.deliveryAgentRunDidUpdate(previous: queued, updated: running)

    #expect(model.runs.first { $0.id == queued.id }?.status == .running)
  }

  @Test("A run finishing work reaches the board with any run started alongside it")
  func completedRunAndNewRunReachBoard() async throws {
    let fixture = try SprintBoardRunFreshnessFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "Unit converter")
    let store = try #require(registry.store(for: product.id))
    let profile = try #require(
      try await store.seedDefaultProfiles(productID: product.id).first
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Design the conversion experience"
    )
    let implementation = AgentRun(
      productID: product.id,
      workItemID: item.id,
      profileID: profile.id,
      status: .running
    )
    _ = try await store.createAgentRun(implementation)

    let model = AppModel(storeRegistry: registry, selectedProductID: product.id)
    await model.reload()
    #expect(model.runs.count == 1)

    // Delivery completes the implementation and starts the review run in the
    // database. The board has never seen the review run, which is the strongest
    // form of staleness: the owner is not shown that the work exists.
    let completed = try await store.updateAgentRun(
      id: implementation.id,
      status: .completed
    )
    let review = AgentRun(
      productID: product.id,
      workItemID: item.id,
      profileID: profile.id,
      status: .running
    )
    _ = try await store.createAgentRun(review)
    await model.deliveryAgentRunDidUpdate(previous: implementation, updated: completed)

    #expect(model.runs.first { $0.id == implementation.id }?.status == .completed)
    #expect(model.runs.first { $0.id == review.id }?.status == .running)
  }

  @Test("A run update in a background product does not reload the selected board")
  func backgroundProductUpdateDoesNotReloadSelectedProduct() async throws {
    let fixture = try SprintBoardRunFreshnessFixture()
    defer { fixture.remove() }
    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let background = try await registry.createProduct(name: "Background product")
    let selected = try await registry.createProduct(name: "Selected product")
    let backgroundStore = try #require(registry.store(for: background.id))
    let profile = try #require(
      try await backgroundStore.seedDefaultProfiles(productID: background.id).first
    )
    let item = try await backgroundStore.createWorkItem(
      productID: background.id,
      title: "Work in another product"
    )
    let queued = AgentRun(
      productID: background.id,
      workItemID: item.id,
      profileID: profile.id,
      status: .queued
    )
    _ = try await backgroundStore.createAgentRun(queued)

    let model = AppModel(storeRegistry: registry, selectedProductID: selected.id)
    await model.reload()

    let running = try await backgroundStore.updateAgentRun(id: queued.id, status: .running)
    await model.deliveryAgentRunDidUpdate(previous: queued, updated: running)

    #expect(model.selectedProductID == selected.id)
    #expect(model.runs.isEmpty)
  }
}

private struct SprintBoardRunFreshnessFixture {
  let directoryURL: URL
  let workspacesURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-board-run-freshness-\(UUID())",
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
