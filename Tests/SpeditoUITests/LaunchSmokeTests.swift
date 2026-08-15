import XCTest

final class LaunchSmokeTests: XCTestCase {
  func testDebugBundleLaunches() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let applicationURL = repositoryRoot
      .appendingPathComponent(".build/app/debug/Spedito.app", isDirectory: true)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: applicationURL.path),
      "Build the debug app bundle before running UI tests."
    )

    let app = XCUIApplication(url: applicationURL)
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    app.terminate()
  }
}
