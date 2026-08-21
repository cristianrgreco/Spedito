import Foundation
import SpeditoCore
import Testing

@testable import SpeditoApp

/// Drives Spedito end to end as a product owner would, against real Codex, real
/// Git, and real demo launching.
///
/// This is deliberately not part of the default suite: it costs real Codex usage
/// and takes minutes to hours. `swift test` skips it unless `SPEDITO_PILOT=1`.
/// Opt-in so `swift test` stays deterministic, fast, and free of real Codex
/// usage. `scripts/pilot.sh` sets this.
nonisolated let pilotIsEnabled = ProcessInfo.processInfo.environment["SPEDITO_PILOT"] == "1"

@Suite("Pilot", .serialized)
@MainActor
struct PilotRunTests {
  @Test(
    "Owner drives a product from request to accepted delivery",
    .enabled(if: pilotIsEnabled)
  )
  func pilotRun() async throws {
    let environment = ProcessInfo.processInfo.environment
    let briefID = environment["SPEDITO_PILOT_BRIEF"] ?? "static-converter"
    let brief = try #require(
      PilotBriefCatalog.brief(id: briefID),
      "Unknown brief \(briefID). Known: \(PilotBriefCatalog.all.map(\.id).joined(separator: ", "))"
    )
    let budget = TimeInterval(environment["SPEDITO_PILOT_BUDGET_SECONDS"] ?? "") ?? 1800

    let workspace = try PilotWorkspace()
    defer { workspace.remove() }
    let journal = try PilotJournal(rootURL: workspace.runsURL, briefID: brief.id)
    journal.record(
      .runStarted,
      "\(brief.productName): \(brief.outcome)",
      detail: "budget \(Int(budget))s, root \(workspace.rootURL.path)"
    )

    let driver = PilotDriver(
      brief: brief,
      journal: journal,
      workspace: workspace,
      deadline: Date().addingTimeInterval(budget)
    )

    do {
      try await driver.run()
    } catch {
      journal.record(.note, "Run ended early", detail: "\(error)")
    }

    journal.captureEvidence(
      productWorkspacesRootURL: workspace.productWorkspacesURL,
      codexThreadIDs: driver.observedThreadIDs
    )
    journal.record(
      .runFinished,
      "\(journal.currentFindings.count) finding(s)",
      detail: journal.bundleURL.path
    )

    // The pilot reports; it does not fail the build. Findings are triaged from
    // the bundle, because a real agent occasionally produces a legitimate
    // outcome the harness did not anticipate.
    print("Pilot bundle: \(journal.bundleURL.path)")
  }
}

/// An isolated Application Support root so a pilot run can never touch the
/// product owner's real products.
struct PilotWorkspace {
  let rootURL: URL
  let productWorkspacesURL: URL
  let runsURL: URL

  init() throws {
    let base =
      ProcessInfo.processInfo.environment["SPEDITO_PILOT_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
      ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("spedito-pilot", isDirectory: true)
    rootURL = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    productWorkspacesURL = rootURL.appendingPathComponent(
      "Product Workspaces",
      isDirectory: true
    )
    runsURL =
      ProcessInfo.processInfo.environment["SPEDITO_PILOT_RUNS"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? base.appendingPathComponent("runs", isDirectory: true)
    try FileManager.default.createDirectory(
      at: productWorkspacesURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: runsURL,
      withIntermediateDirectories: true
    )
  }

  /// A scratch root chosen by the caller, for deterministic tests of the
  /// harness itself. A live run always uses the environment-driven initializer.
  init(rootURL: URL, runsURL: URL) throws {
    self.rootURL = rootURL
    self.runsURL = runsURL
    productWorkspacesURL = rootURL.appendingPathComponent(
      "Product Workspaces",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: productWorkspacesURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: runsURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    guard ProcessInfo.processInfo.environment["SPEDITO_PILOT_KEEP"] != "1" else { return }
    try? FileManager.default.removeItem(at: rootURL)
  }
}
