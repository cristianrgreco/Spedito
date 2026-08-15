import CryptoKit
import Foundation

public enum GitHubAPIError: Error, Equatable, LocalizedError, Sendable {
  case cancelled
  case timedOut
  case unauthorized
  case forbidden(String)
  case notFound
  case conflict
  case unprocessable(String)
  case rateLimited(retryAfter: TimeInterval?)
  case serverUnavailable
  case invalidResponse
  case responseTooLarge
  case authorizationDenied
  case authorizationExpired
  public enum RequestContext: Equatable, Sendable {
    case authorization
    case repository
  }

  public var errorDescription: String? {
    localizedDescription(context: .repository)
  }

  public func localizedDescription(context: RequestContext) -> String {
    switch self {
    case .cancelled:
      "The GitHub request was cancelled."
    case .timedOut:
      "GitHub did not respond in time. Try again."
    case .unauthorized:
      "GitHub authorization is no longer valid. Sign in again."
    case .forbidden(let reason):
      reason
    case .notFound:
      switch context {
      case .authorization:
        "GitHub could not find this App registration. Verify the build’s GitHub client ID, enable Device Flow for that GitHub App, then rebuild Spedito."
      case .repository:
        "The GitHub repository is unavailable or no longer accessible."
      }
    case .conflict:
      "GitHub reported a repository conflict. Check the repository and try again."
    case .unprocessable(let reason):
      reason
    case .rateLimited(let retryAfter):
      if let retryAfter {
        "GitHub is limiting requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
      } else {
        "GitHub is limiting requests. Try again later."
      }
    case .serverUnavailable:
      "GitHub is temporarily unavailable. Try again."
    case .invalidResponse:
      "GitHub returned an invalid response. Try again."
    case .responseTooLarge:
      "GitHub returned more information than Spedito can safely process."
    case .authorizationDenied:
      "GitHub authorization was denied."
    case .authorizationExpired:
      "The GitHub authorization code expired. Try again."
    }
  }
}

public protocol GitHubHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class GitHubRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public actor GitHubURLSessionTransport: GitHubHTTPTransport {
  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    session = URLSession(
      configuration: configuration,
      delegate: GitHubRedirectDelegate(),
      delegateQueue: nil
    )
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw GitHubAPIError.invalidResponse
    }
    return (data, response)
  }
}

public struct GitHubUser: Equatable, Sendable {
  public let id: Int64
  public let login: String
}

public struct GitHubInstallationPermissions: Codable, Equatable, Sendable {
  public let metadata: String?
  public let contents: String?
  public let pullRequests: String?
  public let workflows: String?

  enum CodingKeys: String, CodingKey {
    case metadata
    case contents
    case pullRequests = "pull_requests"
    case workflows
  }

  public init(
    metadata: String? = nil,
    contents: String? = nil,
    pullRequests: String? = nil,
    workflows: String? = nil
  ) {
    self.metadata = metadata
    self.contents = contents
    self.pullRequests = pullRequests
    self.workflows = workflows
  }

  public var permitsPublication: Bool {
    Self.canRead(metadata)
      && Self.canWrite(contents)
      && Self.canWrite(pullRequests)
      && Self.canWrite(workflows)
  }

  private static func canRead(_ value: String?) -> Bool {
    value == "read" || value == "write"
  }

  private static func canWrite(_ value: String?) -> Bool {
    value == "write"
  }
}

public struct GitHubInstallation: Equatable, Sendable {
  public let id: Int64
  public let accountLogin: String
  public let repositorySelection: String
  public let permissions: GitHubInstallationPermissions

  public init(
    id: Int64,
    accountLogin: String,
    repositorySelection: String,
    permissions: GitHubInstallationPermissions
  ) {
    self.id = id
    self.accountLogin = accountLogin
    self.repositorySelection = repositorySelection
    self.permissions = permissions
  }
}

public struct GitHubRepository: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let owner: String
  public let name: String
  public let fullName: String
  public let htmlURL: URL
  public let canonicalHTTPSURL: URL
  public let isPrivate: Bool
  public let defaultBranch: String

  public init(
    id: Int64,
    owner: String,
    name: String,
    fullName: String,
    htmlURL: URL,
    canonicalHTTPSURL: URL,
    isPrivate: Bool,
    defaultBranch: String
  ) {
    self.id = id
    self.owner = owner
    self.name = name
    self.fullName = fullName
    self.htmlURL = htmlURL
    self.canonicalHTTPSURL = canonicalHTTPSURL
    self.isPrivate = isPrivate
    self.defaultBranch = defaultBranch
  }

}

public struct GitHubBranchHead: Equatable, Sendable {
  public let sha: String
}

public enum GitHubAPIPullRequestState: String, Equatable, Sendable {
  case open
  case closed
  case merged
}

public struct GitHubAPIPullRequest: Equatable, Sendable {
  public let number: Int
  public let nodeID: String
  public let htmlURL: URL
  public let state: GitHubAPIPullRequestState
  public let isDraft: Bool
  public let headSHA: String
  public let baseBranch: String
  public let baseSHA: String
  public let mergedSHA: String?
  public let updatedAt: Date
}

public struct GitHubPullRequestCreation: Equatable, Sendable {
  public let title: String
  public let body: String
  public let head: String
  public let base: String
  public let isDraft: Bool

  public init(
    title: String,
    body: String,
    head: String,
    base: String,
    isDraft: Bool = false
  ) {
    self.title = title
    self.body = body
    self.head = head
    self.base = base
    self.isDraft = isDraft
  }
}

public enum GitHubPullRequestReviewDecision: String, Equatable, Sendable {
  case approved
  case changesRequested = "changes_requested"
  case commented
  case dismissed
  case pending
}

public struct GitHubPullRequestFeedback: Equatable, Identifiable, Sendable {
  public let id: String
  public let reviewerLogin: String
  public let reviewerAvatarURL: URL?
  public let body: String
  public let decision: GitHubPullRequestReviewDecision?
  public let reviewContext: GitHubReviewCommentContext?
  public let canonicalURL: URL
  public let createdAt: Date

  public init(
    id: String,
    reviewerLogin: String,
    reviewerAvatarURL: URL?,
    body: String,
    decision: GitHubPullRequestReviewDecision?,
    reviewContext: GitHubReviewCommentContext? = nil,
    canonicalURL: URL,
    createdAt: Date
  ) {
    self.id = id
    self.reviewerLogin = reviewerLogin
    self.reviewerAvatarURL = reviewerAvatarURL
    self.body = body
    self.decision = decision
    self.reviewContext = reviewContext
    self.canonicalURL = canonicalURL
    self.createdAt = createdAt
  }
}

public struct GitHubPullRequestMerge: Equatable, Sendable {
  public let sha: String

  public init(sha: String) {
    self.sha = sha
  }
}

private actor GitHubConditionalResponseCache {
  struct Entry: Sendable {
    let eTag: String
    let data: Data
    let linkHeader: String?
  }

  private static let maximumEntries = 256
  private static let maximumEntryBytes = 1_024 * 1_024
  private static let maximumTotalBytes = 16 * 1_024 * 1_024

  private var entries: [String: Entry] = [:]
  private var recency: [String] = []
  private var totalBytes = 0

  func entry(for key: String) -> Entry? {
    guard let entry = entries[key] else { return nil }
    recency.removeAll { $0 == key }
    recency.append(key)
    return entry
  }

  func store(_ entry: Entry?, for key: String) {
    if let existing = entries.removeValue(forKey: key) {
      totalBytes -= existing.data.count
    }
    recency.removeAll { $0 == key }
    guard let entry, entry.data.count <= Self.maximumEntryBytes else { return }
    entries[key] = entry
    recency.append(key)
    totalBytes += entry.data.count
    while entries.count > Self.maximumEntries || totalBytes > Self.maximumTotalBytes {
      guard !recency.isEmpty else { break }
      let oldestKey = recency.removeFirst()
      if let removed = entries.removeValue(forKey: oldestKey) {
        totalBytes -= removed.data.count
      }
    }
  }
}

public final class GitHubAPIClient: GitHubOAuthAuthorizing, @unchecked Sendable {
  private static let maximumBodyBytes = 5 * 1_024 * 1_024
  private static let maximumPages = 100
  private static let maximumArrayItems = 10_000

  private let transport: any GitHubHTTPTransport
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let userAgent: String
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder
  private let conditionalResponseCache = GitHubConditionalResponseCache()

  public init(
    transport: any GitHubHTTPTransport = GitHubURLSessionTransport(),
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    },
    userAgent: String = "Spedito/0.1"
  ) {
    self.transport = transport
    self.now = now
    self.sleep = sleep
    self.userAgent = String(userAgent.unicodeScalars.prefix(128))
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    encoder = JSONEncoder()
  }

  public func authorize(
    clientID: String,
    onPrompt: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
  ) async throws -> GitHubAuthorizedAccount {
    do {
      let device: DeviceCodeResponse = try await formRequest(
        url: try exactURL("https://github.com/login/device/code"),
        values: ["client_id": clientID]
      )
      try bounded(device.deviceCode, maximum: 1_024)
      try bounded(device.userCode, maximum: 128)
      guard
        device.expiresIn > 0,
        device.expiresIn <= 3_600,
        device.interval > 0,
        device.interval <= 60,
        let verificationURL = URL(string: device.verificationURI),
        verificationURL.scheme == "https",
        verificationURL.host?.lowercased() == "github.com"
      else {
        throw GitHubAPIError.invalidResponse
      }
      let expiresAt = now().addingTimeInterval(TimeInterval(device.expiresIn))
      await onPrompt(
        GitHubDeviceAuthorizationPrompt(
          userCode: device.userCode,
          verificationURL: verificationURL,
          expiresAt: expiresAt
        )
      )

      var interval = device.interval
      while now() < expiresAt {
        try Task.checkCancellation()
        try await sleep(.seconds(interval))
        let response: OAuthTokenResponse = try await formRequest(
          url: try exactURL("https://github.com/login/oauth/access_token"),
          values: [
            "client_id": clientID,
            "device_code": device.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
          ]
        )
        if let error = response.error {
          switch error {
          case "authorization_pending":
            continue
          case "slow_down":
            interval = min(60, interval + 5)
            continue
          case "access_denied":
            throw GitHubAPIError.authorizationDenied
          case "expired_token":
            throw GitHubAPIError.authorizationExpired
          default:
            throw GitHubAPIError.invalidResponse
          }
        }
        let token = try validatedToken(response)
        let user: GitHubUser
        do {
          user = try await self.user(accessToken: token.accessToken)
        } catch let error as GitHubAPIError
          where error == .timedOut || error == .serverUnavailable
        {
          user = try await self.user(accessToken: token.accessToken)
        }
        return GitHubAuthorizedAccount(
          githubUserID: user.id,
          login: user.login,
          accessToken: token.accessToken,
          accessTokenExpiresAt: token.accessTokenExpiresAt,
          refreshToken: token.refreshToken,
          refreshTokenExpiresAt: token.refreshTokenExpiresAt
        )
      }
      throw GitHubAPIError.authorizationExpired
    } catch let error as GitHubAPIError {
      if error == .notFound {
        throw GitHubAPIError.unprocessable(error.localizedDescription(context: .authorization))
      }
      throw error
    }
  }

  public func refresh(clientID: String, refreshToken: String) async throws -> GitHubRefreshedToken {
    do {
      let response: OAuthTokenResponse = try await formRequest(
        url: try exactURL("https://github.com/login/oauth/access_token"),
        values: [
          "client_id": clientID,
          "grant_type": "refresh_token",
          "refresh_token": refreshToken,
        ]
      )
      if let error = response.error {
        if error == "bad_refresh_token" || error == "incorrect_client_credentials" {
          throw GitHubAPIError.unauthorized
        }
        throw GitHubAPIError.invalidResponse
      }
      let token = try validatedToken(response)
      return GitHubRefreshedToken(
        accessToken: token.accessToken,
        accessTokenExpiresAt: token.accessTokenExpiresAt,
        refreshToken: token.refreshToken,
        refreshTokenExpiresAt: token.refreshTokenExpiresAt
      )
    } catch let error as GitHubAPIError {
      if error == .notFound {
        throw GitHubAPIError.unprocessable(error.localizedDescription(context: .authorization))
      }
      throw error
    }
  }

  public func user(accessToken: String) async throws -> GitHubUser {
    let value: UserResponse = try await apiRequest(
      method: "GET",
      url: try apiURL(path: "/user"),
      accessToken: accessToken
    )
    try bounded(value.login, maximum: 100)
    guard value.id > 0 else { throw GitHubAPIError.invalidResponse }
    return GitHubUser(id: value.id, login: value.login)
  }

  public func installations(accessToken: String) async throws -> [GitHubInstallation] {
    let values: [InstallationResponse] = try await paginated(
      url: try apiURL(path: "/user/installations", query: ["per_page": "100"]),
      accessToken: accessToken,
      envelope: InstallationPage.self,
      items: \.installations
    )
    return try values.map { value in
      try bounded(value.account.login, maximum: 100)
      try bounded(value.repositorySelection, maximum: 32)
      guard value.id > 0 else { throw GitHubAPIError.invalidResponse }
      return GitHubInstallation(
        id: value.id,
        accountLogin: value.account.login,
        repositorySelection: value.repositorySelection,
        permissions: value.permissions
      )
    }
  }

  public func repositories(
    installationID: Int64,
    accessToken: String
  ) async throws -> [GitHubRepository] {
    guard installationID > 0 else { throw GitHubAPIError.invalidResponse }
    let values: [RepositoryResponse] = try await paginated(
      url: try apiURL(
        path: "/user/installations/\(installationID)/repositories",
        query: ["per_page": "100"]
      ),
      accessToken: accessToken,
      envelope: RepositoryPage.self,
      items: \.repositories
    )
    return try values.map(repository(from:))
  }

  public func repository(
    owner: String,
    name: String,
    accessToken: String
  ) async throws -> GitHubRepository {
    let value: RepositoryResponse = try await apiRequest(
      method: "GET",
      url: try apiURL(path: "/repos/\(validatedSlug(owner))/\(validatedSlug(name))"),
      accessToken: accessToken
    )
    return try repository(from: value)
  }

  public func repositoryHasBranches(
    owner: String,
    name: String,
    accessToken: String
  ) async throws -> Bool {
    let values: [BranchListResponse] = try await apiRequest(
      method: "GET",
      url: try apiURL(
        path: "/repos/\(validatedSlug(owner))/\(validatedSlug(name))/branches",
        query: ["per_page": "1"]
      ),
      accessToken: accessToken
    )
    guard values.count <= 1 else { throw GitHubAPIError.invalidResponse }
    if let value = values.first {
      try bounded(value.name, maximum: 255)
    }
    return !values.isEmpty
  }

  public func branchHead(
    owner: String,
    name: String,
    branch: String,
    accessToken: String
  ) async throws -> GitHubBranchHead? {
    let branchSegment = try pathSegment(branch, maximum: 255)
    do {
      let value: ReferenceResponse = try await apiRequest(
        method: "GET",
        url: try apiURL(
          path:
            "/repos/\(validatedSlug(owner))/\(validatedSlug(name))/git/ref/heads/\(branchSegment)",
          pathIsPercentEncoded: true
        ),
        accessToken: accessToken
      )
      try validateSHA(value.object.sha)
      return GitHubBranchHead(sha: value.object.sha)
    } catch GitHubAPIError.notFound {
      return nil
    }
  }

  public func pullRequests(
    owner: String,
    name: String,
    head: String,
    accessToken: String
  ) async throws -> [GitHubAPIPullRequest] {
    let owner = try validatedSlug(owner)
    let name = try validatedSlug(name)
    let values: [PullRequestResponse] = try await paginatedArray(
      url: try apiURL(
        path: "/repos/\(owner)/\(name)/pulls",
        query: ["state": "all", "head": head, "per_page": "100"]
      ),
      accessToken: accessToken
    )
    return try values.map(pullRequest(from:))
  }

  public func createPullRequest(
    owner: String,
    name: String,
    creation: GitHubPullRequestCreation,
    accessToken: String
  ) async throws -> GitHubAPIPullRequest {
    let body = try encoder.encode(
      CreatePullRequestBody(
        title: creation.title,
        body: creation.body,
        head: creation.head,
        base: creation.base,
        draft: creation.isDraft
      )
    )
    let value: PullRequestResponse = try await apiRequest(
      method: "POST",
      url: try apiURL(path: "/repos/\(validatedSlug(owner))/\(validatedSlug(name))/pulls"),
      accessToken: accessToken,
      body: body
    )
    return try pullRequest(from: value)
  }
  public func pullRequest(
    owner: String,
    name: String,
    number: Int,
    accessToken: String,
    useConditionalRequest: Bool = false
  ) async throws -> GitHubAPIPullRequest {
    guard number > 0 else { throw GitHubAPIError.invalidResponse }
    let url = try apiURL(
      path: "/repos/\(validatedSlug(owner))/\(validatedSlug(name))/pulls/\(number)"
    )
    let value: PullRequestResponse
    if useConditionalRequest {
      value = try await conditionalAPIRequest(
        url: url,
        accessToken: accessToken
      )
    } else {
      value = try await apiRequest(
        method: "GET",
        url: url,
        accessToken: accessToken
      )
    }
    return try pullRequest(from: value)
  }
  public func pullRequestFeedback(
    owner: String,
    name: String,
    number: Int,
    accessToken: String,
    useConditionalRequests: Bool = false
  ) async throws -> [GitHubPullRequestFeedback] {
    guard number > 0 else { throw GitHubAPIError.invalidResponse }
    let owner = try validatedSlug(owner)
    let name = try validatedSlug(name)
    let reviewsURL = try apiURL(
      path: "/repos/\(owner)/\(name)/pulls/\(number)/reviews",
      query: ["per_page": "100"]
    )
    let commentsURL = try apiURL(
      path: "/repos/\(owner)/\(name)/pulls/\(number)/comments",
      query: ["per_page": "100"]
    )
    async let reviewValues: [PullRequestReviewResponse] =
      useConditionalRequests
      ? conditionalPaginatedArray(url: reviewsURL, accessToken: accessToken)
      : paginatedArray(url: reviewsURL, accessToken: accessToken)
    async let commentValues: [PullRequestReviewCommentResponse] =
      useConditionalRequests
      ? conditionalPaginatedArray(url: commentsURL, accessToken: accessToken)
      : paginatedArray(url: commentsURL, accessToken: accessToken)
    let (reviews, comments) = try await (reviewValues, commentValues)
    var feedback = try reviews.map { value in
      guard let createdAt = value.submittedAt ?? value.updatedAt else {
        throw GitHubAPIError.invalidResponse
      }
      let decision = GitHubPullRequestReviewDecision(
        rawValue: value.state.lowercased()
      )
      guard let decision else { throw GitHubAPIError.invalidResponse }
      return try pullRequestFeedback(
        id: "review:\(value.id)",
        user: value.user,
        body: value.body ?? "",
        decision: decision,
        htmlURL: value.htmlURL,
        createdAt: createdAt
      )
    }
    feedback += try comments.map { value in
      try pullRequestFeedback(
        id: "comment:\(value.id)",
        user: value.user,
        body: value.body,
        decision: nil,
        reviewContext: try reviewContext(from: value),
        htmlURL: value.htmlURL,
        createdAt: value.createdAt
      )
    }
    return feedback.sorted {
      if $0.createdAt == $1.createdAt { return $0.id < $1.id }
      return $0.createdAt < $1.createdAt
    }
  }

  public func markPullRequestReadyForReview(
    nodeID: String,
    accessToken: String
  ) async throws {
    let value = try await mutatePullRequestDraftState(
      nodeID: nodeID,
      mutation: "markPullRequestReadyForReview",
      accessToken: accessToken
    )
    guard !value else { throw GitHubAPIError.invalidResponse }
  }

  public func convertPullRequestToDraft(
    nodeID: String,
    accessToken: String
  ) async throws {
    let value = try await mutatePullRequestDraftState(
      nodeID: nodeID,
      mutation: "convertPullRequestToDraft",
      accessToken: accessToken
    )
    guard value else { throw GitHubAPIError.invalidResponse }
  }

  public func mergePullRequest(
    owner: String,
    name: String,
    number: Int,
    expectedHeadSHA: String,
    accessToken: String
  ) async throws -> GitHubPullRequestMerge {
    guard number > 0 else { throw GitHubAPIError.invalidResponse }
    try validateSHA(expectedHeadSHA)
    let body = try encoder.encode(
      MergePullRequestBody(sha: expectedHeadSHA, mergeMethod: "merge")
    )
    let value: MergePullRequestResponse = try await apiRequest(
      method: "PUT",
      url: try apiURL(
        path: "/repos/\(validatedSlug(owner))/\(validatedSlug(name))/pulls/\(number)/merge"
      ),
      accessToken: accessToken,
      body: body
    )
    guard value.merged, let sha = value.sha else {
      throw GitHubAPIError.unprocessable("GitHub could not merge this exact reviewed revision.")
    }
    try validateSHA(sha)
    return GitHubPullRequestMerge(sha: sha)
  }

  private func pullRequestFeedback(
    id: String,
    user: PullRequestFeedbackUserResponse?,
    body: String,
    decision: GitHubPullRequestReviewDecision?,
    reviewContext: GitHubReviewCommentContext? = nil,
    htmlURL: String,
    createdAt: Date
  ) throws -> GitHubPullRequestFeedback {
    try bounded(id, maximum: 256)
    let login = user?.login ?? "GitHub reviewer"
    try bounded(login, maximum: 100)
    try bounded(body, maximum: 65_000)
    guard
      let url = URL(string: htmlURL),
      url.scheme == "https",
      url.host?.lowercased() == "github.com"
    else {
      throw GitHubAPIError.invalidResponse
    }
    let avatarURL: URL?
    if let rawAvatarURL = user?.avatarURL {
      guard
        let parsed = URL(string: rawAvatarURL),
        parsed.scheme == "https",
        parsed.host?.lowercased() == "avatars.githubusercontent.com"
      else {
        throw GitHubAPIError.invalidResponse
      }
      avatarURL = parsed
    } else {
      avatarURL = nil
    }
    return GitHubPullRequestFeedback(
      id: id,
      reviewerLogin: login,
      reviewerAvatarURL: avatarURL,
      body: body,
      decision: decision,
      reviewContext: reviewContext,
      canonicalURL: url,
      createdAt: createdAt
    )
  }

  private func reviewContext(
    from value: PullRequestReviewCommentResponse
  ) throws -> GitHubReviewCommentContext {
    try bounded(value.path, maximum: 4_096)
    try bounded(value.diffHunk, maximum: 65_000)
    try validateSHA(value.commitID)
    try validateSHA(value.originalCommitID)
    guard !value.path.isEmpty,
      !value.path.hasPrefix("/"),
      !value.path.contains("\0"),
      !value.path.contains("\n"),
      !value.path.contains("\r")
    else {
      throw GitHubAPIError.invalidResponse
    }
    let lines = [
      value.startLine,
      value.line,
      value.originalStartLine,
      value.originalLine,
    ].compactMap { $0 }
    guard lines.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }) else {
      throw GitHubAPIError.invalidResponse
    }
    let sides = [value.startSide, value.side].compactMap { $0?.lowercased() }
    guard sides.allSatisfy({ $0 == "left" || $0 == "right" }) else {
      throw GitHubAPIError.invalidResponse
    }
    return GitHubReviewCommentContext(
      path: value.path,
      commitSHA: value.commitID,
      originalCommitSHA: value.originalCommitID,
      diffHunk: value.diffHunk,
      startLine: value.startLine,
      line: value.line,
      startSide: value.startSide?.lowercased(),
      side: value.side?.lowercased(),
      originalStartLine: value.originalStartLine,
      originalLine: value.originalLine
    )
  }

  private func mutatePullRequestDraftState(
    nodeID: String,
    mutation: String,
    accessToken: String
  ) async throws -> Bool {
    try bounded(nodeID, maximum: 256)
    guard
      mutation == "markPullRequestReadyForReview"
        || mutation == "convertPullRequestToDraft"
    else {
      throw GitHubAPIError.invalidResponse
    }
    let query = """
      mutation UpdateDraftState($pullRequestId: ID!) {
        \(mutation)(input: {pullRequestId: $pullRequestId}) {
          pullRequest { id isDraft }
        }
      }
      """
    let body = try encoder.encode(
      GraphQLRequest(query: query, variables: ["pullRequestId": nodeID])
    )
    let response: PullRequestDraftMutationResponse = try await apiRequest(
      method: "POST",
      url: try apiURL(path: "/graphql"),
      accessToken: accessToken,
      body: body
    )
    guard response.errors?.isEmpty != false else {
      throw GitHubAPIError.unprocessable("GitHub rejected the pull request state change.")
    }
    let pullRequest =
      response.data?.markPullRequestReadyForReview?.pullRequest
      ?? response.data?.convertPullRequestToDraft?.pullRequest
    guard let pullRequest, pullRequest.id == nodeID else {
      throw GitHubAPIError.invalidResponse
    }
    return pullRequest.isDraft
  }

  private func repository(from value: RepositoryResponse) throws -> GitHubRepository {
    try bounded(value.owner.login, maximum: 100)
    try bounded(value.name, maximum: 100)
    try bounded(value.fullName, maximum: 201)
    try bounded(value.defaultBranch, maximum: 255)
    guard
      value.id > 0,
      value.fullName.caseInsensitiveCompare("\(value.owner.login)/\(value.name)") == .orderedSame,
      let htmlURL = URL(string: value.htmlURL),
      htmlURL.scheme == "https",
      htmlURL.host?.lowercased() == "github.com",
      let cloneURL = URL(string: value.cloneURL),
      cloneURL.scheme == "https",
      cloneURL.host?.lowercased() == "github.com",
      cloneURL.user == nil,
      cloneURL.password == nil
    else {
      throw GitHubAPIError.invalidResponse
    }
    return GitHubRepository(
      id: value.id,
      owner: value.owner.login,
      name: value.name,
      fullName: value.fullName,
      htmlURL: htmlURL,
      canonicalHTTPSURL: cloneURL,
      isPrivate: value.isPrivate,
      defaultBranch: value.defaultBranch
    )
  }

  private func pullRequest(from value: PullRequestResponse) throws -> GitHubAPIPullRequest {
    try bounded(value.nodeID, maximum: 256)
    try bounded(value.head.sha, maximum: 64)
    try bounded(value.base.ref, maximum: 255)
    try bounded(value.base.sha, maximum: 64)
    try validateSHA(value.head.sha)
    try validateSHA(value.base.sha)
    if let mergeCommitSHA = value.mergeCommitSHA {
      try validateSHA(mergeCommitSHA)
    }
    guard
      value.number > 0,
      let htmlURL = URL(string: value.htmlURL),
      htmlURL.scheme == "https",
      htmlURL.host?.lowercased() == "github.com"
    else {
      throw GitHubAPIError.invalidResponse
    }
    let state: GitHubAPIPullRequestState
    if value.mergedAt != nil {
      state = .merged
    } else if value.state == "open" {
      state = .open
    } else if value.state == "closed" {
      state = .closed
    } else {
      throw GitHubAPIError.invalidResponse
    }
    return GitHubAPIPullRequest(
      number: value.number,
      nodeID: value.nodeID,
      htmlURL: htmlURL,
      state: state,
      isDraft: value.draft ?? false,
      headSHA: value.head.sha,
      baseBranch: value.base.ref,
      baseSHA: value.base.sha,
      mergedSHA: state == .merged ? value.mergeCommitSHA : nil,
      updatedAt: value.updatedAt
    )
  }

  private func paginated<Envelope: Decodable, Item: Sendable>(
    url: URL,
    accessToken: String,
    envelope: Envelope.Type,
    items: KeyPath<Envelope, [Item]>
  ) async throws -> [Item] {
    var nextURL: URL? = url
    var result: [Item] = []
    var pageCount = 0
    while let currentURL = nextURL {
      pageCount += 1
      guard pageCount <= Self.maximumPages else { throw GitHubAPIError.responseTooLarge }
      let (value, response): (Envelope, HTTPURLResponse) = try await apiRequestWithResponse(
        method: "GET",
        url: currentURL,
        accessToken: accessToken
      )
      result.append(contentsOf: value[keyPath: items])
      guard result.count <= Self.maximumArrayItems else {
        throw GitHubAPIError.responseTooLarge
      }
      nextURL = try nextPaginationURL(response.value(forHTTPHeaderField: "Link"))
    }
    return result
  }

  private func paginatedArray<Item: Decodable & Sendable>(
    url: URL,
    accessToken: String
  ) async throws -> [Item] {
    var nextURL: URL? = url
    var result: [Item] = []
    var pageCount = 0
    while let currentURL = nextURL {
      pageCount += 1
      guard pageCount <= Self.maximumPages else { throw GitHubAPIError.responseTooLarge }
      let (value, response): ([Item], HTTPURLResponse) = try await apiRequestWithResponse(
        method: "GET",
        url: currentURL,
        accessToken: accessToken
      )
      result.append(contentsOf: value)
      guard result.count <= Self.maximumArrayItems else {
        throw GitHubAPIError.responseTooLarge
      }
      nextURL = try nextPaginationURL(response.value(forHTTPHeaderField: "Link"))
    }
    return result
  }

  private func conditionalPaginatedArray<Item: Decodable & Sendable>(
    url: URL,
    accessToken: String
  ) async throws -> [Item] {
    var nextURL: URL? = url
    var result: [Item] = []
    var pageCount = 0
    while let currentURL = nextURL {
      pageCount += 1
      guard pageCount <= Self.maximumPages else {
        throw GitHubAPIError.responseTooLarge
      }
      let (data, linkHeader) = try await conditionalResponse(
        url: currentURL,
        accessToken: accessToken
      )
      let value: [Item]
      do {
        value = try decoder.decode([Item].self, from: data)
      } catch {
        throw GitHubAPIError.invalidResponse
      }
      result.append(contentsOf: value)
      guard result.count <= Self.maximumArrayItems else {
        throw GitHubAPIError.responseTooLarge
      }
      nextURL = try nextPaginationURL(linkHeader)
    }
    return result
  }

  private func conditionalAPIRequest<Response: Decodable>(
    url: URL,
    accessToken: String
  ) async throws -> Response {
    let (data, _) = try await conditionalResponse(
      url: url,
      accessToken: accessToken
    )
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw GitHubAPIError.invalidResponse
    }
  }

  private func conditionalResponse(
    url: URL,
    accessToken: String
  ) async throws -> (data: Data, linkHeader: String?) {
    guard url.scheme == "https", url.host?.lowercased() == "api.github.com" else {
      throw GitHubAPIError.invalidResponse
    }
    let tokenDigest = SHA256.hash(data: Data(accessToken.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let cacheKey = "\(tokenDigest):\(url.absoluteString)"
    let cached = await conditionalResponseCache.entry(for: cacheKey)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let cached {
      request.setValue(cached.eTag, forHTTPHeaderField: "If-None-Match")
    }
    let (data, response) = try await send(request)
    if response.statusCode == 304 {
      guard let cached else { throw GitHubAPIError.invalidResponse }
      return (cached.data, cached.linkHeader)
    }
    try validateStatus(response, data: data)
    let linkHeader = response.value(forHTTPHeaderField: "Link")
    if let eTag = validETag(response.value(forHTTPHeaderField: "ETag")),
      linkHeader?.utf8.count ?? 0 <= 16_384
    {
      await conditionalResponseCache.store(
        GitHubConditionalResponseCache.Entry(
          eTag: eTag,
          data: data,
          linkHeader: linkHeader
        ),
        for: cacheKey
      )
    } else {
      await conditionalResponseCache.store(nil, for: cacheKey)
    }
    return (data, linkHeader)
  }

  private func validETag(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= 512 else { return nil }
    guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
      return nil
    }
    return value
  }

  private func apiRequest<Response: Decodable>(
    method: String,
    url: URL,
    accessToken: String,
    body: Data? = nil
  ) async throws -> Response {
    let (value, _): (Response, HTTPURLResponse) = try await apiRequestWithResponse(
      method: method,
      url: url,
      accessToken: accessToken,
      body: body
    )
    return value
  }

  private func apiRequestWithResponse<Response: Decodable>(
    method: String,
    url: URL,
    accessToken: String,
    body: Data? = nil
  ) async throws -> (Response, HTTPURLResponse) {
    guard url.scheme == "https", url.host?.lowercased() == "api.github.com" else {
      throw GitHubAPIError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await send(request)
    try validateStatus(response, data: data)
    do {
      return (try decoder.decode(Response.self, from: data), response)
    } catch {
      throw GitHubAPIError.invalidResponse
    }
  }

  private func formRequest<Response: Decodable>(
    url: URL,
    values: [String: String]
  ) async throws -> Response {
    var components = URLComponents()
    components.queryItems = values.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard let query = components.percentEncodedQuery else {
      throw GitHubAPIError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(query.utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await send(request)
    try validateStatus(response, data: data)
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw GitHubAPIError.invalidResponse
    }
  }

  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await transport.send(request)
      guard data.count <= Self.maximumBodyBytes else {
        throw GitHubAPIError.responseTooLarge
      }
      guard response.url == request.url else {
        throw GitHubAPIError.invalidResponse
      }
      return (data, response)
    } catch is CancellationError {
      throw GitHubAPIError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw GitHubAPIError.cancelled
    } catch let error as URLError where error.code == .timedOut {
      throw GitHubAPIError.timedOut
    } catch let error as GitHubAPIError {
      throw error
    } catch {
      throw GitHubAPIError.serverUnavailable
    }
  }

  private func validateStatus(_ response: HTTPURLResponse, data: Data) throws {
    switch response.statusCode {
    case 200..<300:
      return
    case 401:
      throw GitHubAPIError.unauthorized
    case 403:
      if isRateLimited(response) {
        throw GitHubAPIError.rateLimited(retryAfter: retryAfter(response))
      }
      throw GitHubAPIError.forbidden(forbiddenReason(response))
    case 404:
      throw GitHubAPIError.notFound
    case 409:
      throw GitHubAPIError.conflict
    case 405:
      throw GitHubAPIError.unprocessable("GitHub could not merge this exact reviewed revision.")
    case 422:
      throw GitHubAPIError.unprocessable("GitHub rejected the requested repository change.")
    case 429:
      throw GitHubAPIError.rateLimited(retryAfter: retryAfter(response))
    case 500...599:
      throw GitHubAPIError.serverUnavailable
    default:
      _ = data
      throw GitHubAPIError.invalidResponse
    }
  }

  private func isRateLimited(_ response: HTTPURLResponse) -> Bool {
    response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
      || response.value(forHTTPHeaderField: "Retry-After") != nil
  }

  private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After"),
      let seconds = TimeInterval(value),
      seconds >= 0,
      seconds <= 86_400
    else { return nil }
    return seconds
  }

  private func forbiddenReason(_ response: HTTPURLResponse) -> String {
    if response.value(forHTTPHeaderField: "X-GitHub-SSO") != nil {
      return "Your organization requires GitHub SAML authorization for this repository."
    }
    return "The Spedito GitHub App does not have access to this repository."
  }

  private func nextPaginationURL(_ linkHeader: String?) throws -> URL? {
    guard let linkHeader, !linkHeader.isEmpty else { return nil }
    for value in linkHeader.split(separator: ",") {
      let parts = value.split(separator: ";", omittingEmptySubsequences: true)
      guard parts.count >= 2 else { continue }
      let target = parts[0].trimmingCharacters(in: .whitespaces)
      let relations = parts.dropFirst().map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard relations.contains("rel=\"next\"") else { continue }
      guard target.hasPrefix("<"), target.hasSuffix(">"),
        let url = URL(string: String(target.dropFirst().dropLast())),
        url.scheme == "https",
        url.host?.lowercased() == "api.github.com",
        url.user == nil,
        url.password == nil
      else {
        throw GitHubAPIError.invalidResponse
      }
      return url
    }
    return nil
  }

  private func apiURL(
    path: String,
    query: [String: String] = [:],
    pathIsPercentEncoded: Bool = false
  ) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "api.github.com"
    if pathIsPercentEncoded {
      components.percentEncodedPath = path
    } else {
      components.path = path
    }
    if !query.isEmpty {
      components.queryItems = query.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      }
    }
    guard let url = components.url else { throw GitHubAPIError.invalidResponse }
    return url
  }

  private func exactURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else { throw GitHubAPIError.invalidResponse }
    return url
  }

  private func validatedSlug(_ value: String) throws -> String {
    try bounded(value, maximum: 100)
    guard !value.isEmpty,
      value.unicodeScalars.allSatisfy({ scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
          || scalar == "."
      })
    else {
      throw GitHubAPIError.invalidResponse
    }
    return value
  }

  private func pathSegment(_ value: String, maximum: Int) throws -> String {
    try bounded(value, maximum: maximum)
    guard !value.isEmpty else { throw GitHubAPIError.invalidResponse }
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#%")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw GitHubAPIError.invalidResponse
    }
    return encoded
  }

  private func bounded(_ value: String, maximum: Int) throws {
    guard value.unicodeScalars.count <= maximum else {
      throw GitHubAPIError.responseTooLarge
    }
  }

  private func validateSHA(_ value: String) throws {
    guard value.count == 40,
      value.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      })
    else {
      throw GitHubAPIError.invalidResponse
    }
  }

  private func validatedToken(_ response: OAuthTokenResponse) throws -> GitHubRefreshedToken {
    guard
      let accessToken = response.accessToken,
      let accessExpiresIn = response.expiresIn,
      let refreshToken = response.refreshToken,
      let refreshExpiresIn = response.refreshTokenExpiresIn,
      !accessToken.isEmpty,
      !refreshToken.isEmpty,
      accessToken.unicodeScalars.count <= 2_048,
      refreshToken.unicodeScalars.count <= 2_048,
      accessExpiresIn > 0,
      accessExpiresIn <= 86_400,
      refreshExpiresIn > accessExpiresIn,
      refreshExpiresIn <= 31_536_000
    else {
      throw GitHubAPIError.invalidResponse
    }
    return GitHubRefreshedToken(
      accessToken: accessToken,
      accessTokenExpiresAt: now().addingTimeInterval(TimeInterval(accessExpiresIn)),
      refreshToken: refreshToken,
      refreshTokenExpiresAt: now().addingTimeInterval(TimeInterval(refreshExpiresIn))
    )
  }
}

private struct DeviceCodeResponse: Decodable {
  let deviceCode: String
  let userCode: String
  let verificationURI: String
  let expiresIn: Int
  let interval: Int

  enum CodingKeys: String, CodingKey {
    case deviceCode = "device_code"
    case userCode = "user_code"
    case verificationURI = "verification_uri"
    case expiresIn = "expires_in"
    case interval
  }
}

private struct OAuthTokenResponse: Decodable {
  let accessToken: String?
  let expiresIn: Int?
  let refreshToken: String?
  let refreshTokenExpiresIn: Int?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case refreshTokenExpiresIn = "refresh_token_expires_in"
    case error
  }
}

private struct UserResponse: Decodable {
  let id: Int64
  let login: String
}

private struct InstallationPage: Decodable {
  let installations: [InstallationResponse]
}

private struct InstallationResponse: Decodable {
  let id: Int64
  let account: OwnerResponse
  let repositorySelection: String
  let permissions: GitHubInstallationPermissions

  enum CodingKeys: String, CodingKey {
    case id
    case account
    case repositorySelection = "repository_selection"
    case permissions
  }
}

private struct RepositoryPage: Decodable {
  let repositories: [RepositoryResponse]
}

private struct BranchListResponse: Decodable {
  let name: String
}

private struct RepositoryResponse: Decodable {
  let id: Int64
  let owner: OwnerResponse
  let name: String
  let fullName: String
  let htmlURL: String
  let cloneURL: String
  let isPrivate: Bool
  let defaultBranch: String

  enum CodingKeys: String, CodingKey {
    case id
    case owner
    case name
    case fullName = "full_name"
    case htmlURL = "html_url"
    case cloneURL = "clone_url"
    case isPrivate = "private"
    case defaultBranch = "default_branch"
  }
}

private struct OwnerResponse: Decodable {
  let login: String
}

private struct ReferenceResponse: Decodable {
  let object: ReferenceObjectResponse
}

private struct ReferenceObjectResponse: Decodable {
  let sha: String
}

private struct PullRequestResponse: Decodable {
  let number: Int
  let nodeID: String
  let htmlURL: String
  let state: String
  let draft: Bool?
  let head: PullRequestRefResponse
  let base: PullRequestRefResponse
  let mergeCommitSHA: String?
  let mergedAt: Date?
  let updatedAt: Date

  enum CodingKeys: String, CodingKey {
    case number
    case nodeID = "node_id"
    case htmlURL = "html_url"
    case state
    case draft
    case head
    case base
    case mergeCommitSHA = "merge_commit_sha"
    case mergedAt = "merged_at"
    case updatedAt = "updated_at"
  }
}

private struct PullRequestRefResponse: Decodable {
  let ref: String
  let sha: String
}

private struct CreatePullRequestBody: Encodable {
  let title: String
  let body: String
  let head: String
  let base: String
  let draft: Bool
}

private struct PullRequestFeedbackUserResponse: Decodable {
  let login: String
  let avatarURL: String?

  enum CodingKeys: String, CodingKey {
    case login
    case avatarURL = "avatar_url"
  }
}

private struct PullRequestReviewResponse: Decodable, Sendable {
  let id: Int64
  let user: PullRequestFeedbackUserResponse?
  let body: String?
  let state: String
  let htmlURL: String
  let submittedAt: Date?
  let updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case user
    case body
    case state
    case htmlURL = "html_url"
    case submittedAt = "submitted_at"
    case updatedAt = "updated_at"
  }
}

private struct PullRequestReviewCommentResponse: Decodable, Sendable {
  let id: Int64
  let user: PullRequestFeedbackUserResponse?
  let body: String
  let htmlURL: String
  let createdAt: Date
  let path: String
  let commitID: String
  let originalCommitID: String
  let diffHunk: String
  let startLine: Int?
  let line: Int?
  let startSide: String?
  let side: String?
  let originalStartLine: Int?
  let originalLine: Int?

  enum CodingKeys: String, CodingKey {
    case id
    case user
    case body
    case htmlURL = "html_url"
    case createdAt = "created_at"
    case path
    case commitID = "commit_id"
    case originalCommitID = "original_commit_id"
    case diffHunk = "diff_hunk"
    case startLine = "start_line"
    case line
    case startSide = "start_side"
    case side
    case originalStartLine = "original_start_line"
    case originalLine = "original_line"
  }
}

private struct GraphQLRequest: Encodable {
  let query: String
  let variables: [String: String]
}

private struct PullRequestDraftMutationResponse: Decodable {
  let data: PullRequestDraftMutationData?
  let errors: [GraphQLErrorResponse]?
}

private struct PullRequestDraftMutationData: Decodable {
  let markPullRequestReadyForReview: PullRequestDraftMutationPayload?
  let convertPullRequestToDraft: PullRequestDraftMutationPayload?
}

private struct PullRequestDraftMutationPayload: Decodable {
  let pullRequest: PullRequestDraftMutationPullRequest
}

private struct PullRequestDraftMutationPullRequest: Decodable {
  let id: String
  let isDraft: Bool
}

private struct GraphQLErrorResponse: Decodable {
  let message: String
}

private struct MergePullRequestBody: Encodable {
  let sha: String
  let mergeMethod: String

  enum CodingKeys: String, CodingKey {
    case sha
    case mergeMethod = "merge_method"
  }
}

private struct MergePullRequestResponse: Decodable {
  let sha: String?
  let merged: Bool
}
