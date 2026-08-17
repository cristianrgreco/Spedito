#if DEBUG
  import Darwin
  import Foundation
  import SpeditoCore

  @MainActor
  enum UIFixtureRuntime {
    private static let scenarioEnvironmentKey = "SPEDITO_UI_TEST_FIXTURE"
    private static let rootEnvironmentKey = "SPEDITO_UI_FIXTURE_ROOT"
    private static let signalEnvironmentKey = "SPEDITO_UI_FIXTURE_SIGNAL"

    private enum Scenario: String {
      case epicNeedsInput = "epic-needs-input"
      case a02 = "a02"
      case a05 = "a05"
      case a06 = "a06"
      case a07 = "a07"
      case b02 = "b02"
      case c07 = "c07"
      case d08 = "d08"
      case d09 = "d09"
      case d14 = "d14"
      case d15 = "d15"
      case d17 = "d17"
      case i07 = "i07"
      case p05 = "p05"
      case r05 = "r05"
      case r13 = "r13"
      case v06 = "v06"
    }

    private static var scenario: Scenario? {
      ProcessInfo.processInfo.environment[scenarioEnvironmentKey].flatMap(Scenario.init(rawValue:))
    }

    static var isEnabled: Bool {
      scenario != nil
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
    static func recordInteraction(_ name: String, value: String = "") {
      guard let rootURL = applicationSupportURL else { return }
      try? Data(value.utf8).write(to: rootURL.appendingPathComponent(name))
    }

    static var preservesPendingPermissionRequest: Bool {
      scenario == .d08
    }

    static func waitForAcceptanceReleaseIfNeeded(workItemID: UUID) async {
      guard scenario == .d17, let rootURL = applicationSupportURL else { return }
      recordInteraction("d17-acceptance-started-\(workItemID.uuidString)")
      await UIFixtureSignal.wait(
        for: rootURL.appendingPathComponent("d17-acceptance-release")
      )
    }

    static func transportFactoryOutput() -> CodexTransportFactoryOutput? {
      guard let scenario,
        scenario == .epicNeedsInput || scenario == .i07,
        let rootURL = applicationSupportURL
      else { return nil }
      let configuredSignalPath = ProcessInfo.processInfo.environment[signalEnvironmentKey]
      let releaseSignalURL =
        configuredSignalPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? rootURL.appendingPathComponent("i07-refinement-release")
      let turnStartedSignalName =
        scenario == .epicNeedsInput ? "epic-turn-started" : "i07-refinement-started"
      return CodexTransportFactoryOutput(
        descriptor: CodexRuntimeDescriptor(
          executableURL: URL(fileURLWithPath: "/private/tmp/spedito-ui-fixture-codex"),
          version: "ui-fixture",
          source: .custom
        ),
        transport: UIFixtureCodexTransport(
          releaseSignalURL: releaseSignalURL,
          turnStartedSignalURL: rootURL.appendingPathComponent(turnStartedSignalName)
        )
      )
    }

    static func prepare(registry: ProductStoreRegistry) async throws -> UUID? {
      guard let scenario, let rootURL = applicationSupportURL else { return nil }
      if let existingManifest = try? loadManifest(rootURL: rootURL) {
        return existingManifest.selectedProductID
      }

      var manifest: UIFixtureManifest
      switch scenario {
      case .epicNeedsInput:
        let first = try await registry.createProduct(name: "First product")
        let second = try await registry.createProduct(name: "Second product")
        manifest = UIFixtureManifest(
          selectedProductID: first.id,
          firstProductID: first.id,
          secondProductID: second.id
        )
      case .a02:
        let product = try await registry.createProduct(name: "A02 complete workspace")
        manifest = UIFixtureManifest(selectedProductID: product.id, firstProductID: product.id)
      case .a05:
        let product = try await registry.createProduct(name: "A05 restored workspace")
        let store = try requireStore(registry, productID: product.id)
        let seeded = try await seedSprint(
          store: store,
          product: product,
          title: "A05 restored ticket",
          active: true
        )
        _ = try await completeSeededRun(store: store, productID: product.id)
        UserDefaults.standard.set(
          WorkspaceDestination.sprint.rawValue,
          forKey: "workspaceDestination.\(product.id.uuidString)"
        )
        SprintBoardSelectionDefaults.select(seeded.sprintID, for: product.id)
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          workItemID: seeded.workItemID,
          sprintID: seeded.sprintID
        )
      case .a06:
        let archived = try await registry.createProduct(name: "A06 archived product")
        let remaining = try await registry.createProduct(name: "A06 remaining product")
        let archivedStore = try requireStore(registry, productID: archived.id)
        _ = try await archivedStore.archiveProduct(id: archived.id)
        manifest = UIFixtureManifest(
          selectedProductID: remaining.id,
          firstProductID: archived.id,
          secondProductID: remaining.id
        )
      case .a07:
        let archived = try await registry.createProduct(name: "A07 durable archive")
        let current = try await registry.createProduct(name: "A07 current product")
        let archivedStore = try requireStore(registry, productID: archived.id)
        _ = try await archivedStore.archiveProduct(id: archived.id)
        manifest = UIFixtureManifest(
          selectedProductID: current.id,
          firstProductID: archived.id,
          secondProductID: current.id
        )
      case .b02:
        let source = try await registry.createProduct(name: "B02 source product")
        let selected = try await registry.createProduct(name: "B02 selected product")
        let sourceStore = try requireStore(registry, productID: source.id)
        let item = try await sourceStore.createWorkItem(
          productID: source.id,
          title: "B02 exact attention ticket"
        )
        _ = try await sourceStore.appendComment(
          workItemID: item.id,
          authorKind: .agent,
          authorName: "Business analyst",
          body: "Choose the delivery boundary.",
          ownerQuestion: TicketOwnerQuestion(
            prompt: "Which delivery boundary should we keep?",
            options: ["Local only", "Publish remotely"]
          )
        )
        manifest = UIFixtureManifest(
          selectedProductID: selected.id,
          firstProductID: source.id,
          secondProductID: selected.id,
          workItemID: item.id
        )
      case .c07:
        let source = try await registry.createProduct(name: "C07 source product")
        let selected = try await registry.createProduct(name: "C07 selected product")
        let sourceStore = try requireStore(registry, productID: source.id)
        let profiles = try await sourceStore.seedDefaultProfiles(productID: source.id)
        guard let recipient = profiles.first else {
          throw UIFixtureError.missingFixtureState("C07 recipient profile")
        }
        let threadID = UUID()
        let thread = try await sourceStore.createConversationThread(
          ProductConversationThread(
            id: threadID,
            productID: source.id,
            recipientProfileID: recipient.id,
            subject: "C07 exact background thread",
            status: .complete
          ),
          initialMessage: ProductConversationMessage(
            threadID: threadID,
            authorKind: .owner,
            authorName: "Product owner",
            body: "Keep this reply scoped to its source product."
          )
        )
        let reply = ProductConversationMessage(
          threadID: thread.id,
          authorKind: .agent,
          authorName: recipient.name,
          body: "C07 background reply"
        )
        _ = try await sourceStore.appendConversationMessage(
          reply,
          threadStatus: .complete
        )
        manifest = UIFixtureManifest(
          selectedProductID: selected.id,
          firstProductID: source.id,
          secondProductID: selected.id,
          threadID: thread.id,
          messageID: reply.id
        )
      case .d08:
        let product = try await registry.createProduct(name: "D08 permissions")
        let store = try requireStore(registry, productID: product.id)
        let seeded = try await seedPermissionRequest(store: store, product: product)
        UserDefaults.standard.set(
          WorkspaceDestination.sprint.rawValue,
          forKey: "workspaceDestination.\(product.id.uuidString)"
        )
        SprintBoardSelectionDefaults.select(seeded.sprintID, for: product.id)
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          workItemID: seeded.workItemID,
          sprintID: seeded.sprintID,
          permissionRequestID: seeded.permissionRequestID
        )
      case .d09:
        let product = try await registry.createProduct(name: "D09 owner question")
        let store = try requireStore(registry, productID: product.id)
        let seeded = try await seedOwnerQuestion(store: store, product: product)
        UserDefaults.standard.set(
          WorkspaceDestination.sprint.rawValue,
          forKey: "workspaceDestination.\(product.id.uuidString)"
        )
        SprintBoardSelectionDefaults.select(seeded.sprintID, for: product.id)
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          workItemID: seeded.workItemID,
          sprintID: seeded.sprintID
        )
      case .d14, .v06:
        let product = try await registry.createProduct(
          name: scenario == .d14 ? "D14 reviewed demo" : "V06 App versions"
        )
        let store = try requireStore(registry, productID: product.id)
        let repositorySHA = try await ensureProductRepository(
          registry: registry,
          productID: product.id
        )
        let seeded = try await seedAcceptedAppVersions(
          store: store,
          product: product,
          repositorySHA: repositorySHA
        )
        UserDefaults.standard.set(
          WorkspaceDestination.app.rawValue,
          forKey: "workspaceDestination.\(product.id.uuidString)"
        )
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          workItemID: seeded.workItemID,
          candidateRevisionIDs: seeded.candidateRevisionIDs
        )
      case .d15, .d17:
        let isD17 = scenario == .d17
        let product = try await registry.createProduct(
          name: isD17 ? "D17 completing ticket" : "D15 reviewed demo comment"
        )
        let store = try requireStore(registry, productID: product.id)
        let repositorySHA = try await ensureProductRepository(
          registry: registry,
          productID: product.id
        )
        let seeded = try await seedReadyForDemoCandidate(
          store: store,
          product: product,
          repositorySHA: repositorySHA,
          title: isD17 ? "D17 promote reviewed change" : "D15 keep the reviewed demo",
          fixtureSlug: isD17 ? "d17" : "d15"
        )
        UserDefaults.standard.set(
          WorkspaceDestination.sprint.rawValue,
          forKey: "workspaceDestination.\(product.id.uuidString)"
        )
        SprintBoardSelectionDefaults.select(seeded.sprintID, for: product.id)
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          workItemID: seeded.workItemID,
          sprintID: seeded.sprintID,
          candidateRevisionIDs: [seeded.candidateRevisionID]
        )
      case .i07:
        let product = try await registry.createProduct(name: "I07 retrospective refinement")
        let store = try requireStore(registry, productID: product.id)
        let seeded = try await seedRetrospectiveBacklogAction(
          store: store,
          product: product
        )
        UserDefaults.standard.set(
          WorkspaceDestination.retrospectives.rawValue,
          forKey: "workspaceDestination.\(product.id.uuidString)"
        )
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          sprintID: seeded.sprintID,
          retrospectiveNoteID: seeded.noteID,
          sourceWorkItemID: seeded.sourceWorkItemID
        )
      case .p05:
        let product = try await registry.createProduct(name: "P05 blocked sprint")
        let store = try requireStore(registry, productID: product.id)
        let profiles = try await store.seedDefaultProfiles(productID: product.id)
        let implementer = profiles.first(where: { $0.role == .implementer })
        let blocker = try await readyItem(
          store: store,
          productID: product.id,
          title: "P05 prerequisite outside sprint"
        )
        let createdItem = try await store.createWorkItem(
          productID: product.id,
          title: "P05 missing estimate",
          acceptanceCriteria: ["The invalid plan remains blocked."],
          dependsOnWorkItemIDs: Set([blocker.id])
        )
        _ = try await store.transitionWorkItem(
          id: createdItem.id,
          to: .refining,
          actor: "Business analyst",
          reason: "Fixture refinement"
        )
        let item = try await store.transitionWorkItem(
          id: createdItem.id,
          to: .ready,
          actor: "Product owner",
          reason: "Fixture ready"
        )
        let draft = try await store.saveDraftSprint(
          productID: product.id,
          goal: "Do not start invalid work",
          tokenBudgetLimit: nil,
          items: [
            SprintDraftItemInput(
              workItemID: item.id,
              implementerProfileID: implementer?.id
            )
          ]
        )
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          workItemID: item.id,
          sprintID: draft.sprint.id
        )
      case .r05:
        let product = try await registry.createProduct(name: "R05 connected blank product")
        manifest = UIFixtureManifest(selectedProductID: product.id, firstProductID: product.id)
      case .r13:
        let product = try await registry.createProduct(name: "R13 incoming changes")
        UserDefaults.standard.set(
          WorkspaceDestination.sprint.rawValue,
          forKey: "workspaceDestination.\(product.id.uuidString)"
        )
        manifest = UIFixtureManifest(
          selectedProductID: product.id,
          firstProductID: product.id,
          remoteSafeSyncID: Self.remoteSafeSyncID
        )
      }

      try await ensureProductRepositories(registry: registry, manifest: manifest)
      try writeManifest(manifest, rootURL: rootURL)
      return manifest.selectedProductID
    }

    private static func requireStore(
      _ registry: ProductStoreRegistry,
      productID: UUID
    ) throws -> SQLiteStore {
      guard let store = registry.store(for: productID) else {
        throw UIFixtureError.missingFixtureState("Product store")
      }
      return store
    }

    private static func readyItem(
      store: SQLiteStore,
      productID: UUID,
      title: String
    ) async throws -> WorkItem {
      let item = try await store.createWorkItem(
        productID: productID,
        title: title,
        acceptanceCriteria: ["The fixture outcome is observable."]
      )
      _ = try await store.transitionWorkItem(
        id: item.id,
        to: .refining,
        actor: "Business analyst",
        reason: "Fixture refinement"
      )
      return try await store.transitionWorkItem(
        id: item.id,
        to: .ready,
        actor: "Product owner",
        reason: "Fixture ready"
      )
    }

    private static func seedSprint(
      store: SQLiteStore,
      product: Product,
      title: String,
      active: Bool
    ) async throws -> (workItemID: UUID, sprintID: UUID, sprintItemID: UUID) {
      let profiles = try await store.seedDefaultProfiles(productID: product.id)
      let implementer = profiles.first(where: { $0.role == .implementer })
      let item = try await readyItem(store: store, productID: product.id, title: title)
      let draft = try await store.saveDraftSprint(
        productID: product.id,
        goal: "Fixture sprint",
        tokenBudgetLimit: nil,
        items: [
          SprintDraftItemInput(
            workItemID: item.id,
            implementerProfileID: implementer?.id,
            estimatedTokens: 1
          )
        ]
      )
      if active {
        _ = try await store.startSprint(id: draft.sprint.id)
      }
      return (item.id, draft.sprint.id, draft.items[0].id)
    }
    private static func completeSeededRun(
      store: SQLiteStore,
      productID: UUID
    ) async throws -> AgentRun {
      guard let run = try await store.fetchAgentRuns(productID: productID).first else {
        throw UIFixtureError.missingFixtureState("Fixture AgentRun")
      }
      return try await store.updateAgentRun(
        id: run.id,
        status: .completed,
        eventActor: "Spedito",
        eventDetail: "Fixture delivery completed"
      )
    }


    private static func seedPermissionRequest(
      store: SQLiteStore,
      product: Product
    ) async throws -> (workItemID: UUID, sprintID: UUID, permissionRequestID: UUID) {
      let seeded = try await seedSprint(
        store: store,
        product: product,
        title: "Review one exact capability",
        active: true
      )
      guard var run = try await store.fetchAgentRuns(productID: product.id).first else {
        throw UIFixtureError.missingFixtureState("Permission AgentRun")
      }
      run = try await store.updateAgentRun(id: run.id, status: .awaitingOwner)
      let request = try await store.saveAgentPermissionRequest(
        AgentPermissionRequest(
          productID: product.id,
          workItemID: seeded.workItemID,
          agentRunID: run.id,
          threadID: "thread-ui-permission",
          turnID: "turn-ui-permission",
          serverRequestID: "request-ui-permission",
          method: "item/commandExecution/requestApproval",
          kind: .command,
          title: "Allow this command?",
          detail: "/usr/bin/swift test",
          signature: "command|swift-test",
          productGrantSignature: "product-command|swift-test"
        )
      )
      return (seeded.workItemID, seeded.sprintID, request.id)
    }

    private static func seedOwnerQuestion(
      store: SQLiteStore,
      product: Product
    ) async throws -> (workItemID: UUID, sprintID: UUID) {
      let seeded = try await seedSprint(
        store: store,
        product: product,
        title: "Answer one exact owner question",
        active: true
      )
      let profiles = try await store.fetchAgentProfiles(productID: product.id)
      guard
        let implementer = profiles.first(where: { $0.role == .implementer }),
        let run = try await store.fetchAgentRuns(productID: product.id).first
      else {
        throw UIFixtureError.missingFixtureState("Owner-question AgentRun")
      }
      _ = try await store.transitionWorkItem(
        id: seeded.workItemID,
        to: .running,
        actor: implementer.name,
        reason: "Fixture delivery"
      )
      _ = try await store.updateAgentRun(
        id: run.id,
        status: .awaitingOwner,
        codexThreadID: "thread-ui-owner-question",
        eventActor: implementer.name,
        eventDetail: "Waiting for one product decision"
      )
      _ = try await store.appendComment(
        workItemID: seeded.workItemID,
        authorKind: .agent,
        authorName: implementer.name,
        body: "Choose the release channel.",
        ownerQuestion: TicketOwnerQuestion(
          prompt: "Which release channel should this ticket use?",
          options: ["Stable", "Preview"]
        )
      )
      return (seeded.workItemID, seeded.sprintID)
    }

    private static func seedReadyForDemoCandidate(
      store: SQLiteStore,
      product: Product,
      repositorySHA: String,
      title: String,
      fixtureSlug: String
    ) async throws -> (
      workItemID: UUID,
      sprintID: UUID,
      candidateRevisionID: UUID
    ) {
      let seeded = try await seedSprint(
        store: store,
        product: product,
        title: title,
        active: true
      )
      let run = try await completeSeededRun(store: store, productID: product.id)
      let profiles = try await store.fetchAgentProfiles(productID: product.id)
      guard
        let implementer = profiles.first(where: { $0.role == .implementer }),
        let reviewer = profiles.first(where: { $0.role == .lead }),
        var item = try await store.fetchWorkItems(productID: product.id).first(where: {
          $0.id == seeded.workItemID
        })
      else {
        throw UIFixtureError.missingFixtureState("Reviewed candidate")
      }
      item = try await store.transitionWorkItem(
        id: item.id,
        to: .running,
        actor: implementer.name,
        reason: "Fixture implementation"
      )
      item = try await store.transitionWorkItem(
        id: item.id,
        to: .integrating,
        actor: implementer.name,
        reason: "Fixture integration"
      )
      item = try await store.transitionWorkItem(
        id: item.id,
        to: .verifying,
        actor: reviewer.name,
        reason: "Fixture review"
      )
      item = try await store.transitionWorkItem(
        id: item.id,
        to: .acceptance,
        actor: reviewer.name,
        reason: "Fixture ready for demo"
      )
      let result = TicketExecutionResult(
        status: .completed,
        comment: "The reviewed demo is ready.",
        question: nil,
        options: [],
        summary: "The reviewed demo remains valid while the owner comments.",
        changedFiles: ["Sources/Demo.swift"],
        tests: ["Fixture review"],
        knowledgeNotes: [],
        reviewInstructions: ["Review the exact candidate."],
        retrospectiveWentWell: [],
        retrospectiveCouldImprove: [],
        retrospectiveActions: []
      )
      let candidate = CandidateRevision(
        productID: product.id,
        sprintID: seeded.sprintID,
        sprintItemID: seeded.sprintItemID,
        workItemID: item.id,
        implementationRunID: run.id,
        version: 1,
        branchName: "ticket/\(item.key)",
        baseSHA: repositorySHA,
        headSHA: repositorySHA,
        integratedSHA: repositorySHA,
        worktreePath: "/private/tmp/spedito-ui-\(fixtureSlug)-ticket",
        integrationWorktreePath: "/private/tmp/spedito-ui-\(fixtureSlug)-integration",
        status: .readyForDemo,
        commitCount: 1,
        executionResultJSON: String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
      )
      _ = try await store.createCandidateRevision(candidate)
      _ = try await store.appendComment(
        workItemID: item.id,
        authorKind: .agent,
        authorName: reviewer.name,
        body: "The exact candidate is reviewed and ready for demo."
      )
      return (item.id, seeded.sprintID, candidate.id)
    }

    private static func seedRetrospectiveBacklogAction(
      store: SQLiteStore,
      product: Product
    ) async throws -> (sprintID: UUID, noteID: UUID, sourceWorkItemID: UUID) {
      let seeded = try await seedSprint(
        store: store,
        product: product,
        title: "I07 completed delivery",
        active: true
      )
      _ = try await completeSeededRun(store: store, productID: product.id)
      let profiles = try await store.fetchAgentProfiles(productID: product.id)
      guard
        let implementer = profiles.first(where: { $0.role == .implementer }),
        let analyst = profiles.first(where: { $0.role == .businessAnalyst })
      else {
        throw UIFixtureError.missingFixtureState("I07 retrospective profiles")
      }
      for state in [
        WorkItemState.running,
        .integrating,
        .verifying,
        .acceptance,
        .readyToRelease,
        .released,
      ] {
        _ = try await store.transitionWorkItem(
          id: seeded.workItemID,
          to: state,
          actor: implementer.name,
          reason: "Complete I07 source delivery"
        )
      }
      _ = try await store.completeSprintIfFinished(id: seeded.sprintID)
      guard
        let synthesis = try await store.fetchRetrospectiveSyntheses(productID: product.id)
          .first(where: { $0.sprintID == seeded.sprintID })
      else {
        throw UIFixtureError.missingFixtureState("I07 retrospective synthesis")
      }
      _ = try await store.skipRetrospectiveSynthesis(id: synthesis.id)
      let note = RetrospectiveNote(
        productID: product.id,
        sprintID: seeded.sprintID,
        workItemID: seeded.workItemID,
        profileID: analyst.id,
        authorName: analyst.name,
        category: .suggestedAction,
        body: "I07 refine the accepted retrospective ticket",
        isActionCandidate: false,
        actionStatus: .proposed,
        actionDestination: .backlog,
        expectedEffect: "The exact action enters normal backlog refinement.",
        synthesisID: synthesis.id
      )
      try await store.saveRetrospectiveNotes([note])
      return (seeded.sprintID, note.id, seeded.workItemID)
    }

    private static func seedAcceptedAppVersions(
      store: SQLiteStore,
      product: Product,
      repositorySHA: String
    ) async throws -> (workItemID: UUID, candidateRevisionIDs: [UUID]) {
      let seeded = try await seedSprint(
        store: store,
        product: product,
        title: "Deliver reviewed App versions",
        active: true
      )
      let run = try await completeSeededRun(store: store, productID: product.id)
      let demo = DemoLaunchSpecification(
        title: "Accepted macOS app",
        presentation: DemoPresentation(kind: .macApplication, path: ".build/UIFixture.app")
      )
      let result = TicketExecutionResult(
        status: .completed,
        comment: "Accepted App version.",
        question: nil,
        options: [],
        summary: "The reviewed App is ready.",
        changedFiles: ["Sources/App.swift"],
        tests: ["swift test"],
        knowledgeNotes: [],
        reviewInstructions: ["Open the accepted native preview."],
        demo: demo,
        retrospectiveWentWell: [],
        retrospectiveCouldImprove: [],
        retrospectiveActions: []
      )
      let resultJSON = String(
        decoding: try JSONEncoder().encode(result),
        as: UTF8.self
      )
      var candidateIDs: [UUID] = []
      for version in 1...2 {
        let candidate = CandidateRevision(
          productID: product.id,
          sprintID: seeded.sprintID,
          sprintItemID: seeded.sprintItemID,
          workItemID: seeded.workItemID,
          implementationRunID: run.id,
          version: version,
          branchName: "ticket/UI-\(version)",
          baseSHA: repositorySHA,
          headSHA: repositorySHA,
          integratedSHA: repositorySHA,
          worktreePath: "/private/tmp/spedito-ui-ticket-\(version)",
          integrationWorktreePath: "/private/tmp/spedito-ui-version-\(version)",
          status: .accepted,
          commitCount: 1,
          executionResultJSON: resultJSON,
          createdAt: Date(timeIntervalSince1970: TimeInterval(version)),
          updatedAt: Date(timeIntervalSince1970: TimeInterval(version))
        )
        _ = try await store.createCandidateRevision(candidate)
        candidateIDs.append(candidate.id)
      }
      return (seeded.workItemID, candidateIDs)
    }

    fileprivate static let remoteSafeSyncID = UUID(
      uuidString: "00000000-0000-0000-0000-000000000013"
    )!

    private static func ensureProductRepository(
      registry: ProductStoreRegistry,
      productID: UUID
    ) async throws -> String {
      let workspaceURL = registry.productWorkspacesRootURL.appendingPathComponent(
        productID.uuidString,
        isDirectory: true
      )
      return try await GitWorkspaceManager().ensureRepository(at: workspaceURL)
    }

    private static func ensureProductRepositories(
      registry: ProductStoreRegistry,
      manifest: UIFixtureManifest
    ) async throws {
      let productIDs = Set(
        [manifest.selectedProductID, manifest.firstProductID]
          + [manifest.secondProductID].compactMap { $0 }
      )
      let gitWorkspaceManager = GitWorkspaceManager()
      for productID in productIDs {
        let workspaceURL = registry.productWorkspacesRootURL.appendingPathComponent(
          productID.uuidString,
          isDirectory: true
        )
        _ = try await gitWorkspaceManager.ensureRepository(at: workspaceURL)
      }
    }

    private static func writeManifest(_ manifest: UIFixtureManifest, rootURL: URL) throws {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true
      )
      try JSONEncoder().encode(manifest).write(
        to: rootURL.appendingPathComponent("fixture-manifest.json"),
        options: .atomic
      )
    }

    private static func loadManifest(rootURL: URL) throws -> UIFixtureManifest {
      try JSONDecoder().decode(
        UIFixtureManifest.self,
        from: Data(contentsOf: rootURL.appendingPathComponent("fixture-manifest.json"))
      )
    }
  }

  private struct UIFixtureManifest: Codable {
    let selectedProductID: UUID
    let firstProductID: UUID
    var secondProductID: UUID?
    var workItemID: UUID?
    var sprintID: UUID?
    var threadID: UUID?
    var messageID: UUID?
    var permissionRequestID: UUID?
    var candidateRevisionIDs: [UUID] = []
    var remoteSafeSyncID: UUID?
    var retrospectiveNoteID: UUID?
    var sourceWorkItemID: UUID?
  }

  private enum UIFixtureError: Error {
    case missingFixtureState(String)
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
    private func fixtureState(productID: UUID) -> GitHubRemoteRepositoryState {
      let scenario = ProcessInfo.processInfo.environment["SPEDITO_UI_TEST_FIXTURE"]
      guard scenario == "r05" || scenario == "r13" else {
        return GitHubRemoteRepositoryState(isConfigured: false)
      }
      let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
      let sha = String(repeating: "a", count: 40)
      let remoteSHA = scenario == "r13" ? String(repeating: "b", count: 40) : sha
      let connection = RemoteRepositoryConnection(
        id: connectionID,
        productID: productID,
        kind: .localEmptyRepository,
        installationID: 5,
        repositoryID: 55,
        owner: "spedito-fixture",
        name: "owner-journey",
        fullName: "spedito-fixture/owner-journey",
        canonicalHTTPSURL: URL(string: "https://github.com/spedito-fixture/owner-journey.git"),
        isPrivate: true,
        defaultBranch: "main",
        permissions: RemoteRepositoryPermissions(
          metadataRead: true,
          contentsWrite: true,
          pullRequestsWrite: true,
          workflowsWrite: true
        ),
        status: .connected,
        latestLocalSHA: sha,
        latestLocalTree: sha,
        latestRemoteSHA: remoteSHA,
        latestRemoteTree: remoteSHA,
        latestRelationship: scenario == "r13" ? .remoteAhead : .aligned,
        latestAheadCount: 0,
        latestBehindCount: scenario == "r13" ? 1 : 0,
        latestCheckedAt: Date(),
        initializationAttemptCount: 1,
        seededSHA: sha,
        originVerified: true
      )
      guard scenario == "r13" else {
        return GitHubRemoteRepositoryState(isConfigured: true, connection: connection)
      }
      let observation = RemoteRepositoryObservation(
        connectionVersion: connection.version,
        repositoryID: 55,
        fullName: "spedito-fixture/owner-journey",
        canonicalHTTPSURL: URL(string: "https://github.com/spedito-fixture/owner-journey.git")!,
        isPrivate: true,
        defaultBranch: "main",
        localSHA: sha,
        localTree: sha,
        remoteSHA: remoteSHA,
        remoteTree: remoteSHA,
        mergeBaseSHA: sha,
        aheadCount: 0,
        behindCount: 1,
        relationship: .remoteAhead,
        observationRef: "refs/spedito/ui-r13",
        commits: [RemoteCommitSummary(sha: remoteSHA, subject: "Incoming owner journey")],
        paths: ["Sources/Incoming.swift"]
      )
      let sync = RemoteSafeSync(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
        productID: productID,
        connectionID: connectionID,
        connectionVersion: connection.version,
        kind: .fastForward,
        observationRef: observation.observationRef,
        localSHA: sha,
        localTree: sha,
        remoteSHA: remoteSHA,
        remoteTree: remoteSHA,
        mergeBaseSHA: sha,
        candidateSHA: remoteSHA,
        candidateTree: remoteSHA,
        commits: observation.commits,
        paths: observation.paths
      )
      return GitHubRemoteRepositoryState(
        isConfigured: true,
        connection: connection,
        observation: observation,
        safeSync: sync
      )
    }

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

    func state(productID: UUID) async -> GitHubRemoteRepositoryState {
      fixtureState(productID: productID)
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

    func refreshRepositories(productID: UUID) async throws -> GitHubRemoteRepositoryState {
      fixtureState(productID: productID)
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

    func check(productID: UUID) async throws -> GitHubRemoteRepositoryState {
      fixtureState(productID: productID)
    }

    func prepareTicketIntegration(
      productID _: UUID
    ) async throws -> GitHubTicketIntegrationPreparation {
      throw GitHubRemoteRepositoryServiceError.notConfigured
    }
    func prepareSafeSync(productID: UUID) async throws -> GitHubRemoteRepositoryState {
      fixtureState(productID: productID)
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
