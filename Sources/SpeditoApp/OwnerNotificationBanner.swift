import SwiftUI

private struct OwnerNotificationBannerDismissDelayKey: EnvironmentKey {
  static let defaultValue: Duration? = .seconds(8)
}

extension EnvironmentValues {
  var ownerNotificationBannerDismissDelay: Duration? {
    get { self[OwnerNotificationBannerDismissDelayKey.self] }
    set { self[OwnerNotificationBannerDismissDelayKey.self] = newValue }
  }
}

struct OwnerNotificationBanner: View {
  @Environment(\.ownerNotificationBannerDismissDelay) private var dismissDelay
  let notification: OwnerNotificationPresentation
  let onOpen: () -> Void
  let onDismiss: () -> Void

  private var tint: Color {
    notification.kind.requiresAction ? .orange : .purple
  }

  private var symbolName: String {
    switch notification.kind {
    case .needsInput:
      "hand.raised.fill"
    case .refinementComplete:
      "wand.and.stars"
    case .newReply:
      "bubble.left.fill"
    }
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbolName)
        .font(.title3.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 28, height: 28)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("\(notification.productName) · \(notification.title)")
          .font(.callout.weight(.semibold))
          .lineLimit(1)
          .accessibilityLabel("\(notification.productName) · \(notification.title)")
          .accessibilityIdentifier("owner-notification.banner")
        Text(notification.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(notification.actionTitle, action: onOpen)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("owner-notification.open")

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Dismiss notification")
      .accessibilityIdentifier("owner-notification.dismiss")
    }
    .padding(12)
    .frame(width: 560)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
    }
    .task(id: notification.id) {
      guard let dismissDelay else { return }
      do {
        try await Task.sleep(for: dismissDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      onDismiss()
    }
  }
}
