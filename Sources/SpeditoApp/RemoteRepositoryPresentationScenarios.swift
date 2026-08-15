#if DEBUG
  import Foundation
  import SpeditoCore

  enum RemoteRepositoryPresentationScenarioID: String, CaseIterable, Identifiable {
    case githubUnavailable
    case notConnected
    case waitingForDeviceFlow
    case waitingForInstallationAccess
    case loadingRepositories
    case noAccessibleRepositories
    case checkingRepositoryEligibility
    case eligibleEmptyRepository
    case ineligibleRepository
    case publishingBootstrap
    case publishingExistingHistory
    case connectedAndAligned
    case incomingChangesAvailable
    case awaitingSafeSyncConfirmation
    case divergedHistory
    case unrelatedHistory
    case publishingDraftPullRequest
    case pullRequestAwaitingReview
    case changesRequested
    case pullRequestReadyForApproval
    case mergedAwaitingReconciliation
    case retryableFailure

    var id: String { rawValue }
  }

  struct RemoteRepositoryPresentationScenario: Identifiable, Equatable {
    let id: RemoteRepositoryPresentationScenarioID
    let title: String
    let snapshot: RemoteRepositoryPresentationSnapshot
    let ticketContext: String?

    init(
      id: RemoteRepositoryPresentationScenarioID,
      title: String,
      snapshot: RemoteRepositoryPresentationSnapshot,
      ticketContext: String? = nil
    ) {
      self.id = id
      self.title = title
      self.snapshot = snapshot
      self.ticketContext = ticketContext
    }
  }

  enum RemoteRepositoryPresentationScenarioCatalog {
    static let all: [RemoteRepositoryPresentationScenario] = [
      scenario(.githubUnavailable, "GitHub unavailable in this build", configured: false),
      scenario(.notConnected, "Not connected", status: .disconnected),
      scenario(
        .waitingForDeviceFlow,
        "Waiting for Device Flow",
        status: .needsAuthorization,
        prompt: GitHubDeviceAuthorizationPrompt(
          userCode: "SPEDITO1",
          verificationURL: URL(string: "https://github.com/login/device")!,
          expiresAt: referenceDate.addingTimeInterval(900)
        ),
        isBusy: true
      ),
      scenario(
        .waitingForInstallationAccess, "Waiting for installation access", status: .needsInstallation
      ),
      scenario(
        .loadingRepositories, "Loading repositories", status: .selectingRepository, isBusy: true),
      scenario(
        .noAccessibleRepositories, "No accessible repositories", status: .selectingRepository),
      repositorySelectionScenario(
        .checkingRepositoryEligibility,
        "Repository eligibility checking",
        eligibility: .checking,
        isBusy: true
      ),
      repositorySelectionScenario(
        .eligibleEmptyRepository,
        "Eligible empty repository",
        eligibility: .empty(bootstrap: bootstrap, existingHistory: nil)
      ),
      repositorySelectionScenario(
        .ineligibleRepository,
        "Ineligible repository",
        eligibility: .ineligible("This repository already contains history.")
      ),
      scenario(
        .publishingBootstrap,
        "Publishing bootstrap",
        status: .initializingRemote,
        isBusy: true,
        activity: .inProgress(progress: .publishingBootstrap, publishesExistingHistory: false)
      ),
      scenario(
        .publishingExistingHistory,
        "Publishing and merging existing history",
        status: .initializingRemote,
        isBusy: true,
        activity: .inProgress(progress: .mergingExistingHistory, publishesExistingHistory: true)
      ),
      connectedScenario(.connectedAndAligned, "Connected and aligned", relationship: .aligned),
      connectedScenario(
        .incomingChangesAvailable,
        "Incoming changes available",
        relationship: .remoteAhead
      ),
      connectedScenario(
        .awaitingSafeSyncConfirmation,
        "Awaiting safe-sync confirmation",
        relationship: .remoteAhead,
        safeSync: safeSync
      ),
      connectedScenario(.divergedHistory, "Diverged history", relationship: .diverged),
      connectedScenario(.unrelatedHistory, "Unrelated history", relationship: .unrelated),
      connectedScenario(
        .publishingDraftPullRequest,
        "Draft pull request publishing",
        relationship: .localAhead,
        publication: publication(status: .pushing)
      ),
      connectedScenario(
        .pullRequestAwaitingReview,
        "Pull request awaiting review",
        relationship: .localAhead,
        publication: publication(status: .open, isDraft: true)
      ),
      connectedScenario(
        .changesRequested,
        "Changes requested",
        relationship: .localAhead,
        publication: publication(status: .open, isDraft: false),
        ticketContext: "The latest durable ticket work-log entry records requested changes."
      ),
      connectedScenario(
        .pullRequestReadyForApproval,
        "Pull request ready for owner approval",
        relationship: .localAhead,
        publication: publication(status: .open, isDraft: false),
        ticketContext: "The reviewed candidate is ready for demo and product owner approval."
      ),
      connectedScenario(
        .mergedAwaitingReconciliation,
        "Remote merge completed but local reconciliation interrupted",
        relationship: .remoteAhead,
        publication: publication(status: .merged, isDraft: false, mergedSHA: remoteSHA),
        failure: RemoteRepositoryFeatureFailure(
          kind: .operation,
          message: "GitHub merged the pull request. Spedito still needs to reconcile local history."
        )
      ),
      scenario(
        .retryableFailure,
        "Retryable API or authorization failure",
        status: .needsAuthorization,
        failure: RemoteRepositoryFeatureFailure(
          kind: .operation,
          message: "GitHub authorization expired. Try connecting again."
        )
      ),
    ]

    private static let productID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let publicationID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private static let workItemID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    private static let candidateRevisionID = UUID(
      uuidString: "00000000-0000-0000-0000-000000000006")!
    private static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let localSHA = String(repeating: "1", count: 40)
    private static let localTree = String(repeating: "2", count: 40)
    private static let remoteSHA = String(repeating: "3", count: 40)
    private static let remoteTree = String(repeating: "4", count: 40)
    private static let repositoryURL = URL(string: "https://github.com/example/product.git")!
    private static let permissions = RemoteRepositoryPermissions(
      metadataRead: true,
      contentsWrite: true,
      pullRequestsWrite: true,
      workflowsWrite: true
    )
    private static let bootstrap = GitBootstrapRoot(sha: localSHA, tree: localTree)

    private static func scenario(
      _ id: RemoteRepositoryPresentationScenarioID,
      _ title: String,
      configured: Bool = true,
      status: RemoteRepositoryConnectionStatus? = nil,
      prompt: GitHubDeviceAuthorizationPrompt? = nil,
      isBusy: Bool = false,
      activity: GitHubRepositorySetupActivity? = nil,
      failure: RemoteRepositoryFeatureFailure? = nil
    ) -> RemoteRepositoryPresentationScenario {
      let connection = status.map { Self.connection(status: $0) }
      return RemoteRepositoryPresentationScenario(
        id: id,
        title: title,
        snapshot: RemoteRepositoryPresentationSnapshot(
          productID: productID,
          repositoryState: GitHubRemoteRepositoryState(
            isConfigured: configured,
            connection: connection
          ),
          authorizationPrompt: prompt,
          isBusy: isBusy,
          failure: failure,
          setupActivity: activity
        )
      )
    }

    private static func repositorySelectionScenario(
      _ id: RemoteRepositoryPresentationScenarioID,
      _ title: String,
      eligibility: GitHubRepositoryEligibility,
      isBusy: Bool = false
    ) -> RemoteRepositoryPresentationScenario {
      let repository = GitHubRepository(
        id: 101,
        owner: "example",
        name: "product",
        fullName: "example/product",
        htmlURL: URL(string: "https://github.com/example/product")!,
        canonicalHTTPSURL: repositoryURL,
        isPrivate: true,
        defaultBranch: "main"
      )
      return RemoteRepositoryPresentationScenario(
        id: id,
        title: title,
        snapshot: RemoteRepositoryPresentationSnapshot(
          productID: productID,
          repositoryState: GitHubRemoteRepositoryState(
            isConfigured: true,
            connection: connection(status: .selectingRepository),
            repositories: [
              GitHubRepositoryChoice(
                installationID: 201,
                repository: repository,
                permissions: permissions,
                eligibility: eligibility
              )
            ],
            selectedEligibility: eligibility
          ),
          isBusy: isBusy
        )
      )
    }

    private static func connectedScenario(
      _ id: RemoteRepositoryPresentationScenarioID,
      _ title: String,
      relationship: RemoteRepositoryRelationship,
      safeSync: RemoteSafeSync? = nil,
      publication: RemotePublication? = nil,
      failure: RemoteRepositoryFeatureFailure? = nil,
      ticketContext: String? = nil
    ) -> RemoteRepositoryPresentationScenario {
      RemoteRepositoryPresentationScenario(
        id: id,
        title: title,
        snapshot: RemoteRepositoryPresentationSnapshot(
          productID: productID,
          repositoryState: GitHubRemoteRepositoryState(
            isConfigured: true,
            connection: connection(status: .connected, relationship: relationship),
            observation: observation(relationship: relationship),
            safeSync: safeSync,
            publications: publication.map { [$0] } ?? []
          ),
          failure: failure
        ),
        ticketContext: ticketContext
      )
    }

    private static func connection(
      status: RemoteRepositoryConnectionStatus,
      relationship: RemoteRepositoryRelationship? = nil
    ) -> RemoteRepositoryConnection {
      RemoteRepositoryConnection(
        id: connectionID,
        productID: productID,
        kind: .localEmptyRepository,
        accountID: accountID,
        installationID: 201,
        repositoryID: 101,
        owner: "example",
        name: "product",
        fullName: "example/product",
        canonicalHTTPSURL: repositoryURL,
        isPrivate: true,
        defaultBranch: "main",
        permissions: permissions,
        status: status,
        latestLocalSHA: localSHA,
        latestLocalTree: localTree,
        latestRemoteSHA: remoteSHA,
        latestRemoteTree: remoteTree,
        latestRelationship: relationship,
        latestAheadCount: relationship == .localAhead ? 1 : 0,
        latestBehindCount: relationship == .remoteAhead ? 1 : 0,
        latestCheckedAt: referenceDate,
        createdAt: referenceDate,
        updatedAt: referenceDate
      )
    }

    private static func observation(
      relationship: RemoteRepositoryRelationship
    ) -> RemoteRepositoryObservation {
      RemoteRepositoryObservation(
        connectionVersion: 1,
        repositoryID: 101,
        fullName: "example/product",
        canonicalHTTPSURL: repositoryURL,
        isPrivate: true,
        defaultBranch: "main",
        localSHA: localSHA,
        localTree: localTree,
        remoteSHA: remoteSHA,
        remoteTree: remoteTree,
        mergeBaseSHA: localSHA,
        aheadCount: relationship == .localAhead ? 1 : 0,
        behindCount: relationship == .remoteAhead ? 1 : 0,
        relationship: relationship,
        observationRef: "refs/spedito/observations/example",
        commits: [RemoteCommitSummary(sha: remoteSHA, subject: "Update product")],
        paths: ["Sources/Product.swift"],
        observedAt: referenceDate
      )
    }

    private static let safeSync = RemoteSafeSync(
      productID: productID,
      connectionID: connectionID,
      connectionVersion: 1,
      kind: .fastForward,
      observationRef: "refs/spedito/observations/example",
      localSHA: localSHA,
      localTree: localTree,
      remoteSHA: remoteSHA,
      remoteTree: remoteTree,
      mergeBaseSHA: localSHA,
      candidateSHA: remoteSHA,
      candidateTree: remoteTree,
      commits: [RemoteCommitSummary(sha: remoteSHA, subject: "Update product")],
      paths: ["Sources/Product.swift"],
      createdAt: referenceDate,
      updatedAt: referenceDate
    )

    private static func publication(
      status: RemotePublicationStatus,
      isDraft: Bool = true,
      mergedSHA: String? = nil
    ) -> RemotePublication {
      let pullRequest: RemotePullRequestSnapshot? =
        switch status {
        case .open, .openOutdated, .openStale, .merged, .closed:
          RemotePullRequestSnapshot(
            number: 42,
            nodeID: "PR_42",
            canonicalURL: URL(string: "https://github.com/example/product/pull/42")!,
            state: status == .merged ? .merged : status == .closed ? .closed : .open,
            isDraft: isDraft,
            headSHA: localSHA,
            baseBranch: "main",
            baseSHA: remoteSHA,
            mergedSHA: mergedSHA,
            updatedAt: referenceDate
          )
        default:
          nil
        }
      return RemotePublication(
        id: publicationID,
        productID: productID,
        connectionID: connectionID,
        workItemID: workItemID,
        candidateRevisionID: candidateRevisionID,
        purpose: .ticket,
        accountID: accountID,
        repositoryID: 101,
        owner: "example",
        name: "product",
        fullName: "example/product",
        canonicalHTTPSURL: repositoryURL,
        isPrivate: true,
        permissions: permissions,
        capturedLocalSHA: localSHA,
        capturedLocalTree: localTree,
        remoteBaseSHA: remoteSHA,
        remoteBaseTree: remoteTree,
        targetBranch: "main",
        publicationBranch: "spedito/ticket-42",
        manifestDigest: "manifest",
        manifestObjectCount: 1,
        manifestCommitCount: 1,
        manifestPathCount: 1,
        commits: [RemoteCommitSummary(sha: localSHA, subject: "Deliver ticket")],
        paths: ["Sources/Product.swift"],
        title: "Deliver ticket",
        body: "Reviewed change",
        status: status,
        pushedSHA: localSHA,
        pullRequest: pullRequest,
        createdAt: referenceDate,
        updatedAt: referenceDate
      )
    }
  }
#endif
