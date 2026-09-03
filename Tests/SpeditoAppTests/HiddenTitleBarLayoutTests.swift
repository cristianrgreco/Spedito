import SwiftUI
import Testing

@testable import SpeditoApp

@Suite("Hidden title bar layout")
struct HiddenTitleBarLayoutTests {
  @Test("Windowed workspace content extends under the hidden title bar")
  func windowedContentExtendsUnderTitleBar() {
    #expect(
      HiddenTitleBarLayoutPolicy.ignoredEdges(
        isActive: true,
        isWindowFullScreen: false
      ) == .top
    )
  }

  @Test("Full screen keeps the top safe area so the header stays visible")
  func fullScreenKeepsTopSafeArea() {
    #expect(
      HiddenTitleBarLayoutPolicy.ignoredEdges(
        isActive: true,
        isWindowFullScreen: true
      ) == []
    )
  }

  @Test("Detail-only layouts keep the top safe area in any window state")
  func detailOnlyKeepsTopSafeArea() {
    #expect(
      HiddenTitleBarLayoutPolicy.ignoredEdges(
        isActive: false,
        isWindowFullScreen: false
      ) == []
    )
    #expect(
      HiddenTitleBarLayoutPolicy.ignoredEdges(
        isActive: false,
        isWindowFullScreen: true
      ) == []
    )
  }
}
