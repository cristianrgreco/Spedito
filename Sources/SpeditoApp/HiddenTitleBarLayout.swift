import AppKit
import SwiftUI

/// Decides when workspace content may extend under the hidden window title
/// bar.
///
/// A normal window with `.hiddenTitleBar` still reserves a top safe-area
/// strip where the title bar would be; extending under it lets a workspace
/// header occupy that strip instead of leaving it empty. In full screen the
/// same strip sits above the visible screen, so extending under it pushes the
/// header off screen and the safe area must be respected.
enum HiddenTitleBarLayoutPolicy {
  static func ignoredEdges(isActive: Bool, isWindowFullScreen: Bool) -> Edge.Set {
    isActive && !isWindowFullScreen ? .top : []
  }
}

extension View {
  func extendsUnderHiddenTitleBar(_ isActive: Bool = true) -> some View {
    modifier(HiddenTitleBarLayout(isActive: isActive))
  }
}

private struct HiddenTitleBarLayout: ViewModifier {
  let isActive: Bool
  @State private var isWindowFullScreen = false

  func body(content: Content) -> some View {
    content
      .ignoresSafeArea(
        .container,
        edges: HiddenTitleBarLayoutPolicy.ignoredEdges(
          isActive: isActive,
          isWindowFullScreen: isWindowFullScreen
        )
      )
      .background(WindowFullScreenReader(isFullScreen: $isWindowFullScreen))
  }
}

private struct WindowFullScreenReader: NSViewRepresentable {
  @Binding var isFullScreen: Bool

  func makeNSView(context: Context) -> WindowFullScreenObservingView {
    WindowFullScreenObservingView()
  }

  func updateNSView(_ view: WindowFullScreenObservingView, context: Context) {
    view.onFullScreenChange = { newValue in
      if isFullScreen != newValue {
        isFullScreen = newValue
      }
    }
  }
}

private final class WindowFullScreenObservingView: NSView {
  var onFullScreenChange: ((Bool) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    guard let window else { return }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillEnterFullScreen),
      name: NSWindow.willEnterFullScreenNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillExitFullScreen),
      name: NSWindow.willExitFullScreenNotification,
      object: window
    )
    publish(window.styleMask.contains(.fullScreen))
  }

  @objc private func windowWillEnterFullScreen() {
    publish(true)
  }

  @objc private func windowWillExitFullScreen() {
    publish(false)
  }

  private func publish(_ isFullScreen: Bool) {
    // viewDidMoveToWindow can run inside a SwiftUI update, where a binding
    // write is not allowed; defer past the current update.
    Task { @MainActor [weak self] in
      self?.onFullScreenChange?(isFullScreen)
    }
  }
}
