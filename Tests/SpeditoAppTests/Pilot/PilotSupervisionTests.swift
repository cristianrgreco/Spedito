import Foundation
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

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

  /// Runs 7 and 8 both reported a ticket waiting on its own prerequisites as a
  /// dead end and a stall. The dispatcher holds a dependant back until its
  /// direct prerequisites reach done, and the board names them, so that is the
  /// system working. The noise cost real triage time.
  @Test("A ticket waiting on its prerequisites is not reported as stranded")
  func prerequisiteBlockedTicketIsNotAFinding() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }

    let blocker = try await fixture.store.createWorkItem(
      productID: fixture.productID,
      title: "Establish the delivery setup"
    )
    let dependant = try #require(
      try await fixture.store.fetchWorkItems(productID: fixture.productID)
        .first { $0.id == fixture.workItemID }
    )
    try await fixture.store.replaceWorkItemDependencies(
      for: dependant,
      dependsOnWorkItemIDs: [blocker.id]
    )
    // Queued is the state a dependant waits in, and it offers the owner nothing,
    // which is exactly what the dead-end rule looks for.
    for state in [WorkItemState.refining, .ready, .queued] {
      _ = try await fixture.store.transitionWorkItem(
        id: fixture.workItemID,
        to: state,
        actor: "Sprint scheduler",
        reason: "Authorized by the sprint"
      )
    }

    let model = AppModel(
      storeRegistry: fixture.registry,
      selectedProductID: fixture.productID
    )
    await model.reload()
    let snapshot = PilotSnapshotRenderer.render(model)
    let blocked = try #require(snapshot.tickets.first { $0.key != blocker.key })
    #expect(blocked.waitingOnPrerequisites == [blocker.key])
    #expect(blocked.availableActions.isEmpty)
    #expect(blocked.latestRunStatus == .queued)
    #expect(PilotSnapshotRenderer.describe(snapshot).contains("waiting-on=\(blocker.key)"))

    let findings = PilotInvariants.check(
      PilotInvariants.Context(
        snapshot: snapshot,
        brief: fixture.brief,
        unchangedSince: Dictionary(
          uniqueKeysWithValues: snapshot.tickets.map {
            ($0.key, Date().addingTimeInterval(-3600))
          }
        ),
        anyRunIsRunning: false
      ),
      model: model
    )
    #expect(!findings.contains { $0.title.contains(blocked.key) })
  }

  /// A live native macOS run put this on the owner's screen and the pilot said
  /// nothing, because its leaked-diagnostic check looked for a fixed list of
  /// markers and none of them appeared.
  @Test("A failure built from chained internal errors is reported")
  func chainedFailureTextIsReported() {
    let chained = """
      The delivery agent returned an invalid execution result: The demo could \
      not be prepared safely: browser paths must be a loopback URL path \
      beginning with “/”.
      """
    let violations = PilotConventions.checkFailureText(chained)
    #expect(violations.contains { $0.rule.contains("not a chain of internal errors") })
    #expect(violations.contains { $0.rule.contains("raw technical evidence") })

    // One concise explanation is what the contract asks for.
    #expect(
      PilotConventions.checkFailureText(
        "Reconnect this product to GitHub before this ticket can finish review."
      ).isEmpty
    )
    #expect(PilotConventions.checkFailureText(nil).isEmpty)
  }

  /// The pilot recorded this title as an ordinary observation and filed nothing:
  /// its convention checks read titles and summaries as one pool of prose, and
  /// nothing in that pool objected to a full stop in the middle.
  @Test("An alert title that glues a sentence to a clause is reported")
  func gluedAlertTitleIsReported() {
    let live = """
      A native Mac app for jotting short notes that stay there when I reopen it. \
      needs your input
      """
    let violations = PilotConventions.checkAlertTitles([live])
    #expect(violations.count == 1)
    #expect(violations.first?.rule.contains("must read as one phrase") == true)

    // The other titles the same run produced are correct and must stay silent,
    // including one carrying a version number.
    #expect(
      PilotConventions.checkAlertTitles([
        "T1 needs your input",
        "Private local notes for Mac plan ready for review",
        "Codex 0.148.0 is connected",
        "Ready",
      ]).isEmpty
    )
  }

  /// A live run rendered `actions=[Open demo, Accept, Accept]`, because a
  /// candidate that is ready for demo and a ticket sitting in acceptance each
  /// contribute Accept. Spedito shows one button. A board line that shows two
  /// invites a finding against a defect that does not exist.
  @Test("A ticket offering Accept from two rules shows it once")
  func availableActionsAreNotDuplicated() {
    let item = WorkItem(
      productID: UUID(),
      key: "T1",
      title: "Establish the native Mac app delivery setup",
      state: .acceptance
    )
    let candidate = CandidateRevision(
      productID: item.productID,
      sprintID: UUID(),
      sprintItemID: UUID(),
      workItemID: item.id,
      implementationRunID: UUID(),
      version: 1,
      branchName: "ticket/T1",
      baseSHA: "base",
      headSHA: "head",
      worktreePath: "/tmp/ticket-T1",
      status: .readyForDemo,
      commitCount: 1,
      executionResultJSON: "{}"
    )
    let actions = PilotSnapshotRenderer.availableActions(
      for: item,
      run: nil,
      candidate: candidate,
      needsInput: false
    )
    #expect(actions == ["Open demo", "Accept"])
  }

  /// `run=running` alone cannot tell an agent that is working from one whose
  /// turn ended without Spedito noticing. Triage had to wait out the ten-minute
  /// silent-run tolerance to find out which, on a harness whose job is to report
  /// facts rather than invite guesses.
  @Test("The board says what a running agent last reported and how long ago")
  func boardLineCarriesRunActivity() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }
    _ = try await fixture.store.updateAgentRun(id: fixture.runID, status: .running)
    _ = try await fixture.store.recordAgentRunActivity(
      id: fixture.runID,
      activity: CodexLiveActivity(text: "Verifying build and demo readiness", kind: .inspecting),
      at: Date().addingTimeInterval(-90)
    )
    let model = AppModel(
      storeRegistry: fixture.registry,
      selectedProductID: fixture.productID
    )
    await model.reload()

    let snapshot = PilotSnapshotRenderer.render(model)
    let ticket = try #require(snapshot.tickets.first)
    #expect(ticket.lastActivityText == "Verifying build and demo readiness")
    let quiet = try #require(ticket.quietForSeconds)
    #expect(quiet >= 88 && quiet <= 95)

    let described = PilotSnapshotRenderer.describe(snapshot)
    #expect(described.contains(#"last="Verifying build and demo readiness""#))
    #expect(described.contains("quiet=\(quiet)s"))
  }

  /// Establishing whether a hung ticket's agent had actually finished cost the
  /// better part of a session: find the rollout, attribute it to a ticket, read
  /// its turn events. Attributing a thread to the wrong ticket inverted a
  /// conclusion once before it was checked.
  @Test("A silent run's finding says what Codex recorded for its thread")
  func silentRunFindingCarriesTheCodexVerdict() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-pilot-rollouts-\(UUID())", isDirectory: true)
    let day = root.appendingPathComponent("2026/08/21", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func write(_ threadID: String, events: [(String, String)]) throws {
      let lines = events.map { at, kind in
        #"{"timestamp":"2026-08-21T\#(at).000Z","payload":{"type":"\#(kind)"}}"#
      }
      try lines.joined(separator: "\n").write(
        to: day.appendingPathComponent("rollout-2026-08-21T18-31-46-\(threadID).jsonl"),
        atomically: true,
        encoding: .utf8
      )
    }

    // The live shape: a turn that started and finished while Spedito kept
    // reporting a working agent.
    try write(
      "finished-thread",
      events: [("18:31:46", "task_started"), ("18:32:52", "task_complete")]
    )
    #expect(
      PilotCodexRollout.lastTurnSummary(
        threadID: "finished-thread",
        sessionsRootURL: root
      ) == "Codex says this thread's last turn completed at 18:32:52Z."
    )

    // An agent that really is still working must not be described as finished.
    try write(
      "working-thread",
      events: [("18:31:46", "task_complete"), ("18:33:00", "task_started")]
    )
    #expect(
      PilotCodexRollout.lastTurnSummary(
        threadID: "working-thread",
        sessionsRootURL: root
      ) == "Codex says this thread's last turn started at 18:33:00Z and has not ended."
    )

    // No rollout is not evidence of no turn, so it must not read as a verdict.
    #expect(
      PilotCodexRollout.lastTurnSummary(threadID: "absent-thread", sessionsRootURL: root) == nil
    )
    #expect(PilotCodexRollout.lastTurnSummary(threadID: "", sessionsRootURL: root) == nil)
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

  /// An owner who asks for something new mid-sprint puts tickets in the backlog
  /// that the running sprint was never going to deliver. Waiting for those to
  /// reach a terminal state would burn the rest of the budget after the sprint
  /// had actually finished — and the mid-sprint request is a journey the brief
  /// catalog has claimed to exercise since it was written.
  @Test("Delivery is finished when the sprint's tickets are, not the whole backlog")
  func finishedDeliveryIgnoresTicketsOutsideTheSprint() async throws {
    let fixture = try await PilotSupervisionFixture()
    defer { fixture.remove() }

    let laterIdea = try await fixture.store.createWorkItem(
      productID: fixture.productID,
      title: "Search what I have saved"
    )
    let profile = try #require(
      try await fixture.store.fetchAgentProfiles(productID: fixture.productID)
        .first { $0.role.canOwnDelivery }
    )
    // A sprint will not start on a ticket with no acceptance criterion, which is
    // the product rule working.
    let sprintTicket = try await fixture.store.fetchWorkItem(id: fixture.workItemID)
    _ = try await fixture.store.updateWorkItem(
      id: sprintTicket.id,
      title: sprintTicket.title,
      type: sprintTicket.type,
      body: sprintTicket.body,
      acceptanceCriteria: ["Converts metric and imperial units both ways."],
      priority: sprintTicket.priority,
      customFields: sprintTicket.customFields
    )
    let draft = try await fixture.store.saveDraftSprint(
      productID: fixture.productID,
      goal: "Convert everyday units",
      tokenBudgetLimit: nil,
      items: [
        SprintDraftItemInput(
          workItemID: fixture.workItemID,
          implementerProfileID: profile.id
        )
      ]
    )
    _ = try await fixture.store.startSprint(id: draft.sprint.id)
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

    // The later idea is still sitting in the backlog, and that is correct.
    #expect(model.workItems.contains { $0.id == laterIdea.id })
    let turn = try #require(await driver.superviseTick(1))
    #expect(turn.outcome == .everyTicketFinished)
  }

  /// The pilot's relaunch carried the `ProductStoreRegistry` across, so the quit
  /// and reopen it claims to perform left every SQLite connection open. Durable
  /// state that only survives because the connection never closed would have
  /// passed a relaunch check, which makes every post-relaunch finding suspect in
  /// the direction that is hardest to notice.
  @Test("Quitting Spedito closes the product databases it had open")
  func quittingClosesTheProductDatabases() async throws {
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
    #expect(try await fixture.store.fetchWorkItems(productID: fixture.productID).count == 1)

    await driver.quit(closing, registry: fixture.registry)

    // The connection the closed application held is gone, the way it would be if
    // the process had ended.
    await #expect(throws: PersistenceError.self) {
      _ = try await fixture.store.fetchWorkItems(productID: fixture.productID)
    }

    // And the ticket is on disk, so reopening reads durable state rather than a
    // connection that was never closed.
    let reopenedRegistry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let reopenedStore = try #require(reopenedRegistry.store(for: fixture.productID))
    let items = try await reopenedStore.fetchWorkItems(productID: fixture.productID)
    #expect(items.map(\.id) == [fixture.workItemID])
    await reopenedStore.close()
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
    // Older than every tolerance, so a test can exercise the stall checks
    // without waiting them out.
    let anHourAgo = Date().addingTimeInterval(-3600)
    let run = AgentRun(
      productID: product.id,
      workItemID: item.id,
      profileID: profile.id,
      status: .queued,
      createdAt: anHourAgo,
      updatedAt: anHourAgo
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
