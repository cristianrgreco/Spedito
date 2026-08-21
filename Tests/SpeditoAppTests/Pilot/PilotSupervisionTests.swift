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

  /// Run 9 was the first pilot run to reach a demo and accept a ticket, and its
  /// evidence database was 4KB with no schema in it. The capture copied only the
  /// database file, and everything the run committed was still in the
  /// write-ahead log.
  @Test("Captured evidence contains what the run committed")
  func capturedEvidenceContainsCommittedRows() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }

    // Capture while the databases are still open, which is when a live run does
    // it: the driver has just finished and the application is still up.
    fixture.journal.captureEvidence(
      productWorkspacesRootURL: fixture.workspacesURL,
      codexThreadIDs: []
    )

    let captured = fixture.journal.bundleURL
      .appendingPathComponent("evidence", isDirectory: true)
      .appendingPathComponent("\(fixture.productID.uuidString)-product.sqlite")
    #expect(FileManager.default.fileExists(atPath: captured.path))

    let reopened = try SQLiteStore(url: captured)
    let items = try await reopened.fetchWorkItems(productID: fixture.productID)
    #expect(items.map(\.id) == [fixture.workItemID])
    let runs = try await reopened.fetchAgentRuns(productID: fixture.productID)
    #expect(runs.map(\.id) == [fixture.runID])
    await reopened.close()
  }

  /// Run 9 sat for thirty minutes with a running agent that reported nothing and
  /// the pilot filed nothing at all: `stalledRuns` only looks at queued runs,
  /// and `deadEnds` skips any ticket offering an action, which a running run
  /// always does because it offers **Stop**.
  @Test("A running agent that reports nothing is reported")
  func silentRunningAgentIsReported() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }
    _ = try await fixture.store.updateAgentRun(id: fixture.runID, status: .running)

    func findings(lastHeard: Date) async throws -> [PilotJournal.Finding] {
      _ = try await fixture.store.recordAgentRunActivity(
        id: fixture.runID,
        activity: CodexLiveActivity(text: "Reviewing the converter", kind: .inspecting),
        at: lastHeard
      )
      let model = AppModel(
        storeRegistry: fixture.registry,
        selectedProductID: fixture.productID
      )
      await model.reload()
      let snapshot = PilotSnapshotRenderer.render(model)
      return PilotInvariants.check(
        PilotInvariants.Context(
          snapshot: snapshot,
          brief: fixture.brief,
          unchangedSince: [:],
          anyRunIsRunning: true
        ),
        model: model
      )
    }

    // A turn that reported a moment ago is working, not hung.
    #expect(try await findings(lastHeard: Date()).isEmpty)

    let silent = try await findings(
      lastHeard: Date().addingTimeInterval(-PilotInvariants.silentRunTolerance - 60)
    )
    let reported = try #require(silent.first { $0.category == .stalled })
    #expect(reported.title.contains("reported nothing while still running"))
    #expect(reported.evidence.contains("Reviewing the converter"))
  }

  /// The check this replaced asked whether every run had an empty
  /// `lastActivityText`, which is a transient activity summary rather than the
  /// work log, and is never empty on a run that finished. It could not fail.
  @Test("A released ticket with no handoff in its work log is reported")
  func releasedTicketWithoutHandoffIsReported() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }
    try await fixture.releaseTheWorkItem()
    // A real completed run always carries activity text. The check this replaced
    // only fired when every run's was empty, so setting it here is what makes
    // this test distinguish the two.
    _ = try await fixture.store.recordAgentRunActivity(
      id: fixture.runID,
      activity: CodexLiveActivity(text: "Finishing the converter", kind: .changingFiles)
    )
    _ = try await fixture.store.updateAgentRun(id: fixture.runID, status: .completed)

    func findings() async -> [PilotJournal.Finding] {
      let model = AppModel(
        storeRegistry: fixture.registry,
        selectedProductID: fixture.productID
      )
      await model.reload()
      return await PilotInvariants.completionHandoffs(model: model)
    }

    // Spedito's own notes are not a handoff: the contract is that the assigned
    // team member records the outcome dependants are given.
    _ = try await fixture.store.appendComment(
      workItemID: fixture.workItemID,
      authorKind: .system,
      authorName: "Spedito",
      body: "The product owner accepted this work."
    )
    let missing = await findings()
    #expect(missing.count == 1)
    #expect(missing.first?.title.contains("left no completion handoff") == true)

    _ = try await fixture.store.appendComment(
      workItemID: fixture.workItemID,
      authorKind: .agent,
      authorName: "Implementer",
      body: """
        I delivered the converter page and its offline behaviour. Dependants may
        assume the page is served from the repository root with no build step.
        """
    )
    #expect(await findings().isEmpty)
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
  let workspacesURL: URL
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
    workspacesURL = directoryURL.appendingPathComponent(
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

  /// Walks the work item through every transition the workflow policy allows,
  /// because `released` is only reachable from `readyToRelease`.
  func releaseTheWorkItem() async throws {
    let route: [WorkItemState] = [
      .refining, .ready, .queued, .running, .integrating, .verifying, .acceptance,
      .readyToRelease, .released,
    ]
    for state in route {
      _ = try await store.transitionWorkItem(
        id: workItemID,
        to: state,
        actor: "Product owner",
        reason: "Walking the ticket to \(state.rawValue)"
      )
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
