import Foundation

public enum RepositoryKnowledgeCommand: Equatable, Sendable {
  case schedule(productIDs: [UUID])
  case recover(productID: UUID)
  case retry(productID: UUID)
  case checkImportedAppLaunch(productID: UUID)
  case cancel(productID: UUID)
  case refresh(productID: UUID)
  case runtimeChanged(executableURL: URL?)
}

public enum RepositoryKnowledgeFailureKind: Equatable, Sendable {
  case unavailable
  case persistence
  case staleRepository
  case analysis
  case publication
}

public enum RepositoryKnowledgeRetryAction: Equatable, Sendable {
  case recover
  case retry
  case checkImportedAppLaunch
}

public struct RepositoryKnowledgeFailure: Error, Equatable, LocalizedError, Sendable {
  public let kind: RepositoryKnowledgeFailureKind
  public let message: String
  public let retryAction: RepositoryKnowledgeRetryAction?

  public init(
    kind: RepositoryKnowledgeFailureKind,
    message: String,
    retryAction: RepositoryKnowledgeRetryAction?
  ) {
    self.kind = kind
    self.message = message
    self.retryAction = retryAction
  }

  public var errorDescription: String? { message }
}

public enum RepositoryKnowledgeEvent: Equatable, Sendable {
  case completed(productID: UUID, runID: UUID)
  case interrupted(productID: UUID, runID: UUID)
  case failed(productID: UUID, runID: UUID)
}

public struct RepositoryKnowledgeSnapshot: Equatable, Sendable {
  public let productID: UUID
  public var repository: ProductRepository?
  public var run: RepositoryKnowledgeRun?
  public var drafts: [RepositoryKnowledgeDraft]
  public var activity: CodexLiveActivity?
  public var completionOutcome: RepositoryKnowledgeCompletionOutcome?
  public var isRunning: Bool
  public var failure: RepositoryKnowledgeFailure?

  public init(
    productID: UUID,
    repository: ProductRepository? = nil,
    run: RepositoryKnowledgeRun? = nil,
    drafts: [RepositoryKnowledgeDraft] = [],
    activity: CodexLiveActivity? = nil,
    completionOutcome: RepositoryKnowledgeCompletionOutcome? = nil,
    isRunning: Bool = false,
    failure: RepositoryKnowledgeFailure? = nil
  ) {
    self.productID = productID
    self.repository = repository
    self.run = run
    self.drafts = drafts
    self.activity = activity
    self.completionOutcome = completionOutcome
    self.isRunning = isRunning
    self.failure = failure
  }

  public var isActive: Bool {
    guard let status = run?.status else { return isRunning }
    switch status {
    case .pendingAnalysis, .analyzing, .reviewing, .publishing:
      return true
    case .completed, .failed, .interrupted, .stale:
      return isRunning
    }
  }
}

@MainActor
public final class RepositoryKnowledgeCoordinator {
  public typealias StoreProvider = @MainActor (UUID) -> SQLiteStore?
  public typealias WorkspaceURLProvider = @MainActor (UUID) throws -> URL
  public typealias AnalysisRootURLProvider = @MainActor () throws -> URL
  public typealias ClientFactory = @MainActor (URL, URL) -> CodexAppServerClient
  public typealias SnapshotObserver = @MainActor (
    RepositoryKnowledgeSnapshot,
    RepositoryKnowledgeEvent?
  ) -> Void
  public typealias EventObserver = @MainActor (RepositoryKnowledgeEvent) async -> Void

  private enum OperationKind: Sendable {
    case recover
    case retry
    case checkImportedAppLaunch
  }

  private struct ActiveOperation {
    let id: UUID
    let task: Task<Void, Never>
  }

  private let storeProvider: StoreProvider
  private let workspaceURLProvider: WorkspaceURLProvider
  private let analysisRootURLProvider: AnalysisRootURLProvider
  private let gitWorkspaceManager: GitWorkspaceManager
  private let recoveryPolicy = RepositoryKnowledgeRecoveryPolicy()
  private let clientFactory: ClientFactory
  private let onSnapshot: SnapshotObserver
  private let onEvent: EventObserver

  private var runtimeExecutableURL: URL?
  private var snapshots: [UUID: RepositoryKnowledgeSnapshot] = [:]
  private var operations: [UUID: ActiveOperation] = [:]
  private var clients: [UUID: CodexAppServerClient] = [:]
  private var activeTurns: [UUID: (threadID: String, turnID: String)] = [:]
  private var activityTasks: [UUID: Task<Void, Never>] = [:]
  private var activityMonitorIDs: [UUID: UUID] = [:]
  private var isShuttingDown = false

  public init(
    storeProvider: @escaping StoreProvider,
    workspaceURLProvider: @escaping WorkspaceURLProvider,
    analysisRootURLProvider: AnalysisRootURLProvider? = nil,
    gitWorkspaceManager: GitWorkspaceManager,
    clientFactory: ClientFactory? = nil,
    onSnapshot: @escaping SnapshotObserver = { _, _ in },
    onEvent: @escaping EventObserver = { _ in }
  ) {
    self.storeProvider = storeProvider
    self.workspaceURLProvider = workspaceURLProvider
    self.analysisRootURLProvider =
      analysisRootURLProvider ?? Self.defaultAnalysisRootURL
    self.gitWorkspaceManager = gitWorkspaceManager
    self.clientFactory = clientFactory ?? Self.makeClient
    self.onSnapshot = onSnapshot
    self.onEvent = onEvent
  }

  public var hasActiveOperations: Bool { !operations.isEmpty }

  public func snapshot(for productID: UUID) -> RepositoryKnowledgeSnapshot {
    snapshots[productID] ?? RepositoryKnowledgeSnapshot(productID: productID)
  }

  @discardableResult
  public func send(_ command: RepositoryKnowledgeCommand) async -> RepositoryKnowledgeSnapshot? {
    switch command {
    case .schedule(let productIDs):
      guard !isShuttingDown else { return nil }
      for productID in productIDs {
        startOperation(.recover, productID: productID)
      }
      return nil
    case .recover(let productID):
      await runAndWait(.recover, productID: productID)
      return snapshot(for: productID)
    case .retry(let productID):
      await runAndWait(.retry, productID: productID)
      return snapshot(for: productID)
    case .checkImportedAppLaunch(let productID):
      await runAndWait(.checkImportedAppLaunch, productID: productID)
      return snapshot(for: productID)
    case .cancel(let productID):
      await cancel(productID: productID)
      return snapshot(for: productID)
    case .refresh(let productID):
      await refreshSnapshot(productID: productID)
      return snapshot(for: productID)
    case .runtimeChanged(let executableURL):
      runtimeExecutableURL = executableURL
      return nil
    }
  }

  public func shutdown() async {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    let activeOperations = operations
    for operation in activeOperations.values {
      operation.task.cancel()
    }
    for (runID, turn) in activeTurns {
      if let client = clients[runID] {
        try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
      }
    }
    for operation in activeOperations.values {
      await operation.task.value
    }
    operations.removeAll()
    activeTurns.removeAll()
    for task in activityTasks.values {
      task.cancel()
    }
    activityTasks.removeAll()
    activityMonitorIDs.removeAll()
    for client in clients.values {
      await client.disconnect()
    }
    clients.removeAll()
  }

  public func cleanupAbandonedSnapshots() throws {
    guard operations.isEmpty else { return }
    try GitWorkspaceManager.cleanupRepositoryAnalysisSnapshots(
      rootURL: analysisRootURLProvider()
    )
  }

  private func runAndWait(_ kind: OperationKind, productID: UUID) async {
    if let operation = operations[productID] {
      await operation.task.value
      return
    }
    startOperation(kind, productID: productID)
    if let operation = operations[productID] {
      await operation.task.value
    }
  }

  private func startOperation(_ kind: OperationKind, productID: UUID) {
    guard !isShuttingDown, operations[productID] == nil else { return }
    let operationID = UUID()
    var snapshot = snapshot(for: productID)
    snapshot.isRunning = true
    snapshot.failure = nil
    publish(snapshot)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.finishOperation(productID: productID, operationID: operationID) }
      switch kind {
      case .recover:
        await self.recoverOrRun(productID: productID)
      case .retry:
        await self.retry(productID: productID)
      case .checkImportedAppLaunch:
        await self.checkImportedAppLaunch(productID: productID)
      }
    }
    operations[productID] = ActiveOperation(id: operationID, task: task)
  }

  private func finishOperation(productID: UUID, operationID: UUID) {
    guard operations[productID]?.id == operationID else { return }
    operations[productID] = nil
    var snapshot = snapshot(for: productID)
    snapshot.isRunning = false
    publish(snapshot)
  }

  private func cancel(productID: UUID) async {
    guard let operation = operations[productID] else { return }
    operation.task.cancel()
    if let run = snapshot(for: productID).run,
      let turn = activeTurns[run.id],
      let client = clients[run.id]
    {
      try? await client.interruptTurn(threadID: turn.threadID, turnID: turn.turnID)
    }
    await operation.task.value
  }

  private func recoverOrRun(productID: UUID) async {
    guard !Task.isCancelled, let store = storeProvider(productID) else { return }
    do {
      guard try await store.fetchProductRepository(productID: productID) != nil,
        let latest = try await store.fetchLatestRepositoryKnowledgeRun(productID: productID)
      else {
        await refreshSnapshot(productID: productID)
        return
      }
      let action = recoveryPolicy.action(for: latest)
      guard
        recoveryPolicy.canExecute(
          action,
          codexConnectionAvailable: runtimeExecutableURL != nil
        )
      else {
        await refreshSnapshot(productID: productID)
        return
      }
      let run: RepositoryKnowledgeRun
      switch action {
      case .startPendingAnalysis, .resumePublication:
        run = latest
      case .createRecoveryAttempt:
        guard
          let recovered = try await createRetry(
            productID: productID,
            after: latest,
            store: store,
            interruptionMessage: "Analysis was interrupted when Spedito closed and is being retried."
          )
        else {
          setFailure(
            RepositoryKnowledgeFailure(
              kind: .unavailable,
              message: "Repository analysis needs an active business analyst and tech lead on this product.",
              retryAction: .recover
            ),
            productID: productID
          )
          return
        }
        run = recovered
      case .none:
        await refreshSnapshot(productID: productID)
        return
      }
      await execute(run, store: store)
    } catch {
      setFailure(classify(error, retryAction: .recover), productID: productID)
      await refreshSnapshot(productID: productID, preservingFailure: true)
    }
  }

  private func retry(productID: UUID) async {
    guard let store = storeProvider(productID) else { return }
    do {
      guard let latest = try await store.fetchLatestRepositoryKnowledgeRun(productID: productID)
      else {
        await refreshSnapshot(productID: productID)
        return
      }
      let retriesCompletedAnalysis: Bool
      if latest.status == .completed {
        let drafts = try await store.fetchRepositoryKnowledgeDrafts(runID: latest.id)
        let pages = try await store.fetchKnowledgePages(productID: productID)
        retriesCompletedAnalysis =
          recoveryPolicy.completionOutcome(for: latest, drafts: drafts, pages: pages)
          == .noPublishableKnowledge
      } else {
        retriesCompletedAnalysis = false
      }
      guard latest.status == .failed || latest.status == .interrupted || latest.status == .stale
        || latest.status == .publishing || latest.status == .pendingAnalysis
        || retriesCompletedAnalysis
      else {
        await refreshSnapshot(productID: productID)
        return
      }
      let run: RepositoryKnowledgeRun
      if latest.status == .publishing || latest.status == .pendingAnalysis {
        run = latest
      } else {
        guard
          let retry = try await createRetry(
            productID: productID,
            after: latest,
            store: store,
            interruptionMessage: nil
          )
        else {
          setFailure(
            RepositoryKnowledgeFailure(
              kind: .unavailable,
              message: "Repository analysis needs an active business analyst and tech lead on this product.",
              retryAction: .retry
            ),
            productID: productID
          )
          return
        }
        run = retry
      }
      await present(run, store: store)
      guard run.status != .pendingAnalysis || runtimeExecutableURL != nil else { return }
      await execute(run, store: store)
    } catch {
      setFailure(classify(error, retryAction: .retry), productID: productID)
      await refreshSnapshot(productID: productID, preservingFailure: true)
    }
  }

  private func checkImportedAppLaunch(productID: UUID) async {
    guard let store = storeProvider(productID) else { return }
    guard runtimeExecutableURL != nil else {
      setFailure(
        RepositoryKnowledgeFailure(
          kind: .unavailable,
          message: "Checking the imported app needs the Codex team connection.",
          retryAction: .checkImportedAppLaunch
        ),
        productID: productID
      )
      return
    }
    do {
      guard let repository = try await store.fetchProductRepository(productID: productID) else {
        await refreshSnapshot(productID: productID)
        return
      }
      let profiles = try await store.fetchAgentProfiles(productID: productID)
      guard let analyzer = profiles.first(where: { $0.role == .businessAnalyst }),
        let reviewer = profiles.first(where: { $0.role == .lead })
      else {
        setFailure(
          RepositoryKnowledgeFailure(
            kind: .unavailable,
            message: "Checking the imported app needs an active business analyst and tech lead.",
            retryAction: .checkImportedAppLaunch
          ),
          productID: productID
        )
        return
      }
      let attempts = try await store.fetchRepositoryKnowledgeRuns(productID: productID)
      let run = RepositoryKnowledgeRun(
        productID: productID,
        attempt: (attempts.map(\.attempt).max() ?? 0) + 1,
        purpose: .importedAppLaunch,
        analyzedSHA: repository.importedSHA,
        analyzerProfileID: analyzer.id,
        reviewerProfileID: reviewer.id
      )
      try await store.createRepositoryKnowledgeRun(run)
      let durableRun = try await store.fetchRepositoryKnowledgeRun(id: run.id)
      await present(durableRun, store: store)
      await execute(durableRun, store: store)
    } catch {
      setFailure(
        classify(error, retryAction: .checkImportedAppLaunch),
        productID: productID
      )
      await refreshSnapshot(productID: productID, preservingFailure: true)
    }
  }

  private func createRetry(
    productID: UUID,
    after previous: RepositoryKnowledgeRun,
    store: SQLiteStore,
    interruptionMessage: String?
  ) async throws -> RepositoryKnowledgeRun? {
    let profiles = try await store.fetchAgentProfiles(productID: productID)
    guard let analyzer = profiles.first(where: { $0.role == .businessAnalyst }),
      let reviewer = profiles.first(where: { $0.role == .lead })
    else {
      return nil
    }
    let analyzedSHA: String
    if previous.purpose == .importedAppLaunch {
      guard let repository = try await store.fetchProductRepository(productID: productID) else {
        return nil
      }
      analyzedSHA = repository.importedSHA
    } else {
      analyzedSHA = try await gitWorkspaceManager.acceptedTrunkSHA(
        at: workspaceURLProvider(productID)
      )
    }
    if let interruptionMessage {
      return try await store.recoverRepositoryKnowledgeRun(
        interruptedRunID: previous.id,
        errorMessage: interruptionMessage,
        analyzedSHA: analyzedSHA,
        analyzerProfileID: analyzer.id,
        reviewerProfileID: reviewer.id
      )
    }
    return try await store.createRepositoryKnowledgeRetry(
      productID: productID,
      analyzedSHA: analyzedSHA,
      purpose: previous.purpose,
      analyzerProfileID: analyzer.id,
      reviewerProfileID: reviewer.id
    )
  }

  private func execute(_ initialRun: RepositoryKnowledgeRun, store: SQLiteStore) async {
    var snapshotURL: URL?
    var analysisClient: CodexAppServerClient?
    var currentRun = initialRun
    do {
      var run = try await store.fetchRepositoryKnowledgeRun(id: initialRun.id)
      currentRun = run
      if run.status == .pendingAnalysis {
        guard let executableURL = runtimeExecutableURL else {
          throw CodexClientError.notConnected
        }
        let activeProfiles = try await store.fetchAgentProfiles(productID: run.productID)
        guard let analyzer = activeProfiles.first(where: { $0.id == run.analyzerProfileID }),
          let reviewer = activeProfiles.first(where: { $0.id == run.reviewerProfileID })
        else {
          run = try await store.updateRepositoryKnowledgeRun(
            id: run.id,
            status: .pendingAnalysis,
            errorMessage: "Repository analysis needs its active business analyst and tech lead."
          )
          await present(run, store: store)
          return
        }
        let workspaceURL = try workspaceURLProvider(run.productID)
        let destinationURL = try analysisRootURLProvider()
          .appendingPathComponent(run.id.uuidString, isDirectory: true)
        let repositorySnapshot = try await gitWorkspaceManager.prepareRepositoryAnalysisSnapshot(
          repositoryURL: workspaceURL,
          sha: run.analyzedSHA,
          destinationURL: destinationURL
        )
        snapshotURL = repositorySnapshot.url
        let client = clientFactory(executableURL, repositorySnapshot.url)
        analysisClient = client
        clients[run.id] = client
        _ = try await client.connect()

        run = try await store.updateRepositoryKnowledgeRun(id: run.id, status: .analyzing)
        currentRun = run
        await present(run, store: store)
        let analyzerThreadID = try await client.startRepositoryAnalysisThread(
          snapshotURL: repositorySnapshot.url,
          developerInstructions: repositoryInstructions(
            base: CodexRepositoryKnowledgeAnalyzer.developerInstructions,
            profile: analyzer
          ),
          model: analyzer.model
        )
        monitorActivity(
          productID: run.productID,
          runID: run.id,
          client: client,
          threadID: analyzerThreadID,
          initialText: "Reading repository evidence…"
        )
        let pages = try await store.fetchKnowledgePages(productID: run.productID)
        var analyzerTurnID = try await client.startStructuredTurn(
          threadID: analyzerThreadID,
          prompt: try CodexRepositoryKnowledgeAnalyzer.prompt(
            run: run,
            pages: pages,
            snapshot: repositorySnapshot
          ),
          effort: analyzer.reasoningEffort,
          outputSchema: CodexRepositoryKnowledgeAnalyzer.outputSchema,
          runtimeWorkspaceRoots: [repositorySnapshot.url],
          responseTimeout: .seconds(30)
        )
        activeTurns[run.id] = (analyzerThreadID, analyzerTurnID)
        run = try await store.updateRepositoryKnowledgeRun(
          id: run.id,
          status: .analyzing,
          analyzerThreadID: analyzerThreadID,
          analyzerTurnID: analyzerTurnID
        )
        currentRun = run
        await present(run, store: store)
        let analyzerText = try await client.waitForFinalAgentMessage(
          threadID: analyzerThreadID,
          turnID: analyzerTurnID,
          timeout: .seconds(120),
          totalTimeout: .seconds(1_200)
        )
        activeTurns[run.id] = nil
        var analysis = try CodexRepositoryKnowledgeAnalyzer.decode(
          analyzerText,
          run: run,
          pages: pages,
          snapshot: repositorySnapshot
        )
        if let launchIssue = analysis.launchProposalIssue {
          updateActivity(
            CodexLiveActivity(
              text: "Correcting the imported app recipe…",
              kind: .inspecting
            ),
            productID: run.productID,
            runID: run.id
          )
          let correctionTurnID = try await client.startStructuredTurn(
            threadID: analyzerThreadID,
            prompt: CodexRepositoryKnowledgeAnalyzer.launchCorrectionPrompt(reason: launchIssue),
            effort: analyzer.reasoningEffort,
            outputSchema: CodexRepositoryKnowledgeAnalyzer.outputSchema,
            runtimeWorkspaceRoots: [repositorySnapshot.url],
            responseTimeout: .seconds(30)
          )
          analyzerTurnID = correctionTurnID
          activeTurns[run.id] = (analyzerThreadID, correctionTurnID)
          run = try await store.updateRepositoryKnowledgeRun(
            id: run.id,
            status: .analyzing,
            analyzerThreadID: analyzerThreadID,
            analyzerTurnID: correctionTurnID
          )
          currentRun = run
          await present(run, store: store)
          let correctedText = try await client.waitForFinalAgentMessage(
            threadID: analyzerThreadID,
            turnID: correctionTurnID,
            timeout: .seconds(120),
            totalTimeout: .seconds(1_200)
          )
          activeTurns[run.id] = nil
          let corrected = try CodexRepositoryKnowledgeAnalyzer.decode(
            correctedText,
            run: run,
            pages: pages,
            snapshot: repositorySnapshot
          )
          analysis = RepositoryKnowledgeAnalysisResult(
            summary: analysis.summary,
            drafts: analysis.drafts,
            launchProposal: corrected.launchProposal,
            launchProposalIssue: corrected.launchProposalIssue
          )
        }
        if run.purpose == .importedAppLaunch, let launchIssue = analysis.launchProposalIssue {
          throw RepositoryKnowledgeAnalysisError.invalidResponse(
            "The imported app recipe could not be validated after one correction: \(launchIssue)"
          )
        }
        if let launchIssue = analysis.launchProposalIssue {
          analysis = RepositoryKnowledgeAnalysisResult(
            summary: "\(analysis.summary)\n\nThe optional imported app recipe was not saved: \(launchIssue)",
            drafts: analysis.drafts
          )
        }
        try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
          at: workspaceURL,
          sha: run.analyzedSHA,
          evidence: analysis.drafts.flatMap(\.evidence)
            + (analysis.launchProposal?.evidence ?? []),
          requiresTrunkRevisionMatch: run.purpose == .knowledge
        )
        run = try await store.recordRepositoryKnowledgeAnalysis(
          runID: run.id,
          summary: analysis.summary,
          drafts: analysis.drafts,
          launchProposal: analysis.launchProposal,
          analyzerThreadID: analyzerThreadID,
          analyzerTurnID: analyzerTurnID
        )
        currentRun = run
        let persistedDrafts = try await store.fetchRepositoryKnowledgeDrafts(runID: run.id)
        let persistedLaunchProposal = try await store.fetchRepositoryLaunchProposal(runID: run.id)
        await present(run, drafts: persistedDrafts, store: store)
        if run.status == .completed {
          await finish(
            run: run,
            snapshotURL: snapshotURL,
            client: analysisClient,
            event: .completed(productID: run.productID, runID: run.id)
          )
          return
        }

        let reviewerThreadID = try await client.startRepositoryAnalysisThread(
          snapshotURL: repositorySnapshot.url,
          developerInstructions: repositoryInstructions(
            base: CodexRepositoryKnowledgeReviewer.developerInstructions,
            profile: reviewer
          ),
          model: reviewer.model
        )
        monitorActivity(
          productID: run.productID,
          runID: run.id,
          client: client,
          threadID: reviewerThreadID,
          initialText: "Checking proposed product information…"
        )
        let reviewerTurnID = try await client.startStructuredTurn(
          threadID: reviewerThreadID,
          prompt: try CodexRepositoryKnowledgeReviewer.prompt(
            run: run,
            drafts: persistedDrafts,
            launchProposal: persistedLaunchProposal,
            snapshot: repositorySnapshot
          ),
          effort: reviewer.reasoningEffort,
          outputSchema: CodexRepositoryKnowledgeReviewer.outputSchema,
          runtimeWorkspaceRoots: [repositorySnapshot.url],
          responseTimeout: .seconds(30)
        )
        activeTurns[run.id] = (reviewerThreadID, reviewerTurnID)
        run = try await store.updateRepositoryKnowledgeRun(
          id: run.id,
          status: .reviewing,
          reviewerThreadID: reviewerThreadID,
          reviewerTurnID: reviewerTurnID
        )
        currentRun = run
        await present(run, drafts: persistedDrafts, store: store)
        let reviewerText = try await client.waitForFinalAgentMessage(
          threadID: reviewerThreadID,
          turnID: reviewerTurnID,
          timeout: .seconds(120),
          totalTimeout: .seconds(1_200)
        )
        activeTurns[run.id] = nil
        let review = try CodexRepositoryKnowledgeReviewer.decode(
          reviewerText,
          drafts: persistedDrafts,
          launchProposal: persistedLaunchProposal
        )
        try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
          at: workspaceURL,
          sha: run.analyzedSHA,
          evidence: persistedDrafts.flatMap(\.evidence)
            + (persistedLaunchProposal?.evidence ?? []),
          requiresTrunkRevisionMatch: run.purpose == .knowledge
        )
        run = try await store.recordRepositoryKnowledgeReview(
          runID: run.id,
          summary: review.summary,
          decisions: review.decisions,
          launchDecision: review.launchDecision,
          reviewerThreadID: reviewerThreadID,
          reviewerTurnID: reviewerTurnID
        )
        currentRun = run
        await present(run, drafts: persistedDrafts, store: store)
      }

      if run.status == .publishing {
        stopActivityMonitoring(productID: run.productID, runID: run.id)
        updateActivity(
          CodexLiveActivity(
            text: run.purpose == .importedAppLaunch
              ? "Saving the verified imported app recipe…"
              : "Saving verified product information…",
            kind: .inspecting
          ),
          productID: run.productID,
          runID: run.id
        )
        if run.purpose == .importedAppLaunch {
          run = try await store.finalizeRepositoryKnowledgePublication(runID: run.id)
        } else {
          run = try await publishKnowledge(run: run, store: store)
        }
        currentRun = run
        await present(run, store: store)
      }
      await finish(
        run: run,
        snapshotURL: snapshotURL,
        client: analysisClient,
        event: run.status == .completed
          ? .completed(productID: run.productID, runID: run.id)
          : nil
      )
    } catch is CancellationError {
      await interrupt(
        currentRun,
        store: store,
        publishingRemainsResumable: true
      )
      await finish(
        run: currentRun,
        snapshotURL: snapshotURL,
        client: analysisClient,
        event: .interrupted(productID: currentRun.productID, runID: currentRun.id)
      )
    } catch {
      await fail(currentRun, error: error, store: store)
      await finish(
        run: currentRun,
        snapshotURL: snapshotURL,
        client: analysisClient,
        event: .failed(productID: currentRun.productID, runID: currentRun.id)
      )
    }
  }

  private func monitorActivity(
    productID: UUID,
    runID: UUID,
    client: CodexAppServerClient,
    threadID: String,
    initialText: String
  ) {
    stopActivityMonitoring(productID: productID)
    let monitorID = UUID()
    activityMonitorIDs[productID] = monitorID
    updateActivity(
      CodexLiveActivity(text: initialText, kind: .thinking),
      productID: productID,
      runID: runID
    )
    activityTasks[productID] = Task { @MainActor [weak self] in
      guard let self else { return }
      var accumulator = CodexLiveActivityAccumulator()
      let messages = await client.inboundMessages(replayRecent: true)
      for await message in messages {
        guard !Task.isCancelled else { break }
        guard case .notification(let notification) = message else { continue }
        guard notification.params["threadId"]?.stringValue == threadID,
          self.activityMonitorIDs[productID] == monitorID,
          self.snapshot(for: productID).run?.id == runID
        else {
          continue
        }
        switch accumulator.consume(notification) {
        case .activity(let activity):
          self.updateActivity(activity, productID: productID, runID: runID)
        case .turnFinished:
          self.stopActivityMonitoring(productID: productID, runID: runID)
          return
        case nil:
          continue
        }
      }
      guard self.activityMonitorIDs[productID] == monitorID else { return }
      self.stopActivityMonitoring(productID: productID, runID: runID)
    }
  }

  private func stopActivityMonitoring(productID: UUID, runID: UUID? = nil) {
    if let runID, snapshot(for: productID).run?.id != runID { return }
    activityTasks.removeValue(forKey: productID)?.cancel()
    activityMonitorIDs.removeValue(forKey: productID)
    var snapshot = snapshot(for: productID)
    snapshot.activity = nil
    publish(snapshot)
  }

  private func updateActivity(
    _ activity: CodexLiveActivity,
    productID: UUID,
    runID: UUID
  ) {
    var snapshot = snapshot(for: productID)
    guard snapshot.run?.id == runID else { return }
    snapshot.activity = activity
    publish(snapshot)
  }

  private func present(
    _ run: RepositoryKnowledgeRun,
    drafts: [RepositoryKnowledgeDraft]? = nil,
    store: SQLiteStore
  ) async {
    var snapshot = snapshot(for: run.productID)
    let previousRunID = snapshot.run?.id
    snapshot.repository = try? await store.fetchProductRepository(productID: run.productID)
    snapshot.run = run
    if let drafts {
      snapshot.drafts = drafts
    } else if previousRunID != run.id {
      snapshot.drafts = (try? await store.fetchRepositoryKnowledgeDrafts(runID: run.id)) ?? []
    }
    if run.status == .completed {
      let pages = (try? await store.fetchKnowledgePages(productID: run.productID)) ?? []
      snapshot.completionOutcome = recoveryPolicy.completionOutcome(
        for: run,
        drafts: snapshot.drafts,
        pages: pages
      )
    } else {
      snapshot.completionOutcome = nil
    }
    snapshot.failure = nil
    publish(snapshot)
  }

  private func refreshSnapshot(productID: UUID, preservingFailure: Bool = false) async {
    guard let store = storeProvider(productID) else { return }
    do {
      let previousFailure = snapshots[productID]?.failure
      let repository = try await store.fetchProductRepository(productID: productID)
      let run = try await store.fetchLatestRepositoryKnowledgeRun(productID: productID)
      let drafts: [RepositoryKnowledgeDraft] = if let run {
        try await store.fetchRepositoryKnowledgeDrafts(runID: run.id)
      } else {
        []
      }
      let pages: [KnowledgePage] = if run?.status == .completed {
        try await store.fetchKnowledgePages(productID: productID)
      } else {
        []
      }
      let outcome = run.flatMap {
        recoveryPolicy.completionOutcome(for: $0, drafts: drafts, pages: pages)
      }
      let refreshed = RepositoryKnowledgeSnapshot(
        productID: productID,
        repository: repository,
        run: run,
        drafts: drafts,
        activity: snapshots[productID]?.activity,
        completionOutcome: outcome,
        isRunning: operations[productID] != nil,
        failure: preservingFailure ? previousFailure : nil
      )
      publish(refreshed)
    } catch {
      setFailure(classify(error, retryAction: .recover), productID: productID)
    }
  }

  private func publishKnowledge(
    run: RepositoryKnowledgeRun,
    store: SQLiteStore
  ) async throws -> RepositoryKnowledgeRun {
    guard let repository = try await store.fetchProductRepository(productID: run.productID) else {
      throw PersistenceError.corruptData("Imported repository provenance is missing")
    }
    let workspaceURL = try workspaceURLProvider(run.productID)
    let drafts = try await store.fetchRepositoryKnowledgeDrafts(runID: run.id)
    if run.knowledgeExportPaths.isEmpty, run.knowledgeCommitSHA == nil {
      try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
        at: workspaceURL,
        sha: run.analyzedSHA,
        evidence: drafts.filter { $0.status != .rejected }.flatMap(\.evidence)
      )
      return try await store.finalizeRepositoryKnowledgePublication(runID: run.id)
    }
    try await gitWorkspaceManager.validateRepositoryAnalysisRevision(
      at: workspaceURL,
      sha: run.analyzedSHA,
      evidence: drafts.filter { $0.status != .rejected }.flatMap(\.evidence),
      requiresCleanWorkspace: false
    )
    let projection = try await store.projectRepositoryKnowledgePublication(runID: run.id)
    let export = try await RepositoryKnowledgeExporter.export(
      projection: projection,
      changedPageIDs: Set(projection.changedPageIDs),
      repository: repository,
      workspaceURL: workspaceURL,
      gitWorkspaceManager: gitWorkspaceManager
    )
    var currentRun = run
    if !currentRun.knowledgeExportPaths.isEmpty, currentRun.knowledgeCommitSHA == nil {
      let expected = Dictionary(
        uniqueKeysWithValues: currentRun.knowledgeExportPaths.compactMap { path in
          export.expectedContents[path].map { (path, $0) }
        }
      )
      guard expected.count == currentRun.knowledgeExportPaths.count else {
        throw PersistenceError.corruptData(
          "Repository knowledge publication content could not be reconstructed"
        )
      }
      if let recoveredSHA = try await gitWorkspaceManager.recoverRepositoryKnowledgeCheckpoint(
        at: workspaceURL,
        analyzedSHA: run.analyzedSHA,
        expectedFiles: expected
      ) {
        currentRun = try await store.recordRepositoryKnowledgeCommitSHA(
          runID: run.id,
          sha: recoveredSHA
        )
      }
    } else if currentRun.knowledgeCommitSHA == nil {
      currentRun = try await store.recordRepositoryKnowledgeExport(
        runID: run.id,
        paths: export.touchedPaths
      )
      if !export.touchedPaths.isEmpty {
        let expected = Dictionary(
          uniqueKeysWithValues: export.touchedPaths.compactMap { path in
            export.expectedContents[path].map { (path, $0) }
          }
        )
        let commitSHA = try await gitWorkspaceManager.checkpointRepositoryKnowledge(
          at: workspaceURL,
          analyzedSHA: run.analyzedSHA,
          expectedFiles: expected
        )
        currentRun = try await store.recordRepositoryKnowledgeCommitSHA(
          runID: run.id,
          sha: commitSHA
        )
      }
    }
    return try await store.finalizeRepositoryKnowledgePublication(runID: run.id)
  }

  private func interrupt(
    _ run: RepositoryKnowledgeRun,
    store: SQLiteStore,
    publishingRemainsResumable: Bool
  ) async {
    do {
      let durable = try await store.fetchRepositoryKnowledgeRun(id: run.id)
      let status: RepositoryKnowledgeRunStatus =
        publishingRemainsResumable && durable.status == .publishing ? .publishing : .interrupted
      let interrupted = try await store.updateRepositoryKnowledgeRun(
        id: run.id,
        status: status,
        errorMessage: status == .publishing
          ? "Spedito closed while verified knowledge was publishing. Publication will resume."
          : "Spedito closed before repository analysis finished."
      )
      await present(interrupted, store: store)
    } catch {
      setFailure(classify(error, retryAction: .recover), productID: run.productID)
    }
  }

  private func fail(_ run: RepositoryKnowledgeRun, error: Error, store: SQLiteStore) async {
    do {
      let durable = try await store.fetchRepositoryKnowledgeRun(id: run.id)
      let status: RepositoryKnowledgeRunStatus
      if error is GitWorkspaceError || error is RepositoryAnalysisSnapshotError {
        status = .stale
      } else if durable.status == .publishing {
        status = .publishing
      } else {
        status = .failed
      }
      let failed = try await store.updateRepositoryKnowledgeRun(
        id: run.id,
        status: status,
        errorMessage: error.localizedDescription
      )
      await present(failed, store: store)
      setFailure(
        classify(error, retryAction: status == .publishing ? .recover : .retry),
        productID: run.productID
      )
    } catch {
      setFailure(classify(error, retryAction: .recover), productID: run.productID)
    }
  }

  private func finish(
    run: RepositoryKnowledgeRun,
    snapshotURL: URL?,
    client: CodexAppServerClient?,
    event: RepositoryKnowledgeEvent?
  ) async {
    activeTurns[run.id] = nil
    stopActivityMonitoring(productID: run.productID, runID: run.id)
    clients[run.id] = nil
    if let client {
      await client.disconnect()
    }
    if let snapshotURL {
      do {
        try GitWorkspaceManager.removeRepositoryAnalysisSnapshot(at: snapshotURL)
      } catch {
        setFailure(classify(error, retryAction: .recover), productID: run.productID)
      }
    }
    if let event {
      onSnapshot(snapshot(for: run.productID), event)
      await onEvent(event)
    }
  }

  private func setFailure(_ failure: RepositoryKnowledgeFailure, productID: UUID) {
    var snapshot = snapshot(for: productID)
    snapshot.failure = failure
    publish(snapshot)
  }

  private func publish(
    _ snapshot: RepositoryKnowledgeSnapshot,
    event: RepositoryKnowledgeEvent? = nil
  ) {
    snapshots[snapshot.productID] = snapshot
    onSnapshot(snapshot, event)
  }

  private func classify(
    _ error: Error,
    retryAction: RepositoryKnowledgeRetryAction?
  ) -> RepositoryKnowledgeFailure {
    let kind: RepositoryKnowledgeFailureKind
    if error is PersistenceError {
      kind = .persistence
    } else if error is GitWorkspaceError || error is RepositoryAnalysisSnapshotError {
      kind = .staleRepository
    } else if error is RepositoryKnowledgeAnalysisError || error is CodexClientError {
      kind = .analysis
    } else {
      kind = .publication
    }
    return RepositoryKnowledgeFailure(
      kind: kind,
      message: error.localizedDescription,
      retryAction: retryAction
    )
  }

  private func repositoryInstructions(base: String, profile: AgentProfile) -> String {
    let custom = profile.customInstructionText
    guard !custom.isEmpty else { return base }
    return "\(base)\n\nTeam member instructions:\n\(custom)"
  }

  private static func makeClient(
    executableURL: URL,
    snapshotURL: URL
  ) -> CodexAppServerClient {
    let transport = CodexJSONLTransport(
      configuration: .init(
        executableURL: executableURL,
        arguments: CodexPermissionProfiles.repositoryAnalysisAppServerArguments(
          snapshotURL: snapshotURL
        ),
        currentDirectoryURL: snapshotURL,
        environmentOverrides: CodexPermissionProfiles.repositoryAnalysisProcessEnvironment,
        environmentMode: .replace,
        requestTimeout: .seconds(30)
      )
    )
    return CodexAppServerClient(transport: transport)
  }

  private static func defaultAnalysisRootURL() throws -> URL {
    let caches = try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return caches
      .appendingPathComponent("Spedito", isDirectory: true)
      .appendingPathComponent("Repository analysis", isDirectory: true)
  }
}
