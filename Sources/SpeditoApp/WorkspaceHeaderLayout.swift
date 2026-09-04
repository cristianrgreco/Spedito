import SwiftUI

extension View {
  /// Shared page-header layout for every workspace destination. Composing the
  /// notification bell here keeps it in the same top-trailing spot on every
  /// view without per-view wiring.
  ///
  /// The bell centres on the title row alone. Content that belongs beneath
  /// that row, such as the Product ask field, goes in `below` so it
  /// spans the full header width without pushing the bell off the title row.
  func workspaceHeaderLayout<Below: View>(
    @ViewBuilder below: () -> Below = { EmptyView() }
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        frame(maxWidth: .infinity, alignment: .leading)
        OwnerNotificationBellView()
      }
      below()
    }
    .padding(24)
  }
}
