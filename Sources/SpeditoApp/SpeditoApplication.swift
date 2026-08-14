import AppKit
import SwiftUI
import UserNotifications

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
          appDelegate.ticketAttentionHandler = { productID, workItemID in
            await model.openTicketAttention(
              productID: productID,
              workItemID: workItemID
            )
          }
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
  var ticketAttentionHandler: (@MainActor (UUID, UUID) async -> Void)? {
    didSet {
      guard let pendingTicketAttentionRoute, ticketAttentionHandler != nil else {
        return
      }
      self.pendingTicketAttentionRoute = nil
      Task { @MainActor [weak self] in
        await self?.deliver(pendingTicketAttentionRoute)
      }
    }
  }
  private var pendingTicketAttentionRoute: TicketAttentionNotificationRoute?
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
      let route = TicketAttentionNotificationRoute(
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

  private func deliver(_ route: TicketAttentionNotificationRoute) async {
    guard let ticketAttentionHandler else {
      pendingTicketAttentionRoute = route
      return
    }
    await ticketAttentionHandler(route.productID, route.workItemID)
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
