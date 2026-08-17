import AppKit
import Combine
import SpeditoCore
import UserNotifications

struct TicketAttention: Identifiable, Equatable, Sendable {
  let id: UUID
  let productID: UUID
  let productName: String
  let sprintID: UUID?
  let workItemID: UUID
  let itemKey: String
  let title: String
  let summary: String
  let updatedAt: Date
}

struct TicketAttentionNavigationRequest: Identifiable, Equatable, Sendable {
  let id = UUID()
  let productID: UUID
  let sprintID: UUID?
  let workItemIDs: Set<UUID>
  let openWorkItemID: UUID?
}

struct OwnerNotificationPresentation: Identifiable, Equatable, Sendable {
  let id: UUID
  let productID: UUID
  let productName: String
  let kind: OwnerNotificationKind
  let target: OwnerNotificationTarget
  let title: String
  let summary: String

  init(notification: OwnerNotification, productName: String) {
    id = notification.id
    productID = notification.productID
    self.productName = productName
    kind = notification.kind
    target = notification.target
    title = notification.title
    summary = notification.body
  }

  init(attention: TicketAttention) {
    id = attention.id
    productID = attention.productID
    productName = attention.productName
    kind = .needsInput
    target = OwnerNotificationTarget(kind: .ticket, id: attention.workItemID)
    title = "\(attention.itemKey) needs your input"
    summary = attention.summary
  }

  var actionTitle: String {
    switch target.kind {
    case .ticket:
      "Open ticket"
    case .epic:
      "Open epic"
    case .conversationThread:
      "Open chat"
    }
  }
}

struct OwnerNotificationNavigationRequest: Identifiable, Equatable, Sendable {
  let id = UUID()
  let notificationID: UUID?
  let productID: UUID
  let target: OwnerNotificationTarget
}

struct OwnerNotificationRoute: Equatable, Sendable {
  let notificationID: UUID
  let productID: UUID
  let target: OwnerNotificationTarget

  init?(userInfo: [AnyHashable: Any]) {
    guard
      let notificationIDString = userInfo[Self.notificationIDKey] as? String,
      let notificationID = UUID(uuidString: notificationIDString),
      let productIDString = userInfo[Self.productIDKey] as? String,
      let productID = UUID(uuidString: productIDString),
      let targetKindString = userInfo[Self.targetKindKey] as? String,
      let targetKind = OwnerNotificationTargetKind(rawValue: targetKindString),
      let targetIDString = userInfo[Self.targetIDKey] as? String,
      let targetID = UUID(uuidString: targetIDString)
    else { return nil }
    self.notificationID = notificationID
    self.productID = productID
    target = OwnerNotificationTarget(kind: targetKind, id: targetID)
  }

  static func userInfo(
    for presentation: OwnerNotificationPresentation
  ) -> [AnyHashable: Any] {
    [
      notificationIDKey: presentation.id.uuidString,
      productIDKey: presentation.productID.uuidString,
      targetKindKey: presentation.target.kind.rawValue,
      targetIDKey: presentation.target.id.uuidString,
    ]
  }

  private static let notificationIDKey = "notificationID"
  private static let productIDKey = "productID"
  private static let targetKindKey = "targetKind"
  private static let targetIDKey = "targetID"
}

@MainActor
protocol OwnerNotificationSoundPlaying: AnyObject {
  func play()
}

@MainActor
protocol OwnerNotificationSystemNotifying: AnyObject {
  func post(_ presentation: OwnerNotificationPresentation)
  func dismiss(ids: [UUID])
}

@MainActor
final class BundledOwnerNotificationSoundPlayer: OwnerNotificationSoundPlaying {
  private lazy var sound: NSSound? = {
    guard
      let url = SpeditoResources.url(
        forResource: "ticket-attention",
        withExtension: "wav"
      )
    else {
      return nil
    }
    return NSSound(contentsOf: url, byReference: true)
  }()

  func play() {
    guard let sound else { return }
    if sound.isPlaying {
      sound.stop()
    }
    sound.play()
  }
}

struct OwnerNotificationDeliveryPolicy {
  static func presentsInApp(applicationIsActive: Bool) -> Bool {
    applicationIsActive
  }

  static func postsToSystem(applicationIsActive: Bool) -> Bool {
    !applicationIsActive
  }
}


@MainActor
final class MacOSOwnerNotificationNotifier: OwnerNotificationSystemNotifying {
  private let centerProvider: () -> UNUserNotificationCenter
  private let applicationIsActive: () -> Bool

  init(
    centerProvider: @escaping () -> UNUserNotificationCenter = {
      .current()
    },
    applicationIsActive: @escaping () -> Bool = {
      NSApplication.shared.isActive
    }
  ) {
    self.centerProvider = centerProvider
    self.applicationIsActive = applicationIsActive
  }

  func post(_ presentation: OwnerNotificationPresentation) {
    guard
      OwnerNotificationDeliveryPolicy.postsToSystem(
        applicationIsActive: applicationIsActive()
      )
    else { return }
    let center = centerProvider()
    Task {
      do {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
          guard try await center.requestAuthorization(options: [.alert]) else {
            return
          }
        case .authorized, .provisional, .ephemeral:
          break
        case .denied:
          return
        @unknown default:
          return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(presentation.productName) · \(presentation.title)"
        content.body = presentation.summary
        content.userInfo = OwnerNotificationRoute.userInfo(for: presentation)
        let request = UNNotificationRequest(
          identifier: presentation.id.uuidString,
          content: content,
          trigger: nil
        )
        try await center.add(request)
      } catch {
        // Durable owner state and in-app indicators remain authoritative.
      }
    }
  }

  func dismiss(ids: [UUID]) {
    guard !ids.isEmpty else { return }
    let identifiers = ids.map(\.uuidString)
    let center = centerProvider()
    center.removeDeliveredNotifications(withIdentifiers: identifiers)
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }
}

@MainActor
final class OwnerNotificationCoordinator: ObservableObject {
  @Published private(set) var notificationsByProductID: [UUID: [OwnerNotification]] = [:]
  @Published private(set) var presentedNotification: OwnerNotificationPresentation?

  private struct VisibleTarget: Hashable {
    let productID: UUID
    let target: OwnerNotificationTarget
  }

  private let storeProvider: (UUID) -> SQLiteStore?
  private let soundPlayer: any OwnerNotificationSoundPlaying
  private let systemNotifier: any OwnerNotificationSystemNotifying
  private var visibleTargets: Set<VisibleTarget> = []
  private var isApplicationActive = true
  private var isShuttingDown = false

  init(
    storeProvider: @escaping (UUID) -> SQLiteStore?,
    soundPlayer: any OwnerNotificationSoundPlaying =
      BundledOwnerNotificationSoundPlayer(),
    systemNotifier: any OwnerNotificationSystemNotifying =
      MacOSOwnerNotificationNotifier()
  ) {
    self.storeProvider = storeProvider
    self.soundPlayer = soundPlayer
    self.systemNotifier = systemNotifier
  }

  func load(products: [Product]) async {
    var loaded: [UUID: [OwnerNotification]] = [:]
    for product in products {
      guard
        let store = storeProvider(product.id),
        let notifications = try? await store.fetchActiveOwnerNotifications(
          productID: product.id
        ),
        !notifications.isEmpty
      else { continue }
      loaded[product.id] = notifications
    }
    notificationsByProductID = loaded
  }

  func refresh(productID: UUID) async {
    guard
      let store = storeProvider(productID),
      let notifications = try? await store.fetchActiveOwnerNotifications(
        productID: productID
      )
    else { return }
    if notifications.isEmpty {
      notificationsByProductID.removeValue(forKey: productID)
    } else {
      notificationsByProductID[productID] = notifications
    }
  }

  @discardableResult
  func publish(
    _ notification: OwnerNotification,
    productName: String
  ) async -> Bool {
    guard !isShuttingDown, let store = storeProvider(notification.productID) else {
      return false
    }
    guard (try? await store.createOwnerNotification(notification)) == true else {
      await refresh(productID: notification.productID)
      return false
    }
    await refresh(productID: notification.productID)

    if isApplicationActive,
      visibleTargets.contains(
        VisibleTarget(productID: notification.productID, target: notification.target)
      )
    {
      await markRead(productID: notification.productID, target: notification.target)
      return true
    }

    if notification.kind.requiresAction {
      soundPlayer.play()
    }
    let presentation = OwnerNotificationPresentation(
      notification: notification,
      productName: productName
    )
    if OwnerNotificationDeliveryPolicy.presentsInApp(
      applicationIsActive: isApplicationActive
    ) {
      presentedNotification = presentation
    }
    systemNotifier.post(presentation)
    return true
  }

  func present(_ attention: TicketAttention) {
    guard !isShuttingDown else { return }
    soundPlayer.play()
    let presentation = OwnerNotificationPresentation(attention: attention)
    if OwnerNotificationDeliveryPolicy.presentsInApp(
      applicationIsActive: isApplicationActive
    ) {
      presentedNotification = presentation
    }
    systemNotifier.post(presentation)
  }

  func dismissPresented(id: UUID) {
    guard presentedNotification?.id == id else { return }
    presentedNotification = nil
  }

  func setVisible(
    productID: UUID,
    target: OwnerNotificationTarget
  ) async {
    visibleTargets.insert(VisibleTarget(productID: productID, target: target))
    guard isApplicationActive else { return }
    await markRead(productID: productID, target: target)
  }

  func clearVisible(
    productID: UUID,
    target: OwnerNotificationTarget
  ) {
    visibleTargets.remove(VisibleTarget(productID: productID, target: target))
  }

  func setApplicationActive(_ isActive: Bool) async {
    isApplicationActive = isActive
    guard isActive else { return }
    let targets = visibleTargets
    for visibleTarget in targets {
      await markRead(
        productID: visibleTarget.productID,
        target: visibleTarget.target
      )
    }
  }

  func markRead(
    productID: UUID,
    target: OwnerNotificationTarget
  ) async {
    guard let store = storeProvider(productID) else { return }
    let dismissedIDs =
      (try? await store.markOwnerNotificationsRead(
        productID: productID,
        target: target
      )) ?? []
    systemNotifier.dismiss(ids: dismissedIDs)
    if let presentedNotification, dismissedIDs.contains(presentedNotification.id) {
      self.presentedNotification = nil
    }
    await refresh(productID: productID)
  }

  func resolve(
    productID: UUID,
    target: OwnerNotificationTarget
  ) async {
    guard let store = storeProvider(productID) else { return }
    let dismissedIDs =
      (try? await store.resolveOwnerNotifications(
        productID: productID,
        target: target
      )) ?? []
    systemNotifier.dismiss(ids: dismissedIDs)
    if let presentedNotification, dismissedIDs.contains(presentedNotification.id) {
      self.presentedNotification = nil
    }
    await refresh(productID: productID)
  }

  func dismissSystemNotification(id: UUID) {
    systemNotifier.dismiss(ids: [id])
  }

  func beginShutdown() {
    isShuttingDown = true
    presentedNotification = nil
  }

  func notifications(productID: UUID) -> [OwnerNotification] {
    notificationsByProductID[productID] ?? []
  }

  func activeKind(
    productID: UUID,
    target: OwnerNotificationTarget
  ) -> OwnerNotificationKind? {
    let targetNotifications = notifications(productID: productID).filter {
      $0.target == target
    }
    if targetNotifications.contains(where: {
      $0.kind.requiresAction && $0.resolvedAt == nil
    }) {
      return .needsInput
    }
    return targetNotifications.first(where: \.isUnread)?.kind
  }

  func hasUnread(
    productID: UUID,
    target: OwnerNotificationTarget
  ) -> Bool {
    notifications(productID: productID).contains {
      $0.target == target && $0.isUnread
    }
  }

  func activeTargetCount(
    productID: UUID,
    targetKinds: Set<OwnerNotificationTargetKind>
  ) -> Int {
    Set(
      notifications(productID: productID).lazy
        .filter { targetKinds.contains($0.target.kind) }
        .map(\.target)
    ).count
  }

  func unreadTargetCount(
    productID: UUID,
    targetKinds: Set<OwnerNotificationTargetKind>
  ) -> Int {
    Set(
      notifications(productID: productID).lazy
        .filter { $0.isUnread && targetKinds.contains($0.target.kind) }
        .map(\.target)
    ).count
  }
}

struct TicketAttentionSoundPolicy {
  static func shouldPlay(
    previousStatus: AgentRunStatus,
    newStatus: AgentRunStatus,
    isShuttingDown: Bool
  ) -> Bool {
    !isShuttingDown
      && previousStatus != .awaitingOwner
      && newStatus == .awaitingOwner
  }
}
