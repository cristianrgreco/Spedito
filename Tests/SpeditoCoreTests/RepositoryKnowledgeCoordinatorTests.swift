import Foundation
import SQLite3
import Testing

@testable import SpeditoCore

@Suite("Repository knowledge coordinator", .serialized)
@MainActor
struct RepositoryKnowledgeCoordinatorTests {
  @Test("Concurrent explicit retries join one durable attempt")
  func concurrentExplicitRetries() async throws {
    let fixture = try await RepositoryKnowledgeProductFixture.make(
      name: "Retry product",
      importedSHA: String(repeating: "1", count: 40)
    )
    defer { fixture.remove() }
    let failedRun = RepositoryKnowledgeRun(
      productID: fixture.product.id,
      attempt: 1,
      purpose: .importedAppLaunch,
      analyzedSHA: fixture.repository.importedSHA,
      analyzerProfileID: fixture.analyzerID,
      reviewerProfileID: fixture.reviewerID,
      status: .failed,
      errorMessage: "The previous explicit attempt failed."
    )
    try await fixture.store.createRepositoryKnowledgeRun(failedRun)

    let recorder = RepositoryKnowledgeObservationRecorder()
    let coordinator = makeCoordinator(fixtures: [fixture], recorder: recorder)
    var joinedRetryTask: Task<RepositoryKnowledgeSnapshot?, Never>?
    recorder.onFirstRunningSnapshot = {
      joinedRetryTask = Task { @MainActor in
        await coordinator.send(.retry(productID: fixture.product.id))
      }
    }

    let firstSnapshot = try #require(
      await coordinator.send(.retry(productID: fixture.product.id))
    )
    let joinedTask = try #require(joinedRetryTask)
    let joinedSnapshot = try #require(await joinedTask.value)
    let durableRuns = try await fixture.store.fetchRepositoryKnowledgeRuns(
      productID: fixture.product.id
    )
    let durableRetry = try #require(durableRuns.first { $0.id != failedRun.id })

    #expect(firstSnapshot == joinedSnapshot)
    #expect(firstSnapshot.productID == fixture.product.id)
    #expect(firstSnapshot.run == durableRetry)
    #expect(firstSnapshot.run?.status == .pendingAnalysis)
    #expect(firstSnapshot.isRunning == false)
    #expect(firstSnapshot.failure == nil)
    #expect(durableRuns.count == 2)
    #expect(Set(durableRuns.map(\.attempt)) == Set([1, 2]))
    #expect(durableRuns.filter { $0.status == .pendingAnalysis }.count == 1)
    #expect(recorder.operationStartCount(for: fixture.product.id) == 1)
    #expect(recorder.snapshots.allSatisfy { $0.failure == nil })

    await coordinator.shutdown()
    await fixture.store.close()
  }

  @Test("Refresh publishes the exact durable run, drafts, and completion outcome")
  func refreshUsesExactDurableState() async throws {
    let fixture = try await RepositoryKnowledgeProductFixture.make(
      name: "Refresh product",
      importedSHA: String(repeating: "2", count: 40)
    )
    defer { fixture.remove() }
    let completedRunID = try await completeKnowledgePublication(in: fixture)
    let durableRun = try await fixture.store.fetchRepositoryKnowledgeRun(id: completedRunID)
    let durableDrafts = try await fixture.store.fetchRepositoryKnowledgeDrafts(
      runID: completedRunID
    )

    let recorder = RepositoryKnowledgeObservationRecorder()
    let coordinator = makeCoordinator(fixtures: [fixture], recorder: recorder)
    let refreshed = try #require(
      await coordinator.send(.refresh(productID: fixture.product.id))
    )

    #expect(refreshed.productID == fixture.product.id)
    #expect(refreshed.repository == fixture.repository)
    #expect(refreshed.run == durableRun)
    #expect(refreshed.drafts == durableDrafts)
    #expect(refreshed.completionOutcome == .publishedKnowledge)
    #expect(refreshed.activity == nil)
    #expect(refreshed.isRunning == false)
    #expect(refreshed.failure == nil)
    #expect(recorder.snapshots == [refreshed])
    #expect(coordinator.snapshot(for: fixture.product.id) == refreshed)

    await coordinator.shutdown()
    await fixture.store.close()
  }

  @Test("Publication recovery emits completion only after the durable status is completed")
  func publicationRecoveryOrdersDurabilityBeforeCompletion() async throws {
    let fixture = try await RepositoryKnowledgeProductFixture.make(
      name: "Recovery product",
      importedSHA: String(repeating: "3", count: 40)
    )
    defer { fixture.remove() }
    let publishingRun = try await createPublishingRun(in: fixture, attempt: 4)
    let recorder = RepositoryKnowledgeObservationRecorder(
      databaseURLs: [fixture.product.id: fixture.databaseURL]
    )
    let coordinator = makeCoordinator(fixtures: [fixture], recorder: recorder)

    let recovered = try #require(
      await coordinator.send(.recover(productID: fixture.product.id))
    )
    let durableRun = try await fixture.store.fetchRepositoryKnowledgeRun(id: publishingRun.id)
    let completion = try #require(recorder.events.first)

    #expect(recorder.events.count == 1)
    #expect(
      completion.event
        == .completed(productID: fixture.product.id, runID: publishingRun.id)
    )
    #expect(completion.durableStatus == .completed)
    #expect(durableRun.status == .completed)
    #expect(recovered.productID == fixture.product.id)
    #expect(recovered.run == durableRun)
    #expect(recovered.completionOutcome == .noPublishableKnowledge)
    #expect(recovered.isRunning == false)
    #expect(recovered.failure == nil)
    #expect(
      recorder.snapshots.contains {
        $0.productID == fixture.product.id
          && $0.run?.id == publishingRun.id
          && $0.run?.status == .completed
      }
    )

    await coordinator.shutdown()
    await fixture.store.close()
  }

  @Test("Concurrent product operations retain isolated snapshots")
  func concurrentProductsRetainIsolatedSnapshots() async throws {
    let firstFixture = try await RepositoryKnowledgeProductFixture.make(
      name: "First isolated product",
      importedSHA: String(repeating: "4", count: 40)
    )
    let secondFixture = try await RepositoryKnowledgeProductFixture.make(
      name: "Second isolated product",
      importedSHA: String(repeating: "5", count: 40)
    )
    defer {
      firstFixture.remove()
      secondFixture.remove()
    }
    let firstRun = try await createPublishingRun(in: firstFixture, attempt: 2)
    let secondRun = try await createPublishingRun(in: secondFixture, attempt: 7)
    let recorder = RepositoryKnowledgeObservationRecorder(
      databaseURLs: [
        firstFixture.product.id: firstFixture.databaseURL,
        secondFixture.product.id: secondFixture.databaseURL,
      ]
    )
    let coordinator = makeCoordinator(
      fixtures: [firstFixture, secondFixture],
      recorder: recorder
    )
    let gate = RepositoryKnowledgeStartGate(participantCount: 2)

    let firstTask = Task { @MainActor in
      await gate.arriveAndWait()
      return await coordinator.send(.recover(productID: firstFixture.product.id))
    }
    let secondTask = Task { @MainActor in
      await gate.arriveAndWait()
      return await coordinator.send(.recover(productID: secondFixture.product.id))
    }
    let firstSnapshot = try #require(await firstTask.value)
    let secondSnapshot = try #require(await secondTask.value)

    #expect(recorder.sawProductsRunningTogether)
    #expect(firstSnapshot.productID == firstFixture.product.id)
    #expect(firstSnapshot.repository == firstFixture.repository)
    #expect(firstSnapshot.run?.id == firstRun.id)
    #expect(firstSnapshot.run?.productID == firstFixture.product.id)
    #expect(firstSnapshot.run?.status == .completed)
    #expect(secondSnapshot.productID == secondFixture.product.id)
    #expect(secondSnapshot.repository == secondFixture.repository)
    #expect(secondSnapshot.run?.id == secondRun.id)
    #expect(secondSnapshot.run?.productID == secondFixture.product.id)
    #expect(secondSnapshot.run?.status == .completed)
    #expect(coordinator.snapshot(for: firstFixture.product.id) == firstSnapshot)
    #expect(coordinator.snapshot(for: secondFixture.product.id) == secondSnapshot)
    #expect(recorder.events.count == 2)
    #expect(
      Set(recorder.events.map { $0.event.productID })
        == Set([firstFixture.product.id, secondFixture.product.id])
    )
    #expect(recorder.events.allSatisfy { $0.durableStatus == .completed })
    for snapshot in recorder.snapshots {
      #expect(
        snapshot.productID == firstFixture.product.id
          || snapshot.productID == secondFixture.product.id
      )
      if let repository = snapshot.repository {
        #expect(repository.productID == snapshot.productID)
      }
      if let run = snapshot.run {
        #expect(run.productID == snapshot.productID)
      }
    }

    await coordinator.shutdown()
    await firstFixture.store.close()
    await secondFixture.store.close()
  }

  /// Existing partial coverage:
  /// - `RepositoryImportKnowledgeTests.importedAppLaunchReviewContract`
  /// - `RepositoryImportKnowledgeTests.schemaMigrationAndPublication`
  /// This test covers V07's owner command, durable failed attempt, and bounded retry action.
  @Test("V07 Check imported source records one durable retryable attempt")
  func v07CheckImportedSourceRecordsRetryableAttempt() async throws {
    let fixture = try await RepositoryKnowledgeProductFixture.make(
      name: "Imported source without a launch recipe",
      importedSHA: String(repeating: "7", count: 40),
      initializesWorkspaceRepository: true
    )
    defer { fixture.remove() }
    let recorder = RepositoryKnowledgeObservationRecorder()
    let transport = V07FailingCodexTransport()
    let coordinator = makeCoordinator(
      fixtures: [fixture],
      recorder: recorder,
      clientFactory: { _, _ in CodexAppServerClient(transport: transport) }
    )

    let unavailable = try #require(
      await coordinator.send(.checkImportedAppLaunch(productID: fixture.product.id))
    )
    #expect(unavailable.failure?.kind == .unavailable)
    #expect(unavailable.failure?.retryAction == .checkImportedAppLaunch)
    #expect(
      try await fixture.store.fetchRepositoryKnowledgeRuns(productID: fixture.product.id)
        .isEmpty
    )

    await coordinator.send(
      .runtimeChanged(executableURL: URL(fileURLWithPath: "/private/tmp/codex-fixture"))
    )
    let failed = try #require(
      await coordinator.send(.checkImportedAppLaunch(productID: fixture.product.id))
    )
    let runs = try await fixture.store.fetchRepositoryKnowledgeRuns(
      productID: fixture.product.id
    )
    let run = try #require(runs.first)

    #expect(runs.count == 1)
    #expect(run.purpose == .importedAppLaunch)
    #expect(run.analyzedSHA == fixture.repository.importedSHA)
    #expect(run.status == .failed)
    #expect(failed.run?.id == run.id)
    #expect(failed.failure?.retryAction == .retry)
    #expect(recorder.events.map(\.event) == [.failed(productID: fixture.product.id, runID: run.id)])

    await coordinator.shutdown()
    await fixture.store.close()
  }

  /// Existing partial coverage:
  /// - `publicationRecoveryOrdersDurabilityBeforeCompletion`
  /// - `refreshUsesExactDurableState`
  /// This test covers only K04's edit lock and recoverable-failure composition.
  @Test("K04 publication locks owner edits and failure preserves drafts for retry")
  func k04PublicationLockAndFailureRecovery() {
    let productID = UUID()
    let run = RepositoryKnowledgeRun(
      productID: productID,
      attempt: 1,
      analyzedSHA: String(repeating: "a", count: 40),
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID(),
      status: .publishing
    )
    let draft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .create,
      title: "Verified integration",
      proposedBodyMarkdown: "# Verified integration\n\nDurable facts.",
      rationale: "The repository proves this contract.",
      evidence: [.init(path: "README.md", startLine: 1, endLine: 2)]
    )
    let publishing = RepositoryKnowledgeSnapshot(
      productID: productID,
      run: run,
      drafts: [draft],
      isRunning: true
    )
    var failedRun = run
    failedRun.status = .failed
    failedRun.errorMessage = "Publishing could not finish."
    let failed = RepositoryKnowledgeSnapshot(
      productID: productID,
      run: failedRun,
      drafts: [draft],
      failure: RepositoryKnowledgeFailure(
        kind: .publication,
        message: "Publishing could not finish.",
        retryAction: .retry
      )
    )

    #expect(publishing.isActive)
    #expect(!failed.isActive)
    #expect(failed.drafts == publishing.drafts)
    #expect(failed.failure?.retryAction == .retry)
  }

  /// Existing partial coverage:
  /// - `concurrentExplicitRetries`
  /// - `refreshUsesExactDurableState`
  /// - `SQLiteStoreTests.repositoryKnowledgeActiveRunConstraintAndRecovery`
  /// This test covers only R09's stale-retry race against the accepted newer revision.
  @Test("R09 a stale retry binds to the newer accepted repository revision")
  func r09StaleRetryUsesNewerAcceptedRevision() async throws {
    let fixture = try await RepositoryKnowledgeProductFixture.make(
      name: "Advanced repository",
      importedSHA: String(repeating: "1", count: 40)
    )
    defer { fixture.remove() }
    let staleSHA = String(repeating: "2", count: 40)
    let acceptedSHA = String(repeating: "3", count: 40)
    let failedRun = RepositoryKnowledgeRun(
      productID: fixture.product.id,
      attempt: 1,
      purpose: .knowledge,
      analyzedSHA: staleSHA,
      analyzerProfileID: fixture.analyzerID,
      reviewerProfileID: fixture.reviewerID,
      status: .failed,
      errorMessage: "The stale attempt failed."
    )
    try await fixture.store.createRepositoryKnowledgeRun(failedRun)
    let gate = AcceptedRevisionGate()
    let coordinator = RepositoryKnowledgeCoordinator(
      storeProvider: { productID in
        productID == fixture.product.id ? fixture.store : nil
      },
      workspaceURLProvider: { _ in fixture.workspaceURL },
      analysisRootURLProvider: {
        fixture.rootURL.appendingPathComponent("analysis", isDirectory: true)
      },
      gitWorkspaceManager: GitWorkspaceManager(),
      acceptedTrunkSHAProvider: { _ in await gate.acceptedSHA() }
    )
    _ = await coordinator.send(
      .runtimeChanged(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
    )

    let retry = Task {
      await coordinator.send(.retry(productID: fixture.product.id))
    }
    await gate.waitUntilRequested()
    await gate.release(acceptedSHA)
    _ = await retry.value

    let durableRetry = try #require(
      try await fixture.store.fetchRepositoryKnowledgeRuns(productID: fixture.product.id)
        .first { $0.id != failedRun.id }
    )
    #expect(durableRetry.attempt == 2)
    #expect(durableRetry.analyzedSHA == acceptedSHA)
    #expect(durableRetry.analyzedSHA != staleSHA)

    await coordinator.shutdown()
    await fixture.store.close()
  }

  private func makeCoordinator(
    fixtures: [RepositoryKnowledgeProductFixture],
    recorder: RepositoryKnowledgeObservationRecorder,
    clientFactory: RepositoryKnowledgeCoordinator.ClientFactory? = nil
  ) -> RepositoryKnowledgeCoordinator {
    let stores = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.product.id, $0.store) })
    let workspaces = Dictionary(
      uniqueKeysWithValues: fixtures.map { ($0.product.id, $0.workspaceURL) }
    )
    let analysisRootURL = fixtures[0].rootURL.appendingPathComponent(
      "analysis",
      isDirectory: true
    )
    return RepositoryKnowledgeCoordinator(
      storeProvider: { stores[$0] },
      workspaceURLProvider: { productID in
        guard let workspaceURL = workspaces[productID] else {
          throw RepositoryKnowledgeCoordinatorFixtureError.missingWorkspace
        }
        return workspaceURL
      },
      analysisRootURLProvider: { analysisRootURL },
      gitWorkspaceManager: GitWorkspaceManager(),
      clientFactory: clientFactory,
      onSnapshot: { snapshot, _ in recorder.record(snapshot) },
      onEvent: recorder.record
    )
  }

  private func createPublishingRun(
    in fixture: RepositoryKnowledgeProductFixture,
    attempt: Int
  ) async throws -> RepositoryKnowledgeRun {
    let run = RepositoryKnowledgeRun(
      productID: fixture.product.id,
      attempt: attempt,
      purpose: .importedAppLaunch,
      analyzedSHA: fixture.repository.importedSHA,
      analyzerProfileID: fixture.analyzerID,
      reviewerProfileID: fixture.reviewerID,
      status: .publishing
    )
    try await fixture.store.createRepositoryKnowledgeRun(run)
    return run
  }

  private func completeKnowledgePublication(
    in fixture: RepositoryKnowledgeProductFixture
  ) async throws -> UUID {
    let pages = try await fixture.store.seedKnowledgeBase(productID: fixture.product.id)
    let home = try #require(pages.first { $0.slug == "home" })
    let run = RepositoryKnowledgeRun(
      productID: fixture.product.id,
      attempt: 1,
      analyzedSHA: fixture.repository.importedSHA,
      analyzerProfileID: fixture.analyzerID,
      reviewerProfileID: fixture.reviewerID
    )
    try await fixture.store.createRepositoryKnowledgeRun(run)
    let draft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .update,
      targetPageID: home.id,
      basePageTitle: home.title,
      basePageBodyMarkdown: home.bodyMarkdown,
      basePageUpdatedAt: home.updatedAt,
      title: home.title,
      proposedBodyMarkdown: "# Product home\n\nDurable repository knowledge.\n",
      rationale: "Records verified repository behavior",
      evidence: [.init(path: "README.md", startLine: 1, endLine: 2)]
    )
    _ = try await fixture.store.recordRepositoryKnowledgeAnalysis(
      runID: run.id,
      summary: "One durable proposal",
      drafts: [draft],
      analyzerThreadID: "refresh-analyzer-thread",
      analyzerTurnID: "refresh-analyzer-turn"
    )
    _ = try await fixture.store.recordRepositoryKnowledgeReview(
      runID: run.id,
      summary: "The proposal is supported",
      decisions: [
        .init(
          draftID: draft.id,
          approved: true,
          explanation: "README evidence supports the proposal"
        )
      ],
      reviewerThreadID: "refresh-reviewer-thread",
      reviewerTurnID: "refresh-reviewer-turn"
    )
    _ = try await fixture.store.recordRepositoryKnowledgeExport(runID: run.id, paths: [])
    _ = try await fixture.store.finalizeRepositoryKnowledgePublication(runID: run.id)
    return run.id
  }
}

private actor V07FailingCodexTransport: CodexRPCTransport {
  private let stream = AsyncStream<CodexInboundMessage> { _ in }

  func start() {}

  func request(method: String, params: JSONValue) throws -> JSONValue {
    _ = params
    guard method == "initialize" else {
      throw CodexRPCError(code: -32_601, message: "Fixture analysis failed")
    }
    return .object([
      "userAgent": .string("codex-cli/test"),
      "codexHome": .string("/private/tmp/codex"),
      "platformFamily": .string("unix"),
      "platformOs": .string("macos"),
    ])
  }

  func notify(method: String, params: JSONValue) {
    _ = method
    _ = params
  }

  func inboundMessages() -> AsyncStream<CodexInboundMessage> { stream }
  func stop() {}
}

private struct RepositoryKnowledgeProductFixture {
  let rootURL: URL
  let databaseURL: URL
  let workspaceURL: URL
  let store: SQLiteStore
  let product: Product
  let repository: ProductRepository
  let analyzerID: UUID
  let reviewerID: UUID

  static func make(
    name: String,
    importedSHA: String,
    initializesWorkspaceRepository: Bool = false
  ) async throws -> Self {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "spedito-knowledge-coordinator-\(UUID().uuidString)", isDirectory: true)
    let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspaceURL,
      withIntermediateDirectories: true
    )
    let durableImportedSHA: String
    if initializesWorkspaceRepository {
      try Data("Imported product\n".utf8).write(
        to: workspaceURL.appendingPathComponent("README.md")
      )
      durableImportedSHA = try await GitWorkspaceManager().ensureRepository(at: workspaceURL)
    } else {
      durableImportedSHA = importedSHA
    }
    let databaseURL = rootURL.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(name: name)
    let profiles = try await store.seedDefaultProfiles(productID: product.id)
    guard let analyzer = profiles.first(where: { $0.role == .businessAnalyst }),
      let reviewer = profiles.first(where: { $0.role == .lead })
    else {
      throw RepositoryKnowledgeCoordinatorFixtureError.missingProfiles
    }
    guard let originURL = URL(string: "https://example.com/\(product.id.uuidString).git") else {
      throw RepositoryKnowledgeCoordinatorFixtureError.invalidOriginURL
    }
    let repository = ProductRepository(
      productID: product.id,
      originURL: originURL,
      sourceDefaultBranch: "main",
      importedSHA: durableImportedSHA
    )
    try await store.createProductRepository(repository)
    let durableRepository = try #require(
      await store.fetchProductRepository(productID: product.id)
    )
    return Self(
      rootURL: rootURL,
      databaseURL: databaseURL,
      workspaceURL: workspaceURL,
      store: store,
      product: product,
      repository: durableRepository,
      analyzerID: analyzer.id,
      reviewerID: reviewer.id
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

@MainActor
private final class RepositoryKnowledgeObservationRecorder {
  struct RecordedEvent {
    let event: RepositoryKnowledgeEvent
    let durableStatus: RepositoryKnowledgeRunStatus?
  }

  private let databaseURLs: [UUID: URL]
  private var lastRunningState: [UUID: Bool] = [:]
  private var operationStartCounts: [UUID: Int] = [:]
  private var runningProductIDs: Set<UUID> = []
  private var invokedFirstRunningSnapshot = false

  private(set) var snapshots: [RepositoryKnowledgeSnapshot] = []
  private(set) var events: [RecordedEvent] = []
  private(set) var sawProductsRunningTogether = false
  var onFirstRunningSnapshot: (@MainActor () -> Void)?

  init(databaseURLs: [UUID: URL] = [:]) {
    self.databaseURLs = databaseURLs
  }

  func record(_ snapshot: RepositoryKnowledgeSnapshot) {
    snapshots.append(snapshot)
    if snapshot.isRunning {
      runningProductIDs.insert(snapshot.productID)
      if lastRunningState[snapshot.productID] != true {
        operationStartCounts[snapshot.productID, default: 0] += 1
      }
      if runningProductIDs.count > 1 {
        sawProductsRunningTogether = true
      }
    } else {
      runningProductIDs.remove(snapshot.productID)
    }
    lastRunningState[snapshot.productID] = snapshot.isRunning

    if snapshot.isRunning, !invokedFirstRunningSnapshot {
      invokedFirstRunningSnapshot = true
      onFirstRunningSnapshot?()
    }
  }

  func record(_ event: RepositoryKnowledgeEvent) async {
    let durableStatus = databaseURLs[event.productID].flatMap { databaseURL in
      durableRepositoryKnowledgeStatus(
        runID: event.runID,
        databaseURL: databaseURL
      )
    }
    events.append(RecordedEvent(event: event, durableStatus: durableStatus))
  }

  func operationStartCount(for productID: UUID) -> Int {
    operationStartCounts[productID, default: 0]
  }
}

private actor AcceptedRevisionGate {
  private var isRequested = false
  private var acceptedValue: String?
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var valueWaiters: [CheckedContinuation<String, Never>] = []

  func acceptedSHA() async -> String {
    isRequested = true
    let waitingForRequest = requestWaiters
    requestWaiters.removeAll()
    for waiter in waitingForRequest {
      waiter.resume()
    }
    if let acceptedValue {
      return acceptedValue
    }
    return await withCheckedContinuation { continuation in
      valueWaiters.append(continuation)
    }
  }

  func waitUntilRequested() async {
    guard !isRequested else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func release(_ sha: String) {
    acceptedValue = sha
    let waitingForValue = valueWaiters
    valueWaiters.removeAll()
    for waiter in waitingForValue {
      waiter.resume(returning: sha)
    }
  }
}

private actor RepositoryKnowledgeStartGate {
  private let participantCount: Int
  private var arrivedCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) {
    self.participantCount = participantCount
  }

  func arriveAndWait() async {
    arrivedCount += 1
    if arrivedCount == participantCount {
      let waiting = waiters
      waiters.removeAll()
      for waiter in waiting {
        waiter.resume()
      }
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private enum RepositoryKnowledgeCoordinatorFixtureError: Error {
  case invalidOriginURL
  case missingProfiles
  case missingWorkspace
}

extension RepositoryKnowledgeEvent {
  fileprivate var productID: UUID {
    switch self {
    case .completed(let productID, _), .interrupted(let productID, _),
      .failed(let productID, _):
      return productID
    }
  }

  fileprivate var runID: UUID {
    switch self {
    case .completed(_, let runID), .interrupted(_, let runID), .failed(_, let runID):
      return runID
    }
  }
}

private func durableRepositoryKnowledgeStatus(
  runID: UUID,
  databaseURL: URL
) -> RepositoryKnowledgeRunStatus? {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(
    databaseURL.path,
    &database,
    SQLITE_OPEN_READONLY,
    nil
  )
  guard openResult == SQLITE_OK, let database else {
    if let database {
      sqlite3_close(database)
    }
    return nil
  }
  defer { sqlite3_close(database) }

  let query = "SELECT status FROM repository_knowledge_runs WHERE id = '\(runID.uuidString)';"
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
    let statement
  else {
    return nil
  }
  defer { sqlite3_finalize(statement) }
  guard sqlite3_step(statement) == SQLITE_ROW,
    let statusText = sqlite3_column_text(statement, 0)
  else {
    return nil
  }
  return RepositoryKnowledgeRunStatus(rawValue: String(cString: statusText))
}
