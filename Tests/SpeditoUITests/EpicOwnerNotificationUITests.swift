import XCTest

final class EpicOwnerNotificationUITests: XCTestCase {
  private struct FixtureManifest: Decodable {
    let firstProductID: UUID
    let secondProductID: UUID
  }

  func testE02NeedsInputOpensTheExactEpicAcrossProducts() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let applicationURL =
      repositoryRoot
      .appendingPathComponent(".build/app/debug/Spedito.app", isDirectory: true)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: applicationURL.path),
      "Build the debug app bundle before running UI tests."
    )

    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-ui-e02-\(UUID().uuidString)", isDirectory: true)
    let releaseSignalURL = fixtureRoot.appendingPathComponent("release-epic-turn")
    let turnStartedSignalURL = fixtureRoot.appendingPathComponent("epic-turn-started")
    try FileManager.default.createDirectory(
      at: fixtureRoot,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: fixtureRoot)
    }

    let app = XCUIApplication(url: applicationURL)
    app.launchEnvironment["SPEDITO_UI_TEST_FIXTURE"] = "epic-needs-input"
    app.launchEnvironment["SPEDITO_UI_FIXTURE_ROOT"] = fixtureRoot.path
    app.launchEnvironment["SPEDITO_UI_FIXTURE_SIGNAL"] = releaseSignalURL.path
    app.launch()
    addTeardownBlock {
      if app.state != .notRunning {
        app.terminate()
      }
    }
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

    let codexConnection = app.buttons["codex.connection"]
    XCTAssertTrue(codexConnection.waitForExistence(timeout: 15))
    wait(
      until: NSPredicate(format: "value CONTAINS 'Connected'"),
      evaluates: codexConnection,
      timeout: 15,
      message: "The fixture Codex connection did not become ready."
    )

    let newEpicButton = app.buttons["epic.new"]
    XCTAssertTrue(
      newEpicButton.waitForExistence(timeout: 15),
      "The launched app did not make the Backlog ready."
    )

    let manifestData = try Data(
      contentsOf: fixtureRoot.appendingPathComponent("fixture-manifest.json")
    )
    let manifest = try JSONDecoder().decode(FixtureManifest.self, from: manifestData)
    XCTAssertNotEqual(manifest.firstProductID, manifest.secondProductID)

    newEpicButton.click()
    let outcomeEditor = app.textViews["epic.outcome"]
    XCTAssertTrue(outcomeEditor.waitForExistence(timeout: 5))
    outcomeEditor.click()
    outcomeEditor.typeText("Let owners preserve draft notes")

    let createEpicButton = app.buttons["epic.create"]
    XCTAssertTrue(createEpicButton.isEnabled)
    createEpicButton.click()

    let epicDetail = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH 'epic.detail.'")
    ).firstMatch
    XCTAssertTrue(
      epicDetail.waitForExistence(timeout: 10),
      "Creating the Epic did not present its real detail view."
    )
    let epicID = String(epicDetail.identifier.dropFirst("epic.detail.".count))
    XCTAssertFalse(epicID.isEmpty)

    wait(
      until: NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: turnStartedSignalURL.path)
      },
      evaluates: NSObject(),
      timeout: 10,
      message: "The scripted Epic operation did not reach its explicit response gate."
    )

    app.buttons["epic.done"].click()
    wait(
      until: NSPredicate(format: "exists == false"),
      evaluates: epicDetail,
      timeout: 5,
      message: "Closing the Epic detail did not return to the Backlog."
    )
    let epicRow = app.buttons["epic.row.\(epicID)"]
    XCTAssertTrue(epicRow.waitForExistence(timeout: 5))

    let productLibraryButton = app.buttons["nav.products"]
    XCTAssertTrue(productLibraryButton.waitForExistence(timeout: 5))
    productLibraryButton.click()

    let secondProductRow = app.buttons[
      "product.row.\(manifest.secondProductID.uuidString)"
    ]
    XCTAssertTrue(secondProductRow.waitForExistence(timeout: 5))
    secondProductRow.click()
    app.buttons["Open"].click()
    wait(
      until: NSPredicate(format: "value CONTAINS 'Second product'"),
      evaluates: productLibraryButton,
      timeout: 10,
      message: "The launched app did not switch to the second Product."
    )

    XCTAssertTrue(FileManager.default.createFile(atPath: releaseSignalURL.path, contents: Data()))

    let banner = app.staticTexts["owner-notification.banner"]
    XCTAssertTrue(
      banner.waitForExistence(timeout: 10),
      "The fixture-controlled post-launch completion did not show the in-app banner."
    )

    let openEpicButton = app.buttons["owner-notification.open"]
    XCTAssertTrue(openEpicButton.exists)
    openEpicButton.click()

    XCTAssertTrue(epicDetail.waitForExistence(timeout: 10))
    wait(
      until: NSPredicate(format: "value CONTAINS 'First product'"),
      evaluates: productLibraryButton,
      timeout: 5,
      message: "Opening the banner did not return to the owning Product."
    )
    let backlogDestination = app.descendants(matching: .any)["nav.backlog"].firstMatch
    XCTAssertTrue(backlogDestination.exists)
    XCTAssertTrue(backlogDestination.isSelected)
    XCTAssertTrue(
      app.staticTexts["I need one product decision."].waitForExistence(timeout: 5)
    )

    let question = app.staticTexts["epic.question.0"].firstMatch
    XCTAssertTrue(question.waitForExistence(timeout: 5))

    let firstChoice = app.buttons["epic.question.0.choice.0"]
    let secondChoice = app.buttons["epic.question.0.choice.1"]
    XCTAssertTrue(firstChoice.exists)
    XCTAssertTrue(secondChoice.exists)
    XCTAssertTrue(firstChoice.label.contains("On this Mac"))
    XCTAssertTrue(secondChoice.label.contains("In the repository"))

    let otherChoice = app.buttons["epic.question.0.choice.other"]
    XCTAssertTrue(otherChoice.exists)
    otherChoice.click()
    let otherAnswer = app.textFields["epic.question.0.other"]
    XCTAssertTrue(otherAnswer.waitForExistence(timeout: 5))
    otherAnswer.click()
    otherAnswer.typeText("Keep drafts on this Mac")

    let submitAnswers = app.buttons["epic.submit-answers"]
    XCTAssertTrue(submitAnswers.exists)
    XCTAssertTrue(submitAnswers.isEnabled)
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
