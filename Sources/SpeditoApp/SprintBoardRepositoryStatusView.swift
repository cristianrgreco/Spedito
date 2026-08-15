import SpeditoCore
import SwiftUI

enum SprintBoardGitHubAction: Equatable {
  case check
  case reviewIncoming
}

struct SprintBoardGitHubPresentation: Equatable {
  enum Tone: Equatable {
    case positive
    case informational
    case attention
    case critical
  }

  let title: String
  let detail: String
  let symbol: String
  let tone: Tone
  let actionTitle: String?
  let action: SprintBoardGitHubAction?

  static func resolve(
    error: String?,
    connectionStatus: RemoteRepositoryConnectionStatus?,
    relationship: RemoteRepositoryRelationship?,
    aheadCount: Int,
    behindCount: Int,
    publicationStatus: RemotePublicationStatus?,
    hasActiveDelivery: Bool
  ) -> SprintBoardGitHubPresentation? {
    guard connectionStatus == .connected else { return nil }
    if let error, !error.isEmpty {
      return SprintBoardGitHubPresentation(
        title: "GitHub needs attention",
        detail: error,
        symbol: "exclamationmark.triangle.fill",
        tone: .critical,
        actionTitle: "Check GitHub",
        action: .check
      )
    }

    switch publicationStatus {
    case .awaitingConfirmation, .checking, .pushing, .branchPublished,
      .creatingPullRequest, .open, .openOutdated, .merged:
      return nil
    case .openStale, .closed, .stale, .failed:
      return SprintBoardGitHubPresentation(
        title: "Ticket delivery needs attention",
        detail: "Spedito could not finish publishing this ticket. Review its work log to continue.",
        symbol: "exclamationmark.triangle.fill",
        tone: .critical,
        actionTitle: nil,
        action: nil
      )
    case .cancelled, nil:
      break
    }

    switch relationship {
    case .localAhead:
      return nil
    case .remoteAhead, .historyAlignmentAvailable:
      guard !hasActiveDelivery else { return nil }
      let count = max(1, behindCount)
      return SprintBoardGitHubPresentation(
        title: "GitHub has \(count) incoming change\(count == 1 ? "" : "s")",
        detail:
          "Review the incoming changes now, or let Spedito integrate them with the next affected ticket.",
        symbol: "arrow.down.circle.fill",
        tone: .attention,
        actionTitle: "Review incoming changes",
        action: .reviewIncoming
      )
    case .diverged:
      return SprintBoardGitHubPresentation(
        title: "Local work and GitHub both changed",
        detail: hasActiveDelivery
          ? "Spedito will combine the verified histories within each affected ticket and ask only if a product decision is needed."
          : "Spedito will combine the verified histories when the next affected ticket reaches review.",
        symbol: "arrow.triangle.merge",
        tone: .informational,
        actionTitle: nil,
        action: nil
      )
    case .unrelated:
      return SprintBoardGitHubPresentation(
        title: "GitHub history does not match this Product",
        detail: "Review the connected repository in Product settings.",
        symbol: "exclamationmark.triangle.fill",
        tone: .critical,
        actionTitle: nil,
        action: nil
      )
    case .aligned:
      return nil
    case nil:
      return SprintBoardGitHubPresentation(
        title: "GitHub has not been checked",
        detail: hasActiveDelivery
          ? "Spedito will check GitHub when an affected ticket reaches review."
          : "Check GitHub now for diagnostics, or continue and let ticket integration check automatically.",
        symbol: "arrow.trianglehead.2.clockwise.rotate.90",
        tone: .informational,
        actionTitle: "Check GitHub",
        action: .check
      )
    }
  }
}
struct SprintBoardGitHubStatus: View {
  @EnvironmentObject private var model: AppModel
  let productID: UUID
  let hasActiveDelivery: Bool
  @State private var showingIncomingReview = false

  private var snapshot: RemoteRepositoryPresentationSnapshot? {
    model.remoteRepositorySnapshotIfLoaded(for: productID)
  }

  private var state: GitHubRemoteRepositoryState? {
    snapshot?.repositoryState
  }

  private var isBusy: Bool {
    snapshot?.isBusy == true
  }

  private var presentation: SprintBoardGitHubPresentation? {
    let relationship = state?.observation?.relationship ?? state?.connection?.latestRelationship
    return SprintBoardGitHubPresentation.resolve(
      error: snapshot?.failure?.message,
      connectionStatus: state?.connection?.status,
      relationship: relationship,
      aheadCount: state?.observation?.aheadCount ?? state?.connection?.latestAheadCount ?? 0,
      behindCount: state?.observation?.behindCount ?? state?.connection?.latestBehindCount ?? 0,
      publicationStatus: state?.publication?.status,
      hasActiveDelivery: hasActiveDelivery
    )
  }

  var body: some View {
    if let presentation {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: presentation.symbol)
          .font(.title3.weight(.semibold))
          .foregroundStyle(color(for: presentation.tone))
          .frame(width: 24)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(presentation.title)
            .font(.callout.weight(.semibold))
          Text(presentation.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 16)

        if isBusy {
          ProgressView()
            .controlSize(.small)
        } else if let action = presentation.action,
          let actionTitle = presentation.actionTitle
        {
          Button(actionTitle) {
            perform(action)
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 10)
      .background(color(for: presentation.tone).opacity(0.07))
      .accessibilityElement(children: .contain)
      .sheet(isPresented: $showingIncomingReview) {
        if let sync = state?.safeSync, sync.status == .awaitingConfirmation {
          IncomingRepositoryReviewSheet(
            sync: sync,
            onAccept: {
              showingIncomingReview = false
              Task {
                await model.acceptIncomingRepositoryChange(
                  productID: productID,
                  syncID: sync.id
                )
              }
            },
            onReject: {
              showingIncomingReview = false
              Task {
                await model.rejectIncomingRepositoryChange(
                  productID: productID,
                  syncID: sync.id
                )
              }
            }
          )
        }
      }
    }
  }

  private func perform(_ action: SprintBoardGitHubAction) {
    switch action {
    case .check:
      Task { await model.checkRemoteRepository(productID: productID) }
    case .reviewIncoming:
      Task {
        await model.prepareIncomingRepositoryChange(productID: productID)
        if model.remoteRepositorySnapshot(for: productID).repositoryState.safeSync?.status
          == .awaitingConfirmation
        {
          showingIncomingReview = true
        }
      }
    }
  }

  private func color(for tone: SprintBoardGitHubPresentation.Tone) -> Color {
    switch tone {
    case .positive:
      .green
    case .informational:
      .blue
    case .attention:
      .orange
    case .critical:
      .red
    }
  }
}
