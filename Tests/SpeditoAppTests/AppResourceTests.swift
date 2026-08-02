import AppKit
import Testing
@testable import SpeditoApp

@Suite("App resources")
@MainActor
struct AppResourceTests {
  @Test("The packaged app icon has PNG and native macOS representations")
  func appIconResources() throws {
    let pngURL = try #require(
      SpeditoResources.url(
        forResource: "AppIcon",
        withExtension: "png"
      )
    )
    let icnsURL = try #require(
      SpeditoResources.url(
        forResource: "AppIcon",
        withExtension: "icns"
      )
    )

    #expect(NSImage(contentsOf: pngURL) != nil)
    #expect(NSImage(contentsOf: icnsURL) != nil)
  }
}
