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
      if app.state != .notRunning {
        app.terminate()
      }
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