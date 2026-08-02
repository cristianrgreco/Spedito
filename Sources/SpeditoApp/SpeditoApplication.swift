import AppKit
import SwiftUI

@main
struct SpeditoApplication: App {
  @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .task {
          appDelegate.terminationHandler = {
            await model.shutdown()
          }
          await model.load()
        }
        .frame(minWidth: 1_080, minHeight: 680)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1_400, height: 860)
    .commands {
      WorkspaceCommands()
    }
  }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
  var terminationHandler: (@MainActor () async -> Void)?
  private var isPreparingToTerminate = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let iconURL = SpeditoResources.url(
      forResource: "AppIcon",
      withExtension: "png"
    ) {
      NSApplication.shared.applicationIconImage = NSImage(contentsOf: iconURL)
    }
    NSApplication.shared.setActivationPolicy(.regular)

    DispatchQueue.main.async {
      NSApplication.shared.activate(ignoringOtherApps: true)
      NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isPreparingToTerminate, let terminationHandler else {
      return .terminateNow
    }
    isPreparingToTerminate = true
    Task { @MainActor in
      await terminationHandler()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
