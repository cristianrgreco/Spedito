import SpeditoCore
import SwiftUI

struct ProductLibraryView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onOpenProduct: () -> Void
  @State private var searchText = ""
  @State private var selectedProductID: UUID?
  @State private var showingNewProduct = false
  @State private var showingArchived: Bool
  @State private var isOpening = false
  @State private var restoringProductID: UUID?

  init(
    isPresented: Binding<Bool>,
    initiallyShowingArchived: Bool = false,
    onOpenProduct: @escaping () -> Void
  ) {
    _isPresented = isPresented
    _showingArchived = State(initialValue: initiallyShowingArchived)
    self.onOpenProduct = onOpenProduct
  }

  private var visibleProducts: [Product] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.products
      .filter { product in
        query.isEmpty
          || product.name.localizedCaseInsensitiveContains(query)
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  private var visibleAttentionProducts: [Product] {
    visibleProducts.filter {
      $0.id != model.selectedProductID
        && model.ownerAttentionCount(for: $0.id) > 0
    }
  }

  private var visibleOtherProducts: [Product] {
    visibleProducts.filter {
      $0.id == model.selectedProductID
        || model.ownerAttentionCount(for: $0.id) == 0
    }
  }

  private var visibleAttentionCount: Int {
    visibleAttentionProducts.reduce(0) {
      $0 + model.ownerAttentionCount(for: $1.id)
    }
  }

  private var visibleAttentionRequiresAction: Bool {
    visibleAttentionProducts.contains {
      model.ownerAttentionRequiresAction(productID: $0.id)
    }
  }

  private var selectedProduct: Product? {
    model.products.first { $0.id == selectedProductID }
  }

  private var visibleArchivedProducts: [Product] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.archivedProducts
      .filter { product in
        query.isEmpty
          || product.name.localizedCaseInsensitiveContains(query)
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  private var displaysArchivedProducts: Bool {
    showingArchived || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Products")
            .font(.largeTitle.bold())
          Text("Choose a local product workspace or start a new one.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !model.archivedProducts.isEmpty {
          Button(showingArchived ? "Hide archived" : "Show archived") {
            showingArchived.toggle()
          }
          .accessibilityIdentifier("products.archived.toggle")
        }
        Button {
          showingNewProduct = true
        } label: {
          Label("New product", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(24)

      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search products", text: $searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(.separator.opacity(0.65), lineWidth: 1)
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 16)

      Divider()

      ScrollView {
        LazyVStack(spacing: 4) {
          if visibleProducts.isEmpty {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              ContentUnavailableView(
                "No active products",
                systemImage: "shippingbox",
                description: Text("Create a product or restore one from the archive.")
              )
              .frame(maxWidth: .infinity, minHeight: 220)
            } else if !displaysArchivedProducts || visibleArchivedProducts.isEmpty {
              ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 220)
            }
          } else {
            if !visibleAttentionProducts.isEmpty {
              HStack(spacing: 7) {
                Text("Needs your attention")
                  .font(.headline)
                Text(visibleAttentionCount.formatted())
                  .font(.caption2.monospacedDigit().weight(.bold))
                  .foregroundStyle(.white)
                  .padding(.horizontal, 7)
                  .padding(.vertical, 2)
                  .background(
                    visibleAttentionRequiresAction ? Color.orange : Color.purple,
                    in: Capsule()
                  )
                  .accessibilityLabel(
                    "\(visibleAttentionCount) "
                      + (visibleAttentionCount == 1 ? "item needs" : "items need")
                      + " your attention"
                  )
                Spacer()
              }
              .padding(.horizontal, 6)
              .padding(.bottom, 2)

              ForEach(visibleAttentionProducts) { product in
                productRow(product)
              }
            }

            if !visibleOtherProducts.isEmpty {
              if !visibleAttentionProducts.isEmpty {
                HStack {
                  Text("Other products")
                    .font(.headline)
                  Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .padding(.bottom, 2)
              }

              ForEach(visibleOtherProducts) { product in
                productRow(product)
              }
            }
          }

          if displaysArchivedProducts && !visibleArchivedProducts.isEmpty {
            HStack {
              Text("Archived")
                .font(.headline)
              Text(visibleArchivedProducts.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              Spacer()
            }
            .padding(.top, visibleProducts.isEmpty ? 4 : 10)

            ForEach(visibleArchivedProducts) { product in
              ArchivedProductLibraryRow(
                product: product,
                isRestoring: restoringProductID == product.id,
                isDisabled: restoringProductID != nil || isOpening,
                onRestore: { restoreAndOpen(product) }
              )
            }
          }
        }
        .padding(16)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button(isOpening ? "Opening…" : "Open") {
          openSelectedProduct()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(selectedProduct == nil || isOpening || restoringProductID != nil)
        .accessibilityIdentifier("products.open")
      }
      .padding(.horizontal, 20)
      .frame(height: 58)
    }
    .frame(width: 640, height: 480)
    .onAppear {
      selectedProductID = model.selectedProductID ?? model.products.first?.id
    }
    .sheet(isPresented: $showingNewProduct) {
      NewProductView(
        isPresented: $showingNewProduct,
        onCreated: {
          onOpenProduct()
          isPresented = false
        }
      )
    }
  }

  private func productRow(_ product: Product) -> some View {
    ProductLibraryRow(
      product: product,
      isSelected: selectedProductID == product.id,
      attentionCount:
        product.id == model.selectedProductID
        ? 0
        : model.ownerAttentionCount(for: product.id),
      requiresAction: model.ownerAttentionRequiresAction(productID: product.id)
    )
    .onTapGesture {
      selectedProductID = product.id
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        selectedProductID = product.id
        openSelectedProduct()
      }
    )
  }

  private func openSelectedProduct() {
    guard let selectedProduct, !isOpening, restoringProductID == nil else { return }
    isOpening = true
    Task {
      if selectedProduct.id == model.selectedProductID {
        await model.reloadSelectedProduct()
      } else if model.ownerAttentionCount(for: selectedProduct.id) > 0 {
        await model.openOwnerAttentions(for: selectedProduct)
      } else {
        await model.selectProduct(selectedProduct)
      }
      isOpening = false
      onOpenProduct()
      isPresented = false
    }
  }

  private func restoreAndOpen(_ product: Product) {
    guard restoringProductID == nil, !isOpening else { return }
    restoringProductID = product.id
    Task {
      let restored = await model.restoreProductAndSelect(product)
      restoringProductID = nil
      if restored {
        onOpenProduct()
        isPresented = false
      }
    }
  }
}

extension ProductColor {
  var displayColor: Color {
    switch self {
    case .accent: .accentColor
    case .blue: .blue
    case .teal: .teal
    case .green: .green
    case .orange: .orange
    case .pink: .pink
    case .indigo: .indigo
    }
  }
}

extension EpicColor {
  var displayColor: Color {
    switch self {
    case .blue: .blue
    case .teal: .teal
    case .green: .green
    case .orange: .orange
    case .pink: .pink
    case .indigo: .indigo
    }
  }
}

struct ProductIcon: View {
  let product: Product
  let size: CGFloat

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.23)
        .fill(product.color.displayColor.opacity(0.12))
      Text(product.name.prefix(1).uppercased())
        .font(.system(size: size * 0.42, weight: .bold))
        .foregroundStyle(product.color.displayColor)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct ProductLibraryRow: View {
  let product: Product
  let isSelected: Bool
  let attentionCount: Int
  let requiresAction: Bool

  var body: some View {
    HStack(spacing: 10) {
      ProductIcon(product: product, size: 28)

      Text(product.name)
        .font(.body.weight(.semibold))

      Spacer(minLength: 12)
      if attentionCount > 0 {
        Label(
          attentionCount == 1
            ? "1 needs your attention"
            : "\(attentionCount) need your attention",
          systemImage: requiresAction ? "hand.raised.fill" : "bell.badge.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(requiresAction ? Color.orange : Color.purple)
      }

      if isSelected {
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 18)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    .background(
      isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
      in: RoundedRectangle(cornerRadius: 7)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(
          isSelected
            ? Color.accentColor.opacity(0.65)
            : Color.clear
        )
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("product.row.\(product.id.uuidString)")
  }
}

private struct ArchivedProductLibraryRow: View {
  let product: Product
  let isRestoring: Bool
  let isDisabled: Bool
  let onRestore: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "archivebox.fill")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

      Text(product.name)
        .font(.body.weight(.semibold))

      Spacer(minLength: 12)

      Button(isRestoring ? "Restoring…" : "Restore and open", action: onRestore)
        .disabled(isDisabled)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("product.archived.row.\(product.id.uuidString)")
  }
}
