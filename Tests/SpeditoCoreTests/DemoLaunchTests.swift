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
      CodexTicketExecutor.demoLaunchSpecificationSchema["anyOf"]?.arrayValue
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

  private func candidate(
    id: UUID = UUID(),
    productID: UUID = UUID(),
    workItemID: UUID = UUID(),
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
      implementationRunID: UUID(),
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
