import AppKit
import StoryPointlessCore
import SwiftUI

private struct WorkspaceContainerSizeKey: EnvironmentKey {
  static let defaultValue = CGSize(width: 1_320, height: 820)
}

private extension EnvironmentValues {
  var workspaceContainerSize: CGSize {
    get { self[WorkspaceContainerSizeKey.self] }
    set { self[WorkspaceContainerSizeKey.self] = newValue }
  }
}

struct ContentView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    GeometryReader { geometry in
      Group {
        if model.isLoading && model.products.isEmpty {
          ProgressView("Opening workspace…")
        } else if model.products.isEmpty {
          ProductOnboardingView()
        } else {
          ProductWorkspaceView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .environment(\.workspaceContainerSize, geometry.size)
    }
    .alert(
      "StoryPointless couldn't complete that action",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }
}

private struct ProductOnboardingView: View {
  @EnvironmentObject private var model: AppModel
  @State private var name = ""
  @State private var vision = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Create your product")
          .font(.largeTitle.bold())
        Text(
          "Describe the outcome. StoryPointless will create the local workspace and delivery team."
        )
        .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 18) {
        EditableTextField(
          title: "Product name",
          prompt: "e.g. Weather Window",
          text: $name
        )
        EditableTextArea(
          title: "Product description",
          prompt: "Describe who it is for, the problem it solves, and the outcome you want.",
          text: $vision,
          minHeight: 150
        )
      }

      HStack {
        Spacer()
        Button("Create product") {
          model.createProduct(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            vision: vision.trimmingCharacters(in: .whitespacesAndNewlines)
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || vision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(44)
    .frame(maxWidth: 720)
  }
}

private enum WorkspaceDestination: String, Hashable {
  case backlog
  case sprint
  case retrospectives
  case reports
  case knowledge
  case codebase
}

private struct TicketDetailPresentation: Identifiable {
  let item: WorkItem
  let startRefinementOnAppear: Bool

  var id: UUID { item.id }
}

private struct ProductWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var destination = WorkspaceDestination.backlog
  @State private var showingNewTicket = false
  @State private var showingNewEpic = false
  @State private var newTicketEpicID: UUID?
  @State private var showingSprintPlanning = false
  @State private var showingProductLibrary = false
  @State private var ticketDetailPresentation: TicketDetailPresentation?

  private static let destinationDefaultsPrefix = "workspaceDestination"

  var body: some View {
    NavigationSplitView {
      TeamSidebar(
        selection: $destination,
        onShowProducts: { showingProductLibrary = true }
      )
        .navigationSplitViewColumnWidth(min: 232, ideal: 272, max: 320)
    } detail: {
      Group {
        switch destination {
        case .backlog:
          BacklogView(
            onNewTicket: { epicID in
              newTicketEpicID = epicID
              showingNewTicket = true
            },
            onNewEpic: { showingNewEpic = true },
            onPlanSprint: { showingSprintPlanning = true },
            onOpenSprint: { destination = .sprint }
          )
        case .sprint:
          SprintBoardView(
            onShowBacklog: { destination = .backlog },
            onEditPlan: { showingSprintPlanning = true },
            onShowRetrospective: { destination = .retrospectives },
            onShowReports: { destination = .reports }
          )
        case .retrospectives:
          RetrospectivesView(
            onConcluded: { destination = .backlog }
          )
        case .reports:
          ReportsView()
        case .knowledge:
          KnowledgeBaseView()
        case .codebase:
          CodebaseView(
            onOpenTicket: { item in
              ticketDetailPresentation = TicketDetailPresentation(
                item: item,
                startRefinementOnAppear: false
              )
            }
          )
        }
      }
    }
    .onAppear {
      restoreDestination(for: model.selectedProductID)
    }
    .onChange(of: destination) { _, destination in
      persist(destination, for: model.selectedProductID)
    }
    .onChange(of: model.codebaseFocusWorkItemID) { _, workItemID in
      if workItemID != nil {
        destination = .codebase
      }
    }
    .onChange(of: model.knowledgeFocusPageID) { _, pageID in
      if pageID != nil {
        destination = .knowledge
      }
    }
    .sheet(isPresented: $showingNewTicket) {
      NewTicketView(
        isPresented: $showingNewTicket,
        initialEpicID: newTicketEpicID,
        onCreated: { item, shouldRefine in
          showingNewTicket = false
          Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            ticketDetailPresentation = TicketDetailPresentation(
              item: item,
              startRefinementOnAppear: shouldRefine
            )
          }
        }
      )
    }
    .sheet(isPresented: $showingNewEpic) {
      NewEpicView(isPresented: $showingNewEpic)
    }
    .sheet(item: $ticketDetailPresentation) { presentation in
      TicketDetailView(
        item: presentation.item,
        dependsOnWorkItemIDs: [],
        startRefinementOnAppear: presentation.startRefinementOnAppear
      )
    }
    .sheet(isPresented: $showingSprintPlanning) {
      SprintPlanningView(
        isPresented: $showingSprintPlanning,
        onSaved: {
          destination = model.sprintPlan?.sprint.state == .active ? .backlog : .sprint
        }
      )
    }
    .sheet(isPresented: $showingProductLibrary) {
      ProductLibraryView(
        isPresented: $showingProductLibrary,
        onOpenProduct: {
          restoreDestination(for: model.selectedProductID)
        }
      )
    }
    .onAppear {
      if model.shouldPresentProductLibraryOnLaunch {
        model.consumeProductLibraryLaunchPrompt()
        showingProductLibrary = true
      }
    }
    .task(id: model.selectedProductID) {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      presentInitialEpicIfNeeded()
    }
  }

  private func restoreDestination(for productID: UUID?) {
    guard let productID else {
      destination = .backlog
      return
    }
    let rawValue = UserDefaults.standard.string(
      forKey: destinationDefaultsKey(for: productID)
    )
    destination =
      rawValue.flatMap(WorkspaceDestination.init(rawValue:))
      ?? (model.sprintPlan?.sprint.state == .active ? .sprint : .backlog)
  }

  private func persist(_ destination: WorkspaceDestination, for productID: UUID?) {
    guard let productID else { return }
    UserDefaults.standard.set(
      destination.rawValue,
      forKey: destinationDefaultsKey(for: productID)
    )
  }

  private func destinationDefaultsKey(for productID: UUID) -> String {
    "\(Self.destinationDefaultsPrefix).\(productID.uuidString)"
  }

  private func presentInitialEpicIfNeeded() {
    guard
      let productID = model.selectedProductID,
      model.epics.isEmpty,
      model.workItems.isEmpty,
      !showingProductLibrary
    else { return }
    let key = "initialEpicPrompt.\(productID.uuidString)"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    showingNewEpic = true
  }
}

private struct TeamSidebar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selection: WorkspaceDestination
  let onShowProducts: () -> Void
  @State private var showingTeamPrompts = false
  @State private var showingProductContext = false
  @AppStorage("teamSidebarExpanded") private var isTeamExpanded = true

  private var sprintAttentionCount: Int {
    guard
      let plan = model.sprintPlan,
      plan.sprint.state == .active
    else { return 0 }
    let sprintWorkItemIDs = Set(plan.items.map(\.workItemID))
    var attentionIDs = Set(
      model.runs
        .filter {
          $0.status == .awaitingOwner && sprintWorkItemIDs.contains($0.workItemID)
        }
        .map(\.workItemID)
    )
    attentionIDs.formUnion(
      model.workItems
        .filter {
          sprintWorkItemIDs.contains($0.id)
            && ($0.state == .acceptance || $0.state == .readyToRelease)
        }
        .map(\.id)
    )
    return attentionIDs.count
  }

  private var pendingRetrospectiveCount: Int {
    model.sprintHistory.filter {
      $0.sprint.state == .completed
        && $0.sprint.retrospectiveConcludedAt == nil
    }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $selection) {
        if let product = model.selectedProduct {
          Section("Product") {
            VStack(alignment: .leading, spacing: 9) {
              Button(action: onShowProducts) {
                HStack(spacing: 9) {
                  Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(product.name)
                      .font(.headline)
                      .foregroundStyle(.primary)
                      .lineLimit(1)
                    Text("Switch product")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help("Browse and switch products")

              Button {
                showingProductContext = true
              } label: {
                Label("View product context", systemImage: "doc.text")
                  .font(.caption)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
          }
        }

        Section("Workspace") {
          Label("Backlog", systemImage: "list.bullet.rectangle")
            .tag(WorkspaceDestination.backlog)
          HStack {
            Label("Sprint Board", systemImage: "rectangle.3.group")
            Spacer()
            if sprintAttentionCount > 0 {
              Text(sprintAttentionCount.formatted())
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
                .accessibilityLabel(
                  "\(sprintAttentionCount) sprint ticket\(sprintAttentionCount == 1 ? "" : "s") need your input"
                )
            }
          }
            .tag(WorkspaceDestination.sprint)
        }

        Section("Improve") {
          HStack {
            Label("Retrospectives", systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            if pendingRetrospectiveCount > 0 {
              Text(pendingRetrospectiveCount.formatted())
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(
                  selection == .retrospectives ? Color.accentColor : .white
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                  selection == .retrospectives ? Color.white : Color.accentColor,
                  in: Capsule()
                )
                .accessibilityLabel(
                  "\(pendingRetrospectiveCount) retrospective\(pendingRetrospectiveCount == 1 ? "" : "s") to conclude"
                )
            }
          }
            .tag(WorkspaceDestination.retrospectives)
          Label("Reports", systemImage: "chart.xyaxis.line")
            .tag(WorkspaceDestination.reports)
        }

        Section("Knowledge") {
          Label("Product", systemImage: "books.vertical")
            .tag(WorkspaceDestination.knowledge)
          Label("Codebase", systemImage: "chevron.left.forwardslash.chevron.right")
            .tag(WorkspaceDestination.codebase)
        }

        Section {
          if isTeamExpanded {
            Button {
              showingTeamPrompts = true
            } label: {
              HStack(spacing: 9) {
                Image(systemName: "gearshape")
                  .frame(width: 20)
                  .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                VStack(alignment: .leading, spacing: 1) {
                  Text("Team settings")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                  Text("Models, effort & instructions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            .padding(.bottom, 9)
            .help("Configure team models, effort, and instructions")

            ForEach(model.profiles) { profile in
              VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                  Image(systemName: profile.role.symbolName)
                    .frame(width: 20)
                    .foregroundStyle(profile.role.tint)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                      .font(.callout.weight(.medium))
                    Text(profile.role.capabilityTitle)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                }

                HStack(spacing: 10) {
                  ProfileModelMenu(profile: profile)
                  ProfileEffortMenu(profile: profile)
                }
                .padding(.leading, 29)
              }
              .padding(.vertical, 3)
            }
          }
        } header: {
          Button {
            withAnimation(.easeInOut(duration: 0.16)) {
              isTeamExpanded.toggle()
            }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: isTeamExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
              Text("Team")
              Text(model.profiles.count.formatted())
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(isTeamExpanded ? "Collapse team" : "Expand team")
        }
      }
      .listStyle(.sidebar)

      Divider()
      SidebarCodexStatus()
    }
    .sheet(isPresented: $showingTeamPrompts) {
      TeamPromptsView(isPresented: $showingTeamPrompts)
    }
    .sheet(isPresented: $showingProductContext) {
      ProductContextView(isPresented: $showingProductContext)
    }
  }

}

private struct SidebarCodexStatus: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: model.codexConnectionState.symbolName)
        .foregroundStyle(model.codexConnectionState.tint)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text("Codex")
          .font(.caption.weight(.medium))
        Text(model.codexConnectionState.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(height: 42)
    .background(.bar)
    .accessibilityElement(children: .combine)
  }
}

private struct ProductLibraryView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onOpenProduct: () -> Void
  @State private var searchText = ""
  @State private var selectedProductID: UUID?
  @State private var showingNewProduct = false
  @State private var isOpening = false

  private var visibleProducts: [Product] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.products
      .filter { product in
        query.isEmpty
          || product.name.localizedCaseInsensitiveContains(query)
          || product.vision.localizedCaseInsensitiveContains(query)
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  private var selectedProduct: Product? {
    model.products.first { $0.id == selectedProductID }
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
        LazyVStack(spacing: 10) {
          if visibleProducts.isEmpty {
            ContentUnavailableView.search(text: searchText)
              .frame(maxWidth: .infinity, minHeight: 300)
          } else {
            ForEach(visibleProducts) { product in
              ProductLibraryRow(
                product: product,
                isSelected: selectedProductID == product.id,
                isCurrent: model.selectedProductID == product.id
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
          }
        }
        .padding(20)
      }

      Divider()

      HStack {
        Text("\(model.products.count) local product\(model.products.count == 1 ? "" : "s")")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { isPresented = false }
        Button(isOpening ? "Opening…" : "Open") {
          openSelectedProduct()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(selectedProduct == nil || isOpening)
      }
      .padding(.horizontal, 20)
      .frame(height: 62)
    }
    .frame(width: 780, height: 640)
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

  private func openSelectedProduct() {
    guard let selectedProduct, !isOpening else { return }
    isOpening = true
    Task {
      await model.selectProduct(selectedProduct)
      isOpening = false
      onOpenProduct()
      isPresented = false
    }
  }
}

private struct ProductLibraryRow: View {
  let product: Product
  let isSelected: Bool
  let isCurrent: Bool

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 11)
          .fill(Color.accentColor.opacity(0.12))
        Text(product.name.prefix(1).uppercased())
          .font(.title2.bold())
          .foregroundStyle(Color.accentColor)
      }
      .frame(width: 48, height: 48)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(product.name)
            .font(.headline)
          if isCurrent {
            Text("OPEN")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.green)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.green.opacity(0.1), in: Capsule())
          }
        }
        Text(product.vision)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 16)

      VStack(alignment: .trailing, spacing: 4) {
        Text("Updated")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(product.updatedAt, format: .dateTime.day().month(.abbreviated).year())
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.title3)
        .foregroundStyle(
          isSelected ? Color.blue : Color(nsColor: .tertiaryLabelColor)
        )
        .frame(width: 24)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
    .background(
      isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(
          isSelected
            ? Color.accentColor.opacity(0.7)
            : Color(nsColor: .separatorColor).opacity(0.45)
        )
    }
    .contentShape(Rectangle())
  }
}

private struct NewProductView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onCreated: () -> Void
  @State private var name = ""
  @State private var vision = ""
  @State private var isCreating = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New product")
          .font(.title.bold())
        Text("Create a separate local workspace with its own backlog, team, and knowledge.")
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        EditableTextField(
          title: "Product name",
          prompt: "e.g. Weather Window",
          text: $name
        )
        EditableTextArea(
          title: "Product description",
          prompt: "Describe who it is for, the problem it solves, and the outcome you want.",
          text: $vision,
          minHeight: 180
        )
      }
      .padding(24)

      Spacer()
      Divider()

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button(isCreating ? "Creating…" : "Create and open") {
          createProduct()
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || vision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isCreating
        )
      }
      .padding(20)
    }
    .frame(width: 680, height: 560)
  }

  private func createProduct() {
    isCreating = true
    Task {
      let created = await model.createProductAndSelect(
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        vision: vision.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      isCreating = false
      if created {
        isPresented = false
        onCreated()
      }
    }
  }
}

private struct ProductContextView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var name = ""
  @State private var description = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Product context")
          .font(.title2.bold())
        Text("The durable product description supplied to planning and delivery agents.")
          .foregroundStyle(.secondary)
      }

      EditableTextField(
        title: "Product name",
        prompt: "Product name",
        text: $name
      )

      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("Product description")
            .font(.headline)
          Spacer()
          Text("\(description.count.formatted()) characters")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        TextEditor(text: $description)
          .scrollContentBackground(.hidden)
          .multilineTextAlignment(.leading)
          .font(.body)
          .frame(minHeight: 250)
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(.separator.opacity(0.7), lineWidth: 1)
          }
      }

      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "brain.head.profile")
          .foregroundStyle(.purple)
        Text(
          "This description forms part of agent context. Changes affect future analysis and runs; an already-started turn keeps the context it began with. Shared behavioural guidance remains under Team Settings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button("Save product context") {
          model.updateProductDetails(name: name, vision: description)
          isPresented = false
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(24)
    .frame(width: 720, height: 610)
    .onAppear {
      name = model.selectedProduct?.name ?? ""
      description = model.selectedProduct?.vision ?? ""
    }
  }
}

private struct ProfileModelMenu: View {
  @EnvironmentObject private var model: AppModel
  let profile: AgentProfile
  @State private var showingOptions = false

  var body: some View {
    Button {
      showingOptions.toggle()
    } label: {
      HStack(spacing: 4) {
        Text(model.modelOption(for: profile)?.displayName ?? profile.model)
          .lineLimit(1)
        Spacer(minLength: 3)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .semibold))
      }
      .font(.system(size: 10, weight: .regular))
      .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
      .frame(width: 122, height: 16, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Change model")
    .popover(isPresented: $showingOptions, arrowEdge: .trailing) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Model")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.bottom, 3)
        if model.codexModels.isEmpty {
          Text("Model catalog unavailable")
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.codexModels) { option in
            Button {
              model.updateProfile(profile, model: option.model)
              showingOptions = false
            } label: {
              HStack(spacing: 10) {
                Text(option.displayName)
                Spacer()
                if option.model == profile.model {
                  Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
                }
              }
              .font(.callout)
              .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(12)
      .frame(width: 220)
    }
  }
}

private struct ProfileEffortMenu: View {
  @EnvironmentObject private var model: AppModel
  let profile: AgentProfile
  @State private var showingOptions = false

  var body: some View {
    Button {
      showingOptions.toggle()
    } label: {
      HStack(spacing: 4) {
        Text(profile.reasoningEffort.displayEffort)
        Spacer(minLength: 3)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .semibold))
      }
      .font(.system(size: 10, weight: .regular))
      .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
      .frame(width: 66, height: 16, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Change reasoning effort")
    .popover(isPresented: $showingOptions, arrowEdge: .trailing) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Reasoning effort")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.bottom, 3)
        ForEach(model.reasoningEfforts(for: profile)) { effort in
          Button {
            model.updateProfile(profile, effort: effort.id)
            showingOptions = false
          } label: {
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 1) {
                Text(effort.id.displayEffort)
                  .font(.callout)
                Text(effort.description)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if effort.id == profile.reasoningEffort {
                Image(systemName: "checkmark")
                  .foregroundStyle(.blue)
              }
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(12)
      .frame(width: 250)
    }
  }
}

private enum TeamSettingsSelection: Hashable {
  case shared
  case profile(UUID)
}

private struct TeamPromptsView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var sharedInstructions = ""
  @State private var personaInstructions: [UUID: String] = [:]
  @State private var personaModels: [UUID: String] = [:]
  @State private var personaEfforts: [UUID: String] = [:]
  @State private var showingAddPersona = false
  @State private var selection: TeamSettingsSelection? = .shared
  @State private var isHoveringAddMember = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Team settings")
            .font(.title2.bold())
          Text("Configure each team member's model, reasoning effort, and instructions.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(22)

      Divider()

      HStack(spacing: 0) {
        VStack(spacing: 0) {
          List(selection: $selection) {
            Section("Product") {
              HStack(spacing: 10) {
                Image(systemName: "person.3")
                  .foregroundStyle(.secondary)
                  .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                  Text("Shared guidance")
                  Text("Applies to everyone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 7)
              .listRowInsets(
                EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18)
              )
              .listRowSeparator(.hidden)
              .tag(TeamSettingsSelection.shared)
            }

            Section("Team members") {
              ForEach(model.profiles) { profile in
                HStack(spacing: 10) {
                  Image(systemName: profile.role.symbolName)
                    .foregroundStyle(profile.role.tint)
                    .frame(width: 18)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                      .lineLimit(1)
                    Text(profile.role.capabilityTitle)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                .padding(.vertical, 7)
                .listRowInsets(
                  EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18)
                )
                .listRowSeparator(.hidden)
                .tag(TeamSettingsSelection.profile(profile.id))
              }
            }
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .background(Color(nsColor: .textBackgroundColor))

          Divider()

          Button {
            showingAddPersona = true
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "person.badge.plus")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
              Text("Add team member")
                .font(.callout.weight(.medium))
              Spacer()
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
              isHoveringAddMember
                ? Color.accentColor.opacity(0.1)
                : Color.clear,
              in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 8)
          .padding(.vertical, 8)
          .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
              isHoveringAddMember = hovering
            }
          }
          .help("Add a custom team member")
        }
        .frame(width: 248)
        .background(Color(nsColor: .textBackgroundColor))

        Divider()

        Group {
          switch selection ?? .shared {
          case .shared:
            sharedGuidanceSettings
          case .profile(let profileID):
            if let profile = model.profiles.first(where: { $0.id == profileID }) {
              memberSettings(profile)
            } else {
              sharedGuidanceSettings
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button("Save") { saveSettings() }
          .buttonStyle(.borderedProminent)
      }
      .padding(.horizontal, 22)
      .frame(height: 62)
    }
    .frame(width: 840, height: 740)
    .sheet(isPresented: $showingAddPersona) {
      AddPersonaView(isPresented: $showingAddPersona)
    }
    .onAppear {
      synchronisePromptState(includeShared: true)
    }
    .onChange(of: model.profiles) {
      synchronisePromptState(includeShared: false)
      if case .profile(let profileID)? = selection,
        !model.profiles.contains(where: { $0.id == profileID })
      {
        selection = .shared
      }
    }
  }

  private var sharedGuidanceSettings: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Shared product guidance")
            .font(.title3.bold())
          Text(
            "Optional conventions and product principles supplied to every team member."
          )
          .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 9) {
          Text("Instructions")
            .font(.headline)
          Text(
            "The product vision, ticket contract, and definition of done are supplied separately."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          TextEditor(text: $sharedInstructions)
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
        }

        Label {
          Text(
            "Safety, permissions, approved scope, and workflow gates are enforced by StoryPointless and cannot be changed here."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "lock.shield")
            .foregroundStyle(.secondary)
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func memberSettings(_ profile: AgentProfile) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 12) {
          Image(systemName: profile.role.symbolName)
            .font(.title2)
            .foregroundStyle(profile.role.tint)
            .frame(width: 28)
          VStack(alignment: .leading, spacing: 3) {
            Text(profile.name)
              .font(.title3.bold())
            Text(profile.role.capabilityTitle)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if !profile.isBuiltIn {
            Button(role: .destructive) {
              model.archiveCustomPersona(profile)
            } label: {
              Label("Remove member", systemImage: "trash")
            }
            .buttonStyle(.borderless)
          }
        }

        VStack(alignment: .leading, spacing: 14) {
          Text("Runtime")
            .font(.headline)

          Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
            GridRow {
              Text("Model")
                .foregroundStyle(.secondary)
              Picker("Model", selection: modelBinding(for: profile)) {
                if model.codexModels.isEmpty {
                  Text(profile.model).tag(profile.model)
                } else {
                  ForEach(model.codexModels) { option in
                    Text(option.displayName).tag(option.model)
                  }
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            GridRow {
              Text("Reasoning effort")
                .foregroundStyle(.secondary)
              Picker("Reasoning effort", selection: effortBinding(for: profile)) {
                ForEach(effortOptions(for: profile)) { effort in
                  Text(effort.id.displayEffort).tag(effort.id)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .frame(maxWidth: 480, alignment: .leading)
        }

        VStack(alignment: .leading, spacing: 9) {
          HStack {
            Text("Member instructions")
              .font(.headline)
            Spacer()
            Button("Restore role default") {
              personaInstructions[profile.id] = AgentPersonaDefaults.instructions(
                for: profile.role
              )
            }
            .buttonStyle(.borderless)
            .font(.caption)
          }

          Text(
            "These instructions refine how this member works without changing its permissions or governed capability."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          TextEditor(
            text: Binding(
              get: { personaInstructions[profile.id] ?? profile.effectiveInstructions },
              set: { personaInstructions[profile.id] = $0 }
            )
          )
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func synchronisePromptState(includeShared: Bool) {
    if includeShared {
      sharedInstructions = model.selectedProduct?.instructions ?? ""
    }
    for profile in model.profiles {
      personaInstructions[profile.id] =
        profile.customInstructions ?? AgentPersonaDefaults.instructions(for: profile.role)
      personaModels[profile.id] = profile.model
      personaEfforts[profile.id] = profile.reasoningEffort
    }
    let activeIDs = Set(model.profiles.map(\.id))
    personaInstructions = personaInstructions.filter { activeIDs.contains($0.key) }
    personaModels = personaModels.filter { activeIDs.contains($0.key) }
    personaEfforts = personaEfforts.filter { activeIDs.contains($0.key) }
  }

  private func saveSettings() {
    let instructionUpdates = Dictionary(
      uniqueKeysWithValues: model.profiles.map { profile in
        let instructions = personaInstructions[profile.id] ?? profile.effectiveInstructions
        let roleDefault = AgentPersonaDefaults.instructions(for: profile.role)
        return (
          profile.id,
          instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            == roleDefault.trimmingCharacters(in: .whitespacesAndNewlines)
            ? "" : instructions
        )
      }
    )
    model.updateTeamSettings(
      productInstructions: sharedInstructions,
      modelsByProfile: personaModels,
      effortsByProfile: personaEfforts,
      customInstructionsByProfile: instructionUpdates
    )
    isPresented = false
  }

  private func modelBinding(for profile: AgentProfile) -> Binding<String> {
    Binding(
      get: { personaModels[profile.id] ?? profile.model },
      set: { selectedModel in
        personaModels[profile.id] = selectedModel
        guard let option = model.codexModels.first(where: { $0.model == selectedModel }) else {
          return
        }
        let supported = option.supportedReasoningEfforts.map(\.id)
        let currentEffort = personaEfforts[profile.id] ?? profile.reasoningEffort
        if !supported.contains(currentEffort) {
          personaEfforts[profile.id] = option.defaultReasoningEffort
        }
      }
    )
  }

  private func effortBinding(for profile: AgentProfile) -> Binding<String> {
    Binding(
      get: { personaEfforts[profile.id] ?? profile.reasoningEffort },
      set: { personaEfforts[profile.id] = $0 }
    )
  }

  private func effortOptions(for profile: AgentProfile) -> [CodexReasoningEffortOption] {
    let selectedModel = personaModels[profile.id] ?? profile.model
    return model.codexModels.first(where: { $0.model == selectedModel })?
      .supportedReasoningEfforts
      ?? [
        CodexReasoningEffortOption(
          id: personaEfforts[profile.id] ?? profile.reasoningEffort,
          description: "Current selection"
        )
      ]
  }
}

private struct AddPersonaView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var templateID = "blank"
  @State private var name = ""
  @State private var capability = AgentRole.businessAnalyst
  @State private var selectedModel = "gpt-5.6-terra"
  @State private var effort = "medium"
  @State private var instructions = ""

  private var selectedModelOption: CodexModelOption? {
    model.codexModels.first { $0.model == selectedModel }
  }

  private var effortOptions: [CodexReasoningEffortOption] {
    selectedModelOption?.supportedReasoningEfforts ?? [
      CodexReasoningEffortOption(id: effort, description: "Current selection")
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add team member")
          .font(.title2.bold())
        Text("Start with a specialist template or configure a member from scratch.")
          .foregroundStyle(.secondary)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 7) {
            Text("Starting point")
              .font(.subheadline.weight(.semibold))
            Picker("Starting point", selection: $templateID) {
              Text("Blank team member").tag("blank")
              Divider()
              ForEach(PersonaTemplate.common) { template in
                Text(template.name).tag(template.id)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: templateID) {
              applySelectedTemplate()
            }
          }

          EditableTextField(
            title: "Team member name",
            prompt: "e.g. Security Auditor",
            text: $name
          )

          HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
              Text("Governed capability")
                .font(.subheadline.weight(.semibold))
              Picker("Governed capability", selection: $capability) {
                ForEach(AgentRole.allCases, id: \.self) { role in
                  Text(role.capabilityTitle).tag(role)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
              Text("Model")
                .font(.subheadline.weight(.semibold))
              Picker("Model", selection: $selectedModel) {
                if model.codexModels.isEmpty {
                  Text(selectedModel).tag(selectedModel)
                } else {
                  ForEach(model.codexModels) { option in
                    Text(option.displayName).tag(option.model)
                  }
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .onChange(of: selectedModel) {
                let efforts = effortOptions.map(\.id)
                if !efforts.contains(effort) {
                  effort = selectedModelOption?.defaultReasoningEffort ?? efforts.first ?? "medium"
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
              Text("Reasoning effort")
                .font(.subheadline.weight(.semibold))
              Picker("Reasoning effort", selection: $effort) {
                ForEach(effortOptions) { option in
                  Text(option.id.displayEffort).tag(option.id)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          EditableTextArea(
            title: "Member instructions",
            prompt: "Describe how this team member should approach authorised work.",
            text: $instructions,
            minHeight: 150
          )
        }
      }

      HStack {
        Label(
          "This team member uses the \(capability.capabilityTitle.lowercased()) capability and cannot expand its own permissions.",
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { isPresented = false }
        Button("Add to team") {
          model.createCustomPersona(
            name: name,
            capability: capability,
            model: selectedModel,
            effort: effort,
            instructions: instructions
          )
          isPresented = false
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 680, height: 650)
    .onAppear {
      if let defaultModel = model.codexModels.first(where: \.isDefault) {
        selectedModel = defaultModel.model
        effort = defaultModel.defaultReasoningEffort
      }
      instructions = AgentPersonaDefaults.instructions(for: capability)
    }
  }

  private func applySelectedTemplate() {
    guard let template = PersonaTemplate.common.first(where: { $0.id == templateID }) else {
      name = ""
      capability = .businessAnalyst
      selectedModel = model.codexModels.first(where: \.isDefault)?.model ?? "gpt-5.6-terra"
      effort = model.codexModels.first(where: \.isDefault)?.defaultReasoningEffort ?? "medium"
      instructions = AgentPersonaDefaults.instructions(for: capability)
      return
    }
    name = template.name
    capability = template.capability
    selectedModel =
      model.codexModels.contains { $0.model == template.model }
      ? template.model
      : model.codexModels.first(where: \.isDefault)?.model ?? template.model
    let supported = selectedModelOption?.supportedReasoningEfforts.map(\.id) ?? []
    effort = supported.contains(template.effort)
      ? template.effort
      : selectedModelOption?.defaultReasoningEffort ?? template.effort
    instructions = template.instructions
  }
}

private enum PlanningDropSection: Equatable {
  case candidateSprint
  case backlog
}

private struct PlanningDropTarget: Equatable {
  let section: PlanningDropSection
  let index: Int
}

private enum BacklogEpicFilter: Hashable {
  case all
  case unassigned
  case epic(UUID)
}

private struct BacklogView: View {
  @EnvironmentObject private var model: AppModel
  let onNewTicket: (UUID?) -> Void
  let onNewEpic: () -> Void
  let onPlanSprint: () -> Void
  let onOpenSprint: () -> Void
  @State private var selectedTicket: WorkItem?
  @State private var selectedEpic: Epic?
  @State private var epicFilter = BacklogEpicFilter.all
  @State private var selectedWorkItemIDs: Set<UUID> = []
  @State private var draggedWorkItemIDs: Set<UUID> = []
  @State private var planningDropTarget: PlanningDropTarget?
  @State private var dragResetTask: Task<Void, Never>?
  @State private var dropExitResetTask: Task<Void, Never>?

  private var allPlanningItems: [WorkItem] {
    model.workItems.filter { [.backlog, .refining, .ready].contains($0.state) }
  }

  private var planningItems: [WorkItem] {
    allPlanningItems.filter { item in
      switch epicFilter {
      case .all: true
      case .unassigned: item.epicID == nil
      case .epic(let id): item.epicID == id
      }
    }
  }

  private var candidateIDs: Set<UUID> {
    Set(model.candidateSprintPlan?.items.map(\.workItemID) ?? [])
  }

  private var candidateItems: [WorkItem] {
    planningItems.filter { candidateIDs.contains($0.id) }
  }

  private var allCandidateItems: [WorkItem] {
    allPlanningItems.filter { candidateIDs.contains($0.id) }
  }

  private var backlogItems: [WorkItem] {
    planningItems.filter { !candidateIDs.contains($0.id) }
  }

  private var candidateSprintNumber: Int {
    if let plan = model.candidateSprintPlan {
      return plan.sprint.number
    }
    return (model.sprintHistory.map(\.sprint.number).max() ?? 0) + 1
  }

  private var visibleSuggestionBatch: TicketSuggestionBatch? {
    guard let batch = model.suggestionBatch else { return nil }
    guard let epicID = batch.session.epicID else { return nil }
    switch epicFilter {
    case .all:
      break
    case .unassigned:
      return nil
    case .epic(let selectedID):
      guard selectedID == epicID else { return nil }
    }
    if batch.session.status == .cancelled {
      return nil
    }
    if batch.session.status == .ready,
      batch.suggestions.allSatisfy({ $0.status != .proposed })
    {
      return nil
    }
    return batch
  }

  private var focusedEpic: Epic? {
    guard case .epic(let id) = epicFilter else { return nil }
    return model.epics.first { $0.id == id }
  }

  private var planningIsComplete: Bool {
    guard
      let plan = model.candidateSprintPlan,
      !plan.items.isEmpty
    else { return false }
    return plan.items.allSatisfy { $0.estimatedTokens > 0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Backlog")
            .font(.largeTitle.bold())
          Text("Rank the work, shape the next sprint, and open any ticket to refine it.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: 8) {
          Button(action: onNewEpic) {
            Label("Add epic", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .help("Plan a substantial product outcome with the Business Analyst")

          Button {
            onPlanSprint()
          } label: {
            Label(
              planningIsComplete ? "Review sprint plan" : "Start sprint planning",
              systemImage: "calendar.badge.plus"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(allCandidateItems.isEmpty)

          if let plan = model.sprintPlan, plan.sprint.state == .active {
            Divider()
              .frame(height: 22)
              .padding(.horizontal, 2)

            Button(action: onOpenSprint) {
              Label("Sprint \(plan.sprint.number) active", systemImage: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .help("Open the active sprint board")
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .padding(.bottom, 12)

      EpicFilterBar(
        selection: $epicFilter,
        planningItems: allPlanningItems,
        onOpenEpic: { selectedEpic = $0 }
      )
      .padding(.horizontal, 24)
      .padding(.bottom, 24)

      Divider()

      GeometryReader { proxy in
        let sectionSpacing: CGFloat = 18
        let topPadding: CGFloat = 18
        let bottomPadding: CGFloat = 28
        let availableHeight = max(
          0,
          proxy.size.height - sectionSpacing - topPadding - bottomPadding
        )

        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: sectionSpacing) {
            PlanningTicketList(
              title: "Sprint \(candidateSprintNumber)",
              subtitle: "Selected for the next sprint",
              items: candidateItems,
              isCandidateSection: true,
              minimumHeight: availableHeight / 3,
              selectedWorkItemIDs: $selectedWorkItemIDs,
              draggedWorkItemIDs: $draggedWorkItemIDs,
              activeDropTarget: $planningDropTarget,
              onDragBegan: beginDragging,
              onDragCompleted: finishDragging,
              onOpen: { selectedTicket = $0 },
              onAddTicket: nil,
              suggestionBatch: nil
            )

            PlanningTicketList(
              title: "Backlog",
              subtitle: "Ranked work not yet planned",
              items: backlogItems,
              isCandidateSection: false,
              minimumHeight: availableHeight * 2 / 3,
              selectedWorkItemIDs: $selectedWorkItemIDs,
              draggedWorkItemIDs: $draggedWorkItemIDs,
              activeDropTarget: $planningDropTarget,
              onDragBegan: beginDragging,
              onDragCompleted: finishDragging,
              onOpen: { selectedTicket = $0 },
              onAddTicket: { onNewTicket(focusedEpic?.id) },
              suggestionBatch: visibleSuggestionBatch
            )
          }
          .padding(.horizontal, 24)
          .padding(.top, topPadding)
          .padding(.bottom, bottomPadding)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .sheet(item: $selectedTicket) { item in
      TicketDetailView(
        item: item,
        dependsOnWorkItemIDs: Set(
          model.dependencies
            .filter { $0.workItemID == item.id }
            .map(\.dependsOnWorkItemID)
        )
      )
    }
    .sheet(item: $selectedEpic) { epic in
      EpicDetailView(epic: epic)
    }
    .onChange(of: Set(planningItems.map(\.id))) { _, availableIDs in
      selectedWorkItemIDs.formIntersection(availableIDs)
    }
    .onChange(of: planningDropTarget) { _, target in
      dropExitResetTask?.cancel()
      guard target == nil, !draggedWorkItemIDs.isEmpty else { return }
      dropExitResetTask = Task {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, planningDropTarget == nil else { return }
        finishDragging()
      }
    }
    .onDisappear {
      dragResetTask?.cancel()
      dropExitResetTask?.cancel()
    }
    .onChange(of: model.backlogFocusEpicID) { _, epicID in
      guard let epicID else { return }
      epicFilter = .epic(epicID)
      model.backlogFocusEpicID = nil
    }
  }

  private func beginDragging(_ ids: Set<UUID>) {
    dragResetTask?.cancel()
    withAnimation(.snappy(duration: 0.2)) {
      draggedWorkItemIDs = ids
    }
    dragResetTask = Task {
      try? await Task.sleep(for: .seconds(30))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        finishDragging()
      }
    }
  }

  private func finishDragging() {
    dragResetTask?.cancel()
    dragResetTask = nil
    dropExitResetTask?.cancel()
    dropExitResetTask = nil
    withAnimation(.snappy(duration: 0.2)) {
      draggedWorkItemIDs.removeAll()
      planningDropTarget = nil
    }
  }

}

private struct EpicFilterBar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selection: BacklogEpicFilter
  let planningItems: [WorkItem]
  let onOpenEpic: (Epic) -> Void

  var body: some View {
    HStack(spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 7) {
          EpicFilterChip(
            title: "All work",
            count: planningItems.count,
            isSelected: selection == .all
          ) {
            selection = .all
          }
          EpicFilterChip(
            title: "No epic",
            count: planningItems.filter { $0.epicID == nil }.count,
            isSelected: selection == .unassigned
          ) {
            selection = .unassigned
          }
          ForEach(model.epics) { epic in
            EpicFilterChip(
              title: epic.title,
              count: planningItems.filter { $0.epicID == epic.id }.count,
              isSelected: selection == .epic(epic.id)
            ) {
              selection = .epic(epic.id)
            }
          }
        }
      }
      if
        case .epic(let epicID) = selection,
        let epic = model.epics.first(where: { $0.id == epicID })
      {
        Divider()
          .frame(height: 22)
        Button {
          onOpenEpic(epic)
        } label: {
          Label("Epic details", systemImage: "sidebar.right")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Open the epic and resume its Business Analyst conversation")
      }
    }
  }
}

private struct EpicFilterChip: View {
  let title: String
  let count: Int
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .fixedSize(horizontal: true, vertical: false)
        Text(count.formatted())
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.primary)
    .background(
      isSelected ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.07),
      in: Capsule()
    )
    .overlay {
      Capsule()
        .stroke(
          isSelected ? Color.secondary.opacity(0.24) : Color.clear,
          lineWidth: 1
        )
    }
    .help(title)
  }
}

private struct PlanningTicketList: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let title: String
  let subtitle: String
  let items: [WorkItem]
  let isCandidateSection: Bool
  let minimumHeight: CGFloat
  @Binding var selectedWorkItemIDs: Set<UUID>
  @Binding var draggedWorkItemIDs: Set<UUID>
  @Binding var activeDropTarget: PlanningDropTarget?
  let onDragBegan: (Set<UUID>) -> Void
  let onDragCompleted: () -> Void
  let onOpen: (WorkItem) -> Void
  let onAddTicket: (() -> Void)?
  let suggestionBatch: TicketSuggestionBatch?

  private var section: PlanningDropSection {
    isCandidateSection ? .candidateSprint : .backlog
  }

  private var isDropTargeted: Bool {
    activeDropTarget?.section == section
  }

  private var itemIDs: Set<UUID> {
    Set(items.map(\.id))
  }

  private var allItemsSelected: Bool {
    !itemIDs.isEmpty && itemIDs.isSubset(of: selectedWorkItemIDs)
  }

  private var selectedItemCount: Int {
    selectedWorkItemIDs.intersection(itemIDs).count
  }

  private var restingBackground: Color {
    return Color.secondary.opacity(colorScheme == .dark ? 0.075 : 0.035)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .center, spacing: 7) {
            Text(title)
              .font(.title3.weight(.semibold))
            Text(items.count.formatted())
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
          }
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let onAddTicket {
          Button(action: onAddTicket) {
            Label("Add ticket", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
        }
      }
      .padding(.horizontal, 2)
      .padding(.bottom, 1)

      Grid(horizontalSpacing: 0, verticalSpacing: 0) {
        PlanningTicketTableHeader(
          itemCount: items.count,
          selectedItemCount: selectedItemCount,
          onToggleSelection: toggleAllItems
        )
          .dropDestination(
            for: String.self,
            action: { values, _ in performDrop(values, at: 0) },
            isTargeted: { targeted in setDropTarget(targeted, index: 0) }
          )

        Divider()
          .gridCellUnsizedAxes(.horizontal)

        if items.isEmpty && suggestionBatch == nil {
          VStack(spacing: 7) {
            Image(systemName: isCandidateSection ? "tray.and.arrow.down" : "text.badge.plus")
              .font(.title2)
              .foregroundStyle(.tertiary)
            Text(isCandidateSection ? "Drag backlog tickets here" : "No backlog tickets")
              .font(.subheadline.weight(.medium))
            Text(
              isCandidateSection
                ? "Dependencies must be added before the work that relies on them."
                : "Add a ticket, or create an epic and let AI plan the outcome."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          }
          .frame(
            maxWidth: .infinity,
            minHeight: 104,
            maxHeight: .infinity,
            alignment: .center
          )
          .gridCellColumns(7)
          .dropDestination(
            for: String.self,
            action: { values, _ in performDrop(values, at: 0) },
            isTargeted: { targeted in setDropTarget(targeted, index: 0) }
          )
        } else {
          ForEach(0...items.count, id: \.self) { index in
            PlanningTicketDropSlot(
              section: section,
              index: index,
              showsRestingDivider: index > 0,
              showsInsertionIndicator: !isNoOpDrop(
                ids: draggedWorkItemIDs,
                at: index
              ),
              activeDropTarget: $activeDropTarget,
              onDrop: { values in performDrop(values, at: index) }
            )
            .gridCellColumns(7)

            if index < items.count {
              let item = items[index]
              let dragSelection = selectedWorkItemIDs.contains(item.id)
                ? selectedWorkItemIDs.intersection(itemIDs)
                : [item.id]
              PlanningTicketRow(
                item: item,
                isCandidate: isCandidateSection,
                isSelected: selectedWorkItemIDs.contains(item.id),
                dragSelection: dragSelection,
                isBeingDragged: draggedWorkItemIDs.contains(item.id),
                onDragBegan: { onDragBegan(dragSelection) },
                onDrop: { values in performDrop(values, at: index + 1) },
                onDropTargeted: { targeted in setDropTarget(targeted, index: index + 1) },
                onToggleSelection: {
                  if selectedWorkItemIDs.contains(item.id) {
                    selectedWorkItemIDs.remove(item.id)
                  } else {
                    selectedWorkItemIDs.insert(item.id)
                  }
                },
                onOpen: { onOpen(item) }
              )
            }
          }

          if let suggestionBatch {
            InlineBacklogSuggestions(batch: suggestionBatch)
              .gridCellColumns(7)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(alignment: .top) {
        Rectangle()
          .fill(.quaternary.opacity(0.18))
          .frame(height: 32)
      }
      .background(isDropTargeted ? Color.accentColor.opacity(0.11) : Color.clear)
      .background(restingBackground)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(
            Color.secondary.opacity(colorScheme == .dark ? 0.45 : 0.28),
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
          )
      }
      .contentShape(Rectangle())
      .dropDestination(
        for: String.self,
        action: { values, _ in performDrop(values, at: items.count) },
        isTargeted: { targeted in setDropTarget(targeted, index: items.count) }
      )
      .animation(.snappy(duration: 0.18), value: isDropTargeted)
      .animation(.snappy(duration: 0.22), value: items.map(\.id))
    }
    .frame(minHeight: minimumHeight, alignment: .top)
  }

  private func toggleAllItems() {
    if allItemsSelected {
      selectedWorkItemIDs.subtract(itemIDs)
    } else {
      selectedWorkItemIDs.formUnion(itemIDs)
    }
  }

  private func performDrop(_ values: [String], at index: Int) -> Bool {
    guard model.canEditCandidateSprint else { return false }
    let ids = Set(
      values.flatMap { payload in
        payload.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
      }
    )
    let movingItems = model.workItems.filter { ids.contains($0.id) }
    guard !movingItems.isEmpty else { return false }
    let safeIndex = min(max(index, 0), items.count)
    if isNoOpDrop(ids: ids, at: safeIndex) {
      onDragCompleted()
      return true
    }
    let targetID = items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
    model.dropPlanningItems(
      movingItems,
      intoCandidateSprint: isCandidateSection,
      before: targetID
    )
    onDragCompleted()
    return true
  }

  private func setDropTarget(_ targeted: Bool, index: Int) {
    let target = PlanningDropTarget(section: section, index: index)
    withAnimation(.snappy(duration: 0.16)) {
      if targeted && !isNoOpDrop(ids: draggedWorkItemIDs, at: index) {
        activeDropTarget = target
      } else if activeDropTarget == target {
        activeDropTarget = nil
      }
    }
  }

  private func isNoOpDrop(ids: Set<UUID>, at index: Int) -> Bool {
    guard !ids.isEmpty, ids.isSubset(of: itemIDs) else { return false }

    let safeIndex = min(max(index, 0), items.count)
    let movingItems = items.filter { ids.contains($0.id) }
    var reorderedItems = items.filter { !ids.contains($0.id) }
    let targetID = items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
    let insertionIndex = targetID.flatMap { targetID in
      reorderedItems.firstIndex { $0.id == targetID }
    } ?? reorderedItems.endIndex
    reorderedItems.insert(contentsOf: movingItems, at: insertionIndex)

    return reorderedItems.map(\.id) == items.map(\.id)
  }
}

private enum PlanningTicketTableLayout {
  static let columnSpacing: CGFloat = 12
  static let selectionWidth: CGFloat = 32
  static let epicWidth: CGFloat = 150
  static let dependenciesWidth: CGFloat = 124
  static let assigneeWidth: CGFloat = 138
  static let readinessWidth: CGFloat = 116
  static let priorityWidth: CGFloat = 72
}

private struct PlanningTicketTableHeader: View {
  let itemCount: Int
  let selectedItemCount: Int
  let onToggleSelection: () -> Void

  private var selectionSymbol: String {
    if itemCount > 0, selectedItemCount == itemCount {
      return "checkmark.square.fill"
    }
    if selectedItemCount > 0 {
      return "minus.square.fill"
    }
    return "square"
  }

  private var selectionHelp: String {
    itemCount > 0 && selectedItemCount == itemCount
      ? "Deselect all tickets"
      : "Select all tickets"
  }

  var body: some View {
    GridRow(alignment: .center) {
      Button(action: onToggleSelection) {
        Image(systemName: selectionSymbol)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(
            selectedItemCount > 0
              ? Color.blue
              : Color(nsColor: .tertiaryLabelColor)
          )
          .frame(width: 18, height: 24)
      }
      .buttonStyle(.plain)
      .disabled(itemCount == 0)
      .help(selectionHelp)
      .frame(
        width: PlanningTicketTableLayout.selectionWidth,
        alignment: .trailing
      )
      Text("Ticket")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)
        .gridColumnAlignment(.leading)
      Text("Epic")
        .frame(
          width: PlanningTicketTableLayout.epicWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)
        .gridColumnAlignment(.leading)
      Text("Dependencies")
        .frame(
          width: PlanningTicketTableLayout.dependenciesWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)
        .gridColumnAlignment(.leading)
      Text("Assignee")
        .frame(
          width: PlanningTicketTableLayout.assigneeWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)
        .gridColumnAlignment(.leading)
      Text("Readiness")
        .frame(
          width: PlanningTicketTableLayout.readinessWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)
        .gridColumnAlignment(.leading)
      Text("Priority")
        .frame(
          width: PlanningTicketTableLayout.priorityWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)
        .gridColumnAlignment(.leading)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .frame(height: 32)
  }
}

private struct PlanningTicketDropSlot: View {
  let section: PlanningDropSection
  let index: Int
  let showsRestingDivider: Bool
  let showsInsertionIndicator: Bool
  @Binding var activeDropTarget: PlanningDropTarget?
  let onDrop: ([String]) -> Bool

  private var target: PlanningDropTarget {
    PlanningDropTarget(section: section, index: index)
  }

  private var isActive: Bool {
    showsInsertionIndicator && activeDropTarget == target
  }

  var body: some View {
    ZStack {
      if isActive {
        HStack(spacing: 7) {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
          Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
          Text("Drop here")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
          Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
        }
        .padding(.horizontal, 14)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
      } else if showsRestingDivider {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 1)
          .padding(.horizontal, 1)
      }
    }
    .frame(height: isActive ? 22 : 1)
    .contentShape(Rectangle())
    .dropDestination(
      for: String.self,
      action: { values, _ in onDrop(values) },
      isTargeted: { targeted in
        withAnimation(.snappy(duration: 0.16)) {
          if targeted && showsInsertionIndicator {
            activeDropTarget = target
          } else if activeDropTarget == target {
            activeDropTarget = nil
          }
        }
      }
    )
    .animation(.snappy(duration: 0.18), value: isActive)
  }
}

private struct PlanningTicketRow: View {
  @EnvironmentObject private var model: AppModel
  let item: WorkItem
  let isCandidate: Bool
  let isSelected: Bool
  let dragSelection: Set<UUID>
  let isBeingDragged: Bool
  let onDragBegan: () -> Void
  let onDrop: ([String]) -> Bool
  let onDropTargeted: (Bool) -> Void
  let onToggleSelection: () -> Void
  let onOpen: () -> Void
  @State private var confirmingArchive = false
  @State private var isHovering = false

  private var prerequisites: [WorkItem] {
    let ids = Set(
      model.dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var dependentsCount: Int {
    model.dependencies.filter { $0.dependsOnWorkItemID == item.id }.count
  }

  private var sprintItem: SprintItem? {
    model.candidateSprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var assignedImplementer: AgentProfile? {
    guard let ownerID = sprintItem?.implementerProfileID ?? item.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var epic: Epic? {
    guard let epicID = item.epicID else { return nil }
    return model.epics.first { $0.id == epicID }
  }

  private var missingReadinessFields: [String] {
    var fields: [String] = []
    if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      fields.append("context")
    }
    if item.acceptanceCriteria.isEmpty {
      fields.append("criteria")
    }
    return fields
  }

  private var readinessLabel: String {
    switch missingReadinessFields {
    case []:
      let count = item.acceptanceCriteria.count
      return "\(count) \(count == 1 ? "criterion" : "criteria")"
    case ["context"]:
      return "No context"
    case ["criteria"]:
      return "No criteria"
    default:
      return "\(missingReadinessFields.count) missing"
    }
  }

  private var archiveMenuTitle: AttributedString {
    var title = AttributedString("Archive ticket…")
    title.foregroundColor = .red
    return title
  }

  var body: some View {
    GridRow(alignment: .center) {
      Button(action: onToggleSelection) {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(
            isSelected ? Color.blue : Color(nsColor: .tertiaryLabelColor)
          )
          .frame(width: 18, height: 24)
      }
      .buttonStyle(.plain)
      .help(isSelected ? "Deselect ticket" : "Select ticket")
      .frame(
        width: PlanningTicketTableLayout.selectionWidth,
        alignment: .trailing
      )

      HStack(spacing: 12) {
        Image(systemName: item.type.symbolName)
          .foregroundStyle(item.type.tint)
          .frame(width: 18)
        Text(item.key)
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 54, alignment: .leading)
        Text(item.title)
          .font(.body.weight(.medium))
          .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
          .lineLimit(1)
        Spacer(minLength: 12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, PlanningTicketTableLayout.columnSpacing)
      .contentShape(Rectangle())

      Group {
        if let epic {
          Label(epic.title, systemImage: "flag.checkered")
            .foregroundStyle(.purple)
            .help(epic.title)
        } else {
          Text("No epic")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.caption.weight(.medium))
      .lineLimit(2)
      .frame(
        width: PlanningTicketTableLayout.epicWidth,
        alignment: .leading
      )
      .padding(.leading, PlanningTicketTableLayout.columnSpacing)

      Group {
        if !prerequisites.isEmpty {
          Label(
            prerequisites.map(\.key).joined(separator: ", "),
            systemImage: "arrow.turn.down.right"
          )
          .foregroundStyle(.indigo)
          .help("Depends on \(prerequisites.map(\.key).joined(separator: ", "))")
        } else if dependentsCount > 0 {
          Label("Blocks \(dependentsCount)", systemImage: "link")
            .foregroundStyle(.secondary)
        } else {
          Text("None")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.caption)
      .lineLimit(1)
      .frame(
        width: PlanningTicketTableLayout.dependenciesWidth,
        alignment: .leading
      )
      .padding(.leading, PlanningTicketTableLayout.columnSpacing)

      PlanningAssignmentSummary(item: item, implementer: assignedImplementer)
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)

      Label(
        readinessLabel,
        systemImage: missingReadinessFields.isEmpty
          ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .font(.caption.weight(.medium))
      .foregroundStyle(missingReadinessFields.isEmpty ? .green : .orange)
      .lineLimit(1)
      .frame(
        width: PlanningTicketTableLayout.readinessWidth,
        alignment: .leading
      )
      .padding(.leading, PlanningTicketTableLayout.columnSpacing)
      .help(
        missingReadinessFields.isEmpty
          ? "The ticket has context and acceptance criteria."
          : "Add \(missingReadinessFields.joined(separator: " and ")) before sprint execution."
      )

      Text(item.priority.title)
        .font(.caption.weight(.medium))
        .foregroundStyle(item.priority.tint)
        .frame(
          width: PlanningTicketTableLayout.priorityWidth,
          alignment: .leading
        )
        .padding(.leading, PlanningTicketTableLayout.columnSpacing)
    }
    .frame(minHeight: 48)
    .background {
      Rectangle()
        .fill(rowBackground)
    }
    .opacity(isBeingDragged ? 0.28 : 1)
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .onDrag {
      onDragBegan()
      let payload = dragSelection.map(\.uuidString).sorted().joined(separator: ",")
      return NSItemProvider(object: payload as NSString)
    } preview: {
      PlanningTicketDragPreview(item: item, count: dragSelection.count)
    }
    .dropDestination(
      for: String.self,
      action: { values, _ in onDrop(values) },
      isTargeted: onDropTargeted
    )
    .animation(.snappy(duration: 0.18), value: isBeingDragged)
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .help(
      isSelected
        ? "Drag to move all selected tickets between Backlog and Next sprint"
        : "Open the ticket, select it to drag with other tickets, or drag it to change sprint scope"
    )
    .contextMenu {
      Button(action: onOpen) {
        Label("Open ticket", systemImage: "doc.text.magnifyingglass")
      }
      Button(action: onToggleSelection) {
        Label(
          isSelected ? "Deselect ticket" : "Select ticket",
          systemImage: isSelected ? "checkmark.square.fill" : "square"
        )
      }
      if isCandidate {
        Button {
          model.removeFromCandidateSprint(item)
        } label: {
          Label("Return to backlog", systemImage: "arrow.uturn.backward")
        }
      } else {
        Button {
          model.addToCandidateSprint(item)
        } label: {
          Label("Add to next sprint", systemImage: "calendar.badge.plus")
        }
        .disabled(!model.canEditCandidateSprint)
      }
      Divider()
      Button {
        model.moveWorkItem(item, to: .top)
      } label: {
        Label("Move to top", systemImage: "arrow.up.to.line")
      }
      Button {
        model.moveWorkItem(item, to: .bottom)
      } label: {
        Label("Move to bottom", systemImage: "arrow.down.to.line")
      }
      Divider()
      Button(role: .destructive) {
        confirmingArchive = true
      } label: {
        Label {
          Text(archiveMenuTitle)
        } icon: {
          Image(systemName: "archivebox")
            .foregroundStyle(.red)
        }
      }
      .tint(.red)
    }
    .confirmationDialog(
      "Archive \(item.key)?",
      isPresented: $confirmingArchive,
      titleVisibility: .visible
    ) {
      Button("Archive ticket", role: .destructive) {
        model.archiveWorkItem(item)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The ticket leaves the backlog but its history remains in the local workspace.")
    }
  }

  private var rowBackground: Color {
    if isBeingDragged {
      return Color.accentColor.opacity(0.045)
    }
    if isSelected {
      return Color.accentColor.opacity(0.1)
    }
    if isHovering {
      return Color.accentColor.opacity(0.055)
    }
    return .clear
  }
}

private struct PlanningTicketDragPreview: View {
  let item: WorkItem
  let count: Int

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.type.symbolName)
        .foregroundStyle(item.type.tint)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(count == 1 ? item.key : "\(count) tickets")
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Text(count == 1 ? item.title : "Move selected work together")
          .font(.callout.weight(.medium))
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: 330, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
  }
}

private struct PlanningAssignmentSummary: View {
  @EnvironmentObject private var model: AppModel
  let item: WorkItem
  let implementer: AgentProfile?

  var body: some View {
    Menu {
      ForEach(model.profiles.filter(\.role.canOwnDelivery)) { candidate in
        Button {
          Task {
            _ = await model.assignTicketOwner(
              workItemID: item.id,
              to: candidate.id
            )
          }
        } label: {
          HStack {
            Label(candidate.name, systemImage: candidate.role.symbolName)
            if candidate.id == implementer?.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(
          systemName: implementer?.role.symbolName
            ?? "person.crop.circle.badge.questionmark"
        )
        .foregroundStyle(implementer?.role.tint ?? Color.secondary)
        Text(implementer?.name ?? "Unassigned")
          .font(.caption.weight(.semibold))
          .foregroundStyle(implementer?.role.tint ?? Color.secondary)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .menuStyle(.borderlessButton)
    .frame(width: 150, alignment: .leading)
    .help("Choose the ticket's delivery owner")
  }
}

private struct InlineBacklogSuggestions: View {
  @EnvironmentObject private var model: AppModel
  let batch: TicketSuggestionBatch
  @State private var confirmingAcceptAll = false
  @State private var confirmingRejectAll = false
  @State private var selectedSuggestion: TicketSuggestion?

  var body: some View {
    Group {
      switch batch.session.status {
      case .generating:
        generatingRows
      case .failed:
        failedRow
      case .ready:
        readyRows
      case .cancelled:
        EmptyView()
      }
    }
    .confirmationDialog(
      "Accept all remaining AI suggestions?",
      isPresented: $confirmingAcceptAll,
      titleVisibility: .visible
    ) {
      Button(
        "Accept \(orderedSuggestions.count) \(orderedSuggestions.count == 1 ? "suggestion" : "suggestions")"
      ) {
        model.decideTicketSuggestionGroup(orderedSuggestions, accept: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("They will become normal backlog tickets and retain their dependency relationships.")
    }
    .confirmationDialog(
      "Reject all remaining AI suggestions?",
      isPresented: $confirmingRejectAll,
      titleVisibility: .visible
    ) {
      Button(
        "Reject \(orderedSuggestions.count) \(orderedSuggestions.count == 1 ? "suggestion" : "suggestions")",
        role: .destructive
      ) {
        model.decideTicketSuggestionGroup(orderedSuggestions, accept: false)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The decisions remain useful context for the next backlog analysis.")
    }
    .sheet(item: $selectedSuggestion) { suggestion in
      TicketSuggestionDetailView(
        suggestion: suggestion,
        batch: batch,
        onClose: { selectedSuggestion = nil }
      )
    }
  }

  private var generatingRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Business Analyst is generating and ordering ticket suggestions…")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.purple)
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)

      ForEach(0..<3, id: \.self) { index in
        Divider()
        HStack(spacing: 12) {
          Image(systemName: "wand.and.stars")
            .foregroundStyle(.purple.opacity(0.55))
            .frame(width: 24)
          VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
              .fill(.purple.opacity(0.14))
              .frame(width: index == 1 ? 250 : 340, height: 10)
            RoundedRectangle(cornerRadius: 3)
              .fill(.quaternary)
              .frame(width: index == 2 ? 180 : 270, height: 8)
          }
          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
      Divider()
    }
    .background(.purple.opacity(0.045))
  }

  private var failedRow: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 5) {
        Text("AI ticket suggestions need another try")
          .font(.subheadline.weight(.semibold))
        Text(batch.session.errorMessage ?? "The Business Analyst could not complete the proposal.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Dismiss") {
        model.dismissFailedTicketSuggestions()
      }
      .buttonStyle(.bordered)
      Button("Try again") {
        model.retryCurrentEpicPlan()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!model.canPlanEpic)
    }
    .padding(14)
    .background(.orange.opacity(0.055))
  }

  private var readyRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Label("Epic plan", systemImage: "wand.and.stars")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.purple)
        Text(
          "\(orderedSuggestions.count) \(orderedSuggestions.count == 1 ? "suggestion" : "suggestions") to review"
        )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        if orderedSuggestions.count > 1 {
          Button("Reject all") { confirmingRejectAll = true }
            .buttonStyle(.bordered)
          Button("Accept all") { confirmingAcceptAll = true }
            .buttonStyle(.borderedProminent)
        }
      }
      .controlSize(.small)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)

      ForEach(dependencyGroups) { group in
        Divider()
        InlineSuggestionDependencyGroup(
          group: group,
          batch: batch,
          onOpen: { selectedSuggestion = $0 }
        )
      }
    }
    .background(.purple.opacity(0.04))
  }

  private var orderedSuggestions: [TicketSuggestion] {
    batch.suggestions.filter { $0.status == .proposed }
      .sorted { lhs, rhs in
        let leftDepth = dependencyDepth(for: lhs, visiting: [])
        let rightDepth = dependencyDepth(for: rhs, visiting: [])
        return leftDepth == rightDepth ? lhs.position < rhs.position : leftDepth < rightDepth
      }
  }

  private var dependencyGroups: [InlineSuggestionGroup] {
    let proposals = orderedSuggestions
    let proposedIDs = Set(proposals.map(\.id))
    var adjacency: [UUID: Set<UUID>] = [:]
    for suggestion in proposals {
      for dependencyID in suggestion.dependencyIDs where proposedIDs.contains(dependencyID) {
        adjacency[suggestion.id, default: []].insert(dependencyID)
        adjacency[dependencyID, default: []].insert(suggestion.id)
      }
    }

    var unvisited = proposedIDs
    var groups: [InlineSuggestionGroup] = []
    for suggestion in proposals where unvisited.contains(suggestion.id) {
      var pending = [suggestion.id]
      var component: Set<UUID> = []
      while let id = pending.popLast() {
        guard unvisited.remove(id) != nil else { continue }
        component.insert(id)
        pending.append(contentsOf: adjacency[id, default: []])
      }
      let members = proposals.filter { component.contains($0.id) }
      if let first = members.first {
        groups.append(InlineSuggestionGroup(id: first.id, suggestions: members))
      }
    }
    return groups
  }

  private func dependencyDepth(
    for suggestion: TicketSuggestion,
    visiting: Set<UUID>
  ) -> Int {
    guard !visiting.contains(suggestion.id) else { return 0 }
    let dependencies = suggestion.dependencyIDs.compactMap { dependencyID in
      batch.suggestions.first { $0.id == dependencyID && $0.status == .proposed }
    }
    guard !dependencies.isEmpty else { return 0 }
    var next = visiting
    next.insert(suggestion.id)
    return 1 + (dependencies.map { dependencyDepth(for: $0, visiting: next) }.max() ?? 0)
  }
}

private struct InlineSuggestionGroup: Identifiable {
  let id: UUID
  let suggestions: [TicketSuggestion]
}

private struct InlineSuggestionDependencyGroup: View {
  @EnvironmentObject private var model: AppModel
  let group: InlineSuggestionGroup
  let batch: TicketSuggestionBatch
  let onOpen: (TicketSuggestion) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if group.suggestions.count > 1 {
        HStack(spacing: 8) {
          Label(
            "Dependency path · \(group.suggestions.count) tickets",
            systemImage: "point.3.connected.trianglepath.dotted"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.purple)
          Spacer()
          Button("Reject group") {
            model.decideTicketSuggestionGroup(group.suggestions, accept: false)
          }
          .buttonStyle(.bordered)
          Button("Accept group") {
            model.decideTicketSuggestionGroup(group.suggestions, accept: true)
          }
          .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.purple.opacity(0.045))
      }

      ForEach(group.suggestions) { suggestion in
        InlineTicketSuggestionRow(
          suggestion: suggestion,
          dependencies: relatedSuggestions(for: suggestion.dependencyIDs),
          existingDependencies: suggestion.existingDependencyWorkItemIDs.compactMap { id in
            model.workItems.first { $0.id == id }
          },
          dependents: batch.suggestions.filter { $0.dependencyIDs.contains(suggestion.id) },
          onOpen: { onOpen(suggestion) }
        )
      }
    }
  }

  private func relatedSuggestions(for ids: [UUID]) -> [TicketSuggestion] {
    ids.compactMap { id in batch.suggestions.first { $0.id == id } }
  }
}

private struct InlineTicketSuggestionRow: View {
  @EnvironmentObject private var model: AppModel
  let suggestion: TicketSuggestion
  let dependencies: [TicketSuggestion]
  let existingDependencies: [WorkItem]
  let dependents: [TicketSuggestion]
  let onOpen: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "wand.and.stars")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.purple)
        .frame(width: 26)

      Text(suggestion.reference)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(.purple)
        .frame(width: 36, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(suggestion.title)
            .font(.body.weight(.semibold))
            .foregroundStyle(isHovering ? Color.purple : Color.primary)
            .lineLimit(1)
          Label(suggestion.type.title, systemImage: suggestion.type.symbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(suggestion.type.tint)
        }
        HStack(spacing: 9) {
          if !blockerKeys.isEmpty {
            Label(
              "Blocked by \(blockerKeys.joined(separator: ", "))",
              systemImage: "arrow.turn.up.left"
            )
            .foregroundStyle(.indigo)
          } else if !dependents.isEmpty {
            Label(
              "Blocks \(dependents.map(\.reference).joined(separator: ", "))",
              systemImage: "link"
            )
            .foregroundStyle(.purple)
          } else {
            Text(suggestion.rationale)
              .lineLimit(1)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 10)

      Label(suggestion.suggestedRole.title, systemImage: suggestion.suggestedRole.symbolName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(suggestion.suggestedRole.tint)
        .lineLimit(1)

      Text(suggestion.priority.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(suggestion.priority.tint)
        .frame(width: 52, alignment: .trailing)

      HStack(spacing: 6) {
        Button("Reject") {
          model.decideTicketSuggestion(suggestion, accept: false)
        }
        .buttonStyle(.bordered)
        Button("Accept") {
          model.decideTicketSuggestion(suggestion, accept: true)
        }
        .buttonStyle(.borderedProminent)
      }
      .controlSize(.small)
      .disabled(model.isDecidingSuggestions)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.purple.opacity(isHovering ? 0.09 : 0.025))
    .overlay(alignment: .bottom) {
      Divider()
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .help("Open suggested ticket details")
  }

  private var blockerKeys: [String] {
    dependencies.map(\.reference) + existingDependencies.map(\.key)
  }
}

private struct TicketSuggestionDetailView: View {
  @EnvironmentObject private var model: AppModel
  let suggestion: TicketSuggestion
  let batch: TicketSuggestionBatch
  let onClose: () -> Void

  private var proposedDependencies: [TicketSuggestion] {
    suggestion.dependencyIDs.compactMap { dependencyID in
      batch.suggestions.first { $0.id == dependencyID }
    }
  }

  private var existingDependencies: [WorkItem] {
    suggestion.existingDependencyWorkItemIDs.compactMap { dependencyID in
      model.workItems.first { $0.id == dependencyID }
    }
  }

  private var dependents: [TicketSuggestion] {
    batch.suggestions.filter { $0.dependencyIDs.contains(suggestion.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "wand.and.stars")
          .foregroundStyle(.purple)
        Text(suggestion.reference)
          .font(.callout.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Text("Suggested ticket")
          .font(.title2.bold())
        Spacer()
        Button("Close", action: onClose)
      }
      .padding(.horizontal, 22)
      .frame(height: 64)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 9) {
            Text(suggestion.title)
              .font(.title2.weight(.semibold))
              .textSelection(.enabled)
            Text(suggestion.body)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          HStack(spacing: 10) {
            SuggestionDetailMetadata(
              title: "Type",
              value: suggestion.type.title,
              symbol: suggestion.type.symbolName,
              tint: suggestion.type.tint
            )
            SuggestionDetailMetadata(
              title: "Priority",
              value: suggestion.priority.title,
              symbol: "chevron.up",
              tint: suggestion.priority.tint
            )
            SuggestionDetailMetadata(
              title: "Suggested owner",
              value: suggestion.suggestedRole.title,
              symbol: suggestion.suggestedRole.symbolName,
              tint: suggestion.suggestedRole.tint
            )
          }

          VStack(alignment: .leading, spacing: 10) {
            Text("Acceptance criteria")
              .font(.headline)
            ForEach(suggestion.acceptanceCriteria, id: \.self) { criterion in
              HStack(alignment: .top, spacing: 9) {
                Text("•")
                  .foregroundStyle(.secondary)
                  .frame(width: 16, alignment: .center)
                Text(criterion)
                  .textSelection(.enabled)
              }
            }
          }
          .padding(15)
          .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))

          if !proposedDependencies.isEmpty
            || !existingDependencies.isEmpty
            || !dependents.isEmpty
          {
            VStack(alignment: .leading, spacing: 11) {
              Text("Relationships")
                .font(.headline)
              if !proposedDependencies.isEmpty || !existingDependencies.isEmpty {
                SuggestionDetailRelationship(
                  title: "Blocked by",
                  values: proposedDependencies.map {
                    "\($0.reference) · \($0.title)"
                  } + existingDependencies.map {
                    "\($0.key) · \($0.title)"
                  },
                  symbol: "arrow.turn.up.left",
                  tint: .indigo
                )
              }
              if !dependents.isEmpty {
                SuggestionDetailRelationship(
                  title: "Blocks",
                  values: dependents.map { "\($0.reference) · \($0.title)" },
                  symbol: "link",
                  tint: .purple
                )
              }
            }
            .padding(15)
            .background(.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Why this work")
              .font(.headline)
            Text(suggestion.rationale)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        .padding(22)
      }

      Divider()

      HStack {
        Text("Nothing enters the backlog until you accept it.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Reject", role: .destructive) {
          model.decideTicketSuggestion(suggestion, accept: false)
          onClose()
        }
        .disabled(model.isDecidingSuggestions)
        Button("Accept") {
          model.decideTicketSuggestion(suggestion, accept: true)
          onClose()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isDecidingSuggestions)
      }
      .padding(.horizontal, 22)
      .frame(height: 64)
    }
    .frame(width: 760, height: 680)
  }
}

private struct SuggestionDetailMetadata: View {
  let title: String
  let value: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
      }
    }
    .padding(11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct SuggestionDetailRelationship: View {
  let title: String
  let values: [String]
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
        ForEach(values, id: \.self) { value in
          Text(value)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

private struct BacklogSuggestionStack: View {
  @EnvironmentObject private var model: AppModel
  let batch: TicketSuggestionBatch
  @State private var confirmingAcceptAll = false
  @State private var confirmingRejectAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Label("Suggested work", systemImage: "wand.and.stars")
            .font(.headline)
          Text("One Business Analyst proposal · roles are planning hints; team members are assigned in Sprint Planning")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if batch.session.status == .generating {
          ProgressView()
            .controlSize(.small)
        } else if batch.session.status == .ready {
          HStack(spacing: 7) {
            Text(
              "\(proposedCount) \(proposedCount == 1 ? "suggestion" : "suggestions") to review"
            )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            if proposedCount > 1 {
              Button("Reject all") { confirmingRejectAll = true }
                .buttonStyle(.bordered)
                .disabled(model.isDecidingSuggestions)
              Button("Accept all") { confirmingAcceptAll = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDecidingSuggestions)
            }
          }
          .controlSize(.small)
        }
      }

      switch batch.session.status {
      case .generating:
        BusinessAnalystSuggestionProgress()

      case .failed:
        VStack(alignment: .leading, spacing: 10) {
          Label("The Business Analyst could not finish", systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)
          Text(batch.session.errorMessage ?? "The proposal did not complete.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Try again") { model.retryCurrentEpicPlan() }
            .buttonStyle(.bordered)
            .disabled(!model.canPlanEpic || batch.session.epicID == nil)
        }
        .padding(12)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

      case .ready:
        if orderedSuggestions.isEmpty {
          Label(reviewedSummary, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.vertical, 4)
        } else {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(orderedSuggestions) { suggestion in
              TicketSuggestionCard(
                suggestion: suggestion,
                dependencies: dependencies(for: suggestion),
                dependents: dependents(for: suggestion)
              )
            }
          }
        }

      case .cancelled:
        Text("This proposal was cancelled.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(
          .purple.opacity(0.38),
          style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
        )
    }
    .confirmationDialog(
      "Accept all remaining suggestions?",
      isPresented: $confirmingAcceptAll,
      titleVisibility: .visible
    ) {
      Button(
        "Accept \(proposedCount) \(proposedCount == 1 ? "suggestion" : "suggestions")"
      ) {
        model.decideAllTicketSuggestions(accept: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("They will be added to the backlog with their dependency relationships. This does not add them to a sprint.")
    }
    .confirmationDialog(
      "Reject all remaining suggestions?",
      isPresented: $confirmingRejectAll,
      titleVisibility: .visible
    ) {
      Button(
        "Reject \(proposedCount) \(proposedCount == 1 ? "suggestion" : "suggestions")",
        role: .destructive
      ) {
        model.decideAllTicketSuggestions(accept: false)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The decisions will be retained as feedback for future backlog analysis.")
    }
  }

  private var proposedCount: Int {
    batch.suggestions.filter { $0.status == .proposed }.count
  }

  private var reviewedSummary: String {
    let accepted = batch.suggestions.filter { $0.status == .accepted }.count
    let rejected = batch.suggestions.filter { $0.status == .rejected }.count
    return "Proposal reviewed · \(accepted) added · \(rejected) rejected"
  }

  private var orderedSuggestions: [TicketSuggestion] {
    batch.suggestions.filter { $0.status == .proposed }
      .sorted { lhs, rhs in
        let lhsDepth = dependencyDepth(for: lhs, visiting: [])
        let rhsDepth = dependencyDepth(for: rhs, visiting: [])
        if lhsDepth == rhsDepth {
          return lhs.position < rhs.position
        }
        return lhsDepth < rhsDepth
      }
  }

  private func dependencies(for suggestion: TicketSuggestion) -> [TicketSuggestion] {
    suggestion.dependencyIDs.compactMap { dependencyID in
      batch.suggestions.first { $0.id == dependencyID }
    }
  }

  private func dependents(for suggestion: TicketSuggestion) -> [TicketSuggestion] {
    batch.suggestions.filter { $0.dependencyIDs.contains(suggestion.id) }
  }

  private func dependencyDepth(
    for suggestion: TicketSuggestion,
    visiting: Set<UUID>
  ) -> Int {
    guard !visiting.contains(suggestion.id) else { return 0 }
    let directDependencies = dependencies(for: suggestion)
    guard !directDependencies.isEmpty else { return 0 }
    var nextVisiting = visiting
    nextVisiting.insert(suggestion.id)
    return 1 + (directDependencies.map {
      dependencyDepth(for: $0, visiting: nextVisiting)
    }.max() ?? 0)
  }
}

private struct BusinessAnalystSuggestionProgress: View {
  private let phases = [
    ("Understanding the product outcome", "target"),
    ("Mapping research, design, and delivery work", "square.3.layers.3d"),
    ("Finding dependencies and parallel paths", "point.3.connected.trianglepath.dotted"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
        HStack(spacing: 9) {
          Image(systemName: phase.1)
            .foregroundStyle(.purple)
            .frame(width: 18)
          Text(phase.0)
            .font(.caption)
          Spacer()
          if index == 0 {
            ProgressView()
              .controlSize(.mini)
          }
        }
      }
    }
    .padding(12)
    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct TicketSuggestionCard: View {
  @EnvironmentObject private var model: AppModel
  let suggestion: TicketSuggestion
  let dependencies: [TicketSuggestion]
  let dependents: [TicketSuggestion]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(suggestion.reference)
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Label(suggestion.type.title, systemImage: suggestion.type.symbolName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(suggestion.type.tint)
        Label(suggestion.priority.title, systemImage: "flag.fill")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(suggestion.priority.tint)
        Spacer()
        Label(suggestion.suggestedRole.title, systemImage: suggestion.suggestedRole.symbolName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(suggestion.suggestedRole.tint)
      }

      Text(suggestion.title)
        .font(.headline)
        .lineLimit(2)
      Text(suggestion.body)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      if !dependencies.isEmpty || !dependents.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          if !activeDependencies.isEmpty {
            SuggestionRelationshipRow(
              title: "Blocked by",
              references: activeDependencies.map(\.reference),
              symbol: "exclamationmark.octagon",
              tint: .indigo
            )
          }
          if !rejectedDependencies.isEmpty {
            SuggestionRelationshipRow(
              title: "Rejected blocker",
              references: rejectedDependencies.map(\.reference),
              symbol: "exclamationmark.triangle",
              tint: .orange
            )
          }
          if !dependents.isEmpty {
            SuggestionRelationshipRow(
              title: "Blocks",
              references: dependents.map(\.reference),
              symbol: "arrow.right",
              tint: Color(nsColor: .secondaryLabelColor)
            )
          }
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Why this work")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(suggestion.rationale)
          .font(.caption)
          .lineLimit(3)
      }

      Spacer(minLength: 0)
      Divider()
      switch suggestion.status {
      case .proposed:
        HStack(spacing: 8) {
          Spacer()
          Button("Reject") { model.decideTicketSuggestion(suggestion, accept: false) }
            .buttonStyle(.bordered)
            .disabled(model.isDecidingSuggestions)
          Button("Accept") { model.decideTicketSuggestion(suggestion, accept: true) }
            .buttonStyle(.borderedProminent)
            .disabled(model.isDecidingSuggestions)
        }
      case .accepted:
        Label("Added to backlog", systemImage: "list.bullet.clipboard")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.blue)
      case .rejected:
        Label("Rejected", systemImage: "xmark.circle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(suggestion.suggestedRole.tint.opacity(0.16))
    }
    .opacity(suggestion.status == .rejected ? 0.58 : 1)
  }

  private var rejectedDependencies: [TicketSuggestion] {
    dependencies.filter { $0.status == .rejected }
  }

  private var activeDependencies: [TicketSuggestion] {
    dependencies.filter { $0.status != .rejected }
  }
}

private struct SuggestionRelationshipRow: View {
  let title: String
  let references: [String]
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 7) {
      Label(title, systemImage: symbol)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
      ForEach(references, id: \.self) { reference in
        Text(reference)
          .font(.caption2.monospaced().weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(tint.opacity(0.1), in: Capsule())
      }
    }
  }
}

private struct PlanningHorizon: View {
  let plan: SprintPlan?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Planning horizon")
        .font(.headline)
      PlanningSlot(
        title: "Candidate sprint",
        detail: plan?.sprint.state == .draft
          ? "\(plan?.items.count ?? 0) tickets under review" : "Drop ready work here"
      )
      PlanningSlot(title: "Next", detail: "Proposed scope")
      PlanningSlot(title: "Later", detail: "Not committed")
      Text("Drag-and-drop planning arrives with interactive refinement.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(width: 248)
    .frame(minHeight: 520, alignment: .top)
    .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
  }
}

private struct PlanningSlot: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(.separator.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4]))
    }
  }
}

private struct SprintBoardView: View {
  @EnvironmentObject private var model: AppModel
  let onShowBacklog: () -> Void
  let onEditPlan: () -> Void
  let onShowRetrospective: () -> Void
  let onShowReports: () -> Void
  @State private var selectedTicket: WorkItem?
  @State private var selectedSprintID: UUID?
  @Namespace private var ticketMotionNamespace

  private static let selectedSprintDefaultsPrefix = "sprintBoardSelection"

  private let lanes = [
    SprintLane(title: "Ready to Pick", states: [.queued]),
    SprintLane(title: "In Progress", states: [.running]),
    SprintLane(title: "In Review", states: [.integrating, .verifying, .readyToRelease]),
    SprintLane(title: "Ready for Demo", states: [.acceptance]),
    SprintLane(title: "Done", states: [.released]),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 9) {
            Text("Sprint Board")
              .font(.largeTitle.bold())
            if let plan = selectedPlan {
              Text(sprintPhaseTitle(for: plan))
                .font(.caption2.weight(.bold))
                .foregroundStyle(sprintPhaseTint(for: plan))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
              .background(sprintPhaseTint(for: plan).opacity(0.1), in: Capsule())
            }
          }
          Text(selectedPlan?.sprint.goal ?? "Delivery begins after sprint planning.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if availablePlans.count > 1 {
          Picker("Sprint", selection: selectedSprintBinding) {
            ForEach(availablePlans, id: \.sprint.id) { plan in
              Text(
                "Sprint \(plan.sprint.number) · \(sprintSelectorTitle(for: plan))"
              )
              .tag(plan.sprint.id)
            }
          }
          .labelsHidden()
          .frame(width: 190)
        }
        if availablePlans.count > 1, selectedPlan != nil {
          Divider()
            .frame(height: 22)
            .padding(.horizontal, 2)
        }
        if let plan = selectedPlan, plan.sprint.state == .completed {
          Button("View report", action: onShowReports)
          Button(
            plan.sprint.retrospectiveConcludedAt == nil
              ? "Continue to retrospective"
              : "View retrospective",
            action: onShowRetrospective
          )
          .buttonStyle(.borderedProminent)
        }
        if let plan = selectedPlan, plan.sprint.state == .active {
          SprintTeamActivity(plan: plan)
        }
        if let draftPlan = selectedDraftPlan {
          if model.sprintReadinessIssues.isEmpty {
            Button("Review plan", action: onEditPlan)
              .buttonStyle(.bordered)
              .help("Review the sprint plan")
          } else {
            Button(action: onEditPlan) {
              Label(
                "Review plan · \(model.sprintReadinessIssues.count) \(model.sprintReadinessIssues.count == 1 ? "issue" : "issues")",
                systemImage: "exclamationmark.triangle.fill"
              )
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .help(model.sprintReadinessIssues.map(\.message).joined(separator: "\n"))
          }
          Button("Start sprint") {
            Task {
              _ = await model.startSprint()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            !draftPlan.items.allSatisfy { $0.estimatedTokens > 0 }
              || !model.sprintReadinessIssues.isEmpty
          )
        }
      }
      .padding(24)

      Divider()

      if let plan = selectedPlan {
        VStack(spacing: 0) {
          let itemIDs = Set(plan.items.map(\.workItemID))
          GeometryReader { proxy in
            let horizontalPadding: CGFloat = 40
            let interColumnSpacing: CGFloat = 10
            let availableForColumns =
              proxy.size.width - horizontalPadding
                - (interColumnSpacing * CGFloat(max(0, lanes.count - 1)))
            let columnWidth = min(
              270,
              max(244, availableForColumns / CGFloat(max(1, lanes.count)))
            )

            ScrollView(.horizontal) {
              HStack(alignment: .top, spacing: interColumnSpacing) {
                ForEach(lanes) { lane in
                  SprintBoardColumn(
                    title: lane.title,
                    items: boardItems(
                      for: lane,
                      plan: plan,
                      itemIDs: itemIDs
                    ),
                    columnWidth: columnWidth,
                    motionNamespace: ticketMotionNamespace,
                    onOpen: { selectedTicket = $0 }
                  )
                }
              }
              .padding(20)
              .frame(maxHeight: .infinity, alignment: .top)
              .animation(
                .spring(response: 0.42, dampingFraction: 0.86),
                value: boardPositionSignature(itemIDs: itemIDs)
              )
            }
            .frame(maxHeight: .infinity)
          }
          .background(Color(nsColor: .windowBackgroundColor))
        }
      } else {
        ContentUnavailableView {
          Label("No active sprint", systemImage: "figure.run")
        } description: {
          Text("Refine the backlog, review tickets in Sprint Planning, then start the sprint.")
        } actions: {
          Button("Open backlog", action: onShowBacklog)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      selectPreferredPlanIfNeeded()
    }
    .onChange(of: availablePlanSignature) { _, _ in
      selectPreferredPlanIfNeeded()
    }
    .sheet(item: $selectedTicket) { item in
      SprintTicketDetailView(item: item)
    }
  }

  private var availablePlans: [SprintPlan] {
    var plans = model.sprintHistory
    if let current = model.sprintPlan,
      !plans.contains(where: { $0.sprint.id == current.sprint.id })
    {
      plans.append(current)
    }
    return plans.sorted { $0.sprint.number > $1.sprint.number }
  }

  private var availablePlanSignature: [String] {
    availablePlans.map {
      "\($0.sprint.id.uuidString):\($0.sprint.state.rawValue):\($0.sprint.retrospectiveConcludedAt?.timeIntervalSince1970 ?? 0)"
    }
  }

  private var selectedPlan: SprintPlan? {
    let id = selectedSprintID ?? preferredPlan?.sprint.id
    return availablePlans.first { $0.sprint.id == id }
  }

  private var selectedDraftPlan: SprintPlan? {
    guard let plan = selectedPlan, plan.sprint.state == .draft else { return nil }
    return plan
  }

  private var preferredPlan: SprintPlan? {
    availablePlans.first(where: { $0.sprint.state == .active })
      ?? availablePlans.first(where: {
        $0.sprint.state == .completed
          && $0.sprint.retrospectiveConcludedAt == nil
      })
      ?? availablePlans.first(where: { $0.sprint.state == .draft })
      ?? availablePlans.first
  }

  private var selectedSprintBinding: Binding<UUID> {
    Binding(
      get: { selectedSprintID ?? preferredPlan?.sprint.id ?? UUID() },
      set: { selectSprint($0) }
    )
  }

  private func selectPreferredPlanIfNeeded() {
    if let selectedSprintID,
      availablePlans.contains(where: { $0.sprint.id == selectedSprintID })
    {
      return
    }
    if let restoredSprintID,
      availablePlans.contains(where: { $0.sprint.id == restoredSprintID })
    {
      selectedSprintID = restoredSprintID
      return
    }
    selectSprint(preferredPlan?.sprint.id)
  }

  private var restoredSprintID: UUID? {
    guard
      let productID = model.selectedProductID,
      let rawValue = UserDefaults.standard.string(
        forKey: selectedSprintDefaultsKey(for: productID)
      )
    else { return nil }
    return UUID(uuidString: rawValue)
  }

  private func selectSprint(_ sprintID: UUID?) {
    selectedSprintID = sprintID
    guard let productID = model.selectedProductID else { return }
    let key = selectedSprintDefaultsKey(for: productID)
    if let sprintID {
      UserDefaults.standard.set(sprintID.uuidString, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  private func selectedSprintDefaultsKey(for productID: UUID) -> String {
    "\(Self.selectedSprintDefaultsPrefix).\(productID.uuidString)"
  }

  private func boardItems(
    for lane: SprintLane,
    plan: SprintPlan,
    itemIDs: Set<UUID>
  ) -> [WorkItem] {
    if plan.sprint.state == .draft {
      return lane.states == [.queued]
        ? model.workItems.filter { itemIDs.contains($0.id) }
        : []
    }
    return model.workItems.filter {
      itemIDs.contains($0.id) && lane.states.contains($0.state)
    }
  }

  private func sprintSelectorTitle(for plan: SprintPlan) -> String {
    switch plan.sprint.state {
    case .draft: "Planning"
    case .active: "Active"
    case .completed:
      plan.sprint.retrospectiveConcludedAt == nil ? "Review due" : "Completed"
    case .cancelled: "Cancelled"
    }
  }

  private func sprintPhaseTitle(for plan: SprintPlan) -> String {
    switch plan.sprint.state {
    case .draft:
      return isReadyToStart(plan) ? "READY" : "PLANNING"
    case .active:
      return "ACTIVE"
    case .completed:
      return "COMPLETED"
    case .cancelled:
      return "CANCELLED"
    }
  }

  private func sprintPhaseTint(for plan: SprintPlan) -> Color {
    switch plan.sprint.state {
    case .draft:
      isReadyToStart(plan) ? .green : .orange
    case .active:
      .blue
    case .completed:
      .green
    case .cancelled:
      .red
    }
  }

  private func isReadyToStart(_ plan: SprintPlan) -> Bool {
    !plan.items.isEmpty
      && plan.items.allSatisfy { $0.estimatedTokens > 0 }
      && model.sprintReadinessIssues.isEmpty
  }

  private func boardPositionSignature(itemIDs: Set<UUID>) -> [String] {
    model.workItems
      .filter { itemIDs.contains($0.id) }
      .sorted { $0.rank < $1.rank }
      .map { "\($0.id.uuidString):\($0.state.rawValue)" }
  }
}

private struct SprintDraftOverview: View {
  @EnvironmentObject private var model: AppModel
  let plan: SprintPlan

  private var scopedItems: [WorkItem] {
    let ids = Set(plan.items.map(\.workItemID))
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var waves: [[SprintPlanningLine]] {
    let scopedIDs = Set(scopedItems.map(\.id))
    let dependenciesByItem = Dictionary(
      grouping: model.dependencies.filter {
        scopedIDs.contains($0.workItemID) && scopedIDs.contains($0.dependsOnWorkItemID)
      },
      by: \.workItemID
    )
    var waveByItem: [UUID: Int] = [:]
    var remaining = scopedItems
    while !remaining.isEmpty {
      var progressed = false
      for item in remaining {
        let prerequisiteIDs = dependenciesByItem[item.id, default: []].map(
          \.dependsOnWorkItemID
        )
        guard prerequisiteIDs.allSatisfy({ waveByItem[$0] != nil }) else { continue }
        waveByItem[item.id] = (prerequisiteIDs.compactMap { waveByItem[$0] }.max() ?? 0) + 1
        remaining.removeAll { $0.id == item.id }
        progressed = true
      }
      if !progressed {
        let fallback = (waveByItem.values.max() ?? 0) + 1
        for item in remaining {
          waveByItem[item.id] = fallback
        }
        remaining.removeAll()
      }
    }

    let sprintItems = Dictionary(
      uniqueKeysWithValues: plan.items.map { ($0.workItemID, $0) }
    )
    let lines = scopedItems.map { item -> SprintPlanningLine in
      let sprintItem = sprintItems[item.id]
      let owner = sprintItem?.implementerProfileID.flatMap { ownerID in
        model.profiles.first { $0.id == ownerID }
      }
      let risks = model.sprintReadinessIssues
        .filter { $0.workItemID == item.id }
        .map(\.message)
      return SprintPlanningLine(
        item: item,
        owner: owner,
        forecast: SprintForecast.estimate(for: item),
        wave: waveByItem[item.id] ?? 1,
        risks: risks
      )
    }
    return Dictionary(grouping: lines, by: \.wave)
      .sorted { $0.key < $1.key }
      .map { $0.value.sorted { $0.item.rank < $1.item.rank } }
  }

  private var allLines: [SprintPlanningLine] {
    waves.flatMap { $0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        SprintPlanningMetric(
          title: "Planned scope",
          value: "\(plan.items.count) \(plan.items.count == 1 ? "ticket" : "tickets")",
          detail: "saved and ready to authorise",
          symbol: "checklist.checked"
        )
        SprintPlanningMetric(
          title: "Execution",
          value: "\(waves.count) \(waves.count == 1 ? "wave" : "waves")",
          detail: "all eligible work starts together",
          symbol: "point.3.connected.trianglepath.dotted"
        )
        SprintPlanningMetric(
          title: "Token forecast",
          value: forecastRange,
          detail: "broad planning range",
          symbol: "gauge.with.dots.needle.33percent"
        )
        SprintPlanningMetric(
          title: "Readiness",
          value: model.sprintReadinessIssues.isEmpty
            ? "Ready to start"
            : "\(model.sprintReadinessIssues.count) blocked",
          detail: model.sprintReadinessIssues.isEmpty
            ? "all gates satisfied"
            : "review highlighted issues",
          symbol: model.sprintReadinessIssues.isEmpty
            ? "checkmark.seal"
            : "exclamationmark.triangle"
        )
      }

      VStack(alignment: .leading, spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Planned delivery")
              .font(.headline)
            Text("Tickets are grouped by the dependency wave in which they can begin.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text("Saved Sprint \(plan.sprint.number) plan")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(14)

        Divider()

        ForEach(Array(waves.enumerated()), id: \.offset) { index, wave in
          SprintPlanningWave(
            number: index + 1,
            lines: wave,
            isLast: index == waves.count - 1
          )
        }
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(.separator.opacity(0.65), lineWidth: 1)
      }

      Text("To change scope or priority, edit tickets in the Sprint or Backlog section of the Backlog view. Review does not start any agents.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var forecastRange: String {
    let low = allLines.reduce(0) { $0 + $1.forecast.tokenLow }
    let high = allLines.reduce(0) { $0 + $1.forecast.tokenHigh }
    return "\(compactTokens(low))–\(compactTokens(high))"
  }

  private func compactTokens(_ value: Int) -> String {
    value >= 1_000
      ? String(format: "%.0fk", Double(value) / 1_000)
      : value.formatted()
  }
}

private struct RetrospectivesView: View {
  @EnvironmentObject private var model: AppModel
  let onConcluded: () -> Void
  @State private var selectedSprintID: UUID?
  @State private var isConcluding = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Retrospectives")
            .font(.largeTitle.bold())
          Text("Review what the team learned and decide what should change next.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !availablePlans.isEmpty {
          Picker("Sprint", selection: selectedSprintBinding) {
            ForEach(availablePlans, id: \.sprint.id) { plan in
              Text(
                "Sprint \(plan.sprint.number) · \(plan.sprint.state == .active ? "Active" : "Completed")"
              )
              .tag(plan.sprint.id)
            }
          }
          .labelsHidden()
          .frame(width: 190)
        }
      }
      .padding(24)

      Divider()

      if let selectedPlan {
        VStack(spacing: 0) {
          retrospectiveWorkspace

          Divider()
          retrospectiveFooter(selectedPlan)
        }
      } else {
        ContentUnavailableView {
          Label("No sprint evidence yet", systemImage: "rectangle.3.group.bubble")
        } description: {
          Text(
            "Start a sprint and StoryPointless will collect specific wins, friction, and suggested improvements from each agent."
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      selectPreferredPlanIfNeeded()
    }
    .onChange(of: availablePlanSignature) { _, _ in
      selectPreferredPlanIfNeeded()
    }
  }

  private var availablePlans: [SprintPlan] {
    var plans = model.sprintHistory
    if let current = model.sprintPlan,
      !plans.contains(where: { $0.sprint.id == current.sprint.id })
    {
      plans.append(current)
    }
    return plans
      .filter { $0.sprint.state == .active || $0.sprint.state == .completed }
      .sorted { $0.sprint.number > $1.sprint.number }
  }

  private var availablePlanSignature: [String] {
    availablePlans.map {
      "\($0.sprint.id.uuidString):\($0.sprint.state.rawValue):\($0.sprint.retrospectiveConcludedAt?.timeIntervalSince1970 ?? 0)"
    }
  }

  private var preferredPlan: SprintPlan? {
    availablePlans.first {
      $0.sprint.state == .completed
        && $0.sprint.retrospectiveConcludedAt == nil
    }
      ?? availablePlans.first(where: { $0.sprint.state == .active })
      ?? availablePlans.first
  }

  private var selectedSprintBinding: Binding<UUID> {
    Binding(
      get: { selectedSprintID ?? preferredPlan?.sprint.id ?? UUID() },
      set: { selectedSprintID = $0 }
    )
  }

  private var selectedPlan: SprintPlan? {
    let id = selectedSprintID ?? preferredPlan?.sprint.id
    return availablePlans.first { $0.sprint.id == id }
  }

  private var selectedNotes: [RetrospectiveNote] {
    guard let sprintID = selectedPlan?.sprint.id else { return [] }
    return model.retrospectiveNotes.filter { $0.sprintID == sprintID }
  }

  private var unresolvedActions: [RetrospectiveNote] {
    selectedNotes.filter {
      $0.category == .suggestedAction && $0.actionStatus == .proposed
    }
  }

  private func selectPreferredPlanIfNeeded() {
    guard
      selectedSprintID == nil
        || !availablePlans.contains(where: { $0.sprint.id == selectedSprintID })
    else { return }
    selectedSprintID = preferredPlan?.sprint.id
  }

  private func themes(
    for category: RetrospectiveNoteCategory
  ) -> [RetrospectiveTheme] {
    let notes = selectedNotes.filter { $0.category == category }
    return Dictionary(grouping: notes) { retrospectiveThemeTitle(for: $0.body) }
      .map { title, notes in
        RetrospectiveTheme(
          title: title,
          notes: notes.sorted { $0.createdAt < $1.createdAt }
        )
      }
      .sorted {
        if $0.notes.count == $1.notes.count {
          return $0.title < $1.title
        }
        return $0.notes.count > $1.notes.count
      }
  }

  private func retrospectiveThemeTitle(for body: String) -> String {
    let text = body.lowercased()
    let themes: [(String, [String])] = [
      ("Verification & evidence", [
        "check", "test", "verify", "verification", "candidate", "diff", "whitespace",
      ]),
      ("Documentation & knowledge", [
        "document", "knowledge", "decision", "record", "wording",
      ]),
      ("Product scope & decisions", [
        "approval", "requirement", "scope", "provider", "commercial", "privacy", "limit",
      ]),
      ("Experience & preview", [
        "ui", "theme", "browser", "visual", "prototype", "responsive", "accessibility",
      ]),
      ("Integration & architecture", [
        "integration", "adapter", "gateway", "cors", "contract", "response",
      ]),
    ]
    return themes.first { _, keywords in
      keywords.contains { text.contains($0) }
    }?.0 ?? "Delivery process"
  }

  private var retrospectiveWorkspace: some View {
    GeometryReader { geometry in
      let dividerWidth: CGFloat = 1
      let availableWidth = max(geometry.size.width - dividerWidth, 0)
      let decisionWidth = availableWidth / 3
      let evidenceWidth = availableWidth - decisionWidth

      HStack(spacing: 0) {
        ScrollView(.vertical) {
          retrospectiveEvidence
            .padding(24)
        }
        .frame(width: evidenceWidth)
        .frame(maxHeight: .infinity)

        Divider()

        RetrospectiveActionPanel(
          notes: selectedNotes.filter { $0.category == .suggestedAction }
        )
        .frame(width: decisionWidth)
        .frame(maxHeight: .infinity)
      }
      .frame(
        width: geometry.size.width,
        height: geometry.size.height,
        alignment: .leading
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var retrospectiveEvidence: some View {
    HStack(alignment: .top, spacing: 14) {
      RetrospectiveColumn(
        category: .wentWell,
        themes: themes(for: .wentWell)
      )
      RetrospectiveColumn(
        category: .couldImprove,
        themes: themes(for: .couldImprove)
      )
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func retrospectiveFooter(_ plan: SprintPlan) -> some View {
    HStack(spacing: 10) {
      Image(
        systemName: plan.sprint.retrospectiveConcludedAt == nil
          ? "arrow.triangle.2.circlepath"
          : "checkmark.seal.fill"
      )
      .foregroundStyle(
        plan.sprint.retrospectiveConcludedAt == nil ? .purple : .green
      )
      if plan.sprint.state == .active {
        Text("This retrospective becomes concludable when the sprint is complete.")
      } else if let concludedAt = plan.sprint.retrospectiveConcludedAt {
        Text(
          "Concluded \(concludedAt.formatted(date: .abbreviated, time: .shortened))"
        )
      } else if unresolvedActions.isEmpty {
        Text("All suggested actions have been reviewed.")
      } else {
        Text(
          "\(unresolvedActions.count) suggested action\(unresolvedActions.count == 1 ? "" : "s") still need a decision."
        )
      }
      Spacer()
      Text("\(selectedNotes.count) observations")
        .foregroundStyle(.secondary)
        .monospacedDigit()
      if plan.sprint.retrospectiveConcludedAt != nil {
        Button("Back to backlog", action: onConcluded)
          .buttonStyle(.borderedProminent)
      } else if plan.sprint.state == .completed {
        Button(isConcluding ? "Concluding…" : "Conclude retrospective") {
          isConcluding = true
          Task {
            let didConclude = await model.concludeRetrospective(
              sprintID: plan.sprint.id
            )
            isConcluding = false
            if didConclude {
              onConcluded()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isConcluding || !unresolvedActions.isEmpty)
        .help(
          unresolvedActions.isEmpty
            ? "Close this sprint’s learning loop and return to the next backlog."
            : "Accept or dismiss every proposed action first."
        )
      }
    }
    .font(.callout)
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background(.bar)
  }
}

private struct RetrospectiveTheme: Identifiable {
  let title: String
  let notes: [RetrospectiveNote]

  var id: String { title }
}

private struct RetrospectiveActionPanel: View {
  @EnvironmentObject private var model: AppModel
  let notes: [RetrospectiveNote]
  @State private var isDecidingAll = false
  @State private var selectedNoteID: UUID?

  private var proposedNotes: [RetrospectiveNote] {
    notes
      .filter { $0.actionStatus == .proposed }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var reviewedCount: Int {
    notes.count - proposedNotes.count
  }

  private var selectedNote: RetrospectiveNote? {
    proposedNotes.first { $0.id == selectedNoteID } ?? proposedNotes.first
  }

  private var queuedNotes: [RetrospectiveNote] {
    guard let selectedNote else { return proposedNotes }
    return proposedNotes.filter { $0.id != selectedNote.id }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "checklist")
          .foregroundStyle(.indigo)
        VStack(alignment: .leading, spacing: 2) {
          Text("Decisions")
            .font(.title3.bold())
          Text(
            proposedNotes.isEmpty
              ? "\(reviewedCount) reviewed"
              : "\(proposedNotes.count) remaining · \(reviewedCount) reviewed"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        if proposedNotes.count > 1 {
          Menu {
            Button {
              decideAll(accept: true)
            } label: {
              Label("Accept all", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
              decideAll(accept: false)
            } label: {
              Label("Dismiss all", systemImage: "xmark.circle")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .disabled(isDecidingAll)
          .help("Decide all remaining actions")
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      if let selectedNote {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 18) {
            RetrospectiveActionDecisionDetail(note: selectedNote)

            if !queuedNotes.isEmpty {
              VStack(alignment: .leading, spacing: 0) {
                Text("Up next")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 4)
                  .padding(.bottom, 7)

                ForEach(queuedNotes) { note in
                  RetrospectiveActionQueueRow(note: note) {
                    selectedNoteID = note.id
                  }
                  if note.id != queuedNotes.last?.id {
                    Divider()
                  }
                }
              }
            }
          }
          .padding(16)
        }
      } else {
        VStack(spacing: 7) {
          Image(systemName: "checkmark.circle.fill")
            .font(.title2)
            .foregroundStyle(Color.green.opacity(0.68))
          Text("Decisions complete")
            .font(.subheadline.weight(.semibold))
          Text(
            reviewedCount == 0
              ? "The team did not suggest a change."
              : "Every suggested change has been reviewed."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
  }

  private func decideAll(accept: Bool) {
    isDecidingAll = true
    Task {
      await model.decideRetrospectiveActions(proposedNotes, accept: accept)
      isDecidingAll = false
    }
  }
}

private struct RetrospectiveActionDecisionDetail: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote

  private var ticket: WorkItem? {
    guard let workItemID = note.workItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  private var profile: AgentProfile? {
    guard let profileID = note.profileID else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var destination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(destination.title, systemImage: destinationSymbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(destination == .teamPractice ? .purple : .blue)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
          (destination == .teamPractice ? Color.purple : Color.blue).opacity(0.09),
          in: Capsule()
        )

      Text(note.body)
        .font(.body.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        Image(systemName: profile?.role.symbolName ?? "person.crop.circle")
          .foregroundStyle(profile?.role.tint ?? .secondary)
        Text(note.authorName)
          .fontWeight(.semibold)
        if let ticket {
          Text("· \(ticket.key)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      Divider()

      Text(
        destination == .teamPractice
          ? "Accepting updates the team’s Ways of working."
          : "Accepting creates a new backlog ticket."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 7) {
        Spacer()
        Button("Dismiss") {
          Task { await model.decideRetrospectiveAction(note, accept: false) }
        }
        Button {
          Task { await model.decideRetrospectiveAction(note, accept: true) }
        } label: {
          Label("Accept", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
      }
      .controlSize(.small)
    }
    .padding(16)
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
    }
  }

  private var destinationSymbol: String {
    switch destination {
    case .teamPractice: "person.2.badge.gearshape"
    case .backlog: "list.bullet.clipboard"
    }
  }
}

private struct RetrospectiveActionQueueRow: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let onSelect: () -> Void
  @State private var isHovering = false

  private var profile: AgentProfile? {
    guard let profileID = note.profileID else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var destination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: destinationSymbol)
          .foregroundStyle(destination == .teamPractice ? .purple : .blue)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 5) {
          Text(note.body)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 5) {
            Text(destination.title)
            Text("·")
            Text(note.authorName)
              .foregroundStyle(profile?.role.tint ?? .secondary)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .padding(.top, 2)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 11)
      .background(
        isHovering ? Color.accentColor.opacity(0.07) : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
  }

  private var destinationSymbol: String {
    switch destination {
    case .teamPractice: "person.2.badge.gearshape"
    case .backlog: "list.bullet.clipboard"
    }
  }
}

private struct RetrospectiveColumn: View {
  let category: RetrospectiveNoteCategory
  let themes: [RetrospectiveTheme]

  private var noteCount: Int {
    themes.reduce(0) { $0 + $1.notes.count }
  }

  private var tint: Color {
    switch category {
    case .wentWell: .green
    case .couldImprove: .orange
    case .suggestedAction: .indigo
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Image(systemName: symbol)
            .foregroundStyle(tint)
          Text(panelTitle)
            .font(.title3.bold())
          Text(noteCount.formatted())
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
          Spacer()
        }
        if category == .suggestedAction {
          Text("The team has chosen a destination for each action. Accept it or dismiss it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if themes.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "note.text")
            .font(.title2)
          Text(category == .suggestedAction ? "No suggested changes" : "No evidence recorded yet")
            .font(.callout.weight(.medium))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
      } else {
        ForEach(themes) { theme in
          RetrospectiveThemeSection(
            category: category,
            theme: theme,
            tint: tint
          )
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
  }

  private var panelTitle: String {
    category == .suggestedAction ? "Actions to decide" : category.title
  }

  private var symbol: String {
    switch category {
    case .wentWell: "hand.thumbsup.fill"
    case .couldImprove: "lightbulb.fill"
    case .suggestedAction: "plus.rectangle.on.rectangle"
    }
  }
}

private struct RetrospectiveThemeSection: View {
  @EnvironmentObject private var model: AppModel
  let category: RetrospectiveNoteCategory
  let theme: RetrospectiveTheme
  let tint: Color
  @State private var isExpanded = false
  @State private var isDeciding = false

  private var proposedNotes: [RetrospectiveNote] {
    theme.notes.filter { $0.actionStatus == .proposed }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Text(theme.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Spacer()
          if !proposedNotes.isEmpty {
            Text("\(proposedNotes.count) to decide")
              .foregroundStyle(.orange)
          } else {
            Text(theme.notes.count.formatted())
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(theme.title), \(theme.notes.count) observations")
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Collapse this group" : "Expand this group")

      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          if category == .suggestedAction, !proposedNotes.isEmpty {
            HStack(spacing: 7) {
              Button("Dismiss theme") {
                decideAll(accept: false)
              }
              Spacer()
              Button {
                decideAll(accept: true)
              } label: {
                Label("Accept theme", systemImage: "checkmark.circle")
              }
              .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .disabled(isDeciding)
          }
          ForEach(theme.notes) { note in
            RetrospectiveStickyNote(note: note, tint: tint)
          }
        }
        .padding(.top, 10)
        .transition(.opacity)
      }
    }
    .padding(12)
    .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(tint.opacity(0.13), lineWidth: 1)
    }
  }

  private func decideAll(accept: Bool) {
    isDeciding = true
    Task {
      await model.decideRetrospectiveActions(proposedNotes, accept: accept)
      isDeciding = false
    }
  }

}

private struct RetrospectiveStickyNote: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let tint: Color

  private var ticket: WorkItem? {
    guard let workItemID = note.workItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  private var profile: AgentProfile? {
    guard let profileID = note.profileID else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var rotation: Double {
    let scalar = note.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return Double((scalar % 5) - 2) * 0.35
  }

  private var actionDestination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text(note.body)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        if note.category == .suggestedAction {
          Label(actionDestination.title, systemImage: destinationSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(actionDestination == .teamPractice ? .purple : .blue)
          Text("·")
            .foregroundStyle(.tertiary)
        }
        Image(systemName: profile?.role.symbolName ?? "person.crop.circle")
          .foregroundStyle(profile?.role.tint ?? tint)
        Text(note.authorName)
          .fontWeight(.semibold)
        if let ticket {
          Text("· \(ticket.key)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      if note.category == .suggestedAction {
        actionControls
      }
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(tint.opacity(0.18), lineWidth: 0.7)
    }
    .rotationEffect(.degrees(rotation))
  }

  @ViewBuilder
  private var actionControls: some View {
    switch note.actionStatus {
    case .proposed:
      HStack(spacing: 7) {
        Spacer()
        Button("Dismiss") {
          Task { await model.decideRetrospectiveAction(note, accept: false) }
        }
        Button {
          Task { await model.decideRetrospectiveAction(note, accept: true) }
        } label: {
          Label("Accept", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
      }
      .controlSize(.small)
    case .accepted:
      Label(
        actionDestination == .teamPractice ? "Added to Ways of working" : "Added to backlog",
        systemImage: destinationSymbol
      )
        .foregroundStyle(actionDestination == .teamPractice ? .purple : .blue)
        .font(.caption.weight(.semibold))
    case .dismissed:
      Label("Dismissed", systemImage: "xmark.circle")
        .foregroundStyle(.secondary)
        .font(.caption)
    case .none:
      EmptyView()
    }
  }

  private var destinationSymbol: String {
    switch actionDestination {
    case .teamPractice: "person.2.badge.gearshape"
    case .backlog: "list.bullet.clipboard"
    }
  }
}

private struct ReportsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Reports")
            .font(.largeTitle.bold())
          Text("Is delivery becoming cheaper, faster, clearer, and more reliable?")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(completedSprints.count) completed sprint\(completedSprints.count == 1 ? "" : "s")")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          trendReadiness

          VStack(alignment: .leading, spacing: 12) {
            Text("Measured delivery signals")
              .font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
              ReportMetricCard(
                title: "Delivered outcomes",
                value: deliveredOutcomes.formatted(),
                detail: "Tickets accepted across completed sprints",
                symbol: "shippingbox",
                tint: .blue
              )
              ReportMetricCard(
                title: "Median cycle time",
                value: medianCycleTime ?? "—",
                detail: "Wall time from Start Sprint to the final accepted ticket",
                symbol: "clock",
                tint: .purple
              )
              ReportMetricCard(
                title: "Agent time per outcome",
                value: agentTimePerOutcome ?? "—",
                detail: "Recorded active delivery and review time; queues excluded",
                symbol: "timer",
                tint: .indigo
              )
              ReportMetricCard(
                title: "First-pass review",
                value: firstPassRate,
                detail: "Accepted candidates that needed no correction cycle",
                symbol: "checkmark.bubble",
                tint: .green
              )
              ReportMetricCard(
                title: "Review corrections",
                value: reviewCorrectionCount.formatted(),
                detail: "Additional candidate revisions before acceptance",
                symbol: "arrow.clockwise",
                tint: .pink
              )
            }
          }

          if !sprintData.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text("Sprint performance")
                .font(.title3.bold())
              Text(
                "Both bars use the same time scale. Agent time sums active work and can exceed wall-clock cycle time when agents work in parallel."
              )
                .font(.caption)
                .foregroundStyle(.secondary)
              SprintPerformanceChart(data: sprintData)
            }

            VStack(alignment: .leading, spacing: 12) {
              Text("Outcomes and review effort")
                .font(.title3.bold())
              SprintOutcomeChart(data: sprintData)
            }
          }

          Text(
            "Treat one sprint as a baseline, not a trend. Compare similar work and connect changes to an adopted retrospective practice before attributing an improvement."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(24)
      }
    }
  }

  private var completedSprints: [SprintPlan] {
    model.sprintHistory
      .filter { $0.sprint.state == .completed }
      .sorted { $0.sprint.number < $1.sprint.number }
  }

  private var completedSprintIDs: Set<UUID> {
    Set(completedSprints.map(\.sprint.id))
  }

  private var acceptedCandidates: [CandidateRevision] {
    model.candidateRevisions.filter {
      completedSprintIDs.contains($0.sprintID) && $0.status == .accepted
    }
  }

  private var deliveredOutcomes: Int {
    Set(acceptedCandidates.map(\.workItemID)).count
  }

  private var medianCycleTime: String? {
    let durations = completedSprints.compactMap { plan -> TimeInterval? in
      guard let started = plan.sprint.startedAt, let completed = plan.sprint.completedAt else {
        return nil
      }
      return max(0, completed.timeIntervalSince(started))
    }.sorted()
    guard !durations.isEmpty else { return nil }
    let middle = durations.count / 2
    let value = durations.count.isMultiple(of: 2)
      ? (durations[middle - 1] + durations[middle]) / 2
      : durations[middle]
    return RunHealthLabel.duration(value)
  }

  private var totalAgentTime: TimeInterval {
    model.runs
      .filter { $0.sprintID.map(completedSprintIDs.contains) == true }
      .reduce(0) { $0 + $1.activeDuration() }
  }

  private var agentTimePerOutcome: String? {
    guard deliveredOutcomes > 0, totalAgentTime > 0 else { return nil }
    return RunHealthLabel.duration(totalAgentTime / Double(deliveredOutcomes))
  }

  private var firstPassRate: String {
    guard !acceptedCandidates.isEmpty else { return "—" }
    let firstPass = acceptedCandidates.filter { $0.version == 1 }.count
    return (Double(firstPass) / Double(acceptedCandidates.count))
      .formatted(.percent.precision(.fractionLength(0)))
  }

  private var reviewCorrectionCount: Int {
    acceptedCandidates.reduce(0) { $0 + max(0, $1.version - 1) }
  }

  private var sprintData: [SprintReportDatum] {
    completedSprints.map { plan in
      let candidates = acceptedCandidates.filter { $0.sprintID == plan.sprint.id }
      let cycleTime: TimeInterval
      if let started = plan.sprint.startedAt, let completed = plan.sprint.completedAt {
        cycleTime = max(0, completed.timeIntervalSince(started))
      } else {
        cycleTime = 0
      }
      let runs = model.runs.filter { $0.sprintID == plan.sprint.id }
      return SprintReportDatum(
        sprintNumber: plan.sprint.number,
        cycleTime: cycleTime,
        activeAgentTime: runs.reduce(0) { $0 + $1.activeDuration() },
        outcomes: Set(candidates.map(\.workItemID)).count,
        reviewCorrections: candidates.reduce(0) { $0 + max(0, $1.version - 1) },
        interruptedRuns: runs.filter {
          $0.status == .failed || $0.status == .interrupted
        }.count
      )
    }
  }

  private var trendReadiness: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: completedSprints.count >= 2 ? "chart.line.uptrend.xyaxis" : "scope")
        .font(.title2)
        .foregroundStyle(completedSprints.count >= 2 ? .green : .blue)
      VStack(alignment: .leading, spacing: 4) {
        Text(trendTitle)
          .font(.headline)
        Text(trendDetail)
          .foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      (completedSprints.count >= 2 ? Color.green : Color.blue).opacity(0.07),
      in: RoundedRectangle(cornerRadius: 14)
    )
  }

  private var trendTitle: String {
    switch completedSprints.count {
    case 0: "Collecting the first baseline"
    case 1: "Baseline established"
    default: "Improvement trends available"
    }
  }

  private var trendDetail: String {
    switch completedSprints.count {
    case 0:
      "Complete a sprint before drawing conclusions. Current operational values are shown, but no trend is claimed."
    case 1:
      "One completed sprint provides a baseline. A second comparable sprint can begin showing direction, with uncertainty kept visible."
    default:
      "Compare similar work across sprints and connect changes to retrospective experiments before attributing an improvement."
    }
  }
}

private struct SprintReportDatum: Identifiable {
  let sprintNumber: Int
  let cycleTime: TimeInterval
  let activeAgentTime: TimeInterval
  let outcomes: Int
  let reviewCorrections: Int
  let interruptedRuns: Int

  var id: Int { sprintNumber }
}

private struct SprintPerformanceChart: View {
  let data: [SprintReportDatum]

  private var maximumTime: TimeInterval {
    max(
      1,
      data.flatMap { [$0.cycleTime, $0.activeAgentTime] }.max() ?? 1
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(data) { sprint in
        VStack(alignment: .leading, spacing: 8) {
          Text("Sprint \(sprint.sprintNumber)")
            .font(.headline)
          ReportBar(
            title: "Cycle time",
            value: RunHealthLabel.duration(sprint.cycleTime),
            fraction: sprint.cycleTime / maximumTime,
            tint: .purple
          )
          ReportBar(
            title: "Agent time",
            value: RunHealthLabel.duration(sprint.activeAgentTime),
            fraction: sprint.activeAgentTime / maximumTime,
            tint: .indigo
          )
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }
}

private struct ReportBar: View {
  let title: String
  let value: String
  let fraction: Double
  let tint: Color

  var body: some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.quaternary)
          Capsule()
            .fill(tint.gradient)
            .frame(width: max(3, geometry.size.width * min(max(fraction, 0), 1)))
        }
      }
      .frame(height: 8)
      Text(value)
        .font(.caption.monospacedDigit().weight(.semibold))
        .frame(width: 72, alignment: .trailing)
    }
  }
}

private struct SprintOutcomeChart: View {
  let data: [SprintReportDatum]

  private var maximumCount: Int {
    max(1, data.map { $0.outcomes + $0.reviewCorrections }.max() ?? 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 14) {
        Label("Accepted outcomes", systemImage: "square.fill")
          .foregroundStyle(.blue)
        Label("Correction cycles", systemImage: "square.fill")
          .foregroundStyle(.orange)
        Spacer()
      }
      .font(.caption)

      ForEach(data) { sprint in
        HStack(spacing: 12) {
          Text("Sprint \(sprint.sprintNumber)")
            .font(.callout.weight(.semibold))
            .frame(width: 72, alignment: .leading)
          GeometryReader { geometry in
            HStack(spacing: 2) {
              if sprint.outcomes > 0 {
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.blue.gradient)
                  .frame(
                    width: geometry.size.width
                      * Double(sprint.outcomes) / Double(maximumCount)
                  )
              }
              if sprint.reviewCorrections > 0 {
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.orange.gradient)
                  .frame(
                    width: geometry.size.width
                      * Double(sprint.reviewCorrections) / Double(maximumCount)
                  )
              }
            }
          }
          .frame(height: 18)
          Text(
            "\(sprint.outcomes) delivered · \(sprint.reviewCorrections) corrections"
              + (sprint.interruptedRuns > 0 ? " · \(sprint.interruptedRuns) interrupted" : "")
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 260, alignment: .trailing)
        }
      }
    }
    .padding(16)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct ImprovementLens: Identifiable {
  let title: String
  let detail: String
  let symbol: String
  let tint: Color

  var id: String { title }
}

private struct ImprovementLensCard: View {
  let lens: ImprovementLens

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: lens.symbol)
        .font(.title3)
        .foregroundStyle(lens.tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(lens.title)
          .font(.headline)
        Text(lens.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct RetrospectiveSprintRow: View {
  let plan: SprintPlan

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
        .font(.title2)
        .foregroundStyle(.purple)
      VStack(alignment: .leading, spacing: 3) {
        Text("Sprint \(plan.sprint.number)")
          .font(.headline)
        Text(plan.sprint.goal)
          .lineLimit(1)
        Text("\(plan.items.count) tickets · evidence ready for retrospective")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let completedAt = plan.sprint.completedAt {
        Text(completedAt, style: .date)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(15)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct ReportMetricCard: View {
  let title: String
  let value: String
  let detail: String
  let symbol: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: symbol)
          .foregroundStyle(tint)
        Spacer()
        Text(value)
          .font(.title2.monospacedDigit().weight(.semibold))
      }
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct SprintLane: Identifiable {
  let title: String
  let states: Set<WorkItemState>

  var id: String { title }
}

private struct SprintTeamActivity: View {
  @EnvironmentObject private var model: AppModel
  let plan: SprintPlan

  private var sprintRuns: [AgentRun] {
    model.runs.filter { $0.sprintID == plan.sprint.id }
  }

  private var activeRuns: [AgentRun] {
    sprintRuns.filter { $0.status == .running }
  }

  private var involvedProfiles: [AgentProfile] {
    var ids = Set(plan.items.compactMap(\.implementerProfileID))
    ids.formUnion(plan.items.compactMap(\.reviewerProfileID))
    ids.formUnion(sprintRuns.map(\.profileID))
    return model.profiles.filter { ids.contains($0.id) }
  }

  private func activeRuns(for profile: AgentProfile) -> [AgentRun] {
    activeRuns
      .filter { $0.profileID == profile.id }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private func helpText(for profile: AgentProfile) -> String {
    let profileRuns = activeRuns(for: profile)
    guard !profileRuns.isEmpty else {
      return "\(profile.name) — idle"
    }
    let lines = profileRuns.map { run in
      let item = model.workItems.first { $0.id == run.workItemID }
      let candidate = model.candidateRevisions
        .filter { $0.workItemID == run.workItemID }
        .max { $0.version < $1.version }
      let action = switch candidate?.status {
      case .resolvingConflict: "Resolving conflict on"
      case .reviewing: "Reviewing"
      default: "Working on"
      }
      return "\(action) \(item?.key ?? "a ticket")"
    }
    return "\(profile.name)\n\(lines.joined(separator: "\n"))"
  }

  var body: some View {
    HStack(spacing: 7) {
      ForEach(involvedProfiles, id: \.id) { profile in
        let runCount = activeRuns(for: profile).count
        let isActive = runCount > 0
        HStack(spacing: 6) {
          Image(systemName: profile.role.symbolName)
            .font(.caption2.weight(.bold))
          Text(profile.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          if isActive {
            Text(runCount.formatted())
              .font(.caption2.monospacedDigit().weight(.bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(profile.role.tint, in: Capsule())
          }
        }
        .foregroundStyle(
          isActive ? profile.role.tint : Color(nsColor: .secondaryLabelColor)
        )
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
          isActive ? profile.role.tint.opacity(0.13) : Color.clear,
          in: Capsule()
        )
        .overlay {
          Capsule().stroke(
            isActive
              ? profile.role.tint.opacity(0.7)
              : Color(nsColor: .separatorColor).opacity(0.8),
            lineWidth: isActive ? 1.2 : 1
          )
        }
        .opacity(isActive ? 1 : 0.58)
        .help(helpText(for: profile))
      }
    }
  }
}

private struct SprintBanner: View {
  @EnvironmentObject private var model: AppModel
  let plan: SprintPlan
  let onEdit: () -> Void
  let onStart: () -> Void

  private var planningIsComplete: Bool {
    !plan.items.isEmpty && plan.items.allSatisfy { $0.estimatedTokens > 0 }
  }

  private var sprintIsReady: Bool {
    planningIsComplete && model.sprintReadinessIssues.isEmpty
  }

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: "pencil.and.list.clipboard")
        .font(.title2)
        .foregroundStyle(sprintIsReady ? .green : .orange)
        .frame(width: 34)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("Sprint \(plan.sprint.number)")
            .font(.headline)
          Text(sprintIsReady ? "READY" : "PLANNING")
            .font(.caption2.weight(.bold))
            .foregroundStyle(sprintIsReady ? .green : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
              (sprintIsReady ? Color.green : Color.orange).opacity(0.1),
              in: Capsule()
            )
        }
        Text(plan.sprint.goal)
          .lineLimit(2)
        Text(planningSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      if !planningIsComplete {
        VStack(alignment: .trailing, spacing: 3) {
          Text("Sprint planning required")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          Text("Review the scope to create owners and forecasts")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if !model.sprintReadinessIssues.isEmpty {
        VStack(alignment: .trailing, spacing: 3) {
          Text("\(model.sprintReadinessIssues.count) readiness issue(s)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          Text(model.sprintReadinessIssues.first?.message ?? "Review the sprint plan")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Button(planningIsComplete ? "Review plan" : "Plan sprint", action: onEdit)
      Button("Start sprint") {
        Task {
          if await model.startSprint() {
            onStart()
          }
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!planningIsComplete || !model.sprintReadinessIssues.isEmpty)
    }
    .padding(14)
    .background(
      (sprintIsReady ? Color.green : Color.orange).opacity(0.06),
      in: RoundedRectangle(cornerRadius: 14)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(
          (sprintIsReady ? Color.green : Color.orange).opacity(0.18),
          lineWidth: 1
        )
    }
  }

  private var planningSummary: String {
    if !planningIsComplete {
      return "\(plan.items.count) tickets scoped · planning has not been completed"
    }
    let tokens = plan.estimatedTokens >= 1_000
      ? String(format: "%.0fk", Double(plan.estimatedTokens) / 1_000)
      : plan.estimatedTokens.formatted()
    return
      "\(plan.items.count) tickets · dependency-led parallelism · ~\(tokens) estimated tokens"
  }
}

private struct BacklogColumn: View {
  let state: WorkItemState
  let items: [WorkItem]
  let suggestionBatch: TicketSuggestionBatch?
  let onNewTicket: (() -> Void)?

  var body: some View {
    TicketColumn(
      title: state.title,
      items: items,
      showsWorkflowActions: true,
      suggestionBatch: suggestionBatch,
      onAdd: onNewTicket
    )
  }
}

private struct SprintBoardColumn: View {
  let title: String
  let items: [WorkItem]
  let columnWidth: CGFloat
  let motionNamespace: Namespace.ID
  let onOpen: (WorkItem) -> Void

  var body: some View {
    TicketColumn(
      title: title,
      items: items,
      showsWorkflowActions: false,
      columnWidth: columnWidth,
      motionNamespace: motionNamespace,
      onOpen: onOpen
    )
  }
}

private struct SprintTicketRunSummary: View {
  let profile: AgentProfile?
  let run: AgentRun?
  let liveActivity: CodexLiveActivity?
  let onStop: ((AgentRun) -> Void)?
  @State private var showsRunDetails = false

  private var contextFraction: Double? {
    guard
      run?.status == .running || run?.status == .awaitingOwner,
      let used = run?.contextUsedTokens,
      let window = run?.contextWindowTokens,
      window > 0
    else { return nil }
    return min(1, max(0, Double(used) / Double(window)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        if let profile {
          Label(profile.name, systemImage: profile.role.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(profile.role.tint)
            .lineLimit(1)
        } else {
          Image(systemName: "person.crop.circle.badge.questionmark")
            .foregroundStyle(.secondary)
          Text("Assignment unavailable")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if run != nil {
          Button {
            showsRunDetails.toggle()
          } label: {
            Image(systemName: "info.circle")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Show run details")
          .popover(isPresented: $showsRunDetails, arrowEdge: .trailing) {
            SprintRunDetailsPopover(
              profile: profile,
              run: run,
              liveActivity: liveActivity,
              onStop: onStop
            )
          }
        }
      }

      if let contextFraction {
        HStack(spacing: 7) {
          ProgressView(value: contextFraction)
            .progressViewStyle(.linear)
          Text("\(Int((contextFraction * 100).rounded()))% context")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
          if let compactions = run?.compactionCount, compactions > 0 {
            Text("· \(compactions) compacted")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
        }
        .help("Current context-window occupancy; compaction can reduce it during a run.")
      }

      if run?.status == .running, let liveActivity {
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: liveActivity.kind.symbolName)
            .frame(width: 13)
          Text(liveActivity.text)
            .lineLimit(2, reservesSpace: true)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.blue)
        .clipped()
      }

      if run?.status == .running {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          RunHealthLabel(run: run, now: timeline.date)
        }
      }
    }
  }
}

private struct RunHealthLabel: View {
  let run: AgentRun?
  let now: Date

  var body: some View {
    let lastActivityAt = run?.lastActivityAt
    let age = lastActivityAt.map { max(0, now.timeIntervalSince($0)) }
    HStack(spacing: 5) {
      Image(systemName: "clock")
      if let age, age > 180, let lastActivityAt {
        Text("Working · telemetry quiet since \(lastActivityAt, style: .relative)")
      } else if let startedAt = run?.turnStartedAt {
        Text("Active · \(Self.duration(now.timeIntervalSince(startedAt))) elapsed")
      } else {
        Text("Waiting for activity")
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .help(
      "Codex telemetry is event-driven. A quiet interval does not mean the run has stopped."
    )
  }

  static func duration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval))
    let days = totalSeconds / 86_400
    let hours = (totalSeconds % 86_400) / 3_600
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if days > 0 {
      return "\(days)d \(hours)h"
    }
    if hours > 0 {
      return "\(hours)h \((totalSeconds % 3_600) / 60)m"
    }
    return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
  }
}

private struct SprintRunDetailsPopover: View {
  let profile: AgentProfile?
  let run: AgentRun?
  let liveActivity: CodexLiveActivity?
  let onStop: ((AgentRun) -> Void)?

  var body: some View {
    Group {
      if run?.status == .running {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          details(at: timeline.date)
        }
      } else {
        details(at: run?.updatedAt ?? Date())
      }
    }
  }

  private func details(at referenceDate: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Run details")
        .font(.headline)
      LabeledContent("Team member", value: profile?.name ?? "Unavailable")
      if let run {
        LabeledContent("Status", value: run.status.displayTitle)
        switch run.status {
        case .running:
          if run.turnStartedAt != nil {
            LabeledContent(
              "Elapsed",
              value: RunHealthLabel.duration(run.activeDuration(at: referenceDate))
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            LabeledContent {
              Text(lastActivityAt, style: .relative)
            } label: {
              Text("Last activity")
            }
          }
        case .queued:
          LabeledContent("Timing", value: "Starts when picked up")
          if run.activeDurationSeconds > 0 {
            LabeledContent(
              "Recorded active time",
              value: RunHealthLabel.duration(run.activeDurationSeconds)
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            LabeledContent {
              Text(
                lastActivityAt,
                format: .dateTime.day().month(.abbreviated).hour().minute()
              )
            } label: {
              Text("Previous activity")
            }
          }
        case .awaitingOwner, .interrupted, .completed, .failed, .cancelled:
          if run.activeDurationSeconds > 0 {
            LabeledContent(
              "Active time",
              value: RunHealthLabel.duration(run.activeDurationSeconds)
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            LabeledContent {
              Text(
                lastActivityAt,
                format: .dateTime.day().month(.abbreviated).hour().minute()
              )
            } label: {
              Text("Last activity")
            }
          }
        }
        if
          run.status != .queued,
          let used = run.contextUsedTokens,
          let window = run.contextWindowTokens
        {
          LabeledContent(
            "Context",
            value: "\(used.formatted()) / \(window.formatted()) tokens"
          )
        } else if run.status == .running {
          LabeledContent("Context", value: "Not reported by Codex yet")
        }
        if run.status != .queued {
          LabeledContent("Compactions", value: run.compactionCount.formatted())
        }
      }
      if run?.status == .running, let liveActivity {
        Divider()
        Label(liveActivity.text, systemImage: liveActivity.kind.symbolName)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if
        let run,
        run.status == .running,
        profile?.role != .lead,
        let onStop
      {
        Divider()
        Button(role: .destructive) {
          onStop(run)
        } label: {
          Label("Stop and preserve workspace", systemImage: "stop.circle")
        }
        .buttonStyle(.bordered)
        .help("Interrupt this turn without deleting its ticket branch or worktree.")
      }
    }
    .frame(width: 300)
    .padding(16)
  }
}

private struct SprintCardActivity {
  let title: String
  let symbol: String
  let tint: Color
}

private extension AgentRunStatus {
  var displayTitle: String {
    switch self {
    case .queued: "Queued"
    case .running: "Running"
    case .awaitingOwner: "Needs Product Owner input"
    case .interrupted: "Interrupted"
    case .completed: "Completed"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }
}

private struct SprintTicketStatusBadge: View {
  let run: AgentRun?
  let itemState: WorkItemState
  let candidateStatus: CandidateRevisionStatus?
  let isDependencyBlocked: Bool

  private var activity: SprintCardActivity {
    if run?.status == .awaitingOwner {
      return SprintCardActivity(
        title: "Needs your input",
        symbol: "hand.raised.fill",
        tint: .orange
      )
    }
    if itemState == .acceptance {
      return SprintCardActivity(
        title: "Ready for demo",
        symbol: "play.rectangle.fill",
        tint: .orange
      )
    }
    if let candidateStatus {
      switch candidateStatus {
      case .queuedForIntegration:
        return SprintCardActivity(
          title: "Queued to integrate",
          symbol: "text.line.first.and.arrowtriangle.forward",
          tint: .indigo
        )
      case .integrating:
        return SprintCardActivity(
          title: "Integrating",
          symbol: "arrow.triangle.merge",
          tint: .blue
        )
      case .resolvingConflict:
        return SprintCardActivity(
          title: "Resolving conflict",
          symbol: "wrench.and.screwdriver.fill",
          tint: .indigo
        )
      case .reviewing:
        switch run?.status {
        case .running:
          return SprintCardActivity(
            title: "Reviewing",
            symbol: "checkmark.shield.fill",
            tint: .purple
          )
        case .failed:
          return SprintCardActivity(
            title: "Review failed",
            symbol: "exclamationmark.triangle.fill",
            tint: .red
          )
        case .interrupted:
          return SprintCardActivity(
            title: "Review interrupted",
            symbol: "pause.circle.fill",
            tint: .orange
          )
        default:
          return SprintCardActivity(
            title: "Queued for review",
            symbol: "checkmark.shield",
            tint: .indigo
          )
        }
      case .readyForDemo:
        return SprintCardActivity(
          title: "Ready for demo",
          symbol: "play.rectangle.fill",
          tint: .orange
        )
      case .accepted:
        return SprintCardActivity(
          title: "Done",
          symbol: "checkmark.circle.fill",
          tint: .green
        )
      case .failed:
        switch run?.status {
        case .running:
          return SprintCardActivity(title: "Working", symbol: "bolt.fill", tint: .blue)
        case .queued:
          return SprintCardActivity(
            title: "Retry queued",
            symbol: "arrow.clockwise",
            tint: .blue
          )
        default:
          return SprintCardActivity(
            title: "Work stopped",
            symbol: "exclamationmark.triangle.fill",
            tint: .red
          )
        }
      case .changesRequested:
        switch run?.status {
        case .failed:
          return SprintCardActivity(
            title: "Work stopped",
            symbol: "exclamationmark.triangle.fill",
            tint: .red
          )
        case .interrupted:
          return SprintCardActivity(
            title: "Work interrupted",
            symbol: "pause.circle.fill",
            tint: .orange
          )
        case .queued:
          return SprintCardActivity(
            title: "Ready to continue",
            symbol: "arrow.clockwise",
            tint: .blue
          )
        default:
          return SprintCardActivity(
            title: "Working",
            symbol: "bolt.fill",
            tint: .blue
          )
        }
      case .superseded:
        return SprintCardActivity(
          title: "Superseded",
          symbol: "arrow.triangle.2.circlepath",
          tint: .secondary
        )
      }
    }
    if itemState == .released {
      return SprintCardActivity(
        title: "Done",
        symbol: "checkmark.circle.fill",
        tint: .green
      )
    }
    if isDependencyBlocked {
      return SprintCardActivity(
        title: "Blocked",
        symbol: "lock.fill",
        tint: .indigo
      )
    }
    if let run {
      switch run.status {
      case .running:
        return SprintCardActivity(title: "Working", symbol: "bolt.fill", tint: .blue)
      case .interrupted:
        return SprintCardActivity(
          title: "Interrupted",
          symbol: "pause.circle.fill",
          tint: .orange
        )
      case .failed:
        return SprintCardActivity(
          title: "Failed",
          symbol: "exclamationmark.triangle.fill",
          tint: .red
        )
      case .cancelled:
        return SprintCardActivity(
          title: "Cancelled",
          symbol: "xmark.circle.fill",
          tint: .secondary
        )
      case .completed:
        return SprintCardActivity(
          title: "Finished",
          symbol: "checkmark.circle.fill",
          tint: .green
        )
      case .queued:
        return SprintCardActivity(title: "Ready", symbol: "tray.full", tint: .secondary)
      case .awaitingOwner:
        return SprintCardActivity(
          title: "Needs your input",
          symbol: "hand.raised.fill",
          tint: .orange
        )
      }
    }

    switch itemState {
    case .backlog:
      return SprintCardActivity(title: "Backlog", symbol: "list.bullet", tint: .secondary)
    case .refining:
      return SprintCardActivity(
        title: "Refining",
        symbol: "wand.and.stars",
        tint: .purple
      )
    case .ready, .queued:
      return SprintCardActivity(title: "Ready", symbol: "tray.full", tint: .secondary)
    case .running:
      return SprintCardActivity(title: "In progress", symbol: "bolt.fill", tint: .blue)
    case .integrating:
      return SprintCardActivity(
        title: "Integrating",
        symbol: "arrow.triangle.merge",
        tint: .blue
      )
    case .verifying:
      return SprintCardActivity(
        title: "In review",
        symbol: "checkmark.shield.fill",
        tint: .purple
      )
    case .acceptance:
      return SprintCardActivity(
        title: "Ready for demo",
        symbol: "play.rectangle.fill",
        tint: .orange
      )
    case .readyToRelease:
      return SprintCardActivity(
        title: "Ready to complete",
        symbol: "checkmark.circle",
        tint: .purple
      )
    case .released:
      return SprintCardActivity(
        title: "Done",
        symbol: "checkmark.circle.fill",
        tint: .green
      )
    case .cancelled:
      return SprintCardActivity(
        title: "Cancelled",
        symbol: "xmark.circle.fill",
        tint: .secondary
      )
    }
  }

  var body: some View {
    Label(activity.title, systemImage: activity.symbol)
      .font(.caption2.weight(.bold))
      .foregroundStyle(activity.tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(activity.tint.opacity(0.1), in: Capsule())
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }
}

private struct SprintPriorityIndicator: View {
  let priority: WorkItemPriority

  private var chevronCount: Int {
    switch priority {
    case .urgent: 3
    case .high: 2
    case .normal, .low: 1
    }
  }

  private var symbolName: String {
    switch priority {
    case .urgent, .high: "chevron.up"
    case .normal: "minus"
    case .low: "chevron.down"
    }
  }

  private var tint: Color {
    switch priority {
    case .urgent: .red
    case .high: .orange
    case .normal: Color(nsColor: .secondaryLabelColor)
    case .low: .blue.opacity(0.72)
    }
  }

  var body: some View {
    HStack(spacing: -3) {
      ForEach(0..<chevronCount, id: \.self) { _ in
        Image(systemName: symbolName)
      }
    }
    .font(.caption2.weight(.black))
    .foregroundStyle(tint)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel("\(priority.title) priority")
    .help("\(priority.title) priority")
  }
}

private struct TicketColumn: View {
  let title: String
  let items: [WorkItem]
  let showsWorkflowActions: Bool
  let suggestionBatch: TicketSuggestionBatch?
  let onAdd: (() -> Void)?
  let onOpen: ((WorkItem) -> Void)?
  let motionNamespace: Namespace.ID?
  let columnWidth: CGFloat

  init(
    title: String,
    items: [WorkItem],
    showsWorkflowActions: Bool,
    columnWidth: CGFloat = 316,
    suggestionBatch: TicketSuggestionBatch? = nil,
    onAdd: (() -> Void)? = nil,
    motionNamespace: Namespace.ID? = nil,
    onOpen: ((WorkItem) -> Void)? = nil
  ) {
    self.title = title
    self.items = items
    self.showsWorkflowActions = showsWorkflowActions
    self.columnWidth = columnWidth
    self.suggestionBatch = suggestionBatch
    self.onAdd = onAdd
    self.motionNamespace = motionNamespace
    self.onOpen = onOpen
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Text("\(items.count)")
          .font(.caption.monospacedDigit())
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        if let onAdd {
          Button(action: onAdd) {
            Image(systemName: "plus")
              .font(.caption.bold())
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Add ticket to Backlog")
        }
      }

      if let suggestionBatch {
        BacklogSuggestionStack(batch: suggestionBatch)
      }

      if items.isEmpty && suggestionBatch == nil {
        Text("No tickets")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, minHeight: 54)
          .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
      } else {
        ScrollView(.vertical) {
          LazyVStack(spacing: 10) {
            ForEach(items) { item in
              ticketCard(for: item)
            }
          }
          .padding(.bottom, 4)
        }
        .scrollIndicators(.visible)
      }
    }
    .padding(12)
    .frame(width: columnWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
  }

  @ViewBuilder
  private func ticketCard(for item: WorkItem) -> some View {
    if let motionNamespace {
      WorkItemCard(
        item: item,
        showsWorkflowActions: showsWorkflowActions,
        onOpen: onOpen
      )
      .matchedGeometryEffect(id: item.id, in: motionNamespace)
      .transition(.opacity.combined(with: .scale(scale: 0.97)))
    } else {
      WorkItemCard(
        item: item,
        showsWorkflowActions: showsWorkflowActions,
        onOpen: onOpen
      )
    }
  }
}

private struct WorkItemCard: View {
  @EnvironmentObject private var model: AppModel
  let item: WorkItem
  let showsWorkflowActions: Bool
  let onOpen: ((WorkItem) -> Void)?
  private let policy = WorkflowPolicy()

  private var sprintItem: SprintItem? {
    model.sprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var latestRun: AgentRun? {
    model.runs
      .filter { $0.workItemID == item.id }
      .sorted { lhs, rhs in
        let lhsPriority = lifecyclePriority(lhs.status)
        let rhsPriority = lifecyclePriority(rhs.status)
        if lhsPriority == rhsPriority {
          return lhs.updatedAt > rhs.updatedAt
        }
        return lhsPriority < rhsPriority
      }
      .first
  }

  private func lifecyclePriority(_ status: AgentRunStatus) -> Int {
    switch status {
    case .running: 0
    case .awaitingOwner: 1
    case .queued: 2
    case .failed, .interrupted: 3
    case .completed: 4
    case .cancelled: 5
    }
  }

  private var assignedProfile: AgentProfile? {
    if let latestRun {
      return model.profiles.first { $0.id == latestRun.profileID }
    }
    guard let ownerID = sprintItem?.implementerProfileID ?? item.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var latestCandidate: CandidateRevision? {
    let candidate = model.candidateRevisions
      .filter { $0.workItemID == item.id }
      .max { lhs, rhs in
        if lhs.version == rhs.version {
          return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.version < rhs.version
      }
    guard let candidate else { return nil }
    if let latestRun,
      (candidate.status == .superseded || candidate.status == .failed),
      (
        latestRun.status == .queued || latestRun.status == .running
          || latestRun.status == .awaitingOwner
      ),
      latestRun.updatedAt > candidate.updatedAt
    {
      return nil
    }
    return candidate
  }

  private var isDependencyBlocked: Bool {
    let prerequisiteIDs = Set(
      model.dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    return model.workItems.contains {
      prerequisiteIDs.contains($0.id) && $0.state != .released
    }
  }

  private var needsOwnerInput: Bool {
    latestRun?.status == .awaitingOwner
  }

  private var isActivelyWorkedOn: Bool {
    latestRun?.status == .running
  }

  private var cardBackground: Color {
    if needsOwnerInput {
      return .orange.opacity(0.1)
    }
    if item.state == .acceptance {
      return .orange.opacity(0.07)
    }
    return Color(nsColor: .controlBackgroundColor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          ticketIdentity
          Spacer(minLength: 4)
          ticketStatus
        }

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            ticketIdentity
            Spacer(minLength: 0)
          }
          HStack {
            Spacer(minLength: 0)
            ticketStatus
          }
        }
      }

      Text(item.title)
        .font(.body.weight(.medium))
        .lineLimit(3)

      if !showsWorkflowActions {
        SprintTicketRunSummary(
          profile: assignedProfile,
          run: latestRun,
          liveActivity: latestRun.flatMap {
            guard $0.status == .running else { return nil }
            return model.liveRunActivities[$0.id] ?? $0.persistedActivity
          },
          onStop: { run in
            Task { await model.stopAgentRun(run) }
          }
        )
      }

      if !item.acceptanceCriteria.isEmpty {
        Divider()
        Label(
          "\(item.acceptanceCriteria.count) acceptance criteria",
          systemImage: "checklist"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if showsWorkflowActions {
        let transitions = policy.availableTransitions(from: item.state)
          .filter { isOwnerDrivenTransition(from: item.state, to: $0) }
        if !transitions.isEmpty {
          Menu("Move to…") {
            ForEach(transitions, id: \.self) { state in
              Button(state.title) {
                model.transition(item, to: state)
              }
            }
          }
          .font(.caption)
          .menuStyle(.borderlessButton)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      ZStack {
        cardBackground
        if isActivelyWorkedOn || needsOwnerInput {
          ActiveWorkShimmer(
            tint: needsOwnerInput ? .orange : .white
          )
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 11))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
    }
    .contentShape(RoundedRectangle(cornerRadius: 11))
    .onTapGesture {
      onOpen?(item)
    }
  }

  private var ticketIdentity: some View {
    HStack(spacing: 8) {
      Text(item.key)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Label(item.type.title, systemImage: item.type.symbolName)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(item.type.tint)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      SprintPriorityIndicator(priority: item.priority)
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var ticketStatus: some View {
    SprintTicketStatusBadge(
      run: latestRun,
      itemState: item.state,
      candidateStatus: latestCandidate?.status,
      isDependencyBlocked: isDependencyBlocked
    )
  }

  private func isOwnerDrivenTransition(from: WorkItemState, to: WorkItemState) -> Bool {
    switch (from, to) {
    case (.backlog, .refining), (.refining, .ready):
      true
    default:
      false
    }
  }
}

private struct ActiveWorkShimmer: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  let tint: Color

  private let duration: TimeInterval = 2.4

  var body: some View {
    Group {
      if reduceMotion {
        Color.clear
      } else {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
          GeometryReader { geometry in
            let progress =
              context.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: duration) / duration
            let bandWidth = max(72, geometry.size.width * 0.28)
            let travel = geometry.size.width + (bandWidth * 2)

            LinearGradient(
              colors: [
                .clear,
                tint.opacity(
                  colorScheme == .dark
                    ? (tint == .orange ? 0.16 : 0.09)
                    : (tint == .orange ? 0.2 : 0.52)
                ),
                .clear,
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
            .frame(width: bandWidth, height: geometry.size.height * 2.4)
            .rotationEffect(.degrees(18))
            .offset(
              x: -bandWidth + (travel * progress),
              y: -geometry.size.height * 0.7
            )
          }
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct SprintTicketDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceContainerSize) private var containerSize
  let item: WorkItem
  @State private var comments: [TicketComment] = []
  @State private var activityEvents: [ActivityEvent] = []
  @State private var commentDraft = ""
  @State private var isPostingComment = false
  @State private var isAskingQuestion = false
  @State private var isResumingWork = false
  @State private var isAcceptingTicket = false
  @State private var decidingKnowledgeProposalIDs: Set<UUID> = []
  @State private var commentError: String?
  @State private var workLogScrollRequest = 0
  @State private var hasLoadedWorkLog = false
  @State private var isContextExpanded = false
  @FocusState private var isCommentComposerFocused: Bool

  private var currentItem: WorkItem {
    model.workItems.first { $0.id == item.id } ?? item
  }

  private var owner: AgentProfile? {
    let sprintOwnerID = model.sprintPlan?.items
      .first { $0.workItemID == item.id }?.implementerProfileID
    guard let ownerID = sprintOwnerID ?? currentItem.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var prerequisites: [WorkItem] {
    let ids = Set(
      model.dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var dependants: [WorkItem] {
    let ids = Set(
      model.dependencies
        .filter { $0.dependsOnWorkItemID == item.id }
        .map(\.workItemID)
    )
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var contextPages: [KnowledgePage] {
    let runIDsWithContext = Set(model.agentRunKnowledgeContext.map(\.runID))
    let contextRuns = model.runs.filter {
      $0.workItemID == item.id && runIDsWithContext.contains($0.id)
    }
    guard let run = contextRuns.max(by: { $0.updatedAt < $1.updatedAt }) else {
      return []
    }
    let pageIDs = Set(
      model.agentRunKnowledgeContext
        .filter { $0.runID == run.id }
        .map(\.pageID)
    )
    return model.knowledgePages
      .filter { pageIDs.contains($0.id) }
      .sorted { $0.title < $1.title }
  }

  private var currentCandidate: CandidateRevision? {
    model.candidateRevisions
      .filter { $0.workItemID == item.id }
      .max(by: { $0.version < $1.version })
  }

  private var trunkPromotionValue: String {
    guard let candidate = currentCandidate else { return "No candidate" }
    switch candidate.status {
    case .accepted:
      return "Promoted after approval"
    case .readyForDemo:
      return "Awaiting your approval"
    default:
      return "Not promoted"
    }
  }

  private var trunkPromotionSymbol: String {
    currentCandidate?.status == .accepted
      ? "checkmark.circle.fill"
      : "arrow.triangle.branch"
  }

  private var trunkPromotionTint: Color {
    switch currentCandidate?.status {
    case .accepted:
      .green
    case .readyForDemo:
      .orange
    default:
      .secondary
    }
  }

  private var currentKnowledgeProposals: [KnowledgePageProposal] {
    guard let candidateID = currentCandidate?.id else { return [] }
    return model.knowledgePageProposals.filter {
      $0.candidateRevisionID == candidateID
    }
  }

  private var knowledgeProposalsBlockCompletion: Bool {
    currentKnowledgeProposals.contains { $0.status == .proposed }
      || (
        model.requiresKnowledgeApproval
          && currentKnowledgeProposals.contains { $0.status == .reviewed }
      )
  }

  private var detailWidth: CGFloat {
    min(900, max(700, containerSize.width - 140))
  }

  private var detailHeight: CGFloat {
    min(780, max(600, containerSize.height - 110))
  }

  private var boardStatusTitle: String {
    if model.sprintPlan?.sprint.state == .draft,
      model.sprintPlan?.items.contains(where: { $0.workItemID == item.id }) == true
    {
      return "Ready to Pick"
    }
    return switch currentItem.state {
    case .queued: "Ready to Pick"
    case .running: "In Progress"
    case .integrating, .verifying, .readyToRelease: "In Review"
    case .acceptance: "Ready for Demo"
    case .released: "Done"
    default: currentItem.state.title
    }
  }

  private var boardStatusSymbol: String {
    switch boardStatusTitle {
    case "Ready to Pick": "tray.full"
    case "In Progress": "bolt.fill"
    case "In Review": "checkmark.shield"
    case "Ready for Demo": "play.rectangle"
    case "Done": "checkmark.circle.fill"
    default: currentItem.state.activitySymbol
    }
  }

  private var boardStatusTint: Color {
    switch boardStatusTitle {
    case "Ready to Pick": Color(nsColor: .secondaryLabelColor)
    case "In Progress": .blue
    case "In Review": .purple
    case "Ready for Demo": .orange
    case "Done": .green
    default: currentItem.state.activityTint
    }
  }

  private var canPostComment: Bool {
    !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isPostingComment
      && !isAskingQuestion
      && !isResumingWork
  }

  private var awaitingOwnerRun: AgentRun? {
    model.runs
      .filter { $0.workItemID == item.id && $0.status == .awaitingOwner }
      .max { $0.updatedAt < $1.updatedAt }
  }

  private var awaitingOwnerProfile: AgentProfile? {
    guard let awaitingOwnerRun else { return nil }
    return model.profiles.first { $0.id == awaitingOwnerRun.profileID }
  }

  private var pausedQuestionRecipient: AgentProfile? {
    if currentCandidate?.status == .changesRequested,
      let techLead = model.profiles.first(where: { $0.role == .lead })
    {
      return techLead
    }
    return awaitingOwnerProfile
  }

  private var failedDeliveryRun: AgentRun? {
    let latestRun = model.runs
      .filter({
        $0.workItemID == item.id
      })
      .max(by: { $0.updatedAt < $1.updatedAt })
    guard let latestRun else { return nil }
    guard latestRun.status == .failed || latestRun.status == .interrupted else {
      return nil
    }
    return latestRun
  }

  private var failedDeliveryProfile: AgentProfile? {
    guard let failedDeliveryRun else { return nil }
    return model.profiles.first { $0.id == failedDeliveryRun.profileID }
  }

  private var workLogEntries: [SprintWorkLogEntry] {
    let commentEntries = comments
      .filter(isVisibleWorkLogComment)
      .map(SprintWorkLogEntry.comment)
    let eventEntries = activityEvents
      .filter(isVisibleWorkLogEvent)
      .map(SprintWorkLogEntry.event)
    return (commentEntries + eventEntries).sorted {
      if $0.createdAt == $1.createdAt {
        if $0.sortOrder == $1.sortOrder {
          return $0.id < $1.id
        }
        return $0.sortOrder < $1.sortOrder
      }
      return $0.createdAt < $1.createdAt
    }
  }

  private func isVisibleWorkLogComment(_ comment: TicketComment) -> Bool {
    let boilerplate = [
      "I’m starting work on this ticket. I’ll record material progress and any decision I need from you here.",
      "I’m continuing with the latest feedback.",
      "I’m reviewing the implementation and its evidence against the ticket.",
    ]
    return !boilerplate.contains(comment.body)
  }

  private func isVisibleWorkLogEvent(_ event: ActivityEvent) -> Bool {
    switch event.kind {
    case "comment.created", "work_item.ranked",
      "agent_run.queued", "agent_run.running", "agent_run.completed":
      return false
    case "work_item.transitioned":
      let movement = event.detail
        .split(separator: ":", maxSplits: 1)
        .first
        .map(String.init) ?? ""
      let states = movement.components(separatedBy: " -> ")
      guard states.count == 2,
        let from = WorkItemState(
          rawValue: states[0].trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        let to = WorkItemState(
          rawValue: states[1].trimmingCharacters(in: .whitespacesAndNewlines)
        )
      else { return true }
      return workLogPhase(for: from) != workLogPhase(for: to)
    default:
      return true
    }
  }

  private func workLogPhase(for state: WorkItemState) -> Int {
    switch state {
    case .backlog, .refining, .ready: 0
    case .queued: 1
    case .running: 2
    case .integrating, .verifying, .readyToRelease: 3
    case .acceptance: 4
    case .released: 5
    case .cancelled: 6
    }
  }

  private var hasRelationships: Bool {
    !prerequisites.isEmpty || !dependants.isEmpty
  }

  private var hasSupportingRail: Bool {
    !contextPages.isEmpty || currentCandidate != nil
  }

  @ViewBuilder
  private var relationshipsSection: some View {
    SprintTicketSectionCard(title: "Relationships") {
      VStack(alignment: .leading, spacing: 14) {
        if !prerequisites.isEmpty {
          SprintTicketRelationshipRow(
            title: "Blocked by",
            items: prerequisites,
            symbol: "arrow.turn.up.left"
          )
        }
        if !dependants.isEmpty {
          SprintTicketRelationshipRow(
            title: "Blocks",
            items: dependants,
            symbol: "link"
          )
        }
      }
    }
  }

  @ViewBuilder
  private var contextSection: some View {
    SprintTicketSectionCard(title: "Context used") {
      VStack(alignment: .leading, spacing: 10) {
        Label(
          "\(contextPages.count) knowledge page\(contextPages.count == 1 ? "" : "s")",
          systemImage: "books.vertical"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

        if isContextExpanded {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(contextPages) { page in
                contextPageRow(page)
              }
            }
          }
          .frame(height: min(CGFloat(contextPages.count) * 28, 168))
          .scrollIndicators(.visible)
        } else {
          ForEach(Array(contextPages.prefix(3))) { page in
            contextPageRow(page)
          }
        }

        if contextPages.count > 3 {
          Button {
            withAnimation(.easeInOut(duration: 0.16)) {
              isContextExpanded.toggle()
            }
          } label: {
            Label(
              isContextExpanded
                ? "Show less"
                : "Show \(contextPages.count - 3) more",
              systemImage: isContextExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption.weight(.medium))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.indigo)
        }
      }
    }
  }

  private func contextPageRow(_ page: KnowledgePage) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text")
        .font(.caption)
        .foregroundStyle(.indigo)
      Text(page.title)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(page.verificationStatus.title)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private var deliveryRevisionSection: some View {
    if let candidate = currentCandidate {
      SprintTicketSectionCard(title: "Delivery revision") {
        VStack(alignment: .leading, spacing: 10) {
          LazyVGrid(
            columns: Array(
              repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
              count: 5
            ),
            alignment: .leading,
            spacing: 12
          ) {
            SprintTicketMetadata(
              title: "Ticket branch",
              value: candidate.branchName,
              symbol: "arrow.triangle.branch",
              tint: .indigo
            )
            SprintTicketMetadata(
              title: "Candidate",
              value: "\(candidate.shortHeadSHA) · \(candidate.commitCount) commit\(candidate.commitCount == 1 ? "" : "s")",
              symbol: "shippingbox",
              tint: .purple
            )
            if let integratedSHA = candidate.shortIntegratedSHA {
              SprintTicketMetadata(
                title: "Integrated revision",
                value: integratedSHA,
                symbol: "point.3.connected.trianglepath.dotted",
                tint: .green
              )
            }
            SprintTicketMetadata(
              title: "Local trunk",
              value: trunkPromotionValue,
              symbol: trunkPromotionSymbol,
              tint: trunkPromotionTint
            )
            Button {
              model.requestCodebaseFocus(workItemID: currentItem.id)
              dismiss()
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                  .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 1) {
                  Text("Codebase")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  HStack(spacing: 4) {
                    Text("View changes")
                    Image(systemName: "arrow.right")
                  }
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.indigo)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          if candidate.status != .accepted {
            Text(
              "The ticket branch remains isolated from trunk until the reviewed demo is approved."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder
  private var knowledgeProposalsSection: some View {
    if !currentKnowledgeProposals.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 9) {
          Label("Knowledge changes", systemImage: "books.vertical.fill")
            .font(.headline)
            .foregroundStyle(.indigo)
          Spacer()
          Text(knowledgeProposalStatusTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(knowledgeProposalStatusTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(knowledgeProposalStatusTint.opacity(0.1), in: Capsule())
        }

        Text(knowledgeProposalExplanation)
          .font(.callout)
          .foregroundStyle(.secondary)

        ForEach(currentKnowledgeProposals) { proposal in
          let knowledgePage = publishedKnowledgePage(for: proposal)
          CanonicalKnowledgeProposalCard(
            proposal: proposal,
            currentPage: knowledgePage,
            isDeciding: decidingKnowledgeProposalIDs.contains(proposal.id),
            onOpenPage: knowledgePage.map { page in
              {
                model.requestKnowledgeFocus(pageID: page.id)
                dismiss()
              }
            },
            onDecision: { accept in
              decidingKnowledgeProposalIDs.insert(proposal.id)
              Task {
                _ = await model.decideKnowledgePageProposal(
                  proposal,
                  accept: accept
                )
                decidingKnowledgeProposalIDs.remove(proposal.id)
              }
            }
          )
        }
      }
      .padding(17)
      .background(Color.indigo.opacity(0.085), in: RoundedRectangle(cornerRadius: 13))
      .overlay {
        RoundedRectangle(cornerRadius: 13)
          .stroke(Color.indigo.opacity(0.38), lineWidth: 1.25)
      }
    }
  }

  private func publishedKnowledgePage(
    for proposal: KnowledgePageProposal
  ) -> KnowledgePage? {
    if let targetPageID = proposal.targetPageID {
      return model.knowledgePages.first { $0.id == targetPageID }
    }
    guard proposal.status == .accepted else { return nil }
    return model.knowledgePages.last {
      $0.sourceWorkItemID == proposal.workItemID
        && $0.title == proposal.title
    }
  }

  private var knowledgeProposalStatusTitle: String {
    if currentKnowledgeProposals.contains(where: { $0.status == .proposed }) {
      return "Reviewing"
    }
    if currentKnowledgeProposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval ? "Your approval required" : "Publishing"
    }
    if currentKnowledgeProposals.allSatisfy({ $0.status == .accepted }) {
      return "Published"
    }
    return "Review recorded"
  }

  private var knowledgeProposalStatusTint: Color {
    if currentKnowledgeProposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval ? .orange : .indigo
    }
    if currentKnowledgeProposals.allSatisfy({ $0.status == .accepted }) {
      return .green
    }
    return .indigo
  }

  private var knowledgeProposalExplanation: String {
    if currentKnowledgeProposals.contains(where: { $0.status == .proposed }) {
      return "These durable wiki changes travel with the delivery and are currently being checked by the Tech Lead."
    }
    if currentKnowledgeProposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval
        ? "The Tech Lead reviewed these durable wiki changes. Accept or reject each change before completing the ticket."
        : "The Tech Lead reviewed these durable wiki changes. StoryPointless is publishing them automatically."
    }
    if currentKnowledgeProposals.allSatisfy({ $0.status == .accepted }) {
      return "Published automatically after Tech Lead review. Open a page below to read the canonical result in the Knowledge Base."
    }
    return "These proposed changes remain visible as part of the ticket’s delivery history."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: currentItem.type.symbolName)
          .foregroundStyle(currentItem.type.tint)
        Text(currentItem.key)
          .font(.callout.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Text("Ticket details")
          .font(.title2.bold())
        Spacer()
        if currentItem.state == .acceptance {
          Button(isAcceptingTicket ? "Completing…" : "Approve & complete") {
            isAcceptingTicket = true
            Task {
              let didComplete = await model.acceptSprintTicket(currentItem)
              isAcceptingTicket = false
              if didComplete {
                dismiss()
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isAcceptingTicket || knowledgeProposalsBlockCompletion)
          .help(
            knowledgeProposalsBlockCompletion
              ? "Accept or reject every proposed knowledge change first."
              : "Promote this exact reviewed revision to the accepted trunk."
          )
        }
        Button("Close") { dismiss() }
      }
      .padding(.horizontal, 22)
      .frame(height: 64)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            SprintTicketSectionCard(title: "Summary") {
              VStack(alignment: .leading, spacing: 9) {
                Text(currentItem.title)
                  .font(.title2.weight(.semibold))
                  .textSelection(.enabled)
                if currentItem.body.isEmpty {
                  Text("No additional context was recorded.")
                    .foregroundStyle(.secondary)
                } else {
                  Text(currentItem.body)
                    .textSelection(.enabled)
                }
              }
            }

            SprintTicketSectionCard(title: "Details") {
              LazyVGrid(
                columns: Array(
                  repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                  count: 4
                ),
                alignment: .leading,
                spacing: 12
              ) {
                SprintTicketMetadata(
                  title: "Status",
                  value: boardStatusTitle,
                  symbol: boardStatusSymbol,
                  tint: boardStatusTint
                )
                SprintTicketMetadata(
                  title: "Owner",
                  value: owner?.name ?? "Unassigned",
                  symbol: owner?.role.symbolName ?? "person.crop.circle.badge.questionmark",
                  tint: owner?.role.tint ?? Color.secondary
                )
                SprintTicketMetadata(
                  title: "Type",
                  value: currentItem.type.title,
                  symbol: currentItem.type.symbolName,
                  tint: currentItem.type.tint
                )
                SprintTicketMetadata(
                  title: "Priority",
                  value: currentItem.priority.title,
                  symbol: "flag.fill",
                  tint: currentItem.priority.tint
                )
              }
            }

            SprintTicketSectionCard(title: "Acceptance criteria") {
              if currentItem.acceptanceCriteria.isEmpty {
                Label("No acceptance criteria", systemImage: "exclamationmark.circle")
                  .foregroundStyle(.secondary)
              } else {
                VStack(alignment: .leading, spacing: 10) {
                  ForEach(currentItem.acceptanceCriteria, id: \.self) { criterion in
                    HStack(alignment: .top, spacing: 9) {
                      Text("•")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)
                      Text(criterion)
                        .textSelection(.enabled)
                    }
                  }
                }
              }
            }

            knowledgeProposalsSection

            if hasRelationships || hasSupportingRail {
              VStack(alignment: .leading, spacing: 18) {
                if hasRelationships, !contextPages.isEmpty {
                  HStack(alignment: .top, spacing: 18) {
                    relationshipsSection
                    contextSection
                  }
                } else {
                  if hasRelationships {
                    relationshipsSection
                  }
                  if !contextPages.isEmpty {
                    contextSection
                  }
                }

                if currentCandidate != nil {
                  deliveryRevisionSection
                }
              }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Work log")
                  .font(.headline)
                Text(workLogEntries.count.formatted())
                  .font(.caption.monospacedDigit())
                  .padding(.horizontal, 7)
                  .padding(.vertical, 3)
                  .background(.quaternary, in: Capsule())
                Spacer()
                Label("Updates automatically", systemImage: "arrow.clockwise")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              if workLogEntries.isEmpty {
                HStack(spacing: 10) {
                  Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.tertiary)
                  VStack(alignment: .leading, spacing: 2) {
                    Text("No work logged yet")
                      .font(.subheadline.weight(.medium))
                    Text("Comments, assignments, and status changes will appear here.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
              } else {
                VStack(spacing: 0) {
                  ForEach(workLogEntries) { entry in
                    Group {
                      switch entry {
                      case .comment(let comment):
                        SprintTicketCommentRow(
                          comment: comment,
                          authorProfile: model.profiles.first { $0.name == comment.authorName }
                        )
                      case .event(let event):
                        SprintTicketEventRow(
                          event: event,
                          profiles: model.profiles,
                          retrospectiveNotes: model.retrospectiveNotes
                        )
                      }
                    }
                    .id(entry.id)
                  }
                }
              }
            }

            Color.clear
              .frame(height: 1)
              .id("work-log-bottom")
          }
          .padding(24)
        }
        .onChange(of: workLogScrollRequest) {
          Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo("work-log-bottom", anchor: .bottom)
            }
          }
        }
      }

      Divider()

      commentComposer
    }
    .frame(width: detailWidth, height: detailHeight)
    .task {
      while !Task.isCancelled {
        let previousLastEntryID = workLogEntries.last?.id
        comments = await model.comments(for: item.id)
        activityEvents = await model.activityEvents(for: item.id)
        let latestEntryID = workLogEntries.last?.id
        if !hasLoadedWorkLog || latestEntryID != previousLastEntryID {
          workLogScrollRequest += 1
        }
        hasLoadedWorkLog = true
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private var commentComposer: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.blue.opacity(0.12))
        Image(systemName: "person.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.blue)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 7) {
        if let awaitingOwnerProfile {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
              Image(systemName: "pause.circle.fill")
              Text(awaitingOwnerProfile.name)
                .fontWeight(.semibold)
              Text("is paused and waiting for direction.")
            }
            Text("Ask a question without restarting work, or add direction and choose Resume work.")
              .foregroundStyle(.secondary)
          }
          .font(.caption)
          .foregroundStyle(.orange)
        } else if let failedDeliveryProfile {
          HStack(spacing: 7) {
            Image(systemName: "arrow.clockwise.circle.fill")
            Text(failedDeliveryProfile.name)
              .fontWeight(.semibold)
            Text("stopped unexpectedly. Add direction, then choose Retry work.")
          }
          .font(.caption)
          .foregroundStyle(.red)
        } else if currentItem.state == .acceptance {
          Label(
            "Approve the demo above, or add feedback and choose Request changes.",
            systemImage: "play.rectangle"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }

        Text("Add a comment")
          .font(.subheadline.weight(.semibold))

        ZStack(alignment: .topLeading) {
          if commentDraft.isEmpty && !isCommentComposerFocused {
            Text("Add context, answer a question, or give feedback…")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
          TextEditor(text: $commentDraft)
            .scrollContentBackground(.hidden)
            .font(.body)
            .focused($isCommentComposerFocused)
            .padding(8)
            .onKeyPress(phases: .down) { keyPress in
              guard keyPress.key == .return else { return .ignored }
              if keyPress.modifiers.contains(.shift) {
                return .ignored
              }
              if canPostComment {
                postComment()
              }
              return .handled
            }
        }
        .frame(height: 58)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }

        HStack {
          if let commentError {
            Label(commentError, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          } else {
            Text("Return to comment · Shift-Return for a new line")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Spacer()
          if awaitingOwnerProfile != nil {
            Button(isPostingComment ? "Commenting…" : "Comment") {
              postComment()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canPostComment)

            if let pausedQuestionRecipient {
              Button(
                isAskingQuestion ? "Asking…" : "Ask \(pausedQuestionRecipient.name)"
              ) {
                askQuestion(to: pausedQuestionRecipient)
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .disabled(!canPostComment)
            }

            Button(isResumingWork ? "Resuming…" : "Resume work") {
              resumeWork()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canPostComment)
          } else if failedDeliveryProfile != nil {
            Button(isPostingComment ? "Commenting…" : "Comment") {
              postComment()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canPostComment)

            Button(isResumingWork ? "Retrying…" : "Retry work") {
              resumeWork()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canPostComment)
          } else if currentItem.state == .acceptance {
            Button(isPostingComment ? "Commenting…" : "Comment") {
              postComment()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canPostComment)

            Button(isResumingWork ? "Sending…" : "Request changes") {
              resumeWork()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canPostComment)
          } else {
            Button(isPostingComment ? "Commenting…" : "Comment") {
              postComment()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canPostComment)
          }
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
    .background(.quaternary.opacity(0.18))
  }

  private func postComment() {
    let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isPostingComment else { return }
    commentDraft = ""
    commentError = nil
    isPostingComment = true

    Task {
      if let comment = await model.appendSprintWorkLogComment(
        workItemID: item.id,
        body: body
      ) {
        if !comments.contains(where: { $0.id == comment.id }) {
          comments.append(comment)
          comments.sort {
            if $0.createdAt == $1.createdAt {
              return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
          }
        }
        workLogScrollRequest += 1
      } else {
        commentDraft = body
        commentError = "Your comment couldn't be saved. Try again."
      }
      isPostingComment = false
    }
  }

  private func askQuestion(to recipient: AgentProfile) {
    let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isAskingQuestion else { return }
    commentDraft = ""
    commentError = nil
    isAskingQuestion = true

    Task {
      let attributedBody = "@\(recipient.name) \(body)"
      guard
        let comment = await model.appendOwnerComment(
          workItemID: item.id,
          body: attributedBody
        )
      else {
        commentDraft = body
        commentError = "Your question couldn't be saved. Try again."
        isAskingQuestion = false
        return
      }
      appendLocalComment(comment)
      workLogScrollRequest += 1

      do {
        _ = try await model.sendTicketConversationMessage(
          for: currentItem,
          to: recipient,
          ownerMessage: body,
          allowsProposal: false
        )
        comments = await model.comments(for: item.id)
        workLogScrollRequest += 1
      } catch {
        commentError = error.localizedDescription
      }
      isAskingQuestion = false
    }
  }

  private func resumeWork() {
    let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isResumingWork else { return }
    commentDraft = ""
    commentError = nil
    isResumingWork = true

    Task {
      if let comment = await model.resumeSprintWork(
        workItemID: item.id,
        body: body
      ) {
        appendLocalComment(comment)
        workLogScrollRequest += 1
      } else {
        commentDraft = body
        commentError = "Your direction couldn't be saved. Try again."
      }
      isResumingWork = false
    }
  }

  private func appendLocalComment(_ comment: TicketComment) {
    guard !comments.contains(where: { $0.id == comment.id }) else { return }
    comments.append(comment)
    comments.sort {
      if $0.createdAt == $1.createdAt {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.createdAt < $1.createdAt
    }
  }
}

private struct CanonicalKnowledgeProposalCard: View {
  let proposal: KnowledgePageProposal
  let currentPage: KnowledgePage?
  let isDeciding: Bool
  let onOpenPage: (() -> Void)?
  let onDecision: (Bool) -> Void
  @State private var isExpanded = false

  private var isPending: Bool {
    proposal.status == .proposed || proposal.status == .reviewed
  }

  private var sourceChanged: Bool {
    guard isPending, proposal.operation == .update, let currentPage else { return false }
    return currentPage.title != proposal.basePageTitle
      || currentPage.bodyMarkdown != proposal.basePageBodyMarkdown
  }

  private var statusTitle: String {
    switch proposal.status {
    case .proposed: "Awaiting Tech Lead"
    case .reviewed: "Decision required"
    case .accepted: "Published"
    case .rejected: "Rejected"
    case .superseded: "Superseded"
    }
  }

  private var statusTint: Color {
    switch proposal.status {
    case .proposed: .secondary
    case .reviewed: .orange
    case .accepted: .green
    case .rejected, .superseded: .secondary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 9) {
        Text(proposal.operation == .create ? "New page" : "Update page")
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.indigo.opacity(0.12), in: Capsule())
          .foregroundStyle(.indigo)
        Text(proposal.title)
          .font(.headline)
        Spacer()
        Text(statusTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusTint)
      }

      Text(proposal.rationale)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if sourceChanged {
        Label(
          "A newer version of this page was published after this proposal was prepared. Dismiss this stale proposal; rerun the ticket only if its missing change is still needed.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      if isPending {
        DisclosureGroup(isExpanded: $isExpanded) {
          VStack(alignment: .leading, spacing: 14) {
            if proposal.operation == .update {
              VStack(alignment: .leading, spacing: 6) {
                Text("Current page")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                TicketMarkdownDocument(
                  source: currentPage?.bodyMarkdown
                    ?? proposal.basePageBodyMarkdown
                    ?? "The source page is unavailable.",
                  baseFont: .callout
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
              }
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("Proposed complete page")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
              TicketMarkdownDocument(
                source: proposal.proposedBodyMarkdown,
                baseFont: .callout
              )
              .font(.callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
          }
          .padding(.top, 10)
        } label: {
          Text(isExpanded ? "Hide rendered preview" : "Review rendered preview")
            .font(.callout.weight(.medium))
        }
      } else if let onOpenPage {
        Button(action: onOpenPage) {
          HStack(spacing: 7) {
            Image(systemName: "books.vertical")
            Text("Open in Knowledge Base")
            Spacer()
            Image(systemName: "arrow.right")
          }
          .font(.callout.weight(.semibold))
          .foregroundStyle(.indigo)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      if isPending {
        HStack {
          Spacer()
          Button(sourceChanged ? "Dismiss stale proposal" : "Reject") {
            onDecision(false)
          }
          .disabled(isDeciding)
          Button(isDeciding ? "Applying…" : "Accept") { onDecision(true) }
            .buttonStyle(.borderedProminent)
            .disabled(isDeciding || proposal.status == .proposed || sourceChanged)
        }
      }
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
    }
  }
}

private struct SprintTicketSectionCard<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SprintTicketMetadata: View {
  let title: String
  let value: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private enum SprintWorkLogEntry: Identifiable {
  case comment(TicketComment)
  case event(ActivityEvent)

  var id: String {
    switch self {
    case .comment(let comment): "comment-\(comment.id.uuidString)"
    case .event(let event): "event-\(event.id.uuidString)"
    }
  }

  var createdAt: Date {
    switch self {
    case .comment(let comment): comment.createdAt
    case .event(let event): event.createdAt
    }
  }

  var sortOrder: Int {
    switch self {
    case .event: 0
    case .comment: 1
    }
  }
}

private struct SprintTicketEventRow: View {
  let event: ActivityEvent
  let profiles: [AgentProfile]
  let retrospectiveNotes: [RetrospectiveNote]

  private var assignedProfile: AgentProfile? {
    guard
      event.kind == "work_item.owner_assigned",
      let profileID = UUID(uuidString: event.detail)
    else { return nil }
    return profiles.first { $0.id == profileID }
  }

  private var actorProfile: AgentProfile? {
    if event.kind == "agent_run.running",
      let returnedOwner = profiles.first(where: {
        event.detail.localizedCaseInsensitiveContains("returning work to \($0.name)")
      })
    {
      return returnedOwner
    }
    return profiles.first { $0.name == event.actor }
  }

  private var actorName: String {
    if let actorProfile {
      return actorProfile.name
    }
    return switch event.actor.lowercased() {
    case "owner", "product owner": "Me"
    case "system": "StoryPointless"
    case "sprint scheduler": "Sprint scheduler"
    default: event.actor
    }
  }

  private var isOwnerActor: Bool {
    ["me", "owner", "product owner"].contains(event.actor.lowercased())
  }

  private var transitionDestination: String? {
    guard event.kind == "work_item.transitioned" else { return nil }
    let movement = event.detail.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    let rawState = movement.components(separatedBy: " -> ").last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rawState, !rawState.isEmpty else { return nil }
    return rawState
  }

  private var destinationTitle: String? {
    guard let transitionDestination else { return nil }
    guard let state = WorkItemState(rawValue: transitionDestination) else {
      return transitionDestination.replacingOccurrences(of: "_", with: " ").capitalized
    }
    return switch state {
    case .queued: "Ready to Pick"
    case .running: "In Progress"
    case .integrating, .verifying, .readyToRelease: "In Review"
    case .acceptance: "Ready for Demo"
    case .released: "Done"
    case .backlog: "Backlog"
    case .refining: "Refining"
    case .ready: "Ready"
    case .cancelled: "Cancelled"
    }
  }

  private var transitionState: WorkItemState? {
    transitionDestination.flatMap { WorkItemState(rawValue: $0) }
  }

  private var title: String {
    switch event.kind {
    case "work_item.created":
      "Ticket created"
    case "work_item.created_from_suggestion":
      "Suggested ticket accepted"
    case "work_item.updated":
      "Ticket details updated"
    case "work_item.owner_assigned":
      assignedProfile.map { "Assigned to \($0.name)" } ?? "Ticket unassigned"
    case "work_item.ranked":
      "Backlog position changed"
    case "work_item.archived":
      "Ticket archived"
    case "work_item.queued":
      "Moved to Ready to Pick"
    case "agent_run.queued":
      "Queued to resume"
    case "agent_run.running":
      "Resumed work"
    case "agent_run.awaiting_owner":
      "Waiting for your response"
    case "agent_run.interrupted":
      "Run interrupted"
    case "agent_run.failed":
      "Run failed"
    case "agent_run.completed":
      "Run completed"
    case "retrospective.action_promoted_to_practice":
      "Added to Ways of working"
    case "work_item.transitioned":
      switch transitionState {
      case .some(.running):
        event.detail.localizedCaseInsensitiveContains("review changes requested")
          ? "Changes requested"
          : "Started work"
      case .some(.acceptance): "Submitted for demo"
      case .some(.released): "Completed ticket"
      case .some(.cancelled): "Cancelled ticket"
      default: destinationTitle.map { "Moved to \($0)" } ?? "Status changed"
      }
    default:
      event.kind
        .split(separator: ".")
        .last
        .map(String.init)?
        .replacingOccurrences(of: "_", with: " ")
        .capitalized ?? "Ticket updated"
    }
  }

  private var detail: String? {
    switch event.kind {
    case "work_item.created", "work_item.created_from_suggestion",
      "work_item.owner_assigned":
      return nil
    case "work_item.updated":
      let trimmed = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.hasPrefix("Changed ") || trimmed == "Saved without field changes"
        ? trimmed
        : nil
    case "work_item.transitioned":
      let parts = event.detail.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      let reason = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      return reason.isEmpty ? nil : reason
    case "retrospective.action_promoted_to_practice":
      let trimmed = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if let noteID = UUID(uuidString: trimmed) {
        return retrospectiveNotes.first { $0.id == noteID }?.body
      }
      return trimmed
    default:
      let trimmed = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  private var actorTint: Color {
    if let actorProfile {
      return actorProfile.role.tint
    }
    return isOwnerActor ? .blue : .secondary
  }

  private var actorSymbolName: String {
    if let actorProfile {
      return actorProfile.role.symbolName
    }
    if isOwnerActor {
      return "person.fill"
    }
    switch event.actor.lowercased() {
    case "system", "sprint scheduler":
      return "gearshape.fill"
    default:
      return "person.crop.circle.fill"
    }
  }

  private var eventTint: Color {
    if let assignedProfile {
      return assignedProfile.role.tint
    }
    return switch event.kind {
    case "work_item.created", "work_item.created_from_suggestion": .blue
    case "work_item.owner_assigned": .indigo
    case "work_item.archived": .red
    case "work_item.queued": Color(nsColor: .secondaryLabelColor)
    case "agent_run.awaiting_owner": .orange
    case "agent_run.failed": .red
    case "agent_run.interrupted": .orange
    case "agent_run.completed": .green
    case "retrospective.action_promoted_to_practice": .purple
    case "agent_run.queued": Color(nsColor: .secondaryLabelColor)
    case "agent_run.running": .blue
    case "work_item.transitioned":
      switch transitionState {
      case .some(.running): .blue
      case .some(.acceptance): .purple
      case .some(.released): .green
      case .some(.cancelled): .red
      default: .indigo
      }
    default: .secondary
    }
  }

  private var eventSymbolName: String {
    switch event.kind {
    case "work_item.created", "work_item.created_from_suggestion": "plus"
    case "work_item.updated": "pencil"
    case "work_item.owner_assigned": assignedProfile?.role.symbolName ?? "person.crop.circle"
    case "work_item.ranked": "arrow.up.arrow.down"
    case "work_item.archived": "archivebox"
    case "work_item.queued": "tray.full"
    case "agent_run.queued": "clock"
    case "agent_run.running": "bolt.fill"
    case "agent_run.awaiting_owner": "hand.raised.fill"
    case "agent_run.interrupted": "pause.circle.fill"
    case "agent_run.failed": "exclamationmark.triangle.fill"
    case "agent_run.completed": "checkmark.circle.fill"
    case "retrospective.action_promoted_to_practice": "person.2.badge.gearshape"
    case "work_item.transitioned":
      switch transitionState {
      case .some(.running): "bolt.fill"
      case .some(.acceptance): "play.rectangle"
      case .some(.released): "checkmark"
      case .some(.cancelled): "xmark"
      default: "arrow.right"
      }
    default: "clock.arrow.circlepath"
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(actorTint.opacity(0.12))
        Image(systemName: actorSymbolName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(actorTint)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(actorName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(actorProfile == nil ? Color.primary : actorTint)
          Text(
            event.createdAt,
            format: .dateTime.day().month(.abbreviated).hour().minute()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Label(title, systemImage: eventSymbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(eventTint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(eventTint.opacity(0.1), in: Capsule())
        }
        if let detail {
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(0.55))
        .frame(height: 1)
        .padding(.leading, 46)
    }
  }
}

private struct SprintTicketCommentRow: View {
  let comment: TicketComment
  let authorProfile: AgentProfile?

  private var accent: Color {
    switch comment.authorKind {
    case .owner: .blue
    case .agent: authorProfile?.role.tint ?? .indigo
    case .system: .secondary
    }
  }

  private var symbolName: String {
    switch comment.authorKind {
    case .owner: "person.fill"
    case .agent: authorProfile?.role.symbolName ?? "sparkles"
    case .system: "gearshape.fill"
    }
  }

  private var authorName: String {
    comment.authorKind == .owner ? "Me" : comment.authorName
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(accent.opacity(0.12))
        Image(systemName: symbolName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(accent)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(authorName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(comment.authorKind == .agent ? accent : Color.primary)
          Text(
            comment.createdAt,
            format: .dateTime.day().month(.abbreviated).hour().minute()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        TicketMarkdownDocument(
          source: comment.body,
          baseFont: .body
        )
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(0.55))
        .frame(height: 1)
        .padding(.leading, 46)
    }
  }
}

private struct TicketMarkdownDocument: View {
  let source: String
  let baseFont: Font
  var highlightedText: String?
  var highlightedColor: Color?

  private var blocks: [KnowledgeMarkdown.Block] {
    KnowledgeMarkdown.blocks(in: source, removesLeadingTitle: false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private func blockView(_ block: KnowledgeMarkdown.Block) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inlineMarkdown(text))
        .font(headingFont(level))
        .fixedSize(horizontal: false, vertical: true)
    case .paragraph(let lines):
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(inlineMarkdown(line))
            .font(baseFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("•")
              .foregroundStyle(.secondary)
            Text(inlineMarkdown(item))
              .font(baseFont)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .layoutPriority(1)
          }
        }
      }
      .padding(.leading, 3)
    case .orderedList(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(index + 1).")
              .font(baseFont)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .frame(minWidth: 18, alignment: .trailing)
            Text(inlineMarkdown(item))
              .font(baseFont)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .layoutPriority(1)
          }
        }
      }
    case .quote(let lines):
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 1)
          .fill(Color.accentColor.opacity(0.5))
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(inlineMarkdown(line))
              .font(baseFont)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .foregroundStyle(.secondary)
      }
    case .code(let code):
      ScrollView(.horizontal) {
        Text(code)
          .font(.caption.monospaced())
          .padding(9)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    case .divider:
      Divider()
    }
  }

  private func inlineMarkdown(_ source: String) -> AttributedString {
    var attributed = (try? AttributedString(markdown: source)) ?? AttributedString(source)
    if
      let highlightedText,
      let highlightedColor,
      let range = attributed.range(of: highlightedText)
    {
      attributed[range].foregroundColor = highlightedColor
      attributed[range].font = baseFont.bold()
    }
    return attributed
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title3.bold()
    case 2: .headline
    default: .subheadline.bold()
    }
  }
}

private struct SprintTicketRelationshipRow: View {
  let title: String
  let items: [WorkItem]
  let symbol: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: symbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(items) { item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.key)
              .font(.caption.monospaced().weight(.semibold))
              .foregroundStyle(.secondary)
            Text("·")
              .foregroundStyle(.tertiary)
            Text(item.title)
              .font(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 3)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SprintPlanningView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onSaved: () -> Void
  @State private var goal = ""
  @State private var didPrepare = false
  @State private var isSaving = false

  private var sprintNumber: Int {
    model.candidateSprintPlan?.sprint.number ?? 1
  }

  private var scopedItems: [WorkItem] {
    guard let plan = model.candidateSprintPlan else { return [] }
    let ids = Set(plan.items.map(\.workItemID))
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var sprintItemsByWorkItemID: [UUID: SprintItem] {
    Dictionary(
      uniqueKeysWithValues: (model.candidateSprintPlan?.items ?? []).map {
        ($0.workItemID, $0)
      }
    )
  }

  private var waves: [[SprintPlanningLine]] {
    let scopedIDs = Set(scopedItems.map(\.id))
    let dependenciesByItem = Dictionary(
      grouping: model.dependencies.filter {
        scopedIDs.contains($0.workItemID) && scopedIDs.contains($0.dependsOnWorkItemID)
      },
      by: \.workItemID
    )
    var waveByItem: [UUID: Int] = [:]
    var remaining = scopedItems
    while !remaining.isEmpty {
      var progressed = false
      for item in remaining {
        let prerequisiteIDs = dependenciesByItem[item.id, default: []].map(
          \.dependsOnWorkItemID
        )
        guard prerequisiteIDs.allSatisfy({ waveByItem[$0] != nil }) else { continue }
        waveByItem[item.id] = (prerequisiteIDs.compactMap { waveByItem[$0] }.max() ?? 0) + 1
        remaining.removeAll { $0.id == item.id }
        progressed = true
      }
      if !progressed {
        let fallback = (waveByItem.values.max() ?? 0) + 1
        for item in remaining {
          waveByItem[item.id] = fallback
        }
        remaining.removeAll()
      }
    }

    let lines = scopedItems.map { item in
      SprintPlanningLine(
        item: item,
        owner: resolvedOwner(for: item),
        forecast: SprintForecast.estimate(for: item),
        wave: waveByItem[item.id] ?? 1,
        risks: risks(for: item, scopedIDs: scopedIDs)
      )
    }
    return Dictionary(grouping: lines, by: \.wave)
      .sorted { $0.key < $1.key }
      .map { $0.value.sorted { $0.item.rank < $1.item.rank } }
  }

  private var lines: [SprintPlanningLine] {
    waves.flatMap { $0 }
  }

  private var totalTokenLow: Int {
    lines.reduce(0) { $0 + $1.forecast.tokenLow }
  }

  private var totalTokenHigh: Int {
    lines.reduce(0) { $0 + $1.forecast.tokenHigh }
  }

  private var elapsedLowMinutes: Int {
    waves.reduce(0) { total, wave in
      total + (wave.map(\.forecast.durationLowMinutes).max() ?? 0)
    }
  }

  private var elapsedHighMinutes: Int {
    waves.reduce(0) { total, wave in
      total + (wave.map(\.forecast.durationHighMinutes).max() ?? 0)
    }
  }

  private var riskCount: Int {
    lines.reduce(0) { $0 + $1.risks.count }
  }

  private var concurrencyLimit: Int {
    max(1, waves.map(\.count).max() ?? 1)
  }

  private var canSave: Bool {
    !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !lines.isEmpty
      && lines.allSatisfy { $0.owner != nil && !$0.item.acceptanceCriteria.isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Plan Sprint \(sprintNumber)")
            .font(.title.bold())
          Text("Confirm the outcome, delivery order, and forecast for the sprint as a whole.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Close") { isPresented = false }
      }

      if scopedItems.isEmpty {
        ContentUnavailableView(
          "No tickets in Sprint \(sprintNumber)",
          systemImage: "checklist.unchecked",
          description: Text("Return to the backlog and drag work into the sprint first.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(alignment: .leading, spacing: 7) {
          Text("Sprint goal")
            .font(.caption.weight(.semibold))
          TextField("What valuable outcome should this sprint deliver?", text: $goal)
            .textFieldStyle(.roundedBorder)
            .font(.body)
        }

        HStack(spacing: 10) {
          SprintPlanningMetric(
            title: "Scope",
            value: "\(lines.count) \(lines.count == 1 ? "ticket" : "tickets")",
            detail: "ranked backlog order",
            symbol: "checklist"
          )
          SprintPlanningMetric(
            title: "Execution",
            value: "\(waves.count) \(waves.count == 1 ? "wave" : "waves")",
            detail: "all eligible work starts together",
            symbol: "point.3.connected.trianglepath.dotted"
          )
          SprintPlanningMetric(
            title: "Token forecast",
            value: "\(compactTokens(totalTokenLow))–\(compactTokens(totalTokenHigh))",
            detail: "planning range",
            symbol: "gauge.with.dots.needle.33percent"
          )
          SprintPlanningMetric(
            title: "Elapsed time",
            value: "\(duration(elapsedLowMinutes))–\(duration(elapsedHighMinutes))",
            detail: "agent work, not a deadline",
            symbol: "clock"
          )
          SprintPlanningMetric(
            title: "Risks",
            value: riskCount == 0 ? "No flags" : "\(riskCount) flagged",
            detail: "review before saving",
            symbol: riskCount == 0 ? "checkmark.shield" : "exclamationmark.triangle"
          )
        }

        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("Sprint scope")
                  .font(.headline)
                Text("Owners were selected from the artifact each refined ticket is meant to produce.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text("Priority and order come from the backlog")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(Array(waves.enumerated()), id: \.offset) { waveIndex, wave in
                  SprintPlanningWave(
                    number: waveIndex + 1,
                    lines: wave,
                    isLast: waveIndex == waves.count - 1
                  )
                }
              }
            }
          }
          .background(.background, in: RoundedRectangle(cornerRadius: 14))
          .overlay {
            RoundedRectangle(cornerRadius: 14)
              .stroke(.separator.opacity(0.65), lineWidth: 1)
          }

          VStack(alignment: .leading, spacing: 14) {
            Label("Planning analysis", systemImage: "chart.bar.doc.horizontal")
              .font(.headline)

            PlanningAnalysisRow(
              title: "Parallel delivery",
              detail: executionSummary,
              symbol: "arrow.triangle.branch"
            )
            PlanningAnalysisRow(
              title: "Review strategy",
              detail: "The Tech Lead reviews implementation work during execution; the Product Owner approves each demo.",
              symbol: "checkmark.bubble"
            )
            PlanningAnalysisRow(
              title: "Forecast confidence",
              detail: "Broad until completed runs calibrate this product. Ranges include implementation and verification.",
              symbol: "waveform.path.ecg"
            )

            if riskCount > 0 {
              Divider()
              Text("Attention needed")
                .font(.subheadline.weight(.semibold))
              ForEach(lines.filter { !$0.risks.isEmpty }) { line in
                VStack(alignment: .leading, spacing: 3) {
                  Text(line.item.key)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                  ForEach(line.risks, id: \.self) { risk in
                    Text(risk)
                      .font(.caption)
                  }
                }
              }
            }

            Spacer()
            Text("Planning does not rewrite refined tickets. Edit them in the Sprint or Backlog section of the Backlog view, then reopen this plan.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(18)
          .frame(width: 300, alignment: .topLeading)
          .frame(maxHeight: .infinity)
          .background(.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        }
      }

      Divider()

      HStack {
        if !canSave && !lines.isEmpty {
          Label(saveBlockerText, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Text("Estimates are forecasts, not token budgets.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { isPresented = false }
        .disabled(isSaving)
        Button {
          savePlan()
        } label: {
          if isSaving {
            HStack(spacing: 7) {
              ProgressView()
                .controlSize(.small)
              Text("Saving Plan…")
            }
          } else {
            Text("Save Plan & Open Board")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave || isSaving)
      }
    }
    .padding(26)
    .frame(minWidth: 1_000, idealWidth: 1_160, minHeight: 680, idealHeight: 780)
    .onAppear(perform: prepare)
  }

  private var executionSummary: String {
    guard let widest = waves.map(\.count).max(), widest > 1 else {
      return "Dependencies require mostly sequential delivery across \(waves.count) waves."
    }
    return "The dependency graph allows up to \(widest) tickets to run together across \(waves.count) waves."
  }

  private var saveBlockerText: String {
    if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Add a sprint goal."
    }
    if lines.contains(where: { $0.owner == nil }) {
      return "One or more tickets have no eligible delivery owner."
    }
    return "Every sprint ticket needs acceptance criteria."
  }

  private func prepare() {
    guard !didPrepare else { return }
    didPrepare = true
    goal = model.candidateSprintPlan?.sprint.goal ?? "Next valuable increment"
  }

  private func savePlan() {
    guard !isSaving else { return }
    isSaving = true
    let inputs = lines.compactMap { line -> SprintDraftItemInput? in
      guard let owner = line.owner else { return nil }
      return SprintDraftItemInput(
        workItemID: line.item.id,
        implementerProfileID: owner.id,
        estimatedTokens: line.forecast.tokenMidpoint
      )
    }
    Task {
      let saved = await model.saveSprintPlan(
        goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
        concurrencyLimit: concurrencyLimit,
        items: inputs
      )
      isSaving = false
      guard saved else { return }
      isPresented = false
      onSaved()
    }
  }

  private func resolvedOwner(for item: WorkItem) -> AgentProfile? {
    let plannedOwnerID = sprintItemsByWorkItemID[item.id]?.implementerProfileID
    if let ownerID = plannedOwnerID ?? item.ownerProfileID,
      let owner = model.profiles.first(where: { $0.id == ownerID })
    {
      return owner
    }
    return TicketOwnerRouter.owner(for: item, profiles: model.profiles)
  }

  private func risks(for item: WorkItem, scopedIDs: Set<UUID>) -> [String] {
    var values: [String] = []
    if resolvedOwner(for: item) == nil {
      values.append("No eligible delivery owner")
    }
    if item.acceptanceCriteria.isEmpty {
      values.append("Acceptance criteria are missing")
    }
    let externalBlockers = model.dependencies.filter {
      $0.workItemID == item.id && !scopedIDs.contains($0.dependsOnWorkItemID)
    }
    for edge in externalBlockers {
      guard
        let blocker = model.workItems.first(where: { $0.id == edge.dependsOnWorkItemID }),
        blocker.state != .released
      else { continue }
      values.append("Blocked by \(blocker.key) outside this sprint")
    }
    return values
  }

  private func compactTokens(_ value: Int) -> String {
    value >= 1_000
      ? String(format: "%.0fk", Double(value) / 1_000)
      : value.formatted()
  }

  private func duration(_ minutes: Int) -> String {
    if minutes < 60 {
      return "\(minutes)m"
    }
    let hours = Double(minutes) / 60
    return String(format: hours < 10 ? "%.1fh" : "%.0fh", hours)
  }
}

private struct SprintPlanningLine: Identifiable {
  let item: WorkItem
  let owner: AgentProfile?
  let forecast: TicketForecast
  let wave: Int
  let risks: [String]

  var id: UUID { item.id }
}

private struct SprintPlanningMetric: View {
  let title: String
  let value: String
  let detail: String
  let symbol: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: symbol)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
        .lineLimit(1)
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
  }
}

private struct SprintPlanningWave: View {
  let number: Int
  let lines: [SprintPlanningLine]
  let isLast: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        Text("WAVE \(number)")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
        Text(number == 1 ? "Starts immediately" : "Starts when prerequisites finish")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        if lines.count > 1 {
          Label("\(lines.count) parallel", systemImage: "arrow.left.and.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.quaternary.opacity(0.25))

      ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
        SprintPlanningTicketRow(line: line)
        if index != lines.count - 1 {
          Divider().padding(.leading, 66)
        }
      }
      if !isLast {
        Divider()
      }
    }
  }
}

private struct SprintPlanningTicketRow: View {
  let line: SprintPlanningLine

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: line.item.type.symbolName)
        .foregroundStyle(line.item.type.tint)
        .frame(width: 18)
      Text(line.item.key)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        Text(line.item.title)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        if let firstRisk = line.risks.first {
          Label(firstRisk, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
      Spacer(minLength: 8)
      if let owner = line.owner {
        Label(owner.name, systemImage: owner.role.symbolName)
          .font(.caption.weight(.medium))
          .foregroundStyle(owner.role.tint)
          .lineLimit(1)
          .frame(width: 132, alignment: .leading)
      } else {
        Text("Unassigned")
          .font(.caption)
          .foregroundStyle(.orange)
          .frame(width: 132, alignment: .leading)
      }
      Text(line.item.priority.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(line.item.priority.tint)
        .frame(width: 54, alignment: .leading)
      VStack(alignment: .trailing, spacing: 2) {
        Text(
          "\(line.forecast.tokenLow / 1_000)–\(line.forecast.tokenHigh / 1_000)k"
        )
        .font(.caption.monospacedDigit().weight(.medium))
        Text("tokens")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .frame(width: 62, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }
}

private struct PlanningAnalysisRow: View {
  let title: String
  let detail: String
  let symbol: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(.indigo)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct LegacySprintPlanningView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var goal = ""
  @State private var concurrencyLimit = 4
  @State private var selections: [UUID: TicketPlanSelection] = [:]
  @State private var currentIndex = 0
  @State private var showingSummary = false
  @State private var didPrepare = false
  @State private var ticketDrafts: [UUID: SprintPlanningTicketDraft] = [:]
  @State private var commentsByItemID: [UUID: [TicketComment]] = [:]
  @State private var recipientByItemID: [UUID: UUID] = [:]
  @State private var messageByItemID: [UUID: String] = [:]
  @State private var conversationErrorsByItemID: [UUID: String] = [:]
  @State private var pendingProposals: [UUID: PendingPlanningProposal] = [:]
  @State private var sendingMessageItemID: UUID?
  @State private var savingTicketItemID: UUID?
  @State private var ticketSaveErrorsByItemID: [UUID: String] = [:]
  @FocusState private var focusedPlanningComposerItemID: UUID?

  private var readyItems: [WorkItem] {
    guard let plan = model.candidateSprintPlan else { return [] }
    let candidateIDs = Set(plan.items.map(\.workItemID))
    return model.workItems.filter { candidateIDs.contains($0.id) }
  }

  private var implementers: [AgentProfile] {
    model.profiles.filter { $0.role.canImplement }
  }

  private var defaultConversationRecipient: AgentProfile? {
    model.profiles.first { $0.role == .lead }
      ?? model.profiles.first { $0.role == .businessAnalyst }
      ?? model.profiles.first
  }

  private var isCodexConnected: Bool {
    if case .connected = model.codexConnectionState { return true }
    return false
  }

  private var canSave: Bool {
    !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !readyItems.isEmpty
      && readyItems.allSatisfy { selections[$0.id]?.implementerID != nil }
      && !hasDirtyTicketDrafts
      && pendingProposals.isEmpty
      && !model.isPlanningMessageRunning
  }

  private var hasDirtyTicketDrafts: Bool {
    readyItems.contains { item in
      guard let draft = ticketDrafts[item.id] else { return false }
      return draft.snapshot != SprintPlanningTicketSnapshot(item: item)
    }
  }

  private var currentWorkItemID: UUID? {
    guard !showingSummary, readyItems.indices.contains(currentIndex) else { return nil }
    return readyItems[currentIndex].id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(model.candidateSprintPlan == nil ? "Sprint Planning" : "Review Sprint Plan")
            .font(.title.bold())
          Text(
            showingSummary
              ? "Review the complete plan before saving it."
              : "Resolve each ticket with the team; you remain in control of every change."
          )
          .foregroundStyle(.secondary)
        }
        Spacer()
        if !readyItems.isEmpty {
          Text(
            showingSummary
              ? "Plan summary" : "Ticket \(currentIndex + 1) of \(readyItems.count)"
          )
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      }

      Divider()

      if readyItems.isEmpty {
        ContentUnavailableView(
          "No tickets in the next sprint",
          systemImage: "checklist.unchecked",
          description: Text("Return to the backlog and drag work into the next sprint first.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if showingSummary {
        summaryView
      } else {
        ticketReview(readyItems[currentIndex])
      }

      Divider()

      HStack {
        Text("\(readyItems.count) sprint \(readyItems.count == 1 ? "ticket" : "tickets")")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button("Discard changes") { isPresented = false }
          .disabled(model.isPlanningMessageRunning)
        if showingSummary {
          Button("Back") { showingSummary = false }
          Button("Save sprint plan") {
            saveAndClose()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
        } else {
          Button("Save draft & close") {
            saveAndClose()
          }
          .disabled(!canSave)
          Button("Back") {
            currentIndex = max(0, currentIndex - 1)
          }
          .disabled(currentIndex == 0 || model.isPlanningMessageRunning)
          Button(currentIndex == readyItems.count - 1 ? "Review sprint" : "Next ticket") {
            if currentIndex == readyItems.count - 1 {
              showingSummary = true
            } else {
              currentIndex += 1
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isPlanningMessageRunning)
        }
      }
    }
    .padding(28)
    .frame(width: 1_120, height: 800)
    .onAppear(perform: prepareOnce)
    .task(id: currentWorkItemID) {
      guard let currentWorkItemID else { return }
      let comments = await model.comments(for: currentWorkItemID)
      guard sendingMessageItemID != currentWorkItemID else { return }
      commentsByItemID[currentWorkItemID] = comments
    }
  }

  private func ticketReview(_ item: WorkItem) -> some View {
    HStack(alignment: .top, spacing: 18) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack {
            Text(item.key)
              .font(.callout.monospaced().weight(.semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Picker("Type", selection: typeBinding(for: item)) {
              ForEach(WorkItemType.allCases, id: \.self) { type in
                Text(type.title).tag(type)
              }
            }
            .frame(width: 120)
            Picker("Priority", selection: priorityBinding(for: item)) {
              ForEach(WorkItemPriority.allCases, id: \.self) { priority in
                Text(priority.title).tag(priority)
              }
            }
            .frame(width: 130)
          }

          EditableTextField(
            title: "Title",
            prompt: "Describe the outcome",
            text: titleBinding(for: item)
          )

          EditableTextArea(
            title: "Context",
            prompt: "Explain the user need, constraints, and relevant background.",
            text: bodyBinding(for: item),
            minHeight: 105
          )

          EditableTextArea(
            title: "Acceptance criteria",
            prompt: "One independently verifiable outcome per line.",
            text: criteriaBinding(for: item),
            minHeight: 125
          )

          Picker("Assigned to", selection: implementerBinding(for: item.id)) {
            Text("Choose a team member…").tag(UUID?.none)
            ForEach(implementers) { profile in
              Text(profile.name).tag(Optional(profile.id))
            }
          }
          .frame(maxWidth: 420, alignment: .leading)

          Divider()

          HStack {
            if isTicketDraftDirty(item) {
              Label("Unsaved ticket edits", systemImage: "pencil.circle")
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
              Label("Ticket is up to date", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(savingTicketItemID == item.id ? "Saving…" : "Save ticket changes") {
              persistTicketDraft(for: item)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isTicketDraftDirty(item) || savingTicketItemID != nil)
          }

          if let error = ticketSaveErrorsByItemID[item.id] {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(20)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

      planningConversation(for: item)
        .frame(width: 390)
        .frame(maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
          RoundedRectangle(cornerRadius: 14)
            .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }
  }

  @ViewBuilder
  private func planningConversation(for item: WorkItem) -> some View {
    let bottomID = "planning-conversation-\(item.id.uuidString)-bottom"
    let comments = commentsByItemID[item.id] ?? []
    let isSending = sendingMessageItemID == item.id
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Ticket conversation", systemImage: "bubble.left.and.bubble.right")
          .font(.headline)
        Spacer()
      }
      .padding(16)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(comments) { comment in
              TicketCommentBubble(
                comment: comment,
                authorProfile: profile(for: comment),
                mentionedProfile: mentionedProfile(
                  in: comment.body,
                  profiles: model.profiles
                )
              )
            }

            if let pending = pendingProposals[item.id] {
              TicketProposalCard(
                proposal: pending.proposal,
                currentSnapshot: draftSnapshot(for: item),
                authorName: pending.authorName,
                conflictMessage: proposalConflict(for: item, pending: pending),
                onAccept: { acceptProposal(for: item, pending: pending) },
                onReject: { rejectProposal(for: item, pending: pending) }
              )
            }

            Color.clear
              .frame(height: 1)
              .id(bottomID)
          }
          .padding(14)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
          if comments.isEmpty && pendingProposals[item.id] == nil {
            VStack(spacing: 7) {
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.title3)
                .foregroundStyle(.tertiary)
              Text("No messages yet")
                .font(.subheadline.weight(.medium))
              Text("Ask for clarification or request a ticket review.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .onChange(of: commentsByItemID[item.id]?.count ?? 0) { _, _ in
          Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo(bottomID, anchor: .bottom)
            }
          }
        }
        .onChange(of: pendingProposals[item.id] != nil) { wasShowing, isShowing in
          if wasShowing && !isShowing {
            proxy.scrollTo(bottomID, anchor: .bottom)
            Task { @MainActor in
              await Task.yield()
              proxy.scrollTo(bottomID, anchor: .bottom)
            }
          } else {
            Task { @MainActor in
              await Task.yield()
              withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
              }
            }
          }
        }
      }

      if isSending,
        let recipient = selectedRecipient(for: item.id)
      {
        PlanningPresenceIndicator(
          profile: recipient,
          onStop: { model.cancelSprintPlanningMessage() }
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        if !isSending {
          HStack {
            Text("To")
              .font(.caption)
              .foregroundStyle(.secondary)
            PlanningRecipientMenu(
              profiles: model.profiles,
              selection: recipientBinding(for: item.id)
            )
            Spacer()
          }
        }

        if let error = conversationErrorsByItemID[item.id] {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }

        ZStack(alignment: .topLeading) {
          let message = messageByItemID[item.id] ?? ""
          if message.isEmpty && focusedPlanningComposerItemID != item.id {
            Text("Ask a question or request a change…")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
          TextEditor(text: messageBinding(for: item.id))
            .scrollContentBackground(.hidden)
            .font(.body)
            .focused($focusedPlanningComposerItemID, equals: item.id)
            .padding(8)
            .onKeyPress(phases: .down) { keyPress in
              guard keyPress.key == .return else {
                return .ignored
              }
              if keyPress.modifiers.contains(.shift) {
                return .ignored
              }
              if canSendPlanningMessage(for: item) {
                sendPlanningMessage(for: item)
              }
              return .handled
            }
        }
        .frame(height: 74)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }

        HStack(alignment: .center) {
          Text(
            isCodexConnected
              ? "Return to send · Shift-Return for a new line"
              : "Codex unavailable"
          )
          .font(.caption2)
          .foregroundStyle(
            isCodexConnected
              ? Color(nsColor: .tertiaryLabelColor)
              : Color.orange
          )
          Spacer()
          Button(isSending ? "Sending…" : "Send") {
            sendPlanningMessage(for: item)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(!canSendPlanningMessage(for: item))
        }
      }
      .padding(14)
      .background(.quaternary.opacity(0.2))
    }
  }

  private var summaryView: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 16) {
        TextField("Sprint goal", text: $goal)
          .textFieldStyle(.roundedBorder)
        Stepper(value: $concurrencyLimit, in: 1...64) {
          LabeledContent("Maximum parallel work", value: concurrencyLimit.formatted())
        }

        Text("Sprint tickets")
          .font(.headline)
        ScrollView {
          VStack(spacing: 8) {
            ForEach(readyItems) { item in
              HStack {
                Text(item.key)
                  .font(.caption.monospaced().weight(.semibold))
                  .foregroundStyle(.secondary)
                Text(ticketDrafts[item.id]?.title ?? item.title)
                Spacer()
                if isTicketDraftDirty(item) {
                  Text("Unsaved")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                }
              }
              .padding(10)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)

      VStack(alignment: .leading, spacing: 14) {
        Label("Planning signals", systemImage: "chart.bar.doc.horizontal")
          .font(.headline)
        PlanningSignal(title: "Delivery forecast", value: "Not yet analysed")
        PlanningSignal(title: "Remaining usage", value: "Available after Codex sign-in")
        PlanningSignal(
          title: "Human review load",
          value: "\(readyItems.count) demos planned"
        )
        Text("StoryPointless will produce forecasts; you will not be asked to guess token budgets.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(18)
      .frame(width: 290, alignment: .topLeading)
      .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
  }

  private var draftInputs: [SprintDraftItemInput] {
    readyItems.compactMap { item in
      guard
        let selection = selections[item.id],
        let implementerID = selection.implementerID
      else { return nil }
      return SprintDraftItemInput(
        workItemID: item.id,
        implementerProfileID: implementerID,
        reviewerProfileID: nil
      )
    }
  }

  private func saveAndClose() {
    Task {
      if await model.saveSprintPlan(
        goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
        concurrencyLimit: concurrencyLimit,
        items: draftInputs
      ) {
        isPresented = false
      }
    }
  }

  private func prepareOnce() {
    guard !didPrepare else { return }
    didPrepare = true

    for item in readyItems {
      selections[item.id] = TicketPlanSelection(
        implementerID: nil
      )
      ticketDrafts[item.id] = SprintPlanningTicketDraft(item: item)
      if let defaultConversationRecipient {
        recipientByItemID[item.id] = defaultConversationRecipient.id
      }
    }

    if let plan = model.candidateSprintPlan {
      goal = plan.sprint.goal
      concurrencyLimit = plan.sprint.concurrencyLimit
      for sprintItem in plan.items {
        selections[sprintItem.workItemID] = TicketPlanSelection(
          implementerID: sprintItem.implementerProfileID
        )
      }
    }
  }

  private func implementerBinding(for id: UUID) -> Binding<UUID?> {
    Binding(
      get: { selections[id]?.implementerID },
      set: {
        selections[id, default: TicketPlanSelection()].implementerID = $0
        pendingProposals[id] = nil
      }
    )
  }

  private func titleBinding(for item: WorkItem) -> Binding<String> {
    draftBinding(for: item, keyPath: \.title)
  }

  private func typeBinding(for item: WorkItem) -> Binding<WorkItemType> {
    draftBinding(for: item, keyPath: \.type)
  }

  private func bodyBinding(for item: WorkItem) -> Binding<String> {
    draftBinding(for: item, keyPath: \.body)
  }

  private func criteriaBinding(for item: WorkItem) -> Binding<String> {
    draftBinding(for: item, keyPath: \.criteriaText)
  }

  private func priorityBinding(for item: WorkItem) -> Binding<WorkItemPriority> {
    draftBinding(for: item, keyPath: \.priority)
  }

  private func draftBinding<Value>(
    for item: WorkItem,
    keyPath: WritableKeyPath<SprintPlanningTicketDraft, Value>
  ) -> Binding<Value> {
    Binding(
      get: { (ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item))[keyPath: keyPath] },
      set: { value in
        var draft = ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item)
        draft[keyPath: keyPath] = value
        ticketDrafts[item.id] = draft
        ticketSaveErrorsByItemID[item.id] = nil
      }
    )
  }

  private func recipientBinding(for itemID: UUID) -> Binding<UUID> {
    Binding(
      get: {
        recipientByItemID[itemID]
          ?? defaultConversationRecipient?.id
          ?? model.profiles.first?.id
          ?? UUID()
      },
      set: { recipientByItemID[itemID] = $0 }
    )
  }

  private func messageBinding(for itemID: UUID) -> Binding<String> {
    Binding(
      get: { messageByItemID[itemID] ?? "" },
      set: { messageByItemID[itemID] = $0 }
    )
  }

  private func selectedRecipient(for itemID: UUID) -> AgentProfile? {
    guard let recipientID = recipientByItemID[itemID] ?? defaultConversationRecipient?.id else {
      return nil
    }
    return model.profiles.first { $0.id == recipientID }
  }

  private func profile(for comment: TicketComment) -> AgentProfile? {
    guard comment.authorKind == .agent else { return nil }
    return model.profiles.first { $0.name == comment.authorName }
  }

  private func selectedAssignee(for itemID: UUID) -> AgentProfile? {
    guard let assigneeID = selections[itemID]?.implementerID else { return nil }
    return model.profiles.first { $0.id == assigneeID }
  }

  private func draftSnapshot(for item: WorkItem) -> SprintPlanningTicketSnapshot {
    (ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item)).snapshot
  }

  private func isTicketDraftDirty(_ item: WorkItem) -> Bool {
    draftSnapshot(for: item) != SprintPlanningTicketSnapshot(item: item)
  }

  private func canSendPlanningMessage(for item: WorkItem) -> Bool {
    isCodexConnected
      && selectedRecipient(for: item.id) != nil
      && !(messageByItemID[item.id] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !model.isPlanningMessageRunning
      && sendingMessageItemID == nil
      && pendingProposals[item.id] == nil
  }

  private func sendPlanningMessage(for item: WorkItem) {
    guard
      let recipient = selectedRecipient(for: item.id),
      canSendPlanningMessage(for: item)
    else { return }
    let message = (messageByItemID[item.id] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshot = draftSnapshot(for: item)

    let optimisticComment = TicketComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Me",
      body: "@\(recipient.name) \(message)"
    )
    commentsByItemID[item.id, default: []].append(optimisticComment)
    messageByItemID[item.id] = ""
    sendingMessageItemID = item.id
    conversationErrorsByItemID[item.id] = nil
    Task {
      guard
        await model.appendOwnerComment(
          workItemID: item.id,
          body: optimisticComment.body
        ) != nil
      else {
        conversationErrorsByItemID[item.id] = "Your message couldn't be saved. Try again."
        commentsByItemID[item.id] = await model.comments(for: item.id)
        if sendingMessageItemID == item.id {
          sendingMessageItemID = nil
        }
        return
      }

      do {
        let reply = try await model.sendSprintPlanningMessage(
          for: item,
          to: recipient,
          ownerMessage: message,
          ticketSnapshot: snapshot,
          proposedAssignee: selectedAssignee(for: item.id)
        )
        if let proposal = reply.proposal {
          pendingProposals[item.id] = PendingPlanningProposal(
            proposal: proposal,
            baseSnapshot: snapshot,
            authorName: recipient.name
          )
        }
      } catch {
        conversationErrorsByItemID[item.id] = error.localizedDescription
      }
      commentsByItemID[item.id] = await model.comments(for: item.id)
      if sendingMessageItemID == item.id {
        sendingMessageItemID = nil
      }
    }
  }

  private func proposalConflict(
    for item: WorkItem,
    pending: PendingPlanningProposal
  ) -> String? {
    guard pending.proposal.baseVersion == pending.baseSnapshot.version else {
      return "The proposal does not target the ticket version that was sent to the agent."
    }
    guard draftSnapshot(for: item) == pending.baseSnapshot else {
      return "You edited the ticket after this request. Save your edits and ask again before applying the proposal."
    }
    guard model.workItems.first(where: { $0.id == item.id })?.version == pending.baseSnapshot.version else {
      return "The saved ticket changed after this request. Reload it before applying the proposal."
    }
    return nil
  }

  private func acceptProposal(for item: WorkItem, pending: PendingPlanningProposal) {
    guard proposalConflict(for: item, pending: pending) == nil else { return }
    guard savingTicketItemID == nil else { return }
    let dependencyIDs = Set(
      model.dependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
    )
    savingTicketItemID = item.id
    ticketSaveErrorsByItemID[item.id] = nil
    Task {
      let saved = await model.updateWorkItem(
        id: item.id,
        title: pending.proposal.title,
        type: pending.proposal.type,
        body: pending.proposal.body,
        acceptanceCriteria: pending.proposal.acceptanceCriteria,
        priority: pending.proposal.priority,
        customFields: item.customFields,
        dependsOnWorkItemIDs: dependencyIDs,
        expectedVersion: pending.proposal.baseVersion
      )
      if saved, let updated = model.workItems.first(where: { $0.id == item.id }) {
        ticketDrafts[item.id] = SprintPlanningTicketDraft(item: updated)
        pendingProposals[item.id] = nil
        _ = await model.appendOwnerComment(
          workItemID: item.id,
          body: "Accepted \(pending.authorName)'s proposed ticket changes."
        )
        commentsByItemID[item.id] = await model.comments(for: item.id)
      } else {
        ticketSaveErrorsByItemID[item.id] =
          model.errorMessage ?? "The proposal could not be applied. Reload the ticket and review it again."
      }
      if savingTicketItemID == item.id {
        savingTicketItemID = nil
      }
    }
  }

  private func rejectProposal(for item: WorkItem, pending: PendingPlanningProposal) {
    pendingProposals[item.id] = nil
    Task {
      _ = await model.appendOwnerComment(
        workItemID: item.id,
        body: "Rejected \(pending.authorName)'s proposed ticket changes."
      )
      commentsByItemID[item.id] = await model.comments(for: item.id)
    }
  }

  private func persistTicketDraft(for item: WorkItem) {
    guard savingTicketItemID == nil else { return }
    let draft = ticketDrafts[item.id] ?? SprintPlanningTicketDraft(item: item)
    let dependencyIDs = Set(
      model.dependencies.filter { $0.workItemID == item.id }.map(\.dependsOnWorkItemID)
    )
    savingTicketItemID = item.id
    ticketSaveErrorsByItemID[item.id] = nil
    Task {
      let saved = await model.updateWorkItem(
        id: item.id,
        title: draft.title,
        type: draft.type,
        body: draft.body,
        acceptanceCriteria: draft.acceptanceCriteria,
        priority: draft.priority,
        customFields: item.customFields,
        dependsOnWorkItemIDs: dependencyIDs,
        expectedVersion: draft.baseVersion
      )
      if saved, let updated = model.workItems.first(where: { $0.id == item.id }) {
        ticketDrafts[item.id] = SprintPlanningTicketDraft(item: updated)
      } else {
        ticketSaveErrorsByItemID[item.id] =
          model.errorMessage ?? "The ticket could not be saved. Reload it and try again."
      }
      if savingTicketItemID == item.id {
        savingTicketItemID = nil
      }
    }
  }

}

private struct PlanningRecipientMenu: View {
  let profiles: [AgentProfile]
  @Binding var selection: UUID

  private var selectedProfile: AgentProfile? {
    profiles.first { $0.id == selection }
  }

  var body: some View {
    Menu {
      ForEach(profiles) { profile in
        Button {
          selection = profile.id
        } label: {
          HStack {
            Label(profile.name, systemImage: profile.role.symbolName)
            if selection == profile.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        if let selectedProfile {
          Image(systemName: selectedProfile.role.symbolName)
            .foregroundStyle(selectedProfile.role.tint)
          Text(selectedProfile.name)
            .foregroundStyle(selectedProfile.role.tint)
        } else {
          Image(systemName: "person.crop.circle.badge.questionmark")
            .foregroundStyle(.secondary)
          Text("Choose a team member")
            .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        (selectedProfile?.role.tint ?? Color.secondary).opacity(0.1),
        in: Capsule()
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

private struct PlanningPresenceIndicator: View {
  let profile: AgentProfile
  let onStop: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      ProgressView()
        .controlSize(.mini)
        .tint(profile.role.tint)
      HStack(spacing: 0) {
        Text(profile.name)
          .font(.caption.weight(.semibold))
          .foregroundStyle(profile.role.tint)
        Text(" is thinking…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Stop", action: onStop)
        .controlSize(.mini)
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
    .background(profile.role.tint.opacity(0.075))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(profile.name) is thinking")
  }
}

private struct TicketProposalCard: View {
  let proposal: SprintPlanningTicketProposal
  let currentSnapshot: SprintPlanningTicketSnapshot
  let authorName: String
  let conflictMessage: String?
  let onAccept: () -> Void
  let onReject: () -> Void

  private var changes: [TicketProposalChange] {
    var values: [TicketProposalChange] = []
    if currentSnapshot.title != proposal.title {
      values.append(TicketProposalChange(field: "Title", before: currentSnapshot.title, after: proposal.title))
    }
    if currentSnapshot.type != proposal.type {
      values.append(
        TicketProposalChange(
          field: "Type",
          before: currentSnapshot.type.title,
          after: proposal.type.title
        )
      )
    }
    if currentSnapshot.body != proposal.body {
      values.append(
        TicketProposalChange(
          field: "Context",
          before: currentSnapshot.body.isEmpty ? "No context" : currentSnapshot.body,
          after: proposal.body.isEmpty ? "No context" : proposal.body
        )
      )
    }
    if currentSnapshot.acceptanceCriteria != proposal.acceptanceCriteria {
      values.append(
        TicketProposalChange(
          field: "Acceptance criteria",
          before: criteriaDescription(currentSnapshot.acceptanceCriteria),
          after: criteriaDescription(proposal.acceptanceCriteria)
        )
      )
    }
    if currentSnapshot.priority != proposal.priority {
      values.append(
        TicketProposalChange(
          field: "Priority",
          before: currentSnapshot.priority.title,
          after: proposal.priority.title
        )
      )
    }
    return values
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Label("\(authorName) proposal", systemImage: "wand.and.stars")
        .font(.headline)
        .foregroundStyle(.indigo)
      Text(proposal.rationale)
        .font(.caption)
        .foregroundStyle(.secondary)

      if changes.isEmpty {
        Text("The proposal does not change the current ticket.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(changes) { change in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(change.field)
                .font(.caption.weight(.semibold))
              Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
              Text("Current")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(change.before)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
              Text("Proposed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
              Text(change.after)
                .font(.caption)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(9)
          .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        }
      }

      if let conflictMessage {
        Label(conflictMessage, systemImage: "exclamationmark.triangle")
          .font(.caption2)
          .foregroundStyle(.orange)
      }

      HStack(spacing: 8) {
        Button("Accept all suggestions", action: onAccept)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(conflictMessage != nil || changes.isEmpty)
        Button("Dismiss", action: onReject)
          .controlSize(.small)
      }
    }
    .padding(14)
    .background(.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.indigo.opacity(0.14), lineWidth: 1)
    }
  }

  private func criteriaDescription(_ criteria: [String]) -> String {
    criteria.isEmpty ? "No acceptance criteria" : criteria.map { "• \($0)" }.joined(separator: "\n")
  }
}

private struct TicketProposalChange: Identifiable {
  let id = UUID()
  let field: String
  let before: String
  let after: String
}

private struct PlanningSignal: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.weight(.medium))
    }
  }
}

private struct TicketPlanSelection {
  var implementerID: UUID?
}

private struct SprintPlanningTicketDraft {
  var baseVersion: Int
  var title: String
  var type: WorkItemType
  var body: String
  var criteriaText: String
  var priority: WorkItemPriority

  init(item: WorkItem) {
    baseVersion = item.version
    title = item.title
    type = item.type
    body = item.body
    criteriaText = item.acceptanceCriteria.joined(separator: "\n")
    priority = item.priority
  }

  init(
    baseVersion: Int,
    title: String,
    type: WorkItemType,
    body: String,
    criteriaText: String,
    priority: WorkItemPriority
  ) {
    self.baseVersion = baseVersion
    self.title = title
    self.type = type
    self.body = body
    self.criteriaText = criteriaText
    self.priority = priority
  }

  var acceptanceCriteria: [String] {
    criteriaText
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var snapshot: SprintPlanningTicketSnapshot {
    SprintPlanningTicketSnapshot(
      version: baseVersion,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      type: type,
      body: body.trimmingCharacters(in: .whitespacesAndNewlines),
      acceptanceCriteria: acceptanceCriteria,
      priority: priority
    )
  }
}

private struct PendingPlanningProposal {
  let proposal: SprintPlanningTicketProposal
  let baseSnapshot: SprintPlanningTicketSnapshot
  let authorName: String
}

extension SprintPlanningTicketSnapshot {
  init(item: WorkItem) {
    self.init(
      version: item.version,
      title: item.title,
      type: item.type,
      body: item.body,
      acceptanceCriteria: item.acceptanceCriteria,
      priority: item.priority
    )
  }
}

private struct TicketCustomFieldDraft: Identifiable {
  let id = UUID()
  var name: String
  var value: String
}

private struct AcceptanceCriterionDraft: Identifiable {
  let id = UUID()
  var text: String
}

private struct AcceptanceCriteriaEditor: View {
  @Binding var criteria: [AcceptanceCriterionDraft]

  private var isMissing: Bool {
    criteria.allSatisfy {
      $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Acceptance criteria")
          .font(.subheadline.weight(.semibold))
        Text(criteria.count.formatted())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
        if isMissing {
          Label("Required", systemImage: "exclamationmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
        Spacer()
        Button {
          criteria.append(AcceptanceCriterionDraft(text: ""))
        } label: {
          Label("Add criterion", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Text("Each item should describe one independently verifiable outcome.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if criteria.isEmpty {
        Button {
          criteria.append(AcceptanceCriterionDraft(text: ""))
        } label: {
          Label("Add the first acceptance criterion", systemImage: "checklist")
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
          RoundedRectangle(cornerRadius: 9)
            .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
      } else {
        VStack(spacing: 8) {
          ForEach($criteria) { $criterion in
            HStack(alignment: .center, spacing: 10) {
              Text("•")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 24)

              TextField(
                "Describe a verifiable outcome",
                text: $criterion.text,
                axis: .vertical
              )
              .textFieldStyle(.plain)
              .lineLimit(1...4)

              Button {
                criteria.removeAll { $0.id == criterion.id }
              } label: {
                Image(systemName: "xmark")
                  .frame(width: 20, height: 24)
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove criterion")
            }
            .padding(10)
            .background(
              Color(nsColor: .textBackgroundColor),
              in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 9)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
            }
          }
        }
      }
    }
  }
}

private struct TicketBlockerEditor: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selectedIDs: Set<UUID>
  let excludingWorkItemID: UUID?

  private var selectedItems: [WorkItem] {
    model.workItems.filter { selectedIDs.contains($0.id) }
  }

  private var availableItems: [WorkItem] {
    model.workItems.filter {
      [.backlog, .refining, .ready].contains($0.state)
        && $0.id != excludingWorkItemID
        && !selectedIDs.contains($0.id)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Blocked by")
            .font(.subheadline.weight(.semibold))
          Text("These tickets must be completed first and are kept above this ticket.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          if availableItems.isEmpty {
            Text("No available tickets")
          } else {
            ForEach(availableItems) { item in
              Button("\(item.key)  \(item.title)") {
                selectedIDs.insert(item.id)
              }
            }
          }
        } label: {
          Label("Add blocker", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if selectedItems.isEmpty {
        Text("No blockers")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else {
        VStack(spacing: 7) {
          ForEach(selectedItems) { item in
            HStack(spacing: 9) {
              Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(.orange)
              Text(item.key)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
              Text(item.title)
                .font(.callout)
                .lineLimit(1)
              Spacer()
              Button {
                selectedIDs.remove(item.id)
              } label: {
                Image(systemName: "xmark")
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove blocker")
            }
            .padding(9)
            .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
  }
}

private enum TicketRefinementField: String, CaseIterable, Identifiable {
  case title
  case type
  case context
  case acceptanceCriteria
  case priority

  var id: String { rawValue }

  var label: String {
    switch self {
    case .title: "Title"
    case .type: "Type"
    case .context: "Context"
    case .acceptanceCriteria: "Acceptance criteria"
    case .priority: "Priority"
    }
  }
}

private struct TicketRefinementFieldChange: Identifiable {
  let field: TicketRefinementField
  let before: String
  let after: String

  var id: TicketRefinementField { field }
}

private struct TicketDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceContainerSize) private var workspaceContainerSize
  let itemID: UUID
  let startRefinementOnAppear: Bool
  @State private var title: String
  @State private var type: WorkItemType
  @State private var bodyText: String
  @State private var criteria: [AcceptanceCriterionDraft]
  @State private var priority: WorkItemPriority
  @State private var blockerIDs: Set<UUID>
  @State private var customFields: [TicketCustomFieldDraft]
  @State private var isSaving = false
  @State private var isStartingRefinement = false
  @State private var didStartInitialRefinement = false
  @State private var refinementReply: TicketRefinementReply?
  @State private var refinementBaseSnapshot: SprintPlanningTicketSnapshot?
  @State private var refinementConflictMessage: String?
  @State private var refinementError: String?
  @State private var acceptedRefinementFields: Set<TicketRefinementField> = []
  @State private var expandedRefinementFields: Set<TicketRefinementField> = []
  @State private var dismissedDependencyKeys: Set<String> = []
  @State private var conversationRefreshToken = 0
  @State private var refinementPanelTitle = "Business Analyst review"

  init(
    item: WorkItem,
    dependsOnWorkItemIDs: Set<UUID>,
    startRefinementOnAppear: Bool = false
  ) {
    itemID = item.id
    self.startRefinementOnAppear = startRefinementOnAppear
    _title = State(initialValue: item.title)
    _type = State(initialValue: item.type)
    _bodyText = State(initialValue: item.body)
    _criteria = State(
      initialValue: item.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    )
    _priority = State(initialValue: item.priority)
    _blockerIDs = State(initialValue: dependsOnWorkItemIDs)
    _customFields = State(
      initialValue: item.customFields.keys.sorted().map {
        TicketCustomFieldDraft(name: $0, value: item.customFields[$0] ?? "")
      }
    )
  }

  private var item: WorkItem? {
    model.workItems.first { $0.id == itemID }
  }

  private var isRefining: Bool {
    isStartingRefinement || model.refiningWorkItemID == itemID
  }

  private var duplicateFieldNames: Set<String> {
    let names = customFields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Set(names.filter { name in
      names.filter { $0.caseInsensitiveCompare(name) == .orderedSame }.count > 1
    })
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && customFields.allSatisfy {
        !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      && duplicateFieldNames.isEmpty
      && !isSaving
  }

  private var detailWidth: CGFloat {
    min(1_320, max(900, workspaceContainerSize.width - 72))
  }

  private var detailHeight: CGFloat {
    min(820, max(620, workspaceContainerSize.height - 72))
  }

  private var conversationWidth: CGFloat {
    min(460, max(360, detailWidth * 0.35))
  }

  private var currentSavedSnapshot: SprintPlanningTicketSnapshot? {
    item.map(SprintPlanningTicketSnapshot.init(item:))
  }

  private var currentDraftSnapshot: SprintPlanningTicketSnapshot? {
    guard let item else { return nil }
    return SprintPlanningTicketSnapshot(
      version: item.version,
      title: title,
      type: type,
      body: bodyText,
      acceptanceCriteria: parsedCriteria,
      priority: priority
    )
  }

  private var savedBlockerIDs: Set<UUID> {
    Set(
      model.dependencies
        .filter { $0.workItemID == itemID }
        .map(\.dependsOnWorkItemID)
    )
  }

  private var draftCustomFields: [String: String] {
    customFields.reduce(into: [:]) { result, field in
      let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }
      result[name] = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private var hasUnsavedChanges: Bool {
    currentDraftSnapshot != currentSavedSnapshot
      || blockerIDs != savedBlockerIDs
      || draftCustomFields != item?.customFields
  }

  private var parsedCriteria: [String] {
    criteria
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var isContextMissing: Bool {
    bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        if let item {
          Image(systemName: item.type.symbolName)
            .foregroundStyle(item.type.tint)
          Text(item.key)
            .font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text("Ticket details")
          .font(.title2.bold())
        Spacer()
        Button {
          startRefinement()
        } label: {
          if isRefining {
            HStack(spacing: 7) {
              ProgressView()
                .controlSize(.small)
              Text("Reviewing…")
            }
          } else {
            Label("Refine with AI", systemImage: "wand.and.stars")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(
          isRefining
            || hasUnsavedChanges
            || !model.canRefineTicket
        )
        .help(
          hasUnsavedChanges
            ? "Save your edits before starting a new review."
            : "Ask the Business Analyst for reviewable ticket and dependency suggestions."
        )
        Button("Close") { dismiss() }
      }
      .padding(.horizontal, 24)
      .frame(height: 62)

      Divider()

      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
              VStack(alignment: .leading, spacing: 7) {
                Text("Type")
                  .font(.subheadline.weight(.semibold))
                Picker("Type", selection: $type) {
                  ForEach(WorkItemType.allCases, id: \.self) { value in
                    Label(value.title, systemImage: value.symbolName).tag(value)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
              }

              VStack(alignment: .leading, spacing: 7) {
                Text("Priority")
                  .font(.subheadline.weight(.semibold))
                Picker("Priority", selection: $priority) {
                  ForEach(WorkItemPriority.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
              }

              Spacer()

              if let item {
                VStack(alignment: .trailing, spacing: 3) {
                  Text("Planning status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Text(candidateStatus(for: item))
                    .font(.subheadline.weight(.semibold))
                }
              }
            }

            EditableTextField(
              title: "Title",
              prompt: "Describe the outcome",
              text: $title
            )

            EditableTextArea(
              title: "Context",
              prompt: "Explain the user need, constraints, and relevant background.",
              text: $bodyText,
              statusText: isContextMissing ? "Required" : nil,
              minHeight: 126
            )

            AcceptanceCriteriaEditor(criteria: $criteria)

            relationshipSection
            customFieldSection
          }
          .padding(24)
        }
        .frame(maxWidth: .infinity)

        Divider()

        TicketConversationView(
          workItemID: itemID,
          ticketSnapshot: currentDraftSnapshot,
          refreshToken: conversationRefreshToken,
          showsReview:
            refinementError != nil
            || (refinementReply?.proposal.missingQuestions.isEmpty == true),
          isAgentResponding: isRefining,
          refinementQuestions: refinementReply?.proposal.missingQuestions ?? [],
          onStopRefinement: { model.cancelTicketRefinement() },
          onRefinementAnswer: { _ in
            await continueRefinement()
          },
          onChatProposal: { proposal, base, author in
            presentChatProposal(
              proposal,
              base: base,
              author: author
            )
          },
          reviewContent: refinementPanel
        )
        .frame(width: conversationWidth)
      }

      Divider()

      HStack {
        if !duplicateFieldNames.isEmpty {
          Label("Custom field names must be unique", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Text("Changes are local and become the ticket source of truth when saved.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { dismiss() }
        Button(isSaving ? "Saving…" : "Save changes") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave)
      }
      .padding(.horizontal, 20)
      .frame(height: 62)
    }
    .frame(width: detailWidth, height: detailHeight)
    .background(InitialFocusClearer())
    .task {
      restoreTicketAssistantSession()
      await restorePendingRefinementQuestion()
      guard
        startRefinementOnAppear,
        !didStartInitialRefinement,
        refinementReply == nil
      else { return }
      didStartInitialRefinement = true
      startRefinement()
    }
    .onChange(of: model.ticketRefinementResults[itemID]) { _, result in
      guard let result else { return }
      applyRefinementSessionResult(result)
      conversationRefreshToken += 1
    }
    .onChange(of: model.ticketConversationResults[itemID]) { _, result in
      guard let result else { return }
      applyConversationSessionResult(result)
      conversationRefreshToken += 1
    }
    .onChange(of: model.refiningWorkItemID) { previousID, currentID in
      guard previousID == itemID || currentID == itemID else { return }
      conversationRefreshToken += 1
    }
    .onChange(of: model.ticketConversationWorkItemID) { previousID, currentID in
      guard previousID == itemID || currentID == itemID else { return }
      conversationRefreshToken += 1
    }
  }

  private func restoreTicketAssistantSession() {
    if let result = model.ticketRefinementResults[itemID] {
      applyRefinementSessionResult(result)
    }
    if let result = model.ticketConversationResults[itemID] {
      applyConversationSessionResult(result)
    }
  }

  private func applyRefinementSessionResult(_ result: TicketRefinementSessionResult) {
    refinementBaseSnapshot = result.base
    refinementPanelTitle =
      (model.profiles.first { $0.role == .businessAnalyst }?.name ?? "Business Analyst")
      + " review"
    refinementReply = result.reply
    refinementError = result.errorMessage
    guard let reply = result.reply else {
      refinementConflictMessage = nil
      return
    }
    if currentDraftSnapshot != result.base {
      refinementConflictMessage =
        "You edited the ticket while the review was running. Save those edits and run a fresh review before accepting suggestions."
    } else if model.workItems.first(where: { $0.id == itemID })?.version
      != reply.proposal.baseVersion
    {
      refinementConflictMessage =
        "The saved ticket changed while the review was running. Run a fresh review before accepting suggestions."
    } else {
      refinementConflictMessage = nil
    }
  }

  private func applyConversationSessionResult(_ result: TicketConversationSessionResult) {
    guard
      let proposal = result.reply.proposal,
      let author = model.profiles.first(where: { $0.id == result.recipientID })
    else { return }
    presentChatProposal(proposal, base: result.base, author: author)
  }

  private func restorePendingRefinementQuestion() async {
    guard
      refinementReply == nil,
      let item,
      let analyst = model.profiles.first(where: { $0.role == .businessAnalyst })
    else { return }

    let comments = await model.comments(for: item.id)
    guard
      let latest = comments.last,
      latest.authorKind == .agent,
      latest.authorName == analyst.name
    else { return }

    let questions = TicketRefinementQuestion.parseTicketCommentBody(latest.body)
    guard !questions.isEmpty else { return }

    let base = SprintPlanningTicketSnapshot(item: item)
    refinementBaseSnapshot = base
    refinementPanelTitle = "\(analyst.name) review"
    refinementReply = TicketRefinementReply(
      message: "",
      proposal: TicketRefinementProposal(
        baseVersion: item.version,
        title: item.title,
        type: item.type,
        body: item.body,
        acceptanceCriteria: item.acceptanceCriteria,
        priority: item.priority,
        rationale: "",
        dependencies: [],
        potentialDuplicates: [],
        splitRecommendation: nil,
        missingQuestions: questions
      )
    )
  }

  @ViewBuilder
  private var refinementPanel: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Label(refinementPanelTitle, systemImage: "wand.and.stars")
          .font(.headline)
          .foregroundStyle(.purple)
        Spacer()
        if refinementReply != nil || refinementError != nil {
          Button {
            refinementReply = nil
            refinementError = nil
            refinementConflictMessage = nil
            model.dismissTicketAssistantResult(workItemID: itemID)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Dismiss review")
        }
      }

      if isRefining {
        HStack(spacing: 9) {
          ProgressView()
            .controlSize(.small)
            .tint(.purple)
          VStack(alignment: .leading, spacing: 2) {
            Text("Business Analyst is reviewing this ticket…")
              .font(.subheadline.weight(.semibold))
            Text("Checking clarity, criteria, overlap, and dependencies.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Stop") {
            model.cancelTicketRefinement()
          }
          .controlSize(.mini)
        }
        .padding(11)
        .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
      } else if let refinementError {
        Label(refinementError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
        Button("Try again") { startRefinement() }
          .controlSize(.small)
      } else if let reply = refinementReply {
        if !reply.proposal.missingQuestions.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            Label("Waiting for your answer", systemImage: "questionmark.bubble")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.purple)
            Text("Reply to the Business Analyst below. Proposed changes will appear only after the open questions are resolved.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(11)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        } else if let base = refinementBaseSnapshot {
          if let refinementConflictMessage {
            Label(refinementConflictMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(9)
              .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
          }

          VStack(alignment: .leading, spacing: 10) {
            ForEach(refinementFieldChanges(proposal: reply.proposal, base: base)) { change in
              refinementFieldRow(change)
            }

            ForEach(reply.proposal.dependencies, id: \.ticketKey) { dependency in
              dependencyProposalRow(dependency)
            }

            if !reply.proposal.potentialDuplicates.isEmpty {
              refinementInsightSection(
                title: "Possible overlap",
                symbol: "square.on.square",
                rows: reply.proposal.potentialDuplicates.map {
                  "\($0.ticketKey) · \($0.reason)"
                }
              )
            }

            if let split = reply.proposal.splitRecommendation {
              refinementInsightSection(
                title: "Consider splitting",
                symbol: "arrow.triangle.branch",
                rows: [split]
              )
            }
          }

          let reviewProgress = refinementReviewProgress(
            proposal: reply.proposal,
            base: base
          )
          HStack(spacing: 8) {
            if reviewProgress.remaining == 0 {
              Label(
                reviewProgress.total == 0
                  ? "No ticket changes suggested"
                  : reviewProgress.dismissed == 0
                    ? "All suggestions applied"
                    : "Review complete",
                systemImage: reviewProgress.total == 0
                  ? "info.circle.fill"
                  : "checkmark.circle.fill"
              )
              .font(.caption.weight(.semibold))
              .foregroundStyle(.green)
            } else {
              Button(
                reviewProgress.remaining == reviewProgress.total
                  ? "Accept all suggestions"
                  : "Accept remaining suggestions"
              ) {
                acceptAllRefinementSuggestions(reply.proposal)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .disabled(refinementConflictMessage != nil)
            }
            Button("Dismiss") {
              refinementReply = nil
              refinementConflictMessage = nil
              model.dismissTicketAssistantResult(workItemID: itemID)
            }
            .controlSize(.small)
          }

          Text("Accepted suggestions update the form. Save changes to make them the ticket source of truth.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(14)
    .background(.purple.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.purple.opacity(0.14), lineWidth: 1)
    }
  }

  private func refinementFieldRow(_ change: TicketRefinementFieldChange) -> some View {
    let isAccepted = acceptedRefinementFields.contains(change.field)
    let isExpanded = expandedRefinementFields.contains(change.field)
    let hasLongComparison =
      change.before.count > 180
      || change.after.count > 260
      || change.before.filter(\.isNewline).count > 2
      || change.after.filter(\.isNewline).count > 4
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(change.field.label)
          .font(.caption.weight(.semibold))
        Spacer()
        if isAccepted {
          Label("Applied", systemImage: "checkmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
        } else {
          Button("Accept") {
            acceptRefinementField(change.field)
          }
          .controlSize(.mini)
          .disabled(refinementConflictMessage != nil)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Current")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(change.before)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(isExpanded ? nil : 3)
      }
      Divider()
      VStack(alignment: .leading, spacing: 4) {
        Text("Proposed")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.green)
        Text(change.after)
          .font(.caption)
          .lineLimit(isExpanded ? nil : 5)
      }
      if hasLongComparison {
        Button(isExpanded ? "Show less" : "Show full comparison") {
          if isExpanded {
            expandedRefinementFields.remove(change.field)
          } else {
            expandedRefinementFields.insert(change.field)
          }
        }
        .buttonStyle(.link)
        .font(.caption.weight(.semibold))
      }
    }
    .padding(9)
    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
  }

  private func dependencyProposalRow(
    _ dependency: TicketRefinementDependencyProposal
  ) -> some View {
    let relatedItem = model.workItems.first { $0.key == dependency.ticketKey }
    let isApplied = relatedItem.map { blockerIDs.contains($0.id) } ?? false
    let isDismissed = dismissedDependencyKeys.contains(dependency.ticketKey)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Suggested dependency: \(dependency.ticketKey)", systemImage: "link")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.indigo)
        Spacer()
        if isApplied {
          Label("Applied", systemImage: "checkmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
        } else if isDismissed {
          Text("Dismissed")
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          Button("Accept") {
            if let relatedItem {
              blockerIDs.insert(relatedItem.id)
              autoDismissRefinementReviewIfResolved()
            }
          }
          .controlSize(.mini)
          .disabled(refinementConflictMessage != nil || relatedItem == nil)
          Button("Dismiss") {
            dismissedDependencyKeys.insert(dependency.ticketKey)
            autoDismissRefinementReviewIfResolved()
          }
          .controlSize(.mini)
        }
      }
      if let relatedItem {
        Text(relatedItem.title)
          .font(.caption)
      }
      Text(dependency.reason)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(9)
    .background(.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
  }

  private func refinementInsightSection(
    title: String,
    symbol: String,
    rows: [String]
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol)
        .font(.caption.weight(.semibold))
      ForEach(Array(rows.enumerated()), id: \.offset) { entry in
        Text("• \(entry.element)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
  }

  private var relationshipSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Relationships")
          .font(.headline)
        Text("Blockers affect backlog order and sprint readiness.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      TicketBlockerEditor(
        selectedIDs: $blockerIDs,
        excludingWorkItemID: itemID
      )

      let blockedItems = model.dependencies
        .filter { $0.dependsOnWorkItemID == itemID }
        .compactMap { edge in
          model.workItems.first { $0.id == edge.workItemID }
        }
      if !blockedItems.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("Blocks")
            .font(.subheadline.weight(.semibold))
          ForEach(blockedItems) { blockedItem in
            HStack(spacing: 9) {
              Image(systemName: "arrow.right")
                .foregroundStyle(.indigo)
              Text(blockedItem.key)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
              Text(blockedItem.title)
                .font(.callout)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(.indigo.opacity(0.16), lineWidth: 1)
    }
  }

  private var customFieldSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Custom fields")
            .font(.subheadline.weight(.semibold))
          Text("Product-specific metadata available to the delivery team.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          customFields.append(TicketCustomFieldDraft(name: "", value: ""))
        } label: {
          Label("Add field", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if customFields.isEmpty {
        Text("No custom fields")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        VStack(spacing: 8) {
          ForEach($customFields) { $field in
            HStack(spacing: 8) {
              TextField("Field name", text: $field.name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(width: 190, height: 36)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
                }
              TextField("Value", text: $field.value)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
                }
              Button {
                customFields.removeAll { $0.id == field.id }
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove custom field")
            }
          }
        }
      }
    }
  }

  private func startRefinement() {
    guard
      let item,
      !hasUnsavedChanges,
      model.canRefineTicket,
      !isRefining
    else { return }
    let base = SprintPlanningTicketSnapshot(item: item)
    refinementBaseSnapshot = base
    refinementPanelTitle =
      (model.profiles.first { $0.role == .businessAnalyst }?.name ?? "Business Analyst")
      + " review"
    refinementReply = nil
    refinementConflictMessage = nil
    refinementError = nil
    acceptedRefinementFields.removeAll()
    expandedRefinementFields.removeAll()
    dismissedDependencyKeys.removeAll()
    isStartingRefinement = true

    Task {
      await performRefinement(item: item, base: base)
    }
  }

  private func continueRefinement() async {
    guard
      let item,
      let base = refinementBaseSnapshot,
      !hasUnsavedChanges,
      model.canRefineTicket,
      !isRefining
    else { return }
    isStartingRefinement = true
    refinementError = nil
    await performRefinement(item: item, base: base)
  }

  private func performRefinement(
    item: WorkItem,
    base: SprintPlanningTicketSnapshot
  ) async {
    do {
      let reply = try await model.refineTicket(item)
      refinementReply = reply
      if currentDraftSnapshot != base {
        refinementConflictMessage =
          "You edited the ticket while the review was running. Save those edits and run a fresh review before accepting suggestions."
      } else if model.workItems.first(where: { $0.id == item.id })?.version
        != reply.proposal.baseVersion
      {
        refinementConflictMessage =
          "The saved ticket changed while the review was running. Run a fresh review before accepting suggestions."
      } else {
        refinementConflictMessage = nil
      }
    } catch {
      refinementError = error.localizedDescription
    }
    conversationRefreshToken += 1
    isStartingRefinement = false
  }

  private func refinementFieldChanges(
    proposal: TicketRefinementProposal,
    base: SprintPlanningTicketSnapshot
  ) -> [TicketRefinementFieldChange] {
    var changes: [TicketRefinementFieldChange] = []
    if proposal.title != base.title {
      changes.append(
        TicketRefinementFieldChange(
          field: .title,
          before: base.title,
          after: proposal.title
        )
      )
    }
    if proposal.type != base.type {
      changes.append(
        TicketRefinementFieldChange(
          field: .type,
          before: base.type.title,
          after: proposal.type.title
        )
      )
    }
    if proposal.body != base.body {
      changes.append(
        TicketRefinementFieldChange(
          field: .context,
          before: base.body.isEmpty ? "No context" : base.body,
          after: proposal.body.isEmpty ? "No context" : proposal.body
        )
      )
    }
    if proposal.acceptanceCriteria != base.acceptanceCriteria {
      changes.append(
        TicketRefinementFieldChange(
          field: .acceptanceCriteria,
          before: refinementCriteriaDescription(base.acceptanceCriteria),
          after: refinementCriteriaDescription(proposal.acceptanceCriteria)
        )
      )
    }
    if proposal.priority != base.priority {
      changes.append(
        TicketRefinementFieldChange(
          field: .priority,
          before: base.priority.title,
          after: proposal.priority.title
        )
      )
    }
    return changes
  }

  private func presentChatProposal(
    _ proposal: SprintPlanningTicketProposal,
    base: SprintPlanningTicketSnapshot,
    author: AgentProfile
  ) {
    refinementBaseSnapshot = base
    refinementPanelTitle = "\(author.name) proposal"
    refinementError = nil
    acceptedRefinementFields.removeAll()
    expandedRefinementFields.removeAll()
    dismissedDependencyKeys.removeAll()
    refinementReply = TicketRefinementReply(
      message: "",
      proposal: TicketRefinementProposal(
        baseVersion: proposal.baseVersion,
        title: proposal.title,
        type: proposal.type,
        body: proposal.body,
        acceptanceCriteria: proposal.acceptanceCriteria,
        priority: proposal.priority,
        rationale: proposal.rationale,
        dependencies: [],
        potentialDuplicates: [],
        splitRecommendation: nil,
        missingQuestions: []
      )
    )
    if currentDraftSnapshot != base {
      refinementConflictMessage =
        "The ticket changed after your message was sent. Review or save those changes, then ask again before accepting this proposal."
    } else if model.workItems.first(where: { $0.id == itemID })?.version
      != proposal.baseVersion
    {
      refinementConflictMessage =
        "The saved ticket changed while this proposal was being prepared. Ask again before accepting it."
    } else {
      refinementConflictMessage = nil
    }
  }

  private func refinementCriteriaDescription(_ criteria: [String]) -> String {
    criteria.isEmpty ? "No acceptance criteria" : criteria.map { "• \($0)" }.joined(separator: "\n")
  }

  private func acceptRefinementField(_ field: TicketRefinementField) {
    guard
      refinementConflictMessage == nil,
      let proposal = refinementReply?.proposal
    else { return }
    switch field {
    case .title:
      title = proposal.title
    case .type:
      type = proposal.type
    case .context:
      bodyText = proposal.body
    case .acceptanceCriteria:
      criteria = proposal.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    case .priority:
      priority = proposal.priority
    }
    acceptedRefinementFields.insert(field)
    autoDismissRefinementReviewIfResolved()
  }

  private func acceptAllRefinementSuggestions(_ proposal: TicketRefinementProposal) {
    guard refinementConflictMessage == nil else { return }
    title = proposal.title
    type = proposal.type
    bodyText = proposal.body
    criteria = proposal.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    priority = proposal.priority
    acceptedRefinementFields.formUnion(TicketRefinementField.allCases)
    for dependency in proposal.dependencies
    where !dismissedDependencyKeys.contains(dependency.ticketKey) {
      if let relatedItem = model.workItems.first(where: { $0.key == dependency.ticketKey }) {
        blockerIDs.insert(relatedItem.id)
      }
    }
    refinementReply = nil
    refinementConflictMessage = nil
    model.dismissTicketAssistantResult(workItemID: itemID)
  }

  private func autoDismissRefinementReviewIfResolved() {
    guard
      let proposal = refinementReply?.proposal,
      let base = refinementBaseSnapshot
    else { return }
    let progress = refinementReviewProgress(proposal: proposal, base: base)
    guard progress.total > 0, progress.remaining == 0 else { return }
    refinementReply = nil
    refinementConflictMessage = nil
    model.dismissTicketAssistantResult(workItemID: itemID)
  }

  private func refinementReviewProgress(
    proposal: TicketRefinementProposal,
    base: SprintPlanningTicketSnapshot
  ) -> (total: Int, remaining: Int, dismissed: Int) {
    let fieldChanges = refinementFieldChanges(proposal: proposal, base: base)
    let remainingFields = fieldChanges.filter {
      !acceptedRefinementFields.contains($0.field)
    }.count
    let dependencyStates = proposal.dependencies.map { dependency -> (applied: Bool, dismissed: Bool) in
      let relatedItem = model.workItems.first { $0.key == dependency.ticketKey }
      return (
        relatedItem.map { blockerIDs.contains($0.id) } ?? false,
        dismissedDependencyKeys.contains(dependency.ticketKey)
      )
    }
    let remainingDependencies = dependencyStates.filter {
      !$0.applied && !$0.dismissed
    }.count
    let dismissedDependencies = dependencyStates.filter(\.dismissed).count
    return (
      total: fieldChanges.count + proposal.dependencies.count,
      remaining: remainingFields + remainingDependencies,
      dismissed: dismissedDependencies
    )
  }

  private func candidateStatus(for item: WorkItem) -> String {
    let candidateIDs = Set(model.candidateSprintPlan?.items.map(\.workItemID) ?? [])
    return candidateIDs.contains(item.id) ? "Next sprint" : "Backlog"
  }

  private func save() {
    isSaving = true
    Task {
      let saved = await model.updateWorkItem(
        id: itemID,
        title: title,
        type: type,
        body: bodyText,
        acceptanceCriteria: parsedCriteria,
        priority: priority,
        customFields: draftCustomFields,
        dependsOnWorkItemIDs: blockerIDs
      )
      isSaving = false
      if saved {
        model.dismissTicketAssistantResult(workItemID: itemID)
        dismiss()
      }
    }
  }
}

private struct TicketConversationView<ReviewContent: View>: View {
  @EnvironmentObject private var model: AppModel
  let workItemID: UUID
  let ticketSnapshot: SprintPlanningTicketSnapshot?
  let refreshToken: Int
  let showsReview: Bool
  let isAgentResponding: Bool
  let refinementQuestions: [TicketRefinementQuestion]
  let onStopRefinement: () -> Void
  let onRefinementAnswer: ((String) async -> Void)?
  let onChatProposal:
    (SprintPlanningTicketProposal, SprintPlanningTicketSnapshot, AgentProfile) -> Void
  let reviewContent: ReviewContent
  @State private var comments: [TicketComment] = []
  @State private var message = ""
  @State private var recipientID: UUID?
  @State private var isSending = false
  @State private var respondingRecipientID: UUID?
  @State private var sendError: String?
  @State private var selectedRefinementOptions: [Int: String] = [:]
  @State private var otherRefinementAnswers: [Int: String] = [:]
  @State private var hasSubmittedRefinementAnswers = false
  @FocusState private var isComposerFocused: Bool

  private var isAwaitingRefinementAnswer: Bool {
    !refinementQuestions.isEmpty
  }

  private var isShowingRefinementChoices: Bool {
    isAwaitingRefinementAnswer && !hasSubmittedRefinementAnswers
  }

  private var businessAnalyst: AgentProfile? {
    model.profiles.first { $0.role == .businessAnalyst }
  }

  private var selectedRecipient: AgentProfile? {
    if isAwaitingRefinementAnswer {
      return businessAnalyst
    }
    guard let recipientID else { return nil }
    return model.profiles.first { $0.id == recipientID }
  }

  private var respondingRecipient: AgentProfile? {
    let activeRecipientID =
      respondingRecipientID
      ?? (
        model.ticketConversationWorkItemID == workItemID
          ? model.ticketConversationRecipientID
          : nil
      )
    guard let activeRecipientID else { return nil }
    return model.profiles.first { $0.id == activeRecipientID }
  }

  private var activeStatusProfile: AgentProfile? {
    isAgentResponding ? businessAnalyst : respondingRecipient
  }

  private var isAnyAgentResponding: Bool {
    isAgentResponding || respondingRecipient != nil
  }

  private var canSendMessage: Bool {
    canSend(message)
  }

  private func canSend(_ content: String) -> Bool {
    selectedRecipient != nil
      && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSending
      && !isAnyAgentResponding
  }

  private var otherChoiceKey: String { "\u{0}other" }

  private var canSubmitRefinementAnswers: Bool {
    !refinementQuestions.isEmpty
      && selectedRecipient != nil
      && refinementQuestions.indices.allSatisfy { index in
        guard let selection = selectedRefinementOptions[index] else { return false }
        return selection != otherChoiceKey
          || !(otherRefinementAnswers[index] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      && !isSending
      && !isAnyAgentResponding
  }

  private var displayedComments: [TicketComment] {
    guard pendingRefinementComment != nil else { return comments }
    return Array(comments.dropLast())
  }

  private var pendingRefinementComment: TicketComment? {
    guard
      isShowingRefinementChoices,
      let last = comments.last,
      last.authorKind == .agent,
      last.authorName == businessAnalyst?.name
    else { return nil }
    return last
  }

  private var showsEmptyConversation: Bool {
    displayedComments.isEmpty
      && !showsReview
      && !isShowingRefinementChoices
  }

  private var defaultRecipient: AgentProfile? {
    if let sprintItem = (
      model.candidateSprintPlan?.items.first(where: { $0.workItemID == workItemID })
        ?? model.sprintPlan?.items.first(where: { $0.workItemID == workItemID })
    ),
      let implementerID = sprintItem.implementerProfileID,
      let assignedImplementer = model.profiles.first(where: {
        $0.id == implementerID
      })
    {
      return assignedImplementer
    }
    return model.profiles.first { $0.role == .businessAnalyst }
      ?? model.profiles.first { $0.role == .lead }
      ?? model.profiles.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Ticket conversation", systemImage: "bubble.left.and.bubble.right")
          .font(.headline)
        Spacer()
      }
      .padding(16)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(displayedComments) { comment in
              TicketCommentBubble(
                comment: comment,
                authorProfile: model.profiles.first { $0.name == comment.authorName },
                mentionedProfile: mentionedProfile(
                  in: comment.body,
                  profiles: model.profiles
                )
              )
            }

            if isShowingRefinementChoices {
              refinementQuestionCards
            }

            if showsReview {
              reviewContent
            }

            Color.clear
              .frame(height: 1)
              .id("ticket-conversation-bottom")
          }
          .padding(14)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
          if showsEmptyConversation {
            VStack(spacing: 7) {
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.title3)
                .foregroundStyle(.tertiary)
              Text("No messages yet")
                .font(.subheadline.weight(.medium))
              Text("Ask for clarification or request a ticket review.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .onChange(of: comments.count) { _, _ in
          Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo("ticket-conversation-bottom", anchor: .bottom)
            }
          }
        }
        .onChange(of: showsReview) { wasShowing, isShowing in
          if wasShowing && !isShowing {
            proxy.scrollTo("ticket-conversation-bottom", anchor: .bottom)
            Task { @MainActor in
              await Task.yield()
              proxy.scrollTo("ticket-conversation-bottom", anchor: .bottom)
            }
          } else {
            Task { @MainActor in
              await Task.yield()
              withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("ticket-conversation-bottom", anchor: .bottom)
              }
            }
          }
        }
      }

      Divider()

      if isShowingRefinementChoices && !isAnyAgentResponding {
        let tint = businessAnalyst?.role.tint ?? Color.purple
        HStack(spacing: 8) {
          Image(systemName: "questionmark.bubble.fill")
            .foregroundStyle(tint)
          HStack(spacing: 0) {
            Text(businessAnalyst?.name ?? "Business Analyst")
              .fontWeight(.semibold)
              .foregroundStyle(tint)
            Text(
              canSubmitRefinementAnswers
                ? " has your answers."
                : " is waiting for your response."
            )
            .foregroundStyle(.secondary)
          }
          .font(.caption)
          Spacer()
          Button("Continue") {
            submitRefinementAnswers()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(!canSubmitRefinementAnswers)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(tint.opacity(0.075))
      } else if isAnyAgentResponding {
        let teammate = activeStatusProfile ?? businessAnalyst
        let tint = teammate?.role.tint ?? Color.purple
        HStack(spacing: 7) {
          ProgressView()
            .controlSize(.mini)
            .tint(tint)
          HStack(spacing: 0) {
            Text(teammate?.name ?? "Business Analyst")
              .fontWeight(.semibold)
              .foregroundStyle(tint)
            Text(
              isAgentResponding
                ? isAwaitingRefinementAnswer
                  ? " is reviewing your response…"
                  : " is reviewing this ticket…"
                : " is thinking…"
            )
              .foregroundStyle(.secondary)
          }
          .font(.caption)
          Spacer()
          Button("Stop") {
            if isAgentResponding {
              onStopRefinement()
            } else {
              model.cancelTicketConversationMessage()
            }
          }
          .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(tint.opacity(0.075))
      }

      if !isAwaitingRefinementAnswer {
        VStack(alignment: .leading, spacing: 9) {
        if !isAwaitingRefinementAnswer && !isAnyAgentResponding {
          HStack {
            Text("To")
              .font(.caption)
              .foregroundStyle(.secondary)
            Menu {
              ForEach(model.profiles) { profile in
                Button {
                  recipientID = profile.id
                } label: {
                  HStack {
                    Label(profile.name, systemImage: profile.role.symbolName)
                    if recipientID == profile.id {
                      Image(systemName: "checkmark")
                    }
                  }
                }
              }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: selectedRecipient?.role.symbolName ?? "person")
                  .foregroundStyle(selectedRecipient?.role.tint ?? Color.secondary)
                Text(selectedRecipient?.name ?? "Choose a teammate")
                  .foregroundStyle(selectedRecipient?.role.tint ?? Color.secondary)
                Image(systemName: "chevron.down")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .padding(.horizontal, 9)
              .padding(.vertical, 5)
              .background(
                (selectedRecipient?.role.tint ?? Color.secondary).opacity(0.1),
                in: Capsule()
              )
            }
            .menuStyle(.borderlessButton)
            Spacer()
          }
        }

        if let sendError {
          Label(sendError, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }

        ZStack(alignment: .topLeading) {
          if message.isEmpty && !isComposerFocused {
            Text("Ask a question or request a change…")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
          TextEditor(text: $message)
            .scrollContentBackground(.hidden)
            .font(.body)
            .focused($isComposerFocused)
            .padding(8)
            .onKeyPress(phases: .down) { keyPress in
              guard keyPress.key == .return else {
                return .ignored
              }
              if keyPress.modifiers.contains(.shift) {
                return .ignored
              }
              if canSendMessage {
                send()
              }
              return .handled
            }
        }
        .frame(height: 74)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }

        HStack(alignment: .center) {
          Text("Return to send · Shift-Return for a new line")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Spacer()
          Button(isSending ? "Sending…" : "Send") { send() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canSendMessage)
        }
      }
      .padding(14)
      .background(.quaternary.opacity(0.25))
      }
    }
    .task(id: refreshToken) {
      comments = await model.comments(for: workItemID)
      if recipientID == nil {
        recipientID = defaultRecipient?.id
      }
    }
    .onChange(of: model.ticketConversationWorkItemID) { previousID, currentID in
      guard previousID == workItemID || currentID == workItemID else { return }
      Task {
        comments = await model.comments(for: workItemID)
      }
    }
    .onChange(of: refinementQuestions) { _, _ in
      selectedRefinementOptions.removeAll()
      otherRefinementAnswers.removeAll()
      hasSubmittedRefinementAnswers = false
    }
  }

  private var refinementQuestionCards: some View {
    let tint = businessAnalyst?.role.tint ?? Color.purple
    return HStack(alignment: .top, spacing: 9) {
      ZStack {
        Circle()
          .fill(tint.opacity(0.12))
        Image(systemName: businessAnalyst?.role.symbolName ?? "questionmark.bubble")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(tint)
      }
      .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 7) {
          Text(businessAnalyst?.name ?? "Business Analyst")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
          Image(systemName: businessAnalyst?.role.symbolName ?? "questionmark.bubble")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
          if let pendingRefinementComment {
            Text(pendingRefinementComment.createdAt, style: .time)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }

        VStack(alignment: .leading, spacing: 9) {
          ForEach(Array(refinementQuestions.enumerated()), id: \.offset) { index, question in
            VStack(alignment: .leading, spacing: 9) {
              if refinementQuestions.count > 1 {
                Text("Question \(index + 1) of \(refinementQuestions.count)")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(tint)
              }
              Text(question.prompt)
                .font(.callout.weight(.medium))

              VStack(spacing: 6) {
                ForEach(question.options, id: \.self) { option in
                  refinementChoiceRow(
                    option,
                    tint: tint,
                    isSelected: selectedRefinementOptions[index] == option
                  ) {
                    selectedRefinementOptions[index] = option
                  }
                }
                refinementChoiceRow(
                  "Other",
                  tint: tint,
                  isSelected: selectedRefinementOptions[index] == otherChoiceKey
                ) {
                  selectedRefinementOptions[index] = otherChoiceKey
                }
              }

              if selectedRefinementOptions[index] == otherChoiceKey {
                TextField(
                  "Type another answer",
                  text: Binding(
                    get: { otherRefinementAnswers[index] ?? "" },
                    set: { otherRefinementAnswers[index] = $0 }
                  )
                )
                .textFieldStyle(.roundedBorder)
              }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
          }
        }
        .frame(maxWidth: 380, alignment: .leading)
      }
      Spacer(minLength: 36)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func refinementChoiceRow(
    _ label: String,
    tint: Color,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
          .font(.caption)
          .foregroundStyle(isSelected ? tint : Color.secondary)
        Text(label)
          .font(.callout)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      RefinementChoiceButtonStyle(
        tint: tint,
        isSelected: isSelected
      )
    )
  }

  private func submitRefinementAnswers() {
    guard canSubmitRefinementAnswers else { return }
    let selectedAnswers = refinementQuestions.enumerated().map { index, _ in
      let selection = selectedRefinementOptions[index] ?? ""
      return
        selection == otherChoiceKey
        ? (otherRefinementAnswers[index] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        : selection
    }
    let answer =
      selectedAnswers.count == 1
      ? selectedAnswers[0]
      : selectedAnswers.enumerated().map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")
    hasSubmittedRefinementAnswers = true
    send(ownerMessage: answer)
  }

  private func send(ownerMessage explicitMessage: String? = nil) {
    let ownerMessage = (explicitMessage ?? message)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let recipient = selectedRecipient, canSend(ownerMessage) else { return }
    isSending = true
    sendError = nil
    let body = "@\(recipient.name) \(ownerMessage)"
    if !isAwaitingRefinementAnswer {
      respondingRecipientID = recipient.id
    }
    Task {
      if let comment = await model.appendOwnerComment(workItemID: workItemID, body: body) {
        comments.append(comment)
        message = ""
        if isAwaitingRefinementAnswer {
          await onRefinementAnswer?(ownerMessage)
        } else if let savedItem = model.workItems.first(where: { $0.id == workItemID }) {
          do {
            let savedSnapshot = SprintPlanningTicketSnapshot(item: savedItem)
            let base =
              if let ticketSnapshot, ticketSnapshot.version == savedItem.version {
                ticketSnapshot
              } else {
                savedSnapshot
              }
            let conversationItem = base.applying(to: savedItem)
            let reply = try await model.sendTicketConversationMessage(
              for: conversationItem,
              to: recipient,
              ownerMessage: ownerMessage
            )
            if let proposal = reply.proposal {
              onChatProposal(proposal, base, recipient)
            }
          } catch {
            sendError = error.localizedDescription
          }
        } else {
          sendError = "This ticket is no longer available."
        }
        comments = await model.comments(for: workItemID)
      } else {
        sendError = model.errorMessage ?? "Your message couldn't be saved. Try again."
        if isAwaitingRefinementAnswer {
          hasSubmittedRefinementAnswers = false
        }
      }
      respondingRecipientID = nil
      isSending = false
    }
  }
}

private struct RefinementChoiceButtonStyle: ButtonStyle {
  let tint: Color
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        isSelected
          ? tint.opacity(configuration.isPressed ? 0.24 : 0.16)
          : Color(nsColor: .controlBackgroundColor)
            .opacity(configuration.isPressed ? 0.72 : 0.52),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isSelected
              ? tint.opacity(0.55)
              : Color.primary.opacity(0.10),
            lineWidth: isSelected ? 1.2 : 0.8
          )
      }
      .scaleEffect(configuration.isPressed ? 0.992 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private func mentionedProfile(
  in body: String,
  profiles: [AgentProfile]
) -> AgentProfile? {
  profiles
    .sorted { $0.name.count > $1.name.count }
    .first { body.hasPrefix("@\($0.name) ") }
}

private struct TicketCommentBubble: View {
  let comment: TicketComment
  let authorProfile: AgentProfile?
  let mentionedProfile: AgentProfile?

  init(
    comment: TicketComment,
    authorProfile: AgentProfile? = nil,
    mentionedProfile: AgentProfile? = nil
  ) {
    self.comment = comment
    self.authorProfile = authorProfile
    self.mentionedProfile = mentionedProfile
  }

  private var accent: Color {
    switch comment.authorKind {
    case .owner: .blue
    case .agent: authorProfile?.role.tint ?? .indigo
    case .system: .secondary
    }
  }

  private var symbolName: String {
    switch comment.authorKind {
    case .owner: "person.fill"
    case .agent: authorProfile?.role.symbolName ?? "sparkles"
    case .system: "gearshape.fill"
    }
  }

  private var displayName: String {
    comment.authorKind == .owner ? "Me" : comment.authorName
  }

  private var isOwner: Bool {
    comment.authorKind == .owner
  }

  private var avatar: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(0.13))
      Image(systemName: symbolName)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(accent)
    }
    .frame(width: 28, height: 28)
  }

  private var messageContent: some View {
    VStack(alignment: isOwner ? .trailing : .leading, spacing: 5) {
      HStack(spacing: 7) {
        if isOwner {
          Text(comment.createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
        } else {
          Text(displayName)
            .font(
              comment.authorKind == .agent
                ? .subheadline.weight(.semibold)
                : .caption.weight(.semibold)
            )
            .foregroundStyle(comment.authorKind == .agent ? accent : Color.primary)
          if comment.authorKind == .agent, let authorProfile {
            Image(systemName: authorProfile.role.symbolName)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(accent)
              .help(authorProfile.role.capabilityTitle)
          }
          Text(comment.createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      TicketMarkdownDocument(
        source: comment.body,
        baseFont: .callout,
        highlightedText: mentionedProfile.map { "@\($0.name)" },
        highlightedColor: mentionedProfile?.role.tint
      )
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 340, alignment: isOwner ? .trailing : .leading)
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      if isOwner {
        Spacer(minLength: 44)
        messageContent
        avatar
      } else {
        avatar
        messageContent
        Spacer(minLength: 44)
      }
    }
    .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
  }
}

private struct NewTicketView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let initialEpicID: UUID?
  let onCreated: (WorkItem, Bool) -> Void
  @State private var outcome = ""
  @State private var selectedEpicID: UUID?
  @State private var isCreating = false

  init(
    isPresented: Binding<Bool>,
    initialEpicID: UUID?,
    onCreated: @escaping (WorkItem, Bool) -> Void
  ) {
    _isPresented = isPresented
    self.initialEpicID = initialEpicID
    self.onCreated = onCreated
    _selectedEpicID = State(initialValue: initialEpicID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New ticket")
          .font(.title.bold())
        Text(
          "Describe the outcome. The Business Analyst will turn it into a delivery-ready ticket for your review."
        )
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          EditableTextArea(
            title: "What do you want to achieve?",
            prompt: "e.g. Let customers search for a location and see its current weather.",
            text: $outcome,
            minHeight: 138
          )

          VStack(alignment: .leading, spacing: 7) {
            Text("Epic")
              .font(.subheadline.weight(.semibold))
            Picker("Epic", selection: $selectedEpicID) {
              Text("No epic").tag(UUID?.none)
              ForEach(model.epics) { epic in
                Text(epic.title).tag(Optional(epic.id))
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)
          }

          Label(
            model.canRefineTicket
              ? "The ticket is saved immediately, then the Business Analyst asks questions and proposes reviewable improvements."
              : "The ticket is saved as a draft. You can refine it with AI when the team connection is available.",
            systemImage: "checkmark.shield"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(24)
      }

      Divider()
      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button {
          create()
        } label: {
          Label(isCreating ? "Creating…" : "Create ticket", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(!canCreate)
      }
      .padding(20)
    }
    .background(InitialFocusClearer())
    .frame(width: 660, height: 470)
  }

  private var canCreate: Bool {
    !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
  }

  private func create() {
    guard canCreate else { return }
    isCreating = true
    Task {
      let item = await model.createWorkItem(
        title: outcome.trimmingCharacters(in: .whitespacesAndNewlines),
        type: .story,
        body: "",
        acceptanceCriteria: [],
        priority: .normal,
        dependsOnWorkItemIDs: [],
        epicID: selectedEpicID
      )
      isCreating = false
      if let item {
        onCreated(item, model.canRefineTicket)
      }
    }
  }
}

private struct NewEpicView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var outcome = ""
  @State private var isCreating = false
  @State private var createdEpic: Epic?

  var body: some View {
    if let createdEpic {
      EpicDetailView(
        epic: createdEpic,
        startPlanningOnAppear: true,
        onClose: { isPresented = false }
      )
    } else {
      captureView
    }
  }

  private var captureView: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(model.epics.isEmpty ? "Plan your first outcome" : "New epic")
          .font(.title.bold())
        Text(
          "Describe the product outcome. The Business Analyst will shape the epic and propose the tickets needed to deliver it."
        )
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        EditableTextArea(
          title: "What outcome do you want to deliver?",
          prompt: "e.g. Customers can save locations and quickly compare their forecasts.",
          text: $outcome,
          minHeight: 150
        )
        Label(
          model.canPlanEpic
            ? "The proposed title, success criteria, tickets, dependencies and owners remain reviewable."
            : "The outcome will be saved as a draft and can be planned when the team connection is available.",
          systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(24)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button {
          create()
        } label: {
          Label(isCreating ? "Creating…" : "Create epic", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(!canCreate)
      }
      .padding(20)
    }
    .background(InitialFocusClearer())
    .frame(width: 660, height: 480)
  }

  private var canCreate: Bool {
    !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
  }

  private func create() {
    guard canCreate else { return }
    isCreating = true
    Task {
      let epic = await model.createEpic(
        outcome: outcome.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      isCreating = false
      if let epic {
        createdEpic = epic
      }
    }
  }
}

private struct EpicDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let epic: Epic
  let startPlanningOnAppear: Bool
  let onClose: (() -> Void)?
  @State private var title: String
  @State private var goal: String
  @State private var criteriaText: String
  @State private var constraints: String
  @State private var status: EpicStatus
  @State private var isSaving = false
  @State private var didStartPlanning = false

  init(
    epic: Epic,
    startPlanningOnAppear: Bool = false,
    onClose: (() -> Void)? = nil
  ) {
    self.epic = epic
    self.startPlanningOnAppear = startPlanningOnAppear
    self.onClose = onClose
    _title = State(initialValue: epic.title)
    _goal = State(initialValue: epic.goal)
    _criteriaText = State(initialValue: epic.successCriteria.joined(separator: "\n"))
    _constraints = State(initialValue: epic.constraints)
    _status = State(initialValue: epic.status)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "flag.checkered")
          .foregroundStyle(.purple)
        Text("Epic details")
          .font(.title2.bold())
        Spacer()
        if conversation == nil {
          Button {
            model.planEpic(epic)
          } label: {
            Label("Refine with AI", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .disabled(!model.canPlanEpic)
        }
        Button("Close", action: close)
      }
      .padding(22)
      Divider()

      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
              EditableTextField(title: "Title", prompt: "Epic title", text: $title)
              VStack(alignment: .leading, spacing: 7) {
                Text("Status")
                  .font(.subheadline.weight(.semibold))
                Picker("Status", selection: $status) {
                  ForEach(EpicStatus.allCases, id: \.self) { status in
                    Text(status.title).tag(status)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
              }
              .frame(width: 130, alignment: .leading)
            }
            EditableTextArea(
              title: "Goal and customer value",
              prompt: "What outcome should this epic create?",
              text: $goal,
              minHeight: 110
            )
            EditableTextArea(
              title: "Success criteria",
              prompt: "One measurable outcome per line",
              text: $criteriaText,
              minHeight: 130
            )
            EditableTextArea(
              title: "Constraints and context",
              prompt: "Material constraints only",
              text: $constraints,
              minHeight: 100
            )
          }
          .padding(22)
        }
        .frame(maxWidth: .infinity)

        Divider()

        EpicPlanningConversationPanel(epic: epic, onReviewProposals: close)
          .frame(width: 430)
      }

      Divider()
      HStack {
        Text(
          conversation?.isComplete == true
            ? "The proposed tickets are ready to review in the backlog."
            : "Resolve the outcome with the Business Analyst before tickets are proposed."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", action: close)
        Button("Save changes") { save() }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave || isSaving)
      }
      .padding(18)
    }
    .background(InitialFocusClearer())
    .frame(width: 1_080, height: 740)
    .task {
      guard startPlanningOnAppear, !didStartPlanning else { return }
      didStartPlanning = true
      if conversation == nil, model.canPlanEpic {
        model.planEpic(epic)
      }
    }
    .onChange(of: conversation?.isComplete == true) { _, isComplete in
      guard isComplete else { return }
      syncFromLatestEpic()
    }
  }

  private var conversation: EpicPlanningConversationState? {
    guard model.epicPlanningConversation?.epicID == epic.id else { return nil }
    return model.epicPlanningConversation
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func close() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    Task {
      _ = await model.updateEpic(
        epic,
        title: title,
        goal: goal,
        successCriteria: criteriaText
          .split(separator: "\n")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty },
        constraints: constraints,
        status: status
      )
      isSaving = false
    }
  }

  private func syncFromLatestEpic() {
    guard let latest = model.epics.first(where: { $0.id == epic.id }) else { return }
    title = latest.title
    goal = latest.goal
    criteriaText = latest.successCriteria.joined(separator: "\n")
    constraints = latest.constraints
    status = latest.status
  }
}

private struct EpicPlanningConversationPanel: View {
  @EnvironmentObject private var model: AppModel
  let epic: Epic
  let onReviewProposals: () -> Void
  @State private var selectedOptions: [Int: String] = [:]
  @State private var otherAnswers: [Int: String] = [:]

  private let otherChoice = "__other__"

  private var conversation: EpicPlanningConversationState? {
    guard model.epicPlanningConversation?.epicID == epic.id else { return nil }
    return model.epicPlanningConversation
  }

  private var analyst: AgentProfile? {
    model.profiles.first { $0.role == .businessAnalyst }
  }

  private var tint: Color {
    analyst?.role.tint ?? .purple
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Epic conversation", systemImage: "bubble.left.and.bubble.right")
          .font(.headline)
        Spacer()
      }
      .padding(16)
      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if let conversation {
              ForEach(conversation.messages) { message in
                messageRow(message)
              }
              if !conversation.questions.isEmpty {
                questionCards(conversation.questions)
              }
            }
            Color.clear.frame(height: 1).id("epic-conversation-bottom")
          }
          .padding(14)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
          if conversation == nil {
            VStack(spacing: 7) {
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.title3)
                .foregroundStyle(.tertiary)
              Text("No conversation yet")
                .font(.subheadline.weight(.medium))
              Text("Refine the epic with the Business Analyst before tickets are proposed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(28)
          }
        }
        .onChange(of: conversation?.messages.count ?? 0) { _, _ in
          Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo("epic-conversation-bottom", anchor: .bottom)
            }
          }
        }
      }

      Divider()
      conversationStatus
    }
    .onChange(of: conversation?.questions ?? []) { _, _ in
      selectedOptions.removeAll()
      otherAnswers.removeAll()
    }
  }

  @ViewBuilder
  private var conversationStatus: some View {
    if let conversation {
      if conversation.isRunning || conversation.isGeneratingPlan {
        HStack(spacing: 8) {
          ProgressView().controlSize(.mini).tint(tint)
          Text(
            conversation.isGeneratingPlan
              ? "\(analyst?.name ?? "Business Analyst") is preparing the epic and tickets…"
              : "\(analyst?.name ?? "Business Analyst") is thinking…"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Spacer()
          Button("Stop") { model.cancelEpicPlanning() }
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(tint.opacity(0.075))
      } else if conversation.isComplete {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Proposed tickets are ready.")
            .font(.caption)
          Spacer()
          Button("Review in backlog") {
            model.backlogFocusEpicID = epic.id
            onReviewProposals()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
        .padding(14)
      } else if !conversation.questions.isEmpty {
        HStack {
          Text("\(analyst?.name ?? "Business Analyst") is waiting for your response.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Continue") { submitAnswers(conversation.questions) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canSubmit(conversation.questions))
        }
        .padding(14)
        .background(tint.opacity(0.075))
      } else if let error = conversation.errorMessage {
        VStack(alignment: .leading, spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
          Button("Try again") {
            model.clearEpicPlanningConversation(for: epic.id)
            model.planEpic(epic)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
        .padding(14)
      }
    }
  }

  @ViewBuilder
  private func messageRow(_ message: EpicPlanningConversationMessage) -> some View {
    let isOwner = message.author == .owner
    HStack(alignment: .top, spacing: 8) {
      if isOwner { Spacer(minLength: 46) }
      if !isOwner {
        Circle()
          .fill(tint.opacity(0.12))
          .overlay {
            Image(systemName: analyst?.role.symbolName ?? "text.magnifyingglass")
              .font(.caption)
              .foregroundStyle(tint)
          }
          .frame(width: 28, height: 28)
      }
      VStack(alignment: isOwner ? .trailing : .leading, spacing: 4) {
        Text(isOwner ? "Me" : analyst?.name ?? "Business Analyst")
          .font(.caption.weight(.semibold))
          .foregroundStyle(isOwner ? Color.primary : tint)
        Text(message.body)
          .font(.callout)
          .textSelection(.enabled)
          .padding(.horizontal, 11)
          .padding(.vertical, 9)
          .background(
            isOwner ? Color.accentColor.opacity(0.1) : tint.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 11)
          )
      }
      if isOwner {
        Circle()
          .fill(Color.accentColor.opacity(0.12))
          .overlay {
            Image(systemName: "person.fill")
              .font(.caption)
              .foregroundStyle(Color.accentColor)
          }
          .frame(width: 28, height: 28)
      } else {
        Spacer(minLength: 46)
      }
    }
  }

  private func questionCards(_ questions: [TicketRefinementQuestion]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
        VStack(alignment: .leading, spacing: 9) {
          if questions.count > 1 {
            Text("Question \(index + 1) of \(questions.count)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(tint)
          }
          Text(question.prompt)
            .font(.callout.weight(.medium))
          VStack(spacing: 6) {
            ForEach(question.options, id: \.self) { option in
              choiceRow(option, selected: selectedOptions[index] == option) {
                selectedOptions[index] = option
              }
            }
            choiceRow("Other", selected: selectedOptions[index] == otherChoice) {
              selectedOptions[index] = otherChoice
            }
          }
          if selectedOptions[index] == otherChoice {
            TextField(
              "Type another answer",
              text: Binding(
                get: { otherAnswers[index] ?? "" },
                set: { otherAnswers[index] = $0 }
              )
            )
            .textFieldStyle(.roundedBorder)
          }
        }
        .padding(11)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 11))
      }
    }
  }

  private func choiceRow(
    _ label: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .font(.caption)
          .foregroundStyle(selected ? tint : Color.secondary)
        Text(label)
          .font(.callout)
          .foregroundStyle(Color.primary)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        selected ? tint.opacity(0.14) : Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 8)
      )
    }
    .buttonStyle(.plain)
  }

  private func canSubmit(_ questions: [TicketRefinementQuestion]) -> Bool {
    questions.indices.allSatisfy { index in
      guard let option = selectedOptions[index] else { return false }
      if option == otherChoice {
        return !(otherAnswers[index] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return true
    }
  }

  private func submitAnswers(_ questions: [TicketRefinementQuestion]) {
    guard canSubmit(questions) else { return }
    let answers = questions.enumerated().map { index, question in
      let selection = selectedOptions[index] ?? ""
      let answer =
        selection == otherChoice
        ? (otherAnswers[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        : selection
      return "\(question.prompt)\nAnswer: \(answer)"
    }
    model.continueEpicPlanning(epic, answers: answers)
  }
}

private struct InitialFocusClearer: NSViewRepresentable {
  func makeNSView(context: Context) -> FocusClearingView {
    FocusClearingView()
  }

  func updateNSView(_ nsView: FocusClearingView, context: Context) {}

  final class FocusClearingView: NSView {
    private var hasClearedInitialFocus = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, !hasClearedInitialFocus else { return }
      hasClearedInitialFocus = true
      window.initialFirstResponder = self
      window.makeFirstResponder(self)
    }
  }
}

private struct EditableTextField: View {
  let title: String
  let prompt: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }
  }
}

private struct EditableTextArea: View {
  let title: String
  let prompt: String
  @Binding var text: String
  let statusText: String?
  let minHeight: CGFloat

  init(
    title: String,
    prompt: String,
    text: Binding<String>,
    statusText: String? = nil,
    minHeight: CGFloat
  ) {
    self.title = title
    self.prompt = prompt
    _text = text
    self.statusText = statusText
    self.minHeight = minHeight
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        if let statusText {
          Label(statusText, systemImage: "exclamationmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
      }
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text(prompt)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .allowsHitTesting(false)
        }
        TextEditor(text: $text)
          .scrollContentBackground(.hidden)
          .multilineTextAlignment(.leading)
          .font(.body)
          .padding(8)
      }
      .frame(minHeight: minHeight)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.separator.opacity(0.7), lineWidth: 1)
      }
    }
  }
}

extension WorkItemType {
  fileprivate var symbolName: String {
    switch self {
    case .story: "person.crop.circle.badge.checkmark"
    case .task: "list.bullet.rectangle"
    case .bug: "ladybug"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .story: .green
    case .task: .blue
    case .bug: .red
    }
  }

  fileprivate var titlePrompt: String {
    switch self {
    case .story: "User outcome"
    case .task: "Task outcome"
    case .bug: "What isn't working?"
    }
  }

  fileprivate var contextPrompt: String {
    switch self {
    case .story: "Who needs this, and why?"
    case .task: "What must be delivered, and why?"
    case .bug: "Expected behavior, actual behavior, and reproduction steps"
    }
  }

  fileprivate var criteriaPrompt: String {
    switch self {
    case .bug: "Fix criteria and regression evidence, one per line"
    default: "Acceptance criteria, one per line"
    }
  }
}

extension AgentRole {
  fileprivate var symbolName: String {
    switch self {
    case .businessAnalyst: "text.magnifyingglass"
    case .uxDesigner: "paintbrush.pointed"
    case .lead: "point.3.connected.trianglepath.dotted"
    case .implementer: "hammer"
    case .frontendEngineer: "macwindow"
    case .backendEngineer: "server.rack"
    case .reviewer: "checkmark.seal"
    case .qualityAssurance: "testtube.2"
    case .knowledgeCurator: "books.vertical"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .businessAnalyst: .purple
    case .uxDesigner: .pink
    case .lead: .orange
    case .implementer: .blue
    case .frontendEngineer: .cyan
    case .backendEngineer: .indigo
    case .reviewer: .green
    case .qualityAssurance: .pink
    case .knowledgeCurator: .indigo
    }
  }
}

extension WorkItemPriority {
  fileprivate var tint: Color {
    switch self {
    case .urgent: .red
    case .high: .orange
    case .normal: .blue
    case .low: .gray
    }
  }
}

extension AgentRunStatus {
  fileprivate var activityTitle: String {
    switch self {
    case .queued: "Waiting"
    case .running: "Working"
    case .awaitingOwner: "Needs you"
    case .interrupted: "Interrupted"
    case .completed: "Finished"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }

  fileprivate var activitySymbol: String {
    switch self {
    case .queued: "clock"
    case .running: "bolt.fill"
    case .awaitingOwner: "hand.raised.fill"
    case .interrupted: "pause.circle.fill"
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .cancelled: "xmark.circle.fill"
    }
  }

  fileprivate var activityTint: Color {
    switch self {
    case .queued: Color(nsColor: .secondaryLabelColor)
    case .running: .blue
    case .awaitingOwner: .orange
    case .interrupted: .orange
    case .completed: .green
    case .failed: .red
    case .cancelled: Color(nsColor: .secondaryLabelColor)
    }
  }
}

extension WorkItemState {
  fileprivate var ownerFacingActivity: String? {
    switch self {
    case .queued: "Waiting to start"
    case .running: "Building"
    case .integrating: "Combining changes"
    case .verifying: "Checking quality"
    case .acceptance: "Ready for you"
    case .readyToRelease: "Finishing approved work"
    case .released: "Completed"
    default: nil
    }
  }

  fileprivate var activitySymbol: String {
    switch self {
    case .queued: "clock"
    case .running: "hammer"
    case .integrating: "arrow.triangle.merge"
    case .verifying: "checkmark.shield"
    case .acceptance: "play.rectangle"
    case .readyToRelease: "shippingbox"
    case .released: "checkmark.circle.fill"
    default: "circle"
    }
  }

  fileprivate var activityTint: Color {
    switch self {
    case .backlog, .refining, .ready, .queued:
      Color(nsColor: .secondaryLabelColor)
    case .running, .integrating, .verifying:
      .blue
    case .acceptance:
      .orange
    case .readyToRelease:
      .purple
    case .released:
      .green
    case .cancelled:
      .red
    }
  }
}

extension CodexConnectionState {
  fileprivate var detail: String {
    switch self {
    case .notChecked: "Not checked"
    case .checking: "Checking compatibility…"
    case .connected(let version, _): "Connected · \(version)"
    case .unavailable: "Not available"
    case .incompatible: "Update required"
    }
  }

  fileprivate var symbolName: String {
    switch self {
    case .notChecked: "circle.dashed"
    case .checking: "arrow.triangle.2.circlepath"
    case .connected: "checkmark.circle.fill"
    case .unavailable: "xmark.circle"
    case .incompatible: "exclamationmark.triangle.fill"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .connected: .green
    case .incompatible: .orange
    case .unavailable: .red
    default: .secondary
    }
  }
}

extension String {
  fileprivate var displayEffort: String {
    switch lowercased() {
    case "low": "Low"
    case "medium": "Medium"
    case "high": "High"
    case "xhigh": "Extra High"
    case "max": "Max"
    case "ultra": "Ultra"
    default: capitalized
    }
  }
}
