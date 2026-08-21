import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

/// The pilot relaunches Spedito mid-delivery, which replaces the application it
/// is watching. A live run held the pre-relaunch application for the rest of the
/// run and reported its frozen board: three queued runs, no available actions,
/// and a stalled sprint, while the database recorded two candidates, two tech
/// lead reviews, and delivery continuing normally in the reopened application.
///
/// These tests are deterministic and always run. The pilot itself is gated
/// behind `SPEDITO_PILOT=1`, but the rule it depends on must not be.
@Suite("Pilot supervision", .serialized)
@MainActor
struct PilotSupervisionTests {
  @Test("Watching a turn reports the application that is open now")
  func supervisionTurnReadsTheCurrentApplication() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }
    let driver = PilotDriver(
      brief: fixture.brief,
      journal: fixture.journal,
      workspace: fixture.workspace,
      deadline: Date().addingTimeInterval(60)
    )

    let closing = AppModel(
      storeRegistry: fixture.registry,
      selectedProductID: fixture.productID
    )
    await closing.reload()
    driver.adopt(model: closing, registry: fixture.registry)

    let before = try #require(await driver.superviseTick(1))
    #expect(before.board.tickets.first?.latestRunStatus == .queued)

    // Delivery moves the run on while the owner is quitting and reopening.
    _ = try await fixture.store.updateAgentRun(id: fixture.runID, status: .running)

    // Reopening installs a new application. The closed one keeps the board it
    // had at shutdown, so a turn that still reads it reports a frozen sprint.
    let reopened = AppModel(
      storeRegistry: fixture.registry,
      selectedProductID: fixture.productID
    )
    await reopened.reload()
    driver.adopt(model: reopened)

    #expect(PilotSnapshotRenderer.render(closing).tickets.first?.latestRunStatus == .queued)

    let after = try #require(await driver.superviseTick(2))
    #expect(after.board.tickets.first?.latestRunStatus == .running)
    #expect(after.outcome == .keepWatching)
  }

  @Test("A turn with no application open reports nothing rather than stale state")
  func supervisionTurnWithoutApplicationReportsNothing() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }
    let driver = PilotDriver(
      brief: fixture.brief,
      journal: fixture.journal,
      workspace: fixture.workspace,
      deadline: Date().addingTimeInterval(60)
    )

    #expect(await driver.superviseTick(1) == nil)
  }

  @Test("Every ticket reaching a terminal state ends the watch")
  func supervisionTurnDetectsFinishedDelivery() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }
    _ = try await fixture.store.transitionWorkItem(
      id: fixture.workItemID,
      to: .cancelled,
      actor: "Product owner",
      reason: "Dropped the ticket from the sprint"
    )
    let driver = PilotDriver(
      brief: fixture.brief,
      journal: fixture.journal,
      workspace: fixture.workspace,
      deadline: Date().addingTimeInterval(60)
    )
    let model = AppModel(
      storeRegistry: fixture.registry,
      selectedProductID: fixture.productID
    )
    await model.reload()
    driver.adopt(model: model, registry: fixture.registry)

    let turn = try #require(await driver.superviseTick(1))
    #expect(turn.outcome == .everyTicketFinished)
  }
}

private enum PilotSupervisionFixtureError: Error {
  case missingProductDatabase
  case missingTeam
  case missingBrief
}

/// A product database, one queued run, and a scratch journal, with nothing that
/// reaches Codex, Git, or the product owner's real products.
@MainActor
private struct PilotSupervisionFixture {
  let directoryURL: URL
  let registry: ProductStoreRegistry
  let store: SQLiteStore
  let workspace: PilotWorkspace
  let journal: PilotJournal
  let brief: PilotBrief
  let productID: UUID
  let workItemID: UUID
  let runID: UUID

  init() async throws {
    directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spedito-pilot-supervision-\(UUID())",
      isDirectory: true
    )
    let workspacesURL = directoryURL.appendingPathComponent(
      "Product Workspaces",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
    let runsURL = directoryURL.appendingPathComponent("runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runsURL, withIntermediateDirectories: true)

    registry = try ProductStoreRegistry(productWorkspacesRootURL: workspacesURL)
    let product = try await registry.createProduct(name: "Unit converter")
    productID = product.id
    guard let productStore = registry.store(for: product.id) else {
      throw PilotSupervisionFixtureError.missingProductDatabase
    }
    store = productStore
    guard let profile = try await store.seedDefaultProfiles(productID: product.id).first
    else { throw PilotSupervisionFixtureError.missingTeam }
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Convert everyday metric and imperial units"
    )
    workItemID = item.id
    let run = AgentRun(
      productID: product.id,
      workItemID: item.id,
      profileID: profile.id,
      status: .queued
    )
    _ = try await store.createAgentRun(run)
    runID = run.id

    workspace = try PilotWorkspace(rootURL: directoryURL, runsURL: runsURL)
    journal = try PilotJournal(rootURL: runsURL, briefID: "supervision")
    guard let catalogBrief = PilotBriefCatalog.brief(id: "static-converter") else {
      throw PilotSupervisionFixtureError.missingBrief
    }
    brief = catalogBrief
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
