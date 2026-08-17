import AppKit
import SpeditoCore
import SwiftUI

struct GitHubRepositorySettingsSection: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  let product: Product
  let importedRepository: ProductRepository?
  @State private var showingRepositoryPicker = false
  @State private var showingIncomingReview = false
  @State private var showingDisconnectConfirmation = false
  @State private var showingSignOutConfirmation = false
  @State private var awaitingGitHubInstallation = false

  private var snapshot: RemoteRepositoryPresentationSnapshot? {
    model.remoteRepositorySnapshotIfLoaded(for: product.id)
  }

  private var state: GitHubRemoteRepositoryState? {
    snapshot?.repositoryState
  }

  private var isBusy: Bool {
    snapshot?.isBusy == true
  }

  private var hasActiveDelivery: Bool {
    model.sprintPlan?.sprint.productID == product.id
      && model.sprintPlan?.sprint.state.isInProgress == true
  }

  private var isSettingUpGitHubConnection: Bool {
    guard let status = state?.connection?.status else { return false }
    return status == .selectingRepository || status == .needsInstallation
  }

  private var productConnectionActionTitle: String {
    isSettingUpGitHubConnection ? "Cancel setup" : "Disconnect this Product"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text("GitHub repository")
            .font(.headline)
            .accessibilityIdentifier("github.settings.\(product.id.uuidString)")
          Text("Link this Product to one repository for pull requests and incoming changes.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        if isBusy {
          ProgressView()
            .controlSize(.small)
        }
      }

      if let error = snapshot?.failure?.message {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let state {
        repositoryContent(state)
      } else {
        ProgressView("Loading GitHub repository status...")
          .controlSize(.small)
      }
    }
    .sheet(isPresented: devicePromptPresentation) {
      if let prompt = snapshot?.authorizationPrompt {
        GitHubDeviceAuthorizationSheet(
          prompt: prompt,
          onCancel: {
            Task { await model.cancelGitHubConnection(productID: product.id) }
          }
        )
      }
    }
    .sheet(isPresented: $showingRepositoryPicker) {
      GitHubRepositoryPickerSheet(
        productID: product.id,
        onClose: { showingRepositoryPicker = false }
      )
      .environmentObject(model)
    }
    .sheet(isPresented: $showingIncomingReview) {
      if let sync = state?.safeSync, sync.status == .awaitingConfirmation {
        IncomingRepositoryReviewSheet(
          sync: sync,
          onAccept: {
            showingIncomingReview = false
            Task {
              await model.acceptIncomingRepositoryChange(
                productID: product.id,
                syncID: sync.id
              )
            }
          },
          onReject: {
            showingIncomingReview = false
            Task {
              await model.rejectIncomingRepositoryChange(
                productID: product.id,
                syncID: sync.id
              )
            }
          }
        )
      }
    }
    .confirmationDialog(
      isSettingUpGitHubConnection
        ? "Cancel GitHub setup?"
        : "Disconnect this Product from GitHub?",
      isPresented: $showingDisconnectConfirmation,
      titleVisibility: .visible
    ) {
      Button(productConnectionActionTitle, role: .destructive) {
        Task {
          if isSettingUpGitHubConnection {
            await model.cancelGitHubConnection(productID: product.id)
          } else {
            await model.disconnectGitHub(productID: product.id)
          }
        }
      }
      Button("Keep connection", role: .cancel) {}
    } message: {
      Text(
        isSettingUpGitHubConnection
          ? "The selected GitHub repository will not be changed. Your signed-in GitHub account remains available to other Products."
          : "Local work and GitHub history are preserved. Your signed-in GitHub account remains available to other Products."
      )
    }
    .confirmationDialog(
      "Sign out of GitHub?",
      isPresented: $showingSignOutConfirmation,
      titleVisibility: .visible
    ) {
      Button("Sign out", role: .destructive) {
        guard let accountID = state?.connection?.accountID else { return }
        Task {
          await model.signOutGitHub(accountID: accountID, productID: product.id)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes the GitHub account from Spedito. Every Product using it will need authorization again. Local work and GitHub repositories are not changed."
      )
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, awaitingGitHubInstallation else { return }
      awaitingGitHubInstallation = false
      Task { await model.refreshGitHubRepositories(productID: product.id) }
    }
  }

  private var devicePromptPresentation: Binding<Bool> {
    Binding(
      get: { snapshot?.authorizationPrompt != nil },
      set: { presented in
        if !presented, snapshot?.authorizationPrompt != nil {
          Task { await model.cancelGitHubConnection(productID: product.id) }
        }
      }
    )
  }

  @ViewBuilder
  private func repositoryContent(_ state: GitHubRemoteRepositoryState) -> some View {
    if !state.isConfigured {
      Text("This Spedito build is not configured for GitHub.")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else if let connection = state.connection {
      switch connection.status {
      case .selectingRepository:
        repositorySelectionContent(state, connection: connection)
      case .initializingRemote:
        repositoryIdentity(connection)
        ProgressView("Initializing GitHub repository...")
          .controlSize(.small)
      case .connected:
        connectedContent(state, connection: connection)
      case .needsTargetReview:
        targetReviewContent(connection)
      case .needsAuthorization:
        authorizationContent(connection)
      case .needsInstallation:
        installationContent(connection)
      case .unavailable:
        repositoryIdentity(connection)
        Text(state.errorMessage ?? "This GitHub repository is unavailable.")
          .font(.callout)
          .foregroundStyle(.secondary)
        connectionManagementButtons(connection)
      case .disconnected:
        disconnectedContent(actionTitle: connectionActionTitle)
      }
    } else {
      disconnectedContent(actionTitle: connectionActionTitle)
    }
  }

  @ViewBuilder
  private func repositorySelectionContent(
    _ state: GitHubRemoteRepositoryState,
    connection: RemoteRepositoryConnection
  ) -> some View {
    let presentation = GitHubRepositorySetupPresentation.resolve(
      repositoryID: connection.repositoryID,
      eligibility: state.selectedEligibility
    )
    repositoryIdentity(connection)
    switch presentation.step {
    case .checkingRepository:
      ProgressView("Verifying that this repository is empty...")
        .controlSize(.small)
    case .reviewAndConnect:
      Text("Repository verified. Review what Spedito will publish, then finish setup.")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .chooseAnotherRepository:
      if case .ineligible(let message) = state.selectedEligibility {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
      }
    case .chooseRepository:
      Text("Next: choose an empty GitHub repository.")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .verifyRepository:
      Text(
        "Next: verify that this repository is empty, review what Spedito will publish, and finish setup."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    HStack(spacing: 8) {
      if let actionTitle = presentation.actionTitle {
        Button(actionTitle) {
          showingRepositoryPicker = true
        }
        .buttonStyle(.borderedProminent)
      }
      connectionManagementButtons(connection)
    }
  }

  private var connectionActionTitle: String {
    importedRepository == nil ? "Set up GitHub repository" : "Connect GitHub"
  }

  @ViewBuilder
  private func authorizationContent(_ connection: RemoteRepositoryConnection) -> some View {
    let presentation = GitHubAuthorizationRecoveryPresentation.resolve(
      repositoryID: connection.repositoryID
    )
    if presentation.showsRepositoryIdentity {
      repositoryIdentity(connection)
    }
    Text(presentation.message)
      .font(.callout)
      .foregroundStyle(.secondary)
    HStack(spacing: 8) {
      Button(presentation.actionTitle) {
        connectGitHub()
      }
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)
      if presentation.showsRepositoryIdentity {
        connectionManagementButtons(connection)
      }
    }
  }

  @ViewBuilder
  private func disconnectedContent(actionTitle: String) -> some View {
    if let importedRepository {
      VStack(alignment: .leading, spacing: 3) {
        Text("Imported source")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(importedRepository.originURL.absoluteString)
          .font(.callout)
          .textSelection(.enabled)
        Text("Default branch: \(importedRepository.sourceDefaultBranch)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      Text(
        "Create an empty repository on GitHub, then connect it here. Spedito sends the bootstrap root once and publishes every later change through a pull request."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    Button(actionTitle) {
      connectGitHub()
    }
    .buttonStyle(.borderedProminent)
    .disabled(isBusy)
  }

  @ViewBuilder
  private func installationContent(_ connection: RemoteRepositoryConnection) -> some View {
    repositoryIdentity(connection)
    Text(
      "GitHub requires one repository-access approval to finish this connection. Spedito checks the imported repository automatically when you return."
    )
    .font(.callout)
    .foregroundStyle(.secondary)
    HStack {
      Button("Continue on GitHub") {
        openGitHubInstallation(for: connection)
      }
      .buttonStyle(.borderedProminent)
      Button("Check again") {
        Task { await model.refreshGitHubRepositories(productID: product.id) }
      }
      .buttonStyle(.bordered)
      .disabled(isBusy)
    }
    connectionManagementButtons(connection)
  }

  @ViewBuilder
  private func targetReviewContent(_ connection: RemoteRepositoryConnection) -> some View {
    Text("GitHub changed the repository target.")
      .font(.callout.weight(.semibold))
    if let fullName = connection.pendingFullName {
      Text(fullName)
        .font(.callout)
    }
    if let url = connection.pendingCanonicalHTTPSURL {
      Text(url.absoluteString)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    if let branch = connection.pendingDefaultBranch {
      Text("Default branch: \(branch)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    HStack {
      Button("Use this repository") {
        guard let observedAt = connection.pendingObservedAt else { return }
        Task {
          await model.confirmRemoteRepositoryTarget(
            productID: product.id,
            expectedVersion: connection.version,
            pendingObservedAt: observedAt
          )
        }
      }
      .buttonStyle(.borderedProminent)
      Button("Disconnect", role: .destructive) {
        showingDisconnectConfirmation = true
      }
      .buttonStyle(.bordered)
      .tint(.red)
    }
  }

  @ViewBuilder
  private func connectedContent(
    _ state: GitHubRemoteRepositoryState,
    connection: RemoteRepositoryConnection
  ) -> some View {
    let connectionPublication = state.publications
      .filter { $0.purpose == .existingProductHistory }
      .max { $0.updatedAt < $1.updatedAt }
    let publicationAction = connectionPublication.map {
      GitHubPullRequestActionPresentation.resolve(
        purpose: $0.purpose,
        status: $0.status,
        relationship: connection.latestRelationship,
        hasAcceptedSynchronization: state.safeSync?.status == .accepted
      )
    }
    repositoryIdentity(connection)
    if let observation = state.observation,
      GitHubRepositoryRelationshipVisibility.showsStatus(for: observation.relationship)
    {
      repositoryRelationshipContent(observation, state: state)
    } else if publicationAction?.isPrimary == true {
      Text("Finish GitHub setup to reconcile the merged pull request with this Product.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    if let connectionPublication, publicationAction?.showsButton == true {
      TicketPullRequestStatusView(
        publication: connectionPublication,
        relationship: connection.latestRelationship,
        hasAcceptedSynchronization: state.safeSync?.status == .accepted,
        isBusy: isBusy,
        onRefresh: {
          Task {
            await model.refreshRemotePullRequest(
              productID: product.id,
              publicationID: connectionPublication.id
            )
          }
        }
      )
    }
    connectionManagementButtons(connection)
  }

  @ViewBuilder
  private func repositoryIdentity(_ connection: RemoteRepositoryConnection) -> some View {
    if let fullName = connection.fullName {
      HStack(spacing: 8) {
        Text(fullName)
          .font(.callout.weight(.semibold))
          .textSelection(.enabled)
        if let isPrivate = connection.isPrivate {
          Text(isPrivate ? "Private" : "Public")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        if let branch = connection.defaultBranch {
          Text("Default branch: \(branch)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("github.repository.\(connection.productID.uuidString)")
    }
  }

  @ViewBuilder
  private func repositoryRelationshipContent(
    _ observation: RemoteRepositoryObservation,
    state: GitHubRemoteRepositoryState
  ) -> some View {
    switch observation.relationship {
    case .aligned:
      EmptyView()
    case .localAhead:
      Label(
        "\(observation.aheadCount) local ticket commit\(observation.aheadCount == 1 ? "" : "s") not yet on the default branch.",
        systemImage: "arrow.up.circle"
      )
      Text(
        "Spedito publishes reviewed ticket revisions automatically and merges them on product owner approval."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .remoteAhead, .historyAlignmentAvailable:
      Label(
        "\(observation.behindCount) incoming commit\(observation.behindCount == 1 ? "" : "s") available for review.",
        systemImage: "arrow.down.circle"
      )
      if hasActiveDelivery {
        Text("Spedito will integrate these changes with affected tickets during review.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Button("Review incoming changes") {
          reviewIncomingChanges()
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
      }
    case .diverged:
      Label(
        "Local trunk and GitHub both changed.",
        systemImage: "arrow.triangle.merge"
      )
      Text(
        hasActiveDelivery
          ? "Spedito will combine the verified histories within affected tickets during review."
          : "Spedito will combine the verified histories when the next affected ticket reaches review."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .unrelated:
      Label(
        "The GitHub history is unrelated to this Product. Choose the intended repository.",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private func connectionManagementButtons(_ connection: RemoteRepositoryConnection) -> some View {
    Menu {
      Section(product.name) {
        Button(productConnectionActionTitle, role: .destructive) {
          showingDisconnectConfirmation = true
        }
      }
      if connection.accountID != nil {
        Section("GitHub account") {
          Button("Sign out of GitHub", role: .destructive) {
            showingSignOutConfirmation = true
          }
        }
      }
    } label: {
      Label("Manage connection", systemImage: "ellipsis.circle")
    }
    .buttonStyle(.bordered)
    .tint(Color(nsColor: .secondaryLabelColor))
  }

  private func connectGitHub() {
    Task {
      await model.connectGitHub(productID: product.id)
      let connection = model.remoteRepositorySnapshot(for: product.id).repositoryState.connection
      switch GitHubRepositorySetupLaunch.resolve(status: connection?.status) {
      case .repositoryPicker:
        showingRepositoryPicker = true
      case .installation:
        openGitHubInstallation(for: connection)
      case .none:
        break
      }
    }
  }

  private func openGitHubInstallation(for connection: RemoteRepositoryConnection?) {
    let slug = GitHubConfiguration.current().appSlug
    let url: URL? =
      if let installationID = connection?.installationID {
        URL(string: "https://github.com/settings/installations/\(installationID)")
      } else if !slug.isEmpty {
        URL(string: "https://github.com/apps/\(slug)/installations/new")
      } else {
        nil
      }
    guard let url else { return }
    awaitingGitHubInstallation = true
    openURL(url)
  }

  private func reviewIncomingChanges() {
    Task {
      await model.prepareIncomingRepositoryChange(productID: product.id)
      if model.remoteRepositorySnapshot(for: product.id).repositoryState.safeSync?.status
        == .awaitingConfirmation
      {
        showingIncomingReview = true
      }
    }
  }

}

struct GitHubDeviceAuthorizationSheet: View {
  let prompt: GitHubDeviceAuthorizationPrompt
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connect GitHub")
        .font(.title2.bold())
      Text("Enter this one-time code on GitHub. Spedito never asks for your password.")
        .foregroundStyle(.secondary)
      Text(prompt.userCode)
        .font(.system(.title, design: .monospaced, weight: .semibold))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
      Text("Expires \(prompt.expiresAt.formatted(date: .omitted, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("Copy code") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(prompt.userCode, forType: .string)
        }
        .buttonStyle(.bordered)
        Button("Open GitHub") {
          NSWorkspace.shared.open(prompt.verificationURL)
        }
        .buttonStyle(.borderedProminent)
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
      }
    }
    .padding(24)
    .frame(width: 480)
  }
}
