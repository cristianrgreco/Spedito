import Foundation
import Testing

@testable import SpeditoApp
@testable import SpeditoCore

/// Pins the demo card's owner-facing words for every presentation kind and
/// session status. The two switches this covers grew a sixth kind; the words
/// are what the product owner reads when deciding what to press.
@Suite("Sprint board demo presentation")
struct SprintBoardDemoPresentationTests {
  private func specification(_ kind: DemoPresentationKind) -> DemoLaunchSpecification {
    switch kind {
    case .browser:
      DemoLaunchSpecification(
        title: "Web demo",
        launchCommand: DemoCommand(executable: "bin/serve"),
        portEnvironmentVariable: "PORT",
        readiness: DemoReadinessCheck(kind: .http, path: "/"),
        presentation: DemoPresentation(kind: .browser, path: "/")
      )
    case .staticWeb:
      DemoLaunchSpecification(
        title: "Prototype",
        presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
      )
    case .macApplication:
      DemoLaunchSpecification(
        title: "Mac app",
        presentation: DemoPresentation(kind: .macApplication, path: "build/App.app")
      )
    case .artifact:
      DemoLaunchSpecification(
        title: "Report",
        presentation: DemoPresentation(kind: .artifact, path: "docs/report.pdf")
      )
    case .commandOutput:
      DemoLaunchSpecification(
        title: "Result",
        launchCommand: DemoCommand(executable: "bin/run"),
        presentation: DemoPresentation(kind: .commandOutput)
      )
    case .terminalApplication:
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "bin/tui"),
        presentation: DemoPresentation(kind: .terminalApplication)
      )
    }
  }

  private func session(_ status: DemoSessionStatus) -> DemoSession {
    DemoSession(productID: UUID(), launchID: UUID(), status: status)
  }

  @Test("The demo button title follows the session status and the kind")
  func buttonTitles() {
    for kind in DemoPresentationKind.allCases {
      let specification = specification(kind)
      func title(_ session: DemoSession?, running: Bool = false) -> String {
        SprintBoardDemoPresentation.buttonTitle(
          specification: specification,
          session: session,
          isActionRunning: running
        )
      }
      #expect(title(nil) == "Demo")
      #expect(title(session(.stopped)) == "Demo")
      #expect(title(session(.failed)) == "Retry demo")
      #expect(
        title(session(.ready)) == (kind == .commandOutput ? "Run demo again" : "Open demo"),
        "\(kind.rawValue)"
      )
      #expect(title(session(.preparing), running: true) == "Preparing…")
      #expect(title(session(.starting), running: true) == "Starting…")
    }
    #expect(
      SprintBoardDemoPresentation.buttonTitle(
        specification: nil,
        session: nil,
        isActionRunning: false
      ) == "Demo"
    )
  }

  @Test("Stop demo appears only for a running version Spedito owns")
  func stopDemo() {
    let expected: [DemoPresentationKind: Bool] = [
      .browser: true,
      .staticWeb: true,
      .macApplication: true,
      .terminalApplication: true,
      .artifact: false,
      .commandOutput: false,
    ]
    #expect(Set(expected.keys) == Set(DemoPresentationKind.allCases))
    for (kind, shows) in expected {
      let specification = specification(kind)
      #expect(
        SprintBoardDemoPresentation.showsStopDemo(
          specification: specification,
          session: session(.ready),
          canOpenDemo: true
        ) == shows,
        "\(kind.rawValue)"
      )
      #expect(
        !SprintBoardDemoPresentation.showsStopDemo(
          specification: specification,
          session: session(.stopped),
          canOpenDemo: true
        )
      )
      #expect(
        !SprintBoardDemoPresentation.showsStopDemo(
          specification: specification,
          session: session(.ready),
          canOpenDemo: false
        )
      )
    }
    #expect(
      !SprintBoardDemoPresentation.showsStopDemo(
        specification: nil,
        session: session(.ready),
        canOpenDemo: true
      )
    )
  }

  @Test("Every kind explains its ready state in owner language")
  func readyExplanations() {
    let expected: [DemoPresentationKind: String] = [
      .browser:
        "The local web demo is running. Open demo reuses it without starting a duplicate.",
      .staticWeb: "The interactive prototype is running on Spedito’s managed local server.",
      .macApplication: "The reviewed macOS app is running in its managed demo session.",
      .artifact: "The reviewed artifact has been opened.",
      .commandOutput: "The reviewed scenario completed and its result is shown below.",
      .terminalApplication:
        "The reviewed program is running in a Terminal window. Close that window or choose Stop demo when you are done.",
    ]
    #expect(Set(expected.keys) == Set(DemoPresentationKind.allCases))
    for (kind, text) in expected {
      #expect(
        SprintBoardDemoPresentation.explanation(
          candidateStatus: .readyForDemo,
          specification: specification(kind),
          session: session(.ready),
          canOpenDemo: true
        ) == text,
        "\(kind.rawValue)"
      )
    }
  }

  @Test("Other states explain themselves regardless of kind")
  func otherExplanations() {
    let specification = specification(.terminalApplication)
    func explanation(
      _ status: CandidateRevisionStatus = .readyForDemo,
      specification: DemoLaunchSpecification?,
      session: DemoSession?,
      canOpenDemo: Bool = true
    ) -> String {
      SprintBoardDemoPresentation.explanation(
        candidateStatus: status,
        specification: specification,
        session: session,
        canOpenDemo: canOpenDemo
      )
    }
    #expect(
      explanation(specification: nil, session: nil)
        == "This candidate predates managed demos. Request changes so the assigned team member can add a one-click demo."
    )
    #expect(
      explanation(.accepted, specification: specification, session: nil, canOpenDemo: false)
        == "The product owner approved this reviewed demo and promoted its integrated revision."
    )
    #expect(
      explanation(.superseded, specification: specification, session: nil, canOpenDemo: false)
        == "This earlier demo submission remains in the work log as delivery history."
    )
    #expect(
      explanation(specification: specification, session: session(.preparing))
        == "Spedito is preparing the exact reviewed revision."
    )
    #expect(
      explanation(specification: specification, session: session(.starting))
        == "Spedito is starting the demo and waiting until it is ready."
    )
    #expect(
      explanation(specification: specification, session: session(.failed))
        == "The demo could not open. Retry it or describe what happened and request changes."
    )
    #expect(
      explanation(specification: specification, session: session(.stopped))
        == "The reviewed demo is ready. Spedito will manage its setup and cleanup."
    )
    #expect(
      explanation(specification: specification, session: nil)
        == "Spedito will open the exact reviewed result and manage any local processes it needs."
    )
  }
}
