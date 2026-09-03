import SpeditoCore
import SwiftUI

/// Count pill shown next to a sidebar row.
private struct SidebarCountBadge: View {
  /// Whether the count belongs to the row it sits on.
  enum Emphasis {
    /// Work waiting on this row. Every such badge shares the accent capsule so
    /// they read down the sidebar as one column of things to attend to. A
    /// selected row already paints its background with the accent colour, so
    /// the badge inverts there to stay legible.
    case attention
    /// Work waiting somewhere this row leads to rather than on the row itself.
    /// It stays quiet so it does not join the accent column and claim
    /// attention for the current product.
    case elsewhere
  }

  let count: Int
  var emphasis: Emphasis = .attention
  var isSelected = false
  let accessibilityLabel: String

  var body: some View {
    Text(count.formatted())
      .font(.caption2.monospacedDigit().weight(emphasis == .attention ? .bold : .semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(background, in: Capsule())
      .overlay {
        if emphasis == .elsewhere {
          Capsule().strokeBorder(Color(nsColor: .separatorColor))
        }
      }
      .accessibilityLabel(accessibilityLabel)
  }

  private var foreground: Color {
    switch emphasis {
    case .attention: isSelected ? Color.accentColor : .white
    case .elsewhere: Color(nsColor: .secondaryLabelColor)
    }
  }

  private var background: Color {
    switch emphasis {
    case .attention: isSelected ? Color.white : .accentColor
    case .elsewhere: Color(nsColor: .quaternaryLabelColor)
    }
  }
}

/// The established purple treatment for an AI action, painted rather than tinted.
///
/// Every other AI action reaches this look with `.borderedProminent` and a purple tint, which
/// leaves both the fill and the label colour to the surrounding context. That context differs
/// here: this is the only prominent button inside the vibrant sidebar list, which blends the
/// tint darker than the same purple elsewhere and re-colours a `Label`'s icon away from the
/// button's white title. Painting the fill and the foreground keeps this action the same purple
/// with a white icon and title as the rest of the app.
struct SidebarAIActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Surface(configuration: configuration)
  }

  private struct Surface: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration

    var body: some View {
      configuration.label
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          Color.purple.opacity(configuration.isPressed ? 0.78 : 1),
          in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(isEnabled ? 1 : 0.5)
    }
  }
}

extension ButtonStyle where Self == SidebarAIActionButtonStyle {
  /// Prominent purple treatment for an AI action inside the sidebar list.
  static var sidebarAIAction: SidebarAIActionButtonStyle { SidebarAIActionButtonStyle() }
}

struct TeamSidebar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var selection: WorkspaceDestination
  let onShowProducts: () -> Void
  @State private var showingTeamPrompts = false
  @State private var showingProductContext = false
  @State private var showingProductSetupDetail = false
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

  private var otherProductAttentionCount: Int {
    model.ownerAttentionCount(excluding: model.selectedProductID)
  }

  private var backlogNotificationCount: Int {
    guard let productID = model.selectedProductID else { return 0 }
    return model.backlogOwnerNotificationCount(productID: productID)
  }

  private var unreadChatThreadCount: Int {
    guard let productID = model.selectedProductID else { return 0 }
    return model.unreadChatThreadCount(productID: productID)
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

  @ViewBuilder
  private var productSetupSubtitle: some View {
    switch model.repositoryKnowledgeSnapshot?.run?.status {
    case .pendingAnalysis, .analyzing, .reviewing, .publishing:
      HStack(spacing: 5) {
        ProgressView()
          .controlSize(.mini)
          .tint(.purple)
        Text("Importing product…")
      }
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.purple)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Color.purple.opacity(0.18), in: Capsule())
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Importing product")
      .onHover { showingProductSetupDetail = $0 }
      .popover(isPresented: $showingProductSetupDetail, arrowEdge: .leading) {
        productSetupDetail
      }
    case .failed, .interrupted, .stale:
      Label("Setup needs attention", systemImage: "exclamationmark.triangle.fill")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.orange)
        .accessibilityLabel("Imported product setup needs attention")
        .onHover { showingProductSetupDetail = $0 }
        .popover(isPresented: $showingProductSetupDetail, arrowEdge: .leading) {
          productSetupDetail
        }
    case .completed:
      if productSetupCompletedWithoutKnowledge {
        Label("No product knowledge found", systemImage: "checkmark.circle")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .onHover { showingProductSetupDetail = $0 }
          .popover(isPresented: $showingProductSetupDetail, arrowEdge: .leading) {
            productSetupDetail
          }
      } else {
        Text("Switch product")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    case .none:
      Text("Switch product")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var productSetupNeedsAttention: Bool {
    guard let status = model.repositoryKnowledgeSnapshot?.run?.status else { return false }
    return status == .failed || status == .interrupted || status == .stale
  }

  private var productSetupCompletedWithoutKnowledge: Bool {
    model.repositoryKnowledgeSnapshot?.completionOutcome == .noPublishableKnowledge
  }

  private var githubRepositoryNeedsAttention: Bool {
    guard let productID = model.selectedProductID else { return false }
    let snapshot = model.remoteRepositorySnapshot(for: productID)
    let state = snapshot.repositoryState
    return GitHubRepositoryAttentionPolicy.needsAttention(
      error: snapshot.failure?.message,
      connectionStatus: state.connection?.status,
      relationship: state.observation?.relationship ?? state.connection?.latestRelationship,
      publicationStatus: state.publication?.status
    )
  }

  private var productSetupDetail: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(productSetupDetailTitle)
        .font(.subheadline.weight(.semibold))
        .lineLimit(nil)
      Text(productSetupDetailMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
      if let activity = productSetupActivity {
        Divider()
          .padding(.vertical, 2)
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: activity.kind.symbolName)
            .foregroundStyle(.purple)
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 2) {
            Text("Latest activity")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(activity.text)
              .font(.caption)
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .transition(.opacity)
      }
    }
    .lineLimit(nil)
    .padding(12)
    .frame(width: 320, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var productSetupActivity: CodexLiveActivity? {
    model.repositoryKnowledgeSnapshot?.activity
  }

  private var productSetupDetailTitle: String {
    switch model.repositoryKnowledgeSnapshot?.run?.status {
    case .pendingAnalysis: "Waiting to continue setup"
    case .analyzing: "Learning how the product works"
    case .reviewing: "Checking the product understanding"
    case .publishing: "Finishing product setup"
    case .failed: "Product setup could not finish"
    case .interrupted: "Product setup was interrupted"
    case .stale: "Product setup is out of date"
    case .completed:
      productSetupCompletedWithoutKnowledge
        ? "No product knowledge found"
        : "Product setup completed"
    case .none: "Product setup completed"
    }
  }

  private var productSetupDetailMessage: String {
    if let error = model.repositoryKnowledgeSnapshot?.run?.errorMessage, !error.isEmpty {
      return error
    }
    return switch model.repositoryKnowledgeSnapshot?.run?.status {
    case .pendingAnalysis:
      "Setup continues when the Codex team connection is available."
    case .analyzing:
      "Spedito is reading the imported repository without running its code."
    case .reviewing:
      "Spedito is checking its understanding against the repository."
    case .publishing:
      "Spedito is saving the verified product information."
    case .failed, .interrupted:
      "Retry creates a new versioned setup attempt."
    case .stale:
      "The imported source changed. Retry uses its current accepted revision."
    case .completed:
      productSetupCompletedWithoutKnowledge
        ? "The analysis completed without verified product information to add. You can keep using this product or analyze it again."
        : "The imported product is ready."
    case .none:
      "The imported product is ready."
    }
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
                    productSetupSubtitle
                  }
                  Spacer()
                  if otherProductAttentionCount > 0 {
                    SidebarCountBadge(
                      count: otherProductAttentionCount,
                      emphasis: .elsewhere,
                      accessibilityLabel: "\(otherProductAttentionCount) "
                        + (otherProductAttentionCount == 1 ? "item needs" : "items need")
                        + " your attention in other products"
                    )
                  }
                  Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("nav.products")
              .accessibilityValue(product.name)
              .help("Browse and switch products")

              Button {
                showingProductContext = true
              } label: {
                Label {
                  HStack(spacing: 6) {
                    Text("Product settings")
                    if githubRepositoryNeedsAttention {
                      Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("GitHub needs attention")
                    }
                  }
                } icon: {
                  Image(systemName: "gearshape")
                }
                .font(.caption)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("nav.product-settings")
              .foregroundStyle(.secondary)
              if productSetupNeedsAttention || productSetupCompletedWithoutKnowledge {
                Button {
                  Task { await model.retryRepositoryKnowledgeAnalysis() }
                } label: {
                  Label(
                    productSetupCompletedWithoutKnowledge
                      ? "Analyze product again"
                      : "Retry product setup",
                    systemImage: "arrow.clockwise"
                  )
                  .font(.caption.weight(.semibold))
                }
                .buttonStyle(.sidebarAIAction)
                .accessibilityIdentifier("nav.product-setup-retry")
              }
            }
            .padding(.vertical, 4)
          }
        }

        Section("Workspace") {
          HStack {
            Label("Backlog", systemImage: "list.bullet.rectangle")
            Spacer()
            if backlogNotificationCount > 0 {
              SidebarCountBadge(
                count: backlogNotificationCount,
                isSelected: selection == .backlog,
                accessibilityLabel: "\(backlogNotificationCount) backlog "
                  + (backlogNotificationCount == 1 ? "item needs" : "items need")
                  + " your attention"
              )
            }
          }
          .accessibilityElement(children: .combine)
          .tag(WorkspaceDestination.backlog)
          .accessibilityIdentifier("nav.backlog")
          .accessibilityAddTraits(selection == .backlog ? .isSelected : [])
          HStack {
            Label("Sprint board", systemImage: "rectangle.3.group")
            Spacer()
            if sprintAttentionCount > 0 {
              SidebarCountBadge(
                count: sprintAttentionCount,
                isSelected: selection == .sprint,
                accessibilityLabel:
                  "\(sprintAttentionCount) sprint ticket\(sprintAttentionCount == 1 ? "" : "s") need your input"
              )
            }
          }
          .tag(WorkspaceDestination.sprint)
          .accessibilityIdentifier("nav.sprint")
          Label("Demos", systemImage: "macwindow")
            .tag(WorkspaceDestination.app)
            .accessibilityIdentifier("nav.app")
        }

        Section("Improve") {
          HStack {
            Label("Retrospectives", systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            if pendingRetrospectiveCount > 0 {
              SidebarCountBadge(
                count: pendingRetrospectiveCount,
                isSelected: selection == .retrospectives,
                accessibilityLabel:
                  "\(pendingRetrospectiveCount) retrospective\(pendingRetrospectiveCount == 1 ? "" : "s") to conclude"
              )
            }
          }
          .tag(WorkspaceDestination.retrospectives)
          .accessibilityIdentifier("nav.retrospectives")
          Label("Reports", systemImage: "chart.xyaxis.line")
            .tag(WorkspaceDestination.reports)
        }

        Section("Knowledge") {
          Label("Product", systemImage: "books.vertical")
            .tag(WorkspaceDestination.knowledge)
            .accessibilityIdentifier("nav.knowledge")
          Label("Codebase", systemImage: "chevron.left.forwardslash.chevron.right")
            .tag(WorkspaceDestination.codebase)
            .accessibilityIdentifier("nav.codebase")
        }

        Section("Team") {
          HStack {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
            Spacer()
            if unreadChatThreadCount > 0 {
              SidebarCountBadge(
                count: unreadChatThreadCount,
                isSelected: selection == .conversation,
                accessibilityLabel: "\(unreadChatThreadCount) unread Chat "
                  + (unreadChatThreadCount == 1 ? "thread" : "threads")
              )
            }
          }
          .tag(WorkspaceDestination.conversation)
          .accessibilityIdentifier("nav.conversation")

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
    .onChange(of: model.repositoryKnowledgeSnapshot?.run?.status) { _, status in
      if status == .completed || status == nil {
        showingProductSetupDetail = false
      }
    }
    .focusedSceneValue(
      \.workspaceCommandActions,
      WorkspaceCommandActions(perform: performWorkspaceCommand)
    )
  }

  private func performWorkspaceCommand(_ command: WorkspaceCommand) {
    switch command.resolution {
    case .destination(let destination):
      selection = destination
    case .productSettings:
      showingTeamPrompts = false
      showingProductContext = true
    case .teamSettings:
      showingProductContext = false
      showingTeamPrompts = true
    }
  }
}
