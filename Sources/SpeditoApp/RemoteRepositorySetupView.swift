import SpeditoCore
import SwiftUI

struct GitHubRepositoryPickerSheet: View {
  @EnvironmentObject private var model: AppModel
  let productID: UUID
  let onClose: () -> Void

  private var snapshot: RemoteRepositoryPresentationSnapshot {
    model.remoteRepositorySnapshot(for: productID)
  }

  private var state: GitHubRemoteRepositoryState {
    snapshot.repositoryState
  }

  private var isBusy: Bool {
    snapshot.isBusy
  }

  private var setupActivity: GitHubRepositorySetupActivity? {
    snapshot.setupActivity
  }

  private var canDismiss: Bool {
    GitHubRepositoryPickerDismissalPolicy.canDismiss(activity: setupActivity)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Choose an empty GitHub repository")
          .font(.title2.bold())
        Text(
          "New repositories default to private. Public visibility is an explicit choice on GitHub."
        )
        .foregroundStyle(.secondary)
      }
      .padding(22)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if let error = snapshot.failure?.message,
            !error.isEmpty,
            !isBusy
          {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.bottom, 4)
          }
          switch GitHubRepositoryPickerContent.resolve(
            repositoryCount: state.repositories.count,
            isBusy: isBusy,
            error: snapshot.failure?.message ?? state.errorMessage
          ) {
          case .loading:
            ProgressView("Loading repositories...")
              .controlSize(.small)
              .frame(maxWidth: .infinity, minHeight: 240)
          case .failure(let message):
            ContentUnavailableView(
              "Couldn’t load repositories",
              systemImage: "exclamationmark.triangle.fill",
              description: Text(message)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
          case .empty:
            ContentUnavailableView(
              "No accessible repositories",
              systemImage: "shippingbox",
              description: Text("Create an empty repository or add the Spedito GitHub App to one.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
          case .repositories:
            ForEach(state.repositories) { choice in
              repositoryRow(choice)
            }
          }
        }
        .padding(22)
      }
      Divider()
      HStack(spacing: 12) {
        if setupActivity == nil {
          Link(
            "Create repository",
            destination: URL(string: "https://github.com/new?visibility=private")!
          )
          .buttonStyle(.link)
          if let installationID = state.connection?.installationID,
            let accessURL = URL(
              string: "https://github.com/settings/installations/\(installationID)"
            )
          {
            Link("Manage access", destination: accessURL)
              .buttonStyle(.link)
          }
          Button("Refresh list") {
            Task { await model.refreshGitHubRepositories(productID: productID) }
          }
          .buttonStyle(.bordered)
          .disabled(isBusy)
          Spacer()
          Button("Close", action: onClose)
            .buttonStyle(.bordered)
        } else if setupActivity?.isCompleted == true {
          Spacer()
          Button("Done", action: onClose)
            .buttonStyle(.borderedProminent)
        } else {
          Label("Setup continues automatically", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
      .padding(18)
    }
    .frame(width: 620, height: 560)
    .task {
      await model.resumeLocalGitHubRepositorySetup(productID: productID)
    }
    .interactiveDismissDisabled(!canDismiss)

  }

  @ViewBuilder
  private func repositoryRow(_ choice: GitHubRepositoryChoice) -> some View {
    let isSelected = state.connection?.repositoryID == choice.id
    VStack(alignment: .leading, spacing: 0) {
      Button {
        Task {
          await model.selectLocalGitHubRepository(
            productID: productID,
            repositoryID: choice.id
          )
        }
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(choice.repository.fullName)
              .font(.callout.weight(.semibold))
            Text(choice.repository.isPrivate ? "Private" : "Public")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if isSelected, state.selectedEligibility != .checking {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(Color.accentColor)
          } else if !isSelected {
            Text("Choose")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.accentColor)
          }
        }
        .padding(12)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isBusy)

      if isSelected {
        eligibilityContent
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
      }
    }
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
  }

  @ViewBuilder
  private var eligibilityContent: some View {
    if let setupActivity {
      repositoryInitializationContent(setupActivity)
    } else {
      switch state.selectedEligibility {
      case .checking:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Checking whether this repository is empty...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      case .empty(_, let existingHistory):
        let presentation = GitHubVerifiedRepositoryPresentation.resolve(
          hasExistingHistory: existingHistory != nil
        )
        VStack(alignment: .leading, spacing: 8) {
          Label("Ready to connect", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
          Text(presentation.message)
            .font(.caption)
            .foregroundStyle(.secondary)
          Button(presentation.actionTitle) {
            Task {
              await model.initializeLocalGitHubRepository(productID: productID)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isBusy)
        }
        .padding(.top, 2)
      case .ineligible(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .padding(.top, 2)
      case .unchecked, nil:
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private func repositoryInitializationContent(
    _ activity: GitHubRepositorySetupActivity
  ) -> some View {
    let presentation = GitHubRepositoryInitializationPresentation.resolve(activity: activity)
    VStack(alignment: .leading, spacing: 8) {
      if presentation.isComplete {
        Label(presentation.title, systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.green)
      } else {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Step \(presentation.step) of \(presentation.stepCount)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        ProgressView(
          value: Double(presentation.step),
          total: Double(presentation.stepCount)
        )
        .progressViewStyle(.linear)
        Text(presentation.title)
          .font(.callout.weight(.semibold))
      }
      Text(presentation.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 2)
  }
}
