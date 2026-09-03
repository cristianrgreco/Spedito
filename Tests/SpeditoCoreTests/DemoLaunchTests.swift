import Foundation
import Testing

@testable import SpeditoCore

@Suite("Managed demo launch")
struct DemoLaunchTests {
  @Test("Web, native app, safe artifact, and command-output recipes validate")
  func supportedPresentations() throws {
    let web = DemoLaunchSpecification(
      title: "Local web preview",
      launchCommand: DemoCommand(
        executable: "python3",
        arguments: ["-m", "http.server", "{{PORT}}", "--bind", "127.0.0.1"]
      ),
      portEnvironmentVariable: "PORT",
      readiness: DemoReadinessCheck(kind: .http, path: "/"),
      presentation: DemoPresentation(kind: .browser, path: "/index.html")
    )
    try DemoLaunchSpecificationValidator.validate(web)

    let staticWeb = DemoLaunchSpecification(
      title: "Forecast interaction prototype",
      presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
    )
    try DemoLaunchSpecificationValidator.validate(staticWeb)

    let app = DemoLaunchSpecification(
      title: "Reviewed app",
      preparationCommands: [
        DemoCommand(executable: "swift", arguments: ["build"])
      ],
      presentation: DemoPresentation(
        kind: .macApplication,
        path: ".build/Spedito.app"
      )
    )
    try DemoLaunchSpecificationValidator.validate(app)

    let artifact = DemoLaunchSpecification(
      title: "Design report",
      presentation: DemoPresentation(kind: .artifact, path: "docs/report.pdf")
    )
    try DemoLaunchSpecificationValidator.validate(artifact)

    let output = DemoLaunchSpecification(
      title: "Parser scenario",
      launchCommand: DemoCommand(
        executable: ".build/debug/parser-demo",
        arguments: ["sample.json"]
      ),
      presentation: DemoPresentation(kind: .commandOutput)
    )
    try DemoLaunchSpecificationValidator.validate(output)
  }

  @Test("Structured demo schema exposes only validator-supported variants")
  func structuredSchemaMatchesValidator() throws {
    let variants = try #require(
      CodexTicketExecutor.demoLaunchSpecificationSchema(
        deliveryDemoPolicy: .anyKind
      )["anyOf"]?.arrayValue
    )
    let kinds = variants.compactMap {
      $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
        .arrayValue?.first?.stringValue
    }
    #expect(
      Set(kinds)
        == Set(DemoPresentationKind.allCases.map(\.rawValue))
    )
    #expect(variants.count == DemoPresentationKind.allCases.count)
    let browserSchema = try #require(
      variants.first {
        $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
          .arrayValue?.first?.stringValue == DemoPresentationKind.browser.rawValue
      }
    )
    #expect(browserSchema["properties"]?["title"]?["minLength"]?.integerValue == 1)
    #expect(
      browserSchema["properties"]?["launchCommand"]?["properties"]?["executable"]?[
        "minLength"
      ]?.integerValue == 1
    )
    let staticWebSchema = try #require(
      variants.first {
        $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
          .arrayValue?.first?.stringValue == DemoPresentationKind.staticWeb.rawValue
      }
    )
    #expect(
      staticWebSchema["properties"]?["presentation"]?["properties"]?["path"]?[
        "minLength"
      ]?.integerValue == 1
    )

    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Command-backed app",
          launchCommand: DemoCommand(executable: "swift", arguments: ["run"]),
          presentation: DemoPresentation(kind: .macApplication, path: ".build/App.app")
        )
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Prepared artifact",
          preparationCommands: [DemoCommand(executable: "swift", arguments: ["build"])],
          presentation: DemoPresentation(kind: .artifact, path: "report.pdf")
        )
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Service result",
          launchCommand: DemoCommand(executable: "swift", arguments: ["run"]),
          portEnvironmentVariable: "PORT",
          presentation: DemoPresentation(kind: .commandOutput)
        )
      )
    }
  }

  /// Pre-contract UX delivery turns that admitted browser and mac_application
  /// beside static_web committed to browser whenever the model emitted
  /// launchCommand before presentation, and labelled an HTML mock of a native
  /// window mac_application; the owner chose to contract such a ticket to
  /// static_web alone (2 September 2026).
  @Test("A pre-contract prototype ticket's schema admits only static_web")
  func preContractPrototypeSchemaAdmitsOnlyStaticWeb() throws {
    let productID = UUID()
    let policy = DeliveryDemoPolicy(
      assignee: AgentProfile(productID: productID, name: "UX designer", role: .uxDesigner),
      item: WorkItem(
        productID: productID,
        key: "T-1",
        title: "Design the invoice status window",
        body: "The window design must be reviewable as an interactive prototype.",
        acceptanceCriteria: ["The managed demo opens the prototype"]
      )
    )
    #expect(policy == .contracted(.staticWeb))
    let variants = try #require(
      CodexTicketExecutor.demoLaunchSpecificationSchema(
        deliveryDemoPolicy: policy
      )["anyOf"]?.arrayValue
    )
    let kinds = variants.compactMap {
      $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
        .arrayValue?.first?.stringValue
    }
    #expect(kinds == [DemoPresentationKind.staticWeb.rawValue])

    let demoField = CodexTicketExecutor.outputSchema(
      deliveryDemoPolicy: policy
    )["properties"]?["demo"]
    let demoBranches = try #require(demoField?["anyOf"]?.arrayValue)
    let demoKinds = demoBranches
      .compactMap { $0["anyOf"]?.arrayValue }
      .flatMap { $0 }
      .compactMap {
        $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
          .arrayValue?.first?.stringValue
      }
    // Neither the browser shape the key-order misses fell into, nor the
    // mac_application bundle an HTML mock was labelled as, nor any inert or
    // terminal kind is expressible for a prototype contract.
    #expect(demoKinds == [DemoPresentationKind.staticWeb.rawValue])
    #expect(
      demoBranches.contains { $0["type"]?.stringValue == "null" },
      "awaiting_owner still needs a null demo under the narrowed policy"
    )
  }

  /// The union's branches mirror the validator's command and null shapes;
  /// path content deliberately stays a validator hard-stop with a schema
  /// description only — schema `pattern` constraints were rejected live
  /// (2026-08-29) because constrained decoding then fabricates conforming
  /// paths instead of contesting the kind.
  @Test("Every schema branch mirrors the validator's structural semantics")
  func schemaBranchShapesMirrorTheValidator() throws {
    let variants = try #require(
      CodexTicketExecutor.demoLaunchSpecificationSchema(
        deliveryDemoPolicy: .anyKind
      )["anyOf"]?.arrayValue
    )
    func branch(_ kind: DemoPresentationKind) throws -> JSONValue {
      try #require(
        variants.first {
          $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
            .arrayValue?.first?.stringValue == kind.rawValue
        }
      )
    }
    func property(_ branch: JSONValue, _ name: String) -> JSONValue? {
      branch["properties"]?[name]
    }
    func presentationPath(_ branch: JSONValue) -> JSONValue? {
      branch["properties"]?["presentation"]?["properties"]?["path"]
    }
    func isNull(_ value: JSONValue?) -> Bool {
      value?["type"]?.stringValue == "null"
    }
    func forbidsCommands(_ branch: JSONValue) -> Bool {
      property(branch, "preparationCommands")?["maxItems"]?.integerValue == 0
        && isNull(property(branch, "launchCommand"))
    }
    func requiresLaunchCommand(_ branch: JSONValue) -> Bool {
      property(branch, "launchCommand")?["properties"]?["executable"] != nil
    }
    for value in variants {
      #expect(value["properties"] != nil)
      for name in ["pattern"] {
        #expect(
          presentationPath(value)?[name] == nil,
          "path content rules stay validator hard-stops, never schema patterns"
        )
      }
    }

    // browser: launch command and HTTP readiness required; loopback paths.
    let browser = try branch(.browser)
    #expect(requiresLaunchCommand(browser))
    #expect(
      property(browser, "readiness")?["properties"]?["kind"]?["enum"]?
        .arrayValue == [.string(DemoReadinessKind.http.rawValue)]
    )
    // static_web: a directory with no commands, port, or readiness.
    let staticWeb = try branch(.staticWeb)
    #expect(forbidsCommands(staticWeb))
    #expect(isNull(property(staticWeb, "portEnvironmentVariable")))
    #expect(isNull(property(staticWeb, "readiness")))
    #expect(
      presentationPath(staticWeb)?["description"]?.stringValue?
        .contains("non-root") == true
    )
    // mac_application: preparation may build; nothing launches or serves.
    let macApplication = try branch(.macApplication)
    #expect(isNull(property(macApplication, "launchCommand")))
    #expect(isNull(property(macApplication, "portEnvironmentVariable")))
    #expect(isNull(property(macApplication, "readiness")))
    #expect(
      presentationPath(macApplication)?["description"]?.stringValue?
        .contains(".app") == true
    )
    // artifact: an existing inert file and no commands at all.
    let artifact = try branch(.artifact)
    #expect(forbidsCommands(artifact))
    let artifactDescription = try #require(
      presentationPath(artifact)?["description"]?.stringValue
    )
    for allowed in DemoArtifactPolicy.allowedExtensions {
      #expect(artifactDescription.contains(allowed))
    }
    #expect(!artifactDescription.contains("svg"))
    // command_output: a launch command whose output is shown; no path.
    let commandOutput = try branch(.commandOutput)
    #expect(requiresLaunchCommand(commandOutput))
    #expect(isNull(presentationPath(commandOutput)))
    // terminal_application: the built program is the launch command; no
    // path, port, or readiness. The executable description states the
    // workspace-relative rule the validator enforces; no schema pattern.
    let terminalApplication = try branch(.terminalApplication)
    #expect(requiresLaunchCommand(terminalApplication))
    #expect(isNull(presentationPath(terminalApplication)))
    #expect(isNull(property(terminalApplication, "portEnvironmentVariable")))
    #expect(isNull(property(terminalApplication, "readiness")))
    #expect(
      property(terminalApplication, "launchCommand")?["properties"]?["executable"]?[
        "description"
      ]?.stringValue?.contains("workspace-relative") == true
    )
    #expect(
      property(terminalApplication, "launchCommand")?["properties"]?["executable"]?[
        "pattern"
      ] == nil
    )
  }

  @Test("Per-kind decode accepts each legal shape and rejects each illegal one")
  func perKindDecodeShapes() throws {
    func resultJSON(demo: DemoLaunchSpecification) throws -> String {
      let result = TicketExecutionResult(
        status: .completed,
        comment: "Delivered.",
        question: nil,
        options: [],
        summary: "Done.",
        changedFiles: ["Sources/App.swift"],
        tests: ["Checked"],
        knowledgeNotes: [],
        reviewInstructions: ["Open the managed Demo."],
        demo: demo,
        retrospectiveWentWell: [],
        retrospectiveCouldImprove: [],
        retrospectiveActions: []
      )
      return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    let legalShapes: [DemoLaunchSpecification] = [
      DemoLaunchSpecification(
        title: "Web demo",
        launchCommand: DemoCommand(executable: "bin/serve"),
        portEnvironmentVariable: "PORT",
        readiness: DemoReadinessCheck(kind: .http, path: "/"),
        presentation: DemoPresentation(kind: .browser, path: "/")
      ),
      DemoLaunchSpecification(
        title: "Prototype",
        presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
      ),
      DemoLaunchSpecification(
        title: "Mac app",
        preparationCommands: [DemoCommand(executable: "scripts/build.sh")],
        presentation: DemoPresentation(kind: .macApplication, path: "build/Preview.app")
      ),
      DemoLaunchSpecification(
        title: "Report",
        presentation: DemoPresentation(kind: .artifact, path: "docs/report.md")
      ),
      DemoLaunchSpecification(
        title: "Result",
        launchCommand: DemoCommand(executable: "bin/run"),
        presentation: DemoPresentation(kind: .commandOutput)
      ),
      DemoLaunchSpecification(
        title: "Terminal app",
        preparationCommands: [DemoCommand(executable: "scripts/build.sh")],
        launchCommand: DemoCommand(executable: "bin/tui", arguments: ["--interactive"]),
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
    ]
    for demo in legalShapes {
      #expect(try CodexTicketExecutor.decode(resultJSON(demo: demo)).demo == demo)
    }

    let illegalShapes: [DemoLaunchSpecification] = [
      // A web demo without its managed service command.
      DemoLaunchSpecification(
        title: "Web demo",
        readiness: DemoReadinessCheck(kind: .http, path: "/"),
        presentation: DemoPresentation(kind: .browser, path: "/")
      ),
      // A prototype cannot declare commands.
      DemoLaunchSpecification(
        title: "Prototype",
        preparationCommands: [DemoCommand(executable: "scripts/build.sh")],
        presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
      ),
      // A macOS app demo opens a built bundle, not a bare directory.
      DemoLaunchSpecification(
        title: "Mac app",
        presentation: DemoPresentation(kind: .macApplication, path: "build/preview")
      ),
      // An artifact must be inert; SVG never is.
      DemoLaunchSpecification(
        title: "Report",
        presentation: DemoPresentation(kind: .artifact, path: "docs/report.svg")
      ),
      // A result demo cannot carry an artifact path.
      DemoLaunchSpecification(
        title: "Result",
        launchCommand: DemoCommand(executable: "bin/run"),
        presentation: DemoPresentation(kind: .commandOutput, path: "docs/report.md")
      ),
      // A terminal app names its program through launchCommand, never a path.
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "bin/tui"),
        presentation: DemoPresentation(kind: .terminalApplication, path: "bin/tui")
      ),
      // An interactive session has no readiness check.
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "bin/tui"),
        readiness: DemoReadinessCheck(kind: .process),
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
      // Nor a managed service port.
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "bin/tui"),
        portEnvironmentVariable: "PORT",
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
      // The launch command is required.
      DemoLaunchSpecification(
        title: "Terminal app",
        preparationCommands: [DemoCommand(executable: "scripts/build.sh")],
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
      // A bare tool name runs a host tool, not the reviewed program.
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "go", arguments: ["run", "."]),
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "sh", arguments: ["bin/tui"]),
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
      // The program must live inside the reviewed checkout.
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "../bin/tui"),
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
      DemoLaunchSpecification(
        title: "Terminal app",
        launchCommand: DemoCommand(executable: "/usr/bin/top"),
        presentation: DemoPresentation(kind: .terminalApplication)
      ),
    ]
    for demo in illegalShapes {
      #expect(throws: TicketExecutionGenerationError.self) {
        try CodexTicketExecutor.decode(try resultJSON(demo: demo))
      }
    }
  }

  @Test("A contracted run's schema admits only the contracted kind's branch")
  func contractedSchemaAdmitsOnlyTheContractedBranch() throws {
    for kind in DemoPresentationKind.allCases {
      let variants = try #require(
        CodexTicketExecutor.demoLaunchSpecificationSchema(
          deliveryDemoPolicy: .contracted(kind)
        )["anyOf"]?.arrayValue
      )
      let kinds = variants.compactMap {
        $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
          .arrayValue?.first?.stringValue
      }
      #expect(kinds == [kind.rawValue])

      let demoField = CodexTicketExecutor.outputSchema(
        deliveryDemoPolicy: .contracted(kind)
      )["properties"]?["demo"]
      let demoBranches = try #require(demoField?["anyOf"]?.arrayValue)
      let demoKinds = demoBranches
        .compactMap { $0["anyOf"]?.arrayValue }
        .flatMap { $0 }
        .compactMap {
          $0["properties"]?["presentation"]?["properties"]?["kind"]?["enum"]?
            .arrayValue?.first?.stringValue
        }
      #expect(demoKinds == [kind.rawValue])
      #expect(
        demoBranches.contains { $0["type"]?.stringValue == "null" },
        "awaiting_owner still needs a null demo under a contracted policy"
      )
    }
  }

  @Test("A code-only contract makes every demo recipe inexpressible")
  func codeOnlyContractForcesANullDemo() throws {
    let demoField = CodexTicketExecutor.outputSchema(
      deliveryDemoPolicy: .codeOnly
    )["properties"]?["demo"]
    #expect(demoField?["type"]?.stringValue == "null")
    #expect(demoField?["anyOf"] == nil)
  }

  @Test("A contested kind gets canonical decision options the answer can match")
  func contestedKindOptionsRoundTrip() {
    let question = DemoKindContestPolicy.question(
      prompt: "The delivered outcome is a built Mac app, not a web service.",
      current: .browser,
      proposed: .macApplication
    )
    #expect(question.options.count == 2)
    #expect(question.options[0] == DemoKindContestPolicy.changeOption(to: .macApplication))
    #expect(question.options[1] == DemoKindContestPolicy.keepOption(current: .browser))
    // An accepted change must also unpin the recipe: the option text counts
    // as feedback naming the demo.
    #expect(DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(question.options[0]))

    func answerComment(selectedOption: String?) -> TicketComment {
      TicketComment(
        workItemID: UUID(),
        authorKind: .owner,
        authorName: "Me",
        body: "Answered.",
        answeredQuestions: [
          TicketAnsweredQuestion(
            question: TicketRefinementQuestion(
              prompt: question.prompt,
              options: question.options
            ),
            selectedOption: selectedOption,
            answer: selectedOption ?? "Something else entirely"
          )
        ]
      )
    }

    #expect(
      DemoKindContestPolicy.acceptedKindChange(
        comments: [answerComment(selectedOption: question.options[0])]
      ) == .macApplication
    )
    #expect(
      DemoKindContestPolicy.acceptedKindChange(
        comments: [answerComment(selectedOption: question.options[1])]
      ) == nil,
      "keeping the planned demo changes nothing"
    )
    #expect(
      DemoKindContestPolicy.acceptedKindChange(
        comments: [answerComment(selectedOption: nil)]
      ) == nil,
      "a free-text Other answer never changes the contract mechanically"
    )
    // The latest owner decision wins across multiple answers.
    #expect(
      DemoKindContestPolicy.acceptedKindChange(
        comments: [
          answerComment(selectedOption: DemoKindContestPolicy.changeOption(to: .artifact)),
          answerComment(selectedOption: question.options[0]),
        ]
      ) == .macApplication
    )
    // An agent-authored comment can never carry an accepted change.
    let agentComment = TicketComment(
      workItemID: UUID(),
      authorKind: .agent,
      authorName: "Implementer",
      body: DemoKindContestPolicy.changeOption(to: .commandOutput)
    )
    #expect(DemoKindContestPolicy.acceptedKindChange(comments: [agentComment]) == nil)

    // The terminal kind's options read in owner language, Terminal keeping
    // its capital as the app name, and its accepted change applies.
    #expect(
      DemoKindContestPolicy.changeOption(to: .terminalApplication)
        == "Change the demo to: opens in Terminal"
    )
    #expect(
      DemoKindContestPolicy.keepOption(current: .terminalApplication)
        == "Keep the planned demo: opens in Terminal"
    )
    #expect(
      DemoKindContestPolicy.acceptedKindChange(
        comments: [
          answerComment(
            selectedOption: DemoKindContestPolicy.changeOption(to: .terminalApplication)
          )
        ]
      ) == .terminalApplication
    )
  }

  @Test("Recipes reject shells, escaped paths, and non-loopback browser URLs")
  func unsafeRecipes() {
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Unsafe shell",
          launchCommand: DemoCommand(
            executable: "bash",
            arguments: ["-lc", "python -m http.server"]
          ),
          readiness: DemoReadinessCheck(kind: .http, path: "/"),
          presentation: DemoPresentation(kind: .browser, path: "/")
        )
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Escaped artifact",
          presentation: DemoPresentation(kind: .artifact, path: "../secret.txt")
        )
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Remote page",
          launchCommand: DemoCommand(executable: "python3"),
          readiness: DemoReadinessCheck(kind: .http, path: "/"),
          presentation: DemoPresentation(
            kind: .browser,
            path: "https://example.com"
          )
        )
      )
    }

    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Command-backed static prototype",
          launchCommand: DemoCommand(executable: "python3"),
          presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
        )
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Escaped static prototype",
          presentation: DemoPresentation(kind: .staticWeb, path: "../prototype")
        )
      )
    }
  }

  /// A live pilot run building a native Mac app was told "browser paths must be
  /// a loopback URL path beginning with “/”". Every demo kind may declare an
  /// HTTP readiness check, so this validation is not reached only for browser
  /// demos, and naming the wrong one leaves the product owner reading a sentence
  /// about a product they did not ask for.
  @Test("A malformed readiness path is not described as a browser path")
  func readinessPathFailureNamesReadiness() throws {
    let nativeApp = DemoLaunchSpecification(
      title: "Reviewed app",
      launchCommand: DemoCommand(executable: "swift", arguments: ["run"]),
      readiness: DemoReadinessCheck(kind: .http, path: "health"),
      presentation: DemoPresentation(kind: .macApplication, path: ".build/Quick Notes.app")
    )
    let readinessFailure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(nativeApp)
    }
    #expect("\(readinessFailure!)".contains("readiness paths"))
    #expect(!"\(readinessFailure!)".contains("browser paths"))

    // A browser demo still names browser paths, because that is what it is.
    let browserDemo = DemoLaunchSpecification(
      title: "Reviewed web app",
      launchCommand: DemoCommand(executable: "swift", arguments: ["run"]),
      readiness: DemoReadinessCheck(kind: .http, path: "/"),
      presentation: DemoPresentation(kind: .browser, path: "index.html")
    )
    let browserFailure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(browserDemo)
    }
    #expect("\(browserFailure!)".contains("browser paths"))
  }

  /// The same pilot's implementer resubmitted its built app bundle as a
  /// browser path twice, because the rejection blamed the path while the
  /// actual mistake was the kind.
  /// Eight of twelve UX delivery samples (bundle 20260902-014640) mirrored
  /// the browser shape for an HTML screen set and handed over the prototype
  /// directory as the browser path; the repair turn must be told the kind.
  @Test("A workspace directory offered as a browser path is pointed at static_web")
  func browserPathThatIsAWorkspaceDirectoryIsPointedAtStaticWeb() {
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Invoice list screens",
          launchCommand: DemoCommand(executable: "bin/serve"),
          portEnvironmentVariable: "PORT",
          readiness: DemoReadinessCheck(kind: .http, path: "/"),
          presentation: DemoPresentation(kind: .browser, path: "prototype/invoice-list")
        )
      )
    }
    do {
      try DemoLaunchSpecificationValidator.validate(
        DemoLaunchSpecification(
          title: "Invoice list screens",
          launchCommand: DemoCommand(executable: "bin/serve"),
          portEnvironmentVariable: "PORT",
          readiness: DemoReadinessCheck(kind: .http, path: "/"),
          presentation: DemoPresentation(kind: .browser, path: "prototype/invoice-list")
        )
      )
    } catch let error as DemoLaunchValidationError {
      #expect(error.localizedDescription.contains("static_web, not browser"))
      #expect(error.localizedDescription.contains("beginning with “/”"))
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  @Test("A built app bundle offered as a browser path is pointed at mac_application")
  func appBundleBrowserPathNamesTheRightKind() throws {
    // The exact recipe the pilot's final repair attempt returned.
    let pilotRecipe = DemoLaunchSpecification(
      title: "Native Weather starter app",
      preparationCommands: [
        DemoCommand(executable: "scripts/prepare-demo.sh", timeoutSeconds: 120)
      ],
      launchCommand: DemoCommand(executable: "scripts/prepare-demo.sh", timeoutSeconds: 120),
      readiness: DemoReadinessCheck(kind: .http, path: "/", timeoutSeconds: 120),
      presentation: DemoPresentation(kind: .browser, path: ".demo/NativeWeather.app")
    )
    let failure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(pilotRecipe)
    }
    #expect("\(failure!)".contains("mac_application, not browser"))

    // A browser path that is merely malformed keeps the plain path message.
    let malformed = DemoLaunchSpecification(
      title: "Reviewed web app",
      launchCommand: DemoCommand(executable: "swift", arguments: ["run"]),
      readiness: DemoReadinessCheck(kind: .http, path: "/"),
      presentation: DemoPresentation(kind: .browser, path: "index.html")
    )
    let malformedFailure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(malformed)
    }
    #expect(!"\(malformedFailure!)".contains("mac_application"))

    // The recipe the pilot needed validates as supplied.
    try DemoLaunchSpecificationValidator.validate(
      DemoLaunchSpecification(
        title: "Native Weather starter app",
        preparationCommands: [
          DemoCommand(executable: "scripts/prepare-demo.sh", timeoutSeconds: 120)
        ],
        presentation: DemoPresentation(kind: .macApplication, path: ".demo/NativeWeather.app")
      )
    )
  }

  /// A live design ticket delivered an SVG screen set and resubmitted it three
  /// times, because the rejection said only "inert text, data, image, or PDF"
  /// and an SVG reads as an image. The refusal must name the rejected extension,
  /// the exact accepted formats, and what to deliver instead, so a repair turn
  /// can converge instead of guessing.
  @Test("A rejected artifact extension is named alongside the accepted formats")
  func rejectedArtifactExtensionNamesTheAllowlist() {
    let failure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoArtifactPolicy.validatePath("design/forecast-screen-set.svg")
    }
    let text = "\(failure!)"
    #expect(text.contains(".svg"))
    #expect(text.contains("Accepted formats:"))
    #expect(text.contains("pdf"))
    #expect(text.contains("png"))
    #expect(text.contains("active content"))
  }

  /// A later pilot's UX designer delivered a PDF screen set and resubmitted it
  /// through five review cycles as static_web, mac_application, and back,
  /// because the wrong kind only failed at tech lead review. An inert file
  /// path under an interactive kind must fail delivery validation with the
  /// artifact contract named.
  @Test("An inert file offered as static_web or mac_application is pointed at artifact")
  func inertFilePathNamesTheArtifactKind() throws {
    // The exact recipes the pilot's fourth and fifth revisions returned.
    let staticWebRecipe = DemoLaunchSpecification(
      title: "Location and forecast experience",
      presentation: DemoPresentation(
        kind: .staticWeb,
        path: "design/location-forecast-screen-set.pdf"
      )
    )
    let staticWebFailure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(staticWebRecipe)
    }
    #expect("\(staticWebFailure!)".contains("artifact, not static_web"))

    let macApplicationRecipe = DemoLaunchSpecification(
      title: "Location and forecast experience",
      presentation: DemoPresentation(
        kind: .macApplication,
        path: "design/location-forecast-screen-set.pdf"
      )
    )
    let macApplicationFailure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(macApplicationRecipe)
    }
    #expect("\(macApplicationFailure!)".contains("artifact, not mac_application"))

    // The recipe the reviewer kept asking for validates as supplied.
    try DemoLaunchSpecificationValidator.validate(
      DemoLaunchSpecification(
        title: "Location and forecast experience",
        presentation: DemoPresentation(
          kind: .artifact,
          path: "design/location-forecast-screen-set.pdf"
        )
      )
    )

    // A prototype directory and a built bundle keep their interactive kinds.
    try DemoLaunchSpecificationValidator.validate(
      DemoLaunchSpecification(
        title: "Prototype",
        presentation: DemoPresentation(kind: .staticWeb, path: "design")
      )
    )
    try DemoLaunchSpecificationValidator.validate(
      DemoLaunchSpecification(
        title: "Built app",
        presentation: DemoPresentation(kind: .macApplication, path: ".demo/App.app")
      )
    )
  }

  /// The next pilot's UX designer twice satisfied the browser contract with a
  /// no-op launch command ("true") that exits without serving HTTP, and once
  /// offered its review-page directory as mac_application; each burned a
  /// review cycle. Both shapes must fail delivery validation with the actual
  /// mistake named.
  @Test("A no-op service command and a directory app bundle name the right kinds")
  func fabricatedInteractiveRecipesNameTheRightKinds() throws {
    // The exact browser recipe the pilot's first and third revisions returned.
    let noOpBrowserRecipe = DemoLaunchSpecification(
      title: "Native Weather — Seven-day forecast screen set",
      launchCommand: DemoCommand(executable: "true", timeoutSeconds: 120),
      portEnvironmentVariable: "PORT",
      readiness: DemoReadinessCheck(kind: .http, path: "/", timeoutSeconds: 60),
      presentation: DemoPresentation(kind: .browser, path: "/")
    )
    let noOpFailure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(noOpBrowserRecipe)
    }
    #expect("\(noOpFailure!)".contains("no-op command"))
    #expect("\(noOpFailure!)".contains("static_web"))

    // The exact recipe the pilot's second revision returned.
    let directoryAppRecipe = DemoLaunchSpecification(
      title: "Native Weather — Seven-day forecast screen set",
      presentation: DemoPresentation(kind: .macApplication, path: "design")
    )
    let directoryFailure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(directoryAppRecipe)
    }
    #expect("\(directoryFailure!)".contains(".app bundle"))
    #expect("\(directoryFailure!)".contains("static_web"))

    // The recipe the pilot converged on validates as supplied.
    try DemoLaunchSpecificationValidator.validate(
      DemoLaunchSpecification(
        title: "Native Weather — Seven-day forecast screen set",
        presentation: DemoPresentation(kind: .staticWeb, path: "design")
      )
    )
  }

  /// The same pilot's T1 twice supplied the correct built-bundle path with
  /// static_web declared as its kind, which only the tech lead caught. The
  /// static_web branch mirrors the browser branch's bundle rule so the repair
  /// turn is pointed at mac_application.
  @Test("A built app bundle offered as static_web is pointed at mac_application")
  func appBundleStaticWebPathNamesTheRightKind() throws {
    // The exact recipe the pilot's third and fifth revisions returned.
    let bundleAsPrototype = DemoLaunchSpecification(
      title: "Native Weather macOS app",
      presentation: DemoPresentation(
        kind: .staticWeb,
        path: ".demo-app/Native Weather.app"
      )
    )
    let failure = #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.validate(bundleAsPrototype)
    }
    #expect("\(failure!)".contains("mac_application, not static_web"))

    // The recipe the reviewer kept asking for validates as supplied.
    try DemoLaunchSpecificationValidator.validate(
      DemoLaunchSpecification(
        title: "Native Weather macOS app",
        preparationCommands: [
          DemoCommand(executable: "scripts/prepare-demo.sh", timeoutSeconds: 300)
        ],
        presentation: DemoPresentation(
          kind: .macApplication,
          path: ".demo-app/Native Weather.app"
        )
      )
    )
  }

  @Test("Workspace paths cannot escape through traversal or symlinks")
  func workspacePathBoundary() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-demo-path-\(UUID())", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: workspace.appendingPathComponent("escape"),
      withDestinationURL: outside
    )

    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        "../outside",
        in: workspace
      )
    }
    #expect(throws: DemoLaunchValidationError.self) {
      try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        "escape/secret.txt",
        in: workspace
      )
    }
    #expect(
      try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        "docs/report.md",
        in: workspace
      ).path == workspace.appendingPathComponent("docs/report.md").path
    )
  }

  @Test("Latest accepted app uses acceptance time instead of ticket version")
  func latestAcceptedRunnableApp() throws {
    let older = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      version: 12,
      demo: browserRecipe(),
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let newerNative = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      version: 1,
      demo: macApplicationRecipe(),
      createdAt: Date(timeIntervalSince1970: 300),
      updatedAt: Date(timeIntervalSince1970: 400)
    )

    let launch = try #require(AcceptedAppLaunchPolicy.latest(in: [newerNative, older]))

    #expect(launch.candidate == newerNative)
    #expect(launch.candidate.integratedSHA == "integrated")
    #expect(launch.specification == macApplicationRecipe())
  }

  @Test("Accepted app versions are returned newest first")
  func acceptedAppVersionHistory() throws {
    let oldest = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      version: 20,
      demo: browserRecipe(),
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let middle = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      version: 2,
      demo: macApplicationRecipe(),
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let newest = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      version: 1,
      demo: browserRecipe(),
      updatedAt: Date(timeIntervalSince1970: 300)
    )

    let versions = AcceptedAppLaunchPolicy.all(in: [middle, newest, oldest])

    #expect(versions.map(\.candidate) == [newest, middle, oldest])
    #expect(
      versions.map(\.specification.presentation.kind) == [
        .browser,
        .macApplication,
        .browser,
      ])
  }

  @Test("Every accepted revision of the same macOS app remains launchable")
  func acceptedMacApplicationHistory() throws {
    let productID = UUID()
    let workItemID = UUID()
    let first = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
      productID: productID,
      workItemID: workItemID,
      version: 1,
      demo: macApplicationRecipe(),
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let second = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
      productID: productID,
      workItemID: workItemID,
      version: 2,
      demo: macApplicationRecipe(),
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let third = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
      productID: productID,
      workItemID: workItemID,
      version: 3,
      demo: macApplicationRecipe(),
      updatedAt: Date(timeIntervalSince1970: 300)
    )

    let versions = AcceptedAppLaunchPolicy.all(in: [second, first, third])

    #expect(versions.map(\.candidate) == [third, second, first])
    #expect(
      versions.allSatisfy {
        $0.specification.presentation.kind == .macApplication
      }
    )
  }

  @Test("Imported source and accepted app versions share one ordered history")
  func unifiedAppVersionHistory() throws {
    let accepted = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      demo: browserRecipe(),
      updatedAt: Date(timeIntervalSince1970: 300)
    )
    let imported = ImportedAppLaunch(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
      runID: UUID(),
      productID: accepted.productID,
      revisionSHA: "imported",
      specification: macApplicationRecipe(),
      evidence: [.init(path: "scripts/build.sh")],
      publishedAt: Date(timeIntervalSince1970: 200)
    )

    let versions = AppVersionPolicy.all(
      imported: imported,
      acceptedCandidates: [accepted]
    )

    #expect(versions.map(\.id) == [accepted.id, imported.id])
    #expect(versions.map(\.revisionSHA) == ["integrated", "imported"])
    #expect(versions.map(\.sessionSourceKind) == [.acceptedCandidate, .importedRepository])
  }

  @Test("Accepted browser, static prototype, and macOS app candidates resolve")
  func acceptedApplicationPresentations() throws {
    let browser = try candidate(demo: browserRecipe())
    let macApplication = try candidate(
      demo: macApplicationRecipe(),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    let staticPrototype = try candidate(
      demo: DemoLaunchSpecification(
        title: "Interaction prototype",
        presentation: DemoPresentation(kind: .staticWeb, path: "prototype")
      ),
      updatedAt: Date(timeIntervalSince1970: 3)
    )
    let ready = try candidate(
      status: .readyForDemo,
      demo: browserRecipe(),
      updatedAt: Date(timeIntervalSince1970: 4)
    )
    let superseded = try candidate(
      status: .superseded,
      demo: macApplicationRecipe(),
      updatedAt: Date(timeIntervalSince1970: 5)
    )

    #expect(AcceptedAppLaunchPolicy.latest(in: [ready]) == nil)
    #expect(AcceptedAppLaunchPolicy.latest(in: [superseded]) == nil)
    #expect(
      AcceptedAppLaunchPolicy.latest(in: [browser])?.specification.presentation.kind == .browser
    )
    #expect(
      AcceptedAppLaunchPolicy.latest(
        in: [browser, macApplication, staticPrototype]
      )?.candidate == staticPrototype
    )
  }

  @Test("Incomplete and non-app accepted candidates do not resolve")
  func invalidAcceptedCandidates() throws {
    let missingRecipe = try candidate(demo: nil)
    let malformedResult = try candidate(
      demo: browserRecipe(),
      executionResultJSON: "{not-json"
    )
    let invalidRecipe = try candidate(
      demo: DemoLaunchSpecification(
        title: "Invalid browser",
        presentation: DemoPresentation(kind: .browser)
      )
    )
    let artifact = try candidate(
      demo: DemoLaunchSpecification(
        title: "Review report",
        presentation: DemoPresentation(kind: .artifact, path: "review/report.pdf")
      )
    )
    let commandOutput = try candidate(
      demo: DemoLaunchSpecification(
        title: "Verification output",
        launchCommand: DemoCommand(executable: "swift", arguments: ["test"]),
        presentation: DemoPresentation(kind: .commandOutput)
      )
    )
    let missingIntegratedRevision = try candidate(
      integratedSHA: nil,
      demo: browserRecipe()
    )

    #expect(
      AcceptedAppLaunchPolicy.latest(
        in: [
          missingRecipe,
          malformedResult,
          invalidRecipe,
          artifact,
          commandOutput,
          missingIntegratedRevision,
        ]
      ) == nil
    )
    #expect(
      AcceptedAppLaunchPolicy.all(
        in: [
          missingRecipe,
          malformedResult,
          invalidRecipe,
          artifact,
          commandOutput,
          missingIntegratedRevision,
        ]
      ).isEmpty
    )
  }

  @Test("Later accepted evidence preserves the prior runnable app")
  func laterAcceptedEvidenceDoesNotDisplaceApp() throws {
    let app = try candidate(
      demo: browserRecipe(),
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let artifact = try candidate(
      demo: DemoLaunchSpecification(
        title: "Acceptance evidence",
        presentation: DemoPresentation(kind: .artifact, path: "evidence/result.pdf")
      ),
      updatedAt: Date(timeIntervalSince1970: 200)
    )

    #expect(AcceptedAppLaunchPolicy.latest(in: [app, artifact])?.candidate == app)
  }

  @Test("Accepted app ties resolve deterministically")
  func deterministicAcceptedAppTieBreaker() throws {
    let timestamp = Date(timeIntervalSince1970: 100)
    let lowerID = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      demo: browserRecipe(),
      createdAt: timestamp,
      updatedAt: timestamp
    )
    let higherID = try candidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      demo: browserRecipe(),
      createdAt: timestamp,
      updatedAt: timestamp
    )

    #expect(AcceptedAppLaunchPolicy.latest(in: [higherID, lowerID])?.candidate == higherID)
    #expect(AcceptedAppLaunchPolicy.latest(in: [lowerID, higherID])?.candidate == higherID)
  }

  @Test("Only explicit demo vocabulary counts as a demo change request")
  func feedbackDemoChangeDetection() {
    #expect(
      DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "The demo recipe must declare mac_application."
      )
    )
    #expect(
      DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "Present this as command output instead of a Mac app."
      )
    )
    #expect(
      DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "The directory already has index.html, so ship it as static_web."
      )
    )
    #expect(
      DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "The readiness check never passes."
      )
    )
    #expect(
      DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "This should open in the browser."
      )
    )
    #expect(
      DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "Please open it in Terminal instead of a Mac window."
      )
    )
    #expect(
      DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "Run the TUI in a window I can type into."
      )
    )
    #expect(
      !DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "Fix the truncated Markdown command in README.md."
      )
    )
    #expect(
      !DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "Add a test that demonstrates the reconnect bug."
      )
    )
    #expect(
      !DemoRecipeRevisionPolicy.feedbackRequestsDemoChange(
        "The application state is lost when the window closes."
      )
    )
  }

  @Test("Unrelated review feedback pins the prior demo recipe verbatim")
  func revisionFeedbackPinsPriorRecipe() {
    let prior = browserRecipe()
    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForRevision(
        reviewFeedback: "Fix the truncated Markdown command in README.md.",
        priorDemo: prior
      ) == prior
    )
    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForRevision(
        reviewFeedback: "The demo should present as mac_application.",
        priorDemo: prior
      ) == nil
    )
    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForRevision(
        reviewFeedback: "Fix the truncated Markdown command in README.md.",
        priorDemo: nil
      ) == nil
    )
  }

  @Test("A recovered revision inherits the sent-back candidate's recipe")
  func continuationPinsChangesRequestedRecipe() throws {
    let runID = UUID()
    let workItemID = UUID()
    let sentBack = try candidate(
      workItemID: workItemID,
      implementationRunID: runID,
      status: .changesRequested,
      integratedSHA: nil,
      demo: browserRecipe(),
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let earlierDemoDiscussion = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Riley Lead",
      body: "v1 review: the demo recipe must use the managed port.",
      createdAt: Date(timeIntervalSince1970: 50)
    )
    let implementerCompletion = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Alex Implementer",
      body: "Delivered the change.\n\nDemo: Accepted browser app · Web demo",
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let unrelatedFeedback = TicketComment(
      workItemID: workItemID,
      authorKind: .agent,
      authorName: "Riley Lead",
      body: "Fix the truncated Markdown command in README.md.",
      createdAt: Date(timeIntervalSince1970: 150)
    )

    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForContinuation(
        latestCandidate: sentBack,
        runID: runID,
        implementerName: "Alex Implementer",
        comments: [earlierDemoDiscussion, implementerCompletion, unrelatedFeedback]
      ) == browserRecipe()
    )

    let demoFailureSendBack = TicketComment(
      workItemID: workItemID,
      authorKind: .system,
      authorName: "Spedito",
      body: "The reviewed candidate failed its managed demo verification.",
      createdAt: Date(timeIntervalSince1970: 160)
    )
    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForContinuation(
        latestCandidate: sentBack,
        runID: runID,
        implementerName: "Alex Implementer",
        comments: [implementerCompletion, unrelatedFeedback, demoFailureSendBack]
      ) == nil
    )

    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForContinuation(
        latestCandidate: sentBack,
        runID: UUID(),
        implementerName: "Alex Implementer",
        comments: [unrelatedFeedback]
      ) == nil
    )

    let queued = try candidate(
      workItemID: workItemID,
      implementationRunID: runID,
      status: .queuedForIntegration,
      integratedSHA: nil,
      demo: browserRecipe()
    )
    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForContinuation(
        latestCandidate: queued,
        runID: runID,
        implementerName: "Alex Implementer",
        comments: [unrelatedFeedback]
      ) == nil
    )

    #expect(
      DemoRecipeRevisionPolicy.pinnedRecipeForContinuation(
        latestCandidate: nil,
        runID: runID,
        implementerName: "Alex Implementer",
        comments: [unrelatedFeedback]
      ) == nil
    )
  }

  private func browserRecipe() -> DemoLaunchSpecification {
    DemoLaunchSpecification(
      title: "Accepted browser app",
      launchCommand: DemoCommand(
        executable: "python3",
        arguments: ["-m", "http.server", "{{PORT}}", "--bind", "127.0.0.1"]
      ),
      portEnvironmentVariable: "PORT",
      readiness: DemoReadinessCheck(kind: .http, path: "/"),
      presentation: DemoPresentation(kind: .browser, path: "/index.html")
    )
  }

  private func macApplicationRecipe() -> DemoLaunchSpecification {
    DemoLaunchSpecification(
      title: "Accepted macOS app",
      preparationCommands: [
        DemoCommand(executable: "swift", arguments: ["build"])
      ],
      presentation: DemoPresentation(kind: .macApplication, path: ".build/Accepted.app")
    )
  }

  private func terminalRecipe() -> DemoLaunchSpecification {
    DemoLaunchSpecification(
      title: "Accepted terminal app",
      preparationCommands: [
        DemoCommand(executable: "scripts/build.sh")
      ],
      launchCommand: DemoCommand(executable: "bin/tui"),
      presentation: DemoPresentation(kind: .terminalApplication)
    )
  }

  private func candidate(
    id: UUID = UUID(),
    productID: UUID = UUID(),
    workItemID: UUID = UUID(),
    implementationRunID: UUID = UUID(),
    status: CandidateRevisionStatus = .accepted,
    integratedSHA: String? = "integrated",
    version: Int = 1,
    demo: DemoLaunchSpecification?,
    executionResultJSON: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1),
    updatedAt: Date = Date(timeIntervalSince1970: 1)
  ) throws -> CandidateRevision {
    let result = TicketExecutionResult(
      status: .completed,
      comment: "Delivered the accepted result.",
      question: nil,
      options: [],
      summary: "Accepted result",
      changedFiles: ["Sources/App.swift"],
      tests: ["Verified"],
      knowledgeNotes: [],
      reviewInstructions: ["Open the app."],
      demo: demo,
      retrospectiveWentWell: [],
      retrospectiveCouldImprove: [],
      retrospectiveActions: []
    )
    let encodedResult = try JSONEncoder().encode(result)

    return CandidateRevision(
      id: id,
      productID: productID,
      sprintID: UUID(),
      sprintItemID: UUID(),
      workItemID: workItemID,
      implementationRunID: implementationRunID,
      version: version,
      branchName: "ticket/T\(version)",
      baseSHA: "base",
      headSHA: "head",
      integratedSHA: integratedSHA,
      worktreePath: "/private/tmp/ticket",
      status: status,
      commitCount: 1,
      executionResultJSON: executionResultJSON ?? String(decoding: encodedResult, as: UTF8.self),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
