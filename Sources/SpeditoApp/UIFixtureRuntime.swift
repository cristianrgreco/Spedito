#if DEBUG
  import Darwin
  import Foundation
  import SpeditoCore

  @MainActor
  enum UIFixtureRuntime {
    private static let scenarioEnvironmentKey = "SPEDITO_UI_TEST_FIXTURE"
    private static let rootEnvironmentKey = "SPEDITO_UI_FIXTURE_ROOT"
    private static let signalEnvironmentKey = "SPEDITO_UI_FIXTURE_SIGNAL"

    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment[scenarioEnvironmentKey] == "epic-needs-input"
    }

    static var applicationSupportURL: URL? {
      guard isEnabled,
        let path = ProcessInfo.processInfo.environment[rootEnvironmentKey],
        !path.isEmpty
      else { return nil }
      return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var notificationBannerDismissDelay: Duration? {
      isEnabled ? nil : .seconds(8)
    }

    static func transportFactoryOutput() -> CodexTransportFactoryOutput? {
      guard isEnabled,
        let signalPath = ProcessInfo.processInfo.environment[signalEnvironmentKey],
        !signalPath.isEmpty,
        let rootURL = applicationSupportURL
      else { return nil }
      return CodexTransportFactoryOutput(
        descriptor: CodexRuntimeDescriptor(
          executableURL: URL(fileURLWithPath: "/private/tmp/spedito-ui-fixture-codex"),
          version: "ui-fixture",
          source: .custom
        ),
        transport: UIFixtureCodexTransport(
          releaseSignalURL: URL(fileURLWithPath: signalPath),
          turnStartedSignalURL: rootURL.appendingPathComponent("epic-turn-started")
        )
      )
    }

    static func prepare(registry: ProductStoreRegistry) async throws -> UUID? {
      guard isEnabled, let rootURL = applicationSupportURL else { return nil }

      let existingProducts = try await registry.fetchProducts()
      if let firstProduct = existingProducts.first(where: { $0.name == "First product" }) {
        return firstProduct.id
      }

      let firstProduct = try await registry.createProduct(name: "First product")
      let secondProduct = try await registry.createProduct(name: "Second product")

      let manifest = UIFixtureManifest(
        firstProductID: firstProduct.id,
        secondProductID: secondProduct.id
      )
      let manifestURL = rootURL.appendingPathComponent("fixture-manifest.json")
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true
      )
      try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
      return firstProduct.id
    }
  }

  private struct UIFixtureManifest: Codable {
    let firstProductID: UUID
    let secondProductID: UUID
  }

  @MainActor
  final class UIFixtureOwnerNotificationSoundPlayer: OwnerNotificationSoundPlaying {
    func play() {}
  }

  @MainActor
  final class UIFixtureOwnerNotificationSystemNotifier: OwnerNotificationSystemNotifying {
    func post(_: OwnerNotificationPresentation) {}
    func dismiss(ids _: [UUID]) {}
  }

  private actor UIFixtureCodexTransport: CodexRPCTransport {
    private let releaseSignalURL: URL
    private let turnStartedSignalURL: URL
    private let inboundStream: AsyncStream<CodexInboundMessage>
    private let inboundContinuation: AsyncStream<CodexInboundMessage>.Continuation
    private var releaseTask: Task<Void, Never>?
    private var didStartTurn = false

    init(releaseSignalURL: URL, turnStartedSignalURL: URL) {
      self.releaseSignalURL = releaseSignalURL
      self.turnStartedSignalURL = turnStartedSignalURL
      let pair = AsyncStream<CodexInboundMessage>.makeStream()
      inboundStream = pair.stream
      inboundContinuation = pair.continuation
    }

    func start() {}

    func request(method: String, params _: JSONValue) throws -> JSONValue {
      switch method {
      case "initialize":
        return .object([
          "userAgent": .string("codex-cli/ui-fixture"),
          "codexHome": .string("/private/tmp/spedito-ui-fixture"),
          "platformFamily": .string("unix"),
          "platformOs": .string("macos"),
        ])
      case "model/list":
        return .object(["data": .array([])])
      case "account/rateLimits/read":
        return .object(["rateLimits": .object([:])])
      case "thread/start":
        return .object(["thread": .object(["id": .string("thread-ui-e02")])])
      case "turn/start":
        guard !didStartTurn else {
          throw CodexRPCError(code: -32_601, message: "The UI fixture supports one Epic turn")
        }
        didStartTurn = true
        _ = FileManager.default.createFile(
          atPath: turnStartedSignalURL.path,
          contents: Data()
        )
        let signalURL = releaseSignalURL
        let continuation = inboundContinuation
        releaseTask = Task {
          await UIFixtureSignal.wait(for: signalURL)
          guard !Task.isCancelled else { return }
          continuation.yield(Self.completedTurn)
        }
        return .object(["turn": .object(["id": .string("turn-ui-e02")])])
      default:
        throw CodexRPCError(code: -32_601, message: "Unexpected UI fixture request: \(method)")
      }
    }

    func notify(method _: String, params _: JSONValue) {}

    func inboundMessages() -> AsyncStream<CodexInboundMessage> {
      inboundStream
    }

    func stop() {
      releaseTask?.cancel()
      releaseTask = nil
      inboundContinuation.finish()
    }

    private static let completedTurn = CodexInboundMessage.notification(
      CodexNotification(
        method: "turn/completed",
        params: .object([
          "threadId": .string("thread-ui-e02"),
          "turn": .object([
            "id": .string("turn-ui-e02"),
            "status": .string("completed"),
            "items": .array([
              .object([
                "id": .string("message-turn-ui-e02"),
                "type": .string("agentMessage"),
                "text": .string(
                  #"{"message":"I need one product decision.","questions":[{"prompt":"Where should drafts be retained?","options":["On this Mac","In the repository"]}],"readyToPlan":false}"#
                ),
              ])
            ]),
          ]),
        ])
      )
    )
  }

  final class UIFixtureGitHubRemoteRepositoryService:
    GitHubRemoteRepositoryServing, @unchecked Sendable
  {
    private var unavailableState: GitHubRemoteRepositoryState {
      GitHubRemoteRepositoryState(isConfigured: false)
    }

    func importRepositories() async throws -> GitHubRepositoryImportCatalog {
      GitHubRepositoryImportCatalog()
    }

    func authorizeImport(
      onPrompt _: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
    ) async throws -> GitHubRepositoryImportCatalog {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func importProduct(
      name _: String,
      repositoryID _: Int64,
      importer _:
        @escaping @Sendable (
          PublicGitRepositoryURL,
          GitCredentialSessionConfiguration
        ) async throws -> ImportedProduct
    ) async throws -> ImportedProduct {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func state(productID _: UUID) async -> GitHubRemoteRepositoryState {
      unavailableState
    }

    func connectLocalProduct(
      productID _: UUID,
      repositoryID _: Int64
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func connect(
      productID _: UUID,
      onPrompt _: @escaping @Sendable (GitHubDeviceAuthorizationPrompt) async -> Void
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func cancelConnection(productID _: UUID) async throws -> GitHubRemoteRepositoryState {
      unavailableState
    }

    func disconnect(productID _: UUID) async throws -> GitHubRemoteRepositoryState {
      unavailableState
    }

    func signOut(accountID _: UUID) async throws {}

    func selectLocalRepository(
      productID _: UUID,
      repositoryID _: Int64
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func refreshRepositories(productID _: UUID) async throws -> GitHubRemoteRepositoryState {
      unavailableState
    }

    func initializeLocalRepository(
      productID _: UUID
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func initializeLocalRepository(
      productID _: UUID,
      onProgress _:
        @escaping @Sendable (
          GitHubRemoteRepositoryInitializationProgress
        ) async -> Void
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func confirmTarget(
      productID _: UUID,
      expectedVersion _: Int,
      pendingObservedAt _: Date
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func check(productID _: UUID) async throws -> GitHubRemoteRepositoryState {
      unavailableState
    }

    func prepareTicketIntegration(
      productID _: UUID
    ) async throws -> GitHubTicketIntegrationPreparation {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func prepareSafeSync(productID _: UUID) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func acceptSafeSync(syncID _: UUID) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func rejectSafeSync(syncID _: UUID) async throws -> GitHubRemoteRepositoryState {
      unavailableState
    }

    func prepareTicketPullRequest(
      productID _: UUID,
      workItemID _: UUID,
      candidateRevisionID _: UUID
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func markTicketPullRequestReady(
      publicationID _: UUID
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func returnTicketPullRequestToDraft(
      publicationID _: UUID
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func syncTicketPullRequest(
      publicationID _: UUID
    ) async throws -> GitHubTicketPullRequestSync {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func mergeTicketPullRequest(
      publicationID _: UUID
    ) async throws -> GitHubTicketPullRequestMergeResult {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func refreshPullRequest(
      publicationID _: UUID
    ) async throws -> GitHubRemoteRepositoryState {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }

    func recover(productID _: UUID) async {}
    func shutdown() async {}
  }
  private enum UIFixtureSignal {
    nonisolated static func wait(for signalURL: URL) async {
      if FileManager.default.fileExists(atPath: signalURL.path) { return }

      let directoryURL = signalURL.deletingLastPathComponent()
      try? FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      let descriptor = open(directoryURL.path, O_EVTONLY)
      guard descriptor >= 0 else { return }
      defer { close(descriptor) }

      let stream = AsyncStream<Void> { continuation in
        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: descriptor,
          eventMask: [.write, .rename],
          queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler {
          guard FileManager.default.fileExists(atPath: signalURL.path) else { return }
          continuation.yield()
          continuation.finish()
        }
        source.setCancelHandler {
          continuation.finish()
        }
        continuation.onTermination = { _ in source.cancel() }
        source.resume()
        if FileManager.default.fileExists(atPath: signalURL.path) {
          continuation.yield()
          continuation.finish()
        }
      }

      for await _ in stream { return }
    }
  }
#endif
