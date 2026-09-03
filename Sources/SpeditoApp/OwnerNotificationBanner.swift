import SpeditoCore
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

extension OwnerNotificationKind {
  var symbolName: String {
    switch self {
    case .needsInput:
      "hand.raised.fill"
    case .refinementComplete:
      "wand.and.stars"
    case .newReply:
      "bubble.left.fill"
    }
  }

  var tint: Color {
    requiresAction ? .orange : .purple
  }
}

/// Window-level presentation of the transient banner as a callout popped out
/// of the notification bell: it sits to the bell's left with an arrow pointing
/// at the bell, and scales back into the bell when it times out or is
/// dismissed. Without a bell on screen it falls back to the top-trailing
/// corner.
struct OwnerNotificationBannerOverlay: View {
  @EnvironmentObject private var model: AppModel
  let bellAnchor: Anchor<CGRect>?

  private static let arrowSize = CGSize(width: 9, height: 16)
  private static let bellGap: CGFloat = 4
  private static let animationDuration: TimeInterval = 0.2

  // The pop is driven explicitly instead of through .transition: the callout
  // is laid out with .position, and a transition outside that wrapper scales
  // around the window-filling frame rather than the callout itself.
  @State private var displayed: OwnerNotificationPresentation?
  @State private var isShown = false

  var body: some View {
    GeometryReader { proxy in
      if let notification = displayed {
        let banner = OwnerNotificationBanner(
          notification: notification,
          onOpen: {
            Task { await model.openOwnerNotification(notification) }
          },
          onDismiss: {
            model.dismissPresentedOwnerNotification(id: notification.id)
          }
        )
        if let bellAnchor {
          let bellFrame = proxy[bellAnchor]
          let calloutWidth = OwnerNotificationBanner.width + Self.arrowSize.width - 1
          HStack(spacing: -1) {
            banner
            OwnerNotificationCalloutArrow()
              .frame(width: Self.arrowSize.width, height: Self.arrowSize.height)
          }
          .scaleEffect(isShown ? 1 : 0.05, anchor: UnitPoint(x: 1, y: 0.5))
          .opacity(isShown ? 1 : 0)
          .position(
            x: bellFrame.minX - Self.bellGap - calloutWidth / 2,
            y: bellFrame.midY
          )
        } else {
          banner
            .scaleEffect(isShown ? 1 : 0.1, anchor: .topTrailing)
            .opacity(isShown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 16)
            .padding(.top, 60)
        }
      }
    }
    .onAppear {
      guard let presented = model.presentedOwnerNotification else { return }
      displayed = presented
      isShown = true
    }
    .onChange(of: model.presentedOwnerNotification) { _, presented in
      if let presented {
        displayed = presented
        withAnimation(.easeOut(duration: Self.animationDuration)) {
          isShown = true
        }
      } else {
        withAnimation(.easeIn(duration: Self.animationDuration)) {
          isShown = false
        }
        Task {
          try? await Task.sleep(for: .milliseconds(250))
          guard model.presentedOwnerNotification == nil else { return }
          displayed = nil
        }
      }
    }
  }
}

private struct CalloutArrowFill: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

private struct CalloutArrowEdges: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    return path
  }
}

/// The little popover-style arrow that makes the callout read as popped out of
/// the bell: filled to match the card, stroked only on its two pointed edges.
private struct OwnerNotificationCalloutArrow: View {
  var body: some View {
    ZStack {
      CalloutArrowFill()
        .fill(Color(nsColor: .controlBackgroundColor))
      CalloutArrowEdges()
        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
    }
    .accessibilityHidden(true)
  }
}

struct OwnerNotificationBanner: View {
  static let width: CGFloat = 420

  @Environment(\.ownerNotificationBannerDismissDelay) private var dismissDelay
  let notification: OwnerNotificationPresentation
  let onOpen: () -> Void
  let onDismiss: () -> Void
  @State private var remainingFraction: CGFloat = 1

  private var tint: Color {
    notification.kind.tint
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: notification.kind.symbolName)
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
    .frame(width: Self.width)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay(alignment: .bottomLeading) {
      if dismissDelay != nil {
        Rectangle()
          .fill(tint.opacity(0.4))
          .frame(height: 3)
          .scaleEffect(x: remainingFraction, y: 1, anchor: .leading)
          .accessibilityHidden(true)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
    }
    .task(id: notification.id) {
      guard let dismissDelay else { return }
      var reset = Transaction()
      reset.disablesAnimations = true
      withTransaction(reset) {
        remainingFraction = 1
      }
      withAnimation(.linear(duration: Self.seconds(of: dismissDelay))) {
        remainingFraction = 0
      }
      do {
        try await Task.sleep(for: dismissDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      onDismiss()
    }
  }

  private static func seconds(of duration: Duration) -> TimeInterval {
    TimeInterval(duration.components.seconds)
      + TimeInterval(duration.components.attoseconds) / 1e18
  }
}
