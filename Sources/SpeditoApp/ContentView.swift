import AppKit
import Charts
import SpeditoCore
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

struct ConversationDetailSheetSizing {
  static func size(for containerSize: CGSize) -> CGSize {
    CGSize(
      width: min(1_080, max(900, containerSize.width - 72)),
      height: min(740, max(620, containerSize.height - 72))
    )
  }

  static func conversationWidth(for detailWidth: CGFloat) -> CGFloat {
    min(430, max(360, detailWidth * 0.4))
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
      "Spedito couldn't complete that action",
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
  @State private var isCreating = false
  @State private var showingProductLibrary = false

  var body: some View {
    ZStack {
      ProductOnboardingBackdrop()
        .ignoresSafeArea(.container, edges: .top)

      VStack(spacing: 22) {
        Image(systemName: "shippingbox.fill")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 64, height: 64)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

        VStack(spacing: 8) {
          Text("What are you building?")
            .font(.largeTitle.bold())
          Text("Choose a product name. You can change it later.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
        }

        ProductNameEntryField(
          text: $name,
          isDisabled: isCreating,
          onSubmit: createProduct
        )
        .frame(width: 420)

        HStack(spacing: 10) {
          if !model.archivedProducts.isEmpty {
            Button("View archived products") {
              showingProductLibrary = true
            }
            .buttonStyle(.bordered)
            .disabled(isCreating)
          }

          Button(isCreating ? "Creating…" : "Create product") {
            createProduct()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedName.isEmpty || isCreating)
        }
        .controlSize(.large)
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showingProductLibrary) {
      ProductLibraryView(
        isPresented: $showingProductLibrary,
        initiallyShowingArchived: true,
        onOpenProduct: {}
      )
    }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func createProduct() {
    guard !trimmedName.isEmpty, !isCreating else { return }
    isCreating = true
    Task {
      _ = await model.createProductAndSelect(name: trimmedName)
      isCreating = false
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
          if
            let iconURL = SpeditoResources.url(
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
            title: "Made for Product Owners",
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

private enum WorkspaceDestination: String, Hashable {
  case conversation
  case backlog
  case sprint
  case retrospectives
  case reports
  case knowledge
  case codebase
}

enum SprintBoardSelectionDefaults {
  private static let prefix = "sprintBoardSelection"

  static func selectedSprintID(for productID: UUID) -> UUID? {
    UserDefaults.standard.string(forKey: key(for: productID))
      .flatMap(UUID.init(uuidString:))
  }

  static func select(_ sprintID: UUID?, for productID: UUID) {
    if let sprintID {
      UserDefaults.standard.set(sprintID.uuidString, forKey: key(for: productID))
    } else {
      UserDefaults.standard.removeObject(forKey: key(for: productID))
    }
  }

  private static func key(for productID: UUID) -> String {
    "\(prefix).\(productID.uuidString)"
  }
}

struct SprintPermissionRequestPresentation: Equatable {
  static let existingAccessTitle = "Existing access used"
  static let existingAccessSummary =
    "Spedito continued using access already available to this run. No permissions changed."
  static let protectedStorageTitle = "Protected Spedito storage"
  static let protectedStorageSummary =
    "Spedito kept this delivery run out of storage owned by another execution. No Product Owner decision was needed."

  let context: String
  let purpose: String
  let detailTitle: String

  init(request: AgentPermissionRequest) {
    let statedReason = request.reason?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackPurpose: String

    switch request.kind {
    case .command:
      context = "The agent wants to run a local project command."
      fallbackPurpose = "Run a project command needed to continue this ticket."
      detailTitle = request.detail.contains("Additional access for this command:")
        ? "Exact command and access"
        : "Exact command"
    case .permissions:
      context = "The agent needs access outside its current ticket workspace."
      fallbackPurpose = "Use an additional capability needed to continue this ticket."
      detailTitle = "Exact access"
    case .fileChange:
      context = "The agent wants to change a file outside its current ticket workspace."
      fallbackPurpose = "Make a file change needed to continue this ticket."
      detailTitle = "Requested file change"
    }

    purpose = if let statedReason, !statedReason.isEmpty {
      statedReason
    } else {
      fallbackPurpose
    }
  }
}

enum RetrospectiveSprintSelection {
  static func preferredSprintID(in plans: [SprintPlan]) -> UUID? {
    plans
      .filter { $0.sprint.state == .completed }
      .max { $0.sprint.number < $1.sprint.number }?
      .sprint.id
      ?? plans
        .filter { $0.sprint.state.isInProgress }
        .max { $0.sprint.number < $1.sprint.number }?
        .sprint.id
  }
}

enum RetrospectivePhase: Equatable {
  case collecting
  case reviewing
  case concluded

  var pickerTitle: String {
    switch self {
    case .collecting: "In progress"
    case .reviewing: "Needs conclusion"
    case .concluded: "Concluded"
    }
  }

  init(sprint: Sprint) {
    if sprint.retrospectiveConcludedAt != nil {
      self = .concluded
    } else if sprint.state == .completed {
      self = .reviewing
    } else {
      self = .collecting
    }
  }
}

struct RetrospectiveActionAttribution: Equatable {
  let authorNames: [String]
  let profileIDs: Set<UUID>

  var summary: String {
    authorNames.joined(separator: ", ")
  }

  static func resolve(
    sourceNotes: [RetrospectiveNote],
    fallbackAuthorName: String,
    fallbackProfileID: UUID?
  ) -> RetrospectiveActionAttribution {
    var seenAuthorNames: Set<String> = []
    var authorNames: [String] = []
    var profileIDs: Set<UUID> = []

    for source in sourceNotes {
      let authorName = source.authorName.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !authorName.isEmpty else { continue }
      if seenAuthorNames.insert(authorName).inserted {
        authorNames.append(authorName)
      }
      if let profileID = source.profileID {
        profileIDs.insert(profileID)
      }
    }

    if authorNames.isEmpty {
      let fallback = fallbackAuthorName.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      authorNames = [fallback.isEmpty ? "Unknown contributor" : fallback]
      if let fallbackProfileID {
        profileIDs.insert(fallbackProfileID)
      }
    }

    return RetrospectiveActionAttribution(
      authorNames: authorNames,
      profileIDs: profileIDs
    )
  }
}

struct SprintStartAvailability: Equatable {
  let blockingActiveSprintNumber: Int?

  var isBlocked: Bool {
    blockingActiveSprintNumber != nil
  }

  var explanation: String? {
    blockingActiveSprintNumber.map {
      "Finish or stop Sprint \($0) before starting this sprint."
    }
  }

  init(draft: SprintPlan, plans: [SprintPlan]) {
    blockingActiveSprintNumber = plans
      .filter {
        $0.sprint.state.isInProgress
          && $0.sprint.id != draft.sprint.id
      }
      .map(\.sprint.number)
      .max()
  }
}

private struct TicketDetailPresentation: Identifiable {
  enum Mode {
    case editable
    case delivery
  }

  let item: WorkItem
  let startRefinementOnAppear: Bool
  let mode: Mode

  var id: UUID { item.id }
}

private struct ProductWorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic
  @State private var destination = WorkspaceDestination.backlog
  @State private var showingNewTicket = false
  @State private var showingNewEpic = false
  @State private var newTicketEpicID: UUID?
  @State private var showingSprintPlanning = false
  @State private var showingProductLibrary = false
  @State private var ticketDetailPresentation: TicketDetailPresentation?
  @State private var selectedSprintID: UUID?

  private static let destinationDefaultsPrefix = "workspaceDestination"

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      TeamSidebar(
        selection: $destination,
        onShowProducts: { showingProductLibrary = true }
      )
        .navigationSplitViewColumnWidth(min: 232, ideal: 262, max: 320)
    } detail: {
      Group {
        switch destination {
        case .conversation:
          ProductConversationView()
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
            selectedSprintID: $selectedSprintID,
            onShowBacklog: { destination = .backlog },
            onEditPlan: { showingSprintPlanning = true },
            onShowRetrospective: { destination = .retrospectives },
            onShowReports: { destination = .reports }
          )
        case .retrospectives:
          RetrospectivesView(
            onConcluded: { destination = .backlog },
            onOpenRefiningTicket: { item in
              ticketDetailPresentation = TicketDetailPresentation(
                item: item,
                startRefinementOnAppear: true,
                mode: .editable
              )
            }
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
                startRefinementOnAppear: false,
                mode: .delivery
              )
            }
          )
        }
      }
      .id(model.selectedProductID)
      .ignoresSafeArea(
        .container,
        edges: columnVisibility == .detailOnly ? [] : .top
      )
    }
    .onAppear {
      restoreDestination(for: model.selectedProductID)
    }
    .onChange(of: model.selectedProductID) { _, productID in
      showingNewTicket = false
      showingNewEpic = false
      newTicketEpicID = nil
      showingSprintPlanning = false
      ticketDetailPresentation = nil
      selectedSprintID = nil
      restoreDestination(for: productID)
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
            guard
              !Task.isCancelled,
              model.selectedProductID == item.productID
            else { return }
            ticketDetailPresentation = TicketDetailPresentation(
              item: item,
              startRefinementOnAppear: shouldRefine,
              mode: .editable
            )
          }
        }
      )
    }
    .sheet(isPresented: $showingNewEpic) {
      NewEpicView(isPresented: $showingNewEpic)
    }
    .sheet(item: $ticketDetailPresentation) { presentation in
      switch presentation.mode {
      case .editable:
        TicketDetailView(
          item: presentation.item,
          dependsOnWorkItemIDs: [],
          startRefinementOnAppear: presentation.startRefinementOnAppear
        )
      case .delivery:
        SprintTicketDetailView(item: presentation.item)
      }
    }
    .sheet(isPresented: $showingSprintPlanning) {
      SprintPlanningView(
        isPresented: $showingSprintPlanning,
        onSaved: { sprintID in
          openSprintBoard(sprintID: sprintID)
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
      ?? (model.sprintPlan?.sprint.state.isInProgress == true ? .sprint : .backlog)
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

  private func openSprintBoard(sprintID: UUID) {
    selectedSprintID = sprintID
    if let productID = model.selectedProductID {
      SprintBoardSelectionDefaults.select(sprintID, for: productID)
    }
    destination = .sprint
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
      plan.sprint.state.isInProgress
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

  private func sidebarModelName(for profile: AgentProfile) -> String {
    let identifier = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
    let catalogName = model.modelOption(for: profile)?.displayName
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if let catalogName, !catalogName.isEmpty {
      let identifierParts = identifier.lowercased().split { !$0.isLetter && !$0.isNumber }
      let catalogParts = Set(
        catalogName.lowercased().split { !$0.isLetter && !$0.isNumber }
      )
      if identifierParts.allSatisfy(catalogParts.contains) {
        return catalogName
      }
    }

    return identifier.split(separator: "-", omittingEmptySubsequences: false)
      .map { component in
        switch component.lowercased() {
        case "gpt": "GPT"
        case "openai": "OpenAI"
        default: component.prefix(1).uppercased() + String(component.dropFirst())
        }
      }
      .joined(separator: "-")
  }

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $selection) {
        if let product = model.selectedProduct {
          Section("Product") {
            VStack(alignment: .leading, spacing: 9) {
              Button(action: onShowProducts) {
                HStack(spacing: 9) {
                  ProductIcon(product: product, size: 30)
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
                Label("Product settings", systemImage: "gearshape")
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
                .background(Color.accentColor, in: Capsule())
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

        Section("Team") {
          Label("Chat", systemImage: "bubble.left.and.bubble.right")
            .tag(WorkspaceDestination.conversation)

          HStack(spacing: 6) {
            Button {
              withAnimation(.easeInOut(duration: 0.16)) {
                isTeamExpanded.toggle()
              }
            } label: {
              HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .rotationEffect(.degrees(isTeamExpanded ? 90 : 0))
                  .frame(width: 12)
                Label("Team members", systemImage: "person.3")
                Spacer(minLength: 0)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isTeamExpanded ? "Collapse team members" : "Expand team members")
            .accessibilityLabel("Team members")
            .accessibilityValue(isTeamExpanded ? "Expanded" : "Collapsed")

            Button {
              showingTeamPrompts = true
            } label: {
              Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Configure team models, effort, and instructions")
            .accessibilityLabel("Team settings")
            .accessibilityHint("Configure models, effort, and instructions")
          }

          if isTeamExpanded {
            ForEach(model.profiles) { profile in
              HStack(alignment: .top, spacing: 9) {
                Image(systemName: profile.role.symbolName)
                  .frame(width: 20)
                  .foregroundStyle(profile.role.tint)
                  .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                  Text(profile.name)
                    .font(.callout.weight(.medium))
                  Text(profile.role.capabilityTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                  Text(
                    "\(sidebarModelName(for: profile)) · \(profile.reasoningEffort.displayEffort)"
                  )
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.leading, 19)
              .padding(.trailing, 8)
              .padding(.vertical, 4)
              .accessibilityElement(children: .combine)
              .transition(.opacity)
            }
          }
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
    .focusedSceneValue(
      \.workspaceCommandActions,
      WorkspaceCommandActions(perform: performWorkspaceCommand)
    )
  }

  private func performWorkspaceCommand(_ command: WorkspaceCommand) {
    switch command {
    case .backlog:
      selection = .backlog
    case .sprintBoard:
      selection = .sprint
    case .retrospectives:
      selection = .retrospectives
    case .reports:
      selection = .reports
    case .productKnowledge:
      selection = .knowledge
    case .codebase:
      selection = .codebase
    case .chat:
      selection = .conversation
    case .productSettings:
      showingTeamPrompts = false
      showingProductContext = true
    case .teamSettings:
      showingProductContext = false
      showingTeamPrompts = true
    }
  }
}

private struct ProductConversationView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selectedThreadID: UUID?
  @State private var selectedRecipientID: UUID?
  @State private var draft = ""
  @State private var isStartingThread = false
  @State private var showingArchived = false

  private var activeThreads: [ProductConversationThread] {
    model.conversationThreads.filter { !$0.isArchived }
  }

  private var archivedThreads: [ProductConversationThread] {
    model.conversationThreads.filter(\.isArchived)
  }

  private var selectedThread: ProductConversationThread? {
    model.conversationThreads.first { $0.id == selectedThreadID }
  }

  private var selectedRecipient: AgentProfile? {
    let recipientID = selectedRecipientID ?? selectedThread?.recipientProfileID
    return model.profiles.first { $0.id == recipientID }
  }

  private var messages: [ProductConversationMessage] {
    guard let selectedThreadID else { return [] }
    return model.conversationMessagesByThread[selectedThreadID] ?? []
  }

  private var isSelectedThreadResponding: Bool {
    guard let selectedThreadID else { return false }
    return model.respondingConversationThreadIDs.contains(selectedThreadID)
  }

  private var archiveThreadTitle: AttributedString {
    var title = AttributedString("Archive thread")
    title.foregroundColor = .red
    return title
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Chat")
          .font(.largeTitle.bold())
        Text("Ask your team about the product, delivery, and what needs your attention.")
          .foregroundStyle(.secondary)
      }
      .workspaceHeaderLayout()

      Divider()

      HSplitView {
        threadList
          .frame(idealWidth: 290, maxWidth: 360)
          .frame(maxHeight: .infinity)

        VStack(spacing: 0) {
          conversationHeader
          Divider()
          conversationTimeline
          Divider()
          conversationStatus
          if selectedThread?.isArchived == true {
            archivedThreadFooter
          } else {
            composer
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      if selectedThreadID == nil, let firstThread = activeThreads.first {
        selectedThreadID = firstThread.id
        selectedRecipientID = firstThread.recipientProfileID
      } else {
        synchronizeRecipientWithSelection()
      }
    }
    .onChange(of: model.selectedProductID) { _, _ in
      selectedThreadID = activeThreads.first?.id
      selectedRecipientID = nil
      draft = ""
      showingArchived = false
      synchronizeRecipientWithSelection()
    }
    .onChange(of: model.conversationThreads) { _, threads in
      let active = threads.filter { !$0.isArchived }
      if isStartingThread, let newest = active.first {
        selectedThreadID = newest.id
        isStartingThread = false
      } else if
        let selectedThreadID,
        !threads.contains(where: { thread in
          thread.id == selectedThreadID
            && (showingArchived || !thread.isArchived)
        })
      {
        self.selectedThreadID = active.first?.id
      }
    }
    .onChange(of: showingArchived) { _, isShowingArchived in
      if !isShowingArchived, selectedThread?.isArchived == true {
        selectedThreadID = activeThreads.first?.id
      }
    }
    .onChange(of: selectedThreadID) {
      synchronizeRecipientWithSelection()
    }
  }

  private var threadList: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Threads")
          .font(.headline)
        Spacer()
        Button {
          selectedThreadID = nil
          selectedRecipientID = nil
          draft = ""
          chooseDefaultRecipient()
        } label: {
          Label("New thread", systemImage: "square.and.pencil")
            .labelStyle(.iconOnly)
        }
        .help("Start a new chat thread")

        if !archivedThreads.isEmpty {
          Button {
            showingArchived.toggle()
          } label: {
            Label(
              showingArchived ? "Hide archived threads" : "Show archived threads",
              systemImage: showingArchived ? "archivebox.fill" : "archivebox"
            )
            .labelStyle(.iconOnly)
          }
          .help(showingArchived ? "Hide archived threads" : "Show archived threads")
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 48)

      Divider()

      if activeThreads.isEmpty && (!showingArchived || archivedThreads.isEmpty) {
        ContentUnavailableView(
          archivedThreads.isEmpty ? "No chat threads" : "No active threads",
          systemImage: "bubble.left.and.bubble.right",
          description: Text(
            archivedThreads.isEmpty
              ? "Ask a team member a product question to begin."
              : "Use the archive button above to show archived threads."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(activeThreads) { thread in
              threadButton(thread)
            }

            if showingArchived, !archivedThreads.isEmpty {
              Text("Archived")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, activeThreads.isEmpty ? 3 : 12)
                .padding(.bottom, 3)

              ForEach(archivedThreads) { thread in
                threadButton(thread)
              }
            }
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
  }

  @ViewBuilder
  private var conversationHeader: some View {
    HStack(spacing: 10) {
      if let thread = selectedThread {
        VStack(alignment: .leading, spacing: 2) {
          Text(thread.subject)
            .font(.headline)
            .lineLimit(1)
          Text("Thread with \(selectedRecipient?.name ?? "team member")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          if thread.isArchived {
            Button("Restore thread", systemImage: "arrow.uturn.backward") {
              restore(thread)
            }
          } else {
            Button(role: .destructive) {
              archive(thread)
            } label: {
              Label {
                Text(archiveThreadTitle)
              } icon: {
                Image(systemName: "archivebox")
                  .foregroundStyle(.red)
              }
            }
            .tint(.red)
            .disabled(model.respondingConversationThreadIDs.contains(thread.id))
          }
        } label: {
          Label("Thread actions", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Thread actions")
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text("New thread")
            .font(.headline)
          Text("New threads can run independently.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
  }

  private var conversationTimeline: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if selectedThread != nil {
            ForEach(messages) { message in
              ProductConversationMessageRow(message: message)
            }
          }
          Color.clear
            .frame(height: 1)
            .padding(.bottom, 14)
            .id("product-conversation-bottom")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
      }
      .defaultScrollAnchor(.bottom)
      .overlay {
        if selectedThread == nil {
          ConversationEmptyState(
            detail:
              "Ask about tickets, Product knowledge, delivery history, retrospectives, or Git."
          )
        }
      }
      .onChange(of: messages.count) { _, _ in
        Task { @MainActor in
          await Task.yield()
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("product-conversation-bottom", anchor: .bottom)
          }
        }
      }
      .onAppear {
        proxy.scrollTo("product-conversation-bottom", anchor: .bottom)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var conversationStatus: some View {
    if let thread = selectedThread, isSelectedThreadResponding {
      ConversationRespondingStatus(
        profile: selectedRecipient,
        fallbackName: "Team member",
        status: "is thinking…",
        activity: model.productConversationActivities[thread.id],
        onStop: {
          model.cancelProductConversation(threadID: thread.id)
        }
      )
    } else if
      let thread = selectedThread,
      let error = model.conversationErrorsByThread[thread.id]
    {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text(error)
          .font(.caption)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 38)
      .background(Color.orange.opacity(0.075))
    }
  }

  private var archivedThreadFooter: some View {
    HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
      Text("This thread is archived.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if let thread = selectedThread {
        Button("Restore thread") {
          restore(thread)
        }
      }
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 48)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
  }

  private var composer: some View {
    TeamConversationComposer(
      profiles: model.profiles,
      recipientID: recipientBinding,
      message: $draft,
      isSending: isStartingThread && selectedThread == nil,
      isResponding: isSelectedThreadResponding,
      sendError: nil,
      onSend: send
    )
  }

  private func threadButton(_ thread: ProductConversationThread) -> some View {
    Button {
      selectedThreadID = thread.id
    } label: {
      ConversationThreadRow(
        thread: thread,
        recipient: model.profiles.first {
          $0.id == thread.recipientProfileID
        },
        isResponding: model.respondingConversationThreadIDs.contains(thread.id),
        isSelected: selectedThreadID == thread.id
      )
    }
    .buttonStyle(.plain)
    .contextMenu {
      if thread.isArchived {
        Button("Restore thread", systemImage: "arrow.uturn.backward") {
          restore(thread)
        }
      } else {
        Button(role: .destructive) {
          archive(thread)
        } label: {
          Label {
            Text(archiveThreadTitle)
          } icon: {
            Image(systemName: "archivebox")
              .foregroundStyle(.red)
          }
        }
        .tint(.red)
        .disabled(model.respondingConversationThreadIDs.contains(thread.id))
      }
    }
  }

  private var recipientBinding: Binding<UUID?> {
    Binding(
      get: { selectedRecipientID ?? selectedThread?.recipientProfileID },
      set: { selectedRecipientID = $0 }
    )
  }

  private func synchronizeRecipientWithSelection() {
    if let selectedThread {
      selectedRecipientID = selectedThread.recipientProfileID
    } else {
      selectedRecipientID = nil
      chooseDefaultRecipient()
    }
  }

  private func chooseDefaultRecipient() {
    guard selectedRecipientID == nil else { return }
    selectedRecipientID =
      model.profiles.first(where: { $0.role == .businessAnalyst })?.id
      ?? model.profiles.first(where: { $0.role == .lead })?.id
      ?? model.profiles.first?.id
  }

  private func send() {
    guard let recipientID = selectedRecipient?.id else { return }
    let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    let currentThreadID = selectedThreadID
    if currentThreadID == nil {
      isStartingThread = true
    }
    draft = ""
    Task {
      let resultingThreadID = await model.sendProductConversationMessage(
        threadID: currentThreadID,
        recipientID: recipientID,
        body: message
      )
      if let resultingThreadID {
        selectedThreadID = resultingThreadID
      } else if currentThreadID == nil {
        isStartingThread = false
        draft = message
      }
    }
  }

  private func archive(_ thread: ProductConversationThread) {
    Task {
      guard await model.archiveProductConversation(threadID: thread.id) else {
        return
      }
      if !showingArchived, selectedThreadID == thread.id {
        selectedThreadID = activeThreads.first?.id
      }
    }
  }

  private func restore(_ thread: ProductConversationThread) {
    Task {
      guard await model.restoreProductConversation(threadID: thread.id) else {
        return
      }
      selectedThreadID = thread.id
    }
  }
}

private struct ConversationThreadRow: View {
  let thread: ProductConversationThread
  let recipient: AgentProfile?
  let isResponding: Bool
  let isSelected: Bool
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(thread.subject)
          .font(.callout.weight(.medium))
          .lineLimit(2)
        Spacer(minLength: 4)
        if isResponding {
          ProgressView()
            .controlSize(.mini)
        }
      }
      HStack(spacing: 5) {
        Text(recipient?.name ?? "Team member")
        Text("·")
        Text(thread.updatedAt.formatted(date: .omitted, time: .shortened))
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.1)
        : (isHovering ? Color.primary.opacity(0.045) : Color.clear),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
  }
}

private struct ProductConversationMessageRow: View {
  @EnvironmentObject private var model: AppModel
  let message: ProductConversationMessage

  var body: some View {
    TeamConversationMessageBubble(
      authorKind: message.authorKind,
      authorName: message.authorName,
      body: message.body,
      createdAt: message.createdAt,
      authorProfile: model.profiles.first { $0.name == message.authorName }
    )
  }
}

private struct SidebarCodexStatus: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingConnectionPopover = false

  var body: some View {
    Button {
      showingConnectionPopover.toggle()
    } label: {
      statusLabel
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
    .background(.bar)
    .help(model.codexConnectionState.diagnostic ?? "Choose the Codex installation")
    .accessibilityLabel("Codex connection")
    .accessibilityValue(model.codexConnectionState.detail)
    .popover(isPresented: $showingConnectionPopover, arrowEdge: .bottom) {
      connectionPopover
    }
  }

  private var statusLabel: some View {
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
    .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
    .contentShape(Rectangle())
  }

  private var connectionPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Codex installation")
          .font(.headline)
        Text("Choose which local Codex installation Spedito uses.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(14)

      Divider()

      if model.codexInstallations.isEmpty {
        Text("No installations found")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(14)
      } else {
        ForEach(model.codexInstallations) { installation in
          HStack(spacing: 8) {
            Button {
              showingConnectionPopover = false
              Task {
                await model.selectCodexInstallation(id: installation.id)
              }
            } label: {
              HStack(spacing: 10) {
                Image(
                  systemName: installation.id == model.selectedCodexInstallationID
                    ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(
                  installation.id == model.selectedCodexInstallationID
                    ? Color.green : Color.secondary
                )
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                  Text(installation.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                  Text(installation.executableURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canChangeCodexInstallation)
            .help(installation.executableURL.path)

            if installation.kind == .custom {
              Button(role: .destructive) {
                Task {
                  await model.removeCodexInstallation(id: installation.id)
                }
              } label: {
                Image(systemName: "trash")
                  .foregroundStyle(.red)
                  .frame(width: 24, height: 24)
              }
              .buttonStyle(.plain)
              .disabled(!model.canChangeCodexInstallation)
              .help("Remove \(installation.name)")
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(
            installation.id == model.selectedCodexInstallationID
              ? Color.accentColor.opacity(0.08) : Color.clear
          )
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Button {
          showingConnectionPopover = false
          chooseCodexInstallation()
        } label: {
          Label("Add Codex installation…", systemImage: "plus")
        }
        .disabled(!model.canChangeCodexInstallation)

        if model.codexConnectionState.showsRetryAction {
          Button {
            showingConnectionPopover = false
            Task {
              await model.retryCodexConnection()
            }
          } label: {
            Label("Retry connection", systemImage: "arrow.clockwise")
          }
          .disabled(!model.canChangeCodexInstallation)
        }

        if let diagnostic = model.codexConnectionState.diagnostic {
          Text(diagnostic)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(14)
    }
    .frame(width: 330)
  }

  private func chooseCodexInstallation() {
    let panel = NSOpenPanel()
    panel.title = "Add Codex installation"
    panel.message = "Choose a Codex app or an executable named codex."
    panel.prompt = "Add"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      await model.addCodexInstallation(at: url)
    }
  }
}

private struct ProductLibraryView: View {
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
        LazyVStack(spacing: 10) {
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
            ForEach(visibleProducts) { product in
              ProductLibraryRow(
                product: product,
                isSelected: selectedProductID == product.id
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

          if displaysArchivedProducts && !visibleArchivedProducts.isEmpty {
            HStack {
              Text("Archived")
                .font(.headline)
              Text(visibleArchivedProducts.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              Spacer()
            }
            .padding(.top, visibleProducts.isEmpty ? 4 : 14)

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

  private func openSelectedProduct() {
    guard let selectedProduct, !isOpening, restoringProductID == nil else { return }
    isOpening = true
    Task {
      await model.selectProduct(selectedProduct)
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

private extension ProductColor {
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

private extension EpicColor {
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

private struct ProductIcon: View {
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

  var body: some View {
    HStack(spacing: 12) {
      ProductIcon(product: product, size: 36)

      Text(product.name)
        .font(.body.weight(.semibold))

      Spacer(minLength: 16)

      if isSelected {
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 20)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
    .background(
      isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          isSelected
            ? Color.accentColor.opacity(0.65)
            : Color.clear
        )
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct ArchivedProductLibraryRow: View {
  let product: Product
  let isRestoring: Bool
  let isDisabled: Bool
  let onRestore: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "archivebox.fill")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 36)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

      Text(product.name)
        .font(.body.weight(.semibold))

      Spacer(minLength: 16)

      Button(isRestoring ? "Restoring…" : "Restore and open", action: onRestore)
        .disabled(isDisabled)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
  }
}

private struct NewProductView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onCreated: () -> Void
  @State private var name = ""
  @State private var isCreating = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text("New product")
          .font(.title2.bold())
        Text("Choose a product name. You can change it later.")
          .foregroundStyle(.secondary)
      }

      ProductNameEntryField(
        text: $name,
        isDisabled: isCreating,
        onSubmit: createProduct
      )

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
          .keyboardShortcut(.cancelAction)
          .disabled(isCreating)
        Button(isCreating ? "Creating…" : "Create and open") {
          createProduct()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(trimmedName.isEmpty || isCreating)
      }
    }
    .padding(24)
    .frame(width: 480)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func createProduct() {
    guard !trimmedName.isEmpty, !isCreating else { return }
    isCreating = true
    Task {
      let created = await model.createProductAndSelect(name: trimmedName)
      isCreating = false
      if created {
        isPresented = false
        onCreated()
      }
    }
  }
}

private struct ProductNameEntryField: View {
  @Binding var text: String
  let isDisabled: Bool
  let onSubmit: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Product name")
        .font(.subheadline.weight(.semibold))
      TextField(
        "Product name",
        text: $text,
        prompt: Text("e.g. Weather App")
      )
      .textFieldStyle(.plain)
      .padding(.horizontal, 11)
      .frame(height: 40)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isFocused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.7),
            lineWidth: isFocused ? 2 : 1
          )
      }
      .focused($isFocused)
      .disabled(isDisabled)
      .onSubmit(onSubmit)
    }
    .task {
      isFocused = true
    }
    .onChange(of: isDisabled) { _, disabled in
      if !disabled {
        isFocused = true
      }
    }
  }
}

private struct ProductContextView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var name = ""
  @State private var isRevokingSavedAccess = false
  @State private var showingRevokeAllConfirmation = false
  @State private var showingArchiveConfirmation = false
  @State private var isArchiving = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Product settings")
          .font(.title.bold())
        Text("Manage product details and saved agent access.")
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          EditableTextField(
            title: "Product name",
            prompt: "Product name",
            text: $name
          )

          Divider()

          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
              VStack(alignment: .leading, spacing: 3) {
                Text("Saved agent access")
                  .font(.headline)
                Text(
                  "Equivalent or narrower capability requests are allowed automatically for this product and recorded in the ticket Work log. Exact commands remain exact."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer(minLength: 12)
              if !model.permissionGrants.isEmpty {
                Button("Revoke all", role: .destructive) {
                  showingRevokeAllConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isRevokingSavedAccess)
              }
            }

            if model.permissionGrants.isEmpty {
              Text("No saved access")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            } else {
              ForEach(AgentPermissionGrantPolicy.savedAccessGroups(for: model.permissionGrants)) {
                group in
                HStack(alignment: .top, spacing: 12) {
                  Image(systemName: group.kind == .command ? "terminal" : "lock.open")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.secondary)
                    Text(group.detail)
                      .font(
                        group.kind == .command
                          ? .system(.callout, design: .monospaced)
                          : .callout
                      )
                      .textSelection(.enabled)
                      .fixedSize(horizontal: false, vertical: true)
                    Text("Updated \(group.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }
                  Spacer(minLength: 12)
                  Button("Revoke", role: .destructive) {
                    isRevokingSavedAccess = true
                    Task {
                      await model.revokePermissionGrants(group.grantIDs)
                      isRevokingSavedAccess = false
                    }
                  }
                  .disabled(isRevokingSavedAccess)
                }
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
              }
            }
          }

          Divider()

          VStack(alignment: .leading, spacing: 10) {
            Text("Archive product")
              .font(.headline)
            Text(
              "Remove this product from active navigation while preserving its Backlog, Work logs, Product knowledge, source workspace, and delivery history."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Archive product", role: .destructive) {
              showingArchiveConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isArchiving)
          }
        }
        .padding(24)
      }

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button("Save") {
          model.updateProductDetails(name: name)
          isPresented = false
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isArchiving
        )
      }
      .padding(20)
    }
    .background(InitialFocusClearer())
    .frame(width: 680, height: 640)
    .onAppear {
      name = model.selectedProduct?.name ?? ""
    }
    .confirmationDialog(
      "Revoke all saved agent access?",
      isPresented: $showingRevokeAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Revoke all", role: .destructive) {
        isRevokingSavedAccess = true
        let grantIDs = model.permissionGrants.map(\.id)
        Task {
          await model.revokePermissionGrants(grantIDs)
          isRevokingSavedAccess = false
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Future matching requests will need your approval again. Existing Work log history is preserved."
      )
    }
    .confirmationDialog(
      "Archive \(model.selectedProduct?.name ?? "this product")?",
      isPresented: $showingArchiveConfirmation,
      titleVisibility: .visible
    ) {
      Button("Archive product", role: .destructive) {
        archiveProduct()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Active delivery will be safely suspended. Nothing is deleted, and you can restore the product later from Products."
      )
    }
  }

  private func archiveProduct() {
    guard !isArchiving else { return }
    isArchiving = true
    Task {
      let archived = await model.archiveSelectedProduct()
      isArchiving = false
      if archived {
        isPresented = false
      }
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
  @State private var customInstructions: [UUID: String] = [:]
  @State private var personaModels: [UUID: String] = [:]
  @State private var personaEfforts: [UUID: String] = [:]
  @State private var selection: TeamSettingsSelection? = .shared
  @State private var hoveredSelection: TeamSettingsSelection?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Team settings")
            .font(.title2.bold())
          Text("Configure each team member's model, reasoning effort, and custom guidance.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(22)

      Divider()

      HStack(spacing: 0) {
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              Text("Product")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 5)

              settingsNavigationRow(
                selectionValue: .shared,
                icon: "person.3",
                tint: .secondary,
                title: "Shared guidance",
                subtitle: "Applies to everyone",
                verticalPadding: 10
              )

              Text("Team members")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 5)

              ForEach(model.profiles) { profile in
                settingsNavigationRow(
                  selectionValue: .profile(profile.id),
                  icon: profile.role.symbolName,
                  tint: profile.role.tint,
                  title: profile.name,
                  subtitle: profile.role.capabilityTitle,
                  verticalPadding: 9
                )
              }
            }
            .padding(.bottom, 10)
          }
        }
        .frame(width: 248)

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

  private func settingsNavigationRow(
    selectionValue: TeamSettingsSelection,
    icon: String,
    tint: Color,
    title: String,
    subtitle: String,
    verticalPadding: CGFloat
  ) -> some View {
    let isSelected = selection == selectionValue
    let isHovering = hoveredSelection == selectionValue

    return Button {
      selection = selectionValue
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .foregroundStyle(tint)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected
          ? Color.accentColor.opacity(0.1)
          : (isHovering ? tint.opacity(0.09) : Color.clear),
        in: RoundedRectangle(cornerRadius: 7)
      )
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        hoveredSelection = hovering ? selectionValue : nil
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
            "Verified Product knowledge, the ticket contract, and the definition of done are supplied separately."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          instructionsEditor(text: $sharedInstructions)
        }

        Label {
          Text(
            "Safety, permissions, approved scope, and workflow gates are enforced by Spedito and cannot be changed here."
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
            Text("Custom instructions")
              .font(.headline)
            Spacer()
            Button("Clear custom instructions") {
              customInstructions[profile.id] = ""
            }
            .buttonStyle(.borderless)
            .font(.caption)
          }

          Text(
            "Spedito supplies this member's built-in role guidance. Add only the extra instructions you want applied after it."
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          instructionsEditor(
            text: Binding(
              get: { customInstructions[profile.id] ?? profile.customInstructionText },
              set: { customInstructions[profile.id] = $0 }
            )
          )
        }
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func instructionsEditor(text: Binding<String>) -> some View {
    TextEditor(text: text)
      .scrollContentBackground(.hidden)
      .multilineTextAlignment(.leading)
      .font(.body)
      .padding(8)
      .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.separator.opacity(0.7), lineWidth: 1)
      }
  }

  private func synchronisePromptState(includeShared: Bool) {
    if includeShared {
      sharedInstructions = model.selectedProduct?.instructions ?? ""
    }
    for profile in model.profiles {
      customInstructions[profile.id] = profile.customInstructionText
      personaModels[profile.id] = profile.model
      personaEfforts[profile.id] = profile.reasoningEffort
    }
    let activeIDs = Set(model.profiles.map(\.id))
    customInstructions = customInstructions.filter { activeIDs.contains($0.key) }
    personaModels = personaModels.filter { activeIDs.contains($0.key) }
    personaEfforts = personaEfforts.filter { activeIDs.contains($0.key) }
  }

  private func saveSettings() {
    let instructionUpdates = Dictionary(
      uniqueKeysWithValues: model.profiles.map { profile in
        (profile.id, customInstructions[profile.id] ?? profile.customInstructionText)
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
            title: "Custom instructions",
            prompt: "Add optional guidance beyond this member's built-in role.",
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
      instructions = ""
    }
  }

  private func applySelectedTemplate() {
    guard let template = PersonaTemplate.common.first(where: { $0.id == templateID }) else {
      name = ""
      capability = .businessAnalyst
      selectedModel = model.codexModels.first(where: \.isDefault)?.model ?? "gpt-5.6-terra"
      effort = model.codexModels.first(where: \.isDefault)?.defaultReasoningEffort ?? "medium"
      instructions = ""
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

enum PlanningDropSection: Equatable {
  case candidateSprint
  case backlog
}

struct PlanningDropTarget: Equatable {
  let section: PlanningDropSection
  let index: Int
}

enum PlanningDropTargetState {
  static func updated(
    current: PlanningDropTarget?,
    target: PlanningDropTarget,
    isTargeted: Bool
  ) -> PlanningDropTarget? {
    if isTargeted {
      return target
    }
    return current == target ? nil : current
  }
}

enum PlanningBulkMoveDestination {
  case candidateSprint
  case backlog
}

struct PlanningBulkMoveAction {
  let items: [WorkItem]
  let selectedWorkItemIDs: Set<UUID>
  let destination: PlanningBulkMoveDestination

  private var selectedItems: [WorkItem] {
    items.filter { selectedWorkItemIDs.contains($0.id) }
  }

  var targetItems: [WorkItem] {
    return selectedItems.isEmpty ? items : selectedItems
  }

  var title: String {
    let quantity = selectedItems.isEmpty
      ? "all"
      : selectedItems.count.formatted()
    switch destination {
    case .candidateSprint:
      return "Move \(quantity) to next sprint"
    case .backlog:
      return "Move \(quantity) to backlog"
    }
  }

  var compactTitle: String {
    let quantity = selectedItems.isEmpty
      ? "All"
      : selectedItems.count.formatted()
    switch destination {
    case .candidateSprint:
      return "\(quantity) to sprint"
    case .backlog:
      return "\(quantity) to backlog"
    }
  }

  var helpText: String {
    let noun = targetItems.count == 1 ? "ticket" : "tickets"
    let subject =
      selectedItems.isEmpty
      ? "all \(items.count.formatted())"
      : "\(targetItems.count.formatted()) selected"
    switch destination {
    case .candidateSprint:
      return "Move \(subject) backlog \(noun) to the next sprint"
    case .backlog:
      return "Return \(subject) sprint \(noun) to the backlog"
    }
  }
}

struct EpicPlanningSections {
  let allEpics: [Epic]
  let openEpics: [Epic]
  let closedEpics: [Epic]
  let deliveredTicketCount: Int

  init(epics: [Epic], workItems: [WorkItem]) {
    let visibleEpics = epics.filter { $0.status != .archived }
    let visibleOpenEpics = visibleEpics.filter { $0.status == .open }
    let visibleClosedEpics = visibleEpics.filter { $0.status == .closed }
    let closedEpicIDs = Set(visibleClosedEpics.map(\.id))
    allEpics = visibleEpics
    openEpics = visibleOpenEpics
    closedEpics = visibleClosedEpics
    deliveredTicketCount = workItems.filter {
      guard let epicID = $0.epicID else { return false }
      return closedEpicIDs.contains(epicID) && $0.state == .released
    }.count
  }

  var isEmpty: Bool {
    allEpics.isEmpty
  }
}

enum TicketEpicNavigation {
  static func destination(for item: WorkItem, in epics: [Epic]) -> Epic? {
    guard let epicID = item.epicID else { return nil }
    return epics.first {
      $0.id == epicID && $0.productID == item.productID
    }
  }
}

enum TicketRelationshipNavigation {
  static func destination(
    for relationshipID: UUID,
    source: WorkItem,
    in workItems: [WorkItem]
  ) -> WorkItem? {
    workItems.first {
      $0.id == relationshipID && $0.productID == source.productID
    }
  }
}

struct BacklogPlanningSizing {
  static let tableRowHeight: CGFloat = 40
  static let tableRowDividerHeight: CGFloat = 1
  static let emptyEpicHeight: CGFloat = 166
  static let epicChromeHeight: CGFloat = 66
  static let defaultBacklogRatio: CGFloat = 0.59
  static let minimumBacklogWidth: CGFloat = 480
  static let minimumSprintWidth: CGFloat = 350
  static let epicRowHeight = tableRowHeight + tableRowDividerHeight

  static func backlogWidth(
    availableWidth: CGFloat,
    dividerWidth: CGFloat,
    preferredRatio: CGFloat
  ) -> CGFloat {
    let paneWidth = max(0, availableWidth - dividerWidth)
    guard paneWidth > 0 else { return 0 }

    let proposedWidth = paneWidth * min(max(preferredRatio, 0), 1)
    let minimumScale = min(
      1,
      paneWidth / (minimumBacklogWidth + minimumSprintWidth)
    )
    let scaledBacklogMinimum = minimumBacklogWidth * minimumScale
    let scaledSprintMinimum = minimumSprintWidth * minimumScale
    let defaultBacklogWidth = paneWidth * defaultBacklogRatio
    let maximumBacklogWidth = max(
      scaledBacklogMinimum,
      min(paneWidth - scaledSprintMinimum, defaultBacklogWidth)
    )

    return min(max(proposedWidth, scaledBacklogMinimum), maximumBacklogWidth)
  }

  static func backlogRatio(
    for width: CGFloat,
    availableWidth: CGFloat,
    dividerWidth: CGFloat
  ) -> CGFloat {
    let paneWidth = max(0, availableWidth - dividerWidth)
    guard paneWidth > 0 else { return defaultBacklogRatio }
    return min(max(width / paneWidth, 0), 1)
  }

  static func splitPosition(
    containerWidth: CGFloat,
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat,
    preferredRatio: CGFloat
  ) -> CGFloat {
    let availableWidth = max(0, containerWidth - (horizontalPadding * 2))
    return horizontalPadding + backlogWidth(
      availableWidth: availableWidth,
      dividerWidth: dividerWidth,
      preferredRatio: preferredRatio
    )
  }

  static func backlogRatio(
    forSplitPosition position: CGFloat,
    containerWidth: CGFloat,
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat
  ) -> CGFloat {
    backlogRatio(
      for: max(0, position - horizontalPadding),
      availableWidth: max(0, containerWidth - (horizontalPadding * 2)),
      dividerWidth: dividerWidth
    )
  }

  static func epicHeight(
    openEpicCount: Int,
    closedEpicCount: Int,
    closedEpicsExpanded: Bool
  ) -> CGFloat {
    let visibleRowCount =
      openEpicCount
      + (closedEpicCount > 0 ? 1 : 0)
      + (closedEpicsExpanded ? closedEpicCount : 0)

    guard visibleRowCount > 0 else { return emptyEpicHeight }
    return CGFloat(visibleRowCount) * epicRowHeight + epicChromeHeight
  }

  static func backlogHeight(
    availableHeight: CGFloat,
    epicHeight: CGFloat,
    sectionDividerHeight: CGFloat
  ) -> CGFloat {
    max(0, availableHeight - epicHeight - sectionDividerHeight)
  }
}

enum BacklogPlanningSplitPreference {
  private static let key = "backlogPlanningSplitRatio"

  static func load(defaults: UserDefaults = .standard) -> CGFloat {
    guard let number = defaults.object(forKey: key) as? NSNumber else {
      return BacklogPlanningSizing.defaultBacklogRatio
    }
    let ratio = CGFloat(number.doubleValue)
    guard ratio.isFinite, ratio > 0, ratio < 1 else {
      return BacklogPlanningSizing.defaultBacklogRatio
    }
    return min(ratio, BacklogPlanningSizing.defaultBacklogRatio)
  }

  static func save(
    _ ratio: CGFloat,
    defaults: UserDefaults = .standard
  ) {
    guard ratio.isFinite, ratio > 0, ratio < 1 else { return }
    defaults.set(
      Double(min(ratio, BacklogPlanningSizing.defaultBacklogRatio)),
      forKey: key
    )
  }
}

enum EpicPlanningDisclosureDefaults {
  private static let prefix = "completedEpicsExpanded"

  static func isExpanded(
    for productID: UUID,
    defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.bool(forKey: key(for: productID))
  }

  static func setExpanded(
    _ isExpanded: Bool,
    for productID: UUID,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(isExpanded, forKey: key(for: productID))
  }

  private static func key(for productID: UUID) -> String {
    "\(prefix).\(productID.uuidString)"
  }
}

private struct BacklogView: View {
  @EnvironmentObject private var model: AppModel
  let onNewTicket: (UUID?) -> Void
  let onNewEpic: () -> Void
  let onPlanSprint: () -> Void
  let onOpenSprint: () -> Void
  @State private var selectedTicket: WorkItem?
  @State private var selectedEpic: Epic?
  @State private var selectedWorkItemIDs: Set<UUID> = []
  @State private var draggedWorkItemIDs: Set<UUID> = []
  @State private var planningDropTarget: PlanningDropTarget?
  @State private var dragResetTask: Task<Void, Never>?
  @State private var dropExitResetTask: Task<Void, Never>?
  @State private var closedEpicsExpanded = false
  @State private var closedExpansionProductID: UUID?

  private var allPlanningItems: [WorkItem] {
    model.workItems.filter { [.backlog, .refining, .ready].contains($0.state) }
  }

  private var candidateIDs: Set<UUID> {
    Set(model.candidateSprintPlan?.items.map(\.workItemID) ?? [])
  }

  private var candidateItems: [WorkItem] {
    allPlanningItems.filter { candidateIDs.contains($0.id) }
  }

  private var allCandidateItems: [WorkItem] {
    allPlanningItems.filter { candidateIDs.contains($0.id) }
  }

  private var backlogItems: [WorkItem] {
    allPlanningItems.filter { !candidateIDs.contains($0.id) }
  }

  private var epicSections: EpicPlanningSections {
    EpicPlanningSections(
      epics: model.planningEpics,
      workItems: model.workItems
    )
  }

  private var candidateSprintNumber: Int {
    if let plan = model.candidateSprintPlan {
      return plan.sprint.number
    }
    return (model.sprintHistory.map(\.sprint.number).max() ?? 0) + 1
  }

  private var visibleSuggestionBatch: TicketSuggestionBatch? {
    guard let batch = model.suggestionBatch else { return nil }
    guard
      batch.session.epicID != nil
        || batch.session.sourceWorkItemID != nil
    else { return nil }
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
        if let plan = model.sprintPlan, plan.sprint.state.isInProgress {
          Button(action: onOpenSprint) {
            Label(
              plan.sprint.state == .paused
                ? "Sprint \(plan.sprint.number) paused"
                : "Sprint \(plan.sprint.number) active",
              systemImage: plan.sprint.state == .paused ? "pause.fill" : "bolt.fill"
            )
          }
          .buttonStyle(.bordered)
          .help("Open the current sprint board")
        }
      }
      .workspaceHeaderLayout()

      Divider()

      GeometryReader { proxy in
        let horizontalPadding: CGFloat = 24
        let columnGutter: CGFloat = 18
        let dividerThickness: CGFloat = 1
        let sectionDividerHeight = (columnGutter * 2) + dividerThickness
        let topPadding: CGFloat = 18
        let bottomPadding: CGFloat = 28
        let availableHeight = max(0, proxy.size.height - topPadding - bottomPadding)
        let epicHeight = BacklogPlanningSizing.epicHeight(
          openEpicCount: epicSections.openEpics.count,
          closedEpicCount: epicSections.closedEpics.count,
          closedEpicsExpanded: closedEpicsExpanded
        )
        let backlogHeight = BacklogPlanningSizing.backlogHeight(
          availableHeight: availableHeight,
          epicHeight: epicHeight,
          sectionDividerHeight: sectionDividerHeight
        )

        BacklogPlanningSplitView(
          containerWidth: proxy.size.width,
          horizontalPadding: horizontalPadding,
          dividerWidth: dividerThickness
        ) {
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
              EpicPlanningList(
                sections: epicSections,
                workItems: model.workItems,
                minimumHeight: epicHeight,
                isClosedExpanded: $closedEpicsExpanded,
                onAddEpic: onNewEpic,
                onOpen: { selectedEpic = $0 }
              )
              .padding(.leading, horizontalPadding)
              .padding(.trailing, columnGutter)

              Divider()
                .frame(height: dividerThickness)
                .padding(.vertical, columnGutter)

              PlanningTicketList(
                title: "Backlog",
                items: backlogItems,
                isCandidateSection: false,
                minimumHeight: backlogHeight,
                selectedWorkItemIDs: $selectedWorkItemIDs,
                draggedWorkItemIDs: $draggedWorkItemIDs,
                activeDropTarget: $planningDropTarget,
                onDragBegan: beginDragging,
                onDragCompleted: finishDragging,
                onOpen: { selectedTicket = $0 },
                onAddTicket: { onNewTicket(nil) },
                suggestionBatch: visibleSuggestionBatch
              )
              .padding(.leading, horizontalPadding)
              .padding(.trailing, columnGutter)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(
            height: availableHeight,
            alignment: .topLeading
          )
          .clipped()
          .padding(.top, topPadding)
          .padding(.bottom, bottomPadding)
        } sprint: {
          CandidateSprintPanel(
            sprintNumber: candidateSprintNumber,
            items: candidateItems,
            planningIsComplete: planningIsComplete,
            availableHeight: availableHeight,
            selectedWorkItemIDs: $selectedWorkItemIDs,
            draggedWorkItemIDs: $draggedWorkItemIDs,
            activeDropTarget: $planningDropTarget,
            onDragBegan: beginDragging,
            onDragCompleted: finishDragging,
            onOpen: { selectedTicket = $0 },
            onPlanSprint: onPlanSprint
          )
          .padding(.leading, columnGutter)
          .padding(.trailing, horizontalPadding)
          .frame(
            height: availableHeight,
            alignment: .top
          )
          .clipped()
          .padding(.top, topPadding)
          .padding(.bottom, bottomPadding)
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
    .onChange(of: Set(allPlanningItems.map(\.id))) { _, availableIDs in
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
      guard epicID != nil else { return }
      model.backlogFocusEpicID = nil
    }
    .onChange(of: model.selectedProductID, initial: true) { _, productID in
      restoreClosedEpicExpansion(for: productID)
    }
    .onChange(of: closedEpicsExpanded) { _, isExpanded in
      guard
        let productID = model.selectedProductID,
        closedExpansionProductID == productID
      else { return }
      EpicPlanningDisclosureDefaults.setExpanded(isExpanded, for: productID)
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

  private func restoreClosedEpicExpansion(for productID: UUID?) {
    closedExpansionProductID = nil
    guard let productID else {
      closedEpicsExpanded = false
      return
    }
    closedEpicsExpanded = EpicPlanningDisclosureDefaults.isExpanded(for: productID)
    closedExpansionProductID = productID
  }
}

private struct BacklogPlanningSplitView<BacklogContent: View, SprintContent: View>: View {
  let containerWidth: CGFloat
  let horizontalPadding: CGFloat
  let dividerWidth: CGFloat
  let backlogContent: BacklogContent
  let sprintContent: SprintContent

  init(
    containerWidth: CGFloat,
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat,
    @ViewBuilder backlog: () -> BacklogContent,
    @ViewBuilder sprint: () -> SprintContent
  ) {
    self.containerWidth = containerWidth
    self.horizontalPadding = horizontalPadding
    self.dividerWidth = dividerWidth
    backlogContent = backlog()
    sprintContent = sprint()
  }

  var body: some View {
    BacklogPlanningNativeSplitView(
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredBacklogRatio: BacklogPlanningSplitPreference.load(),
      backlogContent: backlogContent,
      sprintContent: sprintContent
    )
    .frame(width: containerWidth)
  }
}

private struct BacklogPlanningNativeSplitView<
  BacklogContent: View,
  SprintContent: View
>: NSViewRepresentable {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let horizontalPadding: CGFloat
  let dividerWidth: CGFloat
  let preferredBacklogRatio: CGFloat
  let backlogContent: BacklogContent
  let sprintContent: SprintContent

  final class Coordinator {
    var backlogHostingView: NSHostingView<AnyView>?
    var sprintHostingView: NSHostingView<AnyView>?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> BacklogPlanningSplitNSView {
    let splitView = BacklogPlanningSplitNSView()
    let backlogHostingView = NSHostingView(rootView: hosted(backlogContent))
    let sprintHostingView = NSHostingView(rootView: hosted(sprintContent))
    backlogHostingView.sizingOptions = []
    sprintHostingView.sizingOptions = []
    context.coordinator.backlogHostingView = backlogHostingView
    context.coordinator.sprintHostingView = sprintHostingView
    splitView.addArrangedSubview(backlogHostingView)
    splitView.addArrangedSubview(sprintHostingView)
    splitView.configure(
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredBacklogRatio: preferredBacklogRatio,
      onCommit: { BacklogPlanningSplitPreference.save($0) }
    )
    return splitView
  }

  func updateNSView(
    _ nsView: BacklogPlanningSplitNSView,
    context: Context
  ) {
    context.coordinator.backlogHostingView?.rootView = hosted(backlogContent)
    context.coordinator.sprintHostingView?.rootView = hosted(sprintContent)
    nsView.configure(
      horizontalPadding: horizontalPadding,
      dividerWidth: dividerWidth,
      preferredBacklogRatio: preferredBacklogRatio,
      onCommit: { BacklogPlanningSplitPreference.save($0) }
    )
  }

  private func hosted<Content: View>(_ content: Content) -> AnyView {
    AnyView(
      content
        .environmentObject(model)
        .environment(\.colorScheme, colorScheme)
    )
  }
}

private final class BacklogPlanningSplitNSView: NSSplitView, NSSplitViewDelegate {
  private var planningHorizontalPadding: CGFloat = 0
  private var planningDividerWidth: CGFloat = 1
  private var preferredBacklogRatio = BacklogPlanningSizing.defaultBacklogRatio
  private var lastLayoutWidth: CGFloat = 0
  private var hasAppliedPreferredPosition = false
  private var isApplyingPreferredPosition = false
  private var onCommit: ((CGFloat) -> Void)?

  override var dividerThickness: CGFloat {
    planningDividerWidth
  }

  override var dividerColor: NSColor {
    .separatorColor
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isVertical = true
    dividerStyle = .thin
    delegate = self
    setAccessibilityLabel("Backlog planning columns")
    setAccessibilityHelp(
      "Drag left to give the Sprint more room. Double-click to restore the default size."
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    horizontalPadding: CGFloat,
    dividerWidth: CGFloat,
    preferredBacklogRatio: CGFloat,
    onCommit: @escaping (CGFloat) -> Void
  ) {
    let ratioChanged = abs(self.preferredBacklogRatio - preferredBacklogRatio) > 0.0001
    let geometryChanged =
      self.planningHorizontalPadding != horizontalPadding
      || self.planningDividerWidth != dividerWidth
    planningHorizontalPadding = horizontalPadding
    planningDividerWidth = dividerWidth
    self.preferredBacklogRatio = preferredBacklogRatio
    self.onCommit = onCommit
    if ratioChanged || geometryChanged {
      hasAppliedPreferredPosition = false
      needsLayout = true
    }
  }

  override func layout() {
    let widthChanged = abs(bounds.width - lastLayoutWidth) > 0.5
    lastLayoutWidth = bounds.width
    super.layout()
    guard !isApplyingPreferredPosition else { return }
    if !hasAppliedPreferredPosition || widthChanged {
      applyPreferredPosition()
    }
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      resetDivider()
      return
    }

    super.mouseDown(with: event)
    guard arrangedSubviews.count == 2 else { return }
    let ratio = currentBacklogRatio
    preferredBacklogRatio = ratio
    onCommit?(ratio)
  }

  func splitView(
    _ splitView: NSSplitView,
    constrainSplitPosition proposedPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    guard dividerIndex == 0 else { return proposedPosition }
    let minimumPosition = BacklogPlanningSizing.splitPosition(
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness,
      preferredRatio: 0
    )
    let maximumPosition = BacklogPlanningSizing.splitPosition(
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness,
      preferredRatio: 1
    )
    return min(max(proposedPosition, minimumPosition), maximumPosition)
  }

  private var currentBacklogRatio: CGFloat {
    guard let backlogView = arrangedSubviews.first else {
      return preferredBacklogRatio
    }
    return BacklogPlanningSizing.backlogRatio(
      forSplitPosition: backlogView.frame.maxX,
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness
    )
  }

  private func applyPreferredPosition() {
    guard arrangedSubviews.count == 2, bounds.width > 0 else { return }
    isApplyingPreferredPosition = true
    setPosition(
      BacklogPlanningSizing.splitPosition(
        containerWidth: bounds.width,
        horizontalPadding: planningHorizontalPadding,
        dividerWidth: dividerThickness,
        preferredRatio: preferredBacklogRatio
      ),
      ofDividerAt: 0
    )
    hasAppliedPreferredPosition = true
    isApplyingPreferredPosition = false
  }

  private func resetDivider() {
    preferredBacklogRatio = BacklogPlanningSizing.defaultBacklogRatio
    let position = BacklogPlanningSizing.splitPosition(
      containerWidth: bounds.width,
      horizontalPadding: planningHorizontalPadding,
      dividerWidth: dividerThickness,
      preferredRatio: preferredBacklogRatio
    )
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      animator().setPosition(position, ofDividerAt: 0)
    }
    hasAppliedPreferredPosition = true
    onCommit?(preferredBacklogRatio)
  }
}

private enum EpicPlanningTableGeometry {
  static let columnLeadingInset: CGFloat = 14
  static let ticketsWidth: CGFloat = 64
  static let progressWidth: CGFloat = 120
  static let statusWidth: CGFloat = 96
}

private struct EpicPlanningList: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let sections: EpicPlanningSections
  let workItems: [WorkItem]
  let minimumHeight: CGFloat
  @Binding var isClosedExpanded: Bool
  let onAddEpic: () -> Void
  let onOpen: (Epic) -> Void
  @State private var targetedEpicID: UUID?
  @State private var isBottomTargeted = false
  @State private var confirmingArchive: Epic?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Text("Epics")
          .font(.title3.weight(.semibold))
        Text(sections.openEpics.count.formatted())
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        Spacer()
        Button(action: onAddEpic) {
          Label("Add epic", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .help("Plan a substantial product outcome with the Business Analyst")
      }
      .padding(.horizontal, 2)

      VStack(spacing: 0) {
        EpicPlanningTableHeader()
          .background(PlanningDropSurfaceStyle.tableHeaderBackground)
        Divider()

        if sections.isEmpty {
          VStack(spacing: 6) {
            Image(systemName: "flag.checkered")
              .font(.title3)
              .foregroundStyle(.tertiary)
            Text("No open epics")
              .font(.subheadline.weight(.medium))
            Text("Add an epic to plan a substantial product outcome with AI.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity)
        } else {
          ForEach(Array(sections.openEpics.enumerated()), id: \.element.id) {
            index,
            epic in
            epicRow(epic)
            if index < sections.openEpics.count - 1 {
              Divider()
            }
          }

          if !sections.closedEpics.isEmpty {
            if !sections.openEpics.isEmpty {
              Divider()
            }
            ClosedEpicsDisclosureRow(
              epicCount: sections.closedEpics.count,
              deliveredTicketCount: sections.deliveredTicketCount,
              isExpanded: $isClosedExpanded
            )

            if isClosedExpanded {
              ForEach(sections.closedEpics) { epic in
                Divider()
                epicRow(epic)
              }
            }
          }
        }
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: sections.isEmpty ? .infinity : nil,
        alignment: .top
      )
      .background(PlanningDropSurfaceStyle.restingBackground(for: colorScheme))
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(PlanningDropSurfaceStyle.tableBorder(for: colorScheme), lineWidth: 1)
      }
      .overlay(alignment: .bottom) {
        if !sections.isEmpty {
          Color.clear
            .frame(height: 12)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
              if isBottomTargeted {
                Rectangle()
                  .fill(Color.accentColor)
                  .frame(height: 2)
              }
            }
            .dropDestination(
              for: String.self,
              action: { values, _ in move(values, before: nil) },
              isTargeted: { isBottomTargeted = $0 }
            )
        }
      }
    }
    .frame(minHeight: minimumHeight, alignment: .top)
    .confirmationDialog(
      "Archive \(confirmingArchive?.title ?? "epic")?",
      isPresented: Binding(
        get: { confirmingArchive != nil },
        set: { if !$0 { confirmingArchive = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let epic = confirmingArchive {
        Button("Archive epic", role: .destructive) {
          model.archiveEpic(epic)
          confirmingArchive = nil
        }
      }
      Button("Cancel", role: .cancel) {
        confirmingArchive = nil
      }
    } message: {
      Text(
        "All unfinished Backlog tickets and proposed tickets in this epic will also be archived. Delivered tickets and history remain available."
      )
    }
  }

  private func epicRow(_ epic: Epic) -> some View {
    EpicPlanningRow(
      epic: epic,
      tickets: workItems.filter {
        $0.epicID == epic.id && $0.state != .cancelled
      },
      isDropTargeted: targetedEpicID == epic.id,
      onOpen: { onOpen(epic) },
      onRefine: {
        model.planEpic(epic)
        onOpen(epic)
      },
      onMoveTop: {
        model.moveEpics([epic], before: sections.allEpics.first?.id)
      },
      onMoveBottom: { model.moveEpics([epic], before: nil) },
      onArchive: { confirmingArchive = epic }
    )
    .dropDestination(
      for: String.self,
      action: { values, _ in move(values, before: epic.id) },
      isTargeted: { targeted in
        withAnimation(.easeOut(duration: 0.12)) {
          targetedEpicID = targeted ? epic.id : nil
        }
      }
    )
  }

  private func move(_ values: [String], before targetID: UUID?) -> Bool {
    let ids = values.compactMap { value -> UUID? in
      guard value.hasPrefix("epic:") else { return nil }
      return UUID(uuidString: String(value.dropFirst(5)))
    }
    let moving = sections.allEpics.filter { ids.contains($0.id) }
    guard !moving.isEmpty else { return false }
    if moving.count == 1, moving.first?.id == targetID {
      return true
    }
    model.moveEpics(moving, before: targetID)
    return true
  }
}

private struct ClosedEpicsDisclosureRow: View {
  let epicCount: Int
  let deliveredTicketCount: Int
  @Binding var isExpanded: Bool
  @State private var isHovering = false

  private var epicLabel: String {
    "\(epicCount) closed \(epicCount == 1 ? "epic" : "epics")"
  }

  private var ticketLabel: String {
    "\(deliveredTicketCount) delivered \(deliveredTicketCount == 1 ? "ticket" : "tickets")"
  }

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 12)
          .animation(.easeInOut(duration: 0.18), value: isExpanded)
        Text(epicLabel)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)
        Text("·")
          .foregroundStyle(.tertiary)
        Text(ticketLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .frame(
        maxWidth: .infinity,
        minHeight: BacklogPlanningSizing.tableRowHeight,
        alignment: .leading
      )
      .contentShape(Rectangle())
      .background(isHovering ? Color.accentColor.opacity(0.055) : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .help(isExpanded ? "Hide closed epics" : "Show closed epics")
  }
}

private struct EpicPlanningTableHeader: View {
  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow {
        Text("Epic")
          .frame(maxWidth: .infinity, alignment: .leading)
          .gridColumnAlignment(.leading)
        Text("Tickets")
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.ticketsWidth, alignment: .leading)
          .gridColumnAlignment(.leading)
        Text("Progress")
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.progressWidth, alignment: .leading)
          .gridColumnAlignment(.leading)
        Text("Status")
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.statusWidth, alignment: .leading)
          .gridColumnAlignment(.leading)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(height: 32)
    }
    .padding(.horizontal, 16)
  }
}

private struct EpicPlanningRow: View {
  let epic: Epic
  let tickets: [WorkItem]
  let isDropTargeted: Bool
  let onOpen: () -> Void
  let onRefine: () -> Void
  let onMoveTop: () -> Void
  let onMoveBottom: () -> Void
  let onArchive: () -> Void
  @State private var isHovering = false

  private var completedCount: Int {
    tickets.filter { $0.state == .released }.count
  }

  private var progress: EpicProgress {
    EpicProgress(tickets: tickets)
  }

  private var displayStatus: String {
    switch epic.status {
    case .open:
      return progress.title
    case .closed, .archived:
      return epic.status.title
    }
  }

  private var statusColor: Color {
    switch epic.status {
    case .open:
      switch progress {
      case .created: return .secondary
      case .planned: return .blue
      case .inProgress: return .orange
      case .complete: return .green
      }
    case .closed:
      return .green
    case .archived:
      return .secondary
    }
  }

  private var archiveTitle: AttributedString {
    var title = AttributedString("Archive epic…")
    title.foregroundColor = .red
    return title
  }

  var body: some View {
    Button(action: onOpen) {
      Grid(horizontalSpacing: 0) {
        GridRow(alignment: .center) {
          Text(epic.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
            .lineLimit(2)
            .layoutPriority(1)
            .help(epic.goal.isEmpty ? epic.title : epic.goal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)

          Text(tickets.count.formatted())
            .font(.caption)
            .foregroundStyle(tickets.isEmpty ? .secondary : .primary)
            .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
            .frame(width: EpicPlanningTableGeometry.ticketsWidth, alignment: .leading)
            .gridColumnAlignment(.leading)

          Text(
            tickets.isEmpty
              ? "Not started"
              : "\(completedCount) of \(tickets.count) delivered"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
          .frame(width: EpicPlanningTableGeometry.progressWidth, alignment: .leading)
          .gridColumnAlignment(.leading)

          Text(displayStatus)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .padding(.leading, EpicPlanningTableGeometry.columnLeadingInset)
            .frame(width: EpicPlanningTableGeometry.statusWidth, alignment: .leading)
            .gridColumnAlignment(.leading)
            .help(displayStatus)
        }
      }
      .padding(.horizontal, 16)
      .frame(minHeight: BacklogPlanningSizing.tableRowHeight)
      .contentShape(Rectangle())
      .background(
        isDropTargeted
          ? Color.accentColor.opacity(0.12)
          : (isHovering ? Color.accentColor.opacity(0.055) : Color.clear)
      )
      .overlay(alignment: .top) {
        if isDropTargeted {
          Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
        }
      }
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(epic.color.displayColor)
          .frame(width: 4)
      }
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .onDrag {
      NSItemProvider(object: "epic:\(epic.id.uuidString)" as NSString)
    } preview: {
      Label(epic.title, systemImage: "flag.checkered")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    .contextMenu {
      Button(action: onOpen) {
        Label("Open epic", systemImage: "flag.checkered")
      }
      Button(action: onRefine) {
        Label("Refine with AI", systemImage: "wand.and.stars")
      }
      .disabled(epic.status != .open)
      Divider()
      Button(action: onMoveTop) {
        Label("Move to top", systemImage: "arrow.up.to.line")
      }
      Button(action: onMoveBottom) {
        Label("Move to bottom", systemImage: "arrow.down.to.line")
      }
      Divider()
      Button(role: .destructive, action: onArchive) {
        Label {
          Text(archiveTitle)
        } icon: {
          Image(systemName: "archivebox")
            .foregroundStyle(.red)
        }
      }
      .tint(.red)
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
  }
}

private enum PlanningDropSurfaceStyle {
  static let targetedBackground = Color.accentColor.opacity(0.11)
  static let invalidTargetedBackground = Color.red.opacity(0.11)
  static let tableHeaderBackground = AnyShapeStyle(.quaternary.opacity(0.18))

  static func tableBorder(for colorScheme: ColorScheme) -> Color {
    Color.secondary.opacity(colorScheme == .dark ? 0.32 : 0.2)
  }

  static func restingBackground(for colorScheme: ColorScheme) -> Color {
    Color.secondary.opacity(colorScheme == .dark ? 0.075 : 0.035)
  }
}

private struct CandidateSprintPanel: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let sprintNumber: Int
  let items: [WorkItem]
  let planningIsComplete: Bool
  let availableHeight: CGFloat
  @Binding var selectedWorkItemIDs: Set<UUID>
  @Binding var draggedWorkItemIDs: Set<UUID>
  @Binding var activeDropTarget: PlanningDropTarget?
  let onDragBegan: (Set<UUID>) -> Void
  let onDragCompleted: () -> Void
  let onOpen: (WorkItem) -> Void
  let onPlanSprint: () -> Void

  private var section: PlanningDropSection { .candidateSprint }
  private var itemIDs: Set<UUID> { Set(items.map(\.id)) }
  private var selectedItemCount: Int {
    selectedWorkItemIDs.intersection(itemIDs).count
  }
  private var isDropTargeted: Bool {
    activeDropTarget?.section == .candidateSprint
      && activeDropEvaluation != nil
  }
  private var activeDropEvaluation: PlanningDropEvaluation? {
    guard
      let activeDropTarget,
      activeDropTarget.section == section
    else {
      return nil
    }
    return dropEvaluation(
      ids: draggedWorkItemIDs,
      at: activeDropTarget.index
    )
  }
  private var bulkMoveAction: PlanningBulkMoveAction {
    PlanningBulkMoveAction(
      items: items,
      selectedWorkItemIDs: selectedWorkItemIDs,
      destination: .backlog
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text("Sprint \(sprintNumber)")
              .font(.title3.weight(.semibold))
            Text(items.count.formatted())
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
          }
        }
        Spacer(minLength: 4)
        Button {
          model.removeFromCandidateSprint(bulkMoveAction.targetItems)
        } label: {
          ViewThatFits(in: .horizontal) {
            Label(bulkMoveAction.title, systemImage: "arrow.left")
            Label(bulkMoveAction.compactTitle, systemImage: "arrow.left")
            Image(systemName: "arrow.left")
          }
        }
        .buttonStyle(.bordered)
        .disabled(items.isEmpty)
        .accessibilityLabel(bulkMoveAction.title)
        .help(bulkMoveAction.helpText)
        Button(action: onPlanSprint) {
          Label(
            planningIsComplete ? "Review plan" : "Plan sprint",
            systemImage: "calendar.badge.plus"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(items.isEmpty)
      }
      .padding(.horizontal, 2)

      VStack(spacing: 0) {
        CandidateSprintTableHeader(
          itemCount: items.count,
          selectedItemCount: selectedItemCount,
          onToggleSelection: toggleAllItems
        )
          .padding(.horizontal, PlanningTicketTableMetrics.horizontalPadding)
          .background(PlanningDropSurfaceStyle.tableHeaderBackground)
          .dropDestination(
            for: String.self,
            action: { values, _ in performDrop(values, at: 0) },
            isTargeted: { setDropTarget($0, index: 0) }
          )

        Divider()

        if items.isEmpty {
          VStack(spacing: 7) {
            Image(
              systemName:
                activeDropEvaluation?.isValid == false
                ? "exclamationmark.triangle.fill"
                : "tray.and.arrow.down"
            )
              .font(.title2)
              .foregroundStyle(
                activeDropEvaluation?.isValid == false
                  ? Color.red : Color.secondary
              )
            Text(
              activeDropEvaluation?.isValid == false
                ? "Can't drop here" : "Drag backlog tickets here"
            )
              .font(.subheadline.weight(.medium))
            Text(
              activeDropEvaluation?.message
                ?? (
                  isDropTargeted
                    ? "Backlog rank will stay unchanged."
                    : "Only scoped work enters sprint planning."
                )
            )
              .font(.caption)
              .foregroundStyle(
                activeDropEvaluation?.isValid == false
                  ? Color.red : Color.secondary
              )
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .dropDestination(
            for: String.self,
            action: { values, _ in performDrop(values, at: 0) },
            isTargeted: { setDropTarget($0, index: 0) }
          )
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(0...items.count, id: \.self) { index in
                PlanningTicketDropSlot(
                  section: section,
                  index: index,
                  showsRestingDivider: index > 0,
                  showsInsertionIndicator: !isNoOpDrop(
                    ids: draggedWorkItemIDs,
                    at: index
                  ),
                  evaluation: dropEvaluation(
                    ids: draggedWorkItemIDs,
                    at: index
                  ),
                  activeDropTarget: $activeDropTarget,
                  onDrop: { values in performDrop(values, at: index) }
                )

                if index < items.count {
                  let item = items[index]
                  let dragSelection = selectedWorkItemIDs.contains(item.id)
                    ? selectedWorkItemIDs.intersection(itemIDs)
                    : [item.id]
                  CandidateSprintRow(
                    item: item,
                    isSelected: selectedWorkItemIDs.contains(item.id),
                    dragSelection: dragSelection,
                    isBeingDragged: draggedWorkItemIDs.contains(item.id),
                    dropEvaluation: dropEvaluation(
                      ids: draggedWorkItemIDs,
                      at: index + 1
                    ),
                    onToggleSelection: {
                      if selectedWorkItemIDs.contains(item.id) {
                        selectedWorkItemIDs.remove(item.id)
                      } else {
                        selectedWorkItemIDs.insert(item.id)
                      }
                    },
                    onDragBegan: { onDragBegan(dragSelection) },
                    onDrop: { values in performDrop(values, at: index + 1) },
                    onDropTargeted: { targeted in
                      setDropTarget(targeted, index: index + 1)
                    },
                    onOpen: { onOpen(item) }
                  )
                }
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(
        isDropTargeted
          ? (
            activeDropEvaluation?.isValid == false
              ? PlanningDropSurfaceStyle.invalidTargetedBackground
              : PlanningDropSurfaceStyle.targetedBackground
          )
          : PlanningDropSurfaceStyle.restingBackground(for: colorScheme)
      )
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
        isTargeted: { setDropTarget($0, index: items.count) }
      )
      .animation(.snappy(duration: 0.18), value: isDropTargeted)
      .animation(.snappy(duration: 0.22), value: items.map(\.id))
    }
    .frame(height: availableHeight, alignment: .top)
  }

  private func toggleAllItems() {
    if !itemIDs.isEmpty, itemIDs.isSubset(of: selectedWorkItemIDs) {
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
    let targetID = dropTargetID(ids: ids, at: safeIndex)
    let evaluation = model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: true,
      before: targetID
    )
    guard evaluation.isValid else {
      onDragCompleted()
      return true
    }
    model.dropPlanningItems(
      movingItems,
      intoCandidateSprint: true,
      before: targetID
    )
    onDragCompleted()
    return true
  }

  private func setDropTarget(_ targeted: Bool, index: Int) {
    let target = PlanningDropTarget(section: section, index: index)
    withAnimation(.snappy(duration: 0.16)) {
      activeDropTarget = PlanningDropTargetState.updated(
        current: activeDropTarget,
        target: target,
        isTargeted: targeted
      )
    }
  }

  private func dropEvaluation(
    ids: Set<UUID>,
    at index: Int
  ) -> PlanningDropEvaluation? {
    guard !ids.isEmpty else { return nil }
    return model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: true,
      before: dropTargetID(ids: ids, at: index)
    )
  }

  private func dropTargetID(ids: Set<UUID>, at index: Int) -> UUID? {
    let safeIndex = min(max(index, 0), items.count)
    return items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
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

private enum PlanningTicketTableMetrics {
  static let rowHeight = BacklogPlanningSizing.tableRowHeight
  static let columnSpacing: CGFloat = 6
  static let horizontalPadding: CGFloat = 10
  static let ticketLeadingSpacing: CGFloat = 10
  static let selectionWidth: CGFloat = 30
  static let referenceWidth: CGFloat = 34
  static let assigneeWidth: CGFloat = 54
  static let readinessWidth: CGFloat = 58
  static let priorityWidth: CGFloat = 44
}

private struct PlanningSelectionCheckbox: View {
  let symbol: String
  let isActive: Bool
  let isDisabled: Bool
  let helpText: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(
          isActive ? Color.blue : Color(nsColor: .tertiaryLabelColor)
        )
        .frame(
          width: PlanningTicketTableMetrics.selectionWidth,
          height: 32
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(helpText)
    .frame(width: PlanningTicketTableMetrics.selectionWidth, alignment: .center)
  }
}

private struct PlanningAssigneeIcon: View {
  let profile: AgentProfile?

  var body: some View {
    Image(
      systemName: profile?.role.symbolName
        ?? "person.crop.circle.badge.questionmark"
    )
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(profile?.role.tint ?? Color.secondary)
    .frame(width: PlanningTicketTableMetrics.assigneeWidth, alignment: .center)
    .accessibilityLabel(profile?.name ?? "Unassigned")
    .help(profile?.name ?? "Unassigned")
  }
}

private enum CandidateSprintTableLayout {
  static let columnSpacing = PlanningTicketTableMetrics.columnSpacing
  static let selectionWidth = PlanningTicketTableMetrics.selectionWidth
  static let referenceWidth = PlanningTicketTableMetrics.referenceWidth
  static let assigneeWidth = PlanningTicketTableMetrics.assigneeWidth
  static let readinessWidth = PlanningTicketTableMetrics.readinessWidth
  static let priorityWidth = PlanningTicketTableMetrics.priorityWidth
}

private struct CandidateSprintTableHeader: View {
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
      ? "Deselect all sprint tickets"
      : "Select all sprint tickets"
  }

  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: selectionSymbol,
          isActive: selectedItemCount > 0,
          isDisabled: itemCount == 0,
          helpText: selectionHelp,
          action: onToggleSelection
        )

        Text("Ticket")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
          .gridColumnAlignment(.leading)

        Text("Assignee")
          .frame(
            width: CandidateSprintTableLayout.assigneeWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
          .gridColumnAlignment(.center)

        Text("Readiness")
          .frame(
            width: CandidateSprintTableLayout.readinessWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
          .gridColumnAlignment(.center)

        Text("Priority")
          .frame(
            width: CandidateSprintTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
          .gridColumnAlignment(.center)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(height: 32)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct CandidateSprintRow: View {
  @EnvironmentObject private var model: AppModel
  let item: WorkItem
  let isSelected: Bool
  let dragSelection: Set<UUID>
  let isBeingDragged: Bool
  let dropEvaluation: PlanningDropEvaluation?
  let onToggleSelection: () -> Void
  let onDragBegan: () -> Void
  let onDrop: ([String]) -> Bool
  let onDropTargeted: (Bool) -> Void
  let onOpen: () -> Void
  @State private var isHovering = false

  private var sprintItem: SprintItem? {
    model.candidateSprintPlan?.items
      .first { $0.workItemID == item.id }
  }

  private var epicColor: Color? {
    guard let epicID = item.epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var owner: AgentProfile? {
    guard let ownerID = sprintItem?.implementerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var readinessProblems: [String] {
    var problems: [String] = []
    if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      problems.append("Add ticket context")
    }
    if item.acceptanceCriteria.isEmpty {
      problems.append("Add acceptance criteria")
    }
    if owner == nil {
      problems.append("Choose a delivery assignee")
    }
    problems.append(
      contentsOf: model.sprintReadinessIssues
        .filter {
          $0.workItemID == item.id
            && !$0.id.hasSuffix(".acceptance")
            && !$0.id.hasSuffix(".implementer")
        }
        .map(\.message)
    )
    return problems
  }

  private var readinessLabel: String {
    if readinessProblems.isEmpty {
      let count = item.acceptanceCriteria.count
      return "Ready · \(count) \(count == 1 ? "criterion" : "criteria")"
    }
    return readinessProblems.joined(separator: ". ")
  }

  private var isReady: Bool {
    readinessProblems.isEmpty
  }

  private var targetItems: [WorkItem] {
    model.workItems.filter { dragSelection.contains($0.id) }
  }

  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: isSelected ? "checkmark.square.fill" : "square",
          isActive: isSelected,
          isDisabled: false,
          helpText: isSelected ? "Deselect ticket" : "Select ticket",
          action: onToggleSelection
        )

        HStack(spacing: 8) {
          Image(systemName: item.type.symbolName)
            .foregroundStyle(item.type.tint)
            .frame(width: 16)
          Text(item.key)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(
              width: CandidateSprintTableLayout.referenceWidth,
              alignment: .leading
            )
          Text(item.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
            .lineLimit(2)
            .layoutPriority(1)
          Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)

        PlanningAssigneeIcon(profile: owner)
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)

        Image(
          systemName: isReady
            ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isReady ? .green : .orange)
        .frame(
          width: CandidateSprintTableLayout.readinessWidth,
          alignment: .center
        )
        .padding(.leading, CandidateSprintTableLayout.columnSpacing)
        .accessibilityLabel(readinessLabel)
        .help(readinessLabel)

        SprintPriorityIndicator(priority: item.priority)
          .frame(
            width: CandidateSprintTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, CandidateSprintTableLayout.columnSpacing)
      }
    }
    .padding(.horizontal, PlanningTicketTableMetrics.horizontalPadding)
    .frame(minHeight: PlanningTicketTableMetrics.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.1)
        : (isHovering ? Color.accentColor.opacity(0.055) : Color.clear)
    )
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
    .saturation(dropEvaluation?.isValid == false ? 0.2 : 1)
    .opacity(
      isBeingDragged
        ? 0.28
        : (dropEvaluation?.isValid == false ? 0.45 : 1)
    )
    .onTapGesture(perform: onOpen)
    .onHover { isHovering = $0 }
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
    .animation(.easeOut(duration: 0.12), value: dropEvaluation?.isValid)
    .contextMenu {
      Button(action: onOpen) {
        Label("Open ticket", systemImage: "doc.text.magnifyingglass")
      }
      Button {
        model.removeFromCandidateSprint(targetItems)
      } label: {
        Label(
          targetItems.count > 1 ? "Return selected to backlog" : "Return to backlog",
          systemImage: "arrow.uturn.backward"
        )
      }
    }
  }
}

private struct PlanningTicketList: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let title: String
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
      && activeDropEvaluation != nil
  }
  private var activeDropEvaluation: PlanningDropEvaluation? {
    guard
      let activeDropTarget,
      activeDropTarget.section == section
    else {
      return nil
    }
    return dropEvaluation(
      ids: draggedWorkItemIDs,
      at: activeDropTarget.index
    )
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

  private var proposedSuggestionCount: Int {
    guard !isCandidateSection, suggestionBatch?.session.status == .ready else { return 0 }
    return suggestionBatch?.suggestions.filter { $0.status == .proposed }.count ?? 0
  }

  private var visibleItemCount: Int {
    items.count + proposedSuggestionCount
  }

  private var restingBackground: Color {
    PlanningDropSurfaceStyle.restingBackground(for: colorScheme)
  }

  private var bulkMoveAction: PlanningBulkMoveAction {
    PlanningBulkMoveAction(
      items: items,
      selectedWorkItemIDs: selectedWorkItemIDs,
      destination: isCandidateSection ? .backlog : .candidateSprint
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .center, spacing: 7) {
            Text(title)
              .font(.title3.weight(.semibold))
            Text(visibleItemCount.formatted())
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.quaternary, in: Capsule())
          }
        }
        Spacer()
        if !isCandidateSection {
          Button {
            model.addToCandidateSprint(bulkMoveAction.targetItems)
          } label: {
            ViewThatFits(in: .horizontal) {
              Label(bulkMoveAction.title, systemImage: "arrow.right")
              Label(bulkMoveAction.compactTitle, systemImage: "arrow.right")
              Image(systemName: "arrow.right")
            }
          }
          .buttonStyle(.bordered)
          .disabled(items.isEmpty || !model.canEditCandidateSprint)
          .accessibilityLabel(bulkMoveAction.title)
          .help(bulkMoveAction.helpText)
        }
        if let onAddTicket {
          Button(action: onAddTicket) {
            Label("Add ticket", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
        }
      }
      .padding(.horizontal, 2)
      .padding(.bottom, 1)

      VStack(spacing: 0) {
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

        if items.isEmpty && suggestionBatch == nil {
          VStack(spacing: 7) {
            Image(
              systemName:
                activeDropEvaluation?.isValid == false
                ? "exclamationmark.triangle.fill"
                : (isCandidateSection ? "tray.and.arrow.down" : "text.badge.plus")
            )
              .font(.title2)
              .foregroundStyle(
                activeDropEvaluation?.isValid == false
                  ? Color.red : Color.secondary
              )
            Text(
              activeDropEvaluation?.isValid == false
                ? "Can't drop here"
                : (isCandidateSection ? "Drag backlog tickets here" : "No backlog tickets")
            )
              .font(.subheadline.weight(.medium))
            Text(
              activeDropEvaluation?.message
                ?? (
                  isDropTargeted
                    ? "Backlog rank will stay unchanged."
                    : (
                      isCandidateSection
                        ? "Dependencies must be added before the work that relies on them."
                        : "Add a ticket, or create an epic and let AI plan the outcome."
                    )
                )
            )
            .font(.caption)
            .foregroundStyle(
              activeDropEvaluation?.isValid == false
                ? Color.red : Color.secondary
            )
            .multilineTextAlignment(.center)
          }
          .frame(
            maxWidth: .infinity,
            minHeight: 104,
            maxHeight: .infinity,
            alignment: .center
          )
          .dropDestination(
            for: String.self,
            action: { values, _ in performDrop(values, at: 0) },
            isTargeted: { targeted in setDropTarget(targeted, index: 0) }
          )
        } else {
          if let suggestionBatch {
            InlineBacklogSuggestions(batch: suggestionBatch)
          }

          ForEach(0...items.count, id: \.self) { index in
            PlanningTicketDropSlot(
              section: section,
              index: index,
              showsRestingDivider: index > 0,
              showsInsertionIndicator: !isNoOpDrop(
                ids: draggedWorkItemIDs,
                at: index
              ),
              evaluation: dropEvaluation(
                ids: draggedWorkItemIDs,
                at: index
              ),
              activeDropTarget: $activeDropTarget,
              onDrop: { values in performDrop(values, at: index) }
            )

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
                dropEvaluation: dropEvaluation(
                  ids: draggedWorkItemIDs,
                  at: index + 1
                ),
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
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(alignment: .top) {
        Rectangle()
          .fill(PlanningDropSurfaceStyle.tableHeaderBackground)
          .frame(height: 32)
      }
      .background(
        isDropTargeted
          ? (
            activeDropEvaluation?.isValid == false
              ? PlanningDropSurfaceStyle.invalidTargetedBackground
              : PlanningDropSurfaceStyle.targetedBackground
          )
          : Color.clear
      )
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
    let targetID = dropTargetID(ids: ids, at: safeIndex)
    let evaluation = model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: isCandidateSection,
      before: targetID
    )
    guard evaluation.isValid else {
      onDragCompleted()
      return true
    }
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
      activeDropTarget = PlanningDropTargetState.updated(
        current: activeDropTarget,
        target: target,
        isTargeted: targeted
      )
    }
  }

  private func dropEvaluation(
    ids: Set<UUID>,
    at index: Int
  ) -> PlanningDropEvaluation? {
    guard !ids.isEmpty else { return nil }
    return model.planningDropEvaluation(
      ids: ids,
      intoCandidateSprint: isCandidateSection,
      before: dropTargetID(ids: ids, at: index)
    )
  }

  private func dropTargetID(ids: Set<UUID>, at index: Int) -> UUID? {
    let safeIndex = min(max(index, 0), items.count)
    return items.dropFirst(safeIndex).first { !ids.contains($0.id) }?.id
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
  static let columnSpacing = PlanningTicketTableMetrics.columnSpacing
  static let selectionWidth = PlanningTicketTableMetrics.selectionWidth
  static let referenceWidth = PlanningTicketTableMetrics.referenceWidth
  static let dependenciesWidth: CGFloat = 76
  static let assigneeWidth = PlanningTicketTableMetrics.assigneeWidth
  static let priorityWidth = PlanningTicketTableMetrics.priorityWidth
}

enum PlanningTicketDropSlotLayout {
  static let dividerHeight: CGFloat = 1

  static func height(showsRestingDivider: Bool) -> CGFloat {
    showsRestingDivider ? dividerHeight : 0
  }
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
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: selectionSymbol,
          isActive: selectedItemCount > 0,
          isDisabled: itemCount == 0,
          helpText: selectionHelp,
          action: onToggleSelection
        )
        .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)
        Text("Ticket")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
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
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .gridColumnAlignment(.center)
        Text("Priority")
          .frame(
            width: PlanningTicketTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
          .gridColumnAlignment(.center)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(height: 32)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct PlanningTicketDropSlot: View {
  let section: PlanningDropSection
  let index: Int
  let showsRestingDivider: Bool
  let showsInsertionIndicator: Bool
  let evaluation: PlanningDropEvaluation?
  @Binding var activeDropTarget: PlanningDropTarget?
  let onDrop: ([String]) -> Bool

  private var target: PlanningDropTarget {
    PlanningDropTarget(section: section, index: index)
  }

  private var isActive: Bool {
    showsInsertionIndicator
      && evaluation != nil
      && activeDropTarget == target
  }

  private var indicatorColor: Color {
    evaluation?.isValid == false ? .red : .accentColor
  }

  private var activeLabel: String {
    evaluation?.message ?? "Drop here"
  }

  private var showsValidPosition: Bool {
    showsInsertionIndicator && evaluation?.isValid == true
  }

  var body: some View {
    Color.clear
      .frame(
        height: PlanningTicketDropSlotLayout.height(
          showsRestingDivider: showsRestingDivider
        )
      )
      .overlay {
        if isActive {
          HStack(spacing: 7) {
            Rectangle()
              .fill(indicatorColor)
              .frame(height: 2)
            Label {
              Text(activeLabel)
                .lineLimit(1)
            } icon: {
              Image(
                systemName:
                  evaluation?.isValid == false
                  ? "exclamationmark.triangle.fill" : "circle.fill"
              )
              .font(.system(size: 7, weight: .bold))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(indicatorColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            Rectangle()
              .fill(indicatorColor)
              .frame(height: 2)
          }
          .padding(.horizontal, 10)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if showsValidPosition {
          HStack(spacing: 5) {
            Circle()
              .fill(Color.accentColor.opacity(0.65))
              .frame(width: 4, height: 4)
            Rectangle()
              .fill(Color.accentColor.opacity(0.48))
              .frame(height: 2)
          }
          .padding(.horizontal, 10)
        } else if showsRestingDivider {
          Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: PlanningTicketDropSlotLayout.dividerHeight)
            .padding(.horizontal, 1)
        }
      }
      .zIndex(isActive ? 10 : (showsValidPosition ? 1 : 0))
      .contentShape(Rectangle())
      .accessibilityLabel(
        isActive
          ? activeLabel
          : (showsValidPosition ? "Valid drop position" : "Ticket separator")
      )
      .help(
        isActive
          ? activeLabel
          : (showsValidPosition ? "Valid drop position" : "")
      )
      .dropDestination(
        for: String.self,
        action: { values, _ in onDrop(values) },
        isTargeted: { targeted in
          withAnimation(.snappy(duration: 0.16)) {
            activeDropTarget = PlanningDropTargetState.updated(
              current: activeDropTarget,
              target: target,
              isTargeted: targeted
            )
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
  let dropEvaluation: PlanningDropEvaluation?
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

  private var activePrerequisites: [WorkItem] {
    prerequisites.filter { $0.state != .released }
  }

  private var sprintItem: SprintItem? {
    model.candidateSprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var epicColor: Color? {
    guard let epicID = item.epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var assignedImplementer: AgentProfile? {
    guard let ownerID = sprintItem?.implementerProfileID ?? item.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var archiveMenuTitle: AttributedString {
    var title = AttributedString(
      targetItems.count == 1
        ? "Archive ticket…"
        : "Archive \(targetItems.count) tickets…"
    )
    title.foregroundColor = .red
    return title
  }

  private var targetItems: [WorkItem] {
    model.workItems.filter { dragSelection.contains($0.id) }
  }

  private var targetsMultipleTickets: Bool {
    targetItems.count > 1
  }

  var body: some View {
    Grid(horizontalSpacing: 0) {
      GridRow(alignment: .center) {
        PlanningSelectionCheckbox(
          symbol: isSelected ? "checkmark.square.fill" : "square",
          isActive: isSelected,
          isDisabled: false,
          helpText: isSelected ? "Deselect ticket" : "Select ticket",
          action: onToggleSelection
        )
        .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)

        HStack(spacing: 8) {
          Image(systemName: item.type.symbolName)
            .foregroundStyle(item.type.tint)
            .frame(width: 16)
          Text(item.key)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: PlanningTicketTableLayout.referenceWidth, alignment: .leading)
          Text(item.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
            .lineLimit(2)
            .layoutPriority(1)
          Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
        .contentShape(Rectangle())

        Group {
          if !activePrerequisites.isEmpty {
            Label(
              activePrerequisites.map(\.key).joined(separator: ", "),
              systemImage: "arrow.turn.down.right"
            )
            .foregroundStyle(.indigo)
            .help(
              "Waiting for \(activePrerequisites.map(\.key).joined(separator: ", "))"
            )
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

        PlanningAssigneeIcon(profile: assignedImplementer)
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)

        SprintPriorityIndicator(priority: item.priority)
          .frame(
            width: PlanningTicketTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
      }
    }
    .frame(minHeight: PlanningTicketTableMetrics.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowBackground)
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
          .accessibilityHidden(true)
      }
    }
    .saturation(dropEvaluation?.isValid == false ? 0.2 : 1)
    .opacity(
      isBeingDragged
        ? 0.28
        : (dropEvaluation?.isValid == false ? 0.45 : 1)
    )
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
    .animation(.easeOut(duration: 0.12), value: dropEvaluation?.isValid)
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
          model.removeFromCandidateSprint(targetItems)
        } label: {
          Label(
            targetsMultipleTickets ? "Return selected to backlog" : "Return to backlog",
            systemImage: "arrow.uturn.backward"
          )
        }
      } else {
        Button {
          model.addToCandidateSprint(targetItems)
        } label: {
          Label(
            targetsMultipleTickets ? "Add selected to next sprint" : "Add to next sprint",
            systemImage: "calendar.badge.plus"
          )
        }
        .disabled(!model.canEditCandidateSprint)
      }
      Divider()
      Button {
        model.moveWorkItems(targetItems, to: .top)
      } label: {
        Label(
          targetsMultipleTickets ? "Move selected to top" : "Move to top",
          systemImage: "arrow.up.to.line"
        )
      }
      Button {
        model.moveWorkItems(targetItems, to: .bottom)
      } label: {
        Label(
          targetsMultipleTickets ? "Move selected to bottom" : "Move to bottom",
          systemImage: "arrow.down.to.line"
        )
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
      targetsMultipleTickets
        ? "Archive \(targetItems.count) tickets?"
        : "Archive \(item.key)?",
      isPresented: $confirmingArchive,
      titleVisibility: .visible
    ) {
      Button(
        targetsMultipleTickets ? "Archive tickets" : "Archive ticket",
        role: .destructive
      ) {
        model.archiveWorkItems(targetItems)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        targetsMultipleTickets
          ? "The tickets leave the backlog but their history remains in the local workspace."
          : "The ticket leaves the backlog but its history remains in the local workspace."
      )
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

private enum ProposedTicketVisualStyle {
  static var surface: Color { .purple.opacity(0.09) }
  static var emphasizedSurface: Color { .purple.opacity(0.14) }
  static var border: Color { .purple.opacity(0.42) }
}

private struct TicketSuggestionBatchActions: View {
  @EnvironmentObject private var model: AppModel
  let suggestions: [TicketSuggestion]
  @State private var confirmingDismissal = false

  private var proposedSuggestions: [TicketSuggestion] {
    suggestions
      .filter { $0.status == .proposed }
      .sorted { $0.position < $1.position }
  }

  private var proposalCount: Int {
    proposedSuggestions.count
  }

  var body: some View {
    HStack(spacing: 7) {
      Button("Dismiss all") {
        confirmingDismissal = true
      }
      .buttonStyle(.bordered)

      Button("Accept all") {
        model.decideTicketSuggestionGroup(proposedSuggestions, accept: true)
      }
      .buttonStyle(.borderedProminent)
    }
    .controlSize(.small)
    .disabled(model.isDecidingSuggestions || proposedSuggestions.isEmpty)
    .confirmationDialog(
      "Dismiss all \(proposalCount) proposed tickets?",
      isPresented: $confirmingDismissal,
      titleVisibility: .visible
    ) {
      Button(
        "Dismiss \(proposalCount) \(proposalCount == 1 ? "ticket" : "tickets")",
        role: .destructive
      ) {
        model.decideTicketSuggestionGroup(proposedSuggestions, accept: false)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "They will not enter the Backlog. The decisions remain in history and "
          + "inform future suggestions."
      )
    }
  }
}

private func transitiveSuggestionDependents(
  of suggestion: TicketSuggestion,
  in suggestions: [TicketSuggestion]
) -> [TicketSuggestion] {
  var dependentIDs: Set<UUID> = []
  var dependencyFrontier: Set<UUID> = [suggestion.id]
  while !dependencyFrontier.isEmpty {
    let next = suggestions.filter { candidate in
      !dependentIDs.contains(candidate.id)
        && candidate.id != suggestion.id
        && candidate.dependencyIDs.contains(where: dependencyFrontier.contains)
    }
    dependentIDs.formUnion(next.map(\.id))
    dependencyFrontier = Set(next.map(\.id))
  }
  return suggestions
    .filter { dependentIDs.contains($0.id) && $0.status != .rejected }
    .sorted { $0.position < $1.position }
}

private func transitiveSuggestedPrerequisites(
  of suggestion: TicketSuggestion,
  in suggestions: [TicketSuggestion]
) -> [TicketSuggestion] {
  let suggestionsByID = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.id, $0) })
  var prerequisiteIDs: Set<UUID> = []
  var dependencyFrontier = suggestion.dependencyIDs
  while let dependencyID = dependencyFrontier.popLast() {
    guard
      prerequisiteIDs.insert(dependencyID).inserted,
      let dependency = suggestionsByID[dependencyID]
    else { continue }
    dependencyFrontier.append(contentsOf: dependency.dependencyIDs)
  }
  return suggestions
    .filter { prerequisiteIDs.contains($0.id) && $0.status == .proposed }
    .sorted { $0.position < $1.position }
}

private struct SuggestionAcceptanceImpact {
  let suggestion: TicketSuggestion
  let prerequisites: [TicketSuggestion]

  var requiresConfirmation: Bool {
    !prerequisites.isEmpty
  }

  var dialogTitle: String {
    "Accept \(suggestion.reference) and its prerequisites?"
  }

  var actionTitle: String {
    let count = prerequisites.count + 1
    return "Accept \(count) \(count == 1 ? "ticket" : "tickets")"
  }

  var buttonTitle: String {
    guard requiresConfirmation else { return "Accept ticket" }
    return "Accept ticket and \(prerequisites.count) "
      + (prerequisites.count == 1 ? "prerequisite…" : "prerequisites…")
  }

  var message: String {
    let references = prerequisites.map(\.reference).joined(separator: ", ")
    return
      "This also accepts \(prerequisites.count) suggested "
      + (prerequisites.count == 1 ? "prerequisite" : "prerequisites")
      + " (\(references)). All \(prerequisites.count + 1) tickets will be added to the "
      + "Backlog with their dependency relationships. This does not add them to a Sprint."
  }
}

private struct SuggestionRejectionImpact {
  let suggestion: TicketSuggestion
  let dependents: [TicketSuggestion]

  var proposedDependentCount: Int {
    dependents.filter { $0.status == .proposed }.count
  }

  var acceptedDependentCount: Int {
    dependents.filter { $0.status == .accepted }.count
  }

  var requiresConfirmation: Bool {
    !dependents.isEmpty
  }

  var dialogTitle: String {
    "Reject \(suggestion.reference) and its dependent work?"
  }

  var actionTitle: String {
    if acceptedDependentCount > 0 {
      return "Reject and archive dependent work"
    }
    let count = proposedDependentCount + 1
    return "Reject \(count) \(count == 1 ? "suggestion" : "suggestions")"
  }

  var message: String {
    var sentences: [String] = []
    if proposedDependentCount > 0 {
      sentences.append(
        "This will also reject \(proposedDependentCount) dependent "
          + (proposedDependentCount == 1 ? "suggestion." : "suggestions.")
      )
    }
    if acceptedDependentCount > 0 {
      sentences.append(
        "It will archive \(acceptedDependentCount) dependent "
          + (acceptedDependentCount == 1
            ? "ticket already added to the backlog."
            : "tickets already added to the backlog.")
      )
    }
    sentences.append("The decisions and archived tickets remain in history.")
    return sentences.joined(separator: " ")
  }
}

private struct InlineBacklogSuggestions: View {
  @EnvironmentObject private var model: AppModel
  let batch: TicketSuggestionBatch
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
          TicketSuggestionPlaceholderLines(
            primaryWidth: index == 1 ? 250 : 340,
            secondaryWidth: index == 2 ? 180 : 270
          )
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
      Button {
        model.retryCurrentEpicPlan()
      } label: {
        Label("Try again", systemImage: "wand.and.stars")
      }
      .buttonStyle(.borderedProminent)
      .tint(.purple)
      .disabled(!model.canPlanEpic)
    }
    .padding(14)
    .background(.orange.opacity(0.055))
  }

  private var readyRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !orderedSuggestions.isEmpty {
        HStack(spacing: 0) {
          Image(systemName: "wand.and.stars")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.purple)
            .frame(
              width: PlanningTicketTableMetrics.selectionWidth,
              height: 32
            )
            .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)
          HStack(spacing: 9) {
            Text("Proposed tickets")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.purple)
            Text(orderedSuggestions.count.formatted())
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.purple)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.purple.opacity(0.1), in: Capsule())
          }
          .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)
          Spacer()
          TicketSuggestionBatchActions(suggestions: orderedSuggestions)
            .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
        }
        .frame(minHeight: 42)
        .background(.purple.opacity(0.055))
        Divider()
      }

      if let sourceTicket {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.branch")
            .foregroundStyle(.purple)
          Text("Follow-up work proposed from \(sourceTicket.key) research")
            .font(.caption.weight(.semibold))
          Spacer()
          Text("Review before adding to the backlog")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(.purple.opacity(0.055))
        Divider()
      }
      ForEach(orderedSuggestions) { suggestion in
        InlineTicketSuggestionRow(
          suggestion: suggestion,
          epicID: batch.session.epicID,
          dependencies: relatedSuggestions(for: suggestion.dependencyIDs),
          existingDependencies: suggestion.existingDependencyWorkItemIDs.compactMap { id in
            model.workItems.first { $0.id == id }
          },
          cascadeDependents: transitiveSuggestionDependents(
            of: suggestion,
            in: batch.suggestions
          ),
          cascadePrerequisites: transitiveSuggestedPrerequisites(
            of: suggestion,
            in: batch.suggestions
          ),
          onOpen: { selectedSuggestion = suggestion }
        )
      }
    }
  }

  private var sourceTicket: WorkItem? {
    guard let sourceID = batch.session.sourceWorkItemID else { return nil }
    return model.workItems.first { $0.id == sourceID }
  }

  private var orderedSuggestions: [TicketSuggestion] {
    batch.suggestions.filter { $0.status == .proposed }
      .sorted { lhs, rhs in
        let leftDepth = dependencyDepth(for: lhs, visiting: [])
        let rightDepth = dependencyDepth(for: rhs, visiting: [])
        return leftDepth == rightDepth ? lhs.position < rhs.position : leftDepth < rightDepth
      }
  }

  private func relatedSuggestions(for ids: [UUID]) -> [TicketSuggestion] {
    ids.compactMap { id in batch.suggestions.first { $0.id == id } }
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

private struct TicketSuggestionPlaceholderLines: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  let primaryWidth: CGFloat
  let secondaryWidth: CGFloat
  @State private var isHighlighted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RoundedRectangle(cornerRadius: 3)
        .fill(.purple.opacity(isHighlighted ? 0.24 : 0.11))
        .frame(width: primaryWidth, height: 10)
      RoundedRectangle(cornerRadius: 3)
        .fill(Color.secondary.opacity(isHighlighted ? 0.19 : 0.09))
        .frame(width: secondaryWidth, height: 8)
    }
    .animation(
      accessibilityReduceMotion
        ? nil
        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
      value: isHighlighted
    )
    .onAppear {
      if !accessibilityReduceMotion {
        isHighlighted = true
      }
    }
  }
}

private struct InlineTicketSuggestionRow: View {
  @EnvironmentObject private var model: AppModel
  let suggestion: TicketSuggestion
  let epicID: UUID?
  let dependencies: [TicketSuggestion]
  let existingDependencies: [WorkItem]
  let cascadeDependents: [TicketSuggestion]
  let cascadePrerequisites: [TicketSuggestion]
  let onOpen: () -> Void
  @State private var isHovering = false
  @State private var confirmingCascadeAcceptance = false
  @State private var confirmingCascadeRejection = false

  private var acceptanceImpact: SuggestionAcceptanceImpact {
    SuggestionAcceptanceImpact(
      suggestion: suggestion,
      prerequisites: cascadePrerequisites
    )
  }

  private var rejectionImpact: SuggestionRejectionImpact {
    SuggestionRejectionImpact(
      suggestion: suggestion,
      dependents: cascadeDependents
    )
  }

  private var epicColor: Color? {
    guard let epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var rejectMenuTitle: AttributedString {
    var title = AttributedString("Reject ticket…")
    title.foregroundColor = .red
    return title
  }

  var body: some View {
    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow(alignment: .center) {
        Color.clear
          .frame(
            width: PlanningTicketTableLayout.selectionWidth,
            height: 24
          )
          .padding(.leading, PlanningTicketTableMetrics.horizontalPadding)

        HStack(alignment: .center, spacing: 8) {
          Image(systemName: suggestion.type.symbolName)
            .foregroundStyle(suggestion.type.tint)
            .frame(width: 16)
          Text(suggestion.reference)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.purple)
            .frame(width: PlanningTicketTableLayout.referenceWidth, alignment: .leading)
          Text(suggestion.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isHovering ? Color.purple : Color.primary)
            .lineLimit(2)
            .layoutPriority(1)
          Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PlanningTicketTableMetrics.ticketLeadingSpacing)

        Group {
          if !blockerKeys.isEmpty {
            Label(
              blockerKeys.joined(separator: ", "),
              systemImage: "arrow.turn.down.right"
            )
            .foregroundStyle(.indigo)
            .help("Waiting for \(blockerKeys.joined(separator: ", "))")
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

        Image(systemName: suggestion.suggestedRole.symbolName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(suggestion.suggestedRole.tint)
          .frame(
            width: PlanningTicketTableLayout.assigneeWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .accessibilityLabel(suggestion.suggestedRole.title)
          .help(suggestion.suggestedRole.title)

        SprintPriorityIndicator(priority: suggestion.priority)
          .frame(
            width: PlanningTicketTableLayout.priorityWidth,
            alignment: .center
          )
          .padding(.leading, PlanningTicketTableLayout.columnSpacing)
          .padding(.trailing, PlanningTicketTableMetrics.horizontalPadding)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: PlanningTicketTableMetrics.rowHeight)
    .background(
      isHovering
        ? ProposedTicketVisualStyle.emphasizedSurface
        : ProposedTicketVisualStyle.surface
    )
    .overlay(alignment: .bottom) {
      Divider()
    }
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
          .accessibilityHidden(true)
      }
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
    .contextMenu {
      Button {
        if acceptanceImpact.requiresConfirmation {
          confirmingCascadeAcceptance = true
        } else {
          model.decideTicketSuggestion(suggestion, accept: true)
        }
      } label: {
        Label(acceptanceImpact.buttonTitle, systemImage: "checkmark.circle")
      }
      .disabled(model.isDecidingSuggestions)

      Button(role: .destructive) {
        if rejectionImpact.requiresConfirmation {
          confirmingCascadeRejection = true
        } else {
          model.rejectTicketSuggestion(suggestion)
        }
      } label: {
        Label {
          Text(rejectMenuTitle)
        } icon: {
          Image(systemName: "xmark.circle")
            .foregroundStyle(.red)
        }
      }
      .tint(.red)
      .disabled(model.isDecidingSuggestions)
    }
    .confirmationDialog(
      acceptanceImpact.dialogTitle,
      isPresented: $confirmingCascadeAcceptance,
      titleVisibility: .visible
    ) {
      Button(acceptanceImpact.actionTitle) {
        model.decideTicketSuggestion(suggestion, accept: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(acceptanceImpact.message)
    }
    .confirmationDialog(
      rejectionImpact.dialogTitle,
      isPresented: $confirmingCascadeRejection,
      titleVisibility: .visible
    ) {
      Button(rejectionImpact.actionTitle, role: .destructive) {
        model.rejectTicketSuggestion(suggestion)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rejectionImpact.message)
    }
  }

  private var blockerKeys: [String] {
    dependencies.map(\.reference) + activeExistingDependencies.map(\.key)
  }

  private var activeExistingDependencies: [WorkItem] {
    existingDependencies.filter { $0.state != .released }
  }
}

private struct TicketSuggestionDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.workspaceContainerSize) private var containerSize
  let suggestion: TicketSuggestion
  let batch: TicketSuggestionBatch
  let onClose: () -> Void
  @State private var confirmingCascadeAcceptance = false
  @State private var confirmingCascadeRejection = false

  init(
    suggestion: TicketSuggestion,
    batch: TicketSuggestionBatch,
    onClose: @escaping () -> Void
  ) {
    self.suggestion = suggestion
    self.batch = batch
    self.onClose = onClose
  }

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

  private var activeExistingDependencies: [WorkItem] {
    existingDependencies.filter { $0.state != .released }
  }

  private var dependents: [TicketSuggestion] {
    batch.suggestions.filter { $0.dependencyIDs.contains(suggestion.id) }
  }

  private var epic: Epic? {
    guard let epicID = batch.session.epicID else { return nil }
    return model.epics.first {
      $0.id == epicID && $0.productID == batch.session.productID
    }
  }

  private var relationships: [TicketDetailRelationshipGroup] {
    var groups: [TicketDetailRelationshipGroup] = []
    let blockers =
      proposedDependencies.map {
        TicketDetailRelationshipItem(
          id: "suggestion-\($0.id.uuidString)",
          key: $0.reference,
          title: $0.title
        )
      }
      + activeExistingDependencies.map {
        TicketDetailRelationshipItem(
          id: "ticket-\($0.id.uuidString)",
          key: $0.key,
          title: $0.title
        )
      }
    if !blockers.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocked-by",
          title: "Blocked by",
          symbol: "arrow.turn.up.left",
          items: blockers
        )
      )
    }
    if !dependents.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocks",
          title: "Blocks",
          symbol: "link",
          items: dependents.map {
            TicketDetailRelationshipItem(
              id: "suggestion-\($0.id.uuidString)",
              key: $0.reference,
              title: $0.title
            )
          }
        )
      )
    }
    return groups
  }

  private var acceptanceImpact: SuggestionAcceptanceImpact {
    SuggestionAcceptanceImpact(
      suggestion: suggestion,
      prerequisites: transitiveSuggestedPrerequisites(
        of: suggestion,
        in: batch.suggestions
      )
    )
  }

  private var rejectionImpact: SuggestionRejectionImpact {
    SuggestionRejectionImpact(
      suggestion: suggestion,
      dependents: transitiveSuggestionDependents(
        of: suggestion,
        in: batch.suggestions
      )
    )
  }

  private var detailWidth: CGFloat {
    min(900, max(700, containerSize.width - 140))
  }

  private var detailHeight: CGFloat {
    min(780, max(600, containerSize.height - 110))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: suggestion.type.symbolName)
          .foregroundStyle(suggestion.type.tint)
        Text(suggestion.reference)
          .font(.callout.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Text("Ticket details")
          .font(.title2.bold())
        Text("Suggested")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.purple)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.purple.opacity(0.1), in: Capsule())
        Spacer()
        Button("Close", action: onClose)
      }
      .padding(.horizontal, 22)
      .frame(height: 64)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          TicketDetailOverview(
            title: suggestion.title,
            context: suggestion.body,
            emptyContextText: "No additional context was proposed.",
            metadata: [
              TicketDetailMetadataValue(
                id: "status",
                title: "Status",
                value: "Suggested",
                symbol: "wand.and.stars",
                tint: .purple
              ),
              TicketDetailMetadataValue(
                id: "owner",
                title: "Suggested owner",
                value: suggestion.suggestedRole.title,
                symbol: suggestion.suggestedRole.symbolName,
                tint: suggestion.suggestedRole.tint
              ),
              TicketDetailMetadataValue(
                id: "type",
                title: "Type",
                value: suggestion.type.title,
                symbol: suggestion.type.symbolName,
                tint: suggestion.type.tint
              ),
              TicketDetailMetadataValue(
                id: "priority",
                title: "Priority",
                value: suggestion.priority.title,
                symbol: "flag.fill",
                tint: suggestion.priority.tint
              ),
            ],
              epic: epic,
              acceptanceCriteria: suggestion.acceptanceCriteria,
              emptyAcceptanceCriteriaText: "No acceptance criteria proposed",
              relationships: relationships,
              onOpenRelationship: nil
            )

          SprintTicketSectionCard(title: "Why this work") {
            Text(suggestion.rationale)
              .textSelection(.enabled)
          }
        }
        .padding(24)
      }

      Divider()

      HStack {
        Text(
          acceptanceImpact.requiresConfirmation
            ? "Accepting this ticket also accepts its suggested prerequisites."
            : "Nothing enters the Backlog until you accept it."
        )
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Reject", role: .destructive) {
          if rejectionImpact.requiresConfirmation {
            confirmingCascadeRejection = true
          } else {
            rejectSuggestion()
          }
        }
        .disabled(model.isDecidingSuggestions)
        Button(acceptanceImpact.buttonTitle) {
          if acceptanceImpact.requiresConfirmation {
            confirmingCascadeAcceptance = true
          } else {
            acceptSuggestion()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isDecidingSuggestions)
      }
      .padding(.horizontal, 22)
      .frame(height: 64)
    }
    .frame(width: detailWidth, height: detailHeight)
    .confirmationDialog(
      acceptanceImpact.dialogTitle,
      isPresented: $confirmingCascadeAcceptance,
      titleVisibility: .visible
    ) {
      Button(acceptanceImpact.actionTitle) {
        acceptSuggestion()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(acceptanceImpact.message)
    }
    .confirmationDialog(
      rejectionImpact.dialogTitle,
      isPresented: $confirmingCascadeRejection,
      titleVisibility: .visible
    ) {
      Button(rejectionImpact.actionTitle, role: .destructive) {
        rejectSuggestion()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rejectionImpact.message)
    }
  }

  private func acceptSuggestion() {
    model.decideTicketSuggestion(suggestion, accept: true)
    onClose()
  }

  private func rejectSuggestion() {
    model.rejectTicketSuggestion(suggestion, completion: onClose)
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
          Label(
            sourceTicket.map { "Follow-up work from \($0.key)" } ?? "Suggested work",
            systemImage: "wand.and.stars"
          )
            .font(.headline)
          Text(
            sourceTicket == nil
              ? "One Business Analyst proposal · roles are planning hints; team members are assigned in Sprint Planning"
              : "Proposed from approved research · review each ticket before it enters the backlog"
          )
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
          Button {
            model.retryCurrentEpicPlan()
          } label: {
            Label("Try again", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
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
                dependents: dependents(for: suggestion),
                cascadeDependents: transitiveSuggestionDependents(
                  of: suggestion,
                  in: batch.suggestions
                ),
                cascadePrerequisites: transitiveSuggestedPrerequisites(
                  of: suggestion,
                  in: batch.suggestions
                )
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
      Text(rejectAllMessage)
    }
  }

  private var proposedCount: Int {
    batch.suggestions.filter { $0.status == .proposed }.count
  }

  private var sourceTicket: WorkItem? {
    guard let sourceID = batch.session.sourceWorkItemID else { return nil }
    return model.workItems.first { $0.id == sourceID }
  }

  private var reviewedSummary: String {
    let accepted = batch.suggestions.filter { $0.status == .accepted }.count
    let rejected = batch.suggestions.filter { $0.status == .rejected }.count
    return "Proposal reviewed · \(accepted) added · \(rejected) rejected"
  }

  private var acceptedCascadeTicketCount: Int {
    let acceptedIDs = batch.suggestions
      .filter { $0.status == .proposed }
      .flatMap {
        transitiveSuggestionDependents(of: $0, in: batch.suggestions)
      }
      .filter { $0.status == .accepted }
      .map(\.id)
    return Set(acceptedIDs).count
  }

  private var rejectAllMessage: String {
    if acceptedCascadeTicketCount > 0 {
      return
        "This also archives \(acceptedCascadeTicketCount) dependent "
        + (acceptedCascadeTicketCount == 1
          ? "ticket already added to the backlog. "
          : "tickets already added to the backlog. ")
        + "The decisions and archived tickets remain in history."
    }
    return "The decisions will be retained as feedback for future backlog analysis."
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
  let cascadeDependents: [TicketSuggestion]
  let cascadePrerequisites: [TicketSuggestion]
  @State private var confirmingCascadeAcceptance = false
  @State private var confirmingCascadeRejection = false

  private var acceptanceImpact: SuggestionAcceptanceImpact {
    SuggestionAcceptanceImpact(
      suggestion: suggestion,
      prerequisites: cascadePrerequisites
    )
  }

  private var rejectionImpact: SuggestionRejectionImpact {
    SuggestionRejectionImpact(
      suggestion: suggestion,
      dependents: cascadeDependents
    )
  }

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
          Button("Reject") {
            if rejectionImpact.requiresConfirmation {
              confirmingCascadeRejection = true
            } else {
              model.rejectTicketSuggestion(suggestion)
            }
          }
            .buttonStyle(.bordered)
            .disabled(model.isDecidingSuggestions)
          Button(acceptanceImpact.requiresConfirmation ? acceptanceImpact.buttonTitle : "Accept") {
            if acceptanceImpact.requiresConfirmation {
              confirmingCascadeAcceptance = true
            } else {
              model.decideTicketSuggestion(suggestion, accept: true)
            }
          }
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
    .background(
      ProposedTicketVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(ProposedTicketVisualStyle.border)
    }
    .opacity(suggestion.status == .rejected ? 0.58 : 1)
    .confirmationDialog(
      acceptanceImpact.dialogTitle,
      isPresented: $confirmingCascadeAcceptance,
      titleVisibility: .visible
    ) {
      Button(acceptanceImpact.actionTitle) {
        model.decideTicketSuggestion(suggestion, accept: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(acceptanceImpact.message)
    }
    .confirmationDialog(
      rejectionImpact.dialogTitle,
      isPresented: $confirmingCascadeRejection,
      titleVisibility: .visible
    ) {
      Button(rejectionImpact.actionTitle, role: .destructive) {
        model.rejectTicketSuggestion(suggestion)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rejectionImpact.message)
    }
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
  @Binding var selectedSprintID: UUID?
  let onShowBacklog: () -> Void
  let onEditPlan: () -> Void
  let onShowRetrospective: () -> Void
  let onShowReports: () -> Void
  @State private var selectedTicket: WorkItem?
  @State private var showingStopSprintConfirmation = false
  @State private var isUpdatingSprintState = false
  @Namespace private var ticketMotionNamespace

  private let lanes = [
    SprintLane(title: "Ready to Pick", states: [.queued]),
    SprintLane(title: "In Progress", states: [.running]),
    SprintLane(title: "In Review", states: [.integrating, .verifying, .readyToRelease]),
    SprintLane(title: "Ready for Demo", states: [.acceptance]),
    SprintLane(title: "Done", states: [.released]),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 0) {
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
          Text("Track each ticket from Ready to Pick through review, demo, and Done.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 8) {
          HStack(spacing: 0) {
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
              .frame(width: 190, alignment: .trailing)
            }

            if availablePlans.count > 1, hasHeaderActions {
              Divider()
                .frame(height: 22)
                .padding(.horizontal, 12)
            }

            HStack(spacing: 6) {
              if let plan = selectedPlan, plan.sprint.state == .active {
                Button {
                  updateSprintState {
                    await model.pauseSprint(plan.sprint)
                  }
                } label: {
                  Image(systemName: "pause.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isUpdatingSprintState)
                .accessibilityLabel(isUpdatingSprintState ? "Pausing sprint" : "Pause sprint")
                .help("Pause delivery and preserve work so this sprint can resume later")
              }
              if let plan = selectedPlan, plan.sprint.state == .paused {
                Button {
                  updateSprintState {
                    await model.resumeSprint(plan.sprint)
                  }
                } label: {
                  Image(systemName: "play.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isUpdatingSprintState)
                .accessibilityLabel(
                  isUpdatingSprintState ? "Resuming sprint" : "Resume sprint"
                )
                .help("Continue preserved work in this sprint")
              }
              if let plan = selectedPlan, plan.sprint.state.isInProgress {
                Button(role: .destructive) {
                  showingStopSprintConfirmation = true
                } label: {
                  Image(systemName: "stop.fill")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isUpdatingSprintState)
                .accessibilityLabel("Stop sprint")
                .help("Stop this sprint and return unfinished tickets to Ready")
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
              if let draftPlan = selectedDraftPlan {
                let startAvailability = SprintStartAvailability(
                  draft: draftPlan,
                  plans: availablePlans
                )
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
                    || startAvailability.isBlocked
                )
                .help(startAvailability.explanation ?? "Start the sprint")
              }
            }
          }

          if let plan = selectedPlan {
            HStack(spacing: 6) {
              Image(systemName: "flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
              Text(plan.sprint.goal)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: 420, alignment: .trailing)
            .help("Sprint goal: \(plan.sprint.goal)")
            .accessibilityLabel("Sprint goal")
            .accessibilityValue(plan.sprint.goal)
          }
        }
      }
      .workspaceHeaderLayout()

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
              max(210, availableForColumns / CGFloat(max(1, lanes.count)))
            )

            ScrollView(.horizontal) {
              HStack(alignment: .top, spacing: interColumnSpacing) {
                ForEach(lanes) { lane in
                  SprintBoardColumn(
                    title: boardLaneTitle(for: lane, plan: plan),
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
    .onChange(of: model.isLoading) { _, isLoading in
      if !isLoading {
        selectPreferredPlanIfNeeded()
      }
    }
    .sheet(item: $selectedTicket) { item in
      if selectedPlan?.sprint.state == .draft {
        TicketDetailView(
          item: item,
          dependsOnWorkItemIDs: Set(
            model.dependencies
              .filter { $0.workItemID == item.id }
              .map(\.dependsOnWorkItemID)
          )
        )
      } else {
        SprintTicketDetailView(item: item)
      }
    }
    .alert(
      selectedPlan.map { "Stop Sprint \($0.sprint.number)?" } ?? "Stop sprint?",
      isPresented: $showingStopSprintConfirmation
    ) {
      Button("Stop sprint", role: .destructive) {
        guard let plan = selectedPlan else { return }
        updateSprintState {
          await model.stopSprint(plan.sprint)
        }
      }
      Button("Keep sprint", role: .cancel) {}
    } message: {
      Text(
        "Done tickets stay Done. Spedito will stop current work, preserve its Work logs, Conversations, workspaces, and candidate history for audit, and return unfinished tickets to Ready for replanning. No unaccepted candidate will be promoted. This cannot be undone."
      )
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

  private var hasHeaderActions: Bool {
    selectedPlan?.sprint.state.isInProgress == true
      || selectedPlan?.sprint.state == .completed
      || selectedDraftPlan != nil
  }

  private var preferredPlan: SprintPlan? {
    availablePlans.first(where: { $0.sprint.state == .active })
      ?? availablePlans.first(where: { $0.sprint.state == .paused })
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
    guard !model.isLoading, !availablePlans.isEmpty else {
      return
    }
    selectSprint(preferredPlan?.sprint.id)
  }

  private var restoredSprintID: UUID? {
    guard let productID = model.selectedProductID else { return nil }
    return SprintBoardSelectionDefaults.selectedSprintID(for: productID)
  }

  private func selectSprint(_ sprintID: UUID?) {
    selectedSprintID = sprintID
    guard let productID = model.selectedProductID else { return }
    SprintBoardSelectionDefaults.select(sprintID, for: productID)
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

  private func boardLaneTitle(for lane: SprintLane, plan: SprintPlan) -> String {
    guard plan.sprint.state == .draft, lane.states == [.queued] else {
      return lane.title
    }
    return isReadyToStart(plan) ? lane.title : "Planning"
  }

  private func sprintSelectorTitle(for plan: SprintPlan) -> String {
    switch plan.sprint.state {
    case .draft: "Planning"
    case .active: "Active"
    case .paused: "Paused"
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
    case .paused:
      return "PAUSED"
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
    case .paused:
      .orange
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

  private func updateSprintState(
    _ operation: @escaping () async -> Bool
  ) {
    guard !isUpdatingSprintState else { return }
    isUpdatingSprintState = true
    Task {
      _ = await operation()
      isUpdatingSprintState = false
    }
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
          Text("Saved sprint \(plan.sprint.number) plan")
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
  let onOpenRefiningTicket: (WorkItem) -> Void
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
              let phase = RetrospectivePhase(sprint: plan.sprint)
              Text("Sprint \(plan.sprint.number) · \(phase.pickerTitle)")
                .tag(plan.sprint.id)
            }
          }
          .labelsHidden()
          .frame(width: 230, alignment: .trailing)
        }
      }
      .workspaceHeaderLayout()

      Divider()

      if let selectedPlan {
        VStack(spacing: 0) {
          if selectedPlan.sprint.state.isInProgress {
            activeSprintPreviewBanner(selectedPlan.sprint)
            Divider()
          }

          retrospectiveWorkspace

          Divider()
          retrospectiveFooter(selectedPlan)
        }
      } else {
        ContentUnavailableView {
          Label("No sprint evidence yet", systemImage: "rectangle.3.group.bubble")
        } description: {
          Text(
            "Start a sprint and Spedito will collect specific wins, friction, and suggested improvements from each agent."
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      selectPreferredPlanIfNeeded()
      prepareSelectedSynthesisIfNeeded()
    }
    .onChange(of: availablePlanSignature) { _, _ in
      selectPreferredPlanIfNeeded()
      prepareSelectedSynthesisIfNeeded()
    }
    .onChange(of: selectedSprintID) { _, _ in
      prepareSelectedSynthesisIfNeeded()
    }
  }

  private func activeSprintPreviewBanner(_ sprint: Sprint) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: "clock.arrow.circlepath")
        .foregroundStyle(.purple)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 3) {
        Text(
          sprint.state == .paused
            ? "Sprint \(sprint.number) is paused"
            : "Sprint \(sprint.number) is still in progress"
        )
          .font(.callout.weight(.semibold))
        Text(
          sprint.state == .paused
            ? "Existing evidence is preserved. Collection continues when the sprint resumes."
            : "Evidence will continue to accumulate until the sprint ends. "
              + "Add action ideas whenever they occur; the Business Analyst will consider them "
              + "with the team’s evidence when preparing the final actions."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
    .background(Color.purple.opacity(0.055))
  }

  private var availablePlans: [SprintPlan] {
    var plans = model.sprintHistory
    if let current = model.sprintPlan,
      !plans.contains(where: { $0.sprint.id == current.sprint.id })
    {
      plans.append(current)
    }
    return plans
      .filter { $0.sprint.state.isInProgress || $0.sprint.state == .completed }
      .sorted { $0.sprint.number > $1.sprint.number }
  }

  private var availablePlanSignature: [String] {
    availablePlans.map {
      "\($0.sprint.id.uuidString):\($0.sprint.state.rawValue):\($0.sprint.retrospectiveConcludedAt?.timeIntervalSince1970 ?? 0)"
    }
  }

  private var preferredPlan: SprintPlan? {
    guard
      let preferredSprintID = RetrospectiveSprintSelection.preferredSprintID(
        in: availablePlans
      )
    else { return nil }
    return availablePlans.first { $0.sprint.id == preferredSprintID }
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
      $0.category == .suggestedAction
        && !$0.isActionCandidate
        && $0.actionStatus == .proposed
    }
  }

  private var selectedSynthesis: RetrospectiveSynthesis? {
    guard let sprintID = selectedPlan?.sprint.id else { return nil }
    return model.retrospectiveSyntheses.first { $0.sprintID == sprintID }
  }

  private func selectPreferredPlanIfNeeded() {
    guard
      selectedSprintID == nil
        || !availablePlans.contains(where: { $0.sprint.id == selectedSprintID })
    else { return }
    selectedSprintID = preferredPlan?.sprint.id
  }

  private func prepareSelectedSynthesisIfNeeded() {
    guard
      let plan = selectedPlan,
      plan.sprint.state == .completed,
      plan.sprint.retrospectiveConcludedAt == nil
    else { return }
    model.prepareRetrospectiveSynthesisIfNeeded(sprintID: plan.sprint.id)
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
          sprint: selectedPlan?.sprint,
          synthesis: selectedSynthesis,
          notes: selectedNotes.filter { $0.category == .suggestedAction },
          onOpenRefiningTicket: onOpenRefiningTicket
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
        themes: themes(for: .wentWell),
        allowsActionDecisions: selectedPlan.map {
          RetrospectivePhase(sprint: $0.sprint) == .reviewing
        } ?? false
      )
      RetrospectiveColumn(
        category: .couldImprove,
        themes: themes(for: .couldImprove),
        allowsActionDecisions: selectedPlan.map {
          RetrospectivePhase(sprint: $0.sprint) == .reviewing
        } ?? false
      )
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func retrospectiveFooter(_ plan: SprintPlan) -> some View {
    HStack(spacing: 10) {
      if
        plan.sprint.state.isInProgress
          || plan.sprint.retrospectiveConcludedAt != nil
          || !unresolvedActions.isEmpty
      {
        Image(
          systemName: plan.sprint.retrospectiveConcludedAt == nil
            ? "arrow.triangle.2.circlepath"
            : "checkmark.seal.fill"
        )
        .foregroundStyle(
          plan.sprint.retrospectiveConcludedAt == nil ? .purple : .green
        )
        if plan.sprint.state.isInProgress {
          Text(
            plan.sprint.state == .paused
              ? "Evidence collection is paused with the sprint."
              : "Evidence is still being collected."
          )
        } else if let concludedAt = plan.sprint.retrospectiveConcludedAt {
          Text(
            "Concluded \(concludedAt.formatted(date: .abbreviated, time: .shortened))"
          )
        } else {
          Text(
            "\(unresolvedActions.count) suggested action\(unresolvedActions.count == 1 ? "" : "s") still need a decision."
          )
        }
      }
      Spacer()
      Text("\(selectedNotes.count) observations")
        .foregroundStyle(.secondary)
        .monospacedDigit()
      if plan.sprint.retrospectiveConcludedAt != nil {
        Button("Back to backlog", action: onConcluded)
          .buttonStyle(.borderedProminent)
      } else if plan.sprint.state == .completed {
        let synthesisIsResolved = selectedSynthesis?.status.isResolved == true
        let conclusionHelp =
          !synthesisIsResolved
          ? "Wait for the final actions, retry their preparation, or continue without AI suggestions."
          : unresolvedActions.isEmpty
            ? "Close this sprint’s learning loop and return to the next backlog."
            : "Accept or dismiss every proposed action first."
        Button(isConcluding ? "Concluding…" : "Conclude retrospective") {
          isConcluding = true
          Task {
            let didConclude = await model.concludeRetrospective(
              productID: plan.sprint.productID,
              sprintID: plan.sprint.id
            )
            isConcluding = false
            if didConclude {
              onConcluded()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          isConcluding || !unresolvedActions.isEmpty || !synthesisIsResolved
        )
        .help(conclusionHelp)
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
  let sprint: Sprint?
  let synthesis: RetrospectiveSynthesis?
  let notes: [RetrospectiveNote]
  let onOpenRefiningTicket: (WorkItem) -> Void
  @State private var isDecidingAll = false
  @State private var selectedNoteID: UUID?
  @State private var showingProposal = false
  @State private var showingActionIdea = false

  private var actionCandidateNotes: [RetrospectiveNote] {
    notes
      .filter(\.isActionCandidate)
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var decisionNotes: [RetrospectiveNote] {
    notes.filter { !$0.isActionCandidate }
  }

  private var proposedNotes: [RetrospectiveNote] {
    decisionNotes
      .filter { $0.actionStatus == .proposed }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var acceptedNotes: [RetrospectiveNote] {
    decisionNotes
      .filter { $0.actionStatus == .accepted }
      .sorted { $0.updatedAt < $1.updatedAt }
  }

  private var dismissedCount: Int {
    decisionNotes.count { $0.actionStatus == .dismissed }
  }

  private var reviewedCount: Int {
    decisionNotes.count - proposedNotes.count
  }

  private var selectedNote: RetrospectiveNote? {
    proposedNotes.first { $0.id == selectedNoteID } ?? proposedNotes.first
  }

  private var queuedNotes: [RetrospectiveNote] {
    guard let selectedNote else { return proposedNotes }
    return proposedNotes.filter { $0.id != selectedNote.id }
  }

  private var phase: RetrospectivePhase {
    sprint.map(RetrospectivePhase.init(sprint:)) ?? .collecting
  }

  private var canPropose: Bool {
    phase == .reviewing && synthesis?.status.isResolved == true
  }

  private var canCaptureActionIdea: Bool {
    phase == .collecting
  }

  private var isHistorical: Bool {
    phase == .concluded
  }

  private var decisionSummary: String {
    switch phase {
    case .collecting:
      let ideaCount = actionCandidateNotes.count
      return actionCandidateNotes.isEmpty
        ? "Evidence still collecting"
        : "\(ideaCount) action idea\(ideaCount == 1 ? "" : "s") captured"
    case .concluded:
      let accepted = "\(acceptedNotes.count) accepted"
      guard dismissedCount > 0 else { return accepted }
      return "\(accepted) · \(dismissedCount) dismissed"
    case .reviewing:
      if synthesis?.status == .pending || synthesis?.status == .generating {
        return "Business Analyst synthesis"
      }
      if synthesis?.status == .failed {
        return "Needs attention"
      }
      return proposedNotes.isEmpty
        ? "\(reviewedCount) reviewed"
        : "\(proposedNotes.count) remaining · \(reviewedCount) reviewed"
    }
  }

  private var canAcceptAll: Bool {
    phase == .reviewing
      && proposedNotes.allSatisfy { $0.actionDestination != .backlog }
  }

  private var panelTitle: String {
    switch phase {
    case .collecting: "Action ideas"
    case .reviewing:
      if synthesis?.status == .pending || synthesis?.status == .generating {
        "Preparing actions"
      } else {
        "Actions to review"
      }
    case .concluded: "Decisions"
    }
  }

  private var queueTitle: String {
    phase == .collecting ? "Also collected" : "Up next"
  }

  private var emptyStateTitle: String {
    phase == .collecting ? "Capture action ideas as they happen" : "Decisions complete"
  }

  private var emptyStateDetail: String {
    if phase == .collecting {
      return "Add an action idea now. The Business Analyst will consider it after the sprint ends."
    }
    return reviewedCount == 0
      ? "The team did not suggest a change."
      : "Every suggested change has been reviewed."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "checklist")
          .foregroundStyle(.indigo)
        VStack(alignment: .leading, spacing: 2) {
          Text(panelTitle)
            .font(.title3.bold())
          Text(decisionSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if canCaptureActionIdea {
          Button {
            showingActionIdea = true
          } label: {
            Label("Add action idea", systemImage: "plus")
          }
          .controlSize(.small)
          .help("Capture an action idea for the retrospective")
        }
        if canPropose {
          Button {
            showingProposal = true
          } label: {
            Label("Propose change", systemImage: "plus")
          }
          .controlSize(.small)
          .help("Add your own retrospective proposal")
        }
        if phase == .reviewing, proposedNotes.count > 1 {
          Menu {
            if canAcceptAll {
              Button {
                decideAll(accept: true)
              } label: {
                Label("Accept all", systemImage: "checkmark.circle")
              }
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

      if isHistorical {
        historicalDecisions
      } else if phase == .collecting {
        capturedActionIdeas
      } else if phase == .reviewing,
        synthesis == nil || synthesis?.status == .pending || synthesis?.status == .generating
      {
        synthesisProgress
      } else if phase == .reviewing, synthesis?.status == .failed {
        synthesisFailure
      } else if let selectedNote {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 18) {
            RetrospectiveActionDecisionDetail(
              note: selectedNote,
              allowsDecisions: phase == .reviewing,
              onOpenRefiningTicket: onOpenRefiningTicket
            )

            if !queuedNotes.isEmpty {
              VStack(alignment: .leading, spacing: 0) {
                Text(queueTitle)
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
        VStack(spacing: 6) {
          Image(
            systemName: phase == .collecting
              ? "clock.arrow.circlepath"
              : "checkmark.circle"
          )
            .font(.title3)
            .foregroundStyle(.tertiary)
          Text(emptyStateTitle)
            .font(.subheadline.weight(.medium))
          Text(emptyStateDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    .sheet(isPresented: $showingProposal) {
      if let sprint {
        RetrospectiveProposalView(
          productID: sprint.productID,
          sprintID: sprint.id,
          isPresented: $showingProposal
        )
      }
    }
    .sheet(isPresented: $showingActionIdea) {
      if let sprint {
        RetrospectiveActionIdeaView(
          productID: sprint.productID,
          sprintID: sprint.id,
          isPresented: $showingActionIdea
        )
      }
    }
  }

  @ViewBuilder
  private var capturedActionIdeas: some View {
    if actionCandidateNotes.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "square.and.pencil")
          .font(.title3)
          .foregroundStyle(.tertiary)
        Text(emptyStateTitle)
          .font(.subheadline.weight(.medium))
        Text(emptyStateDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .padding(16)
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(
            Array(actionCandidateNotes.enumerated()),
            id: \.element.id
          ) { index, note in
            RetrospectiveActionCandidateRow(
              note: note,
              allowsDeletion:
                note.authorName == "Product Owner"
                && note.profileID == nil
            )
            if index < actionCandidateNotes.count - 1 {
              Divider()
                .padding(.leading, 39)
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
    }
  }

  private var synthesisProgress: some View {
    VStack(spacing: 10) {
      if synthesis?.status == .generating {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "wand.and.stars")
          .font(.title3)
          .foregroundStyle(.purple)
      }
      Text(
        synthesis?.status == .generating
          ? "Consolidating sprint evidence"
          : "Waiting to prepare final actions"
      )
      .font(.subheadline.weight(.medium))
      Text(
        synthesis?.status == .generating
          ? "The Business Analyst is grouping repeated observations into no more than five reviewable actions."
          : "Spedito will ask the Business Analyst to prepare the final action list when Codex is available."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)

      if let synthesis, synthesis.status == .pending {
        Button("Continue without AI suggestions") {
          Task { await model.skipRetrospectiveSynthesis(synthesis) }
        }
        .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(24)
  }

  private var synthesisFailure: some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title3)
        .foregroundStyle(.orange)
      Text("Final actions could not be prepared")
        .font(.subheadline.weight(.medium))
      Text(
        synthesis?.errorMessage
          ?? "The evidence is preserved and can be processed again safely."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)

      if let synthesis {
        HStack(spacing: 7) {
          Button("Continue without AI suggestions") {
            Task { await model.skipRetrospectiveSynthesis(synthesis) }
          }
          Button("Retry") {
            model.retryRetrospectiveSynthesis(synthesis)
          }
          .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(24)
  }

  @ViewBuilder
  private var historicalDecisions: some View {
    if acceptedNotes.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "checkmark.circle")
          .font(.title3)
          .foregroundStyle(.tertiary)
        Text("No changes were accepted")
          .font(.subheadline.weight(.medium))
        Text(historicalEmptyStateDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .padding(16)
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(acceptedNotes.enumerated()), id: \.element.id) { index, note in
            RetrospectiveAcceptedDecisionRow(note: note)
              .overlay(alignment: .bottom) {
                if index < acceptedNotes.count - 1 {
                  Divider()
                    .padding(.leading, 43)
                    .padding(.trailing, 4)
                }
              }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
      }
    }
  }

  private var historicalEmptyStateDetail: String {
    if dismissedCount > 0 {
      return "\(dismissedCount) suggested change\(dismissedCount == 1 ? " was" : "s were") dismissed."
    }
    return "No changes were proposed in this retrospective."
  }

  private func decideAll(accept: Bool) {
    isDecidingAll = true
    Task {
      await model.decideRetrospectiveActions(proposedNotes, accept: accept)
      isDecidingAll = false
    }
  }
}

private struct RetrospectiveActionCandidateRow: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let allowsDeletion: Bool
  @State private var confirmingDeletion = false
  @State private var isDeleting = false

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: "lightbulb")
        .foregroundStyle(.indigo)
        .frame(width: 28, height: 28)
        .background(Color.indigo.opacity(0.1), in: Circle())

      VStack(alignment: .leading, spacing: 5) {
        Text(note.body)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 5) {
          Text(note.authorName)
          Text("·")
          Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Label("For Business Analyst review", systemImage: "clock")
          .font(.caption.weight(.medium))
          .foregroundStyle(.purple)
      }

      if allowsDeletion {
        Button(role: .destructive) {
          confirmingDeletion = true
        } label: {
          Image(systemName: "trash")
            .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .disabled(isDeleting)
        .help("Delete this action idea")
      }
    }
    .padding(.vertical, 10)
    .confirmationDialog(
      "Delete this action idea?",
      isPresented: $confirmingDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete action idea", role: .destructive) {
        isDeleting = true
        Task {
          await model.deleteRetrospectiveActionIdea(note)
          isDeleting = false
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "It will not be included when the Business Analyst prepares the retrospective."
      )
    }
  }
}

private struct RetrospectiveActionIdeaView: View {
  @EnvironmentObject private var model: AppModel
  let productID: UUID
  let sprintID: UUID
  @Binding var isPresented: Bool
  @State private var actionIdea = ""
  @State private var isSubmitting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add an action idea")
          .font(.title.bold())
        Text(
          "Capture the idea now. The Business Analyst will consider it with the team’s evidence after the sprint ends."
        )
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        EditableTextArea(
          title: "What change should the team consider?",
          prompt: "e.g. Confirm required access before starting delivery.",
          text: $actionIdea,
          minHeight: 140,
          focusOnAppear: true
        )

        Label(
          "This is source evidence during the sprint, not an early decision. You’ll review any final action after the Business Analyst prepares the retrospective.",
          systemImage: "clock"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Spacer(minLength: 0)
      Divider()

      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        Button {
          submit()
        } label: {
          Label(
            isSubmitting ? "Adding…" : "Add action idea",
            systemImage: "plus.circle"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .padding(20)
    }
    .frame(width: 620, height: 440)
  }

  private var canSubmit: Bool {
    !actionIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSubmitting
  }

  private func submit() {
    guard canSubmit else { return }
    isSubmitting = true
    Task {
      let note = await model.captureRetrospectiveActionIdea(
        productID: productID,
        sprintID: sprintID,
        body: actionIdea
      )
      isSubmitting = false
      if note != nil {
        isPresented = false
      }
    }
  }
}

private struct RetrospectiveProposalView: View {
  @EnvironmentObject private var model: AppModel
  let productID: UUID
  let sprintID: UUID
  @Binding var isPresented: Bool
  @State private var destination = RetrospectiveActionDestination.teamPractice
  @State private var proposal = ""
  @State private var isSubmitting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Propose a retrospective change")
          .font(.title.bold())
        Text(
          "Add your own improvement to the same reviewable decision queue as the team’s suggestions."
        )
        .foregroundStyle(.secondary)
      }
      .padding(24)

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Change type")
            .font(.subheadline.weight(.semibold))
          Picker("Change type", selection: $destination) {
            ForEach(RetrospectiveActionDestination.allCases, id: \.rawValue) { destination in
              Text(destination.title).tag(destination)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }

        EditableTextArea(
          title: proposalTitle,
          prompt: proposalPrompt,
          text: $proposal,
          minHeight: 140,
          focusOnAppear: true
        )

        Label(guidance, systemImage: "checkmark.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(24)

      Spacer(minLength: 0)
      Divider()

      HStack(spacing: 10) {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        Button {
          submit()
        } label: {
          Label(
            isSubmitting ? "Adding…" : "Add proposal",
            systemImage: "plus.circle"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .padding(20)
    }
    .frame(width: 620, height: 480)
  }

  private var proposalTitle: String {
    switch destination {
    case .teamPractice:
      "What should change in the ways of working?"
    case .backlog:
      "What outcome should the ticket deliver?"
    }
  }

  private var proposalPrompt: String {
    switch destination {
    case .teamPractice:
      "e.g. Confirm the preview evidence before asking for Product Owner approval."
    case .backlog:
      "e.g. Make sprint forecast changes visible in the retrospective."
    }
  }

  private var guidance: String {
    switch destination {
    case .teamPractice:
      "If accepted, this is added to Ways of working and inherited by future team runs."
    case .backlog:
      "If accepted, this creates a backlog ticket and opens it for automatic Business Analyst refinement."
    }
  }

  private var canSubmit: Bool {
    !proposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSubmitting
  }

  private func submit() {
    guard canSubmit else { return }
    isSubmitting = true
    Task {
      let note = await model.proposeRetrospectiveAction(
        productID: productID,
        sprintID: sprintID,
        body: proposal,
        destination: destination
      )
      isSubmitting = false
      if note != nil {
        isPresented = false
      }
    }
  }
}

private struct RetrospectiveActionDecisionDetail: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let allowsDecisions: Bool
  let onOpenRefiningTicket: (WorkItem) -> Void
  @State private var areSourcesExpanded = false

  private var ticket: WorkItem? {
    guard let workItemID = note.workItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var destination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var attributionSymbol: String {
    if attribution.authorNames.count > 1 || attribution.profileIDs.count > 1 {
      return "person.2.fill"
    }
    return profile?.role.symbolName ?? "person.crop.circle"
  }

  private var sourceTicketKeys: [String] {
    Array(
      Set(
        sources.compactMap { source in
          source.workItemID.flatMap { workItemID in
            model.workItems.first { $0.id == workItemID }?.key
          }
        }
      )
    ).sorted()
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

      if let expectedEffect = note.expectedEffect {
        VStack(alignment: .leading, spacing: 3) {
          Text("Expected effect")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(expectedEffect)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: 6) {
        Image(systemName: attributionSymbol)
          .foregroundStyle(profile?.role.tint ?? .secondary)
        Text(attribution.summary)
          .fontWeight(.semibold)
        if let ticket {
          Text("· \(ticket.key)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      if !sources.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          Button {
            withAnimation(.easeInOut(duration: 0.16)) {
              areSourcesExpanded.toggle()
            }
          } label: {
            HStack(spacing: 7) {
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(areSourcesExpanded ? 90 : 0))
                .frame(width: 12)
              Text(sourceSummary)
                .font(.caption.weight(.semibold))
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(sourceSummary)
          .accessibilityValue(areSourcesExpanded ? "Expanded" : "Collapsed")
          .accessibilityHint(
            areSourcesExpanded
              ? "Collapse the source observations"
              : "Expand the source observations"
          )

          if areSourcesExpanded {
            Divider()
              .overlay(Color(nsColor: .separatorColor).opacity(0.55))
              .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 9) {
              ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 3) {
                  HStack(spacing: 5) {
                    Text(source.authorName)
                      .fontWeight(.semibold)
                    if let workItemID = source.workItemID,
                      let sourceTicket = model.workItems.first(where: {
                        $0.id == workItemID
                      })
                    {
                      Text("· \(sourceTicket.key)")
                        .foregroundStyle(.secondary)
                    }
                  }
                  Text(source.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .transition(.opacity)
          }
        }
        .background(
          Color(nsColor: .windowBackgroundColor).opacity(0.7),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
      }

      Divider()

      Text(
        actionEffectDescription
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if allowsDecisions {
        HStack(spacing: 7) {
          Spacer()
          Button("Dismiss") {
            Task { await model.decideRetrospectiveAction(note, accept: false) }
          }
          Button {
            Task {
              let createdItem = await model.decideRetrospectiveAction(
                note,
                accept: true
              )
              if let createdItem {
                onOpenRefiningTicket(createdItem)
              }
            }
          } label: {
            Label("Accept", systemImage: "checkmark.circle")
          }
          .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
      } else {
        Label("Available after sprint completion", systemImage: "clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
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

  private var sourceSummary: String {
    let observationCount =
      "\(sources.count) source observation\(sources.count == 1 ? "" : "s")"
    guard !sourceTicketKeys.isEmpty else { return observationCount }
    return "\(observationCount) · \(sourceTicketKeys.joined(separator: ", "))"
  }

  private var actionEffectDescription: String {
    switch (allowsDecisions, destination) {
    case (true, .teamPractice):
      "Accepting updates the team’s Ways of working."
    case (true, .backlog):
      "Accepting creates a new backlog ticket."
    case (false, .teamPractice):
      "If accepted after the sprint, this will update the team’s Ways of working."
    case (false, .backlog):
      "If accepted after the sprint, this will create a new backlog ticket."
    }
  }
}

private struct RetrospectiveActionQueueRow: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote
  let onSelect: () -> Void
  @State private var isHovering = false

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
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
            Text(attribution.summary)
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

private struct RetrospectiveAcceptedDecisionRow: View {
  @EnvironmentObject private var model: AppModel
  let note: RetrospectiveNote

  private var destination: RetrospectiveActionDestination {
    note.actionDestination ?? .teamPractice
  }

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var attributionSymbol: String {
    if attribution.authorNames.count > 1 || attribution.profileIDs.count > 1 {
      return "person.2.fill"
    }
    return profile?.role.symbolName ?? "person.crop.circle"
  }

  private var acceptedTicket: WorkItem? {
    guard let workItemID = note.acceptedWorkItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: destinationSymbol)
        .foregroundStyle(destinationTint)
        .frame(width: 28, height: 28)
        .background(destinationTint.opacity(0.1), in: Circle())

      VStack(alignment: .leading, spacing: 5) {
        Text(note.body)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 5) {
          Label("Accepted", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("·")
          Text(destination.title)
          if let acceptedTicket {
            Text("·")
            Text(acceptedTicket.key)
          }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

        HStack(spacing: 5) {
          Image(systemName: attributionSymbol)
            .foregroundStyle(profile?.role.tint ?? .secondary)
          Text(attribution.summary)
          Text("·")
          Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 10)
  }

  private var destinationTint: Color {
    destination == .teamPractice ? .purple : .blue
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
  let allowsActionDecisions: Bool

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
          Text(
            allowsActionDecisions
              ? "The team has chosen a destination for each action. Accept it or dismiss it."
              : "Suggested actions remain reviewable previews until the sprint is complete."
          )
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
            tint: tint,
            allowsActionDecisions: allowsActionDecisions
          )
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
  }

  private var panelTitle: String {
    guard category == .suggestedAction else { return category.title }
    return allowsActionDecisions ? "Actions to decide" : "Emerging actions"
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
  let allowsActionDecisions: Bool
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
            if allowsActionDecisions {
              Text("\(proposedNotes.count) to decide")
                .foregroundStyle(.orange)
            } else {
              Text("\(proposedNotes.count) collected")
                .foregroundStyle(.secondary)
            }
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
          if
            category == .suggestedAction,
            allowsActionDecisions,
            !proposedNotes.isEmpty
          {
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
            RetrospectiveStickyNote(
              note: note,
              tint: tint,
              allowsActionDecisions: allowsActionDecisions
            )
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
  let allowsActionDecisions: Bool

  private var ticket: WorkItem? {
    guard let workItemID = note.workItemID else { return nil }
    return model.workItems.first { $0.id == workItemID }
  }

  private var sources: [RetrospectiveNote] {
    model.retrospectiveSources(for: note.id)
  }

  private var attribution: RetrospectiveActionAttribution {
    .resolve(
      sourceNotes: sources,
      fallbackAuthorName: note.authorName,
      fallbackProfileID: note.profileID
    )
  }

  private var profile: AgentProfile? {
    guard attribution.profileIDs.count == 1,
      let profileID = attribution.profileIDs.first
    else { return nil }
    return model.profiles.first { $0.id == profileID }
  }

  private var attributionSymbol: String {
    if attribution.authorNames.count > 1 || attribution.profileIDs.count > 1 {
      return "person.2.fill"
    }
    return profile?.role.symbolName ?? "person.crop.circle"
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
        Image(systemName: attributionSymbol)
          .foregroundStyle(profile?.role.tint ?? tint)
        Text(attribution.summary)
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
      if allowsActionDecisions {
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
      } else {
        Label("Available after sprint completion", systemImage: "clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
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
  @State private var sprintRange: SprintReportRange = .latestTwelve
  @State private var selectedSprintNumber: Int?

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
        if !completedSprints.isEmpty {
          Text("\(completedSprints.count) completed sprint\(completedSprints.count == 1 ? "" : "s")")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .workspaceHeaderLayout()

      Divider()

      if completedSprints.isEmpty {
        ContentUnavailableView {
          Label("No report data yet", systemImage: "chart.xyaxis.line")
        } description: {
          Text(
            "Complete a sprint and Spedito will report delivery time, outcomes, and review effort."
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
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
                HStack(alignment: .firstTextBaseline) {
                  Text("Sprint performance")
                    .font(.title3.bold())
                  Spacer()
                  if sprintData.count > SprintReportPresentation.recentSprintLimit {
                    Picker("Sprint range", selection: $sprintRange) {
                      ForEach(SprintReportRange.allCases) { range in
                        Text(range.title).tag(range)
                      }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityLabel("Sprint range")
                  }
                }
                Text(
                  "Choose one delivery signal at a time. Agent effort is normalized per delivered outcome so larger sprints do not automatically look more expensive. Select a sprint for exact values."
                )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                SprintPerformanceChart(
                  data: visibleSprintData,
                  selectedSprintNumber: $selectedSprintNumber
                )
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
    .onAppear {
      selectLatestVisibleSprintIfNeeded()
    }
    .onChange(of: visibleSprintData.map(\.sprintNumber)) { _, _ in
      selectLatestVisibleSprintIfNeeded()
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
    return RunDurationFormatter.duration(value)
  }

  private var totalAgentTime: TimeInterval {
    model.runs
      .filter { $0.sprintID.map(completedSprintIDs.contains) == true }
      .reduce(0) { $0 + $1.activeDuration() }
  }

  private var agentTimePerOutcome: String? {
    guard deliveredOutcomes > 0, totalAgentTime > 0 else { return nil }
    return RunDurationFormatter.duration(totalAgentTime / Double(deliveredOutcomes))
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
      let cycleTime = if let started = plan.sprint.startedAt,
        let completed = plan.sprint.completedAt
      {
        Optional(max(0, completed.timeIntervalSince(started)))
      } else {
        Optional<TimeInterval>.none
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

  private var visibleSprintData: [SprintReportDatum] {
    SprintReportPresentation.visibleData(sprintData, range: sprintRange)
  }

  private func selectLatestVisibleSprintIfNeeded() {
    let visibleSprintNumbers = Set(visibleSprintData.map(\.sprintNumber))
    if selectedSprintNumber.map(visibleSprintNumbers.contains) != true {
      selectedSprintNumber = visibleSprintData.last?.sprintNumber
    }
  }
}

enum SprintReportRange: String, CaseIterable, Identifiable {
  case latestTwelve
  case all

  var id: Self { self }

  var title: String {
    switch self {
    case .latestTwelve: "Latest 12"
    case .all: "All"
    }
  }
}

struct SprintReportDatum: Identifiable, Equatable {
  let sprintNumber: Int
  let cycleTime: TimeInterval?
  let activeAgentTime: TimeInterval
  let outcomes: Int
  let reviewCorrections: Int
  let interruptedRuns: Int

  var id: Int { sprintNumber }

  var agentTimePerOutcome: TimeInterval? {
    guard outcomes > 0, activeAgentTime > 0 else { return nil }
    return activeAgentTime / Double(outcomes)
  }
}

enum SprintReportMetric {
  case cycleTime
  case agentTimePerOutcome

  func value(in datum: SprintReportDatum) -> TimeInterval? {
    switch self {
    case .cycleTime: datum.cycleTime
    case .agentTimePerOutcome: datum.agentTimePerOutcome
    }
  }
}

enum SprintReportChartType: String, CaseIterable, Identifiable {
  case cycleTime
  case agentEffort
  case outcomesAndReview

  var id: Self { self }

  var title: String {
    switch self {
    case .cycleTime: "Cycle time"
    case .agentEffort: "Agent effort"
    case .outcomesAndReview: "Outcomes and review"
    }
  }
}

struct SprintReportTrendPoint: Identifiable, Equatable {
  let sprintNumber: Int
  let value: TimeInterval
  let segment: Int

  var id: String {
    "\(segment)-\(sprintNumber)"
  }
}

enum SprintReportPresentation {
  static let recentSprintLimit = 12

  static func visibleData(
    _ data: [SprintReportDatum],
    range: SprintReportRange
  ) -> [SprintReportDatum] {
    switch range {
    case .latestTwelve:
      Array(data.suffix(recentSprintLimit))
    case .all:
      data
    }
  }

  static func trendPoints(
    in data: [SprintReportDatum],
    metric: SprintReportMetric
  ) -> [SprintReportTrendPoint] {
    var segment = 0
    var previousMeasuredSprint: Int?
    var points: [SprintReportTrendPoint] = []

    for datum in data {
      guard let value = metric.value(in: datum) else {
        previousMeasuredSprint = nil
        segment += 1
        continue
      }

      if let previousMeasuredSprint,
        datum.sprintNumber != previousMeasuredSprint + 1
      {
        segment += 1
      }
      points.append(
        SprintReportTrendPoint(
          sprintNumber: datum.sprintNumber,
          value: value,
          segment: segment
        )
      )
      previousMeasuredSprint = datum.sprintNumber
    }
    return points
  }

  static func median(_ values: [TimeInterval]) -> TimeInterval? {
    let sortedValues = values.sorted()
    guard !sortedValues.isEmpty else { return nil }
    let middle = sortedValues.count / 2
    return sortedValues.count.isMultiple(of: 2)
      ? (sortedValues[middle - 1] + sortedValues[middle]) / 2
      : sortedValues[middle]
  }

  static func axisSprintNumbers(
    in data: [SprintReportDatum],
    maximumLabelCount: Int = 8
  ) -> [Int] {
    let sprintNumbers = data.map(\.sprintNumber)
    guard maximumLabelCount > 1, sprintNumbers.count > maximumLabelCount else {
      return sprintNumbers
    }

    let step = Int(
      ceil(Double(sprintNumbers.count - 1) / Double(maximumLabelCount - 1))
    )
    var labels = stride(from: 0, to: sprintNumbers.count, by: step)
      .map { sprintNumbers[$0] }
    if let last = sprintNumbers.last, labels.last != last {
      labels.append(last)
    }
    return labels
  }

  static func sprintAxisDomain(
    in data: [SprintReportDatum]
  ) -> ClosedRange<Double>? {
    let sprintNumbers = data.map(\.sprintNumber)
    guard
      let firstSprintNumber = sprintNumbers.min(),
      let lastSprintNumber = sprintNumbers.max()
    else {
      return nil
    }
    return (Double(firstSprintNumber) - 0.5)...(Double(lastSprintNumber) + 0.5)
  }

  static func countAxisValues(
    maximumCount: Int,
    desiredIntervals: Int = 4
  ) -> [Int] {
    let maximumCount = max(1, maximumCount)
    let desiredIntervals = max(1, desiredIntervals)
    let step = max(
      1,
      Int(ceil(Double(maximumCount) / Double(desiredIntervals)))
    )
    var values = Array(stride(from: 0, through: maximumCount, by: step))
    if values.last != maximumCount {
      values.append(maximumCount)
    }
    return values
  }
}

private struct SprintPerformanceChart: View {
  let data: [SprintReportDatum]
  @Binding var selectedSprintNumber: Int?
  @State private var chartType: SprintReportChartType = .cycleTime

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker("Chart type", selection: $chartType) {
        ForEach(SprintReportChartType.allCases) { chartType in
          Text(chartType.title).tag(chartType)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 520)
      .accessibilityLabel("Chart type")

      switch chartType {
      case .cycleTime:
        SprintTimeTrendChart(
          title: "Cycle time",
          detail: "Wall time from sprint start to completion",
          metric: .cycleTime,
          tint: .purple,
          data: data,
          selectedSprintNumber: $selectedSprintNumber
        )
      case .agentEffort:
        SprintTimeTrendChart(
          title: "Agent time per outcome",
          detail: "Active delivery and review time divided by delivered outcomes",
          metric: .agentTimePerOutcome,
          tint: .indigo,
          data: data,
          selectedSprintNumber: $selectedSprintNumber
        )
      case .outcomesAndReview:
        SprintOutcomeChart(
          data: data,
          selectedSprintNumber: $selectedSprintNumber
        )
      }

      if let selectedSprint = data.first(where: {
        $0.sprintNumber == selectedSprintNumber
      }) {
        SprintReportSelectionSummary(sprint: selectedSprint)
      }
    }
  }
}

private struct SprintTimeTrendChart: View {
  let title: String
  let detail: String
  let metric: SprintReportMetric
  let tint: Color
  let data: [SprintReportDatum]
  @Binding var selectedSprintNumber: Int?

  private var points: [SprintReportTrendPoint] {
    SprintReportPresentation.trendPoints(in: data, metric: metric)
  }

  private var median: TimeInterval? {
    SprintReportPresentation.median(points.map(\.value))
  }

  private var durationScale: SprintReportDurationScale {
    SprintReportDurationScale(
      maximumDuration: points.map(\.value).max() ?? 0
    )
  }

  private var maximumPlottedValue: Double {
    max(
      1,
      durationScale.plottedValue(points.map(\.value).max() ?? 0) * 1.12
    )
  }

  private var axisSprintNumbers: [Int] {
    SprintReportPresentation.axisSprintNumbers(in: data)
  }

  private var sprintAxisDomain: ClosedRange<Double> {
    SprintReportPresentation.sprintAxisDomain(in: data) ?? 0.5...1.5
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let median {
          VStack(alignment: .trailing, spacing: 2) {
            Text("Median")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text(RunDurationFormatter.duration(median))
              .font(.caption.monospacedDigit().weight(.semibold))
          }
        }
      }

      if points.isEmpty {
        Text("No measured \(title.lowercased()) yet")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        Chart {
          if let median {
            RuleMark(
              y: .value("Median", durationScale.plottedValue(median))
            )
            .foregroundStyle(.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
          }

          ForEach(points) { point in
            LineMark(
              x: .value("Sprint", point.sprintNumber),
              y: .value(title, durationScale.plottedValue(point.value)),
              series: .value("Measured segment", point.segment)
            )
            .foregroundStyle(tint.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.linear)
          }

          ForEach(points) { point in
            PointMark(
              x: .value("Sprint", point.sprintNumber),
              y: .value(title, durationScale.plottedValue(point.value))
            )
            .foregroundStyle(tint)
            .symbolSize(48)
            .accessibilityLabel("Sprint \(point.sprintNumber), \(title)")
            .accessibilityValue(RunDurationFormatter.duration(point.value))
          }

          if let selectedSprintNumber,
            data.contains(where: { $0.sprintNumber == selectedSprintNumber })
          {
            RuleMark(x: .value("Selected sprint", selectedSprintNumber))
              .foregroundStyle(.secondary.opacity(0.55))
              .lineStyle(StrokeStyle(lineWidth: 1))
          }
        }
        .chartXScale(domain: sprintAxisDomain)
        .chartYScale(domain: 0...maximumPlottedValue)
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
              .foregroundStyle(.quaternary)
            AxisValueLabel {
              if let plottedValue = value.as(Double.self) {
                Text(durationScale.axisLabel(plottedValue))
              }
            }
          }
        }
        .chartXAxis {
          AxisMarks(values: axisSprintNumbers) { value in
            AxisGridLine()
              .foregroundStyle(.quaternary.opacity(0.7))
            AxisTick()
            AxisValueLabel {
              if let sprintNumber = value.as(Int.self) {
                Text("S\(sprintNumber)")
              }
            }
          }
        }
        .chartXSelection(value: $selectedSprintNumber)
        .frame(height: 190)
      }
    }
    .padding(16)
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.quaternary, lineWidth: 1)
    }
  }
}

private struct SprintOutcomeChart: View {
  let data: [SprintReportDatum]
  @Binding var selectedSprintNumber: Int?

  private var maximumCount: Int {
    max(
      1,
      data.flatMap { [$0.outcomes, $0.reviewCorrections] }.max() ?? 1
    )
  }

  private var axisSprintNumbers: [Int] {
    SprintReportPresentation.axisSprintNumbers(in: data)
  }

  private var sprintAxisDomain: ClosedRange<Double> {
    SprintReportPresentation.sprintAxisDomain(in: data) ?? 0.5...1.5
  }

  private var countAxisValues: [Int] {
    SprintReportPresentation.countAxisValues(maximumCount: maximumCount)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Outcomes and review")
          .font(.headline)
        Text("Delivered outcomes and additional candidate correction cycles")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 14) {
        Label("Accepted outcomes", systemImage: "square.fill")
          .foregroundStyle(.blue)
        Label("Correction cycles", systemImage: "circle.fill")
          .foregroundStyle(.orange)
        Spacer()
      }
      .font(.caption)

      Chart {
        ForEach(data) { sprint in
          BarMark(
            x: .value("Sprint", sprint.sprintNumber),
            y: .value("Accepted outcomes", sprint.outcomes)
          )
          .foregroundStyle(Color.blue.gradient)
          .accessibilityLabel("Sprint \(sprint.sprintNumber), accepted outcomes")
          .accessibilityValue(sprint.outcomes.formatted())
        }

        ForEach(data) { sprint in
          LineMark(
            x: .value("Sprint", sprint.sprintNumber),
            y: .value("Correction cycles", sprint.reviewCorrections)
          )
          .foregroundStyle(.orange)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.linear)
        }

        ForEach(data) { sprint in
          PointMark(
            x: .value("Sprint", sprint.sprintNumber),
            y: .value("Correction cycles", sprint.reviewCorrections)
          )
          .foregroundStyle(.orange)
          .symbolSize(45)
          .accessibilityLabel("Sprint \(sprint.sprintNumber), correction cycles")
          .accessibilityValue(sprint.reviewCorrections.formatted())
        }

        if let selectedSprintNumber,
          data.contains(where: { $0.sprintNumber == selectedSprintNumber })
        {
          RuleMark(x: .value("Selected sprint", selectedSprintNumber))
            .foregroundStyle(.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1))
        }
      }
      .chartXScale(domain: sprintAxisDomain)
      .chartYScale(domain: 0...Double(maximumCount) * 1.12)
      .chartYAxis {
        AxisMarks(position: .leading, values: countAxisValues) { value in
          AxisGridLine()
            .foregroundStyle(.quaternary)
          AxisValueLabel {
            if let count = value.as(Int.self) {
              Text(count.formatted())
            }
          }
        }
      }
      .chartXAxis {
        AxisMarks(values: axisSprintNumbers) { value in
          AxisGridLine()
            .foregroundStyle(.quaternary.opacity(0.7))
          AxisTick()
          AxisValueLabel {
            if let sprintNumber = value.as(Int.self) {
              Text("S\(sprintNumber)")
            }
          }
        }
      }
      .chartXSelection(value: $selectedSprintNumber)
      .frame(height: 190)
    }
    .padding(16)
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.quaternary, lineWidth: 1)
    }
  }
}

private struct SprintReportSelectionSummary: View {
  let sprint: SprintReportDatum

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Sprint \(sprint.sprintNumber)")
        .font(.headline)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 130), spacing: 18)],
        alignment: .leading,
        spacing: 10
      ) {
        ReportSelectionValue(
          title: "Cycle time",
          value: sprint.cycleTime.map(RunDurationFormatter.duration) ?? "Unavailable"
        )
        ReportSelectionValue(
          title: "Agent time per outcome",
          value: sprint.agentTimePerOutcome.map(RunDurationFormatter.duration) ?? "Unavailable"
        )
        ReportSelectionValue(
          title: "Delivered outcomes",
          value: sprint.outcomes.formatted()
        )
        ReportSelectionValue(
          title: "Correction cycles",
          value: sprint.reviewCorrections.formatted()
        )
        ReportSelectionValue(
          title: "Interrupted runs",
          value: sprint.interruptedRuns.formatted()
        )
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }
}

private struct ReportSelectionValue: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospacedDigit().weight(.semibold))
    }
  }
}

enum SprintReportDurationUnit: Equatable {
  case seconds
  case minutes
  case hours

  var seconds: TimeInterval {
    switch self {
    case .seconds: 1
    case .minutes: 60
    case .hours: 3_600
    }
  }

  var suffix: String {
    switch self {
    case .seconds: "s"
    case .minutes: "m"
    case .hours: "h"
    }
  }
}

struct SprintReportDurationScale: Equatable {
  let unit: SprintReportDurationUnit

  init(maximumDuration: TimeInterval) {
    if maximumDuration >= 7_200 {
      unit = .hours
    } else if maximumDuration >= 120 {
      unit = .minutes
    } else {
      unit = .seconds
    }
  }

  func plottedValue(_ duration: TimeInterval) -> Double {
    max(0, duration) / unit.seconds
  }

  func axisLabel(_ plottedValue: Double) -> String {
    let roundedValue = plottedValue.rounded()
    let value = if abs(plottedValue - roundedValue) < 0.01 {
      roundedValue.formatted(.number.precision(.fractionLength(0)))
    } else {
      plottedValue.formatted(.number.precision(.fractionLength(1)))
    }
    return value + unit.suffix
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

  private var startAvailability: SprintStartAvailability {
    var plans = model.sprintHistory
    if let current = model.sprintPlan,
      !plans.contains(where: { $0.sprint.id == current.sprint.id })
    {
      plans.append(current)
    }
    return SprintStartAvailability(draft: plan, plans: plans)
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
      } else if let activeSprintNumber = startAvailability.blockingActiveSprintNumber {
        VStack(alignment: .trailing, spacing: 3) {
          Text("Sprint \(activeSprintNumber) is in progress")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text("Finish it before starting this sprint.")
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
      .disabled(
        !planningIsComplete
          || !model.sprintReadinessIssues.isEmpty
          || startAvailability.isBlocked
      )
      .help(startAvailability.explanation ?? "Start the sprint")
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

struct SprintTicketRunTelemetryPresentation {
  let contextFraction: Double?
  let compactionCount: Int?
  let showsLiveActivity: Bool

  var contextPercentage: Int? {
    contextFraction.map { Int(($0 * 100).rounded()) }
  }

  var showsFooter: Bool {
    showsLiveActivity || contextFraction != nil
  }

  init(run: AgentRun?, hasLiveActivity: Bool) {
    if
      let used = run?.contextUsedTokens,
      let window = run?.contextWindowTokens,
      window > 0
    {
      contextFraction = min(1, max(0, Double(used) / Double(window)))
    } else {
      contextFraction = nil
    }
    if let compactions = run?.compactionCount, compactions > 0 {
      compactionCount = compactions
    } else {
      compactionCount = nil
    }
    showsLiveActivity = run?.status == .running && hasLiveActivity
  }
}

private enum AIActivityVisualStyle {
  static var tint: Color { .purple }
}

struct SprintTicketRunDetailsSelection {
  static func run(
    for itemState: WorkItemState,
    latestRun: AgentRun?,
    allRuns: [AgentRun]
  ) -> AgentRun? {
    guard
      itemState == .acceptance
        || itemState == .readyToRelease
        || itemState == .released
    else {
      return latestRun
    }

    return allRuns
      .filter(hasContextTelemetry)
      .max { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.updatedAt < rhs.updatedAt
      }
      ?? latestRun
  }

  private static func hasContextTelemetry(_ run: AgentRun) -> Bool {
    guard
      run.contextUsedTokens != nil,
      let window = run.contextWindowTokens
    else {
      return false
    }
    return window > 0
  }
}

private enum WorkItemCardLayout {
  static let edgePadding: CGFloat = 12
}

private struct SprintTicketRunSummary<Status: View>: View {
  let profile: AgentProfile?
  let detailsProfile: AgentProfile?
  let run: AgentRun?
  let liveActivity: CodexLiveActivity?
  let status: Status
  @State private var showsContextDetails = false

  private var telemetry: SprintTicketRunTelemetryPresentation {
    SprintTicketRunTelemetryPresentation(
      run: run,
      hasLiveActivity: liveActivity != nil
    )
  }

  init(
    profile: AgentProfile?,
    detailsProfile: AgentProfile?,
    run: AgentRun?,
    liveActivity: CodexLiveActivity?,
    @ViewBuilder status: () -> Status
  ) {
    self.profile = profile
    self.detailsProfile = detailsProfile
    self.run = run
    self.liveActivity = liveActivity
    self.status = status()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          status
          Spacer(minLength: 4)
          teamMemberLabel
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            status
            Spacer(minLength: 4)
          }
          teamMemberLabel
        }
      }

      if telemetry.showsFooter {
        Divider()
          .padding(.horizontal, -WorkItemCardLayout.edgePadding)
          .padding(.top, WorkItemCardLayout.edgePadding)

        HStack(alignment: .center, spacing: 8) {
          if telemetry.showsLiveActivity, let liveActivity {
            Image(systemName: liveActivity.kind.symbolName)
              .foregroundStyle(AIActivityVisualStyle.tint)
              .frame(width: 13)

            liveActivityText(liveActivity.text)
          } else if let contextPercentage = telemetry.contextPercentage {
            Image(systemName: "brain.head.profile")
              .foregroundStyle(AIActivityVisualStyle.tint)
              .frame(width: 13)

            Text("\(contextPercentage)% context used")
              .foregroundStyle(.primary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          if let contextFraction = telemetry.contextFraction {
            contextOccupancyIndicator(
              fraction: contextFraction,
              compactionCount: telemetry.compactionCount
            )
          }
        }
        .padding(.top, WorkItemCardLayout.edgePadding)
        .font(.caption.weight(.medium))
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func liveActivityText(_ text: String) -> some View {
    ViewThatFits(in: .horizontal) {
      Text(text)
        .lineLimit(1)
        .allowsTightening(true)
        .fixedSize(horizontal: true, vertical: false)

      Text(text)
        .lineLimit(2)
        .truncationMode(.tail)
        .allowsTightening(true)
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(.primary)
    .frame(
      maxWidth: .infinity,
      minHeight: 24,
      maxHeight: 24,
      alignment: .leading
    )
    .layoutPriority(1)
  }

  private func contextOccupancyIndicator(
    fraction: Double,
    compactionCount: Int?
  ) -> some View {
    let percentage = Int((fraction * 100).rounded())
    let compactionDescription = compactionCount.map {
      ", \($0) compaction\($0 == 1 ? "" : "s")"
    } ?? ""

    return ZStack {
      Circle()
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 2.5)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(
          AIActivityVisualStyle.tint,
          style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
    }
    .frame(width: 12, height: 12)
    .overlay {
      if let compactionCount {
        Text(compactionCount.formatted())
          .font(.system(size: 6, weight: .bold, design: .rounded))
          .foregroundStyle(AIActivityVisualStyle.tint)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .frame(width: 8)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Agent context")
    .accessibilityValue("\(percentage) percent used\(compactionDescription)")
    .onHover { hovering in
      showsContextDetails = hovering
    }
    .popover(isPresented: $showsContextDetails, arrowEdge: .bottom) {
      SprintRunDetailsPopover(
        profile: detailsProfile,
        run: run,
        liveActivity: liveActivity
      )
    }
  }

  private var teamMemberLabel: some View {
    Group {
      if let profile {
        Label(profile.name, systemImage: profile.role.symbolName)
          .foregroundStyle(profile.role.tint)
      } else {
        Label("Unassigned", systemImage: "person.crop.circle.badge.questionmark")
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption.weight(.semibold))
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }

}

private enum RunDurationFormatter {
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
    VStack(alignment: .leading, spacing: 8) {
      Text("Run details")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 3)
      detailLine("Team member", value: profile?.name ?? "Unavailable")
      if let run {
        detailLine("Status", value: run.status.displayTitle)
        switch run.status {
        case .running:
          if run.turnStartedAt != nil {
            detailLine(
              "Elapsed",
              value: RunDurationFormatter.duration(run.activeDuration(at: referenceDate))
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            detailLine("Last activity", value: Text(lastActivityAt, style: .relative))
          }
        case .queued:
          detailLine("Timing", value: "Starts when picked up")
          if run.activeDurationSeconds > 0 {
            detailLine(
              "Recorded active time",
              value: RunDurationFormatter.duration(run.activeDurationSeconds)
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            detailLine(
              "Previous activity",
              value: Text(
                lastActivityAt,
                format: .dateTime.day().month(.abbreviated).hour().minute()
              )
            )
          }
        case .awaitingOwner, .interrupted, .completed, .failed, .cancelled:
          if run.activeDurationSeconds > 0 {
            detailLine(
              "Active time",
              value: RunDurationFormatter.duration(run.activeDurationSeconds)
            )
          }
          if let lastActivityAt = run.lastActivityAt {
            detailLine(
              "Last activity",
              value: Text(
                lastActivityAt,
                format: .dateTime.day().month(.abbreviated).hour().minute()
              )
            )
          }
        }
        if
          run.status != .queued,
          let used = run.contextUsedTokens,
          let window = run.contextWindowTokens,
          window > 0
        {
          let percentage = Int(
            (Double(used) / Double(window) * 100).rounded()
          )
          detailLine(
            "Context used",
            value: "\(percentage)%"
          )
          detailLine(
            "Context tokens",
            value: "\(used.formatted()) / \(window.formatted()) tokens"
          )
        } else if run.status == .running {
          detailLine("Context used", value: "Not reported yet")
        }
        if run.status != .queued {
          detailLine("Compactions", value: run.compactionCount.formatted())
        }
      }
      if run?.status == .running, let liveActivity {
        Divider()
        Label(liveActivity.text, systemImage: liveActivity.kind.symbolName)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.callout)
    .padding(12)
    .frame(width: 270)
  }

  private func detailLine(_ label: String, value: String) -> some View {
    detailLine(label, value: Text(value))
  }

  private func detailLine(_ label: String, value: Text) -> some View {
    (
      Text("\(label): ")
        .foregroundColor(.secondary)
      + value
    )
    .fixedSize(horizontal: false, vertical: true)
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
  let planningIssue: String?

  private var activity: SprintCardActivity {
    if planningIssue != nil {
      return SprintCardActivity(
        title: "Needs planning",
        symbol: "exclamationmark.triangle.fill",
        tint: .orange
      )
    }
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
      case .queuedForReview:
        return SprintCardActivity(
          title: "Queued for review",
          symbol: "checkmark.shield",
          tint: .indigo
        )
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
      .help(planningIssue ?? activity.title)
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
    VStack(spacing: -4) {
      ForEach(0..<chevronCount, id: \.self) { _ in
        Image(systemName: symbolName)
      }
    }
    .font(.system(size: 7, weight: .semibold))
    .foregroundStyle(tint)
    .frame(width: 8)
    .fixedSize(horizontal: false, vertical: true)
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
      .padding(.horizontal, showsWorkflowActions ? 0 : 10)

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
    .padding(.vertical, 12)
    .padding(.horizontal, showsWorkflowActions ? 12 : 8)
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
  @Environment(\.colorScheme) private var colorScheme
  let item: WorkItem
  let showsWorkflowActions: Bool
  let onOpen: ((WorkItem) -> Void)?
  private let policy = WorkflowPolicy()
  @State private var isHovering = false

  private var sprintItem: SprintItem? {
    model.sprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var epicColor: Color? {
    guard let epicID = item.epicID else { return nil }
    return model.epics.first { $0.id == epicID }?.color.displayColor
  }

  private var itemRuns: [AgentRun] {
    model.runs.filter { $0.workItemID == item.id }
  }

  private var latestRun: AgentRun? {
    itemRuns
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

  private var detailsRun: AgentRun? {
    SprintTicketRunDetailsSelection.run(
      for: item.state,
      latestRun: latestRun,
      allRuns: itemRuns
    )
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

  private var detailsProfile: AgentProfile? {
    guard let detailsRun else { return assignedProfile }
    return model.profiles.first { $0.id == detailsRun.profileID }
  }

  private var planningIssue: String? {
    guard model.sprintPlan?.sprint.state == .draft, let sprintItem else {
      return nil
    }
    if let issue = model.sprintReadinessIssues.first(where: {
      $0.workItemID == item.id
    }) {
      return issue.message
    }
    if sprintItem.estimatedTokens <= 0 {
      return "\(item.key) still needs sprint planning."
    }
    return nil
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

  private var isInteractiveHover: Bool {
    onOpen != nil && isHovering
  }

  private var cardBackground: Color {
    return colorScheme == .dark
      ? Color.white.opacity(0.06)
      : Color(nsColor: .controlBackgroundColor)
  }

  private var cardShadow: Color {
    colorScheme == .dark
      ? Color.black.opacity(0.44)
      : Color.black.opacity(0.05)
  }

  private var cardShadowRadius: CGFloat {
    colorScheme == .dark ? 4 : 2
  }

  private var cardShadowOffset: CGFloat {
    colorScheme == .dark ? 2 : 1
  }

  var body: some View {
    let cardShape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        ticketIdentity
        Spacer(minLength: 0)
        if showsWorkflowActions {
          ticketStatus
        }
        SprintPriorityIndicator(priority: item.priority)
      }

      Text(item.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(3)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)

      if !showsWorkflowActions {
        SprintTicketRunSummary(
          profile: assignedProfile,
          detailsProfile: detailsProfile,
          run: detailsRun,
          liveActivity: detailsRun.flatMap {
            guard $0.status == .running else { return nil }
            return model.liveRunActivities[$0.id] ?? $0.persistedActivity
          }
        ) {
          ticketStatus
        }
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
    .padding(.vertical, WorkItemCardLayout.edgePadding)
    .padding(.horizontal, WorkItemCardLayout.edgePadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      cardShape
        .fill(cardBackground)
        .overlay {
          if isInteractiveHover {
            cardShape.fill(Color.accentColor.opacity(0.055))
          }
        }
    }
    .overlay {
      if !showsWorkflowActions {
        cardShape.strokeBorder(
          PlanningDropSurfaceStyle.tableBorder(for: colorScheme),
          lineWidth: 1
        )
      } else if colorScheme == .dark {
        cardShape.stroke(Color.white.opacity(0.1), lineWidth: 1)
      }
    }
    .overlay(alignment: .leading) {
      if let epicColor {
        Rectangle()
          .fill(epicColor)
          .frame(width: 4)
      }
    }
    .clipShape(cardShape)
    .shadow(
      color: showsWorkflowActions ? cardShadow : .clear,
      radius: showsWorkflowActions ? cardShadowRadius : 0,
      y: showsWorkflowActions ? cardShadowOffset : 0
    )
    .contentShape(cardShape)
    .onTapGesture {
      onOpen?(item)
    }
    .onHover { hovering in
      guard onOpen != nil else { return }
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = hovering
      }
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
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var ticketStatus: some View {
    SprintTicketStatusBadge(
      run: latestRun,
      itemState: item.state,
      candidateStatus: latestCandidate?.status,
      isDependencyBlocked: isDependencyBlocked,
      planningIssue: planningIssue
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

enum SprintTicketWorkLogHistory {
  private struct PendingQuestion {
    let displayedIndex: Int
    let question: TicketOwnerQuestion
  }

  static func displayedComments(
    from comments: [TicketComment],
    permissionRequests: [AgentPermissionRequest] = []
  ) -> [TicketComment] {
    var displayed: [TicketComment] = []
    var pendingQuestions: [PendingQuestion] = []

    for comment in comments {
      if isRepresentedByPermissionRequest(
        comment,
        permissionRequests: permissionRequests
      ) {
        continue
      }

      if
        comment.authorKind == .agent,
        let presentation = TicketOwnerQuestion.presentation(
          in: comment.body,
          structuredQuestion: comment.ownerQuestion
        )
      {
        displayed.append(comment)
        pendingQuestions.append(
          PendingQuestion(
            displayedIndex: displayed.count - 1,
            question: presentation.question
          )
        )
        continue
      }

      if comment.authorKind == .owner,
        let match = matchingAnswer(
          in: comment,
          pendingQuestions: pendingQuestions
        )
      {
        let pending = pendingQuestions.remove(at: match.pendingIndex)
        let questionComment = displayed[pending.displayedIndex]
        displayed[pending.displayedIndex] = TicketComment(
          id: questionComment.id,
          workItemID: questionComment.workItemID,
          authorKind: questionComment.authorKind,
          authorName: questionComment.authorName,
          body: questionComment.body,
          ownerQuestion: questionComment.ownerQuestion,
          answeredQuestions: [match.answer],
          createdAt: questionComment.createdAt
        )
        continue
      }

      displayed.append(comment)
    }

    return displayed
  }

  private static func isRepresentedByPermissionRequest(
    _ comment: TicketComment,
    permissionRequests: [AgentPermissionRequest]
  ) -> Bool {
    let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
    return permissionRequests
      .filter { $0.workItemID == comment.workItemID }
      .contains { request in
        switch comment.authorKind {
        case .owner:
          switch request.status {
          case .allowed:
            body == "Allowed once: \(request.detail)"
              || body == "Always allowed for this product: \(request.detail)"
          case .existingAccess:
            false
          case .policyDenied:
            false
          case .denied:
            body == "Denied: \(request.detail)"
          case .pending, .interrupted:
            false
          }
        case .system:
          body.hasPrefix("Permission requested: \(request.detail)")
            || body == "Automatically allowed by saved product access: \(request.detail)"
        case .agent:
          false
        }
      }
  }

  private static func matchingAnswer(
    in ownerComment: TicketComment,
    pendingQuestions: [PendingQuestion]
  ) -> (pendingIndex: Int, answer: TicketAnsweredQuestion)? {
    for answered in ownerComment.answeredQuestions {
      if let pendingIndex = pendingQuestions.lastIndex(where: {
        $0.question.prompt == answered.question.prompt
          && $0.question.options == answered.question.options
      }) {
        return (pendingIndex, answered)
      }
    }

    let body = ownerComment.body.trimmingCharacters(in: .whitespacesAndNewlines)
    for pendingIndex in pendingQuestions.indices.reversed() {
      let pending = pendingQuestions[pendingIndex]
      guard pending.question.options.contains(body) else { continue }
      return (
        pendingIndex,
        TicketAnsweredQuestion(
          question: TicketRefinementQuestion(
            prompt: pending.question.prompt,
            options: pending.question.options
          ),
          selectedOption: body,
          answer: body
        )
      )
    }
    return nil
  }
}

enum SprintTicketCommentRouting {
  static func activeQuestionRecipient(
    workItemID: UUID,
    assignedProfileID: UUID?,
    comments: [TicketComment],
    runs: [AgentRun],
    profiles: [AgentProfile]
  ) -> AgentProfile? {
    let activeStatuses: Set<AgentRunStatus> = [.queued, .running, .awaitingOwner]
    let activeRun = runs
      .filter {
        $0.workItemID == workItemID && activeStatuses.contains($0.status)
      }
      .max {
        let lhsDate = $0.lastActivityAt ?? $0.updatedAt
        let rhsDate = $1.lastActivityAt ?? $1.updatedAt
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return $0.id.uuidString < $1.id.uuidString
      }
    if
      let activeRun,
      let activeProfile = profiles.first(where: { $0.id == activeRun.profileID })
    {
      return activeProfile
    }
    return replyRecipient(
      workItemID: workItemID,
      assignedProfileID: assignedProfileID,
      comments: comments,
      runs: runs,
      profiles: profiles
    )
  }

  static func unansweredOwnerComment(
    workItemID: UUID,
    since date: Date,
    comments: [TicketComment]
  ) -> TicketComment? {
    let relevantComments = comments
      .filter { $0.workItemID == workItemID && $0.createdAt >= date }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    guard
      let ownerIndex = relevantComments.lastIndex(where: {
        $0.authorKind == .owner
      })
    else { return nil }
    guard
      !relevantComments.suffix(from: relevantComments.index(after: ownerIndex))
        .contains(where: { $0.authorKind == .agent })
    else { return nil }
    return relevantComments[ownerIndex]
  }

  static func replyRecipient(
    workItemID: UUID,
    assignedProfileID: UUID?,
    comments: [TicketComment],
    runs: [AgentRun],
    profiles: [AgentProfile]
  ) -> AgentProfile? {
    if let assignedProfileID,
      let assigned = profiles.first(where: { $0.id == assignedProfileID })
    {
      return assigned
    }

    var latestParticipant: (profile: AgentProfile, date: Date)?
    for comment in comments
    where comment.workItemID == workItemID && comment.authorKind == .agent
    {
      guard let profile = profiles.first(where: { $0.name == comment.authorName }) else {
        continue
      }
      if latestParticipant.map({ comment.createdAt > $0.date }) ?? true {
        latestParticipant = (profile, comment.createdAt)
      }
    }
    for run in runs where run.workItemID == workItemID {
      guard let profile = profiles.first(where: { $0.id == run.profileID }) else {
        continue
      }
      let interactionDate = run.lastActivityAt ?? run.updatedAt
      if latestParticipant.map({ interactionDate > $0.date }) ?? true {
        latestParticipant = (profile, interactionDate)
      }
    }
    if let latestParticipant {
      return latestParticipant.profile
    }
    return profiles.first { $0.role == .lead }
  }
}

enum SprintTicketWorkLogAttention {
  static func requiresProductOwnerInput(
    hasPendingPermissionRequest: Bool,
    hasActiveOwnerQuestion: Bool,
    knowledgeProposalStatuses: [KnowledgePageProposalStatus],
    requiresKnowledgeApproval: Bool,
    ticketState: WorkItemState
  ) -> Bool {
    hasPendingPermissionRequest
      || hasActiveOwnerQuestion
      || (
        requiresKnowledgeApproval
          && knowledgeProposalStatuses.contains(.reviewed)
      )
      || ticketState == .acceptance
  }
}

private struct SprintTicketDetailView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceContainerSize) private var containerSize
  let item: WorkItem
  @State private var comments: [TicketComment] = []
  @State private var activityEvents: [ActivityEvent] = []
  @State private var isPostingComment = false
  @State private var isAskingQuestion = false
  @State private var isResumingWork = false
  @State private var isAcceptingTicket = false
  @State private var isDemoActionRunning = false
  @State private var decidingPermissionRequestID: UUID?
  @State private var decidingKnowledgeProposalIDs: Set<UUID> = []
  @State private var commentError: String?
  @State private var workLogScrollRequest = 0
  @State private var hasLoadedWorkLog = false
  @State private var hoveredContextPageID: UUID?
  @State private var ownerAnswerSelection: TicketOwnerAnswerSelection?
  @State private var customOwnerAnswerDraft = ""
  @State private var commentComposerFocusResetRequest = 0
  @State private var selectedRelationshipTicket: WorkItem?

  private var currentItem: WorkItem {
    model.workItems.first { $0.id == item.id } ?? item
  }

  private var currentSprintItem: SprintItem? {
    model.sprintPlan?.items.first { $0.workItemID == item.id }
  }

  private var owner: AgentProfile? {
    let sprintOwnerID = currentSprintItem?.implementerProfileID
    guard let ownerID = sprintOwnerID ?? currentItem.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  private var commentReplyRecipient: AgentProfile? {
    SprintTicketCommentRouting.replyRecipient(
      workItemID: item.id,
      assignedProfileID: currentSprintItem?.implementerProfileID ?? currentItem.ownerProfileID,
      comments: comments,
      runs: model.runs,
      profiles: model.profiles
    )
  }

  private var questionRecipient: AgentProfile? {
    SprintTicketCommentRouting.activeQuestionRecipient(
      workItemID: item.id,
      assignedProfileID: currentSprintItem?.implementerProfileID ?? currentItem.ownerProfileID,
      comments: comments,
      runs: model.runs,
      profiles: model.profiles
    )
  }

  private var prerequisites: [WorkItem] {
    let ids = Set(
      model.dependencies
        .filter { $0.workItemID == item.id }
        .map(\.dependsOnWorkItemID)
    )
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var activePrerequisites: [WorkItem] {
    prerequisites.filter { $0.state != .released }
  }

  private var dependants: [WorkItem] {
    let ids = Set(
      model.dependencies
        .filter { $0.dependsOnWorkItemID == item.id }
        .map(\.workItemID)
    )
    return model.workItems.filter { ids.contains($0.id) }
  }

  private var ticketCandidates: [CandidateRevision] {
    model.candidateRevisions
      .filter { $0.workItemID == item.id }
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.version < $1.version
        }
        return $0.createdAt < $1.createdAt
      }
  }

  private var currentCandidate: CandidateRevision? {
    ticketCandidates.max(by: { $0.version < $1.version })
  }

  private var ticketPermissionRequests: [AgentPermissionRequest] {
    model.permissionRequests
      .filter { $0.workItemID == item.id }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var ticketRunContexts: [SprintTicketRunContextLogItem] {
    let pageIDsByRun = Dictionary(
      grouping: model.agentRunKnowledgeContext,
      by: \.runID
    )
    let implementationRunIDs = Set(ticketCandidates.map(\.implementationRunID))
    return model.runs
      .filter { $0.workItemID == item.id }
      .compactMap { run in
        let profile = model.profiles.first { $0.id == run.profileID }
        let isActiveDeliveryRun =
          currentItem.state == .running
          && currentSprintItem?.implementerProfileID == run.profileID
        guard SprintTicketRunContextVisibility.includes(
          profile: profile,
          isDeliveryRun: implementationRunIDs.contains(run.id) || isActiveDeliveryRun
        ) else {
          return nil
        }
        let pageIDs = Set((pageIDsByRun[run.id] ?? []).map(\.pageID))
        guard !pageIDs.isEmpty else { return nil }
        let pages = model.knowledgePages
          .filter { pageIDs.contains($0.id) }
          .sorted { $0.title < $1.title }
        guard !pages.isEmpty else { return nil }
        return SprintTicketRunContextLogItem(run: run, pages: pages)
      }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private var ticketKnowledgeBatches: [SprintTicketKnowledgeLogItem] {
    let proposalsByCandidate = Dictionary(
      grouping: model.knowledgePageProposals.filter {
        $0.workItemID == item.id
      },
      by: \.candidateRevisionID
    )
    return ticketCandidates.compactMap { candidate in
      guard let proposals = proposalsByCandidate[candidate.id], !proposals.isEmpty else {
        return nil
      }
      return SprintTicketKnowledgeLogItem(
        candidate: candidate,
        proposals: proposals.sorted { $0.createdAt < $1.createdAt }
      )
    }
  }

  private var ticketDemoSubmissions: [SprintTicketDemoLogItem] {
    SprintTicketWorkLogTimeline.demoSubmissions(
      events: activityEvents,
      candidates: ticketCandidates
    )
  }

  private var ticketFollowUps: [SprintTicketFollowUpLogItem] {
    ticketCandidates.compactMap { candidate in
      guard
        let result = executionResult(for: candidate),
        !result.followUpTicketProposals.isEmpty
      else { return nil }
      return SprintTicketFollowUpLogItem(candidate: candidate)
    }
  }

  private var pendingPermissionRequest: AgentPermissionRequest? {
    model.pendingPermissionRequest(workItemID: item.id)
  }

  private var unansweredPermissionComment: TicketComment? {
    guard let pendingPermissionRequest else { return nil }
    return SprintTicketCommentRouting.unansweredOwnerComment(
      workItemID: item.id,
      since: pendingPermissionRequest.createdAt,
      comments: comments
    )
  }

  private var activeTicketConversationProfile: AgentProfile? {
    guard
      model.ticketConversationWorkItemID == item.id,
      let recipientID = model.ticketConversationRecipientID
    else { return nil }
    return model.profiles.first { $0.id == recipientID }
  }

  private func trunkPromotionValue(for candidate: CandidateRevision) -> String {
    switch candidate.status {
    case .accepted:
      return "Promoted after approval"
    case .readyForDemo:
      return "Awaiting your approval"
    default:
      return "Not promoted"
    }
  }

  private func trunkPromotionSymbol(for candidate: CandidateRevision) -> String {
    candidate.status == .accepted
      ? "checkmark.circle.fill"
      : "arrow.triangle.branch"
  }

  private func trunkPromotionTint(for candidate: CandidateRevision) -> Color {
    switch candidate.status {
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

  private var hasPendingWorkLogAction: Bool {
    SprintTicketWorkLogAttention.requiresProductOwnerInput(
      hasPendingPermissionRequest: pendingPermissionRequest != nil,
      hasActiveOwnerQuestion: activeOwnerQuestionComment != nil,
      knowledgeProposalStatuses: currentKnowledgeProposals.map(\.status),
      requiresKnowledgeApproval: model.requiresKnowledgeApproval,
      ticketState: currentItem.state
    )
  }

  private var detailWidth: CGFloat {
    min(900, max(700, containerSize.width - 140))
  }

  private var detailHeight: CGFloat {
    min(780, max(600, containerSize.height - 110))
  }

  private func latestActivityButton(hasEntries: Bool) -> some View {
    Button {
      workLogScrollRequest += 1
    } label: {
      Label("Latest activity", systemImage: "arrow.down.to.line")
    }
    .disabled(!hasEntries)
    .help("Jump to the latest Work log entry")
  }

  private var boardStatusTitle: String {
    if model.sprintPlan?.sprint.state == .draft, let currentSprintItem {
      if currentSprintItem.estimatedTokens <= 0
        || model.sprintReadinessIssues.contains(where: { $0.workItemID == item.id })
      {
        return "Needs planning"
      }
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
    case "Needs planning": "exclamationmark.triangle.fill"
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
    case "Needs planning": .orange
    case "Ready to Pick": Color(nsColor: .secondaryLabelColor)
    case "In Progress": .blue
    case "In Review": .purple
    case "Ready for Demo": .orange
    case "Done": .green
    default: currentItem.state.activityTint
    }
  }

  private var ownerAnswer: String? {
    switch ownerAnswerSelection {
    case .option(let option):
      return option
    case .custom:
      let answer = customOwnerAnswerDraft
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return answer.isEmpty ? nil : answer
    case nil:
      return nil
    }
  }

  private var canRetryFailedPostReviewDemo: Bool {
    model.canRetryFailedPostReviewDemo(workItemID: item.id)
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

  private var activeOwnerQuestionComment: TicketComment? {
    guard awaitingOwnerRun != nil, !canRetryFailedPostReviewDemo else { return nil }
    let agentComments = comments.filter { $0.authorKind == .agent }
    if let structuredComment = agentComments.last(where: { $0.ownerQuestion != nil }) {
      return structuredComment
    }
    guard
      let latestAgentComment = agentComments.last,
      TicketOwnerQuestion.presentation(
        in: latestAgentComment.body,
        structuredQuestion: nil
      ) != nil
    else { return nil }
    return latestAgentComment
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

  private func executionResult(
    for candidate: CandidateRevision
  ) -> TicketExecutionResult? {
    try? CodexTicketExecutor.decode(candidate.executionResultJSON)
  }

  private var workLogEntries: [SprintWorkLogEntry] {
    let demoSubmissions = ticketDemoSubmissions
    let commentEntries = SprintTicketWorkLogHistory.displayedComments(
      from: comments,
      permissionRequests: ticketPermissionRequests
    )
      .filter(isVisibleWorkLogComment)
      .map(SprintWorkLogEntry.comment)
    let eventEntries = SprintTicketWorkLogTimeline.displayedEvents(
      events: activityEvents,
      comments: comments,
      permissionRequests: ticketPermissionRequests,
      demoSubmissions: demoSubmissions
    )
      .map(SprintWorkLogEntry.event)
    let artifactEntries =
      ticketPermissionRequests.map(SprintWorkLogEntry.permission)
      + ticketRunContexts.map(SprintWorkLogEntry.runContext)
      + ticketCandidates.map(SprintWorkLogEntry.candidate)
      + ticketKnowledgeBatches.map(SprintWorkLogEntry.knowledge)
      + demoSubmissions.map(SprintWorkLogEntry.demo)
      + ticketFollowUps.map(SprintWorkLogEntry.followUp)
    return SprintTicketWorkLogTimeline.ordered(
      commentEntries + eventEntries + artifactEntries
    )
  }

  private func isVisibleWorkLogComment(_ comment: TicketComment) -> Bool {
    let boilerplate = [
      "I’m starting work on this ticket. I’ll record material progress and any decision I need from you here.",
      "I’m continuing with the latest feedback.",
      "I’m reviewing the implementation and its evidence against the ticket.",
    ]
    return !boilerplate.contains(comment.body)
  }

  private var overviewRelationships: [TicketDetailRelationshipGroup] {
    var groups: [TicketDetailRelationshipGroup] = []
    if !activePrerequisites.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocked-by",
          title: "Blocked by",
          symbol: "arrow.turn.up.left",
          items: activePrerequisites.map(TicketDetailRelationshipItem.init(workItem:))
        )
      )
    }
    if !dependants.isEmpty {
      groups.append(
        TicketDetailRelationshipGroup(
          id: "blocks",
          title: "Blocks",
          symbol: "link",
          items: dependants.map(TicketDetailRelationshipItem.init(workItem:))
        )
      )
    }
    return groups
  }

  private func profile(for candidate: CandidateRevision) -> AgentProfile? {
    guard
      let run = model.runs.first(where: {
        $0.id == candidate.implementationRunID
      })
    else { return nil }
    return model.profiles.first { $0.id == run.profileID }
  }

  private func workLogArtifactRow<Content: View>(
    actorName: String,
    profile: AgentProfile?,
    createdAt: Date,
    showsBottomSeparator: Bool,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let tint = profile?.role.tint ?? Color.secondary
    let symbol = profile?.role.symbolName ?? "gearshape.fill"
    return HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(tint.opacity(0.12))
        Image(systemName: symbol)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text(actorName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(profile == nil ? Color.primary : tint)
          Text(
            createdAt,
            format: .dateTime.day().month(.abbreviated).hour().minute()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.top, 14)
    .padding(.bottom, showsBottomSeparator ? 14 : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      if showsBottomSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor).opacity(0.55))
          .frame(height: 1)
          .padding(.leading, 46)
      }
    }
  }

  private func workLogPanel<Content: View>(
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .padding(14)
      .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .stroke(tint.opacity(0.3), lineWidth: 1)
      }
  }

  private func contextSection(
    _ context: SprintTicketRunContextLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    let profile = model.profiles.first { $0.id == context.run.profileID }
    return workLogArtifactRow(
      actorName: profile?.name ?? "Spedito",
      profile: profile,
      createdAt: context.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      workLogPanel(tint: .indigo) {
        SprintTicketSectionCard(title: "Knowledge used") {
          VStack(alignment: .leading, spacing: 10) {
            Label(
              "\(context.pages.count) knowledge page\(context.pages.count == 1 ? "" : "s")",
              systemImage: "books.vertical"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if !context.mandatoryPages.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Always included")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.secondary)
                IntrinsicWrappingLayout(spacing: 6) {
                  ForEach(context.mandatoryPages) { page in
                    contextPageRow(page)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }

            if !context.relevantPages.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Relevant to this ticket")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.secondary)
                IntrinsicWrappingLayout(spacing: 6) {
                  ForEach(context.relevantPages) { page in
                    contextPageRow(page)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      }
    }
  }

  private func contextPageRow(_ page: KnowledgePage) -> some View {
    let isHovered = hoveredContextPageID == page.id
    return Button {
      model.requestKnowledgeFocus(pageID: page.id)
      dismiss()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "doc.text")
          .font(.caption2)
          .foregroundStyle(.indigo)
        Text(page.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(isHovered ? Color.indigo : Color.secondary)
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .fixedSize(horizontal: true, vertical: false)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovered
        ? Color.indigo.opacity(0.12)
        : Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(
          isHovered
            ? Color.indigo.opacity(0.55)
            : Color(nsColor: .separatorColor).opacity(0.45),
          lineWidth: 1
        )
    }
    .onHover { hovering in
      if hovering {
        hoveredContextPageID = page.id
      } else if hoveredContextPageID == page.id {
        hoveredContextPageID = nil
      }
    }
    .help("Open \(page.title) in Product knowledge")
  }

  private func deliveryRevisionSection(
    _ candidate: CandidateRevision,
    showsBottomSeparator: Bool
  ) -> some View {
    let candidateProfile = profile(for: candidate)
    return workLogArtifactRow(
      actorName: candidateProfile?.name ?? "Spedito",
      profile: candidateProfile,
      createdAt: candidate.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      workLogPanel(tint: .purple) {
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
              value: trunkPromotionValue(for: candidate),
              symbol: trunkPromotionSymbol(for: candidate),
              tint: trunkPromotionTint(for: candidate)
            )
            if candidate.id == currentCandidate?.id {
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
          }
          if candidate.status != .accepted {
            Text(deliveryRevisionExplanation(candidate.status))
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          .textSelection(.enabled)
        }
      }
    }
  }

  private func deliveryRevisionExplanation(
    _ status: CandidateRevisionStatus
  ) -> String {
    switch status {
    case .changesRequested, .superseded, .failed:
      "This candidate was not promoted to local trunk."
    default:
      "The ticket branch remains isolated from trunk until the reviewed demo is approved."
    }
  }

  private func permissionRequestSection(
    _ request: AgentPermissionRequest,
    showsBottomSeparator: Bool
  ) -> some View {
    let run = model.runs.first { $0.id == request.agentRunID }
    let requestProfile = run.flatMap { run in
      model.profiles.first { $0.id == run.profileID }
    }
    let isActionable = pendingPermissionRequest?.id == request.id
    let presentation = SprintPermissionRequestPresentation(request: request)
    let isSpeditoDecision = request.status == .existingAccess
      || request.status == .policyDenied
    return workLogArtifactRow(
      actorName: isSpeditoDecision
        ? "Spedito"
        : requestProfile?.name ?? "Spedito",
      profile: isSpeditoDecision ? nil : requestProfile,
      createdAt: request.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      if request.status == .existingAccess {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.open.fill")
              .font(.title3)
              .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
              Text(SprintPermissionRequestPresentation.existingAccessTitle)
                .font(.headline)
              Text(SprintPermissionRequestPresentation.existingAccessSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          WorkLogDisclosure(
            collapsedTitle: "Requested access",
            tint: .green,
            labelFont: .caption.weight(.semibold)
          ) {
            Text(request.detail)
              .font(.callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
          RoundedRectangle(cornerRadius: 13)
            .stroke(Color.green.opacity(0.3), lineWidth: 1)
        }
      } else if request.status == .policyDenied {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.shield.fill")
              .font(.title3)
              .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
              Text(SprintPermissionRequestPresentation.protectedStorageTitle)
                .font(.headline)
              Text(SprintPermissionRequestPresentation.protectedStorageSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          if let reason = request.reason {
            TicketMarkdownDocument(source: reason, baseFont: .callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          WorkLogDisclosure(
            collapsedTitle: "Requested access",
            tint: .orange,
            labelFont: .caption.weight(.semibold)
          ) {
            Text(request.detail)
              .font(.callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
          RoundedRectangle(cornerRadius: 13)
            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
      } else {
        VStack(alignment: .leading, spacing: 13) {
          HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.shield.fill")
              .font(.title3)
              .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
              Text(request.title)
                .font(.headline)
              Text(presentation.context)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(
              permissionStatusTitle(
                request.status,
                isActionable: isActionable
              )
            )
              .font(.caption.weight(.semibold))
              .foregroundStyle(
                permissionStatusTint(
                  request.status,
                  isActionable: isActionable
                )
              )
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(
                permissionStatusTint(
                  request.status,
                  isActionable: isActionable
                ).opacity(0.1),
                in: Capsule()
              )
          }

          VStack(alignment: .leading, spacing: 5) {
            Text("Why this is needed")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            TicketMarkdownDocument(source: presentation.purpose, baseFont: .body)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .textSelection(.enabled)

          WorkLogDisclosure(
            collapsedTitle: presentation.detailTitle,
            tint: .orange,
            labelFont: .caption.weight(.semibold)
          ) {
            Text(request.detail)
              .font(
                request.kind == .command
                  ? .system(.callout, design: .monospaced)
                  : .callout
              )
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .fixedSize(horizontal: false, vertical: true)

          if isActionable {
            HStack {
              Spacer()
              Button("Deny") {
                decidePermissionRequest(request, allow: false)
              }
              .buttonStyle(.bordered)
              .disabled(decidingPermissionRequestID != nil)

              Button("Allow once") {
                decidePermissionRequest(request, allow: true)
              }
              .buttonStyle(.bordered)
              .disabled(decidingPermissionRequestID != nil)

              if request.productGrantSignature != nil {
                Button("Always allow") {
                  decidePermissionRequest(
                    request,
                    allow: true,
                    rememberForProduct: true
                  )
                }
                .buttonStyle(.borderedProminent)
                .disabled(decidingPermissionRequestID != nil)
              }
            }
          }

          if let explanation = permissionExplanation(request) {
            Text(explanation)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(17)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
          RoundedRectangle(cornerRadius: 13)
            .stroke(Color.orange.opacity(0.38), lineWidth: 1.2)
        }
      }
    }
  }

  private func permissionStatusTitle(
    _ status: AgentPermissionRequestStatus,
    isActionable: Bool
  ) -> String {
    switch status {
    case .pending: "Needs your input"
    case .allowed: "Allowed"
    case .existingAccess: "Existing access"
    case .policyDenied: "Protected"
    case .denied: "Denied"
    case .interrupted: isActionable ? "Needs your input" : "Interrupted"
    }
  }

  private func permissionStatusTint(
    _ status: AgentPermissionRequestStatus,
    isActionable: Bool
  ) -> Color {
    switch status {
    case .pending: .orange
    case .allowed: .green
    case .existingAccess: .green
    case .policyDenied: .orange
    case .denied: .secondary
    case .interrupted: isActionable ? .orange : .secondary
    }
  }

  private func permissionExplanation(_ request: AgentPermissionRequest) -> String? {
    switch request.status {
    case .pending:
      if request.kind == .fileChange {
        "Allow once grants this file change for the current run. Deny returns control to the agent so it can adapt."
      } else {
        nil
      }
    case .allowed, .existingAccess, .policyDenied, .denied, .interrupted:
      nil
    }
  }

  private func demoSection(
    _ demo: SprintTicketDemoLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    let candidate = demo.candidate
    let result = executionResult(for: candidate)
    let specification = result?.demo
    let session = model.currentDemoSession(for: candidate.id)
    let eventProfile = model.profiles.first { $0.name == demo.event.actor }
    let canOpenDemo =
      candidate.id == currentCandidate?.id
      && candidate.status == .readyForDemo
      && currentItem.state == .acceptance
    return workLogArtifactRow(
      actorName: eventProfile?.name ?? demo.event.actor,
      profile: eventProfile,
      createdAt: demo.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          Image(systemName: "play.rectangle.fill")
            .font(.title3)
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(specification?.title ?? "Demo")
              .font(.headline)
            Text(specification?.presentation.kind.title ?? "Demo setup unavailable")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if canOpenDemo,
            session?.status == .ready,
            specification?.presentation.kind == .browser
              || specification?.presentation.kind == .macApplication
          {
            Button("Stop demo") {
              stopDemo(candidate)
            }
            .buttonStyle(.bordered)
            .disabled(isDemoActionRunning)
          }
          if canOpenDemo {
            Button(demoButtonTitle(specification: specification, session: session)) {
              launchDemo(candidate)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDemoActionRunning || specification == nil)
          } else {
            Text(demoStatusTitle(candidate.status))
              .font(.caption.weight(.semibold))
              .foregroundStyle(demoStatusTint(candidate.status))
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(demoStatusTint(candidate.status).opacity(0.1), in: Capsule())
          }
        }

        Text(
          demoExplanation(
            candidate: candidate,
            specification: specification,
            session: session,
            canOpenDemo: canOpenDemo
          )
        )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let instructions = result?.reviewInstructions,
          !instructions.isEmpty
        {
          VStack(alignment: .leading, spacing: 7) {
            Text("Things to try")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(instructions, id: \.self) { instruction in
              HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle")
                  .font(.caption)
                  .foregroundStyle(.orange)
                  .padding(.top, 1)
                Text(instruction)
                  .font(.callout)
              }
            }
          }
        }

        if let output = session?.output, !output.isEmpty {
          VStack(alignment: .leading, spacing: 7) {
            Text("Demo result")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ScrollView {
              Text(output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 180)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
          }
        }

        if let error = session?.errorMessage, !error.isEmpty {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(17)
      .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
      .overlay {
        RoundedRectangle(cornerRadius: 13)
          .stroke(Color.orange.opacity(0.38), lineWidth: 1.2)
      }
    }
  }

  private func demoButtonTitle(
    specification: DemoLaunchSpecification?,
    session: DemoSession?
  ) -> String {
    if isDemoActionRunning {
      return session?.status == .starting ? "Starting…" : "Preparing…"
    }
    switch session?.status {
    case .ready:
      return specification?.presentation.kind == .commandOutput
        ? "Run demo again"
        : "Open demo"
    case .failed:
      return "Retry demo"
    default:
      return "Demo"
    }
  }

  private func demoStatusTitle(_ status: CandidateRevisionStatus) -> String {
    switch status {
    case .accepted: "Approved"
    case .readyForDemo: "Ready"
    case .changesRequested: "Changes requested"
    case .superseded: "Superseded"
    case .failed: "Stopped"
    default: "Historical"
    }
  }

  private func demoStatusTint(_ status: CandidateRevisionStatus) -> Color {
    switch status {
    case .accepted: .green
    case .readyForDemo: .orange
    case .changesRequested, .failed: .red
    default: .secondary
    }
  }

  private func demoExplanation(
    candidate: CandidateRevision,
    specification: DemoLaunchSpecification?,
    session: DemoSession?,
    canOpenDemo: Bool
  ) -> String {
    guard let specification else {
      return "This candidate predates managed demos. Request changes so the assigned team member can add a one-click demo."
    }
    guard canOpenDemo else {
      return candidate.status == .accepted
        ? "The Product Owner approved this reviewed demo and promoted its integrated revision."
        : "This earlier demo submission remains in the Work log as delivery history."
    }
    switch session?.status {
    case .preparing:
      return "Spedito is preparing the exact reviewed revision."
    case .starting:
      return "Spedito is starting the demo and waiting until it is ready."
    case .ready:
      switch specification.presentation.kind {
      case .browser:
        return "The local web demo is running. Open demo reuses it without starting a duplicate."
      case .macApplication:
        return "The reviewed macOS app is running in its managed demo session."
      case .artifact:
        return "The reviewed artifact has been opened."
      case .commandOutput:
        return "The reviewed scenario completed and its result is shown below."
      }
    case .failed:
      return "The demo could not open. Retry it or describe what happened and request changes."
    case .stopped:
      return "The reviewed demo is ready. Spedito will manage its setup and cleanup."
    case nil:
      return "Spedito will open the exact reviewed result and manage any local processes it needs."
    }
  }

  private func launchDemo(_ candidate: CandidateRevision) {
    guard !isDemoActionRunning else { return }
    isDemoActionRunning = true
    Task {
      _ = await model.launchDemo(for: candidate)
      isDemoActionRunning = false
    }
  }

  private func stopDemo(_ candidate: CandidateRevision) {
    guard !isDemoActionRunning else { return }
    isDemoActionRunning = true
    Task {
      await model.stopDemo(for: candidate)
      isDemoActionRunning = false
    }
  }

  private func decidePermissionRequest(
    _ request: AgentPermissionRequest,
    allow: Bool,
    rememberForProduct: Bool = false
  ) {
    guard decidingPermissionRequestID == nil else { return }
    decidingPermissionRequestID = request.id
    Task {
      await model.decidePermissionRequest(
        request,
        allow: allow,
        rememberForProduct: rememberForProduct
      )
      decidingPermissionRequestID = nil
    }
  }

  @ViewBuilder
  private func followUpTicketProposalsSection(
    _ followUp: SprintTicketFollowUpLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    if let result = executionResult(for: followUp.candidate),
      !result.followUpTicketProposals.isEmpty
    {
      let followUpProfile = profile(for: followUp.candidate)
      workLogArtifactRow(
        actorName: followUpProfile?.name ?? "Spedito",
        profile: followUpProfile,
        createdAt: followUp.createdAt,
        showsBottomSeparator: showsBottomSeparator
      ) {
        VStack(alignment: .leading, spacing: 12) {
          Label("Recommended follow-up work", systemImage: "arrow.triangle.branch")
            .font(.headline)
            .foregroundStyle(.purple)

          Text(followUpExplanation(followUp.candidate.status))
            .font(.callout)
            .foregroundStyle(.secondary)

          ForEach(result.followUpTicketProposals, id: \.reference) { proposal in
            HStack(alignment: .top, spacing: 10) {
              Text(proposal.reference)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.purple)
                .frame(width: 28, alignment: .leading)
              VStack(alignment: .leading, spacing: 4) {
                Text(proposal.title)
                  .font(.subheadline.weight(.semibold))
                Text(proposal.rationale)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer()
              Label(
                proposal.suggestedRole.title,
                systemImage: proposal.suggestedRole.symbolName
              )
              .font(.caption.weight(.medium))
              .foregroundStyle(proposal.suggestedRole.tint)
            }
            .padding(11)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
          }
        }
        .padding(17)
        .background(Color.purple.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
          RoundedRectangle(cornerRadius: 13)
            .stroke(Color.purple.opacity(0.34), lineWidth: 1.2)
        }
      }
    }
  }

  private func followUpExplanation(
    _ status: CandidateRevisionStatus
  ) -> String {
    switch status {
    case .accepted:
      "These recommendations were published to the Backlog for individual review."
    case .readyForDemo:
      "Approving this research outcome will publish these as reviewable Backlog proposals. Nothing enters the Backlog until you accept each proposal."
    case .queuedForReview, .reviewing:
      "These recommendations are part of this candidate and remain subject to Tech Lead review."
    case .queuedForIntegration, .integrating, .resolvingConflict:
      "The Tech Lead approved these recommendations. They are waiting to join the integrated demo candidate."
    case .changesRequested, .superseded, .failed:
      "These recommendations belonged to an earlier candidate and were not published."
    }
  }

  private func knowledgeProposalsSection(
    _ knowledge: SprintTicketKnowledgeLogItem,
    showsBottomSeparator: Bool
  ) -> some View {
    let knowledgeProfile = profile(for: knowledge.candidate)
    return workLogArtifactRow(
      actorName: knowledgeProfile?.name ?? "Spedito",
      profile: knowledgeProfile,
      createdAt: knowledge.createdAt,
      showsBottomSeparator: showsBottomSeparator
    ) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 9) {
          Label("Knowledge changes", systemImage: "books.vertical.fill")
            .font(.headline)
            .foregroundStyle(.indigo)
          Spacer()
          Text(knowledgeProposalStatusTitle(knowledge.proposals))
            .font(.caption.weight(.semibold))
            .foregroundStyle(knowledgeProposalStatusTint(knowledge.proposals))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              knowledgeProposalStatusTint(knowledge.proposals).opacity(0.1),
              in: Capsule()
            )
        }

        Text(knowledgeProposalExplanation(knowledge.proposals))
          .font(.callout)
          .foregroundStyle(.secondary)

        ForEach(knowledge.proposals) { proposal in
          let knowledgePage = publishedKnowledgePage(for: proposal)
          CanonicalKnowledgeProposalCard(
            proposal: proposal,
            currentPage: knowledgePage,
            requiresOwnerApproval: model.requiresKnowledgeApproval,
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

  private func knowledgeProposalStatusTitle(
    _ proposals: [KnowledgePageProposal]
  ) -> String {
    if proposals.contains(where: { $0.status == .proposed }) {
      return "Reviewing"
    }
    if proposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval ? "Your approval required" : "Ready to publish"
    }
    if proposals.allSatisfy({ $0.status == .accepted }) {
      return "Published"
    }
    return "Review recorded"
  }

  private func knowledgeProposalStatusTint(
    _ proposals: [KnowledgePageProposal]
  ) -> Color {
    if proposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval ? .orange : .indigo
    }
    if proposals.allSatisfy({ $0.status == .accepted }) {
      return .green
    }
    return .indigo
  }

  private func knowledgeProposalExplanation(
    _ proposals: [KnowledgePageProposal]
  ) -> String {
    if proposals.contains(where: { $0.status == .proposed }) {
      return "These durable wiki changes travel with the delivery and are currently being checked by the Tech Lead."
    }
    if proposals.contains(where: { $0.status == .reviewed }) {
      return model.requiresKnowledgeApproval
        ? "The Tech Lead reviewed these durable wiki changes. Accept or reject each change before completing the ticket."
        : "The Tech Lead reviewed these Product knowledge changes. They’ll be published automatically when you approve this ticket."
    }
    if proposals.allSatisfy({ $0.status == .accepted }) {
      return "Published after Tech Lead review. Open a page below to read the canonical result in the Knowledge Base."
    }
    return "These proposed changes remain visible as part of the ticket’s delivery history."
  }

  var body: some View {
    let workLogRows = SprintTicketWorkLogTimeline.rows(workLogEntries)

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
        if hasPendingWorkLogAction {
          latestActivityButton(hasEntries: !workLogRows.isEmpty)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        } else {
          latestActivityButton(hasEntries: !workLogRows.isEmpty)
            .buttonStyle(.bordered)
        }
        Button("Close") { dismiss() }
      }
      .padding(.horizontal, 22)
      .frame(height: 64)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            TicketDetailOverview(
              title: currentItem.title,
              context: currentItem.body,
              emptyContextText: "No additional context was recorded.",
              metadata: [
                TicketDetailMetadataValue(
                  id: "status",
                  title: "Status",
                  value: boardStatusTitle,
                  symbol: boardStatusSymbol,
                  tint: boardStatusTint
                ),
                TicketDetailMetadataValue(
                  id: "owner",
                  title: "Owner",
                  value: owner?.name ?? "Unassigned",
                  symbol: owner?.role.symbolName ?? "person.crop.circle.badge.questionmark",
                  tint: owner?.role.tint ?? Color.secondary
                ),
                TicketDetailMetadataValue(
                  id: "type",
                  title: "Type",
                  value: currentItem.type.title,
                  symbol: currentItem.type.symbolName,
                  tint: currentItem.type.tint
                ),
                TicketDetailMetadataValue(
                  id: "priority",
                  title: "Priority",
                  value: currentItem.priority.title,
                  symbol: "flag.fill",
                  tint: currentItem.priority.tint
                ),
              ],
              epic: TicketEpicNavigation.destination(
                for: currentItem,
                in: model.epics
              ),
              acceptanceCriteria: currentItem.acceptanceCriteria,
              emptyAcceptanceCriteriaText: "No acceptance criteria",
              relationships: overviewRelationships,
              onOpenRelationship: openRelationship
            )

            Divider()

            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Work log")
                  .font(.headline)
                Text(workLogRows.count.formatted())
                  .font(.caption.monospacedDigit())
                  .padding(.horizontal, 7)
                  .padding(.vertical, 3)
                  .background(.quaternary, in: Capsule())
                Spacer()
              }

              if workLogRows.isEmpty {
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
                  ForEach(workLogRows) { row in
                    Group {
                      switch row.entry {
                      case .comment(let comment):
                        SprintTicketCommentRow(
                          comment: comment,
                          authorProfile: model.profiles.first { $0.name == comment.authorName },
                          mentionedProfile: mentionedProfile(
                            in: comment.body,
                            profiles: model.profiles
                          ),
                          showsBottomSeparator: row.showsBottomSeparator,
                          ownerAnswerSelection:
                            comment.id == activeOwnerQuestionComment?.id
                            ? ownerAnswerSelection
                            : nil,
                          customOwnerAnswer:
                            comment.id == activeOwnerQuestionComment?.id
                            ? $customOwnerAnswerDraft
                            : nil,
                          onSelectOwnerAnswer:
                            comment.id == activeOwnerQuestionComment?.id
                            ? { selection in
                              selectOwnerAnswer(selection)
                            }
                            : nil,
                          routedRecipientName:
                            comment.id == unansweredPermissionComment?.id
                            ? questionRecipient?.name
                            : nil,
                          isRouting:
                            comment.id == unansweredPermissionComment?.id
                              && isAskingQuestion,
                          onRoute:
                            comment.id == unansweredPermissionComment?.id
                            && !model.isTicketConversationMessageRunning
                            ? {
                              guard let questionRecipient else { return }
                              Task {
                                _ = await routeExistingQuestion(
                                  comment,
                                  to: questionRecipient
                                )
                              }
                            }
                            : nil,
                          onOpenDecisionArtifact: { artifact in
                            model.openDecisionArtifact(
                              artifact,
                              workItemID: item.id
                            )
                          }
                        )
                      case .event(let event):
                        SprintTicketEventRow(
                          event: event,
                          profiles: model.profiles,
                          retrospectiveNotes: model.retrospectiveNotes,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .permission(let request):
                        permissionRequestSection(
                          request,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .runContext(let context):
                        contextSection(
                          context,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .candidate(let candidate):
                        deliveryRevisionSection(
                          candidate,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .knowledge(let knowledge):
                        knowledgeProposalsSection(
                          knowledge,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .demo(let demo):
                        demoSection(
                          demo,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      case .followUp(let followUp):
                        followUpTicketProposalsSection(
                          followUp,
                          showsBottomSeparator: row.showsBottomSeparator
                        )
                      }
                    }
                    .id(row.id)
                  }
                }
              }
            }
          }
          .padding(24)
          .id("work-log-bottom")
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

      if model.ticketConversationWorkItemID == item.id {
        ConversationRespondingStatus(
          profile: activeTicketConversationProfile,
          fallbackName: "Team member",
          status: "is thinking…",
          activity: model.ticketConversationActivity,
          onStop: model.cancelTicketConversationMessage
        )
      }

      commentComposer
    }
    .frame(width: detailWidth, height: detailHeight)
    .onChange(of: activeOwnerQuestionComment?.id) { _, _ in
      ownerAnswerSelection = nil
      customOwnerAnswerDraft = ""
    }
    .sheet(item: $selectedRelationshipTicket) { relatedItem in
      SprintTicketDetailView(item: relatedItem)
    }
    .task {
      while !Task.isCancelled {
        let isFirstLoad = !hasLoadedWorkLog
        let previousLastEntryID = workLogEntries.last?.id
        let latestComments = await model.comments(for: item.id, productID: item.productID)
        let latestActivityEvents = await model.activityEvents(
          for: item.id,
          productID: item.productID
        )
        if latestComments != comments {
          comments = latestComments
        }
        if latestActivityEvents != activityEvents {
          activityEvents = latestActivityEvents
        }
        let latestEntryID = workLogEntries.last?.id
        if isFirstLoad, hasPendingWorkLogAction {
          workLogScrollRequest += 1
        } else if
          hasLoadedWorkLog,
          !isAcceptingTicket,
          latestEntryID != previousLastEntryID
        {
          workLogScrollRequest += 1
        }
        hasLoadedWorkLog = true
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func openRelationship(_ relationshipID: UUID) {
    selectedRelationshipTicket = TicketRelationshipNavigation.destination(
      for: relationshipID,
      source: currentItem,
      in: model.workItems
    )
  }

  private var commentComposer: some View {
    SprintTicketCommentComposer(
      ticketState: currentItem.state,
      canRetryFailedPostReviewDemo: canRetryFailedPostReviewDemo,
      awaitingOwnerName: awaitingOwnerProfile?.name,
      failedDeliveryName: failedDeliveryProfile?.name,
      hasPendingPermissionRequest: pendingPermissionRequest != nil,
      hasActiveOwnerQuestion: activeOwnerQuestionComment != nil,
      commentReplyRecipientName: commentReplyRecipient?.name,
      pausedQuestionRecipientName: pausedQuestionRecipient?.name,
      questionRecipientName: questionRecipient?.name,
      ownerAnswer: ownerAnswer,
      isPostingComment: isPostingComment,
      isAskingQuestion: isAskingQuestion,
      isResumingWork: isResumingWork,
      isAcceptingTicket: isAcceptingTicket,
      isConversationMessageRunning: model.isTicketConversationMessageRunning,
      knowledgeProposalsBlockCompletion: knowledgeProposalsBlockCompletion,
      commentError: commentError,
      focusResetRequest: commentComposerFocusResetRequest,
      onPostComment: { body in
        await postComment(body)
      },
      onAskCommentRecipient: { body in
        guard let commentReplyRecipient else { return false }
        return await askQuestion(body, to: commentReplyRecipient)
      },
      onAskPausedRecipient: { body in
        guard let pausedQuestionRecipient else { return false }
        return await askQuestion(body, to: pausedQuestionRecipient)
      },
      onAskQuestionRecipient: { body in
        guard let questionRecipient else { return false }
        return await askQuestion(body, to: questionRecipient)
      },
      onResumeWork: { body in
        await resumeWork(body)
      },
      onAcceptTicket: acceptTicket
    )
  }

  private func acceptTicket() {
    guard !isAcceptingTicket, !knowledgeProposalsBlockCompletion else { return }
    isAcceptingTicket = true
    Task {
      let didComplete = await model.acceptSprintTicket(currentItem)
      if didComplete {
        dismiss()
      } else {
        isAcceptingTicket = false
      }
    }
  }

  private func postComment(_ draft: String) async -> Bool {
    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isPostingComment else { return false }
    commentError = nil
    isPostingComment = true

    if let comment = await model.appendSprintWorkLogComment(
      workItemID: item.id,
      productID: item.productID,
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
      isPostingComment = false
      return true
    }
    commentError = "Your comment couldn't be saved. Try again."
    isPostingComment = false
    return false
  }

  private func selectOwnerAnswer(_ selection: TicketOwnerAnswerSelection) {
    ownerAnswerSelection = selection
    commentComposerFocusResetRequest += 1
  }

  private func askQuestion(
    _ draft: String,
    to recipient: AgentProfile
  ) async -> Bool {
    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isAskingQuestion else { return false }
    commentError = nil
    isAskingQuestion = true

    let attributedBody = "@\(recipient.name) \(body)"
    guard
      let comment = await model.appendOwnerComment(
        workItemID: item.id,
        productID: item.productID,
        body: attributedBody
      )
    else {
      commentError = "Your question couldn't be saved. Try again."
      isAskingQuestion = false
      return false
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
      let latestComments = await model.comments(for: item.id, productID: item.productID)
      if latestComments != comments {
        comments = latestComments
      }
      workLogScrollRequest += 1
    } catch {
      commentError = error.localizedDescription
    }
    isAskingQuestion = false
    return true
  }

  private func resumeWork(_ draft: String) async -> Bool {
    if canRetryFailedPostReviewDemo {
      guard !isResumingWork else { return false }
      commentError = nil
      isResumingWork = true
      let didRetry = await model.retryFailedPostReviewDemo(
        workItemID: item.id
      )
      if !didRetry {
        commentError = "Demo preparation couldn't be retried. Try again."
      }
      let latestComments = await model.comments(for: item.id, productID: item.productID)
      let latestActivityEvents = await model.activityEvents(
        for: item.id,
        productID: item.productID
      )
      if latestComments != comments {
        comments = latestComments
      }
      if latestActivityEvents != activityEvents {
        activityEvents = latestActivityEvents
      }
      workLogScrollRequest += 1
      isResumingWork = false
      return didRetry
    }

    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, !isResumingWork else { return false }
    let answeredQuestions = answeredOwnerQuestions(answer: body)
    let submittedSelection = ownerAnswerSelection
    let submittedCustomAnswer = customOwnerAnswerDraft
    let wasAnsweringQuestion = activeOwnerQuestionComment != nil
    if wasAnsweringQuestion {
      ownerAnswerSelection = nil
      customOwnerAnswerDraft = ""
    }
    commentError = nil
    isResumingWork = true

    if let comment = await model.resumeSprintWork(
      productID: item.productID,
      workItemID: item.id,
      body: body,
      answeredQuestions: answeredQuestions
    ) {
      appendLocalComment(comment)
      workLogScrollRequest += 1
      isResumingWork = false
      return true
    }
    if wasAnsweringQuestion {
      ownerAnswerSelection = submittedSelection
      customOwnerAnswerDraft = submittedCustomAnswer
    }
    commentError = "Your direction couldn't be saved. Try again."
    isResumingWork = false
    return false
  }

  private func routeExistingQuestion(
    _ comment: TicketComment,
    to recipient: AgentProfile
  ) async -> Bool {
    guard
      comment.authorKind == .owner,
      !isAskingQuestion,
      !model.isTicketConversationMessageRunning
    else { return false }
    commentError = nil
    isAskingQuestion = true

    do {
      _ = try await model.sendTicketConversationMessage(
        for: currentItem,
        to: recipient,
        ownerMessage: comment.body,
        allowsProposal: false
      )
      let latestComments = await model.comments(for: item.id, productID: item.productID)
      if latestComments != comments {
        comments = latestComments
      }
      workLogScrollRequest += 1
      isAskingQuestion = false
      return true
    } catch {
      commentError = error.localizedDescription
      isAskingQuestion = false
      return false
    }
  }

  private func answeredOwnerQuestions(
    answer: String
  ) -> [TicketAnsweredQuestion] {
    guard
      let comment = activeOwnerQuestionComment,
      let presentation = TicketOwnerQuestion.presentation(
        in: comment.body,
        structuredQuestion: comment.ownerQuestion
      )
    else { return [] }

    let selectedOption: String? =
      if case .option(let option) = ownerAnswerSelection {
        option
      } else {
        nil
      }
    return [
      TicketAnsweredQuestion(
        question: TicketRefinementQuestion(
          prompt: presentation.question.prompt,
          options: presentation.question.options
        ),
        selectedOption: selectedOption,
        answer: answer
      )
    ]
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

private struct SprintTicketCommentComposer: View {
  let ticketState: WorkItemState
  let canRetryFailedPostReviewDemo: Bool
  let awaitingOwnerName: String?
  let failedDeliveryName: String?
  let hasPendingPermissionRequest: Bool
  let hasActiveOwnerQuestion: Bool
  let commentReplyRecipientName: String?
  let pausedQuestionRecipientName: String?
  let questionRecipientName: String?
  let ownerAnswer: String?
  let isPostingComment: Bool
  let isAskingQuestion: Bool
  let isResumingWork: Bool
  let isAcceptingTicket: Bool
  let isConversationMessageRunning: Bool
  let knowledgeProposalsBlockCompletion: Bool
  let commentError: String?
  let focusResetRequest: Int
  let onPostComment: (String) async -> Bool
  let onAskCommentRecipient: (String) async -> Bool
  let onAskPausedRecipient: (String) async -> Bool
  let onAskQuestionRecipient: (String) async -> Bool
  let onResumeWork: (String) async -> Bool
  let onAcceptTicket: () -> Void

  @State private var draft = ""
  @FocusState private var isFocused: Bool

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSubmitting: Bool {
    isPostingComment || isAskingQuestion || isResumingWork
  }

  private var canPostComment: Bool {
    !trimmedDraft.isEmpty && !isSubmitting
  }

  private var canAskCommentRecipient: Bool {
    canPostComment
      && commentReplyRecipientName != nil
      && !isConversationMessageRunning
  }

  private var canAskQuestionRecipient: Bool {
    canPostComment
      && questionRecipientName != nil
      && !isConversationMessageRunning
  }

  private var resumeBody: String {
    if hasActiveOwnerQuestion {
      return ownerAnswer ?? ""
    }
    return trimmedDraft
  }

  private var canResumeWork: Bool {
    (canRetryFailedPostReviewDemo || !resumeBody.isEmpty)
      && !isSubmitting
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(ConversationPalette.owner.opacity(0.12))
        Image(systemName: "person.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(ConversationPalette.owner)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 7) {
        statusMessage

        Text(hasActiveOwnerQuestion ? "Your response" : "Add a comment")
          .font(.subheadline.weight(.semibold))

        ZStack(alignment: .topLeading) {
          if draft.isEmpty && !isFocused {
            Text("Add context, answer a question, or give feedback…")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
          TextEditor(text: $draft)
            .scrollContentBackground(.hidden)
            .font(.body)
            .focused($isFocused)
            .padding(8)
            .onKeyPress(phases: .down) { keyPress in
              handleKeyPress(keyPress)
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
          actionButtons
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
    .background(.quaternary.opacity(0.18))
    .onChange(of: focusResetRequest) {
      isFocused = false
    }
  }

  @ViewBuilder
  private var statusMessage: some View {
    if canRetryFailedPostReviewDemo {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Image(systemName: "arrow.clockwise.circle.fill")
          Text("Demo preparation stopped unexpectedly.")
            .fontWeight(.semibold)
        }
        Text(
          "Retry the already reviewed candidate. No new comment or repeat implementation is required."
        )
        .foregroundStyle(.secondary)
      }
      .font(.caption)
      .foregroundStyle(.red)
    } else if let awaitingOwnerName {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Image(systemName: "pause.circle.fill")
          Text(awaitingOwnerName)
            .fontWeight(.semibold)
          Text("is paused and waiting for direction.")
        }
        Text(
          hasPendingPermissionRequest
            ? "Use Allow or Deny on the permission request above, or ask the waiting team member for an explanation without resuming work."
            : hasActiveOwnerQuestion
              ? "Choose an answer above or select Other, then choose Submit answers."
              : "Ask a question without restarting work, or add direction and choose Submit answers."
        )
        .foregroundStyle(.secondary)
      }
      .font(.caption)
      .foregroundStyle(.orange)
    } else if let failedDeliveryName {
      HStack(spacing: 7) {
        Image(systemName: "arrow.clockwise.circle.fill")
        Text(failedDeliveryName)
          .fontWeight(.semibold)
        Text("stopped unexpectedly. Add direction, then choose Retry work.")
      }
      .font(.caption)
      .foregroundStyle(.red)
    } else if ticketState == .acceptance {
      Label(
        commentReplyRecipientName.map {
          "Comments go to \($0) for a reply without changing the reviewed demo."
        }
          ?? "No team member is available to answer comments on this ticket.",
        systemImage: "play.rectangle"
      )
      .font(.caption)
      .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var actionButtons: some View {
    if hasPendingPermissionRequest {
      commentButton(style: .bordered)
      questionButton(
        recipientName: questionRecipientName,
        action: onAskQuestionRecipient
      )
    } else if canRetryFailedPostReviewDemo {
      commentButton(style: .bordered)

      Button(
        isResumingWork ? "Retrying…" : "Retry demo preparation"
      ) {
        submitResumeWork()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canResumeWork)
    } else if awaitingOwnerName != nil {
      commentButton(style: .bordered)

      if let pausedQuestionRecipientName {
        Button(
          isAskingQuestion ? "Asking…" : "Ask \(pausedQuestionRecipientName)"
        ) {
          submitDraft(using: onAskPausedRecipient)
        }
        .buttonStyle(.bordered)
        .disabled(!canPostComment)
      }

      Button {
        submitResumeWork()
      } label: {
        Label(
          isResumingWork ? "Submitting…" : "Submit answers",
          systemImage: "paperplane.fill"
        )
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canResumeWork)
    } else if failedDeliveryName != nil {
      commentButton(style: .bordered)

      Button(isResumingWork ? "Retrying…" : "Retry work") {
        submitResumeWork()
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canResumeWork)
    } else if ticketState == .acceptance {
      Button(isAskingQuestion ? "Commenting…" : "Comment") {
        submitDraft(using: onAskCommentRecipient)
      }
      .buttonStyle(.bordered)
      .disabled(!canAskCommentRecipient)

      Divider()
        .frame(height: 20)
        .padding(.horizontal, 2)

      Button(isResumingWork ? "Sending…" : "Request changes") {
        submitResumeWork()
      }
      .buttonStyle(.bordered)
      .disabled(!canResumeWork)

      Button(isAcceptingTicket ? "Completing…" : "Approve and complete") {
        onAcceptTicket()
      }
      .buttonStyle(.borderedProminent)
      .disabled(isAcceptingTicket || knowledgeProposalsBlockCompletion)
      .help(
        knowledgeProposalsBlockCompletion
          ? "Accept or reject every proposed knowledge change first."
          : "Promote this exact reviewed revision to the accepted trunk."
      )
    } else if
      ticketState == .running
        || ticketState == .integrating
        || ticketState == .verifying
    {
      commentButton(style: .bordered)
      questionButton(
        recipientName: questionRecipientName,
        action: onAskQuestionRecipient
      )
    } else {
      commentButton(style: .borderedProminent)
    }
  }

  @ViewBuilder
  private func questionButton(
    recipientName: String?,
    action: @escaping (String) async -> Bool
  ) -> some View {
    if let recipientName {
      Button(isAskingQuestion ? "Asking…" : "Ask \(recipientName)") {
        submitDraft(using: action)
      }
      .buttonStyle(.borderedProminent)
      .tint(.purple)
      .disabled(!canAskQuestionRecipient)
    }
  }

  @ViewBuilder
  private func commentButton(style: CommentButtonStyle) -> some View {
    switch style {
    case .bordered:
      Button(isPostingComment ? "Commenting…" : "Comment") {
        submitDraft(using: onPostComment)
      }
      .buttonStyle(.bordered)
      .disabled(!canPostComment)
    case .borderedProminent:
      Button(isPostingComment ? "Commenting…" : "Comment") {
        submitDraft(using: onPostComment)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canPostComment)
    }
  }

  private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
    guard keyPress.key == .return else { return .ignored }
    if keyPress.modifiers.contains(.shift) {
      return .ignored
    }
    if ticketState == .acceptance, commentReplyRecipientName != nil {
      if canAskCommentRecipient {
        submitDraft(using: onAskCommentRecipient)
      }
      return .handled
    }
    if canPostComment {
      submitDraft(using: onPostComment)
    }
    return .handled
  }

  private func submitDraft(
    using action: @escaping (String) async -> Bool
  ) {
    let submittedDraft = trimmedDraft
    guard !submittedDraft.isEmpty, !isSubmitting else { return }
    draft = ""
    Task { @MainActor in
      if !(await action(submittedDraft)) {
        restore(submittedDraft)
      }
    }
  }

  private func submitResumeWork() {
    let submittedDraft = resumeBody
    guard canResumeWork else { return }
    let restoresDraft = !hasActiveOwnerQuestion && !canRetryFailedPostReviewDemo
    if restoresDraft {
      draft = ""
    }
    Task { @MainActor in
      if !(await onResumeWork(submittedDraft)), restoresDraft {
        restore(submittedDraft)
      }
    }
  }

  private func restore(_ submittedDraft: String) {
    if trimmedDraft.isEmpty {
      draft = submittedDraft
    } else {
      draft = submittedDraft + "\n" + draft
    }
  }

  private enum CommentButtonStyle {
    case bordered
    case borderedProminent
  }
}

private struct CanonicalKnowledgeProposalCard: View {
  let proposal: KnowledgePageProposal
  let currentPage: KnowledgePage?
  let requiresOwnerApproval: Bool
  let isDeciding: Bool
  let onOpenPage: (() -> Void)?
  let onDecision: (Bool) -> Void

  private var isPending: Bool {
    proposal.status == .proposed || proposal.status == .reviewed
  }

  private var sourceChanged: Bool {
    guard isPending, proposal.operation == .update, let currentPage else { return false }
    return currentPage.title != proposal.basePageTitle
      || currentPage.bodyMarkdown != proposal.basePageBodyMarkdown
  }

  private var requiresOwnerDecision: Bool {
    requiresOwnerApproval && proposal.status == .reviewed
  }

  private var statusTitle: String {
    switch proposal.status {
    case .proposed: "Awaiting Tech Lead"
    case .reviewed: requiresOwnerApproval ? "Decision required" : "Ready to publish"
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
        WorkLogDisclosure(
          collapsedTitle: "Review rendered preview",
          expandedTitle: "Hide rendered preview",
          tint: .indigo
        ) {
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
        }
      } else if let onOpenPage {
        Button(action: onOpenPage) {
          HStack(spacing: 7) {
            Image(systemName: "books.vertical")
            Text("Open in product")
            Spacer()
            Image(systemName: "arrow.right")
          }
          .font(.callout.weight(.semibold))
          .foregroundStyle(.indigo)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      if requiresOwnerDecision {
        HStack {
          Spacer()
          Button(sourceChanged ? "Dismiss stale proposal" : "Reject") {
            onDecision(false)
          }
          .disabled(isDeciding)
          Button(isDeciding ? "Applying…" : "Accept") { onDecision(true) }
            .buttonStyle(.borderedProminent)
            .disabled(isDeciding || sourceChanged)
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

private struct WorkLogDisclosure<Content: View>: View {
  let collapsedTitle: String
  let expandedTitle: String
  let tint: Color
  let labelFont: Font
  let content: Content
  @State private var isExpanded = false

  init(
    collapsedTitle: String,
    expandedTitle: String? = nil,
    tint: Color,
    labelFont: Font = .callout.weight(.medium),
    @ViewBuilder content: () -> Content
  ) {
    self.collapsedTitle = collapsedTitle
    self.expandedTitle = expandedTitle ?? collapsedTitle
    self.tint = tint
    self.labelFont = labelFont
    self.content = content()
  }

  private var title: String {
    isExpanded ? expandedTitle : collapsedTitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
          Text(title)
            .font(labelFont)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Collapse these details" : "Expand these details")

      if isExpanded {
        Divider()
          .overlay(tint.opacity(0.16))
          .padding(.horizontal, 10)

        content
          .padding(.horizontal, 10)
          .padding(.vertical, 9)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(tint.opacity(0.035))
          .transition(.opacity)
      }
    }
    .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(tint.opacity(0.16), lineWidth: 1)
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

private struct TicketDetailMetadataValue: Identifiable {
  let id: String
  let title: String
  let value: String
  let symbol: String
  let tint: Color
}

private struct TicketDetailRelationshipItem: Identifiable {
  let id: String
  let key: String
  let title: String
  let workItemID: UUID?

  init(id: String, key: String, title: String, workItemID: UUID? = nil) {
    self.id = id
    self.key = key
    self.title = title
    self.workItemID = workItemID
  }

  init(workItem: WorkItem) {
    id = "ticket-\(workItem.id.uuidString)"
    key = workItem.key
    title = workItem.title
    workItemID = workItem.id
  }
}

private struct TicketDetailRelationshipGroup: Identifiable {
  let id: String
  let title: String
  let symbol: String
  let items: [TicketDetailRelationshipItem]
}

private struct TicketDetailOverview: View {
  let title: String
  let context: String
  let emptyContextText: String
  let metadata: [TicketDetailMetadataValue]
  let epic: Epic?
  let acceptanceCriteria: [String]
  let emptyAcceptanceCriteriaText: String
  let relationships: [TicketDetailRelationshipGroup]
  let onOpenRelationship: ((UUID) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.title2.weight(.semibold))
          .textSelection(.enabled)
        if context.isEmpty {
          Text(emptyContextText)
            .foregroundStyle(.secondary)
        } else {
          Text(context)
            .textSelection(.enabled)
        }

        if let epic {
          TicketEpicLink(epic: epic)
        }
      }

      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
          count: 4
        ),
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(metadata) { value in
          SprintTicketMetadata(
            title: value.title,
            value: value.value,
            symbol: value.symbol,
            tint: value.tint
          )
        }
      }

      TicketDetailAcceptanceCriteriaSection(
        criteria: acceptanceCriteria,
        emptyText: emptyAcceptanceCriteriaText
      )

      if !relationships.isEmpty {
        TicketDetailRelationshipsSection(
          groups: relationships,
          onOpenRelationship: onOpenRelationship
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TicketDetailAcceptanceCriteriaSection: View {
  let criteria: [String]
  let emptyText: String

  var body: some View {
    SprintTicketSectionCard(title: "Acceptance criteria") {
      if criteria.isEmpty {
        Label(emptyText, systemImage: "exclamationmark.circle")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(criteria, id: \.self) { criterion in
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
  }
}

private struct TicketDetailRelationshipsSection: View {
  let groups: [TicketDetailRelationshipGroup]
  let onOpenRelationship: ((UUID) -> Void)?

  var body: some View {
    SprintTicketSectionCard(title: "Relationships") {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(groups) { group in
          TicketDetailRelationshipRow(
            group: group,
            onOpenRelationship: onOpenRelationship
          )
        }
      }
    }
  }
}

private struct TicketDetailRelationshipRow: View {
  let group: TicketDetailRelationshipGroup
  let onOpenRelationship: ((UUID) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(group.title, systemImage: group.symbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(group.items) { item in
          TicketDetailRelationshipItemRow(
            item: item,
            onOpen: item.workItemID.flatMap { workItemID in
              onOpenRelationship.map { open in
                { open(workItemID) }
              }
            }
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TicketDetailRelationshipItemRow: View {
  let item: TicketDetailRelationshipItem
  let onOpen: (() -> Void)?
  @State private var isHovering = false

  var body: some View {
    Group {
      if let onOpen {
        Button(action: onOpen) {
          rowContent(showsOpenAffordance: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
          isHovering
            ? Color.accentColor.opacity(0.075)
            : Color(nsColor: .windowBackgroundColor).opacity(0.7),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(
              isHovering
                ? Color.accentColor.opacity(0.4)
                : Color(nsColor: .separatorColor).opacity(0.65),
              lineWidth: 1
            )
        }
        .onHover { hovering in
          withAnimation(.easeOut(duration: 0.12)) {
            isHovering = hovering
          }
        }
        .help("Open \(item.key) · \(item.title)")
      } else {
        rowContent(showsOpenAffordance: false)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func rowContent(showsOpenAffordance: Bool) -> some View {
    HStack(alignment: .center, spacing: 9) {
      HStack(alignment: .top, spacing: 9) {
        Text("•")
          .foregroundStyle(.secondary)
          .frame(width: 16, alignment: .center)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(item.key)
            .font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(
              showsOpenAffordance && isHovering ? Color.accentColor : Color.secondary
            )
          Text("·")
            .foregroundStyle(.tertiary)
          Text(item.title)
            .foregroundStyle(
              showsOpenAffordance && isHovering ? Color.accentColor : Color.primary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if showsOpenAffordance {
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
      }
    }
  }
}

struct SprintTicketRunContextLogItem: Identifiable {
  let run: AgentRun
  let pages: [KnowledgePage]

  var id: UUID { run.id }
  var createdAt: Date { run.createdAt }
  var mandatoryPages: [KnowledgePage] {
    pages.filter(KnowledgeContextSelector.isMandatory)
  }
  var relevantPages: [KnowledgePage] {
    pages.filter { !KnowledgeContextSelector.isMandatory($0) }
  }
}

enum SprintTicketRunContextVisibility {
  static func includes(
    profile: AgentProfile?,
    isDeliveryRun: Bool
  ) -> Bool {
    isDeliveryRun || profile?.role.canReview != true
  }
}

struct SprintTicketKnowledgeLogItem: Identifiable {
  let candidate: CandidateRevision
  let proposals: [KnowledgePageProposal]

  var id: UUID { candidate.id }
  var createdAt: Date {
    proposals.map(\.createdAt).min() ?? candidate.createdAt
  }
}

struct SprintTicketDemoLogItem: Identifiable {
  let event: ActivityEvent
  let candidate: CandidateRevision

  var id: UUID { event.id }
  var createdAt: Date { event.createdAt }
}

struct SprintTicketFollowUpLogItem: Identifiable {
  let candidate: CandidateRevision

  var id: UUID { candidate.id }
  var createdAt: Date { candidate.createdAt }
}

enum SprintWorkLogEntry: Identifiable {
  case comment(TicketComment)
  case event(ActivityEvent)
  case permission(AgentPermissionRequest)
  case runContext(SprintTicketRunContextLogItem)
  case candidate(CandidateRevision)
  case knowledge(SprintTicketKnowledgeLogItem)
  case demo(SprintTicketDemoLogItem)
  case followUp(SprintTicketFollowUpLogItem)

  var id: String {
    switch self {
    case .comment(let comment): "comment-\(comment.id.uuidString)"
    case .event(let event): "event-\(event.id.uuidString)"
    case .permission(let request): "permission-\(request.id.uuidString)"
    case .runContext(let context): "context-\(context.id.uuidString)"
    case .candidate(let candidate): "candidate-\(candidate.id.uuidString)"
    case .knowledge(let knowledge): "knowledge-\(knowledge.id.uuidString)"
    case .demo(let demo): "demo-\(demo.id.uuidString)"
    case .followUp(let followUp): "follow-up-\(followUp.id.uuidString)"
    }
  }

  var createdAt: Date {
    switch self {
    case .comment(let comment): comment.createdAt
    case .event(let event): event.createdAt
    case .permission(let request): request.createdAt
    case .runContext(let context): context.createdAt
    case .candidate(let candidate): candidate.createdAt
    case .knowledge(let knowledge): knowledge.createdAt
    case .demo(let demo): demo.createdAt
    case .followUp(let followUp): followUp.createdAt
    }
  }

  var sortOrder: Int {
    switch self {
    case .event: 0
    case .runContext: 1
    case .comment: 2
    case .permission: 3
    case .candidate: 4
    case .knowledge: 5
    case .followUp: 6
    case .demo: 7
    }
  }
}

struct SprintWorkLogRow: Identifiable {
  let entry: SprintWorkLogEntry
  let showsBottomSeparator: Bool

  var id: String { entry.id }
}

enum SprintTicketWorkLogTimeline {
  static func displayedEvents(
    events: [ActivityEvent],
    comments: [TicketComment],
    permissionRequests: [AgentPermissionRequest],
    demoSubmissions: [SprintTicketDemoLogItem]
  ) -> [ActivityEvent] {
    let demoEventIDs = Set(demoSubmissions.map(\.event.id))
    return events.filter { event in
      guard !demoEventIDs.contains(event.id) else { return false }

      switch event.kind {
      case "comment.created", "work_item.ranked",
        "agent_run.queued", "agent_run.running", "agent_run.completed":
        return false
      case "agent_run.awaiting_owner":
        return !isRepresentedByPermissionRequest(
          event,
          permissionRequests: permissionRequests
        )
      case "work_item.transitioned":
        guard !isRepresentedByDemoFeedbackComment(event, comments: comments) else {
          return false
        }
        guard let transition = transition(in: event.detail) else { return true }
        return workLogPhase(for: transition.from) != workLogPhase(for: transition.to)
      default:
        return true
      }
    }
  }

  static func rows(_ entries: [SprintWorkLogEntry]) -> [SprintWorkLogRow] {
    entries.enumerated().map { index, entry in
      SprintWorkLogRow(
        entry: entry,
        showsBottomSeparator: index < entries.count - 1
      )
    }
  }

  static func ordered(_ entries: [SprintWorkLogEntry]) -> [SprintWorkLogEntry] {
    entries.sorted {
      if $0.createdAt == $1.createdAt {
        if $0.sortOrder == $1.sortOrder {
          return $0.id < $1.id
        }
        return $0.sortOrder < $1.sortOrder
      }
      return $0.createdAt < $1.createdAt
    }
  }

  static func demoSubmissions(
    events: [ActivityEvent],
    candidates: [CandidateRevision]
  ) -> [SprintTicketDemoLogItem] {
    let orderedCandidates = candidates.sorted {
      if $0.createdAt == $1.createdAt {
        return $0.version < $1.version
      }
      return $0.createdAt < $1.createdAt
    }
    return events
      .filter(isDemoSubmission)
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.sequence < $1.sequence
        }
        return $0.createdAt < $1.createdAt
      }
      .compactMap { event in
        guard
          let candidate = orderedCandidates.last(where: {
            $0.createdAt <= event.createdAt
          })
        else { return nil }
        return SprintTicketDemoLogItem(event: event, candidate: candidate)
      }
  }

  private static func isRepresentedByPermissionRequest(
    _ event: ActivityEvent,
    permissionRequests: [AgentPermissionRequest]
  ) -> Bool {
    guard event.detail == "Waiting for a scoped permission decision" else {
      return false
    }
    return permissionRequests.contains {
      $0.workItemID == event.workItemID
    }
  }

  private static func isRepresentedByDemoFeedbackComment(
    _ event: ActivityEvent,
    comments: [TicketComment]
  ) -> Bool {
    guard
      let reason = transitionReason(in: event.detail),
      reason.hasPrefix("Demo feedback:")
    else {
      return false
    }
    let feedback = reason
      .dropFirst("Demo feedback:".count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !feedback.isEmpty else { return false }
    return comments.contains {
      $0.workItemID == event.workItemID
        && $0.authorKind == .owner
        && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(feedback)
    }
  }

  private static func transition(
    in detail: String
  ) -> (from: WorkItemState, to: WorkItemState)? {
    let movement = detail
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
    else {
      return nil
    }
    return (from, to)
  }

  private static func transitionReason(in detail: String) -> String? {
    let parts = detail.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func workLogPhase(for state: WorkItemState) -> Int {
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

  private static func isDemoSubmission(_ event: ActivityEvent) -> Bool {
    guard event.kind == "work_item.transitioned" else { return false }
    let movement = event.detail
      .split(separator: ":", maxSplits: 1)
      .first
      .map(String.init) ?? ""
    let destination = movement
      .components(separatedBy: " -> ")
      .last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return destination == WorkItemState.acceptance.rawValue
  }
}

private struct SprintTicketEventRow: View {
  let event: ActivityEvent
  let profiles: [AgentProfile]
  let retrospectiveNotes: [RetrospectiveNote]
  let showsBottomSeparator: Bool

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
    case "system": "Spedito"
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
    case "retrospective.action_proposed":
      "Retrospective change proposed"
    case "retrospective.action_promoted_to_practice":
      "Added to Ways of working"
    case "work_item.created_from_retrospective":
      "Retrospective ticket created"
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
    case "retrospective.action_proposed", "retrospective.action_promoted_to_practice",
      "work_item.created_from_retrospective":
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
    case "retrospective.action_proposed": .blue
    case "retrospective.action_promoted_to_practice": .purple
    case "work_item.created_from_retrospective": .blue
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
    case "retrospective.action_proposed": "plus.bubble"
    case "retrospective.action_promoted_to_practice": "person.2.badge.gearshape"
    case "work_item.created_from_retrospective": "list.bullet.clipboard"
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
    .padding(.top, 14)
    .padding(.bottom, showsBottomSeparator ? 14 : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      if showsBottomSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor).opacity(0.55))
          .frame(height: 1)
          .padding(.leading, 46)
      }
    }
  }
}

private enum TicketOwnerAnswerSelection: Equatable {
  case option(String)
  case custom
}

private struct SprintTicketCommentRow: View {
  let comment: TicketComment
  let authorProfile: AgentProfile?
  let mentionedProfile: AgentProfile?
  let showsBottomSeparator: Bool
  let ownerAnswerSelection: TicketOwnerAnswerSelection?
  let customOwnerAnswer: Binding<String>?
  let onSelectOwnerAnswer: ((TicketOwnerAnswerSelection) -> Void)?
  let routedRecipientName: String?
  let isRouting: Bool
  let onRoute: (() -> Void)?
  var onOpenDecisionArtifact: ((TicketDecisionArtifact) -> Void)? = nil
  @FocusState private var isCustomOwnerAnswerFocused: Bool

  private var accent: Color {
    switch comment.authorKind {
    case .owner: ConversationPalette.owner
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

  private var ownerQuestionPresentation: TicketOwnerQuestionPresentation? {
    guard comment.authorKind == .agent else { return nil }
    return TicketOwnerQuestion.presentation(
      in: comment.body,
      structuredQuestion: comment.ownerQuestion
    )
  }

  private var presentedOwnerAnswerSelection: TicketOwnerAnswerSelection? {
    if let ownerAnswerSelection {
      return ownerAnswerSelection
    }
    guard let answered = comment.answeredQuestions.first else { return nil }
    return answered.selectedOption.map(TicketOwnerAnswerSelection.option)
      ?? .custom
  }

  private var submittedCustomOwnerAnswer: String? {
    guard
      presentedOwnerAnswerSelection == .custom,
      customOwnerAnswer == nil
    else { return nil }
    return comment.answeredQuestions.first?.answer
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
        if let ownerQuestionPresentation {
          if !ownerQuestionPresentation.context.isEmpty {
            TicketMarkdownDocument(
              source: ownerQuestionPresentation.context,
              baseFont: .body,
              highlightedText: mentionedProfile.map { "@\($0.name)" },
              highlightedColor: mentionedProfile?.role.tint
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          ownerQuestionView(ownerQuestionPresentation.question)
            .padding(.top, ownerQuestionPresentation.context.isEmpty ? 0 : 10)
        } else {
          TicketMarkdownDocument(
            source: comment.body,
            baseFont: .body,
            highlightedText: mentionedProfile.map { "@\($0.name)" },
            highlightedColor: mentionedProfile?.role.tint
          )
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let routedRecipientName, let onRoute {
          Button(isRouting ? "Asking…" : "Ask \(routedRecipientName) about this") {
            onRoute()
          }
          .buttonStyle(.bordered)
          .tint(.purple)
          .controlSize(.small)
          .disabled(isRouting)
        }
      }
    }
    .padding(.top, 14)
    .padding(.bottom, showsBottomSeparator ? 14 : 0)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      if showsBottomSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor).opacity(0.55))
          .frame(height: 1)
          .padding(.leading, 46)
      }
    }
  }

  private func ownerQuestionView(_ question: TicketOwnerQuestion) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Question for you", systemImage: "questionmark.bubble.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(accent)
      Text(question.prompt)
        .font(.body.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)

      if let artifact = question.decisionArtifact {
        Button {
          onOpenDecisionArtifact?(artifact)
        } label: {
          Label("Open \(artifact.title)", systemImage: "doc.text")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(onOpenDecisionArtifact == nil)
      }

      VStack(spacing: 6) {
        ForEach(question.options, id: \.self) { option in
          ownerAnswerRow(
            option,
            selection: .option(option)
          )
        }
        ownerAnswerRow(
          "Other",
          selection: .custom
        )
      }

      if presentedOwnerAnswerSelection == .custom, let customOwnerAnswer {
        TextField("Type another answer", text: customOwnerAnswer)
          .textFieldStyle(.roundedBorder)
          .focused($isCustomOwnerAnswerFocused)
          .task {
            await Task.yield()
            isCustomOwnerAnswerFocused = true
          }
      } else if let submittedCustomOwnerAnswer {
        Text(submittedCustomOwnerAnswer)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(
            accent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
          )
      }

      if onSelectOwnerAnswer != nil {
        Text("Choose an answer to continue.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .stroke(accent.opacity(0.28), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func ownerAnswerRow(
    _ label: String,
    selection: TicketOwnerAnswerSelection
  ) -> some View {
    if let onSelectOwnerAnswer {
      Button {
        onSelectOwnerAnswer(selection)
      } label: {
        ownerAnswerLabel(label, selection: selection)
      }
      .buttonStyle(
        RefinementChoiceButtonStyle(
          tint: accent,
          isSelected: presentedOwnerAnswerSelection == selection
        )
      )
    } else {
      readOnlyOwnerAnswerLabel(label, selection: selection)
    }
  }

  private func readOnlyOwnerAnswerLabel(
    _ label: String,
    selection: TicketOwnerAnswerSelection
  ) -> some View {
    let isSelected = presentedOwnerAnswerSelection == selection
    return HStack(alignment: .firstTextBaseline, spacing: 9) {
      Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
        .font(.caption)
        .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.65))
      Text(label)
        .font(.callout)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 8)
    )
  }

  private func ownerAnswerLabel(
    _ label: String,
    selection: TicketOwnerAnswerSelection
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 9) {
      Image(
        systemName:
          presentedOwnerAnswerSelection == selection
          ? "largecircle.fill.circle"
          : "circle"
      )
      .font(.caption)
      .foregroundStyle(
        presentedOwnerAnswerSelection == selection ? accent : Color.secondary
      )
      Text(label)
        .font(.callout)
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
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
    case .table(let table):
      MarkdownTableView(
        table: table,
        font: baseFont,
        inlineMarkdown: inlineMarkdown
      )
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

private struct IntrinsicWrappingLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let result = layout(
      sizes: subviews.map { $0.sizeThatFits(.unspecified) },
      availableWidth: proposal.width ?? .infinity
    )
    return CGSize(
      width: proposal.width ?? result.contentSize.width,
      height: result.contentSize.height
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let result = layout(sizes: sizes, availableWidth: bounds.width)

    for (index, subview) in subviews.enumerated() {
      let size = sizes[index]
      let origin = result.origins[index]
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )
    }
  }

  private func layout(
    sizes: [CGSize],
    availableWidth: CGFloat
  ) -> (contentSize: CGSize, origins: [CGPoint]) {
    var origins: [CGPoint] = []
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var rowHeight: CGFloat = 0
    var contentWidth: CGFloat = 0

    for size in sizes {
      if currentX > 0, currentX + size.width > availableWidth {
        currentX = 0
        currentY += rowHeight + spacing
        rowHeight = 0
      }

      origins.append(CGPoint(x: currentX, y: currentY))
      contentWidth = max(contentWidth, currentX + size.width)
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    return (
      CGSize(
        width: contentWidth,
        height: sizes.isEmpty ? 0 : currentY + rowHeight
      ),
      origins
    )
  }
}

enum SprintGoalSuggestionPolicy {
  static let defaultPlaceholder = "Next valuable increment"

  static func shouldGenerate(existingGoal: String) -> Bool {
    let goal = existingGoal.trimmingCharacters(in: .whitespacesAndNewlines)
    return goal.isEmpty || goal == defaultPlaceholder
  }
}

private struct SprintPlanningView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  let onSaved: (UUID) -> Void
  @State private var goal = ""
  @State private var didPrepare = false
  @State private var isSaving = false
  @State private var goalSuggestionError: String?
  @State private var needsAutomaticGoalSuggestion = false
  @State private var selectedAssigneeIDs: [UUID: UUID] = [:]

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

  private var deliveryProfiles: [AgentProfile] {
    model.profiles.filter(\.role.canOwnDelivery)
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

  private var elapsedLowSeconds: Int {
    waves.reduce(0) { total, wave in
      total + (wave.map(\.forecast.durationLowSeconds).max() ?? 0)
    }
  }

  private var elapsedHighSeconds: Int {
    waves.reduce(0) { total, wave in
      total + (wave.map(\.forecast.durationHighSeconds).max() ?? 0)
    }
  }

  private var riskCount: Int {
    lines.reduce(0) { $0 + $1.risks.count }
  }

  private var canSave: Bool {
    !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !model.isGeneratingSprintGoal
      && !lines.isEmpty
      && lines.allSatisfy { $0.owner != nil && !$0.item.acceptanceCriteria.isEmpty }
  }

  private var goalBinding: Binding<String> {
    Binding(
      get: { goal },
      set: { newGoal in
        goal = newGoal
        needsAutomaticGoalSuggestion = false
      }
    )
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
          HStack(spacing: 8) {
            TextField("What valuable outcome should this sprint deliver?", text: goalBinding)
              .textFieldStyle(.roundedBorder)
              .font(.body)
              .disabled(model.isGeneratingSprintGoal)
            Button(action: suggestGoal) {
              Group {
                if model.isGeneratingSprintGoal {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Image(systemName: "wand.and.stars")
                }
              }
              .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(!model.canGenerateSprintGoal)
            .accessibilityLabel(
              model.isGeneratingSprintGoal
                ? "Generating sprint goal with AI"
                : "Generate sprint goal with AI"
            )
            .help("Generate a sprint goal from the ticket titles")
          }
          if let goalSuggestionError {
            Label(goalSuggestionError, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
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
            value: "\(duration(elapsedLowSeconds))–\(duration(elapsedHighSeconds))",
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

        if riskCount > 0 {
          VStack(alignment: .leading, spacing: 9) {
            Label("Plan needs attention", systemImage: "exclamationmark.triangle.fill")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.orange)
            Text(
              "Resolve \(riskCount) \(riskCount == 1 ? "issue" : "issues") before this sprint can start."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(lines.filter { !$0.risks.isEmpty }) { line in
              ForEach(line.risks, id: \.self) { risk in
                Text("\(line.item.key): \(risk)")
                  .font(.caption.weight(.medium))
              }
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .stroke(.orange.opacity(0.22), lineWidth: 1)
          }
        }

        VStack(alignment: .leading, spacing: 0) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("Sprint scope")
                .font(.headline)
              Text("Choose the delivery assignee for every ticket before starting the sprint.")
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
                  isLast: waveIndex == waves.count - 1,
                  deliveryProfiles: deliveryProfiles,
                  assigneeBinding: assigneeBinding(for:)
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
              Text("Saving…")
            }
          } else {
            Text("Save and open board")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave || isSaving)
      }
    }
    .padding(26)
    .frame(minWidth: 1_000, idealWidth: 1_160, minHeight: 680, idealHeight: 780)
    .onAppear {
      prepare()
      generateGoalAutomaticallyIfNeeded()
    }
    .onChange(of: model.canGenerateSprintGoal) { _, canGenerate in
      if canGenerate {
        generateGoalAutomaticallyIfNeeded()
      }
    }
    .onDisappear {
      if model.isGeneratingSprintGoal {
        model.cancelSprintGoalGeneration()
      }
    }
  }

  private var saveBlockerText: String {
    if model.isGeneratingSprintGoal {
      return "Wait for AI to finish the sprint goal."
    }
    if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Add a sprint goal."
    }
    if lines.contains(where: { $0.owner == nil }) {
      return "Choose an assignee for every sprint ticket."
    }
    return "Every sprint ticket needs acceptance criteria."
  }

  private func prepare() {
    guard !didPrepare else { return }
    didPrepare = true
    goal =
      model.candidateSprintPlan?.sprint.goal
      ?? SprintGoalSuggestionPolicy.defaultPlaceholder
    needsAutomaticGoalSuggestion = SprintGoalSuggestionPolicy.shouldGenerate(
      existingGoal: goal
    )
    selectedAssigneeIDs = scopedItems.reduce(into: [:]) { result, item in
      let plannedOwnerID = sprintItemsByWorkItemID[item.id]?.implementerProfileID
      if let ownerID = plannedOwnerID ?? item.ownerProfileID {
        result[item.id] = ownerID
      }
    }
  }

  private func savePlan() {
    guard
      !isSaving,
      let sprintID = model.candidateSprintPlan?.sprint.id
    else { return }
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
        items: inputs
      )
      isSaving = false
      guard saved else { return }
      isPresented = false
      onSaved(sprintID)
    }
  }

  private func suggestGoal() {
    guard model.canGenerateSprintGoal else { return }
    needsAutomaticGoalSuggestion = false
    goalSuggestionError = nil
    Task {
      do {
        goal = try await model.generateSprintGoal()
      } catch {
        goalSuggestionError = error.localizedDescription
      }
    }
  }

  private func generateGoalAutomaticallyIfNeeded() {
    guard needsAutomaticGoalSuggestion else { return }
    suggestGoal()
  }

  private func resolvedOwner(for item: WorkItem) -> AgentProfile? {
    guard let ownerID = selectedAssigneeIDs[item.id] else { return nil }
    return deliveryProfiles.first { $0.id == ownerID }
  }

  private func assigneeBinding(for itemID: UUID) -> Binding<UUID?> {
    Binding(
      get: { selectedAssigneeIDs[itemID] },
      set: { ownerID in
        if let ownerID {
          selectedAssigneeIDs[itemID] = ownerID
        } else {
          selectedAssigneeIDs.removeValue(forKey: itemID)
        }
      }
    )
  }

  private func risks(for item: WorkItem, scopedIDs: Set<UUID>) -> [String] {
    var values: [String] = []
    if resolvedOwner(for: item) == nil {
      values.append("Choose a delivery assignee")
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

  private func duration(_ seconds: Int) -> String {
    if seconds < 60 {
      return "\(seconds)s"
    }
    if seconds < 3_600 {
      if seconds.isMultiple(of: 60) {
        return "\(seconds / 60)m"
      }
      return String(format: "%.1fm", Double(seconds) / 60)
    }
    let hours = Double(seconds) / 3_600
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
  var deliveryProfiles: [AgentProfile] = []
  var assigneeBinding: ((UUID) -> Binding<UUID?>)?

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
        SprintPlanningTicketRow(
          line: line,
          deliveryProfiles: deliveryProfiles,
          assigneeID: assigneeBinding?(line.item.id)
        )
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
  let deliveryProfiles: [AgentProfile]
  let assigneeID: Binding<UUID?>?

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
      if let assigneeID {
        Picker("Assignee", selection: assigneeID) {
          Text("Choose assignee")
            .tag(nil as UUID?)
          ForEach(deliveryProfiles) { profile in
            Label(profile.name, systemImage: profile.role.symbolName)
              .tag(Optional(profile.id))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 132, alignment: .leading)
        .help("Choose the team member who will deliver this ticket.")
      } else if let owner = line.owner {
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

private struct LegacySprintPlanningView: View {
  @EnvironmentObject private var model: AppModel
  @Binding var isPresented: Bool
  @State private var goal = ""
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
          Button("Save") {
            saveAndClose()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
        } else {
          Button("Save and close") {
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
      guard let item = readyItems.first(where: { $0.id == currentWorkItemID }) else { return }
      let comments = await model.comments(
        for: currentWorkItemID,
        productID: item.productID
      )
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
            Button(savingTicketItemID == item.id ? "Saving…" : "Save") {
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
        Label("Conversation", systemImage: "bubble.left.and.bubble.right")
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
              .padding(.bottom, 14)
              .id(bottomID)
          }
          .padding(.horizontal, 14)
          .padding(.top, 14)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
          if comments.isEmpty && pendingProposals[item.id] == nil {
            ConversationEmptyState(
              detail: "Ask for clarification or request a ticket review."
            )
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
        Text("Spedito will produce forecasts; you will not be asked to guess token budgets.")
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
          productID: item.productID,
          body: optimisticComment.body
        ) != nil
      else {
        conversationErrorsByItemID[item.id] = "Your message couldn't be saved. Try again."
        commentsByItemID[item.id] = await model.comments(
          for: item.id,
          productID: item.productID
        )
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
      commentsByItemID[item.id] = await model.comments(
        for: item.id,
        productID: item.productID
      )
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
        productID: item.productID,
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
          productID: item.productID,
          body: "Accepted \(pending.authorName)'s proposed ticket changes."
        )
        commentsByItemID[item.id] = await model.comments(
          for: item.id,
          productID: item.productID
        )
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
        productID: item.productID,
        body: "Rejected \(pending.authorName)'s proposed ticket changes."
      )
      commentsByItemID[item.id] = await model.comments(
        for: item.id,
        productID: item.productID
      )
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
        productID: item.productID,
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
          .foregroundStyle(.primary)
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

private struct TicketEpicLink: View {
  let epic: Epic
  @State private var selectedEpic: Epic?
  @State private var isHovered = false

  var body: some View {
    Button {
      selectedEpic = epic
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "flag.checkered")
          .font(.caption2)
          .foregroundStyle(.purple)

        Text("Epic")
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(epic.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)

        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(isHovered ? Color.purple : Color.secondary)
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .fixedSize(horizontal: true, vertical: false)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovered
        ? Color.purple.opacity(0.12)
        : Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(
          isHovered
            ? Color.purple.opacity(0.55)
            : Color(nsColor: .separatorColor).opacity(0.45),
          lineWidth: 1
        )
    }
    .onHover { isHovered = $0 }
    .help("Open \(epic.title) in Epic details")
    .sheet(item: $selectedEpic) { selectedEpic in
      EpicDetailView(epic: selectedEpic)
    }
  }
}

private struct AcceptanceCriterionDraft: Identifiable {
  let id = UUID()
  var text: String
}

private struct EpicDetailItemDraft: Identifiable {
  let id = UUID()
  var text: String
}

private struct FirstItemButton: View {
  let label: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(label, systemImage: systemImage)
        .font(.subheadline)
        .frame(maxWidth: .infinity, minHeight: 40)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(.separator.opacity(0.65), lineWidth: 1)
    }
  }
}

private struct EpicDetailItemsEditor: View {
  let title: String
  let guidance: String
  let addLabel: String
  let firstItemLabel: String
  let itemPrompt: String
  let systemImage: String
  @Binding var items: [EpicDetailItemDraft]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(items.count.formatted())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
        Spacer()
        Button {
          items.append(EpicDetailItemDraft(text: ""))
        } label: {
          Label(addLabel, systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Text(guidance)
        .font(.caption)
        .foregroundStyle(.secondary)

      if items.isEmpty {
        FirstItemButton(
          label: firstItemLabel,
          systemImage: systemImage
        ) {
          items.append(EpicDetailItemDraft(text: ""))
        }
      } else {
        VStack(spacing: 8) {
          ForEach($items) { $item in
            HStack(alignment: .center, spacing: 10) {
              Text("•")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 24)

              TextField(itemPrompt, text: $item.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)

              Button {
                items.removeAll { $0.id == item.id }
              } label: {
                Image(systemName: "xmark")
                  .frame(width: 20, height: 24)
              }
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .help("Remove item")
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
        FirstItemButton(
          label: "Add the first acceptance criterion",
          systemImage: "checklist"
        ) {
          criteria.append(AcceptanceCriterionDraft(text: ""))
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
  let onOpen: (UUID) -> Void

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
          Label("Blocked by", systemImage: "arrow.turn.up.left")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 10) {
          ForEach(selectedItems) { item in
            HStack(alignment: .top, spacing: 9) {
              Text("•")
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
              Button {
                onOpen(item.id)
              } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                  Text(item.key)
                    .font(.callout.monospaced().weight(.semibold))
                  Text("·")
                    .foregroundStyle(.tertiary)
                  Text(item.title)
                    .fixedSize(horizontal: false, vertical: true)
                  Image(systemName: "arrow.right")
                    .font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
              .foregroundStyle(Color.accentColor)
              .help("Open \(item.key) · \(item.title)")
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
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
  let productID: UUID
  let startRefinementOnAppear: Bool
  @State private var title: String
  @State private var type: WorkItemType
  @State private var bodyText: String
  @State private var criteria: [AcceptanceCriterionDraft]
  @State private var priority: WorkItemPriority
  @State private var blockerIDs: Set<UUID>
  @State private var customFields: [TicketCustomFieldDraft]
  @State private var assigneeID: UUID?
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
  @State private var selectedRelationshipTicket: WorkItem?

  init(
    item: WorkItem,
    dependsOnWorkItemIDs: Set<UUID>,
    startRefinementOnAppear: Bool = false
  ) {
    itemID = item.id
    productID = item.productID
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
    _assigneeID = State(initialValue: item.ownerProfileID)
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

  private var detailSize: CGSize {
    ConversationDetailSheetSizing.size(for: workspaceContainerSize)
  }

  private var conversationWidth: CGFloat {
    ConversationDetailSheetSizing.conversationWidth(for: detailSize.width)
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

  private var savedAssigneeID: UUID? {
    let plannedAssigneeID = model.candidateSprintPlan?.items
      .first { $0.workItemID == itemID }?
      .implementerProfileID
    return plannedAssigneeID ?? item?.ownerProfileID
  }

  private var deliveryProfiles: [AgentProfile] {
    model.profiles.filter(\.role.canOwnDelivery)
  }

  private var ticketFieldsHaveUnsavedChanges: Bool {
    currentDraftSnapshot != currentSavedSnapshot
      || blockerIDs != savedBlockerIDs
      || draftCustomFields != item?.customFields
  }

  private var assignmentHasUnsavedChanges: Bool {
    return assigneeID != savedAssigneeID
  }

  private var hasUnsavedChanges: Bool {
    ticketFieldsHaveUnsavedChanges || assignmentHasUnsavedChanges
  }

  private var parsedCriteria: [String] {
    criteria
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var isContextMissing: Bool {
    bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var needsInitialRefinement: Bool {
    guard let item else { return false }
    return item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || item.acceptanceCriteria.isEmpty
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
        Button("Close") { dismiss() }
      }
      .padding(.horizontal, 24)
      .frame(height: 62)

      Divider()

      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
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

            if
              let item,
              let epic = TicketEpicNavigation.destination(
                for: item,
                in: model.epics
              )
            {
              TicketEpicLink(epic: epic)
            }

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

              VStack(alignment: .leading, spacing: 7) {
                Text("Assignee")
                  .font(.subheadline.weight(.semibold))
                Picker("Assignee", selection: $assigneeID) {
                  Text("Choose assignee")
                    .tag(nil as UUID?)
                  ForEach(deliveryProfiles) { profile in
                    Label(profile.name, systemImage: profile.role.symbolName)
                      .tag(Optional(profile.id))
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(deliveryProfiles.isEmpty)
                .help("Choose the team member who will deliver this ticket.")
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

            AcceptanceCriteriaEditor(criteria: $criteria)

            relationshipSection
            customFieldSection
          }
          .padding(24)
          .disabled(isRefining)
        }
        .frame(maxWidth: .infinity)

        Divider()

        TicketConversationView(
          workItemID: itemID,
          productID: productID,
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
        Button(isSaving ? "Saving…" : "Save") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave)
      }
      .padding(.horizontal, 20)
      .frame(height: 62)
    }
    .frame(width: detailSize.width, height: detailSize.height)
    .background(InitialFocusClearer())
    .task {
      assigneeID = savedAssigneeID
      restoreTicketAssistantSession()
      await restorePendingRefinementQuestion()
      guard
        startRefinementOnAppear || needsInitialRefinement,
        !didStartInitialRefinement,
        refinementReply == nil,
        model.canRefineTicket
      else { return }
      didStartInitialRefinement = true
      startRefinement()
    }
    .onChange(of: model.canRefineTicket) { _, canRefine in
      guard
        startRefinementOnAppear || needsInitialRefinement,
        canRefine,
        !didStartInitialRefinement,
        refinementReply == nil,
        !hasUnsavedChanges
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
    .sheet(item: $selectedRelationshipTicket) { relatedItem in
      TicketDetailView(
        item: relatedItem,
        dependsOnWorkItemIDs: Set(
          model.dependencies
            .filter { $0.workItemID == relatedItem.id }
            .map(\.dependsOnWorkItemID)
        )
      )
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
    refinementError = result.errorMessage
    if
      result.errorMessage == nil,
      result.reply?.proposal.missingQuestions.isEmpty == true
    {
      syncFromLatestSavedTicket()
      refinementReply = nil
      refinementConflictMessage = nil
      return
    }
    refinementReply = result.reply
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

  private func syncFromLatestSavedTicket() {
    guard let latest = item else { return }
    title = latest.title
    type = latest.type
    bodyText = latest.body
    criteria = latest.acceptanceCriteria.map(AcceptanceCriterionDraft.init(text:))
    priority = latest.priority
    blockerIDs = savedBlockerIDs
    customFields = latest.customFields.keys.sorted().map {
      TicketCustomFieldDraft(name: $0, value: latest.customFields[$0] ?? "")
    }
    assigneeID = savedAssigneeID
    acceptedRefinementFields.removeAll()
    expandedRefinementFields.removeAll()
    dismissedDependencyKeys.removeAll()
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

    let comments = await model.comments(for: item.id, productID: item.productID)
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
        Button {
          startRefinement()
        } label: {
          Label("Try again", systemImage: "wand.and.stars")
        }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
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
    SprintTicketSectionCard(title: "Relationships") {
      VStack(alignment: .leading, spacing: 14) {
        Text("Blockers affect backlog order and sprint readiness.")
          .font(.caption)
          .foregroundStyle(.secondary)

        TicketBlockerEditor(
          selectedIDs: $blockerIDs,
          excludingWorkItemID: itemID,
          onOpen: openRelationship
        )

        let blockedItems = model.dependencies
          .filter { $0.dependsOnWorkItemID == itemID }
          .compactMap { edge in
            model.workItems.first { $0.id == edge.workItemID }
          }
        if !blockedItems.isEmpty {
          Divider()
          TicketDetailRelationshipRow(
            group: TicketDetailRelationshipGroup(
              id: "blocks",
              title: "Blocks",
              symbol: "link",
              items: blockedItems.map(TicketDetailRelationshipItem.init(workItem:))
            ),
            onOpenRelationship: openRelationship
          )
        }
      }
    }
  }

  private func openRelationship(_ relationshipID: UUID) {
    guard let item else { return }
    selectedRelationshipTicket = TicketRelationshipNavigation.destination(
      for: relationshipID,
      source: item,
      in: model.workItems
    )
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
      if reply.proposal.missingQuestions.isEmpty {
        syncFromLatestSavedTicket()
        refinementReply = nil
        refinementConflictMessage = nil
      } else if currentDraftSnapshot != base {
        refinementReply = reply
        refinementConflictMessage =
          "You edited the ticket while the review was running. Save those edits and run a fresh review before accepting suggestions."
      } else if model.workItems.first(where: { $0.id == item.id })?.version
        != reply.proposal.baseVersion
      {
        refinementReply = reply
        refinementConflictMessage =
          "The saved ticket changed while the review was running. Run a fresh review before accepting suggestions."
      } else {
        refinementReply = reply
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
    let shouldSaveTicketFields = ticketFieldsHaveUnsavedChanges
    let shouldSaveAssignment = assignmentHasUnsavedChanges
    let selectedAssigneeID = assigneeID
    Task {
      var saved = true
      if shouldSaveTicketFields {
        saved = await model.updateWorkItem(
          productID: productID,
          id: itemID,
          title: title,
          type: type,
          body: bodyText,
          acceptanceCriteria: parsedCriteria,
          priority: priority,
          customFields: draftCustomFields,
          dependsOnWorkItemIDs: blockerIDs
        )
      }
      if saved, shouldSaveAssignment {
        saved = await model.assignTicketOwner(
          productID: productID,
          workItemID: itemID,
          to: selectedAssigneeID
        )
      }
      isSaving = false
      if saved {
        model.dismissTicketAssistantResult(workItemID: itemID)
        dismiss()
      }
    }
  }
}

enum TicketConversationHistory {
  static func displayedComments(
    from comments: [TicketComment],
    pendingQuestionID: UUID?,
    analystName: String?
  ) -> [TicketComment] {
    var displayed: [TicketComment] = []
    let explicitlyAnsweredQuestions = Set(
      comments.flatMap { comment in
        comment.answeredQuestions.map(\.question)
      }
    )

    for comment in comments where comment.id != pendingQuestionID {
      var presentedComment = comment
      var answeredQuestions = comment.answeredQuestions

      if answeredQuestions.isEmpty,
        comment.authorKind == .owner,
        let analystName,
        let questionComment = displayed.last,
        questionComment.authorKind == .agent,
        questionComment.authorName == analystName
      {
        let questions = TicketRefinementQuestion.parseTicketCommentBody(
          questionComment.body
        )
        if questions.allSatisfy({ !explicitlyAnsweredQuestions.contains($0) }) {
          answeredQuestions = inferredAnswers(
            to: questions,
            from: comment.body,
            analystName: analystName
          )
        }
        if !answeredQuestions.isEmpty {
          presentedComment = TicketComment(
            id: comment.id,
            workItemID: comment.workItemID,
            authorKind: comment.authorKind,
            authorName: comment.authorName,
            body: comment.body,
            ownerQuestion: comment.ownerQuestion,
            answeredQuestions: answeredQuestions,
            createdAt: comment.createdAt
          )
        }
      }

      if
        !answeredQuestions.isEmpty,
        let analystName,
        let questionIndex = displayed.lastIndex(where: { comment in
          guard
            comment.authorKind == .agent,
            comment.authorName == analystName
          else { return false }
          return TicketRefinementQuestion.parseTicketCommentBody(comment.body)
            == answeredQuestions.map(\.question)
        })
      {
        displayed.remove(at: questionIndex)
      }

      displayed.append(presentedComment)
    }

    return displayed
  }

  static func pendingQuestionInsertionIndex(
    in displayedComments: [TicketComment],
    sourceComments: [TicketComment],
    pendingQuestionID: UUID
  ) -> Int? {
    guard
      let questionIndex = sourceComments.firstIndex(where: {
        $0.id == pendingQuestionID
      })
    else { return nil }

    let laterCommentIDs = Set(
      sourceComments[sourceComments.index(after: questionIndex)...].map(\.id)
    )
    return displayedComments.firstIndex(where: {
      laterCommentIDs.contains($0.id)
    }) ?? displayedComments.endIndex
  }

  private static func inferredAnswers(
    to questions: [TicketRefinementQuestion],
    from ownerCommentBody: String,
    analystName: String
  ) -> [TicketAnsweredQuestion] {
    guard !questions.isEmpty else { return [] }
    let mention = "@\(analystName) "
    guard ownerCommentBody.hasPrefix(mention) else { return [] }
    let response = String(ownerCommentBody.dropFirst(mention.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !response.isEmpty else { return [] }

    let answers: [String]
    if questions.count == 1 {
      answers = [response]
    } else {
      let lines = response.components(separatedBy: .newlines)
      guard lines.count == questions.count else { return [] }
      answers = lines.enumerated().compactMap { index, line in
        let prefix = "\(index + 1). "
        guard line.hasPrefix(prefix) else { return nil }
        let answer = String(line.dropFirst(prefix.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
      }
      guard answers.count == questions.count else { return [] }
    }

    return zip(questions, answers).map { question, answer in
      TicketAnsweredQuestion(
        question: question,
        selectedOption: question.options.contains(answer) ? answer : nil,
        answer: answer
      )
    }
  }
}

private struct ConversationEmptyState: View {
  let detail: String

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.title3)
        .foregroundStyle(.tertiary)
      Text("No messages yet")
        .font(.subheadline.weight(.medium))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct TeamConversationComposer: View {
  let profiles: [AgentProfile]
  @Binding var recipientID: UUID?
  @Binding var message: String
  let isSending: Bool
  let isResponding: Bool
  let sendError: String?
  let onSend: () -> Void
  var allowsRecipientSelection = true
  @FocusState private var isFocused: Bool

  private var selectedRecipient: AgentProfile? {
    guard let recipientID else { return nil }
    return profiles.first { $0.id == recipientID }
  }

  private var canSend: Bool {
    selectedRecipient != nil
      && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSending
      && !isResponding
  }

  private func recipientLabel(showsDisclosureIndicator: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: selectedRecipient?.role.symbolName ?? "person")
        .foregroundStyle(selectedRecipient?.role.tint ?? Color.secondary)
      Text(selectedRecipient?.name ?? "Choose a team member")
        .foregroundStyle(selectedRecipient?.role.tint ?? Color.secondary)
      if showsDisclosureIndicator {
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(
      (selectedRecipient?.role.tint ?? Color.secondary).opacity(0.1),
      in: Capsule()
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("To")
          .font(.caption)
          .foregroundStyle(.secondary)
        if allowsRecipientSelection {
          Menu {
            ForEach(profiles) { profile in
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
            recipientLabel(showsDisclosureIndicator: true)
          }
          .menuStyle(.borderlessButton)
        } else {
          recipientLabel(showsDisclosureIndicator: false)
            .help("Replies stay with this thread's team member")
        }
        Spacer()
      }

      if let sendError {
        Label(sendError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      ZStack(alignment: .topLeading) {
        if message.isEmpty && !isFocused {
          Text("Ask a question or discuss a change…")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }
        TextEditor(text: $message)
          .scrollContentBackground(.hidden)
          .font(.body)
          .focused($isFocused)
          .padding(8)
          .onKeyPress(phases: .down) { keyPress in
            guard keyPress.key == .return else {
              return .ignored
            }
            if keyPress.modifiers.contains(.shift) {
              return .ignored
            }
            if canSend {
              onSend()
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
        Button(isSending ? "Sending…" : "Send", action: onSend)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(!canSend)
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.25))
  }
}

private struct ConversationRespondingStatus: View {
  let profile: AgentProfile?
  let fallbackName: String
  let status: String
  var activity: CodexLiveActivity? = nil
  let onStop: () -> Void

  var body: some View {
    let tint = profile?.role.tint ?? Color.purple
    HStack(spacing: 7) {
      if let activity {
        Image(systemName: activity.kind.symbolName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
          .frame(width: 14)
      } else {
        ProgressView()
          .controlSize(.mini)
          .tint(tint)
      }
      HStack(spacing: 0) {
        Text(profile?.name ?? fallbackName)
          .fontWeight(.semibold)
          .foregroundStyle(tint)
        Text(activity.map { " · \($0.text)" } ?? " \(status)")
          .foregroundStyle(.primary)
      }
      .font(.caption)
      .lineLimit(2)
      Spacer()
      Button("Stop", action: onStop)
        .controlSize(.mini)
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
    .background(tint.opacity(0.075))
  }
}

private struct TicketConversationView<ReviewContent: View>: View {
  @EnvironmentObject private var model: AppModel
  let workItemID: UUID
  let productID: UUID
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

  private var otherChoiceKey: String { "\u{0}other" }

  private var canSubmitRefinementAnswers: Bool {
    !refinementQuestions.isEmpty
      && businessAnalyst != nil
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
    TicketConversationHistory.displayedComments(
      from: comments,
      pendingQuestionID: pendingRefinementComment?.id,
      analystName: businessAnalyst?.name
    )
  }

  private var pendingRefinementComment: TicketComment? {
    guard
      isShowingRefinementChoices,
      let analystName = businessAnalyst?.name
    else { return nil }
    return comments.last { comment in
      comment.authorKind == .agent
        && comment.authorName == analystName
        && TicketRefinementQuestion.parseTicketCommentBody(comment.body)
          == refinementQuestions
    }
  }

  private var pendingRefinementInsertionIndex: Int? {
    guard let pendingRefinementComment else { return nil }
    return TicketConversationHistory.pendingQuestionInsertionIndex(
      in: displayedComments,
      sourceComments: comments,
      pendingQuestionID: pendingRefinementComment.id
    )
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
        Label("Conversation", systemImage: "bubble.left.and.bubble.right")
          .font(.headline)
        Spacer()
      }
      .padding(16)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(displayedComments.enumerated()), id: \.element.id) {
              index,
              comment in
              if pendingRefinementInsertionIndex == index {
                refinementQuestionCards
              }

              if comment.answeredQuestions.isEmpty {
                TicketCommentBubble(
                  comment: comment,
                  authorProfile: model.profiles.first { $0.name == comment.authorName },
                  mentionedProfile: mentionedProfile(
                    in: comment.body,
                    profiles: model.profiles
                  )
                )
              } else {
                answeredRefinementQuestionCards(
                  comment.answeredQuestions,
                  createdAt: comment.createdAt
                )
              }
            }

            if
              isShowingRefinementChoices,
              pendingRefinementInsertionIndex == nil
                || pendingRefinementInsertionIndex == displayedComments.endIndex
            {
              refinementQuestionCards
            }

            if showsReview {
              reviewContent
            }

            Color.clear
              .frame(height: 1)
              .padding(.bottom, 14)
              .id("ticket-conversation-bottom")
          }
          .padding(.horizontal, 14)
          .padding(.top, 14)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
          if showsEmptyConversation {
            ConversationEmptyState(
              detail: "Ask for clarification or request a ticket review."
            )
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
            .foregroundStyle(.primary)
          }
          .font(.caption)
          Spacer()
          Button {
            submitRefinementAnswers()
          } label: {
            Label("Submit answers", systemImage: "paperplane.fill")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
          .disabled(!canSubmitRefinementAnswers)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(tint.opacity(0.075))
      } else if isAnyAgentResponding {
        let teammate = activeStatusProfile ?? businessAnalyst
        ConversationRespondingStatus(
          profile: teammate,
          fallbackName: "Business Analyst",
          status:
            isAgentResponding
            ? isAwaitingRefinementAnswer
              ? "is reviewing your response…"
              : "is reviewing this ticket…"
            : "is thinking…",
          activity:
            isAgentResponding
            ? nil
            : model.ticketConversationActivity,
          onStop: {
            if isAgentResponding {
              onStopRefinement()
            } else {
              model.cancelTicketConversationMessage()
            }
          }
        )
      }

      TeamConversationComposer(
        profiles: model.profiles,
        recipientID: $recipientID,
        message: $message,
        isSending: isSending,
        isResponding: isAnyAgentResponding,
        sendError: sendError,
        onSend: send
      )
    }
    .task(id: refreshToken) {
      comments = await model.comments(for: workItemID, productID: productID)
      if recipientID == nil {
        recipientID = defaultRecipient?.id
      }
    }
    .onChange(of: model.ticketConversationWorkItemID) { previousID, currentID in
      guard previousID == workItemID || currentID == workItemID else { return }
      Task {
        comments = await model.comments(for: workItemID, productID: productID)
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

  private func answeredRefinementQuestionCards(
    _ answeredQuestions: [TicketAnsweredQuestion],
    createdAt: Date
  ) -> some View {
    let tint = businessAnalyst?.role.tint ?? Color.purple
    return HStack(alignment: .top, spacing: 9) {
      ZStack {
        Circle()
          .fill(tint.opacity(0.12))
        Image(systemName: "checkmark")
          .font(.caption2.weight(.bold))
          .foregroundStyle(tint)
      }
      .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Text("Answered")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
          Text(createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        VStack(alignment: .leading, spacing: 9) {
          ForEach(Array(answeredQuestions.enumerated()), id: \.offset) {
            index,
            answered in
            VStack(alignment: .leading, spacing: 9) {
              if answeredQuestions.count > 1 {
                Text("Question \(index + 1) of \(answeredQuestions.count)")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(tint)
              }
              Text(answered.question.prompt)
                .font(.callout.weight(.medium))

              VStack(spacing: 6) {
                ForEach(answered.question.options, id: \.self) { option in
                  readOnlyRefinementChoiceRow(
                    option,
                    tint: tint,
                    isSelected: answered.selectedOption == option
                  )
                }
                readOnlyRefinementChoiceRow(
                  "Other",
                  tint: tint,
                  isSelected: answered.selectedOption == nil
                )
              }

              if answered.selectedOption == nil {
                Text(answered.answer)
                  .font(.callout)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .background(
                    tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8)
                  )
              }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
          }
        }
        .frame(maxWidth: 380, alignment: .leading)
      }
      Spacer(minLength: 36)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func readOnlyRefinementChoiceRow(
    _ label: String,
    tint: Color,
    isSelected: Bool
  ) -> some View {
    HStack(spacing: 9) {
      Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
        .font(.caption)
        .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.65))
      Text(label)
        .font(.callout)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .multilineTextAlignment(.leading)
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      isSelected ? tint.opacity(0.14) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 8)
    )
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
    let answeredQuestions = refinementQuestions.enumerated().map { index, question in
      let selection = selectedRefinementOptions[index] ?? ""
      let answer =
        selection == otherChoiceKey
        ? (otherRefinementAnswers[index] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        : selection
      return TicketAnsweredQuestion(
        question: question,
        selectedOption: selection == otherChoiceKey ? nil : selection,
        answer: answer
      )
    }
    let selectedAnswers = answeredQuestions.map(\.answer)
    let answer =
      selectedAnswers.count == 1
      ? selectedAnswers[0]
      : selectedAnswers.enumerated().map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")
    guard let businessAnalyst else { return }
    hasSubmittedRefinementAnswers = true
    isSending = true
    sendError = nil
    Task {
      let body = "@\(businessAnalyst.name) \(answer)"
      if let comment = await model.appendOwnerComment(
        workItemID: workItemID,
        productID: productID,
        body: body,
        answeredQuestions: answeredQuestions
      ) {
        comments.append(comment)
        await onRefinementAnswer?(answer)
        comments = await model.comments(for: workItemID, productID: productID)
      } else {
        sendError = model.errorMessage ?? "Your answers couldn't be saved. Try again."
        hasSubmittedRefinementAnswers = false
      }
      isSending = false
    }
  }

  private func send() {
    let ownerMessage = message
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let recipient = selectedRecipient,
      !ownerMessage.isEmpty,
      !isSending,
      !isAnyAgentResponding
    else { return }
    isSending = true
    sendError = nil
    respondingRecipientID = recipient.id
    let body = "@\(recipient.name) \(ownerMessage)"
    Task {
      if let comment = await model.appendOwnerComment(
        workItemID: workItemID,
        productID: productID,
        body: body
      ) {
        comments.append(comment)
        message = ""
        if let savedItem = model.workItems.first(where: { $0.id == workItemID }) {
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
        comments = await model.comments(for: workItemID, productID: productID)
      } else {
        sendError = model.errorMessage ?? "Your message couldn't be saved. Try again."
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

private enum ConversationPalette {
  static let owner = Color(nsColor: .secondaryLabelColor)
}

private struct TeamConversationMessageBubble: View {
  let authorKind: CommentAuthorKind
  let authorName: String
  let messageBody: String
  let createdAt: Date
  let authorProfile: AgentProfile?
  let mentionedProfile: AgentProfile?

  init(
    authorKind: CommentAuthorKind,
    authorName: String,
    body: String,
    createdAt: Date,
    authorProfile: AgentProfile? = nil,
    mentionedProfile: AgentProfile? = nil
  ) {
    self.authorKind = authorKind
    self.authorName = authorName
    messageBody = body
    self.createdAt = createdAt
    self.authorProfile = authorProfile
    self.mentionedProfile = mentionedProfile
  }

  private var accent: Color {
    switch authorKind {
    case .owner: ConversationPalette.owner
    case .agent: authorProfile?.role.tint ?? .indigo
    case .system: .secondary
    }
  }

  private var symbolName: String {
    switch authorKind {
    case .owner: "person.fill"
    case .agent: authorProfile?.role.symbolName ?? "sparkles"
    case .system: "gearshape.fill"
    }
  }

  private var displayName: String {
    authorKind == .owner ? "Me" : authorName
  }

  private var isOwner: Bool {
    authorKind == .owner
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

  private var messageDocument: some View {
    TicketMarkdownDocument(
      source: messageBody,
      baseFont: .callout,
      highlightedText: mentionedProfile.map { "@\($0.name)" },
      highlightedColor: mentionedProfile?.role.tint
    )
  }

  private var messageContent: some View {
    VStack(alignment: isOwner ? .trailing : .leading, spacing: 5) {
      HStack(spacing: 7) {
        if isOwner {
          Text(createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
        } else {
          Text(displayName)
            .font(
              authorKind == .agent
                ? .subheadline.weight(.semibold)
                : .caption.weight(.semibold)
            )
            .foregroundStyle(authorKind == .agent ? accent : Color.primary)
          if authorKind == .agent, let authorProfile {
            Image(systemName: authorProfile.role.symbolName)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(accent)
              .help(authorProfile.role.capabilityTitle)
          }
          Text(createdAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      ViewThatFits(in: .horizontal) {
        messageDocument
          .fixedSize(horizontal: true, vertical: true)
        messageDocument
      }
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 560, alignment: isOwner ? .trailing : .leading)
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

  var body: some View {
    TeamConversationMessageBubble(
      authorKind: comment.authorKind,
      authorName: comment.authorName,
      body: comment.body,
      createdAt: comment.createdAt,
      authorProfile: authorProfile,
      mentionedProfile: mentionedProfile
    )
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
        Text("Describe the outcome. The Business Analyst will shape the ticket for your review.")
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
            minHeight: 138,
            focusOnAppear: true
          )

          VStack(alignment: .leading, spacing: 7) {
            Text("Epic")
              .font(.subheadline.weight(.semibold))
            Picker("Epic", selection: $selectedEpicID) {
              Text("No epic").tag(UUID?.none)
              ForEach(model.openEpics) { epic in
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
              : "The ticket is saved as a draft. The Business Analyst review starts automatically when the team connection becomes available.",
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
        onCreated(item, true)
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
        onClose: { isPresented = false }
      )
    } else {
      captureView
    }
  }

  private var captureView: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New epic")
          .font(.title.bold())
        Text(
          "Describe the outcome. The Business Analyst will shape the epic and its tickets for your review."
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
          minHeight: 150,
          focusOnAppear: true
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
  @Environment(\.workspaceContainerSize) private var workspaceContainerSize
  let epic: Epic
  let onClose: (() -> Void)?
  @State private var title: String
  @State private var goal: String
  @State private var successCriteria: [EpicDetailItemDraft]
  @State private var constraints: [EpicDetailItemDraft]
  @State private var isSaving = false
  @State private var didStartPlanning = false
  @State private var selectedTicket: WorkItem?
  @State private var selectedSuggestion: TicketSuggestion?

  init(
    epic: Epic,
    onClose: (() -> Void)? = nil
  ) {
    self.epic = epic
    self.onClose = onClose
    _title = State(initialValue: epic.title)
    _goal = State(initialValue: epic.goal)
    _successCriteria = State(
      initialValue: epic.successCriteria.map(EpicDetailItemDraft.init(text:))
    )
    _constraints = State(
      initialValue: Self.itemDrafts(from: epic.constraints)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "flag.checkered")
          .foregroundStyle(.purple)
        Text("Epic details")
          .font(.title2.bold())
        Spacer()
        Button("Close", action: close)
      }
      .padding(22)
      Divider()

      HStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
              EditableTextField(title: "Title", prompt: "Epic title", text: $title)
                .disabled(isReadOnly)
              VStack(alignment: .leading, spacing: 7) {
                Text("Status")
                  .font(.subheadline.weight(.semibold))
                Text(displayStatus)
                  .font(.callout.weight(.semibold))
                  .foregroundStyle(displayStatusColor)
                  .padding(.vertical, 5)
              }
              .frame(width: 130, alignment: .leading)
            }
            EditableTextArea(
              title: "Goal and customer value",
              prompt: "What outcome should this epic create?",
              text: $goal,
              minHeight: 110,
              isReadOnly: isReadOnly
            )
            EpicDetailItemsEditor(
              title: "Success criteria",
              guidance: "Each item should describe one measurable product outcome.",
              addLabel: "Add criterion",
              firstItemLabel: "Add the first success criterion",
              itemPrompt: "Describe a measurable outcome",
              systemImage: "checklist",
              items: $successCriteria
            )
            .disabled(isReadOnly)
            EpicDetailItemsEditor(
              title: "Constraints and context",
              guidance: "Capture each material constraint, assumption, or relevant fact separately.",
              addLabel: "Add item",
              firstItemLabel: "Add the first constraint or context item",
              itemPrompt: "Describe a constraint, assumption, or relevant fact",
              systemImage: "slider.horizontal.3",
              items: $constraints
            )
            .disabled(isReadOnly)
            EpicTicketsSection(
              epic: latestEpic,
              tickets: activeEpicTickets,
              archivedCount: archivedEpicTicketCount,
              suggestionBatch: epicSuggestionBatch,
              isGeneratingSuggestions:
                conversation?.isGeneratingPlan == true
                || epicSuggestionBatch?.session.status == .generating,
              onOpen: { selectedTicket = $0 },
              onOpenSuggestion: { selectedSuggestion = $0 }
            )
          }
          .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()

        EpicPlanningConversationPanel(epic: latestEpic)
          .frame(width: conversationWidth)
          .frame(maxHeight: .infinity)
      }
      .frame(maxHeight: .infinity)
      .clipped()

      Divider()
      HStack {
        Text(footerStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if isClosed {
          Button {
            reopenEpic()
          } label: {
            Label(
              isSaving ? "Reopening…" : "Reopen epic",
              systemImage: "arrow.uturn.backward.circle"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSaving)
          .help("Return this epic to active planning")
        } else if canCloseEpic {
          Button {
            confirmCloseEpic()
          } label: {
            Label(
              isSaving
                ? "Closing…"
                : (hasUnsavedChanges ? "Save and close epic" : "Close epic"),
              systemImage: "checkmark.circle.fill"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSaving || (hasUnsavedChanges && !canSave))
          .help("Confirm that this epic's outcome has been delivered")
        } else if hasUnsavedChanges {
          Button("Save") { save() }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
        } else if !proposedEpicSuggestions.isEmpty {
          Button("Review tickets in backlog") {
            close()
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(18)
    }
    .background(InitialFocusClearer())
    .frame(width: detailSize.width, height: detailSize.height)
    .task(id: epic.id) {
      await model.restoreEpicPlanningConversation(for: epic)
      startPlanningIfNeeded()
    }
    .onChange(of: model.canPlanEpic) { _, _ in
      startPlanningIfNeeded()
    }
    .onChange(of: conversation?.isComplete == true) { _, isComplete in
      guard isComplete else { return }
      syncFromLatestEpic()
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
    .sheet(item: $selectedSuggestion) { suggestion in
      if let batch = epicSuggestionBatch {
        TicketSuggestionDetailView(
          suggestion: suggestion,
          batch: batch,
          onClose: { selectedSuggestion = nil }
        )
      }
    }
  }

  private var conversation: EpicPlanningConversationState? {
    guard model.epicPlanningConversation?.epicID == epic.id else { return nil }
    return model.epicPlanningConversation
  }

  private var detailSize: CGSize {
    ConversationDetailSheetSizing.size(for: workspaceContainerSize)
  }

  private var conversationWidth: CGFloat {
    ConversationDetailSheetSizing.conversationWidth(for: detailSize.width)
  }

  private var needsInitialPlanning: Bool {
    conversation?.hasStartedPlanning != true
      && latestEpic.successCriteria.isEmpty
      && activeEpicTickets.isEmpty
      && proposedEpicSuggestions.isEmpty
  }

  private var canSave: Bool {
    isOpen
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var latestEpic: Epic {
    model.epics.first(where: { $0.id == epic.id }) ?? epic
  }

  private var isArchived: Bool {
    latestEpic.status == .archived
  }

  private var isClosed: Bool {
    latestEpic.status == .closed
  }

  private var isOpen: Bool {
    latestEpic.status == .open
  }

  private var isReadOnly: Bool {
    !isOpen
  }

  private var progress: EpicProgress {
    EpicProgress(tickets: activeEpicTickets)
  }

  private var displayStatus: String {
    isOpen ? progress.title : latestEpic.status.title
  }

  private var displayStatusColor: Color {
    switch latestEpic.status {
    case .closed:
      return .green
    case .archived:
      return .secondary
    case .open:
      switch progress {
      case .created: return .secondary
      case .planned: return .blue
      case .inProgress: return .orange
      case .complete: return .green
      }
    }
  }

  private var hasUnsavedChanges: Bool {
    title != latestEpic.title
      || goal != latestEpic.goal
      || criteria != latestEpic.successCriteria
      || constraintsText != latestEpic.constraints
  }

  private var criteria: [String] {
    successCriteria
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var constraintsText: String {
    constraints
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private var epicSuggestionBatch: TicketSuggestionBatch? {
    guard model.suggestionBatch?.session.epicID == epic.id else { return nil }
    return model.suggestionBatch
  }

  private var proposedEpicSuggestions: [TicketSuggestion] {
    epicSuggestionBatch?.suggestions
      .filter { $0.status == .proposed }
      .sorted { $0.position < $1.position } ?? []
  }

  private var canCloseEpic: Bool {
    isOpen
      && progress == .complete
      && proposedEpicSuggestions.isEmpty
      && conversation?.isRunning != true
      && conversation?.isGeneratingPlan != true
      && epicSuggestionBatch?.session.status != .generating
  }

  private var footerStatus: String {
    if isArchived {
      return "This archived epic is available as read-only delivery history."
    }
    if isClosed {
      return "The epic outcome is confirmed and available as read-only delivery history."
    }
    if conversation?.isRunning == true
      || conversation?.isGeneratingPlan == true
      || epicSuggestionBatch?.session.status == .generating
    {
      return "The Business Analyst is preparing the proposed ticket plan."
    }
    if progress == .complete, !proposedEpicSuggestions.isEmpty {
      return "All accepted tickets are delivered. Review the remaining proposals before closing."
    }
    if progress == .complete {
      return "All accepted tickets are delivered. Close the epic to confirm its outcome."
    }
    let count = proposedEpicSuggestions.count
    if count > 0 {
      return "\(count) proposed \(count == 1 ? "ticket needs" : "tickets need") review in Tickets."
    }
    if conversation?.isComplete == true {
      return "The epic plan is up to date."
    }
    switch progress {
    case .created:
      return "Resolve the outcome with the Business Analyst before tickets are proposed."
    case .planned:
      return "Tickets are planned and delivery has not started."
    case .inProgress:
      return "Delivery is in progress."
    case .complete:
      return "All accepted tickets are delivered. Close the epic to confirm its outcome."
    }
  }

  private var activeEpicTickets: [WorkItem] {
    model.workItems.filter {
      $0.epicID == epic.id && $0.state != .cancelled
    }
  }

  private var archivedEpicTicketCount: Int {
    model.workItems.filter {
      $0.epicID == epic.id && $0.state == .cancelled
    }.count
  }

  private func close() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }

  private func startPlanningIfNeeded() {
    guard
      !didStartPlanning,
      isOpen,
      needsInitialPlanning,
      model.canPlanEpic
    else { return }
    didStartPlanning = true
    model.planEpic(latestEpic)
  }

  private func save() {
    guard canSave else { return }
    isSaving = true
    Task {
      let updated = await model.updateEpic(
        epic,
        title: title,
        goal: goal,
        successCriteria: criteria,
        constraints: constraintsText
      )
      isSaving = false
      if updated != nil {
        close()
      }
    }
  }

  private func confirmCloseEpic() {
    guard canCloseEpic else { return }
    isSaving = true
    Task {
      var epicToClose: Epic? = latestEpic
      if hasUnsavedChanges {
        epicToClose = await model.updateEpic(
          epic,
          title: title,
          goal: goal,
          successCriteria: criteria,
          constraints: constraintsText
        )
      }
      let updated: Epic? =
        if let epicToClose {
          await model.closeEpic(epicToClose)
        } else {
          nil
        }
      isSaving = false
      if updated != nil {
        close()
      }
    }
  }

  private func reopenEpic() {
    guard isClosed else { return }
    isSaving = true
    Task {
      let updated = await model.reopenEpic(latestEpic)
      isSaving = false
      if updated != nil {
        syncFromLatestEpic()
      }
    }
  }

  private func syncFromLatestEpic() {
    guard let latest = model.epics.first(where: { $0.id == epic.id }) else { return }
    title = latest.title
    goal = latest.goal
    successCriteria = latest.successCriteria.map(EpicDetailItemDraft.init(text:))
    constraints = Self.itemDrafts(from: latest.constraints)
  }

  private static func itemDrafts(from text: String) -> [EpicDetailItemDraft] {
    text
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(EpicDetailItemDraft.init(text:))
  }

}

private struct EpicTicketsSection: View {
  @EnvironmentObject private var model: AppModel
  let epic: Epic
  let tickets: [WorkItem]
  let archivedCount: Int
  let suggestionBatch: TicketSuggestionBatch?
  let isGeneratingSuggestions: Bool
  let onOpen: (WorkItem) -> Void
  let onOpenSuggestion: (TicketSuggestion) -> Void
  @State private var hoveredTicketID: UUID?
  @State private var hoveredSuggestionID: UUID?

  private var deliveredCount: Int {
    tickets.filter { $0.state == .released }.count
  }

  private var allDelivered: Bool {
    !tickets.isEmpty && deliveredCount == tickets.count
  }

  private var proposedSuggestions: [TicketSuggestion] {
    suggestionBatch?.suggestions
      .filter { $0.status == .proposed }
      .sorted { $0.position < $1.position } ?? []
  }

  private var visibleTicketCount: Int {
    tickets.count + proposedSuggestions.count
  }

  private let statusColumnWidth: CGFloat = 108
  private let ownerColumnWidth: CGFloat = 128
  private let tableRowHeight = PlanningTicketTableMetrics.rowHeight

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        Text("Tickets")
          .font(.headline)
        Text(visibleTicketCount.formatted())
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        if archivedCount > 0 {
          Text("\(archivedCount) archived")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !proposedSuggestions.isEmpty {
          TicketSuggestionBatchActions(suggestions: proposedSuggestions)
        } else if allDelivered {
          Label(
            epic.status == .closed ? "Outcome confirmed" : "Complete",
            systemImage: "checkmark.circle.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
        } else if !tickets.isEmpty {
          Text("\(deliveredCount) of \(tickets.count) delivered")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Text("Ticket")
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text("Status")
            .padding(.horizontal, 8)
            .frame(width: statusColumnWidth, alignment: .leading)
          Text("Owner")
            .padding(.horizontal, 8)
            .frame(width: ownerColumnWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: 32)

        Divider()

        if isGeneratingSuggestions && proposedSuggestions.isEmpty {
          ForEach(0..<3, id: \.self) { index in
            proposedTicketPlaceholder(index: index)
            if index < 2 {
              Divider()
            }
          }
        } else if tickets.isEmpty && proposedSuggestions.isEmpty {
          VStack(spacing: 5) {
            Text(archivedCount > 0 ? "No active tickets" : "No tickets yet")
              .font(.subheadline.weight(.medium))
            Text(
              archivedCount > 0
                ? "Archived tickets no longer count towards this epic."
                : "The Business Analyst can propose the work needed for this outcome."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 74)
        } else {
          ForEach(Array(proposedSuggestions.enumerated()), id: \.element.id) {
            index,
            suggestion in
            proposedTicketRow(suggestion)
            if index < proposedSuggestions.count - 1 || !tickets.isEmpty {
              Divider()
            }
          }

          ForEach(Array(tickets.enumerated()), id: \.element.id) { index, ticket in
            ticketRow(ticket)
            if index < tickets.count - 1 {
              Divider()
            }
          }
        }
      }
      .background(Color.secondary.opacity(0.035))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
      }

      if allDelivered, epic.status == .open {
        Text(
          "All accepted tickets are delivered. Confirm the product outcome, then close this epic."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func proposedTicketPlaceholder(index: Int) -> some View {
    HStack(spacing: 0) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.mini)
          .tint(.purple)
        TicketSuggestionPlaceholderLines(
          primaryWidth: index == 1 ? 150 : 190,
          secondaryWidth: index == 2 ? 100 : 130
        )
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      Text("Preparing")
        .padding(.horizontal, 8)
        .foregroundStyle(.purple)
        .frame(width: statusColumnWidth, alignment: .leading)

      Text("Business Analyst")
        .padding(.horizontal, 8)
        .foregroundStyle(.secondary)
        .frame(width: ownerColumnWidth, alignment: .leading)
    }
    .font(.caption)
    .frame(minHeight: tableRowHeight)
  }

  private func proposedTicketRow(_ suggestion: TicketSuggestion) -> some View {
    let isHovering = hoveredSuggestionID == suggestion.id
    return HStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: suggestion.type.symbolName)
          .foregroundStyle(suggestion.type.tint)
          .frame(width: 16)
        Text(suggestion.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isHovering ? Color.purple : Color.primary)
          .lineLimit(2)
          .layoutPriority(1)
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      Label("Proposed", systemImage: "wand.and.stars")
        .font(.caption.weight(.medium))
        .foregroundStyle(.purple)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: statusColumnWidth, alignment: .leading)

      Label(suggestion.suggestedRole.title, systemImage: suggestion.suggestedRole.symbolName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(suggestion.suggestedRole.tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: ownerColumnWidth, alignment: .leading)
    }
    .frame(minHeight: tableRowHeight)
    .background(
      isHovering
        ? ProposedTicketVisualStyle.emphasizedSurface
        : ProposedTicketVisualStyle.surface
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onOpenSuggestion(suggestion)
    }
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        hoveredSuggestionID = hovering ? suggestion.id : nil
      }
    }
    .help("Open suggested ticket details")
  }

  private func ticketRow(_ ticket: WorkItem) -> some View {
    let isHovering = hoveredTicketID == ticket.id
    return HStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: ticket.type.symbolName)
          .foregroundStyle(ticket.type.tint)
          .frame(width: 16)
        Text(ticket.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
          .lineLimit(2)
          .layoutPriority(1)
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(statusTitle(for: ticket))
        .font(.caption.weight(.medium))
        .foregroundStyle(statusColor(for: ticket))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: statusColumnWidth, alignment: .leading)

      ownerLabel(for: ticket)
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(width: ownerColumnWidth, alignment: .leading)
    }
    .frame(minHeight: tableRowHeight)
    .background(
      isHovering ? Color.accentColor.opacity(0.055) : Color.clear
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onOpen(ticket)
    }
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        hoveredTicketID = hovering ? ticket.id : nil
      }
    }
    .help("Open \(ticket.key) · \(ticket.title)")
  }

  private func owner(for ticket: WorkItem) -> AgentProfile? {
    guard let ownerID = ticket.ownerProfileID else { return nil }
    return model.profiles.first { $0.id == ownerID }
  }

  @ViewBuilder
  private func ownerLabel(for ticket: WorkItem) -> some View {
    if let owner = owner(for: ticket) {
      Label(owner.name, systemImage: owner.role.symbolName)
        .foregroundStyle(owner.role.tint)
        .lineLimit(1)
    } else {
      Text("Unassigned")
        .foregroundStyle(.secondary)
    }
  }

  private func statusTitle(for ticket: WorkItem) -> String {
    switch ticket.state {
    case .queued: "Ready to Pick"
    case .running: "In Progress"
    case .integrating, .verifying, .readyToRelease: "In Review"
    case .acceptance: "Ready for Demo"
    case .released: "Done"
    default: ticket.state.title
    }
  }

  private func statusColor(for ticket: WorkItem) -> Color {
    switch ticket.state {
    case .released: .green
    case .running: .blue
    case .integrating, .verifying, .readyToRelease: .indigo
    case .acceptance: .purple
    default: .secondary
    }
  }
}

enum EpicPlanningConversationTimeline {
  static func pendingQuestionMessageID(
    in messages: [EpicPlanningConversationMessage],
    questions: [TicketRefinementQuestion]
  ) -> UUID? {
    guard !questions.isEmpty else { return nil }
    return messages.last(where: {
      $0.author == .businessAnalyst
        && $0.kind != .chat
        && $0.answeredQuestions.isEmpty
    })?.id
  }
}

private struct EpicPlanningConversationPanel: View {
  @EnvironmentObject private var model: AppModel
  let epic: Epic
  @State private var selectedOptions: [Int: String] = [:]
  @State private var otherAnswers: [Int: String] = [:]
  @State private var message = ""
  @State private var recipientID: UUID?
  @State private var isSending = false
  @State private var respondingRecipientID: UUID?
  @State private var sendError: String?

  private let otherChoice = "__other__"

  private var conversation: EpicPlanningConversationState? {
    guard model.epicPlanningConversation?.epicID == epic.id else { return nil }
    return model.epicPlanningConversation
  }

  private var analyst: AgentProfile? {
    model.profiles.first { $0.role == .businessAnalyst }
  }

  private var selectedRecipient: AgentProfile? {
    guard let recipientID else { return nil }
    return model.profiles.first { $0.id == recipientID }
  }

  private var respondingRecipient: AgentProfile? {
    let activeRecipientID =
      respondingRecipientID
      ?? (
        model.epicConversationEpicID == epic.id
          ? model.epicConversationRecipientID
          : nil
      )
    guard let activeRecipientID else { return nil }
    return model.profiles.first { $0.id == activeRecipientID }
  }

  private var defaultRecipient: AgentProfile? {
    analyst
      ?? model.profiles.first { $0.role == .lead }
      ?? model.profiles.first
  }

  private var isPlanningResponding: Bool {
    conversation?.isRunning == true || conversation?.isGeneratingPlan == true
  }

  private var isChatResponding: Bool {
    respondingRecipient != nil
  }

  private var isAnyAgentResponding: Bool {
    isPlanningResponding || isChatResponding
  }

  private var tint: Color {
    analyst?.role.tint ?? .purple
  }

  private var showsEmptyConversation: Bool {
    guard let conversation else { return true }
    return conversation.messages.isEmpty && conversation.questions.isEmpty
  }

  private var pendingQuestionMessageID: UUID? {
    guard let conversation else { return nil }
    return EpicPlanningConversationTimeline.pendingQuestionMessageID(
      in: conversation.messages,
      questions: conversation.questions
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Conversation", systemImage: "bubble.left.and.bubble.right")
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
                if message.answeredQuestions.isEmpty {
                  messageRow(message)
                } else {
                  answeredQuestionCards(message.answeredQuestions)
                }
                if message.id == pendingQuestionMessageID {
                  questionCards(conversation.questions)
                }
              }
              if
                !conversation.questions.isEmpty,
                pendingQuestionMessageID == nil
              {
                questionCards(conversation.questions)
              }
            }
            Color.clear
              .frame(height: 1)
              .padding(.bottom, 14)
              .id("epic-conversation-bottom")
          }
          .padding(.horizontal, 14)
          .padding(.top, 14)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
          if showsEmptyConversation {
            ConversationEmptyState(
              detail: "Ask any team member about this epic."
            )
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
      .frame(maxHeight: .infinity)

      Divider()
      conversationStatus
      if isChatResponding {
        ConversationRespondingStatus(
          profile: respondingRecipient,
          fallbackName: "Team member",
          status: "is thinking…",
          onStop: model.cancelEpicConversationMessage
        )
      }
      if epic.status == .open {
        TeamConversationComposer(
          profiles: model.profiles,
          recipientID: $recipientID,
          message: $message,
          isSending: isSending,
          isResponding: isAnyAgentResponding,
          sendError: sendError,
          onSend: send
        )
      }
    }
    .frame(maxHeight: .infinity)
    .clipped()
    .onChange(of: conversation?.questions ?? []) { _, _ in
      selectedOptions.removeAll()
      otherAnswers.removeAll()
    }
    .task(id: epic.id) {
      if recipientID == nil {
        recipientID = defaultRecipient?.id
      }
    }
  }

  @ViewBuilder
  private var conversationStatus: some View {
    if let conversation {
      if conversation.isRunning || conversation.isGeneratingPlan {
        ConversationRespondingStatus(
          profile: analyst,
          fallbackName: "Business Analyst",
          status:
            conversation.isGeneratingPlan
            ? "is preparing the epic and tickets…"
            : "is thinking…",
          onStop: model.cancelEpicPlanning
        )
      } else if !conversation.questions.isEmpty {
        HStack {
          Text("\(analyst?.name ?? "Business Analyst") is waiting for your response.")
            .font(.caption)
            .foregroundStyle(.primary)
          Spacer()
          Button {
            submitAnswers(conversation.questions)
          } label: {
            Label("Submit answers", systemImage: "paperplane.fill")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
          .disabled(!canSubmit(conversation.questions) || isAnyAgentResponding)
        }
        .padding(14)
        .background(tint.opacity(0.075))
      } else if let error = conversation.errorMessage {
        VStack(alignment: .leading, spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
          Button {
            model.retryEpicPlanning(epic)
          } label: {
            Label("Try again", systemImage: "wand.and.stars")
          }
          .buttonStyle(.borderedProminent)
          .tint(.purple)
          .controlSize(.small)
        }
        .padding(14)
      }
    }
  }

  @ViewBuilder
  private func messageRow(_ message: EpicPlanningConversationMessage) -> some View {
    let isOwner = message.author == .owner
    let profile = profile(for: message)
    let accent = message.author == .system ? Color.secondary : profile?.role.tint ?? tint
    let displayName =
      switch message.author {
      case .owner: "Me"
      case .businessAnalyst: analyst?.name ?? "Business Analyst"
      case .agent: message.participantName ?? profile?.name ?? "Team member"
      case .system: "Spedito"
      }
    let symbolName =
      message.author == .system
      ? "gearshape.fill"
      : profile?.role.symbolName ?? "sparkles"
    HStack(alignment: .top, spacing: 8) {
      if isOwner { Spacer(minLength: 46) }
      if !isOwner {
        Circle()
          .fill(accent.opacity(0.12))
          .overlay {
            Image(systemName: symbolName)
              .font(.caption)
              .foregroundStyle(accent)
          }
          .frame(width: 28, height: 28)
      }
      VStack(alignment: isOwner ? .trailing : .leading, spacing: 4) {
        Text(displayName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(isOwner ? Color.primary : accent)
        Text(message.body)
          .font(.callout)
          .textSelection(.enabled)
          .padding(.horizontal, 11)
          .padding(.vertical, 9)
          .background(
            isOwner ? ConversationPalette.owner.opacity(0.1) : accent.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 11)
          )
      }
      if isOwner {
        Circle()
          .fill(ConversationPalette.owner.opacity(0.12))
          .overlay {
            Image(systemName: "person.fill")
              .font(.caption)
              .foregroundStyle(ConversationPalette.owner)
          }
          .frame(width: 28, height: 28)
      } else {
        Spacer(minLength: 46)
      }
    }
  }

  private func profile(
    for message: EpicPlanningConversationMessage
  ) -> AgentProfile? {
    if let participantID = message.participantID,
      let profile = model.profiles.first(where: { $0.id == participantID })
    {
      return profile
    }
    if let participantName = message.participantName,
      let profile = model.profiles.first(where: { $0.name == participantName })
    {
      return profile
    }
    return message.author == .businessAnalyst ? analyst : nil
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

  private func answeredQuestionCards(
    _ answeredQuestions: [EpicPlanningAnsweredQuestion]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(answeredQuestions.enumerated()), id: \.offset) { index, answered in
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(
              answeredQuestions.count > 1
                ? "Question \(index + 1) of \(answeredQuestions.count)"
                : "Answered"
            )
          }
          .font(.caption2.weight(.semibold))
          .foregroundStyle(tint)

          Text(answered.question.prompt)
            .font(.callout.weight(.medium))

          VStack(spacing: 6) {
            ForEach(answered.question.options, id: \.self) { option in
              readOnlyChoiceRow(
                option,
                selected: answered.selectedOption == option
              )
            }
            readOnlyChoiceRow(
              "Other",
              selected: answered.selectedOption == nil
            )
          }

          if answered.selectedOption == nil {
            Text(answered.answer)
              .font(.callout)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(
                tint.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
              )
          }
        }
        .padding(11)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
      }
    }
  }

  private func readOnlyChoiceRow(_ label: String, selected: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: selected ? "largecircle.fill.circle" : "circle")
        .font(.caption)
        .foregroundStyle(selected ? tint : Color.secondary.opacity(0.65))
      Text(label)
        .font(.callout)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      selected ? tint.opacity(0.14) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 8)
    )
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

  private func send() {
    let ownerMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let recipient = selectedRecipient,
      !ownerMessage.isEmpty,
      !isSending,
      !isAnyAgentResponding
    else { return }
    isSending = true
    respondingRecipientID = recipient.id
    sendError = nil
    message = ""
    Task {
      do {
        _ = try await model.sendEpicConversationMessage(
          for: epic,
          to: recipient,
          ownerMessage: ownerMessage
        )
      } catch {
        sendError = error.localizedDescription
      }
      respondingRecipientID = nil
      isSending = false
    }
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
    guard canSubmit(questions), !isAnyAgentResponding else { return }
    let answeredQuestions = questions.enumerated().map { index, question in
      let selection = selectedOptions[index] ?? ""
      let answer =
        selection == otherChoice
        ? (otherAnswers[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        : selection
      return EpicPlanningAnsweredQuestion(
        question: question,
        selectedOption: selection == otherChoice ? nil : selection,
        answer: answer
      )
    }
    let answers = answeredQuestions.map {
      "\($0.question.prompt)\nAnswer: \($0.answer)"
    }
    model.continueEpicPlanning(
      epic,
      answers: answers,
      answeredQuestions: answeredQuestions
    )
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
  let focusOnAppear: Bool
  let isReadOnly: Bool
  @FocusState private var isFocused: Bool

  init(
    title: String,
    prompt: String,
    text: Binding<String>,
    statusText: String? = nil,
    minHeight: CGFloat,
    focusOnAppear: Bool = false,
    isReadOnly: Bool = false
  ) {
    self.title = title
    self.prompt = prompt
    _text = text
    self.statusText = statusText
    self.minHeight = minHeight
    self.focusOnAppear = focusOnAppear
    self.isReadOnly = isReadOnly
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
          .focused($isFocused)
      }
      .frame(minHeight: minHeight)
      .background(
        Color(nsColor: .textBackgroundColor),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.separator.opacity(0.7), lineWidth: 1)
      }
      .disabled(isReadOnly)
      .allowsHitTesting(!isReadOnly)
    }
    .onAppear {
      guard focusOnAppear else { return }
      DispatchQueue.main.async {
        isFocused = true
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
  fileprivate var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  fileprivate var detail: String {
    switch self {
    case .notChecked: "Not checked"
    case .checking: "Checking compatibility…"
    case .connected(let version, _): "Connected · \(version)"
    case .unavailable: "Not available"
    case .incompatible: "Not compatible"
    }
  }

  fileprivate var diagnostic: String? {
    switch self {
    case .unavailable(let message), .incompatible(let message):
      message
    default:
      nil
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
