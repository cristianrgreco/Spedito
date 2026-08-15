import SpeditoCore
import SwiftUI

struct TicketPullRequestStatusView: View {
  let publication: RemotePublication
  let relationship: RemoteRepositoryRelationship?
  let hasAcceptedSynchronization: Bool
  let isBusy: Bool
  let onRefresh: () -> Void

  var body: some View {
    switch publication.status {
    case .awaitingConfirmation:
      Text("Spedito is preparing the reviewed ticket pull request.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .checking, .pushing, .creatingPullRequest:
      ProgressView("Publishing immutable review branch...")
        .controlSize(.small)
    case .branchPublished:
      Text("The review branch is on GitHub. Spedito is finishing pull request creation.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .open:
      pullRequestLink(message: "Pull request open")
    case .openOutdated:
      pullRequestLink(
        message:
          "Pull request open. New local work is not included; finish this pull request first."
      )
    case .openStale:
      pullRequestLink(
        message: "GitHub changed this pull request. Review it on GitHub before continuing.")
    case .merged:
      let action = actionPresentation
      let message =
        action.isPrimary
        ? "Pull request merged. Finish GitHub setup to align local history."
        : publication.purpose == .existingProductHistory && !action.showsButton
          ? "GitHub setup complete."
          : "Pull request merged. Local and GitHub history are aligned."
      pullRequestLink(message: message)
    case .closed:
      pullRequestLink(message: "Pull request closed")
    case .cancelled, .stale, .failed:
      if let errorCode = publication.errorCode {
        Text(errorCode)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var actionPresentation: GitHubPullRequestActionPresentation {
    GitHubPullRequestActionPresentation.resolve(
      purpose: publication.purpose,
      status: publication.status,
      relationship: relationship,
      hasAcceptedSynchronization: hasAcceptedSynchronization
    )
  }

  @ViewBuilder
  private func pullRequestLink(message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let pullRequest = publication.pullRequest {
        Link("Open pull request #\(pullRequest.number)", destination: pullRequest.canonicalURL)
          .buttonStyle(.link)
        if actionPresentation.showsButton {
          if actionPresentation.isPrimary {
            Button(actionPresentation.title, action: onRefresh)
              .buttonStyle(.borderedProminent)
              .disabled(isBusy)
          } else {
            Button(actionPresentation.title, action: onRefresh)
              .buttonStyle(.bordered)
              .disabled(isBusy)
          }
        }
      }
    }
  }
}
