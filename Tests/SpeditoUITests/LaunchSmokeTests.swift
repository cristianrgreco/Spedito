import XCTest

final class LaunchSmokeTests: XCTestCase {
  func testDebugBundleLaunches() throws {
    let applicationURL = Bundle(for: type(of: self)).bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Spedito.app", isDirectory: true)
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
