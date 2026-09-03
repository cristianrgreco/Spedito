import Foundation
import SpeditoCore

/// The owner-facing words the sprint board's demo card derives from a
/// candidate's recipe and its managed session. Pure projection, so every
/// kind and status can be pinned without a running demo.
enum SprintBoardDemoPresentation {
  static func buttonTitle(
    specification: DemoLaunchSpecification?,
    session: DemoSession?,
    isActionRunning: Bool
  ) -> String {
    if isActionRunning {
      return session?.status == .starting ? "Starting…" : "Preparing…"
    }
    switch session?.status {
    case .ready:
      return specification?.presentation.kind == .commandOutput
        ? "Run demo again"
        : "Open demo"
    case .failed:
      return "Retry demo"
    default:
      return "Demo"
    }
  }

  /// Whether the card offers **Stop demo**: only a running version Spedito
  /// owns can be stopped, so artifacts and captured results never show it.
  static func showsStopDemo(
    specification: DemoLaunchSpecification?,
    session: DemoSession?,
    canOpenDemo: Bool
  ) -> Bool {
    guard canOpenDemo, session?.status == .ready, let kind = specification?.presentation.kind
    else { return false }
    switch kind {
    case .browser, .staticWeb, .macApplication, .terminalApplication:
      return true
    case .artifact, .commandOutput:
      return false
    }
  }

  static func explanation(
    candidateStatus: CandidateRevisionStatus,
    specification: DemoLaunchSpecification?,
    session: DemoSession?,
    canOpenDemo: Bool
  ) -> String {
    guard let specification else {
      return
        "This candidate predates managed demos. Request changes so the assigned team member can add a one-click demo."
    }
    guard canOpenDemo else {
      return candidateStatus == .accepted
        ? "The product owner approved this reviewed demo and promoted its integrated revision."
        : "This earlier demo submission remains in the work log as delivery history."
    }
    switch session?.status {
    case .preparing:
      return "Spedito is preparing the exact reviewed revision."
    case .starting:
      return "Spedito is starting the demo and waiting until it is ready."
    case .ready:
      switch specification.presentation.kind {
      case .browser:
        return "The local web demo is running. Open demo reuses it without starting a duplicate."
      case .staticWeb:
        return "The interactive prototype is running on Spedito’s managed local server."
      case .macApplication:
        return "The reviewed macOS app is running in its managed demo session."
      case .artifact:
        return "The reviewed artifact has been opened."
      case .commandOutput:
        return "The reviewed scenario completed and its result is shown below."
      case .terminalApplication:
        return
          "The reviewed program is running in a Terminal window. Close that window or choose Stop demo when you are done."
      }
    case .failed:
      return "The demo could not open. Retry it or describe what happened and request changes."
    case .stopped:
      return "The reviewed demo is ready. Spedito will manage its setup and cleanup."
    case nil:
      return "Spedito will open the exact reviewed result and manage any local processes it needs."
    }
  }
}
