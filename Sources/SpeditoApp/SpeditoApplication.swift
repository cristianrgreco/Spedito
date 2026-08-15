import AppKit
import SwiftUI
import UserNotifications

enum ApplicationTerminationOutcome: Equatable {
  case shutdownCompleted
  case gracePeriodElapsed
  case quitNow
}

@MainActor
final class ApplicationTerminationCoordinator {
  typealias GraceWait = @MainActor (Duration) async -> Void

  static let defaultGracePeriod: Duration = .seconds(10)

  private let gracePeriod: Duration
  private let waitForGrace: GraceWait
  private var shutdownTask: Task<Void, Never>?
  private var graceTask: Task<Void, Never>?
  private var completion: (@MainActor (ApplicationTerminationOutcome) -> Void)?

  private(set) var outcome: ApplicationTerminationOutcome?
  var isPreparing: Bool { completion != nil && outcome == nil }

  init(
    gracePeriod: Duration = defaultGracePeriod,
    waitForGrace: @escaping GraceWait = { duration in
      try? await Task.sleep(for: duration)
    }
  ) {
    self.gracePeriod = gracePeriod
    self.waitForGrace = waitForGrace
  }

  @discardableResult
  func begin(
    shutdown: @escaping @MainActor () async -> Void,
    completion: @escaping @MainActor (ApplicationTerminationOutcome) -> Void
  ) -> Bool {
    guard !isPreparing, outcome == nil else { return false }
    self.completion = completion
    shutdownTask = Task { @MainActor [weak self] in
      await shutdown()
      guard !Task.isCancelled else { return }
      self?.finish(.shutdownCompleted)
    }
    graceTask = Task { @MainActor [weak self, gracePeriod, waitForGrace] in
      await waitForGrace(gracePeriod)
      guard !Task.isCancelled else { return }
      self?.finish(.gracePeriodElapsed)
    }
    return true
  }

  func quitNow() {
    finish(.quitNow)
  }

  private func finish(_ outcome: ApplicationTerminationOutcome) {
    guard self.outcome == nil, let completion else { return }
    self.outcome = outcome
    self.completion = nil
    shutdownTask?.cancel()
    graceTask?.cancel()
    shutdownTask = nil
    graceTask = nil
    completion(outcome)
  }
}

@MainActor
private final class ShutdownGraceAlertController: NSObject {
  private var alert: NSAlert?
  private var quitNowHandler: (() -> Void)?

  func present(quitNow: @escaping () -> Void) {
    guard alert == nil else { return }
    quitNowHandler = quitNow

    let alert = NSAlert()
    alert.messageText = "Preparing to quit"
    alert.informativeText =
      "Spedito is saving active work so it can resume safely. You can quit immediately instead."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Quit now")
    alert.buttons[0].hasDestructiveAction = true
    alert.buttons[0].target = self
    alert.buttons[0].action = #selector(handleQuitNow)
    alert.window.level = .modalPanel
    alert.window.center()
    alert.window.makeKeyAndOrderFront(nil)
    self.alert = alert
  }

  func dismiss() {
    alert?.window.orderOut(nil)
    alert = nil
    quitNowHandler = nil
  }

  @objc private func handleQuitNow() {
    quitNowHandler?()
  }
}

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
  private let terminationCoordinator = ApplicationTerminationCoordinator()
  private let shutdownGraceAlert = ShutdownGraceAlertController()
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
    guard let terminationHandler else { return .terminateNow }
    guard !isPreparingToTerminate else { return .terminateLater }

    isPreparingToTerminate = true
    shutdownGraceAlert.present { [weak self] in
      self?.terminationCoordinator.quitNow()
    }
    terminationCoordinator.begin(
      shutdown: terminationHandler,
      completion: { [weak self, weak sender] _ in
        self?.shutdownGraceAlert.dismiss()
        sender?.reply(toApplicationShouldTerminate: true)
      }
    )
    return .terminateLater
  }
}
