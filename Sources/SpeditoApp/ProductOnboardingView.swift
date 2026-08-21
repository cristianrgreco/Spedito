import SwiftUI

struct ProductOnboardingView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingProductLibrary = false

  var body: some View {
    ZStack {
      ProductOnboardingBackdrop()

      VStack(spacing: 22) {
        Image(systemName: "shippingbox.fill")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 64, height: 64)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

        VStack(spacing: 8) {
          Text("What are you building?")
            .font(.largeTitle.bold())
          Text("Create a blank product or start from an existing public or private repository.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
        }

        ProductCreationForm(
          blankActionTitle: "Create product",
          importActionTitle: "Create from repository",
          actionControlSize: .large,
          onCreate: model.createProductAndSelect
        ) { isCreating in
          if !model.archivedProducts.isEmpty {
            Button("View archived products") {
              showingProductLibrary = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("products.archived.open")
            .disabled(isCreating)
          }
        }
        .frame(width: 420)
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea(.container, edges: .top)
    .sheet(isPresented: $showingProductLibrary) {
      ProductLibraryView(
        isPresented: $showingProductLibrary,
        initiallyShowingArchived: true,
        onOpenProduct: {}
      )
    }
  }
}

private struct ProductOnboardingBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      LinearGradient(
        colors: [
          Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.09),
          Color.purple.opacity(colorScheme == .dark ? 0.08 : 0.045),
          Color.clear,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      Circle()
        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.1 : 0.065))
        .frame(width: 520, height: 520)
        .blur(radius: 90)
        .offset(x: 430, y: -280)

      Circle()
        .fill(Color.purple.opacity(colorScheme == .dark ? 0.08 : 0.045))
        .frame(width: 460, height: 460)
        .blur(radius: 100)
        .offset(x: -480, y: 320)

      VStack(spacing: 0) {
        HStack(spacing: 11) {
          if let iconURL = SpeditoResources.url(
            forResource: "AppIcon",
            withExtension: "png"
          ),
            let appIcon = NSImage(contentsOf: iconURL)
          {
            Image(nsImage: appIcon)
              .resizable()
              .interpolation(.high)
              .frame(width: 48, height: 48)
              .accessibilityHidden(true)
          } else {
            Image(systemName: "shippingbox.fill")
              .font(.title2.weight(.semibold))
              .foregroundStyle(Color.accentColor)
              .frame(width: 38, height: 38)
              .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
          }

          VStack(alignment: .leading, spacing: 1) {
            Text("Spedito")
              .font(.headline)
            Text("Product delivery, kept in your control")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 56)

        Spacer()

        HStack(spacing: 26) {
          onboardingPromise(
            symbol: "internaldrive",
            title: "Local-first",
            detail: "Your product stays on this Mac"
          )
          onboardingPromise(
            symbol: "person.crop.circle",
            title: "Made for product owners",
            detail: "Describe outcomes in product language"
          )
          onboardingPromise(
            symbol: "checkmark.shield",
            title: "Review before delivery",
            detail: "You approve the work that ships"
          )
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
      }
    }
    .clipped()
  }

  private func onboardingPromise(symbol: String, title: String, detail: String) -> some View {
    HStack(spacing: 9) {
      Image(systemName: symbol)
        .font(.callout.weight(.semibold))
        .foregroundStyle(Color.accentColor)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
