import SpeditoCore
import SwiftUI

/// One tray entry: the notification presentation the row displays and opens,
/// with the timestamp that orders it inside its product group.
struct OwnerNotificationTrayRow: Identifiable, Equatable {
  let presentation: OwnerNotificationPresentation
  let updatedAt: Date

  var id: UUID { presentation.id }
}

struct OwnerNotificationTrayGroup: Identifiable, Equatable {
  let productID: UUID
  let productName: String
  let rows: [OwnerNotificationTrayRow]

  var id: UUID { productID }
}

/// Deterministic projection of every notification still waiting on the
/// product owner, grouped by product with the selected product first.
///
/// Membership matches the sidebar attention model: live ticket attentions and
/// active stored notifications, one row per target. A target covered by a
/// ticket attention keeps the attention row because its summary follows the
/// live run. Among stored notifications on one target, an unresolved
/// needs-input notification outranks newer informational ones, mirroring
/// `OwnerNotificationCoordinator.activeKind`.
struct OwnerNotificationTrayPresentation: Equatable {
  let groups: [OwnerNotificationTrayGroup]

  var badgeCount: Int {
    groups.reduce(0) { $0 + $1.rows.count }
  }

  var isEmpty: Bool {
    groups.isEmpty
  }

  static func make(
    products: [Product],
    selectedProductID: UUID?,
    notificationsByProductID: [UUID: [OwnerNotification]],
    attentionsByProductID: [UUID: [TicketAttention]],
    planReviewsByProductID: [UUID: [EpicPlanReviewAttention]] = [:]
  ) -> OwnerNotificationTrayPresentation {
    var orderedProducts = products
    if let index = orderedProducts.firstIndex(where: { $0.id == selectedProductID }) {
      orderedProducts.insert(orderedProducts.remove(at: index), at: 0)
    }

    let groups = orderedProducts.compactMap { product -> OwnerNotificationTrayGroup? in
      var rows: [OwnerNotificationTrayRow] = []
      var coveredTargets: Set<OwnerNotificationTarget> = []

      for attention in attentionsByProductID[product.id, default: []] {
        let target = OwnerNotificationTarget(kind: .ticket, id: attention.workItemID)
        guard coveredTargets.insert(target).inserted else { continue }
        rows.append(
          OwnerNotificationTrayRow(
            presentation: OwnerNotificationPresentation(attention: attention),
            updatedAt: attention.updatedAt
          )
        )
      }

      for planReview in planReviewsByProductID[product.id, default: []] {
        let target = OwnerNotificationTarget(kind: .epic, id: planReview.epicID)
        guard coveredTargets.insert(target).inserted else { continue }
        rows.append(
          OwnerNotificationTrayRow(
            presentation: OwnerNotificationPresentation(planReview: planReview),
            updatedAt: planReview.updatedAt
          )
        )
      }

      let notificationsByTarget = Dictionary(
        grouping: notificationsByProductID[product.id, default: []].filter(\.isActive),
        by: \.target
      )
      for (target, notifications) in notificationsByTarget {
        guard !coveredTargets.contains(target) else { continue }
        let awaitingOwner = notifications.filter {
          $0.kind.requiresAction && $0.resolvedAt == nil
        }
        guard
          let representative =
            awaitingOwner.max(by: { $0.createdAt < $1.createdAt })
            ?? notifications.max(by: { $0.createdAt < $1.createdAt })
        else { continue }
        rows.append(
          OwnerNotificationTrayRow(
            presentation: OwnerNotificationPresentation(
              notification: representative,
              productName: product.name
            ),
            updatedAt: representative.createdAt
          )
        )
      }

      guard !rows.isEmpty else { return nil }
      rows.sort {
        if $0.updatedAt != $1.updatedAt {
          return $0.updatedAt > $1.updatedAt
        }
        return $0.presentation.title
          .localizedStandardCompare($1.presentation.title) == .orderedAscending
      }
      return OwnerNotificationTrayGroup(
        productID: product.id,
        productName: product.name,
        rows: rows
      )
    }
    return OwnerNotificationTrayPresentation(groups: groups)
  }
}

/// Publishes the bell's frame so the window-level banner callout can attach
/// itself to the bell from outside the header hierarchy.
struct OwnerNotificationBellAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// The persistent toolbar bell: a badge with everything still waiting on the
/// owner, and a popover tray that navigates to each item.
struct OwnerNotificationBellView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingTray = false
  @State private var bannerTuckCount = 0
  @State private var isHovering = false

  private var tray: OwnerNotificationTrayPresentation {
    OwnerNotificationTrayPresentation.make(
      products: model.products,
      selectedProductID: model.selectedProductID,
      notificationsByProductID: model.ownerNotificationsByProductID,
      attentionsByProductID: model.ticketAttentionsByProductID,
      planReviewsByProductID: model.epicPlanReviewsByProductID
    )
  }

  var body: some View {
    let tray = tray
    Button {
      showingTray = true
    } label: {
      Image(systemName: "bell")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .symbolEffect(.bounce, value: bannerTuckCount)
        .frame(width: 30, height: 30)
        .background(
          Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0.06))
        )
        .overlay(alignment: .topTrailing) {
          if tray.badgeCount > 0 {
            Text(tray.badgeCount.formatted())
              .font(.caption2.monospacedDigit().weight(.bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.accentColor, in: Capsule())
              .offset(x: 6, y: -4)
              .accessibilityHidden(true)
          }
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .anchorPreference(key: OwnerNotificationBellAnchorKey.self, value: .bounds) { $0 }
    .help("Notifications that need your attention")
    .accessibilityLabel(
      tray.badgeCount == 0
        ? "Notifications"
        : "Notifications, \(tray.badgeCount) need your attention"
    )
    .accessibilityIdentifier("owner-notification.bell")
    .onChange(of: model.presentedOwnerNotification?.id) { previous, current in
      if previous != nil, current == nil {
        bannerTuckCount += 1
      }
    }
    .popover(isPresented: $showingTray, arrowEdge: .bottom) {
      OwnerNotificationTrayView(tray: tray) { presentation in
        showingTray = false
        Task { await model.openOwnerNotification(presentation) }
      }
    }
  }
}

struct OwnerNotificationTrayView: View {
  let tray: OwnerNotificationTrayPresentation
  let onOpen: (OwnerNotificationPresentation) -> Void
  @State private var rowsHeight: CGFloat = 0

  private var showsProductNames: Bool {
    tray.groups.count > 1
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text("Needs your attention")
          .font(.headline)
        Spacer()
        if tray.badgeCount > 0 {
          Text(tray.badgeCount.formatted())
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 4)

      if tray.isEmpty {
        Text("Nothing needs your attention right now.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 64)
          .padding(.horizontal, 14)
          .padding(.bottom, 8)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(tray.groups) { group in
              if showsProductNames {
                Text(group.productName)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 8)
                  .padding(.top, 7)
                  .padding(.bottom, 1)
              }
              ForEach(group.rows) { row in
                OwnerNotificationTrayRowView(row: row) {
                  onOpen(row.presentation)
                }
              }
            }
          }
          .padding(.horizontal, 6)
          .padding(.bottom, 8)
          .background(
            GeometryReader { proxy in
              Color.clear.preference(
                key: TrayRowsHeightKey.self,
                value: proxy.size.height
              )
            }
          )
        }
        .frame(height: min(max(rowsHeight, 44), 420))
        .onPreferenceChange(TrayRowsHeightKey.self) { rowsHeight = $0 }
      }
    }
    .frame(width: 380)
    .accessibilityIdentifier("owner-notification.tray")
  }
}

private struct TrayRowsHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct OwnerNotificationTrayRowView: View {
  let row: OwnerNotificationTrayRow
  let onOpen: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: onOpen) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: row.presentation.kind.symbolName)
          .font(.callout.weight(.semibold))
          .foregroundStyle(row.presentation.kind.tint)
          .frame(width: 26, height: 26)
          .background(
            row.presentation.kind.tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 7)
          )
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 1) {
          Text(row.presentation.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(row.presentation.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .padding(8)
      .background(
        isHovering ? Color.primary.opacity(0.06) : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(row.presentation.actionTitle)
    .accessibilityLabel("\(row.presentation.title). \(row.presentation.summary)")
    .accessibilityHint(row.presentation.actionTitle)
    .accessibilityIdentifier("owner-notification.tray.row")
  }
}
