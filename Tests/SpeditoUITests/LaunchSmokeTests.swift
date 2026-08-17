import Darwin
import XCTest

final class LaunchSmokeTests: XCTestCase {
  func testDebugBundleLaunches() throws {
    let applicationURL = try speditoUITestApplicationURL()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: applicationURL.path),
      "Build the debug app bundle before running UI tests."
    )

    let app = XCUIApplication(url: applicationURL)
    addTeardownBlock {
      terminateSpeditoUITestApplication(app)
    }
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
  }
}

func speditoUITestApplicationURL() throws -> URL {
  URL(
    fileURLWithPath: "/tmp/spedito-ui-tests-\(getuid())/Spedito.app",
    isDirectory: true
  )
}

func terminateSpeditoUITestApplication(_ app: XCUIApplication) {
  guard app.state != .notRunning else { return }
  app.terminate()
  XCTAssertTrue(
    app.wait(for: .notRunning, timeout: 15),
    "The launched Spedito fixture did not terminate before the next UI contract."
  )
}