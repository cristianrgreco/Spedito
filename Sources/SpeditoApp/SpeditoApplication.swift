import AppKit
import SwiftUI
import UserNotifications

@main
struct SpeditoApplication: App {
  @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .task {
          appDelegate.terminationHandler = {
            await model.shutdown()
          }
          await model.setApplicationActive(scenePhase == .active)
          await model.load()
          appDelegate.ownerNotificationHandler = { route in
            await model.openOwnerNotification(route)
          }
        }
        .onChange(of: scenePhase) { _, phase in
          Task { await model.setApplicationActive(phase == .active) }
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
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate,
  UNUserNotificationCenterDelegate
{
  var terminationHandler: (@MainActor () async -> Void)?
  var ownerNotificationHandler: (@MainActor (OwnerNotificationRoute) async -> Void)? {
    didSet {
      guard let pendingOwnerNotificationRoute, ownerNotificationHandler != nil else {
        return
      }
      self.pendingOwnerNotificationRoute = nil
      Task { @MainActor [weak self] in
        await self?.deliver(pendingOwnerNotificationRoute)
      }
    }
  }
  private var pendingOwnerNotificationRoute: OwnerNotificationRoute?
  private var isPreparingToTerminate = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let iconURL = SpeditoResources.url(
      forResource: "AppIcon",
      withExtension: "png"
    ) {
      NSApplication.shared.applicationIconImage = NSImage(contentsOf: iconURL)
    }
    NSApplication.shared.setActivationPolicy(.regular)
    UNUserNotificationCenter.current().delegate = self

    DispatchQueue.main.async {
      NSApplication.shared.activate(ignoringOtherApps: true)
      NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    guard
      let route = OwnerNotificationRoute(
        userInfo: response.notification.request.content.userInfo
      )
    else {
      completionHandler()
      return
    }
    Task { @MainActor [weak self] in
      await self?.deliver(route)
      completionHandler()
    }
  }

  private func deliver(_ route: OwnerNotificationRoute) async {
    guard let ownerNotificationHandler else {
      pendingOwnerNotificationRoute = route
      return
    }
    await ownerNotificationHandler(route)
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
