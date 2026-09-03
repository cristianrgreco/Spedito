import Foundation
import SpeditoCore
import Testing

/// Ordinary-suite coverage for eval harness pieces with observable contracts
/// of their own; these tests never talk to Codex.
@Suite("Eval judge image attachments")
struct EvalJudgeImageAttachmentTests {
  @Test("Collects changed images bounded by count and size, naming every drop")
  func collectsBoundedImages() throws {
    let workspace = try EvalFixtureWorkspace.make()
    defer { workspace.remove() }
    let repository = try workspace.makeRepository(
      name: "image-attachments",
      files: ["README.md": "fixture"]
    )
    let baseSHA = try repository.headSHA()

    let smallImage = String(repeating: "x", count: 10)
    let oversizedImage = String(
      repeating: "y",
      count: EvalJudgeImageAttachments.maximumFileBytes + 1
    )
    try repository.write(files: [
      "design/a.png": smallImage,
      "design/b.jpg": smallImage,
      "design/c.jpeg": smallImage,
      "design/d.webp": smallImage,
      "design/e.gif": smallImage,
      "design/too-big.png": oversizedImage,
      "design/notes.md": "not an image",
      "prototype/index.html": "<p>markup</p>",
    ])

    let result = EvalJudgeImageAttachments.collect(
      worktreeURL: repository.rootURL,
      baseSHA: baseSHA
    )

    #expect(result.attached.count == EvalJudgeImageAttachments.maximumFileCount)
    for fileURL in result.attached {
      #expect(
        EvalJudgeImageAttachments.imageExtensions.contains(
          fileURL.pathExtension.lowercased()
        )
      )
    }
    // One image beyond the file bound and one over the size bound: both drops
    // are named, and non-image files are never candidates.
    #expect(result.dropped.count == 2)
    #expect(result.dropped.contains { $0.contains("too-big.png") })
    #expect(!result.dropped.contains { $0.contains("notes.md") })
    #expect(!result.attached.contains { $0.lastPathComponent == "index.html" })
  }

  @Test("A worktree without image work attaches nothing")
  func attachesNothingWithoutImages() throws {
    let workspace = try EvalFixtureWorkspace.make()
    defer { workspace.remove() }
    let repository = try workspace.makeRepository(
      name: "no-images",
      files: ["README.md": "fixture"]
    )
    let baseSHA = try repository.headSHA()
    try repository.write(files: ["prototype/index.html": "<p>markup</p>"])

    let result = EvalJudgeImageAttachments.collect(
      worktreeURL: repository.rootURL,
      baseSHA: baseSHA
    )

    #expect(result.attached.isEmpty)
    #expect(result.dropped.isEmpty)
  }
}

/// Hand-built drafts proving every structural epic-plan check with a passing
/// and a failing fixture. The production decoder rejects some of these shapes
/// before a check would ever see them live; the checks still assert them so a
/// decoder loosening cannot silently drop the property.
@Suite("Epic plan structural checks")
struct EvalEpicPlanCheckTests {
  private func ticket(
    _ reference: String,
    title: String,
    type: WorkItemType = .story,
    body: String = "A concrete outcome the owner asked for.",
    criteria: [String] = ["The agreed outcome is visible and verified"],
    role: AgentRole = .implementer,
    dependsOn: [String] = [],
    dependsOnExisting: [String] = [],
    environment: TicketEnvironmentRelationship = .independent
  ) -> TicketSuggestionDraft {
    TicketSuggestionDraft(
      reference: reference,
      title: title,
      type: type,
      body: body,
      acceptanceCriteria: criteria,
      suggestedRole: role,
      priority: .normal,
      rationale: "fixture",
      dependsOnReferences: dependsOn,
      dependsOnExistingWorkItemKeys: dependsOnExisting,
      environmentRelationship: environment
    )
  }

  private func plan(_ suggestions: [TicketSuggestionDraft]) -> EpicPlanDraft {
    EpicPlanDraft(
      title: "Fixture epic",
      goal: "A hand-built plan for check fixtures",
      successCriteria: ["The fixture outcome is achieved"],
      constraints: "",
      environmentAssessment: EpicEnvironmentAssessment(
        readiness: .sufficient,
        rationale: "fixture"
      ),
      ticketSuggestions: suggestions
    )
  }

  /// The canonical cat-joke shape from the contributor instructions: research
  /// and design in parallel, implementation depending on both, verification
  /// last. Every structural check passes on it.
  private var canonicalPlan: EpicPlanDraft {
    plan([
      ticket(
        "S1",
        title: "Recommend a suitable content provider",
        type: .task,
        role: .businessAnalyst
      ),
      ticket(
        "S2",
        title: "Design the result and unavailable states",
        type: .task,
        role: .uxDesigner
      ),
      ticket(
        "S3",
        title: "Integrate the approved provider",
        criteria: ["The provider recommended by S1 supplies the shown content"],
        dependsOn: ["S1", "S2"]
      ),
      ticket(
        "S4",
        title: "Verify successful and unavailable behaviour",
        type: .task,
        role: .qualityAssurance,
        dependsOn: ["S3"]
      ),
    ])
  }

  @Test("The canonical parallel plan passes every structural check")
  func canonicalPlanPassesEverything() {
    let checks = EvalEpicPlanChecks.structuralChecks(
      canonicalPlan,
      existingItems: [],
      expectedTicketCountRange: 2...5
    )
    for check in checks {
      #expect(check.passed, "\(check.name): \(check.detail)")
    }
  }

  @Test("Setup and story tickets plan the product surface; design and research plan artifacts")
  func plannedDemoKindMatchesProductSurface() {
    func draft(
      _ reference: String,
      type: WorkItemType = .story,
      role: AgentRole = .implementer,
      environment: TicketEnvironmentRelationship = .independent,
      demoKind: TicketDemoKind?
    ) -> TicketSuggestionDraft {
      TicketSuggestionDraft(
        reference: reference,
        title: "Ticket \(reference)",
        type: type,
        body: "A concrete outcome the owner asked for.",
        acceptanceCriteria: ["The agreed outcome is visible and verified"],
        suggestedRole: role,
        priority: .normal,
        rationale: "fixture",
        dependsOnReferences: [],
        dependsOnExistingWorkItemKeys: [],
        environmentRelationship: environment,
        demoKind: demoKind
      )
    }
    let surfaces: [TicketDemoKind] = [
      .macApplication, .browser, .terminalApplication, .commandOutput,
    ]
    for surface in surfaces {
      let other = surfaces.first { $0 != surface }!
      let passing = plan([
        draft("S1", type: .task, environment: .establishes, demoKind: surface),
        draft("S2", type: .task, role: .uxDesigner, demoKind: .staticWeb),
        draft("S3", type: .task, role: .businessAnalyst, demoKind: .artifact),
        draft("S4", environment: .requires, demoKind: surface),
        draft("S5", type: .task, role: .qualityAssurance, demoKind: .codeOnly),
      ])
      let pass = EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
        passing,
        productSurface: surface
      )
      #expect(pass.passed, "\(surface.rawValue): \(pass.detail)")

      let wrongStory = EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
        plan([
          draft("S1", type: .task, environment: .establishes, demoKind: surface),
          draft("S2", environment: .requires, demoKind: other),
        ]),
        productSurface: surface
      )
      #expect(!wrongStory.passed)
      #expect(wrongStory.detail.contains("S2"))
      #expect(wrongStory.detail.contains(surface.rawValue))

      let wrongSetup = EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
        plan([draft("S1", type: .task, environment: .establishes, demoKind: other)]),
        productSurface: surface
      )
      #expect(!wrongSetup.passed)

      let designAsSurface = EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
        plan([
          draft("S1", environment: .requires, demoKind: surface),
          draft("S2", type: .task, role: .uxDesigner, demoKind: surface),
        ]),
        productSurface: surface
      )
      #expect(!designAsSurface.passed)
      #expect(designAsSurface.detail.contains("S2"))

      // A PDF screen set for ordinary design work is the quality failure the
      // rule exists to stop; a document-first outcome may still be a file.
      let designAsArtifact = EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
        plan([draft("S1", type: .task, role: .uxDesigner, demoKind: .artifact)]),
        productSurface: surface
      )
      #expect(!designAsArtifact.passed)
      #expect(designAsArtifact.detail.contains("static_web"))
      var audit = draft("S1", type: .task, role: .uxDesigner, demoKind: .artifact)
      audit = TicketSuggestionDraft(
        reference: audit.reference,
        title: "Audit the accessibility of the forecast screens",
        type: audit.type,
        body: audit.body,
        acceptanceCriteria: audit.acceptanceCriteria,
        suggestedRole: audit.suggestedRole,
        priority: audit.priority,
        rationale: audit.rationale,
        environmentRelationship: audit.environmentRelationship,
        demoKind: .artifact
      )
      #expect(
        EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
          plan([audit]),
          productSurface: surface
        ).passed
      )
      let researchAsScreenSet = EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
        plan([draft("S1", type: .task, role: .businessAnalyst, demoKind: .staticWeb)]),
        productSurface: surface
      )
      #expect(!researchAsScreenSet.passed)

      let missing = EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface(
        plan([draft("S1", demoKind: nil)]),
        productSurface: surface
      )
      #expect(!missing.passed)
      #expect(missing.detail.contains("no demo kind"))
    }
  }

  @Test("Ticket counts outside the cell's expected shape fail")
  func ticketCountShape() {
    let sixTickets = plan(
      (1...6).map { ticket("S\($0)", title: "Distinct outcome number \($0)") }
    )
    #expect(
      !EvalEpicPlanChecks.ticketCountWithinExpectedShape(sixTickets, expectedRange: 2...5).passed
    )
    #expect(
      EvalEpicPlanChecks.ticketCountWithinExpectedShape(canonicalPlan, expectedRange: 2...5).passed
    )
    let single = plan([ticket("S1", title: "One small change")])
    #expect(
      !EvalEpicPlanChecks.ticketCountWithinExpectedShape(single, expectedRange: 2...5).passed
    )
    #expect(
      EvalEpicPlanChecks.ticketCountWithinExpectedShape(single, expectedRange: 1...3).passed
    )
  }

  @Test("A ticket with more criteria than the bound is an overloaded mega-ticket")
  func overloadedScope() {
    let bound = EvalEpicPlanChecks.acceptanceCriteriaBound
    let atBound = plan([
      ticket(
        "S1",
        title: "A rich but coherent outcome",
        criteria: (1...bound).map { "Observable behaviour \($0) is verified" }
      )
    ])
    #expect(EvalEpicPlanChecks.ticketScopeNotOverloaded(atBound).passed)
    let overloaded = plan([
      ticket(
        "S1",
        title: "Everything at once",
        criteria: (1...(bound + 1)).map { "Observable behaviour \($0) is verified" }
      )
    ])
    let check = EvalEpicPlanChecks.ticketScopeNotOverloaded(overloaded)
    #expect(!check.passed)
    #expect(check.detail.contains("S1"))
  }

  @Test("Duplicate titles and bare role labels fail title distinctness")
  func titleDistinctness() {
    let duplicated = plan([
      ticket("S1", title: "Show the forecast"),
      ticket("S2", title: "Show the forecast "),
    ])
    let duplicateCheck = EvalEpicPlanChecks.titlesAreDistinctOutcomes(duplicated)
    #expect(!duplicateCheck.passed)
    #expect(duplicateCheck.detail.contains("S1"))
    #expect(duplicateCheck.detail.contains("S2"))

    let bareLabel = plan([
      ticket("S1", title: "Design", role: .uxDesigner),
      ticket("S2", title: "Show the forecast"),
    ])
    let bareCheck = EvalEpicPlanChecks.titlesAreDistinctOutcomes(bareLabel)
    #expect(!bareCheck.passed)
    #expect(bareCheck.detail.contains("bare role label"))

    #expect(EvalEpicPlanChecks.titlesAreDistinctOutcomes(canonicalPlan).passed)
  }

  @Test("Dangling references, self-dependencies, and cycles fail the graph check")
  func graphResolution() {
    let dangling = plan([
      ticket("S1", title: "Show the forecast", dependsOn: ["S9"])
    ])
    let danglingCheck = EvalEpicPlanChecks.dependenciesResolveAndAreAcyclic(
      dangling,
      existingItems: []
    )
    #expect(!danglingCheck.passed)
    #expect(danglingCheck.detail.contains("S9"))

    let selfDependent = plan([
      ticket("S1", title: "Show the forecast", dependsOn: ["S1"])
    ])
    #expect(
      !EvalEpicPlanChecks.dependenciesResolveAndAreAcyclic(selfDependent, existingItems: [])
        .passed
    )

    let cyclic = plan([
      ticket("S1", title: "Show the forecast", dependsOn: ["S2"]),
      ticket("S2", title: "Save the location", dependsOn: ["S1"]),
    ])
    let cycleCheck = EvalEpicPlanChecks.dependenciesResolveAndAreAcyclic(
      cyclic,
      existingItems: []
    )
    #expect(!cycleCheck.passed)
    #expect(cycleCheck.detail.contains("cycle"))
  }

  @Test("Dependencies on retired backlog tickets fail unless the cell marks them legitimate")
  func retiredBacklogDependencies() {
    let productID = UUID()
    let released = WorkItem(
      productID: productID,
      key: "T1",
      title: "Establish the delivery environment",
      state: .released
    )
    let active = WorkItem(
      productID: productID,
      key: "T2",
      title: "Create and save an invoice",
      state: .ready
    )
    let dependsOnReleased = plan([
      ticket("S1", title: "Show the forecast", dependsOnExisting: ["T1"])
    ])
    let releasedCheck = EvalEpicPlanChecks.dependenciesResolveAndAreAcyclic(
      dependsOnReleased,
      existingItems: [released, active]
    )
    #expect(!releasedCheck.passed)
    #expect(releasedCheck.detail.contains("released"))
    #expect(
      EvalEpicPlanChecks.dependenciesResolveAndAreAcyclic(
        dependsOnReleased,
        existingItems: [released, active],
        legitimateExistingDependencyKeys: ["T1"]
      ).passed
    )

    let dependsOnActive = plan([
      ticket("S1", title: "Show the forecast", dependsOnExisting: ["T2"])
    ])
    #expect(
      EvalEpicPlanChecks.dependenciesResolveAndAreAcyclic(
        dependsOnActive,
        existingItems: [released, active]
      ).passed
    )

    let dependsOnUnknown = plan([
      ticket("S1", title: "Show the forecast", dependsOnExisting: ["T9"])
    ])
    #expect(
      !EvalEpicPlanChecks.dependenciesResolveAndAreAcyclic(
        dependsOnUnknown,
        existingItems: [released, active]
      ).passed
    )
  }

  @Test("An explicit edge already implied through another dependency is redundant")
  func redundantTransitiveEdges() {
    let redundant = plan([
      ticket("S1", title: "Recommend a provider", type: .task, role: .businessAnalyst),
      ticket("S2", title: "Integrate the provider", dependsOn: ["S1"]),
      ticket("S3", title: "Verify the behaviour", dependsOn: ["S1", "S2"]),
    ])
    let check = EvalEpicPlanChecks.noRedundantTransitiveEdges(redundant)
    #expect(!check.passed)
    #expect(check.detail.contains("S3 → S1"))
    #expect(EvalEpicPlanChecks.noRedundantTransitiveEdges(canonicalPlan).passed)
  }

  @Test("A verification proposal must follow the implementation it verifies")
  func verificationPlacement() {
    let floating = plan([
      ticket("S1", title: "Show the forecast"),
      ticket("S2", title: "Verify the forecast", type: .task, role: .qualityAssurance),
    ])
    let check = EvalEpicPlanChecks.verificationFollowsImplementation(floating)
    #expect(!check.passed)
    #expect(check.detail.contains("S2"))

    #expect(EvalEpicPlanChecks.verificationFollowsImplementation(canonicalPlan).passed)

    let followsExisting = plan([
      ticket(
        "S1",
        title: "Verify the invoice flow",
        type: .task,
        role: .qualityAssurance,
        dependsOnExisting: ["T2"]
      )
    ])
    #expect(EvalEpicPlanChecks.verificationFollowsImplementation(followsExisting).passed)
  }

  @Test("Design work serialised behind the environment task fails, directly or transitively")
  func designSerialisation() {
    let setup = ticket(
      "S1",
      title: "Set up the delivery environment",
      type: .task,
      environment: .establishes
    )
    let direct = plan([
      setup,
      ticket("S2", title: "Design the forecast screens", role: .uxDesigner, dependsOn: ["S1"]),
    ])
    let directCheck = EvalEpicPlanChecks.independentWorkNotSerialised(direct)
    #expect(!directCheck.passed)
    #expect(directCheck.detail.contains("S2 → S1"))

    let transitive = plan([
      setup,
      ticket(
        "S2",
        title: "Recommend a provider",
        type: .task,
        role: .businessAnalyst,
        dependsOn: ["S1"]
      ),
      ticket("S3", title: "Design the forecast screens", role: .uxDesigner, dependsOn: ["S2"]),
    ])
    #expect(!EvalEpicPlanChecks.independentWorkNotSerialised(transitive).passed)

    let parallel = plan([
      setup,
      ticket("S2", title: "Design the forecast screens", role: .uxDesigner),
      ticket("S3", title: "Show the forecast", dependsOn: ["S1", "S2"]),
    ])
    #expect(EvalEpicPlanChecks.independentWorkNotSerialised(parallel).passed)

    let noSetup = plan([
      ticket("S1", title: "Design the forecast screens", role: .uxDesigner),
      ticket("S2", title: "Show the forecast", dependsOn: ["S1"]),
    ])
    #expect(EvalEpicPlanChecks.independentWorkNotSerialised(noSetup).passed)
  }

  @Test("Parallelism width divides ticket count by the critical-path length")
  func parallelismWidthMetric() {
    let serial = plan([
      ticket("S1", title: "First outcome"),
      ticket("S2", title: "Second outcome", dependsOn: ["S1"]),
      ticket("S3", title: "Third outcome", dependsOn: ["S2"]),
    ])
    let serialMetric = EvalEpicPlanChecks.parallelismWidth(serial)
    #expect(serialMetric.criticalPathLength == 3)
    #expect(serialMetric.width == 1.0)

    let canonicalMetric = EvalEpicPlanChecks.parallelismWidth(canonicalPlan)
    #expect(canonicalMetric.criticalPathLength == 3)
    #expect(abs(canonicalMetric.width - 4.0 / 3.0) < 0.0001)

    let independent = plan([
      ticket("S1", title: "First outcome"),
      ticket("S2", title: "Second outcome"),
      ticket("S3", title: "Third outcome"),
    ])
    let independentMetric = EvalEpicPlanChecks.parallelismWidth(independent)
    #expect(independentMetric.criticalPathLength == 1)
    #expect(independentMetric.width == 3.0)
  }

  @Test("A proposal without acceptance criteria is not an agreed outcome")
  func missingCriteria() {
    let missing = plan([
      ticket("S1", title: "Show the forecast", criteria: [])
    ])
    #expect(!EvalEpicPlanChecks.everyTicketHasAcceptanceCriteria(missing).passed)
    let blank = plan([
      ticket("S1", title: "Show the forecast", criteria: ["   "])
    ])
    #expect(!EvalEpicPlanChecks.everyTicketHasAcceptanceCriteria(blank).passed)
    #expect(EvalEpicPlanChecks.everyTicketHasAcceptanceCriteria(canonicalPlan).passed)
  }

  @Test("A criterion citing another ticket must declare that dependency")
  func criterionCitations() {
    #expect(
      EvalEpicPlanChecks.dependantCriteriaCiteExactKeys(canonicalPlan, existingItems: []).passed
    )

    let undeclared = plan([
      ticket("S1", title: "Recommend a provider", type: .task, role: .businessAnalyst),
      ticket(
        "S2",
        title: "Integrate the provider",
        criteria: ["The provider recommended by S1 supplies the shown content"]
      ),
    ])
    let undeclaredCheck = EvalEpicPlanChecks.dependantCriteriaCiteExactKeys(
      undeclared,
      existingItems: []
    )
    #expect(!undeclaredCheck.passed)
    #expect(undeclaredCheck.detail.contains("without declaring it as a dependency"))

    let unknown = plan([
      ticket(
        "S1",
        title: "Integrate the provider",
        criteria: ["The provider recommended by T9 supplies the shown content"]
      )
    ])
    let unknownCheck = EvalEpicPlanChecks.dependantCriteriaCiteExactKeys(
      unknown,
      existingItems: []
    )
    #expect(!unknownCheck.passed)
    #expect(unknownCheck.detail.contains("matches nothing"))
  }

  @Test("Calendar deadlines in criteria or bodies are unfalsifiable noise")
  func calendarDeadlines() {
    let battersea = plan([
      ticket(
        "S1",
        title: "Review the shelter's public listings",
        type: .task,
        criteria: [
          "Within two working days, review Battersea's current public terms, "
            + "access limits, and the pages that expose available dog listings"
        ],
        role: .businessAnalyst
      )
    ])
    let batterseaCheck = EvalEpicPlanChecks.criteriaAvoidCalendarDeadlines(battersea)
    #expect(!batterseaCheck.passed)
    #expect(batterseaCheck.detail.contains("working day"))

    let numericBody = plan([
      ticket(
        "S1",
        title: "Show the forecast",
        body: "Deliver the forecast screen within 2 weeks of starting."
      )
    ])
    #expect(!EvalEpicPlanChecks.criteriaAvoidCalendarDeadlines(numericBody).passed)

    let byEndOf = plan([
      ticket(
        "S1",
        title: "Show the forecast",
        criteria: ["The forecast is ready by end of the sprint"]
      )
    ])
    #expect(!EvalEpicPlanChecks.criteriaAvoidCalendarDeadlines(byEndOf).passed)

    #expect(EvalEpicPlanChecks.criteriaAvoidCalendarDeadlines(canonicalPlan).passed)
  }

  @Test("Criteria mandating an exact image format burn deliveries the sandbox cannot satisfy")
  func deliverableFormatMandates() {
    let pngMandate = plan([
      ticket(
        "S1",
        title: "Design the forecast screens",
        criteria: ["A managed Demo containing a static PNG visual screen set is provided"],
        role: .uxDesigner
      )
    ])
    let pngCheck = EvalEpicPlanChecks.criteriaRespectDeliverableFormats(pngMandate)
    #expect(!pngCheck.passed)
    #expect(pngCheck.detail.contains("png"))
    #expect(pngCheck.detail.contains("states covered"))

    let svgMandate = plan([
      ticket(
        "S1",
        title: "Design the forecast screens",
        body: "Deliver the screens as one SVG file for review.",
        role: .uxDesigner
      )
    ])
    let svgCheck = EvalEpicPlanChecks.criteriaRespectDeliverableFormats(svgMandate)
    #expect(!svgCheck.passed)
    #expect(svgCheck.detail.contains("svg is never an accepted"))

    let statesPhrased = plan([
      ticket(
        "S1",
        title: "Design the forecast screens",
        criteria: [
          "A static visual screen set covers the success, empty, loading, and failure states"
        ],
        role: .uxDesigner
      )
    ])
    #expect(EvalEpicPlanChecks.criteriaRespectDeliverableFormats(statesPhrased).passed)

    // PDF stays out of the mined list: it can be genuine product scope, such
    // as the greenfield cell's invoice PDF download epic.
    let pdfScope = plan([
      ticket(
        "S1",
        title: "Download an invoice as a PDF file",
        criteria: ["A saved invoice downloads as a PDF file laid out like a printed invoice"]
      )
    ])
    #expect(EvalEpicPlanChecks.criteriaRespectDeliverableFormats(pdfScope).passed)
  }

  @Test("Archetype presence names the shape a plan actually has")
  func archetypePresence() {
    let withSetup = plan([
      ticket(
        "S1",
        title: "Set up the delivery environment",
        type: .task,
        environment: .establishes
      ),
      ticket("S2", title: "Design the forecast screens", type: .task, role: .uxDesigner),
      ticket("S3", title: "Show the forecast", dependsOn: ["S1", "S2"]),
    ])
    #expect(EvalEpicPlanChecks.archetypes(withSetup) == ["setup", "design", "story"])
    #expect(
      EvalEpicPlanChecks.archetypes(canonicalPlan)
        == ["research", "design", "story", "verification"]
    )
  }

  @Test("Setup-ticket vocabulary mined from judge rationales fails the jargon check")
  func minedSetupJargonFails() {
    for term in [
      "managed check", "cached files", "team-owned commands", "stored build data",
    ] {
      let leaking = plan([
        ticket(
          "S1",
          title: "Set up the delivery environment",
          type: .task,
          criteria: ["A \(term) confirms the product is ready"],
          environment: .establishes
        )
      ])
      let check = EvalScenarioCatalog.ownerJargonCheck(leaking)
      #expect(!check.passed, "expected “\(term)” to fail: \(check.detail)")
      #expect(check.detail.contains(term))
    }
    let plain = plan([
      ticket(
        "S1",
        title: "Set up the delivery environment",
        type: .task,
        criteria: [
          "The team can build, test, and demo the product on this Mac",
          "The setup is written down for the team",
        ],
        environment: .establishes
      )
    ])
    #expect(EvalScenarioCatalog.ownerJargonCheck(plain).passed)
  }

  @Test("A committed storage default must be stated in an owner-facing field")
  func committedDefaultStatement() {
    let stated = plan([
      ticket(
        "S1",
        title: "Create and manage Markdown notes",
        criteria: ["Notes are saved in this browser on this device and reappear on return"]
      )
    ])
    #expect(EvalScenarioCatalog.committedDefaultIsStatedCheck(stated).passed)

    let silent = plan([
      ticket(
        "S1",
        title: "Create and manage Markdown notes",
        criteria: ["A user can create, edit, and delete a note"]
      )
    ])
    let check = EvalScenarioCatalog.committedDefaultIsStatedCheck(silent)
    #expect(!check.passed)
    #expect(check.detail.contains("no owner-facing field"))
  }
}

@Suite("Eval report consistency block")
struct EvalReportConsistencyTests {
  private func record(
    scenarioID: String,
    repetition: Int,
    facts: [String: String]
  ) -> EvalCellRecord {
    EvalCellRecord(
      scenarioID: scenarioID,
      generator: "epicPlan",
      model: "gpt-5.6-terra",
      effort: "medium",
      repetition: repetition,
      startedAt: Date(timeIntervalSince1970: 0),
      latencySeconds: 1,
      turnFailure: nil,
      responseCharacterCount: facts.isEmpty ? nil : 100,
      decodePassed: !facts.isEmpty,
      decodeFailure: facts.isEmpty ? "fixture decode failure" : nil,
      checks: [],
      facts: facts,
      judge: nil,
      rawResponse: nil
    )
  }

  @Test("Multi-sample cells aggregate spread and archetype presence")
  func aggregatesMultiSampleCells() throws {
    let rows = EvalReport.consistencyRows(for: [
      record(
        scenarioID: "epic-plan/native-weather",
        repetition: 1,
        facts: [
          "ticketCount": "3",
          "parallelismWidth": "1.50",
          "archetypes": "setup, design, story",
        ]
      ),
      record(
        scenarioID: "epic-plan/native-weather",
        repetition: 2,
        facts: [
          "ticketCount": "2",
          "parallelismWidth": "1.00",
          "archetypes": "setup, story",
        ]
      ),
      record(
        scenarioID: "epic-plan/established",
        repetition: 1,
        facts: ["ticketCount": "2", "parallelismWidth": "2.00", "archetypes": "story"]
      ),
    ])

    // The single-sample cell produces no row; spread and presence come from
    // the two weather samples.
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.cell == "epic-plan/native-weather · gpt-5.6-terra medium")
    #expect(row.samples == "2")
    #expect(row.ticketCountSpread == "2–3")
    #expect(row.parallelismWidthSpread == "1.00–1.50")
    #expect(row.archetypePresence == "setup 2/2, design 1/2, story 2/2")
  }

  @Test("Samples that never decoded a plan are excluded and named in the sample count")
  func excludesUndecodedSamples() {
    let rows = EvalReport.consistencyRows(for: [
      record(
        scenarioID: "epic-plan/native-weather",
        repetition: 1,
        facts: [
          "ticketCount": "3",
          "parallelismWidth": "1.50",
          "archetypes": "setup, story",
        ]
      ),
      record(scenarioID: "epic-plan/native-weather", repetition: 2, facts: [:]),
    ])
    #expect(rows.count == 1)
    #expect(rows.first?.samples == "1 of 2 decoded")
    #expect(rows.first?.ticketCountSpread == "3")

    let undecoded = EvalReport.consistencyRows(for: [
      record(scenarioID: "epic-plan/native-weather", repetition: 1, facts: [:]),
      record(scenarioID: "epic-plan/native-weather", repetition: 2, facts: [:]),
    ])
    #expect(undecoded.isEmpty)
  }
}
