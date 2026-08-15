import Foundation

public enum RemoteRepositoryConnectionKind: String, Codable, Sendable {
  case importedSource = "imported_source"
  case localEmptyRepository = "local_empty_repository"
}

public enum RemoteRepositoryConnectionStatus: String, Codable, Sendable {
  case selectingRepository = "selecting_repository"
  case initializingRemote = "initializing_remote"
  case connected
  case disconnected
  case needsAuthorization = "needs_authorization"
  case needsInstallation = "needs_installation"
  case needsTargetReview = "needs_target_review"
  case unavailable
}

public enum RemoteRepositoryRelationship: String, Codable, Sendable {
  case aligned
  case localAhead = "local_ahead"
  case remoteAhead = "remote_ahead"
  case historyAlignmentAvailable = "history_alignment_available"
  case diverged
  case unrelated
}

public enum RemoteSafeSyncKind: String, Codable, Sendable {
  case fastForward = "fast_forward"
  case historyAlignment = "history_alignment"
}

public enum RemoteSafeSyncStatus: String, Codable, Sendable {
  case awaitingConfirmation = "awaiting_confirmation"
  case accepting
  case accepted
  case rejected
  case stale
  case failed

  public var isActive: Bool {
    self == .awaitingConfirmation || self == .accepting
  }
}

public enum RemotePullRequestState: String, Codable, Sendable {
  case open
  case closed
  case merged
}

public enum RemotePublicationStatus: String, Codable, Sendable {
  case awaitingConfirmation = "awaiting_confirmation"
  case checking
  case pushing
  case branchPublished = "branch_published"
  case creatingPullRequest = "creating_pull_request"
  case open
  case openOutdated = "open_outdated"
  case openStale = "open_stale"
  case merged
  case closed
  case cancelled
  case stale
  case failed

  public var isActive: Bool {
    switch self {
    case .awaitingConfirmation, .checking, .pushing, .branchPublished,
      .creatingPullRequest, .open, .openOutdated, .openStale:
      true
    case .merged, .closed, .cancelled, .stale, .failed:
      false
    }
  }

  public var hasPullRequest: Bool {
    switch self {
    case .open, .openOutdated, .openStale, .merged, .closed:
      true
    default:
      false
    }
  }
}

public enum RemotePublicationPurpose: String, Codable, Sendable {
  case existingProductHistory = "existing_product_history"
  case ticket
}

public struct RemoteRepositoryPermissions: Codable, Equatable, Sendable {
  public var metadataRead: Bool
  public var contentsWrite: Bool
  public var pullRequestsWrite: Bool
  public var workflowsWrite: Bool

  public init(
    metadataRead: Bool,
    contentsWrite: Bool,
    pullRequestsWrite: Bool,
    workflowsWrite: Bool
  ) {
    self.metadataRead = metadataRead
    self.contentsWrite = contentsWrite
    self.pullRequestsWrite = pullRequestsWrite
    self.workflowsWrite = workflowsWrite
  }

  public var permitsPublication: Bool {
    metadataRead && contentsWrite && pullRequestsWrite && workflowsWrite
  }
}

public struct RemoteCommitSummary: Codable, Equatable, Identifiable, Sendable {
  public var id: String { sha }
  public let sha: String
  public let subject: String

  public init(sha: String, subject: String) {
    self.sha = sha
    self.subject = subject
  }
}

public struct RemoteRepositoryConnection: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let productID: UUID
  public var version: Int
  public let kind: RemoteRepositoryConnectionKind
  public var accountID: UUID?
  public var installationID: Int64?
  public var repositoryID: Int64?
  public var owner: String?
  public var name: String?
  public var fullName: String?
  public var canonicalHTTPSURL: URL?
  public var isPrivate: Bool?
  public var defaultBranch: String?
  public var permissions: RemoteRepositoryPermissions
  public var status: RemoteRepositoryConnectionStatus
  public var errorCode: String?
  public var latestLocalSHA: String?
  public var latestLocalTree: String?
  public var latestRemoteSHA: String?
  public var latestRemoteTree: String?
  public var latestRelationship: RemoteRepositoryRelationship?
  public var latestAheadCount: Int?
  public var latestBehindCount: Int?
  public var latestCheckedAt: Date?
  public var pendingRepositoryID: Int64?
  public var pendingFullName: String?
  public var pendingCanonicalHTTPSURL: URL?
  public var pendingDefaultBranch: String?
  public var pendingObservedAt: Date?
  public var bootstrapRootSHA: String?
  public var bootstrapRootTree: String?
  public var initializationAttemptCount: Int
  public var seededSHA: String?
  public var originVerified: Bool?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    version: Int = 1,
    kind: RemoteRepositoryConnectionKind,
    accountID: UUID? = nil,
    installationID: Int64? = nil,
    repositoryID: Int64? = nil,
    owner: String? = nil,
    name: String? = nil,
    fullName: String? = nil,
    canonicalHTTPSURL: URL? = nil,
    isPrivate: Bool? = nil,
    defaultBranch: String? = nil,
    permissions: RemoteRepositoryPermissions = .init(
      metadataRead: false,
      contentsWrite: false,
      pullRequestsWrite: false,
      workflowsWrite: false
    ),
    status: RemoteRepositoryConnectionStatus,
    errorCode: String? = nil,
    latestLocalSHA: String? = nil,
    latestLocalTree: String? = nil,
    latestRemoteSHA: String? = nil,
    latestRemoteTree: String? = nil,
    latestRelationship: RemoteRepositoryRelationship? = nil,
    latestAheadCount: Int? = nil,
    latestBehindCount: Int? = nil,
    latestCheckedAt: Date? = nil,
    pendingRepositoryID: Int64? = nil,
    pendingFullName: String? = nil,
    pendingCanonicalHTTPSURL: URL? = nil,
    pendingDefaultBranch: String? = nil,
    pendingObservedAt: Date? = nil,
    bootstrapRootSHA: String? = nil,
    bootstrapRootTree: String? = nil,
    initializationAttemptCount: Int = 0,
    seededSHA: String? = nil,
    originVerified: Bool? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.version = version
    self.kind = kind
    self.accountID = accountID
    self.installationID = installationID
    self.repositoryID = repositoryID
    self.owner = owner
    self.name = name
    self.fullName = fullName
    self.canonicalHTTPSURL = canonicalHTTPSURL
    self.isPrivate = isPrivate
    self.defaultBranch = defaultBranch
    self.permissions = permissions
    self.status = status
    self.errorCode = errorCode
    self.latestLocalSHA = latestLocalSHA
    self.latestLocalTree = latestLocalTree
    self.latestRemoteSHA = latestRemoteSHA
    self.latestRemoteTree = latestRemoteTree
    self.latestRelationship = latestRelationship
    self.latestAheadCount = latestAheadCount
    self.latestBehindCount = latestBehindCount
    self.latestCheckedAt = latestCheckedAt
    self.pendingRepositoryID = pendingRepositoryID
    self.pendingFullName = pendingFullName
    self.pendingCanonicalHTTPSURL = pendingCanonicalHTTPSURL
    self.pendingDefaultBranch = pendingDefaultBranch
    self.pendingObservedAt = pendingObservedAt
    self.bootstrapRootSHA = bootstrapRootSHA
    self.bootstrapRootTree = bootstrapRootTree
    self.initializationAttemptCount = initializationAttemptCount
    self.seededSHA = seededSHA
    self.originVerified = originVerified
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RemoteRepositoryObservation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let connectionVersion: Int
  public let repositoryID: Int64
  public let fullName: String
  public let canonicalHTTPSURL: URL
  public let isPrivate: Bool
  public let defaultBranch: String
  public let localSHA: String
  public let localTree: String
  public let remoteSHA: String
  public let remoteTree: String
  public let mergeBaseSHA: String?
  public let aheadCount: Int
  public let behindCount: Int
  public let relationship: RemoteRepositoryRelationship
  public let observationRef: String
  public let commits: [RemoteCommitSummary]
  public let paths: [String]
  public let observedAt: Date

  public init(
    id: UUID = UUID(),
    connectionVersion: Int,
    repositoryID: Int64,
    fullName: String,
    canonicalHTTPSURL: URL,
    isPrivate: Bool,
    defaultBranch: String,
    localSHA: String,
    localTree: String,
    remoteSHA: String,
    remoteTree: String,
    mergeBaseSHA: String?,
    aheadCount: Int,
    behindCount: Int,
    relationship: RemoteRepositoryRelationship,
    observationRef: String,
    commits: [RemoteCommitSummary],
    paths: [String],
    observedAt: Date = Date()
  ) {
    self.id = id
    self.connectionVersion = connectionVersion
    self.repositoryID = repositoryID
    self.fullName = fullName
    self.canonicalHTTPSURL = canonicalHTTPSURL
    self.isPrivate = isPrivate
    self.defaultBranch = defaultBranch
    self.localSHA = localSHA
    self.localTree = localTree
    self.remoteSHA = remoteSHA
    self.remoteTree = remoteTree
    self.mergeBaseSHA = mergeBaseSHA
    self.aheadCount = aheadCount
    self.behindCount = behindCount
    self.relationship = relationship
    self.observationRef = observationRef
    self.commits = commits
    self.paths = paths
    self.observedAt = observedAt
  }
}

public struct RemoteSafeSync: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let connectionID: UUID
  public var version: Int
  public let connectionVersion: Int
  public let kind: RemoteSafeSyncKind
  public var status: RemoteSafeSyncStatus
  public let observationRef: String
  public let localSHA: String
  public let localTree: String
  public let remoteSHA: String
  public let remoteTree: String
  public let mergeBaseSHA: String?
  public let candidateSHA: String
  public let candidateTree: String
  public let provingPublicationID: UUID?
  public let publishedSHA: String?
  public let commits: [RemoteCommitSummary]
  public let paths: [String]
  public var errorCode: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    connectionID: UUID,
    version: Int = 1,
    connectionVersion: Int,
    kind: RemoteSafeSyncKind,
    status: RemoteSafeSyncStatus = .awaitingConfirmation,
    observationRef: String,
    localSHA: String,
    localTree: String,
    remoteSHA: String,
    remoteTree: String,
    mergeBaseSHA: String?,
    candidateSHA: String,
    candidateTree: String,
    provingPublicationID: UUID? = nil,
    publishedSHA: String? = nil,
    commits: [RemoteCommitSummary] = [],
    paths: [String] = [],
    errorCode: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.connectionID = connectionID
    self.version = version
    self.connectionVersion = connectionVersion
    self.kind = kind
    self.status = status
    self.observationRef = observationRef
    self.localSHA = localSHA
    self.localTree = localTree
    self.remoteSHA = remoteSHA
    self.remoteTree = remoteTree
    self.mergeBaseSHA = mergeBaseSHA
    self.candidateSHA = candidateSHA
    self.candidateTree = candidateTree
    self.provingPublicationID = provingPublicationID
    self.publishedSHA = publishedSHA
    self.commits = commits
    self.paths = paths
    self.errorCode = errorCode
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RemotePullRequestSnapshot: Codable, Equatable, Sendable {
  public let number: Int
  public let nodeID: String
  public let canonicalURL: URL
  public let state: RemotePullRequestState
  public let isDraft: Bool
  public let headSHA: String
  public let baseBranch: String
  public let baseSHA: String
  public let mergedSHA: String?
  public let updatedAt: Date

  public init(
    number: Int,
    nodeID: String,
    canonicalURL: URL,
    state: RemotePullRequestState,
    isDraft: Bool,
    headSHA: String,
    baseBranch: String,
    baseSHA: String,
    mergedSHA: String?,
    updatedAt: Date
  ) {
    self.number = number
    self.nodeID = nodeID
    self.canonicalURL = canonicalURL
    self.state = state
    self.isDraft = isDraft
    self.headSHA = headSHA
    self.baseBranch = baseBranch
    self.baseSHA = baseSHA
    self.mergedSHA = mergedSHA
    self.updatedAt = updatedAt
  }
}

public struct RemotePublication: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let productID: UUID
  public let connectionID: UUID
  public let workItemID: UUID?
  public var candidateRevisionID: UUID?
  public let purpose: RemotePublicationPurpose
  public var version: Int
  public var pushAttemptCount: Int
  public var pullRequestAttemptCount: Int
  public let accountID: UUID
  public let repositoryID: Int64
  public let owner: String
  public let name: String
  public let fullName: String
  public let canonicalHTTPSURL: URL
  public let isPrivate: Bool
  public let permissions: RemoteRepositoryPermissions
  public var capturedLocalSHA: String
  public var capturedLocalTree: String
  public var remoteBaseSHA: String
  public var remoteBaseTree: String
  public let targetBranch: String
  public let publicationBranch: String
  public var manifestDigest: String
  public var manifestObjectCount: Int
  public var manifestCommitCount: Int
  public var manifestPathCount: Int
  public var commits: [RemoteCommitSummary]
  public var paths: [String]
  public var title: String
  public var body: String
  public var textRevision: Int
  public var status: RemotePublicationStatus
  public var pushedSHA: String?
  public var pullRequest: RemotePullRequestSnapshot?
  public var remoteBranchDeletedAt: Date?
  public var errorCode: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    productID: UUID,
    connectionID: UUID,
    workItemID: UUID? = nil,
    candidateRevisionID: UUID? = nil,
    purpose: RemotePublicationPurpose,
    version: Int = 1,
    pushAttemptCount: Int = 0,
    pullRequestAttemptCount: Int = 0,
    accountID: UUID,
    repositoryID: Int64,
    owner: String,
    name: String,
    fullName: String,
    canonicalHTTPSURL: URL,
    isPrivate: Bool,
    permissions: RemoteRepositoryPermissions,
    capturedLocalSHA: String,
    capturedLocalTree: String,
    remoteBaseSHA: String,
    remoteBaseTree: String,
    targetBranch: String,
    publicationBranch: String,
    manifestDigest: String,
    manifestObjectCount: Int,
    manifestCommitCount: Int,
    manifestPathCount: Int,
    commits: [RemoteCommitSummary],
    paths: [String],
    title: String,
    body: String,
    textRevision: Int = 1,
    status: RemotePublicationStatus = .awaitingConfirmation,
    pushedSHA: String? = nil,
    pullRequest: RemotePullRequestSnapshot? = nil,
    remoteBranchDeletedAt: Date? = nil,
    errorCode: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.productID = productID
    self.connectionID = connectionID
    self.workItemID = workItemID
    self.candidateRevisionID = candidateRevisionID
    self.purpose = purpose
    self.version = version
    self.pushAttemptCount = pushAttemptCount
    self.pullRequestAttemptCount = pullRequestAttemptCount
    self.accountID = accountID
    self.repositoryID = repositoryID
    self.owner = owner
    self.name = name
    self.fullName = fullName
    self.canonicalHTTPSURL = canonicalHTTPSURL
    self.isPrivate = isPrivate
    self.permissions = permissions
    self.capturedLocalSHA = capturedLocalSHA
    self.capturedLocalTree = capturedLocalTree
    self.remoteBaseSHA = remoteBaseSHA
    self.remoteBaseTree = remoteBaseTree
    self.targetBranch = targetBranch
    self.publicationBranch = publicationBranch
    self.manifestDigest = manifestDigest
    self.manifestObjectCount = manifestObjectCount
    self.manifestCommitCount = manifestCommitCount
    self.manifestPathCount = manifestPathCount
    self.commits = commits
    self.paths = paths
    self.title = title
    self.body = body
    self.textRevision = textRevision
    self.status = status
    self.pushedSHA = pushedSHA
    self.pullRequest = pullRequest
    self.remoteBranchDeletedAt = remoteBranchDeletedAt
    self.errorCode = errorCode
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
