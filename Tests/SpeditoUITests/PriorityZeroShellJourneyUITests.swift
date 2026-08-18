import Foundation
import XCTest

final class PriorityZeroShellJourneyUITests: XCTestCase {
  private struct FixtureManifest: Decodable {
    let selectedProductID: UUID
    let firstProductID: UUID
    let secondProductID: UUID?
    let workItemID: UUID?
    let sprintID: UUID?
    let threadID: UUID?
    let messageID: UUID?
    let permissionRequestID: UUID?
    let candidateRevisionIDs: [UUID]
    let remoteSafeSyncID: UUID?
    let retrospectiveNoteID: UUID?
    let sourceWorkItemID: UUID?
    let knowledgePageID: UUID?
  }

  private struct FixtureSession {
    let app: XCUIApplication
    let manifest: FixtureManifest
    let rootURL: URL
  }

  /// Existing deterministic coverage:
  /// - `ProductScopedPersistenceTests.a02BlankProductActivatesCompleteLocalWorkspace`
  /// This launched-process test covers only A02's application-shell projection of that workspace.
  func testA02BlankProductLaunchesItsCompleteWorkspace() throws {
    let session = try launchFixture("a02")

    XCTAssertTrue(element(session.app, "nav.backlog").isSelected)
    XCTAssertTrue(element(session.app, "epic.new").exists)
    XCTAssertTrue(element(session.app, "nav.products").value as? String == "A02 complete workspace")
  }

  /// Existing deterministic coverage:
  /// - `ProductScopedPersistenceTests.a05RelaunchRestoresWorkspaceTuple`
  /// This launched-process test covers only A05's restored Product, destination, and sprint projection.
  func testA05RelaunchRestoresProductDestinationAndSprint() throws {
    let session = try launchFixture("a05")
    let workItemID = try XCTUnwrap(session.manifest.workItemID)

    XCTAssertTrue(element(session.app, "sprint.board").waitForExistence(timeout: 10))
    XCTAssertTrue(
      element(session.app, "sprint.ticket.\(workItemID.uuidString)").waitForExistence(timeout: 10))
    XCTAssertEqual(session.manifest.selectedProductID, session.manifest.firstProductID)
    XCTAssertNotNil(session.manifest.sprintID)
  }

  /// Existing deterministic coverage:
  /// - `ProductScopedPersistenceTests.a06ArchivingSelectedProductRoutesToRemainingProduct`
  /// This launched-process test covers only A06's active and archived Product-library projection.
  func testA06ArchivingSelectedProductRoutesToRemainingProduct() throws {
    let session = try launchFixture("a06")
    let remainingID = try XCTUnwrap(session.manifest.secondProductID)

    element(session.app, "nav.products").click()
    XCTAssertTrue(
      element(session.app, "product.row.\(remainingID.uuidString)").waitForExistence(timeout: 5))
    let archivedToggle = element(session.app, "products.archived.toggle")
    XCTAssertTrue(archivedToggle.waitForExistence(timeout: 5))
    archivedToggle.click()
    XCTAssertTrue(
      element(session.app, "product.archived.row.\(session.manifest.firstProductID.uuidString)")
        .waitForExistence(timeout: 5)
    )
  }

  /// Existing deterministic coverage:
  /// - `ProductScopedPersistenceTests.a07RestorePreservesCompleteProductHistory`
  /// This launched-process test covers only A07's archived-Product restore control and workspace route.
  func testA07ArchivedProductRestoresIntoItsWorkspace() throws {
    let session = try launchFixture("a07")
    let productID = session.manifest.firstProductID

    element(session.app, "nav.products").click()
    let archivedToggle = element(session.app, "products.archived.toggle")
    XCTAssertTrue(archivedToggle.waitForExistence(timeout: 5))
    archivedToggle.click()

    let restore = element(session.app, "product.archived.restore.\(productID.uuidString)")
    XCTAssertTrue(restore.waitForExistence(timeout: 5))
    XCTAssertTrue(restore.isEnabled)
    restore.click()

    XCTAssertTrue(element(session.app, "nav.products").waitForExistence(timeout: 10))
    XCTAssertTrue(element(session.app, "nav.backlog").isSelected)
  }

  /// Existing deterministic coverage:
  /// - `TicketAttentionTests.b02ClosingIncompleteTicketCanReturnFromAnotherProduct`
  /// This launched-process test covers only B02's source-Product switch and exact ticket presentation.
  func testB02ClosingIncompleteTicketReturnsToExactSourceTicket() throws {
    let session = try launchFixture("b02")
    let workItemID = try XCTUnwrap(session.manifest.workItemID)

    try switchProduct(session, to: session.manifest.firstProductID)
    let ticketRow = session.app.staticTexts.matching(
      identifier: "ticket.row.\(workItemID.uuidString)"
    ).firstMatch
    XCTAssertTrue(ticketRow.waitForExistence(timeout: 10))
    ticketRow.click()
    XCTAssertTrue(
      element(session.app, "ticket.detail.\(workItemID.uuidString)").waitForExistence(timeout: 5)
    )
  }

  /// Existing deterministic coverage:
  /// - `TicketAttentionTests.c07BackgroundChatOpensExactThreadAndClearsOnlyThatUnreadTarget`
  /// This launched-process test covers only C07's source-Product Chat thread and persisted reply.
  func testC07BackgroundChatOpensItsExactSourceThread() throws {
    let session = try launchFixture("c07")
    let threadID = try XCTUnwrap(session.manifest.threadID)
    let messageID = try XCTUnwrap(session.manifest.messageID)

    try switchProduct(session, to: session.manifest.firstProductID)
    element(session.app, "nav.conversation").click()
    let thread = element(session.app, "conversation.thread.\(threadID.uuidString)")
    XCTAssertTrue(thread.waitForExistence(timeout: 10))
    thread.click()
    let reply = element(session.app, "conversation.message.\(messageID.uuidString)")
    XCTAssertTrue(reply.waitForExistence(timeout: 5))
    XCTAssertTrue(reply.label.contains("C07 background reply"))
  }

  /// Existing deterministic coverage:
  /// - `TicketDeliveryWorkflowCoordinatorTests.d08PermissionReviewSupportsDenyAllowOnceAndAlwaysAllow`
  /// This launched-process test covers only D08's three owner decision controls in the ticket work log.
  func testD08PermissionReviewPresentsDenyAllowOnceAndAlwaysAllow() throws {
    let session = try launchFixture("d08")
    try openPermissionTicket(session)
    let requestID = try XCTUnwrap(session.manifest.permissionRequestID)

    XCTAssertTrue(
      element(session.app, "permission.deny.\(requestID.uuidString)").waitForExistence(timeout: 5))
    XCTAssertTrue(element(session.app, "permission.allow-once.\(requestID.uuidString)").exists)
    XCTAssertTrue(element(session.app, "permission.always.\(requestID.uuidString)").exists)
  }

  /// Existing deterministic coverage:
  /// - `TicketDeliveryWorkflowCoordinatorTests.d09SubmittedAnswersResumeExactRun`
  /// This launched-process test covers only D09's listed choice, Other, and Submit answers wiring.
  func testD09OwnerQuestionPresentsListedOtherAndSubmitAnswers() throws {
    let session = try launchFixture("d09")
    try openPermissionTicket(session)

    let prompt = element(session.app, "sprint.ticket.owner-question.prompt")
    XCTAssertTrue(prompt.waitForExistence(timeout: 5))
    let firstChoice = element(session.app, "sprint.ticket.owner-question.option.0")
    let secondChoice = element(session.app, "sprint.ticket.owner-question.option.1")
    let otherChoice = element(session.app, "sprint.ticket.owner-question.other")
    XCTAssertTrue(firstChoice.exists)
    XCTAssertTrue(secondChoice.exists)
    XCTAssertTrue(otherChoice.exists)
    XCTAssertTrue(firstChoice.label.contains("Stable"))
    XCTAssertTrue(secondChoice.label.contains("Preview"))

    firstChoice.click()
    let submitAnswers = element(session.app, "sprint.ticket.owner-question.submit")
    XCTAssertTrue(submitAnswers.exists)
    XCTAssertTrue(submitAnswers.isEnabled)

    otherChoice.click()
    let customAnswer = element(session.app, "sprint.ticket.owner-question.custom")
    XCTAssertTrue(customAnswer.waitForExistence(timeout: 5))
    customAnswer.click()
    customAnswer.typeText("Canary")
    XCTAssertTrue(submitAnswers.isEnabled)
    submitAnswers.click()
    wait(
      until: NSPredicate(format: "exists == false"),
      evaluates: submitAnswers,
      timeout: 10,
      message: "Submitting the owner answer did not settle the paused question."
    )
  }

  /// Existing deterministic coverage:
  /// - `TicketDeliveryWorkflowCoordinatorTests.d14DemoPreparationRetryReusesReviewedCandidate`
  /// - `MacOSDemoLauncherTests.hostFailureDisposition`
  /// This launched-process test covers only D14's immutable reviewed-candidate selection in App versions.
  func testD14DemoRetrySelectsTheReviewedCandidate() throws {
    let session = try launchFixture("d14")
    let reviewedCandidateID = try XCTUnwrap(session.manifest.candidateRevisionIDs.first)

    element(session.app, "nav.app").click()
    XCTAssertTrue(element(session.app, "app.versions").waitForExistence(timeout: 10))
    let reviewedVersion = element(session.app, "app.version.\(reviewedCandidateID.uuidString)")
    XCTAssertTrue(reviewedVersion.waitForExistence(timeout: 5))
    reviewedVersion.click()
    let open = element(session.app, "app.version.open")
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    XCTAssertTrue(open.isEnabled)
  }

  /// Existing deterministic coverage:
  /// - `SprintTicketWorkLogHistoryTests.d15ReadyForDemoCommentPreservesCandidate`
  /// - `SprintTicketWorkLogHistoryTests.readyForDemoCommentRouting`
  /// This launched-process test covers only D15's owner comment control and the still-actionable
  /// reviewed candidate after that comment settles.
  func testD15ReadyForDemoCommentKeepsCandidateActionable() throws {
    let session = try launchFixture("d15")
    try openPermissionTicket(session)
    XCTAssertEqual(session.manifest.candidateRevisionIDs.count, 1)

    let editor = session.app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    editor.typeText("Confirm the empty state during the demo.")
    let send = element(session.app, "sprint.ticket.comment.send")
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertTrue(send.isEnabled)
    send.click()
    wait(
      until: NSPredicate(format: "value == ''"),
      evaluates: editor,
      timeout: 10,
      message: "D15 comment did not settle."
    )

    let approve = element(session.app, "sprint.ticket.approve")
    XCTAssertTrue(approve.waitForExistence(timeout: 5))
    XCTAssertTrue(approve.isEnabled)
  }

  /// Existing deterministic coverage:
  /// - `TicketDeliveryWorkflowCoordinatorTests.repositoryAcceptancePromotesExactRevision`
  /// This launched-process test covers only D17's immediate detail dismissal and Completing
  /// projection while repository-changing acceptance remains in progress.
  func testD17ApprovalClosesDetailAndPresentsCompleting() throws {
    let session = try launchFixture("d17")
    let workItemID = try XCTUnwrap(session.manifest.workItemID)
    try openPermissionTicket(session)

    let detail = element(session.app, "ticket.detail.\(workItemID.uuidString)")
    let approve = element(session.app, "sprint.ticket.approve")
    XCTAssertTrue(approve.waitForExistence(timeout: 5))
    approve.click()

    wait(
      until: NSPredicate(format: "exists == false"),
      evaluates: detail,
      timeout: 5,
      message: "D17 approval did not close Ticket detail immediately."
    )
    let ticket = element(session.app, "sprint.ticket.\(workItemID.uuidString)")
    wait(
      until: NSPredicate(format: "label CONTAINS %@", "Completing ticket"),
      evaluates: ticket,
      timeout: 5,
      message: "D17 Ticket did not present the Completing state. \(ticket.debugDescription)"
    )
    waitForFixtureSignal(
      "d17-acceptance-started-\(workItemID.uuidString)",
      session: session,
      message: "D17 approval did not enter the acceptance coordinator."
    )
  }

  /// Existing deterministic coverage:
  /// - `SQLiteStoreTests.retrospectiveEvidenceLifecycle`
  /// - `TicketConversationHistoryTests.completeHistory`
  /// This launched-process test covers only I07's Backlog routing, exact Ticket detail, and
  /// normal Business Analyst refinement start after accepting the retrospective action.
  func testI07AcceptedRetrospectiveActionOpensExactTicketRefinement() throws {
    let session = try launchFixture("i07")
    let noteID = try XCTUnwrap(session.manifest.retrospectiveNoteID)
    let sourceWorkItemID = try XCTUnwrap(session.manifest.sourceWorkItemID)
    element(session.app, "nav.retrospectives").click()
    let accept = element(
      session.app,
      "retrospective.action.accept.\(noteID.uuidString)"
    )
    XCTAssertTrue(accept.waitForExistence(timeout: 10))
    accept.click()

    waitForFixtureSignal(
      "i07-refinement-started",
      session: session,
      message: "I07 did not start the Business Analyst refinement turn."
    )
    let acceptedWorkItemID = try XCTUnwrap(
      UUID(
        uuidString: String(
          contentsOf: session.rootURL.appendingPathComponent(
            "i07-accepted-work-item-id"
          ),
          encoding: .utf8
        )
      )
    )
    let detailPrefix = "ticket.detail."
    let detail = session.app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", detailPrefix)
    ).firstMatch
    XCTAssertTrue(detail.waitForExistence(timeout: 5))
    let openedWorkItemID = try XCTUnwrap(
      UUID(uuidString: String(detail.identifier.dropFirst(detailPrefix.count)))
    )

    XCTAssertEqual(
      openedWorkItemID,
      acceptedWorkItemID,
      "I07 did not open the exact Backlog Ticket created by retrospective acceptance."
    )
    XCTAssertTrue(element(session.app, "nav.backlog").isSelected)
    XCTAssertNotEqual(
      openedWorkItemID,
      sourceWorkItemID,
      "I07 reopened the released source delivery instead of the Backlog Ticket created by acceptance."
    )
  }

  /// Existing deterministic coverage:
  /// - `SQLiteStoreTests.p05MissingEstimatesAndInvalidDependenciesBlockSprintStart`
  /// - `SprintStartAvailabilityTests.activeSprintBlocksDraftStart`
  /// This launched-process test covers only P05's blocker projection in sprint planning.
  func testP05SprintPlanningShowsStartBlockers() throws {
    let session = try launchFixture("p05")

    element(session.app, "nav.sprint").click()
    let start = element(session.app, "sprint.start")
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    XCTAssertFalse(start.isEnabled)
    let issues = element(session.app, "sprint.readiness.issues")
    XCTAssertTrue(issues.waitForExistence(timeout: 5))
    XCTAssertTrue(issues.label.contains("T2 needs an estimate before the sprint can start."))
    XCTAssertTrue(
      issues.label.contains(
        "T2 is blocked by T1, which is not in this sprint, the active sprint, or done."
      )
    )
  }

  /// Existing deterministic coverage:
  /// - `RemoteRepositoryAppModelTests.r05EmptyGitHubRepositoryCreatesAndConnectsBlankProduct`
  /// - `RemoteRepositoryServiceTests.localProductLifecycle`
  /// This launched-process test covers only R05's connected repository projection in Product settings.
  func testR05ConnectedBlankProductShowsItsExactGitHubRepository() throws {
    let session = try launchFixture("r05")

    element(session.app, "nav.product-settings").click()
    XCTAssertTrue(
      element(session.app, "github.settings.\(session.manifest.firstProductID.uuidString)")
        .waitForExistence(timeout: 10)
    )
    let repository = element(
      session.app,
      "github.repository.\(session.manifest.firstProductID.uuidString)"
    )
    XCTAssertTrue(repository.waitForExistence(timeout: 5))
    XCTAssertTrue(repository.label.contains("spedito-fixture/owner-journey"))
  }

  /// Existing deterministic coverage:
  /// - `RemoteRepositoryAppModelTests.r13IncomingChangesAcceptRejectAndRecoverAfterInterruption`
  /// - `RemoteRepositoryServiceTests.remoteAheadSafeSync`
  /// This launched-process test covers only R13's exact incoming-candidate review sheet.
  func testR13IncomingChangesOpenExactReviewCandidate() throws {
    let session = try launchFixture("r13")
    let syncID = try XCTUnwrap(session.manifest.remoteSafeSyncID)

    let review = element(session.app, "github.review-incoming")
    XCTAssertTrue(review.waitForExistence(timeout: 15))
    review.click()
    XCTAssertTrue(
      element(session.app, "github.incoming-review.\(syncID.uuidString)")
        .waitForExistence(timeout: 10)
    )
  }

  /// Existing deterministic coverage:
  /// - `CodebaseCommitOriginTests.v04CommitOriginAndDetailMode`
  /// This launched-process test covers V04's exact commit-to-Ticket routing through Codebase.
  func testV04CommitOpensItsExactTicketInEditableMode() throws {
    let session = try launchFixture("v04")
    let workItemID = try XCTUnwrap(session.manifest.workItemID)

    element(session.app, "nav.codebase").click()
    let open = element(
      session.app,
      "codebase.commit.open-ticket.\(workItemID.uuidString)"
    )
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.click()
    let detail = element(session.app, "ticket.detail.\(workItemID.uuidString)")
    XCTAssertTrue(detail.waitForExistence(timeout: 5))
    XCTAssertEqual(detail.value as? String, "Editable")
  }

  /// Existing deterministic coverage:
  /// - `MacOSDemoLauncherTests.v06HistoricalAcceptedVersionLaunchesExactRevision`
  /// - `DemoLaunchTests.acceptedMacApplicationHistory`
  /// This launched-process test covers only V06's historical accepted-version selection contract.
  func testV06HistoricalAcceptedAppVersionIsIndependentlySelectable() throws {
    let session = try launchFixture("v06")
    XCTAssertEqual(session.manifest.candidateRevisionIDs.count, 2)
    let historicalID = session.manifest.candidateRevisionIDs[0]
    let latestID = session.manifest.candidateRevisionIDs[1]

    element(session.app, "nav.app").click()
    XCTAssertTrue(
      element(session.app, "app.version.\(latestID.uuidString)").waitForExistence(timeout: 10))
    let historical = element(session.app, "app.version.\(historicalID.uuidString)")
    XCTAssertTrue(historical.waitForExistence(timeout: 5))
    historical.click()
    let open = element(session.app, "app.version.open")
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    XCTAssertTrue(open.isEnabled)
  }

  /// Existing deterministic coverage:
  /// - `KnowledgePageReadStateTests.k05KnowledgeAnswersLinkOnlyCitedVerifiedPages`
  /// This launched-process test covers only K05's Knowledge sheet and exact-citation routing.
  func testK05GroundedAnswerOpensItsExactCitedKnowledgePage() throws {
    let session = try launchFixture("k05")
    let pageID = try XCTUnwrap(session.manifest.knowledgePageID)

    element(session.app, "nav.knowledge").click()
    let ask = element(session.app, "knowledge.ask")
    XCTAssertTrue(ask.waitForExistence(timeout: 10))
    wait(
      until: NSPredicate(format: "enabled == true"),
      evaluates: ask,
      timeout: 10,
      message: "The fixture Codex connection did not become ready for a Knowledge question."
    )
    ask.click()
    ask.typeText("What must happen before a production release?")
    ask.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(element(session.app, "knowledge.answer-sheet").waitForExistence(timeout: 10))
    XCTAssertTrue(element(session.app, "knowledge.answer.text").exists)
    XCTAssertTrue(
      session.app.staticTexts[
        "Production releases require product owner acceptance."
      ].exists
    )
    let citation = element(
      session.app,
      "knowledge.answer.citation.\(pageID.uuidString)"
    )
    XCTAssertTrue(citation.waitForExistence(timeout: 5))
    citation.click()
    XCTAssertTrue(
      element(session.app, "knowledge.page.\(pageID.uuidString)").waitForExistence(timeout: 5)
    )
  }

  private func openPermissionTicket(_ session: FixtureSession) throws {
    let workItemID = try XCTUnwrap(session.manifest.workItemID)
    element(session.app, "nav.sprint").click()
    let ticket = element(session.app, "sprint.ticket.\(workItemID.uuidString)")
    XCTAssertTrue(ticket.waitForExistence(timeout: 10))
    XCTAssertTrue(ticket.isHittable, ticket.debugDescription)
    ticket.press(forDuration: 0.1)
    let openedSignalURL = session.rootURL.appendingPathComponent(
      "sprint-ticket-opened-\(workItemID.uuidString)"
    )
    let opened = expectation(
      for: NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: openedSignalURL.path)
      },
      evaluatedWith: NSObject()
    )
    let openedResult = XCTWaiter.wait(for: [opened], timeout: 3)
    XCTAssertEqual(openedResult, .completed, "The sprint ticket action did not run.")
    guard openedResult == .completed else { return }
    XCTAssertTrue(
      element(session.app, "ticket.detail.\(workItemID.uuidString)").waitForExistence(timeout: 5)
    )
  }

  private func switchProduct(_ session: FixtureSession, to productID: UUID) throws {
    let productLibrary = element(session.app, "nav.products")
    productLibrary.click()
    let row = element(session.app, "product.row.\(productID.uuidString)")
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.click()
    let open = element(session.app, "products.open")
    XCTAssertTrue(open.isEnabled)
    open.click()
    wait(
      until: NSPredicate(format: "exists == false"),
      evaluates: open,
      timeout: 10,
      message: "The Product library did not close after switching Products."
    )
  }

  private func waitForFixtureSignal(
    _ name: String,
    session: FixtureSession,
    message: String
  ) {
    let signalURL = session.rootURL.appendingPathComponent(name)
    wait(
      until: NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: signalURL.path)
      },
      evaluates: NSObject(),
      timeout: 10,
      message: message
    )
  }

  private func launchFixture(_ scenario: String) throws -> FixtureSession {
    let applicationURL = try speditoUITestApplicationURL()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: applicationURL.path),
      "Build the debug app bundle before running UI tests."
    )

    let cachesURL = try XCTUnwrap(
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    )
    let fixtureRoot =
      cachesURL
      .appendingPathComponent("spedito-ui-\(scenario)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let app = XCUIApplication(url: applicationURL)
    app.launchEnvironment["SPEDITO_UI_TEST_FIXTURE"] = scenario
    app.launchEnvironment["SPEDITO_UI_FIXTURE_ROOT"] = fixtureRoot.path
    app.launch()
    app.activate()
    addTeardownBlock {
      terminateSpeditoUITestApplication(app)
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

    let manifestURL = fixtureRoot.appendingPathComponent("fixture-manifest.json")
    wait(
      until: NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: manifestURL.path)
      },
      evaluates: NSObject(),
      timeout: 15,
      message: "The launched fixture did not publish its explicit ready manifest."
    )
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      let alert = app.alerts.firstMatch
      XCTFail(
        "Fixture preparation failed before publishing its manifest. \(alert.debugDescription)"
      )
      throw CocoaError(.fileNoSuchFile)
    }
    let manifest = try JSONDecoder().decode(
      FixtureManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    XCTAssertTrue(
      element(app, "nav.products").waitForExistence(timeout: 15),
      "The launched app did not finish loading its fixture Product."
    )
    let alert = app.alerts.firstMatch
    XCTAssertFalse(alert.exists, alert.debugDescription)
    return FixtureSession(app: app, manifest: manifest, rootURL: fixtureRoot)
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func wait(
    until predicate: NSPredicate,
    evaluates object: Any,
    timeout: TimeInterval,
    message: String
  ) {
    let readiness = expectation(for: predicate, evaluatedWith: object)
    let result = XCTWaiter.wait(for: [readiness], timeout: timeout)
    XCTAssertEqual(result, .completed, message)
  }
}
