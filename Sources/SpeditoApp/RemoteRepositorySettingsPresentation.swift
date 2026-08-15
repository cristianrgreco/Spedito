import Foundation
import SpeditoCore

enum GitHubRepositoryAttentionPolicy {
  static func needsAttention(
    error: String?,
    connectionStatus: RemoteRepositoryConnectionStatus?,
    relationship: RemoteRepositoryRelationship?,
    publicationStatus: RemotePublicationStatus?
  ) -> Bool {
    if let error, !error.isEmpty {
      return true
    }
    switch connectionStatus {
    case .needsAuthorization, .needsInstallation, .needsTargetReview, .unavailable:
      return true
    case .selectingRepository, .initializingRemote, .connected, .disconnected, nil:
      break
    }
    switch relationship {
    case .diverged, .unrelated:
      return true
    case .aligned, .localAhead, .remoteAhead, .historyAlignmentAvailable, nil:
      break
    }
    switch publicationStatus {
    case .openStale, .stale, .failed:
      return true
    default:
      return false
    }
  }
}

enum GitHubRepositoryRelationshipVisibility {
  static func showsStatus(for relationship: RemoteRepositoryRelationship) -> Bool {
    switch relationship {
    case .aligned:
      false
    case .localAhead, .remoteAhead, .historyAlignmentAvailable, .diverged, .unrelated:
      true
    }
  }
}

enum GitHubRepositorySetupLaunch: Equatable {
  case repositoryPicker
  case installation
  case none

  static func resolve(
    status: RemoteRepositoryConnectionStatus?
  ) -> GitHubRepositorySetupLaunch {
    switch status {
    case .selectingRepository:
      .repositoryPicker
    case .needsInstallation:
      .installation
    default:
      .none
    }
  }
}

struct GitHubVerifiedRepositoryPresentation: Equatable {
  let message: String
  let actionTitle: String

  static func resolve(hasExistingHistory: Bool) -> GitHubVerifiedRepositoryPresentation {
    if hasExistingHistory {
      return GitHubVerifiedRepositoryPresentation(
        message:
          "Spedito will initialize this empty repository, then publish the Product's existing work through one pull request. No action is needed on GitHub.",
        actionTitle: "Connect and publish"
      )
    }
    return GitHubVerifiedRepositoryPresentation(
      message: "Spedito will initialize this empty repository with the Product.",
      actionTitle: "Connect repository"
    )
  }
}

enum GitHubRepositoryPickerContent: Equatable {
  case loading
  case failure(String)
  case empty
  case repositories

  static func resolve(
    repositoryCount: Int,
    isBusy: Bool,
    error: String?
  ) -> GitHubRepositoryPickerContent {
    if repositoryCount > 0 {
      return .repositories
    }
    if isBusy {
      return .loading
    }
    if let error, !error.isEmpty {
      return .failure(error)
    }
    return .empty
  }
}
struct GitHubRepositorySetupPresentation: Equatable {
  enum Step: Equatable {
    case chooseRepository
    case verifyRepository
    case checkingRepository
    case reviewAndConnect
    case chooseAnotherRepository
  }

  let step: Step
  let actionTitle: String?

  static func resolve(
    repositoryID: Int64?,
    eligibility: GitHubRepositoryEligibility?
  ) -> GitHubRepositorySetupPresentation {
    switch eligibility {
    case .checking:
      GitHubRepositorySetupPresentation(step: .checkingRepository, actionTitle: nil)
    case .empty:
      GitHubRepositorySetupPresentation(
        step: .reviewAndConnect,
        actionTitle: "Review and connect"
      )
    case .ineligible:
      GitHubRepositorySetupPresentation(
        step: .chooseAnotherRepository,
        actionTitle: "Choose another repository"
      )
    case .unchecked, nil:
      if repositoryID == nil {
        GitHubRepositorySetupPresentation(
          step: .chooseRepository,
          actionTitle: "Choose repository"
        )
      } else {
        GitHubRepositorySetupPresentation(
          step: .verifyRepository,
          actionTitle: "Continue setup"
        )
      }
    }
  }
}

struct GitHubRepositoryInitializationPresentation: Equatable {
  let title: String
  let detail: String
  let step: Int
  let stepCount: Int
  let isComplete: Bool

  static func resolve(
    activity: GitHubRepositorySetupActivity
  ) -> GitHubRepositoryInitializationPresentation {
    switch activity {
    case .inProgress(let progress, let publishesExistingHistory):
      let stepCount = publishesExistingHistory ? 6 : 4
      return switch progress {
      case .validatingProduct:
        GitHubRepositoryInitializationPresentation(
          title: "Checking the Product",
          detail: "Verifying that local history can be published safely.",
          step: 1,
          stepCount: stepCount,
          isComplete: false
        )
      case .publishingBootstrap:
        GitHubRepositoryInitializationPresentation(
          title: "Initializing the GitHub repository",
          detail: "Publishing the Product’s first commit to establish the default branch.",
          step: 2,
          stepCount: stepCount,
          isComplete: false
        )
      case .verifyingConnection:
        GitHubRepositoryInitializationPresentation(
          title: "Confirming the connection",
          detail: "Verifying the repository identity and local Git connection.",
          step: 3,
          stepCount: stepCount,
          isComplete: false
        )
      case .checkingRepository:
        GitHubRepositoryInitializationPresentation(
          title: "Comparing local and GitHub history",
          detail: "Confirming the exact revisions before publishing further work.",
          step: 4,
          stepCount: stepCount,
          isComplete: false
        )
      case .publishingExistingHistory:
        GitHubRepositoryInitializationPresentation(
          title: "Publishing existing Product work",
          detail: "Creating one review branch and pull request for the accepted local history.",
          step: 5,
          stepCount: stepCount,
          isComplete: false
        )
      case .mergingExistingHistory:
        GitHubRepositoryInitializationPresentation(
          title: "Finishing the pull request",
          detail: "Merging the exact published revision and aligning local history.",
          step: 6,
          stepCount: stepCount,
          isComplete: false
        )
      }
    case .completed(let publishedExistingHistory):
      return GitHubRepositoryInitializationPresentation(
        title: "GitHub repository connected",
        detail: publishedExistingHistory
          ? "Spedito initialized the repository, merged the pull request, and aligned the local Product."
          : "Spedito initialized the repository. Future Product changes will use pull requests.",
        step: publishedExistingHistory ? 6 : 4,
        stepCount: publishedExistingHistory ? 6 : 4,
        isComplete: true
      )
    }
  }
}

struct GitHubRepositoryPickerDismissalPolicy {
  static func canDismiss(activity: GitHubRepositorySetupActivity?) -> Bool {
    activity?.isInProgress != true
  }
}
