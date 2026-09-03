import SpeditoCore
import SwiftUI

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
      ProductContentRootView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.workspaceContainerSize, geometry.size)
    }
    .environment(\.openURL, SafeURLPolicy.openURLAction)
    .environment(
      \.ownerNotificationBannerDismissDelay,
      ownerNotificationBannerDismissDelay
    )
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

  private var ownerNotificationBannerDismissDelay: Duration? {
    #if DEBUG
      UIFixtureRuntime.notificationBannerDismissDelay
    #else
      .seconds(8)
    #endif
  }
}

enum WorkspaceDestination: String, Hashable {
  case conversation
  case backlog
  case sprint
  case app
  case retrospectives
  case reports
  case knowledge
  case codebase
}

enum WorkspaceDestinationDefaults {
  private static let prefix = "workspaceDestination"

  static func destination(
    for productID: UUID?,
    hasActiveSprint: Bool,
    defaults: UserDefaults = .standard
  ) -> WorkspaceDestination {
    guard let productID else { return .backlog }
    return defaults.string(forKey: key(for: productID))
      .flatMap(WorkspaceDestination.init(rawValue:))
      ?? (hasActiveSprint ? .sprint : .backlog)
  }

  static func select(
    _ destination: WorkspaceDestination,
    for productID: UUID?,
    defaults: UserDefaults = .standard
  ) {
    guard let productID else { return }
    defaults.set(destination.rawValue, forKey: key(for: productID))
  }

  private static func key(for productID: UUID) -> String {
    "\(prefix).\(productID.uuidString)"
  }
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
      "Finish or stop sprint \($0) before starting this sprint."
    }
  }

  init(draft: SprintPlan, plans: [SprintPlan]) {
    blockingActiveSprintNumber =
      plans
      .filter {
        $0.sprint.state.isInProgress
          && $0.sprint.id != draft.sprint.id
      }
      .map(\.sprint.number)
      .max()
  }
}

struct ProductWorkspaceView: View {
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
  @State private var attentionWorkItemIDs: Set<UUID>?

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
          ProductConversationView(conversations: model.productConversationFeature)
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
            attentionWorkItemIDs: $attentionWorkItemIDs,
            onShowBacklog: { destination = .backlog },
            onEditPlan: { showingSprintPlanning = true },
            onShowRetrospective: { destination = .retrospectives },
            onShowReports: { destination = .reports }
          )
        case .app:
          AppVersionsView()
        case .retrospectives:
          RetrospectivesView(
            onShowBacklog: { destination = .backlog },
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
              ticketDetailPresentation = .existing(
                item,
                activeSprint: model.sprintPlan
              )
            }
          )
        }
      }
      .id(model.selectedProductID)
      .extendsUnderHiddenTitleBar(columnVisibility != .detailOnly)
    }
    .onAppear {
      restoreDestination(for: model.selectedProductID)
      if let request = model.ticketAttentionNavigationRequest {
        handleAttentionNavigationRequest(request)
      }
      if let request = model.ownerNotificationNavigationRequest {
        handleOwnerNotificationNavigationRequest(request)
      }
    }
    .onChange(of: model.selectedProductID) { _, productID in
      showingNewTicket = false
      showingNewEpic = false
      newTicketEpicID = nil
      showingSprintPlanning = false
      ticketDetailPresentation = nil
      selectedSprintID = nil
      attentionWorkItemIDs = nil
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
    .onChange(of: model.ticketAttentionNavigationRequest) { _, request in
      if let request {
        handleAttentionNavigationRequest(request)
      }
    }
    .onChange(of: model.ownerNotificationNavigationRequest) { _, request in
      if let request {
        handleOwnerNotificationNavigationRequest(request)
      }
    }
    .overlayPreferenceValue(OwnerNotificationBellAnchorKey.self) { bellAnchor in
      OwnerNotificationBannerOverlay(bellAnchor: bellAnchor)
    }
    .sheet(isPresented: $showingNewTicket) {
      NewTicketView(
        isPresented: $showingNewTicket,
        initialEpicID: newTicketEpicID,
        onCreated: { item in
          showingNewTicket = false
          Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard
              !Task.isCancelled,
              model.selectedProductID == item.productID
            else { return }
            ticketDetailPresentation = .newlyCreated(item)
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
    destination = WorkspaceDestinationDefaults.destination(
      for: productID,
      hasActiveSprint: model.sprintPlan?.sprint.state.isInProgress == true
    )
  }

  private func persist(_ destination: WorkspaceDestination, for productID: UUID?) {
    WorkspaceDestinationDefaults.select(destination, for: productID)
  }

  private func openSprintBoard(sprintID: UUID) {
    selectedSprintID = sprintID
    if let productID = model.selectedProductID {
      SprintBoardSelectionDefaults.select(sprintID, for: productID)
    }
    destination = .sprint
  }

  private func handleAttentionNavigationRequest(
    _ request: TicketAttentionNavigationRequest
  ) {
    guard model.selectedProductID == request.productID else { return }
    destination = .sprint
    selectedSprintID = request.sprintID
    if let workItemID = request.openWorkItemID,
      let item = model.workItems.first(where: { $0.id == workItemID })
    {
      attentionWorkItemIDs = nil
      ticketDetailPresentation = TicketDetailPresentation(
        item: item,
        startRefinementOnAppear: false,
        mode: .delivery
      )
    } else {
      attentionWorkItemIDs = request.workItemIDs
    }
    model.consumeTicketAttentionNavigationRequest(id: request.id)
  }

  private func handleOwnerNotificationNavigationRequest(
    _ request: OwnerNotificationNavigationRequest
  ) {
    guard model.selectedProductID == request.productID else { return }
    switch request.target.kind {
    case .ticket:
      guard let item = model.workItems.first(where: { $0.id == request.target.id }) else {
        model.consumeOwnerNotificationNavigationRequest(id: request.id)
        return
      }
      let presentation = TicketDetailPresentation.existing(
        item,
        activeSprint: model.sprintPlan
      )
      destination = presentation.mode == .delivery ? .sprint : .backlog
      selectedSprintID = presentation.mode == .delivery ? model.sprintPlan?.sprint.id : nil
      attentionWorkItemIDs = nil
      ticketDetailPresentation = presentation

    case .epic:
      destination = .backlog
      model.backlogFocusEpicID = request.target.id

    case .conversationThread:
      destination = .conversation
      model.conversationFocusThreadID = request.target.id
    }
    model.consumeOwnerNotificationNavigationRequest(id: request.id)
  }
}
