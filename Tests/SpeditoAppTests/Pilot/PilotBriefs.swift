import Foundation
import SpeditoCore

/// A product an autonomous owner asks Spedito to build.
///
/// The catalog deliberately spans every `DemoPresentationKind` because demo
/// preparation and launch is where owner-visible delivery most often breaks.
struct PilotBrief: Sendable {
  enum Source: Sendable {
    case blank
    case publicRepository(String)
  }

  let id: String
  let productName: String
  /// The owner's opening request, phrased the way a non-technical owner phrases it.
  let outcome: String
  let source: Source
  /// The demo kind this product should reach if delivery behaves.
  let expectedDemoKind: DemoPresentationKind
  /// True when the product legitimately needs network access, so the run should
  /// observe a scoped permission request rather than a silent failure.
  let expectsNetworkPermission: Bool
  /// An owner request made after the first sprint starts, to exercise scope
  /// change against live delivery.
  let midSprintFollowUp: String?

  var isImport: Bool {
    if case .publicRepository = source { return true }
    return false
  }
}

enum PilotBriefCatalog {
  static let all: [PilotBrief] = [
    PilotBrief(
      id: "static-weather",
      productName: "Weather board",
      outcome: "Show me today's weather for a city I type in, on a single page.",
      source: .blank,
      expectedDemoKind: .staticWeb,
      expectsNetworkPermission: true,
      midSprintFollowUp: "Can it remember the last city I looked at?"
    ),
    PilotBrief(
      id: "static-converter",
      productName: "Unit converter",
      outcome: "A page that converts between metric and imperial units.",
      source: .blank,
      expectedDemoKind: .staticWeb,
      expectsNetworkPermission: false,
      midSprintFollowUp: nil
    ),
    PilotBrief(
      id: "web-reading-list",
      productName: "Reading list",
      outcome:
        "A small web app where I can save links to read later and tick them off.",
      source: .blank,
      expectedDemoKind: .browser,
      expectsNetworkPermission: false,
      midSprintFollowUp: "I'd also like to search what I've saved."
    ),
    PilotBrief(
      id: "native-notes",
      productName: "Quick notes",
      outcome:
        "A native Mac app for jotting short notes that stay there when I reopen it.",
      source: .blank,
      expectedDemoKind: .macApplication,
      expectsNetworkPermission: false,
      midSprintFollowUp: nil
    ),
    PilotBrief(
      id: "native-timer",
      productName: "Focus timer",
      outcome: "A Mac app that counts down twenty five minutes and tells me when it is done.",
      source: .blank,
      expectedDemoKind: .macApplication,
      expectsNetworkPermission: false,
      midSprintFollowUp: nil
    ),
    PilotBrief(
      id: "script-log-summary",
      productName: "Log summary",
      outcome:
        "Something I can run that reads a folder of log files and tells me the most common errors.",
      source: .blank,
      expectedDemoKind: .commandOutput,
      expectsNetworkPermission: false,
      midSprintFollowUp: nil
    ),
    PilotBrief(
      id: "library-csv",
      productName: "Spreadsheet tidier",
      outcome:
        "A reusable piece of code that cleans up messy spreadsheet exports, with tests that prove it works.",
      source: .blank,
      expectedDemoKind: .artifact,
      expectsNetworkPermission: false,
      midSprintFollowUp: nil
    ),
    PilotBrief(
      id: "vague-dashboard",
      productName: "Team dashboard",
      outcome: "I want a dashboard.",
      source: .blank,
      expectedDemoKind: .browser,
      expectsNetworkPermission: false,
      midSprintFollowUp: nil
    ),
  ]

  static func brief(id: String) -> PilotBrief? {
    all.first { $0.id == id }
  }
}
