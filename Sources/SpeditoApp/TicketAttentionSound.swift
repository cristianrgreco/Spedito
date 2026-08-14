import AppKit
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

struct TicketAttentionNotificationRoute: Equatable, Sendable {
  let productID: UUID
  let workItemID: UUID

  init?(userInfo: [AnyHashable: Any]) {
    guard
      let productIDString = userInfo[Self.productIDKey] as? String,
      let productID = UUID(uuidString: productIDString),
      let workItemIDString = userInfo[Self.workItemIDKey] as? String,
      let workItemID = UUID(uuidString: workItemIDString)
    else { return nil }
    self.productID = productID
    self.workItemID = workItemID
  }

  static func userInfo(for attention: TicketAttention) -> [AnyHashable: Any] {
    [
      productIDKey: attention.productID.uuidString,
      workItemIDKey: attention.workItemID.uuidString,
    ]
  }

  private static let productIDKey = "productID"
  private static let workItemIDKey = "workItemID"
}

@MainActor
protocol TicketAttentionSoundPlaying: AnyObject {
  func play()
}

@MainActor
protocol TicketAttentionSystemNotifying: AnyObject {
  func post(_ attention: TicketAttention)
}

@MainActor
final class BundledTicketAttentionSoundPlayer: TicketAttentionSoundPlaying {
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

@MainActor
final class MacOSTicketAttentionNotifier: TicketAttentionSystemNotifying {
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

  func post(_ attention: TicketAttention) {
    guard !applicationIsActive() else { return }
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
        content.title = "\(attention.productName) · \(attention.itemKey) needs your input"
        content.body = attention.summary
        content.userInfo = TicketAttentionNotificationRoute.userInfo(for: attention)
        let request = UNNotificationRequest(
          identifier: attention.id.uuidString,
          content: content,
          trigger: nil
        )
        try await center.add(request)
      } catch {
        // Durable ticket attention and the in-app badge remain authoritative.
      }
    }
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
