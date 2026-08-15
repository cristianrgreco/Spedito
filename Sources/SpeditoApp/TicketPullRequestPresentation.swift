import SpeditoCore

struct GitHubPullRequestActionPresentation: Equatable {
  let title: String
  let isPrimary: Bool
  let showsButton: Bool

  static func resolve(
    purpose: RemotePublicationPurpose,
    status: RemotePublicationStatus,
    relationship: RemoteRepositoryRelationship?,
    hasAcceptedSynchronization: Bool
  ) -> GitHubPullRequestActionPresentation {
    let setupIsComplete =
      purpose == .existingProductHistory
      && status == .merged
      && (relationship == .aligned || hasAcceptedSynchronization)
    let isFinishingSetup =
      purpose == .existingProductHistory
      && (status == .open || (status == .merged && !setupIsComplete))
    if isFinishingSetup {
      return GitHubPullRequestActionPresentation(
        title: "Finish GitHub setup",
        isPrimary: true,
        showsButton: true
      )
    }
    return GitHubPullRequestActionPresentation(
      title: "Refresh pull request",
      isPrimary: false,
      showsButton: !setupIsComplete
    )
  }
}
