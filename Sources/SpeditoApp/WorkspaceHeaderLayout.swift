import SwiftUI

extension View {
  /// Shared page-header layout for every workspace destination. Composing the
  /// notification bell here keeps it in the same top-trailing spot on every
  /// view without per-view wiring.
  func workspaceHeaderLayout() -> some View {
    HStack(alignment: .center, spacing: 16) {
      frame(maxWidth: .infinity, alignment: .leading)
      OwnerNotificationBellView()
    }
    .padding(24)
  }
}
