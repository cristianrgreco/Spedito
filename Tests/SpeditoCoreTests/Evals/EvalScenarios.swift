import Foundation
import SpeditoCore

struct EvalRubricDimension: Sendable {
  let name: String
  let guidance: String
}

/// How a scenario's Codex thread starts, mirroring the thread type the owning
/// coordinator uses in production.
enum EvalThreadKind: Sendable {
  /// A read-only thread. A nil working directory means the shared fixture
  /// repository; review scenarios pin their own detached candidate checkout.
  case readOnly(workingDirectoryURL: URL?)
  /// A repository-analysis thread over a sanitized snapshot.
  case repositoryAnalysis(snapshotURL: URL)
  /// A write-enabled delivery thread in an isolated ticket worktree, the
  /// production shape for implementer and UX designer runs. The runner resets
  /// the worktree to baseSHA before every cell so repeated cells start clean.
  case workspace(worktreeURL: URL, readOnlyGitDirectoryURL: URL, baseSHA: String)

  var isWorkspace: Bool {
    if case .workspace = self { return true }
    return false
  }
}

/// Which of a run's requested efforts a scenario may execute at. Most
/// scenarios sweep every requested effort; a family production only ever
/// runs in one configuration declares that instead, so sweeps stop spending
/// usage on configurations the product never uses.
enum EvalEffortPolicy: Sendable {
  /// Run at every requested effort.
  case anyRequested
  /// Run only at the lightest effort the model supports — production's
  /// sprint-goal configuration under its hard 15-second deadline.
  case lightestSupported
}

/// One prompt scenario: the exact developer instructions, prompt, and output
/// schema production would send, a deterministic evaluation built on the
/// production decoder and validators, and a rubric for the LLM judge.
struct EvalScenario: Sendable {
  let id: String
  let generator: String
  let brief: String
  let developerInstructions: String
  let prompt: String
  let outputSchema: JSONValue
  let threadKind: EvalThreadKind
  let effortPolicy: EvalEffortPolicy
  let rubric: [EvalRubricDimension]
  let evaluate: @Sendable (String) -> EvalDeterministicOutcome
  /// Extra evidence for the judge computed after the turn — a delivery cell
  /// supplies the actual worktree diff so the judge scores real changes, not
  /// just the handoff's claims about them.
  let judgeSupplement: (@Sendable () -> String)?

  init(
    id: String,
    generator: String,
    brief: String,
    developerInstructions: String,
    prompt: String,
    outputSchema: JSONValue,
    threadKind: EvalThreadKind = .readOnly(workingDirectoryURL: nil),
    effortPolicy: EvalEffortPolicy = .anyRequested,
    rubric: [EvalRubricDimension],
    evaluate: @escaping @Sendable (String) -> EvalDeterministicOutcome,
    judgeSupplement: (@Sendable () -> String)? = nil
  ) {
    self.id = id
    self.generator = generator
    self.brief = brief
    self.developerInstructions = developerInstructions
    self.prompt = prompt
    self.outputSchema = outputSchema
    self.threadKind = threadKind
    self.effortPolicy = effortPolicy
    self.rubric = rubric
    self.evaluate = evaluate
    self.judgeSupplement = judgeSupplement
  }
}

enum EvalScenarioCatalog {
  private static let ownerClarity = EvalRubricDimension(
    name: "ownerClarity",
    guidance: """
      Owner-facing text is plain, concise language a non-technical product owner \
      understands at a glance. No engineering jargon, internal identifiers, or \
      leaked diagnostics.
      """
  )
  private static let groundedness = EvalRubricDimension(
    name: "groundedness",
    guidance: """
      Every claim is supported by the supplied evidence. Nothing is invented, no \
      product decision is silently made on the owner's behalf, and no unsupported \
      relationship between facts is implied.
      """
  )

  static func scenarios(workspace: EvalFixtureWorkspace) async throws -> [EvalScenario] {
    epicPlanScenarios() + clarificationScenarios() + refinementScenarios()
      + sprintGoalScenarios() + knowledgeScenarios()
      + (try reviewScenarios(workspace: workspace))
      + [try await repositoryAnalysisScenario(workspace: workspace)]
      + [try await knowledgeReviewScenario(workspace: workspace)]
      + (try deliveryScenarios(workspace: workspace))
      + [retrospectiveSynthesisScenario()]
  }

  // MARK: - Shared fixtures

  private static func makeProduct() -> Product {
    Product(
      name: "Ledgerline",
      instructions: "Use UK English. Keep every owner-facing sentence plain and jargon-free."
    )
  }

  private static func environmentsPage(productID: UUID) -> KnowledgePage {
    KnowledgePage(
      productID: productID,
      title: "Environments",
      slug: "environments",
      bodyMarkdown: """
        The product is a Node.js 22 web application managed with npm scripts.

        - Build: `npm run build`
        - Test: `npm test`
        - Local run and demo: `npm run dev` serving http://localhost:5173
        - Temporary files and caches stay inside the repository's `.cache/` directory.

        The delivery environment was established and verified by ticket T1. Managed \
        demo readiness has been confirmed. No additional runtimes are required for \
        ordinary feature work.
        """
    )
  }

  private static func numberingPage(productID: UUID) -> KnowledgePage {
    KnowledgePage(
      productID: productID,
      title: "Invoice numbering rules",
      slug: "invoice-numbering-rules",
      bodyMarkdown: """
        Invoice numbers use the format LL-YYYY-NNN: the client's two-letter code, \
        the calendar year, and a sequence number padded to three digits. The \
        sequence restarts at 001 every January, per client. Numbers are assigned \
        when an invoice is first saved and are never reused, including for deleted \
        invoices.
        """
    )
  }

  private static func establishedBacklog(productID: UUID) -> [WorkItem] {
    [
      WorkItem(
        productID: productID,
        key: "T1",
        title: "Establish the delivery environment",
        type: .task,
        body: """
          Set up the approved Node.js 22 toolchain with repository-owned build, \
          test, run, and demo entry points, run-private caches, and a verified \
          Environments knowledge page.
          """,
        acceptanceCriteria: [
          "npm run build, npm test, and npm run dev succeed from a fresh checkout",
          "The Environments knowledge page is verified and current",
        ],
        state: .released
      ),
      WorkItem(
        productID: productID,
        key: "T2",
        title: "Create and save an invoice",
        body: "A freelancer can create an invoice with line items and save it.",
        acceptanceCriteria: [
          "Saving an invoice with at least one line item persists it",
          "A saved invoice shows its total and payment status",
        ],
        state: .ready
      ),
    ]
  }

  // MARK: - Epic planning

  private static func epicPlanScenarios() -> [EvalScenario] {
    let rubric = [
      ownerClarity, groundedness,
      EvalRubricDimension(
        name: "planShape",
        guidance: """
          Tickets are right-sized, independently understandable outcomes with only \
          genuine dependencies. No padding tickets, no manufactured research or \
          backend work, and parallelism where work truly can proceed in parallel.
          """
      ),
      EvalRubricDimension(
        name: "criteriaQuality",
        guidance: """
          Acceptance criteria are concrete and testable. No vague placeholders such \
          as "as agreed" or "the chosen provider" without naming the prerequisite \
          ticket that supplies the decision.
          """
      ),
      EvalRubricDimension(
        name: "researchDiscipline",
        guidance: """
          No research or discovery ticket exists without explicit product owner \
          authorisation in the supplied context. Product decisions are not silently \
          made or buried inside design or implementation tickets. Environment work \
          follows the environment instructions exactly.
          """
      ),
    ]

    let greenfieldProduct = makeProduct()
    let greenfieldEpic = Epic(
      productID: greenfieldProduct.id,
      title: "",
      goal: """
        Freelancers can download a saved invoice as a PDF file from Ledgerline, \
        laid out like a traditional printed invoice, so they can send it to \
        clients however they already communicate with them.
        """
    )
    let greenfield = EvalScenario(
      id: "epic-plan/greenfield",
      generator: "epicPlan",
      brief: """
        A brand-new product with an empty backlog and no verified environment \
        knowledge. The plan must notice that no delivery environment exists yet: \
        it should include exactly one implementer-owned environment establishment \
        task and make executable work depend on it, without inventing unauthorised \
        research tickets.
        """,
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: greenfieldProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexTicketSuggestionGenerator.epicPrompt(
        product: greenfieldProduct,
        epic: greenfieldEpic,
        existingItems: [],
        verifiedKnowledge: []
      ),
      outputSchema: CodexTicketSuggestionGenerator.epicOutputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateEpicPlan(response, existingItems: []) { plan, checks in
          checks.append(
            EvalCheck(
              name: "readinessIsFoundationRequired",
              passed: plan.environmentAssessment.readiness == .foundationRequired,
              detail: "readiness was \(plan.environmentAssessment.readiness.rawValue)"
            )
          )
        }
      }
    )

    let establishedProduct = makeProduct()
    let establishedEpic = Epic(
      productID: establishedProduct.id,
      title: "Chasing list",
      goal: """
        Show freelancers a chasing list inside Ledgerline: every unpaid invoice \
        more than three days past its due date, with a way to note that the \
        client has been chased, at most one chase note per invoice.
        """,
      successCriteria: [
        "An unpaid invoice appears on the chasing list once it is more than "
          + "three days past its due date",
        "Paid invoices never appear on the chasing list",
        "The owner can record one chase note per invoice and see it on the list",
      ],
      constraints: "Everything happens inside Ledgerline; no emails are sent."
    )
    let establishedItems = establishedBacklog(productID: establishedProduct.id)
    let established = EvalScenario(
      id: "epic-plan/established",
      generator: "epicPlan",
      brief: """
        A product with a verified delivery environment (established by released \
        ticket T1 and recorded in verified Environments knowledge) and \
        owner-reviewed epic metadata. The plan must treat the environment as \
        sufficient rather than re-establishing it, and must preserve the \
        owner-reviewed epic title, goal, success criteria, and constraints exactly.
        """,
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: establishedProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexTicketSuggestionGenerator.epicPrompt(
        product: establishedProduct,
        epic: establishedEpic,
        existingItems: establishedItems,
        verifiedKnowledge: [environmentsPage(productID: establishedProduct.id)]
      ),
      outputSchema: CodexTicketSuggestionGenerator.epicOutputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateEpicPlan(response, existingItems: establishedItems) { plan, checks in
          checks.append(
            EvalCheck(
              name: "readinessIsSufficient",
              passed: plan.environmentAssessment.readiness == .sufficient,
              detail: "readiness was \(plan.environmentAssessment.readiness.rawValue)"
            )
          )
          checks.append(
            EvalCheck(
              name: "ownerTitlePreserved",
              passed: plan.title == establishedEpic.title,
              detail: "title was \"\(plan.title)\""
            )
          )
          checks.append(
            EvalCheck(
              name: "ownerGoalPreserved",
              passed: plan.goal == establishedEpic.goal
                .trimmingCharacters(in: .whitespacesAndNewlines),
              detail: "goal was \"\(plan.goal)\""
            )
          )
        }
      }
    )

    let unresolvedProduct = makeProduct()
    let unresolvedEpic = Epic(
      productID: unresolvedProduct.id,
      title: "",
      goal: """
        Freelancers can show each invoice total in the client's own currency \
        alongside the original amount, converted with current exchange rates, \
        so international clients understand what they owe.
        """
    )
    let unresolvedItems = establishedBacklog(productID: unresolvedProduct.id)
    let providerQuestion = TicketRefinementQuestion(
      prompt: "Which exchange-rate source should Ledgerline use for currency conversion?",
      options: [
        "Have the business analyst research current exchange-rate sources and "
          + "recommend one for your approval (Recommended)",
        "Name an already approved exchange-rate source now",
        "Delegate the choice to the implementer at implementation time without "
          + "a separate recommendation",
      ]
    )
    let unresolvedMessages = [
      EpicPlanningConversationMessage(
        author: .businessAnalyst,
        body: "One consequential choice remains before I can plan: the exchange-rate source."
      ),
      EpicPlanningConversationMessage(
        author: .owner,
        body: "",
        answeredQuestions: [
          EpicPlanningAnsweredQuestion(
            question: providerQuestion,
            selectedOption: nil,
            answer: "Whatever the analyst recommends at planning time."
          )
        ]
      ),
    ]
    let unresolvedProvider = EvalScenario(
      id: "epic-plan/unresolved-provider",
      generator: "epicPlan",
      brief: """
        The final planning turn after a clarification conversation in which the \
        owner answered the exchange-rate source question with "Whatever the \
        analyst recommends at planning time" — an ambiguous delegation that \
        neither names a source nor clearly authorises or declines research. Two \
        replies are acceptable: a plan that carries the source choice in an \
        authorised business analyst research ticket that downstream work depends \
        on, or an escape that returns the one material question needed to \
        disambiguate. Silently naming a specific real exchange-rate source in \
        the tickets, or burying the choice in an implementation ticket, is the \
        failure.
        """,
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: unresolvedProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexEpicClarificationGenerator.finalPlanRecoveryPrompt(
        product: unresolvedProduct,
        epic: unresolvedEpic,
        existingItems: unresolvedItems,
        rejectedSuggestions: [],
        messages: unresolvedMessages,
        verifiedKnowledge: [environmentsPage(productID: unresolvedProduct.id)]
      ),
      outputSchema: CodexTicketSuggestionGenerator.epicOutputSchema,
      rubric: [
        ownerClarity, groundedness,
        EvalRubricDimension(
          name: "decisionDiscipline",
          guidance: """
            The unresolved exchange-rate source is handled responsibly: either a \
            business analyst research ticket owns the recommendation and the \
            dependent work waits for it, or the reply escapes with a material \
            question that names the choice. The reply never invents a specific \
            provider, never buries the selection inside design or \
            implementation, and never returns a plan alongside questions.
            """
        ),
      ],
      evaluate: { response in
        evaluateUnresolvedChoiceReply(response, existingItems: unresolvedItems)
      }
    )

    return [greenfield, established, unresolvedProvider]
  }

  private static func evaluateUnresolvedChoiceReply(
    _ response: String,
    existingItems: [WorkItem]
  ) -> EvalDeterministicOutcome {
    do {
      let reply = try CodexTicketSuggestionGenerator.decodeEpicPlan(
        response,
        existingItems: existingItems
      )
      switch reply {
      case .questions(_, let questions):
        return EvalDeterministicOutcome(
          decodePassed: true,
          decodeFailure: nil,
          checks: [
            EvalCheck(
              name: "escapesOrAuthorisesResearch",
              passed: true,
              detail: "escaped with question(s): "
                + questions.map(\.prompt).joined(separator: "; ")
            )
          ],
          facts: [
            "outcome": "questions",
            "escapedQuestionCount": String(questions.count),
          ]
        )
      case .plan(let plan):
        let researchTickets = plan.ticketSuggestions.filter {
          $0.suggestedRole == .businessAnalyst
        }
        return EvalDeterministicOutcome(
          decodePassed: true,
          decodeFailure: nil,
          checks: [
            EvalCheck(
              name: "escapesOrAuthorisesResearch",
              passed: !researchTickets.isEmpty,
              detail: researchTickets.isEmpty
                ? "planned without a business analyst research ticket or questions"
                : "planned with analyst ticket(s): "
                  + researchTickets.map(\.title).joined(separator: "; ")
            )
          ],
          facts: [
            "outcome": "plan",
            "ticketCount": String(plan.ticketSuggestions.count),
            "analystTicketCount": String(researchTickets.count),
          ]
        )
      }
    } catch {
      return EvalDeterministicOutcome(
        decodePassed: false,
        decodeFailure: describeError(error),
        checks: [],
        facts: [:]
      )
    }
  }

  /// The mined judge critique behind sub-4 greenfield scores: engineering
  /// vocabulary in owner-facing ticket fields. The term list stays small and
  /// literal — every entry was observed in recorded judge rationales; the
  /// judge remains the qualitative layer for wording this list cannot catch.
  private static let ownerFacingJargonTerms = [
    "repository", "repo", "localhost", "cache", "caches", "toolchain",
    "readiness check", "capability boundary",
  ]

  /// Theme 2's mined markers: acceptance-criteria phrases that defer what
  /// would be verified instead of stating it. "hand-off" alone is excluded —
  /// a criterion citing a named prerequisite's hand-off is legitimate
  /// provenance under the criteriaQuality rubric.
  private static let vagueCriteriaPhrases = [
    "relevant", "that matter", "ready for build hand-off",
  ]

  private static func vagueCriteriaCheck(_ plan: EpicPlanDraft) -> EvalCheck {
    var findings: [String] = []
    for suggestion in plan.ticketSuggestions {
      for criterion in suggestion.acceptanceCriteria {
        let lowered = criterion.lowercased()
        let hits = vagueCriteriaPhrases.filter { phrase in
          lowered.range(
            of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b",
            options: .regularExpression
          ) != nil
        }
        if !hits.isEmpty {
          findings.append(
            "\(suggestion.reference): “\(criterion.prefix(90))” (\(hits.joined(separator: ", ")))"
          )
        }
      }
    }
    return EvalCheck(
      name: "criteriaAvoidVaguePhrases",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "no acceptance criterion defers its own definition"
        : "criteria defer what they verify — " + findings.joined(separator: "; ")
    )
  }

  private static func ownerJargonCheck(_ plan: EpicPlanDraft) -> EvalCheck {
    var findings: [String] = []
    for suggestion in plan.ticketSuggestions {
      let text = ([suggestion.title, suggestion.body] + suggestion.acceptanceCriteria)
        .joined(separator: "\n")
        .lowercased()
      let hits = ownerFacingJargonTerms.filter { term in
        text.range(
          of: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b",
          options: .regularExpression
        ) != nil
      }
      if !hits.isEmpty {
        findings.append(
          "\(suggestion.reference) “\(suggestion.title)”: " + hits.joined(separator: ", ")
        )
      }
    }
    return EvalCheck(
      name: "ownerFacingFieldsAvoidJargon",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "no mined jargon term appears in owner-facing ticket fields"
        : "owner-facing fields use engineering jargon — " + findings.joined(separator: "; ")
    )
  }

  private static func evaluateEpicPlan(
    _ response: String,
    existingItems: [WorkItem],
    extraChecks: (EpicPlanDraft, inout [EvalCheck]) -> Void
  ) -> EvalDeterministicOutcome {
    do {
      let reply = try CodexTicketSuggestionGenerator.decodeEpicPlan(
        response,
        existingItems: existingItems
      )
      let plan: EpicPlanDraft
      switch reply {
      case .questions(_, let questions):
        return EvalDeterministicOutcome(
          decodePassed: true,
          decodeFailure: nil,
          checks: [
            EvalCheck(
              name: "returnsPlan",
              passed: false,
              detail: "escaped to questions instead of planning: "
                + questions.map(\.prompt).joined(separator: "; ")
            )
          ],
          facts: ["escapedQuestionCount": String(questions.count)]
        )
      case .plan(let decodedPlan):
        plan = decodedPlan
      }
      var checks: [EvalCheck] = []
      let prefixedTitles = plan.ticketSuggestions.filter {
        $0.title.range(of: #"^S\d+\b"#, options: .regularExpression) != nil
      }
      checks.append(
        EvalCheck(
          name: "noReferencePrefixInTitles",
          passed: prefixedTitles.isEmpty,
          detail: prefixedTitles.isEmpty
            ? "no ticket title repeats its temporary reference"
            : "titles repeat references: \(prefixedTitles.map(\.title).joined(separator: "; "))"
        )
      )
      checks.append(ownerJargonCheck(plan))
      checks.append(vagueCriteriaCheck(plan))
      extraChecks(plan, &checks)
      let dependencyEdges = plan.ticketSuggestions.reduce(0) {
        $0 + $1.dependsOnReferences.count + $1.dependsOnExistingWorkItemKeys.count
      }
      let roles = Dictionary(grouping: plan.ticketSuggestions, by: \.suggestedRole.rawValue)
        .mapValues(\.count)
        .sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value)" }
        .joined(separator: ", ")
      return EvalDeterministicOutcome(
        decodePassed: true,
        decodeFailure: nil,
        checks: checks,
        facts: [
          "ticketCount": String(plan.ticketSuggestions.count),
          "dependencyEdges": String(dependencyEdges),
          "readiness": plan.environmentAssessment.readiness.rawValue,
          "foundationReference": plan.environmentAssessment.foundationTicketReference ?? "none",
          "roles": roles,
        ]
      )
    } catch {
      return EvalDeterministicOutcome(
        decodePassed: false,
        decodeFailure: describeError(error),
        checks: [],
        facts: [:]
      )
    }
  }

  // MARK: - Epic clarification

  private static func clarificationScenarios() -> [EvalScenario] {
    let rubric = [
      ownerClarity, groundedness,
      EvalRubricDimension(
        name: "questionMateriality",
        guidance: """
          Asks only questions whose answer genuinely changes scope, success \
          criteria, user experience, cost, privacy, or maintenance. Does not \
          re-ask anything the owner already decided, and declares readiness \
          exactly when nothing material remains open.
          """
      ),
      EvalRubricDimension(
        name: "optionQuality",
        guidance: """
          Answer options are concise, realistic, mutually exclusive decisions \
          that cover the plausible choice space without steering the owner. \
          Shared context belongs in the question prompt: each option states \
          only what differs between the choices, and options that restate the \
          epic outcome or repeat context common to every option fail this \
          dimension even when they are otherwise accurate.
          """
      ),
    ]

    let vagueProduct = makeProduct()
    let vagueEpic = Epic(
      productID: vagueProduct.id,
      title: "",
      goal: "Customers should be able to pay invoices online."
    )
    let vagueItems = establishedBacklog(productID: vagueProduct.id)
    let vague = EvalScenario(
      id: "clarification/vague",
      generator: "clarification",
      brief: """
        An epic request that leaves consequential choices open: payment provider, \
        fees, currencies, and what "paid" means for the invoice record. A good \
        reply asks one to three material questions and does not declare itself \
        ready to plan.
        """,
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: vagueProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexEpicClarificationGenerator.initialPrompt(
        product: vagueProduct,
        epic: vagueEpic,
        existingItems: vagueItems,
        verifiedKnowledge: [environmentsPage(productID: vagueProduct.id)]
      ),
      outputSchema: CodexEpicClarificationGenerator.outputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateClarification(response, epicGoal: vagueEpic.goal) { reply, checks in
          checks.append(
            EvalCheck(
              name: "asksBeforePlanning",
              passed: !reply.readyToPlan,
              detail: reply.readyToPlan
                ? "declared ready to plan despite unresolved payment decisions"
                : "asked before planning"
            )
          )
        }
      }
    )

    let resolvedProduct = makeProduct()
    let resolvedEpic = Epic(
      productID: resolvedProduct.id,
      title: "",
      goal: """
        Add a printable monthly income summary. Decisions already made by the \
        product owner: the summary lives in the existing reports area; it counts \
        paid invoices only, assigned to months by the paid date that Ledgerline \
        already records when an invoice is marked paid; totals are grouped by \
        client, with one line per client and one overall total, and individual \
        invoices are not listed; amounts are in GBP only; the summary uses only \
        invoice data already saved in Ledgerline; no charts; printing uses the \
        standard system print dialog; the owner picks the month from a list of \
        all months that have at least one paid invoice, and other months are \
        not shown.
        """
    )
    let resolvedItems = establishedBacklog(productID: resolvedProduct.id)
    let resolved = EvalScenario(
      id: "clarification/resolved",
      generator: "clarification",
      brief: """
        An epic request in which the owner has already resolved every \
        consequential choice: grouping, currency, data source, presentation, and \
        print mechanism. A good reply asks nothing and declares itself ready to \
        plan; asking again about resolved choices is the failure this scenario \
        probes.
        """,
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: resolvedProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexEpicClarificationGenerator.initialPrompt(
        product: resolvedProduct,
        epic: resolvedEpic,
        existingItems: resolvedItems,
        verifiedKnowledge: [environmentsPage(productID: resolvedProduct.id)]
      ),
      outputSchema: CodexEpicClarificationGenerator.outputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateClarification(response, epicGoal: resolvedEpic.goal) { reply, checks in
          checks.append(
            EvalCheck(
              name: "readyWithoutQuestions",
              passed: reply.readyToPlan,
              detail: reply.readyToPlan
                ? "ready to plan"
                : "asked again despite resolved decisions: "
                  + reply.questions.map(\.prompt).joined(separator: " | ")
            )
          )
        }
      }
    )

    let detailedProduct = makeProduct()
    let detailedEpic = Epic(
      productID: detailedProduct.id,
      title: "",
      goal: """
        Freelancers can send each overdue client one polite payment reminder \
        email per week directly from Ledgerline, using the contact address \
        already saved on the invoice, with every reminder recorded on that \
        invoice so the freelancer can always see when a client was last \
        reminded.
        """
    )
    let detailedItems = establishedBacklog(productID: detailedProduct.id)
    let detailed = EvalScenario(
      id: "clarification/detailed-outcome",
      generator: "clarification",
      brief: """
        A long, specific outcome sentence in which the owner has already \
        resolved the audience, channel, frequency cap, address source, and \
        record-keeping — but not how email actually leaves Ledgerline, which \
        is a consequential external delivery choice with cost, privacy, and \
        deliverability consequences. A good reply asks one to three material \
        questions whose options are concise, self-contained decisions; the \
        shared context is carried by the question prompt, and options that \
        each restate the long outcome sentence are the failure this scenario \
        probes.
        """,
      developerInstructions: CodexTicketSuggestionGenerator.developerInstructions(
        productInstructions: detailedProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexEpicClarificationGenerator.initialPrompt(
        product: detailedProduct,
        epic: detailedEpic,
        existingItems: detailedItems,
        verifiedKnowledge: [environmentsPage(productID: detailedProduct.id)]
      ),
      outputSchema: CodexEpicClarificationGenerator.outputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateClarification(response, epicGoal: detailedEpic.goal) { reply, checks in
          checks.append(
            EvalCheck(
              name: "asksBeforePlanning",
              passed: !reply.readyToPlan,
              detail: reply.readyToPlan
                ? "declared ready to plan despite the unresolved email delivery choice"
                : "asked before planning"
            )
          )
        }
      }
    )

    return [vague, resolved, detailed]
  }

  private static func evaluateClarification(
    _ response: String,
    epicGoal: String,
    extraChecks: (EpicClarificationReply, inout [EvalCheck]) -> Void
  ) -> EvalDeterministicOutcome {
    do {
      let reply = try CodexEpicClarificationGenerator.decode(response)
      var checks: [EvalCheck] = []
      if !reply.questions.isEmpty {
        checks.append(optionRestatementCheck(reply, epicGoal: epicGoal))
      }
      extraChecks(reply, &checks)
      return EvalDeterministicOutcome(
        decodePassed: true,
        decodeFailure: nil,
        checks: checks,
        facts: [
          "questionCount": String(reply.questions.count),
          "readyToPlan": String(reply.readyToPlan),
          "questions": reply.questions.map(\.prompt).joined(separator: " | "),
        ]
      )
    } catch {
      return EvalDeterministicOutcome(
        decodePassed: false,
        decodeFailure: describeError(error),
        checks: [],
        facts: [:]
      )
    }
  }

  /// Mechanically catches the observed production defect: every option in a
  /// question opening with the same restated outcome sentence. Wording quality
  /// stays with the judge; this check only flags a long shared option prefix
  /// or a verbatim epic-goal restatement inside an option.
  private static func optionRestatementCheck(
    _ reply: EpicClarificationReply,
    epicGoal: String
  ) -> EvalCheck {
    let sharedPrefixLimit = 25
    let goalSentence =
      epicGoal
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    var failures: [String] = []
    for question in reply.questions {
      let sharedPrefix = question.options.dropFirst().reduce(
        question.options.first ?? ""
      ) { $0.commonPrefix(with: $1) }
      if sharedPrefix.count >= sharedPrefixLimit {
        failures.append(
          "options for “\(question.prompt)” share the prefix "
            + "“\(String(sharedPrefix.prefix(60)))…”"
        )
      }
      if goalSentence.count >= 20,
        question.options.contains(where: { $0.contains(goalSentence) })
      {
        failures.append(
          "an option for “\(question.prompt)” restates the epic goal verbatim"
        )
      }
    }
    return EvalCheck(
      name: "optionsShareNoLongPrefix",
      passed: failures.isEmpty,
      detail: failures.isEmpty
        ? "options state only what differs"
        : failures.joined(separator: "; ")
    )
  }

  // MARK: - Ticket refinement

  private static func refinementScenarios() -> [EvalScenario] {
    let rubric = [
      ownerClarity, groundedness,
      EvalRubricDimension(
        name: "refinementValue",
        guidance: """
          The refined snapshot genuinely improves clarity and testability while \
          preserving the owner's intent. Criteria describe observable outcomes, \
          not implementation steps.
          """
      ),
      EvalRubricDimension(
        name: "processDiscipline",
        guidance: """
          When a material owner choice is unresolved, asks a focused question with \
          two to four mutually exclusive options instead of guessing, and leaves \
          the saved ticket unchanged while asking. References only tickets that \
          exist in the supplied backlog.
          """
      ),
    ]

    let thinProduct = makeProduct()
    let thinItems = establishedBacklog(productID: thinProduct.id)
    let thinItem = WorkItem(
      productID: thinProduct.id,
      key: "T3",
      title: "Search invoices",
      state: .refining
    )
    let thin = EvalScenario(
      id: "refinement/thin-ticket",
      generator: "refinement",
      brief: """
        A one-line ticket with no context and no acceptance criteria, in a product \
        whose environment is already established. A good reply either produces a \
        concrete, testable refinement or asks a genuinely material question; it \
        must not return the ticket as thin as it arrived.
        """,
      developerInstructions: CodexTicketRefinementGenerator.developerInstructions(
        productInstructions: thinProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexTicketRefinementGenerator.prompt(
        product: thinProduct,
        item: thinItem,
        existingItems: thinItems,
        dependencies: []
      ),
      outputSchema: CodexTicketRefinementGenerator.outputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateRefinement(response, item: thinItem, relatedItems: thinItems) { reply, checks in
          let refined = reply.proposal.missingQuestions.isEmpty
            && reply.proposal.acceptanceCriteria.count >= 2
          checks.append(
            EvalCheck(
              name: "refinesOrAsks",
              passed: refined || !reply.proposal.missingQuestions.isEmpty,
              detail: refined
                ? "returned a refined snapshot"
                : (reply.proposal.missingQuestions.isEmpty
                  ? "returned the ticket still thin, without questions"
                  : "asked \(reply.proposal.missingQuestions.count) question(s)")
            )
          )
        }
      }
    )

    let decisionProduct = makeProduct()
    let decisionItems = establishedBacklog(productID: decisionProduct.id)
    let decisionItem = WorkItem(
      productID: decisionProduct.id,
      key: "T4",
      title: "Export invoices to accounting software",
      body: """
        Freelancers want their Ledgerline invoices in their accounting software \
        without retyping them. The product owner has not yet said which accounting \
        software or export format matters.
        """,
      state: .refining
    )
    let decision = EvalScenario(
      id: "refinement/decision-needed",
      generator: "refinement",
      brief: """
        A ticket whose body states that a consequential owner choice (which \
        accounting software and format to target) is still open. A good reply asks \
        that question with concrete options and preserves the saved ticket exactly \
        while asking, rather than picking a target on the owner's behalf.
        """,
      developerInstructions: CodexTicketRefinementGenerator.developerInstructions(
        productInstructions: decisionProduct.instructions,
        customInstructions: ""
      ),
      prompt: CodexTicketRefinementGenerator.prompt(
        product: decisionProduct,
        item: decisionItem,
        existingItems: decisionItems,
        dependencies: []
      ),
      outputSchema: CodexTicketRefinementGenerator.outputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateRefinement(response, item: decisionItem, relatedItems: decisionItems) {
          reply, checks in
          let questions = reply.proposal.missingQuestions
          checks.append(
            EvalCheck(
              name: "asksMaterialQuestion",
              passed: !questions.isEmpty,
              detail: questions.isEmpty
                ? "chose a target without asking the owner"
                : "asked: " + questions.map(\.prompt).joined(separator: " | ")
            )
          )
          if !questions.isEmpty {
            let preserved =
              reply.proposal.title == decisionItem.title
              && reply.proposal.body == decisionItem.body
              && reply.proposal.acceptanceCriteria == decisionItem.acceptanceCriteria
            checks.append(
              EvalCheck(
                name: "snapshotPreservedWhileAsking",
                passed: preserved,
                detail: preserved
                  ? "saved snapshot preserved"
                  : "modified the saved ticket while questions are outstanding"
              )
            )
          }
        }
      }
    )

    return [thin, decision]
  }

  private static func evaluateRefinement(
    _ response: String,
    item: WorkItem,
    relatedItems: [WorkItem],
    extraChecks: (TicketRefinementReply, inout [EvalCheck]) -> Void
  ) -> EvalDeterministicOutcome {
    do {
      let reply = try CodexTicketRefinementGenerator.decode(
        response,
        currentItem: item,
        validRelatedItems: relatedItems
      )
      var checks: [EvalCheck] = []
      extraChecks(reply, &checks)
      return EvalDeterministicOutcome(
        decodePassed: true,
        decodeFailure: nil,
        checks: checks,
        facts: [
          "criteriaCount": String(reply.proposal.acceptanceCriteria.count),
          "questionCount": String(reply.proposal.missingQuestions.count),
          "dependencyCount": String(reply.proposal.dependencies.count),
          "splitRecommended": String(reply.proposal.splitRecommendation != nil),
        ]
      )
    } catch {
      return EvalDeterministicOutcome(
        decodePassed: false,
        decodeFailure: describeError(error),
        checks: [],
        facts: [:]
      )
    }
  }

  // MARK: - Sprint goal

  private static func sprintGoalScenarios() -> [EvalScenario] {
    let rubric = [
      ownerClarity,
      EvalRubricDimension(
        name: "goalQuality",
        guidance: """
          A five-to-ten-word, outcome-oriented goal a non-technical owner scans at \
          a glance. Captures the unifying user-visible outcome; no ticket keys, \
          mechanics, or generic activity such as "complete the planned tickets". \
          When ticket titles cover distinct outcomes, it stays honest about the \
          combined focus instead of implying a false theme.
          """
      ),
    ]

    let cohesive = sprintGoalScenario(
      id: "sprint-goal/cohesive",
      brief: """
        Ticket titles that share one user-visible outcome (getting invoice \
        reminders working end to end). A good goal names that single outcome.
        """,
      rubric: rubric,
      ticketTitles: [
        "Schedule a reminder three days after an invoice due date",
        "Compose the reminder email from the invoice details",
        "Record on the invoice that its reminder was sent",
        "Let the owner turn reminders off for one client",
      ]
    )

    let disjoint = sprintGoalScenario(
      id: "sprint-goal/disjoint",
      brief: """
        Ticket titles spanning three unrelated outcomes. A good goal describes the \
        combined product focus honestly without inventing a unifying theme the \
        titles do not support.
        """,
      rubric: rubric,
      ticketTitles: [
        "Search invoices by client name",
        "Export invoices as CSV",
        "Fix the total shown for invoices with a credit line",
      ]
    )

    return [cohesive, disjoint]
  }

  private static func sprintGoalScenario(
    id: String,
    brief: String,
    rubric: [EvalRubricDimension],
    ticketTitles: [String]
  ) -> EvalScenario {
    EvalScenario(
      id: id,
      generator: "sprintGoal",
      brief: brief,
      developerInstructions: CodexSprintGoalGenerator.developerInstructions,
      prompt: CodexSprintGoalGenerator.prompt(
        productName: "Ledgerline",
        sprintNumber: 3,
        ticketTitles: ticketTitles
      ),
      outputSchema: CodexSprintGoalGenerator.outputSchema,
      // Production only ever generates the sprint goal at the lightest
      // supported effort under its 15-second deadline; measuring heavier
      // efforts spends usage on a configuration the product cannot reach.
      effortPolicy: .lightestSupported,
      rubric: rubric,
      evaluate: { response in
        do {
          let goal = try CodexSprintGoalGenerator.decode(response)
          let wordCount = goal.split(whereSeparator: \.isWhitespace).count
          let endsCleanly = goal.last.map { !",.!?:;".contains($0) } ?? false
          return EvalDeterministicOutcome(
            decodePassed: true,
            decodeFailure: nil,
            checks: [
              EvalCheck(
                name: "endsWithoutPunctuation",
                passed: endsCleanly,
                detail: "goal was \"\(goal)\""
              )
            ],
            facts: [
              "goal": goal,
              "characterCount": String(goal.count),
              "wordCount": String(wordCount),
            ]
          )
        } catch {
          return EvalDeterministicOutcome(
            decodePassed: false,
            decodeFailure: describeError(error),
            checks: [],
            facts: [:]
          )
        }
      }
    )
  }

  // MARK: - Knowledge assistant

  private static func knowledgeScenarios() -> [EvalScenario] {
    let rubric = [
      ownerClarity,
      EvalRubricDimension(
        name: "answerFidelity",
        guidance: """
          Answers strictly from the supplied pages. Says plainly when the pages do \
          not answer the question, without speculating. Cites exactly the pages \
          that support each material claim.
          """
      ),
    ]

    let product = makeProduct()
    let pages = [
      environmentsPage(productID: product.id),
      numberingPage(productID: product.id),
    ]
    let allowedPageIDs = Set(pages.map(\.id))
    let numberingPageID = pages[1].id

    let answerable = EvalScenario(
      id: "knowledge/answerable",
      generator: "knowledge",
      brief: """
        A question fully answered by the "Invoice numbering rules" page. A good \
        answer states the format and the yearly per-client reset, and cites that \
        page.
        """,
      developerInstructions: CodexKnowledgeAssistant.developerInstructions,
      prompt: CodexKnowledgeAssistant.prompt(
        question: "How are invoice numbers assigned, and do they ever reset?",
        pages: pages
      ),
      outputSchema: CodexKnowledgeAssistant.outputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateKnowledge(response, allowedPageIDs: allowedPageIDs) { answer, checks in
          checks.append(
            EvalCheck(
              name: "citesNumberingPage",
              passed: answer.citationPageIDs.contains(numberingPageID),
              detail: answer.citationPageIDs.isEmpty
                ? "no citations returned"
                : "cited \(answer.citationPageIDs.count) page(s)"
            )
          )
        }
      }
    )

    let unanswerable = EvalScenario(
      id: "knowledge/unanswerable",
      generator: "knowledge",
      brief: """
        A question (supported payment providers) that no supplied page answers. A \
        good answer says plainly that the knowledge base does not cover it, cites \
        nothing, and invents nothing.
        """,
      developerInstructions: CodexKnowledgeAssistant.developerInstructions,
      prompt: CodexKnowledgeAssistant.prompt(
        question: "Which payment providers does Ledgerline support?",
        pages: pages
      ),
      outputSchema: CodexKnowledgeAssistant.outputSchema,
      rubric: rubric,
      evaluate: { response in
        evaluateKnowledge(response, allowedPageIDs: allowedPageIDs) { answer, checks in
          checks.append(
            EvalCheck(
              name: "declinesWithoutCitations",
              passed: answer.citationPageIDs.isEmpty,
              detail: answer.citationPageIDs.isEmpty
                ? "no citations, as expected"
                : "cited pages although none answer the question"
            )
          )
        }
      }
    )

    return [answerable, unanswerable]
  }

  private static func evaluateKnowledge(
    _ response: String,
    allowedPageIDs: Set<UUID>,
    extraChecks: (KnowledgeAnswer, inout [EvalCheck]) -> Void
  ) -> EvalDeterministicOutcome {
    do {
      let answer = try CodexKnowledgeAssistant.decode(response, allowedPageIDs: allowedPageIDs)
      var checks: [EvalCheck] = []
      extraChecks(answer, &checks)
      return EvalDeterministicOutcome(
        decodePassed: true,
        decodeFailure: nil,
        checks: checks,
        facts: [
          "citationCount": String(answer.citationPageIDs.count),
          "answerCharacterCount": String(answer.answer.count),
        ]
      )
    } catch {
      return EvalDeterministicOutcome(
        decodePassed: false,
        decodeFailure: describeError(error),
        checks: [],
        facts: [:]
      )
    }
  }

  // MARK: - Tech lead review

  private static let overdueSummaryIntegration = """
    import { invoiceTotal } from "./invoices.js"
    import { isOverdue } from "./overdue.js"

    export function invoiceSummaryLine(invoice, today) {
      const total = invoiceTotal(invoice.lines)
      const overdue = isOverdue(invoice, today) ? " — OVERDUE" : ""
      return `${invoice.number} — £${total.toFixed(2)} — ${invoice.status}${overdue}`
    }
    """

  private static let overdueTicketFiles: [String: String] = [
    "clean": """
      export function isOverdue(invoice, today) {
        if (invoice.status === "paid") {
          return false
        }
        return invoice.dueDate < today
      }
      """,
    "flawed": """
      export function isOverdue(invoice, today) {
        return invoice.dueDate < today
      }
      """,
    "cleanTest": """
      import test from "node:test"
      import assert from "node:assert/strict"
      import { invoiceSummaryLine } from "../src/summary.js"

      const lines = [{ amount: 120 }]

      test("an unpaid invoice past its due date shows OVERDUE", () => {
        const invoice = { number: "AC-2026-001", status: "sent", dueDate: "2026-08-01", lines }
        assert.match(invoiceSummaryLine(invoice, "2026-08-27"), / — OVERDUE$/)
      })

      test("a paid invoice never shows OVERDUE", () => {
        const invoice = { number: "AC-2026-002", status: "paid", dueDate: "2026-08-01", lines }
        assert.doesNotMatch(invoiceSummaryLine(invoice, "2026-08-27"), /OVERDUE/)
      })
      """,
    "flawedTest": """
      import test from "node:test"
      import assert from "node:assert/strict"
      import { invoiceSummaryLine } from "../src/summary.js"

      const lines = [{ amount: 120 }]

      test("an unpaid invoice past its due date shows OVERDUE", () => {
        const invoice = { number: "AC-2026-001", status: "sent", dueDate: "2026-08-01", lines }
        assert.match(invoiceSummaryLine(invoice, "2026-08-27"), / — OVERDUE$/)
      })
      """,
  ]

  private static func reviewScenarios(workspace: EvalFixtureWorkspace) throws -> [EvalScenario] {
    let rubric = [
      ownerClarity,
      EvalRubricDimension(
        name: "findingPrecision",
        guidance: """
          Every finding names a real, material problem with exact evidence from \
          the candidate. No invented problems, no cosmetic-only findings raised \
          as blockers, and a sound candidate is approved rather than nitpicked.
          """
      ),
      EvalRubricDimension(
        name: "reviewJudgment",
        guidance: """
          The decision matches the evidence. Material acceptance-criteria \
          violations are caught, and the implementer's handoff claims are \
          verified against the actual files rather than trusted.
          """
      ),
      EvalRubricDimension(
        name: "retrospectiveDiscipline",
        guidance: """
          The reviewer's own retrospective lists stay within the review \
          contract: empty unless a concrete observation is already evident \
          from this pass, at most two items, each tied to evidence seen \
          during review. Empty lists on an ordinary review score WELL. \
          Generic praise, echoing the implementer's borderline-generic note, \
          and restated review findings are penalized. A team_practice action \
          describes conduct possible with existing capabilities, and missing \
          evidence must not become a retrospective action.
          """
      ),
    ]

    func makeScenario(
      id: String,
      brief: String,
      overdueSource: String,
      overdueTest: String,
      expectedDecision: TechLeadReviewDecision,
      checkName: String
    ) throws -> EvalScenario {
      let repository = try workspace.makeRepository(
        name: id.replacingOccurrences(of: "/", with: "-"),
        files: EvalFixtureWorkspace.sharedRepositoryFiles
      )
      let baseSHA = try repository.headSHA()
      try repository.write(files: [
        "src/overdue.js": overdueSource,
        "src/summary.js": overdueSummaryIntegration,
        "tests/overdue.test.js": overdueTest,
      ])
      let headSHA = try repository.commitAll(message: "T5: mark overdue invoices")
      try repository.checkoutDetached(headSHA)

      let product = makeProduct()
      let item = WorkItem(
        productID: product.id,
        key: "T5",
        title: "Show which invoices are overdue",
        body: """
          Freelancers need to see at a glance which invoices are overdue so they \
          can chase payment.
          """,
        acceptanceCriteria: [
          "The invoice summary line ends with OVERDUE for an unpaid invoice "
            + "with a due date before today",
          "A paid invoice never shows OVERDUE, whatever its due date",
          "Automated tests cover both the unpaid-overdue and the paid case",
        ],
        state: .verifying
      )
      let implementer = AgentProfile(
        productID: product.id,
        name: "Implementer",
        role: .implementer,
        model: "gpt-5.6-terra",
        reasoningEffort: "medium"
      )
      let reviewer = AgentProfile(
        productID: product.id,
        name: "Tech lead",
        role: .lead,
        model: "gpt-5.6-terra",
        reasoningEffort: "high"
      )
      let implementation = TicketExecutionResult(
        status: .completed,
        comment: """
          Overdue detection is in place: the summary line for an unpaid invoice \
          past its due date now ends with OVERDUE, paid invoices never show it, \
          and tests cover both cases.
          """,
        question: nil,
        options: [],
        summary: """
          Added src/overdue.js with an isOverdue(invoice, today) helper, wired \
          it into the summary line in src/summary.js, and added \
          tests/overdue.test.js covering the acceptance criteria: an unpaid \
          invoice with a due date before today shows OVERDUE, and a paid \
          invoice never does. No other modules changed.
          """,
        changedFiles: ["src/overdue.js", "src/summary.js", "tests/overdue.test.js"],
        tests: ["npm test — all tests passing"],
        knowledgeNotes: [],
        reviewInstructions: [
          "Check that the summary line for an unpaid invoice with a past due date ends with OVERDUE"
        ],
        retrospectiveWentWell: [
          "The executable acceptance tests in tests/overdue.test.js made the "
            + "overdue rules unambiguous to implement"
        ],
        retrospectiveCouldImprove: ["Everything went smoothly overall"],
        retrospectiveActions: []
      )
      return EvalScenario(
        id: id,
        generator: "techLeadReview",
        brief: brief,
        developerInstructions: CodexTechLeadReviewer.developerInstructions(
          productInstructions: product.instructions,
          customInstructions: "",
          reviewer: reviewer
        ),
        prompt: CodexTechLeadReviewer.prompt(
          product: product,
          item: item,
          implementation: implementation,
          knowledgePageProposals: [],
          assignee: implementer,
          baseSHA: baseSHA,
          candidateHeadSHA: headSHA
        ),
        outputSchema: CodexTechLeadReviewer.outputSchema,
        threadKind: .readOnly(workingDirectoryURL: repository.rootURL),
        rubric: rubric,
        evaluate: { response in
          do {
            let review = try CodexTechLeadReviewer.decode(response)
            return EvalDeterministicOutcome(
              decodePassed: true,
              decodeFailure: nil,
              checks: [
                EvalCheck(
                  name: checkName,
                  passed: review.decision == expectedDecision,
                  detail: "decision was \(review.decision.rawValue)"
                    + (review.findings.isEmpty
                      ? ""
                      : "; findings: " + review.findings.joined(separator: " | "))
                ),
                retrospectiveRestatementCheck(
                  items: review.retrospectiveWentWell
                    + review.retrospectiveCouldImprove
                    + review.retrospectiveActions.map(\.body),
                  workLogTexts: [review.comment] + review.findings
                ),
              ],
              facts: [
                "decision": review.decision.rawValue,
                "findingCount": String(review.findings.count),
                "findings": review.findings.joined(separator: " | "),
                "retroCounts": "wentWell \(review.retrospectiveWentWell.count), "
                  + "couldImprove \(review.retrospectiveCouldImprove.count), "
                  + "actions \(review.retrospectiveActions.count)",
              ]
            )
          } catch {
            return EvalDeterministicOutcome(
              decodePassed: false,
              decodeFailure: describeError(error),
              checks: [],
              facts: [:]
            )
          }
        }
      )
    }

    let clean = try makeScenario(
      id: "review/clean-candidate",
      brief: """
        A sound candidate: the overdue helper is correct, it is wired into the \
        owner-visible invoice summary line, the tests cover both required \
        cases, and the handoff is accurate. A good review approves it without \
        inventing findings.
        """,
      overdueSource: overdueTicketFiles["clean"]!,
      overdueTest: overdueTicketFiles["cleanTest"]!,
      expectedDecision: .approved,
      checkName: "approvesCleanCandidate"
    )
    let flawed = try makeScenario(
      id: "review/flawed-candidate",
      brief: """
        A flawed candidate whose handoff overclaims: the overdue helper ignores \
        whether an invoice is paid, violating the "a paid invoice is never \
        marked overdue" criterion, and the promised paid-case test does not \
        exist. The handoff claims both are covered. A good review reads the \
        actual files, catches the violation, and requests changes.
        """,
      overdueSource: overdueTicketFiles["flawed"]!,
      overdueTest: overdueTicketFiles["flawedTest"]!,
      expectedDecision: .changesRequested,
      checkName: "blocksFlawedCandidate"
    )
    return [clean, flawed]
  }

  // MARK: - Delivery runs

  private static let dueSoonSpecification = """
    import test from "node:test"
    import assert from "node:assert/strict"
    import { invoiceSummaryLine } from "../src/summary.js"

    const lines = [{ amount: 60 }]

    test("an unpaid invoice due within the next seven days shows DUE SOON", () => {
      const invoice = { number: "AC-2026-003", status: "sent", dueDate: "2026-09-01", lines }
      assert.match(invoiceSummaryLine(invoice, "2026-08-27"), / — DUE SOON$/)
    })

    test("a paid invoice never shows DUE SOON", () => {
      const invoice = { number: "AC-2026-004", status: "paid", dueDate: "2026-09-01", lines }
      assert.doesNotMatch(invoiceSummaryLine(invoice, "2026-08-27"), /DUE SOON/)
    })

    test("an unpaid invoice due more than seven days ahead shows no DUE SOON", () => {
      const invoice = { number: "AC-2026-005", status: "sent", dueDate: "2026-10-01", lines }
      assert.doesNotMatch(invoiceSummaryLine(invoice, "2026-08-27"), /DUE SOON/)
    })
    """

  /// The judge reads the textual diff, so a committed image is an invisible
  /// binary blob to it. This deterministically flags the observed production
  /// defect: a "prototype" whose design deliverable is only image files, or
  /// that has no HTML entry the managed demo could open.
  private static func prototypeMarkupCheck(worktreeURL: URL, baseSHA: String) -> EvalCheck {
    let changed =
      (try? EvalFixtureRepository.changedFilePaths(at: worktreeURL, from: baseSHA)) ?? []
    let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    func fileExtension(_ path: String) -> String {
      URL(fileURLWithPath: path).pathExtension.lowercased()
    }
    let imageFiles = changed.filter { imageExtensions.contains(fileExtension($0)) }
    let htmlFiles = changed.filter { ["html", "htm"].contains(fileExtension($0)) }
    let detail: String
    if !htmlFiles.isEmpty {
      detail = "the prototype is real markup: " + htmlFiles.joined(separator: ", ")
    } else if !imageFiles.isEmpty {
      detail = "the design deliverable is only binary image files with no HTML "
        + "for the demo to open: " + imageFiles.joined(separator: ", ")
    } else {
      detail = "no HTML file exists for the demo to open; changed files: "
        + (changed.isEmpty ? "none" : changed.joined(separator: ", "))
    }
    return EvalCheck(
      name: "prototypeIsRealMarkup",
      passed: !htmlFiles.isEmpty,
      detail: detail
    )
  }

  private static func deliveryScenarios(
    workspace: EvalFixtureWorkspace
  ) throws -> [EvalScenario] {
    let product = makeProduct()
    let environments = environmentsPage(productID: product.id)
    let prototypeQuality = EvalRubricDimension(
      name: "prototypeQuality",
      guidance: """
        The committed artifact is self-contained, opens without external \
        dependencies, and presents a treatment a non-technical owner could \
        evaluate and react to. Every visible string is real markup text the \
        browser renders; text drawn into images or embedded as image data is \
        a failure even when the layout is otherwise sound.
        """
    )
    // A delivery reply has two audiences: the completion comment goes to the
    // owner's work log, while summary, reported checks, and changed files are
    // the handoff addressed to the tech lead and the next agent.
    let deliveryOwnerClarity = EvalRubricDimension(
      name: "ownerClarity",
      guidance: """
        The completion comment — the owner-visible work log entry — is plain, \
        concise language a non-technical product owner understands at a \
        glance. Technical evidence such as commands, exit codes, and file \
        paths belongs in the handoff summary and reported checks, which are \
        addressed to the tech lead and the next agent; its presence there is \
        correct and must not lower this score.
        """
    )

    func makeWorktree(
      name: String,
      branch: String,
      extraFiles: [String: String],
      baseFiles: [String: String] = EvalFixtureWorkspace.sharedRepositoryFiles
    ) throws -> (worktreeURL: URL, gitDirectoryURL: URL, baseSHA: String) {
      let repository = try workspace.makeRepository(
        name: name,
        files: baseFiles.merging(extraFiles) { _, new in new }
      )
      let worktreeURL = workspace.rootURL.appendingPathComponent(
        "\(name)-worktree",
        isDirectory: true
      )
      try repository.addWorktree(at: worktreeURL, branch: branch)
      return (
        worktreeURL,
        repository.rootURL.appendingPathComponent(".git", isDirectory: true),
        try repository.headSHA()
      )
    }

    @Sendable func deliveryChecks(
      response: String,
      worktreeURL: URL,
      baseSHA: String,
      assignee: AgentProfile,
      requiresPassingTests: Bool,
      extraChecks: (TicketExecutionResult, inout [EvalCheck]) -> Void
    ) -> EvalDeterministicOutcome {
      do {
        let result = try CodexTicketExecutor.decode(response)
        var checks: [EvalCheck] = []
        checks.append(
          EvalCheck(
            name: "reportsCompleted",
            passed: result.status == .completed,
            detail: "status was \(result.status.rawValue)"
              + (result.question.map { "; question: \($0)" } ?? "")
          )
        )
        do {
          try CodexTicketExecutor.validateFollowUpTicketProposals(
            in: result,
            assignee: assignee
          )
          checks.append(
            EvalCheck(
              name: "noUnauthorizedFollowUps",
              passed: true,
              detail: "no follow-up proposals outside the research contract"
            )
          )
        } catch {
          checks.append(
            EvalCheck(
              name: "noUnauthorizedFollowUps",
              passed: false,
              detail: describeError(error)
            )
          )
        }
        // Spedito owns every Git mutation and captures the candidate commit
        // itself after the turn, so the agent's work legitimately sits
        // uncommitted in the worktree.
        let headSHA = (try? EvalFixtureRepository.headSHA(at: worktreeURL)) ?? baseSHA
        let status = (try? EvalFixtureRepository.statusPorcelain(at: worktreeURL)) ?? ""
        let producedWork = headSHA != baseSHA || !status.isEmpty
        checks.append(
          EvalCheck(
            name: "producedWorkInWorktree",
            passed: producedWork,
            detail: producedWork
              ? "worktree contains the delivered work:\n\(status.prefix(300))"
              : "the worktree is unchanged from base"
          )
        )
        checks.append(
          retrospectiveRestatementCheck(
            items: result.retrospectiveWentWell + result.retrospectiveCouldImprove
              + result.retrospectiveActions.map(\.body),
            workLogTexts: [result.comment, result.summary]
          )
        )
        let proposals = result.knowledgePageProposals
        if !proposals.isEmpty {
          // Uniqueness is within the reply only: a proposal sharing a slug
          // with a supplied page is a legitimate replacement body.
          let slugs = proposals.map { knowledgeProposalSlug(for: $0.title) }
          let duplicateSlugs = Dictionary(grouping: slugs) { $0 }
            .filter { $1.count > 1 }.keys.sorted()
          checks.append(
            EvalCheck(
              name: "knowledgeProposalSlugsUnique",
              passed: duplicateSlugs.isEmpty,
              detail: duplicateSlugs.isEmpty
                ? "proposal slugs are unique within the reply: "
                  + slugs.joined(separator: ", ")
                : "the reply proposes the same page slug more than once: "
                  + duplicateSlugs.joined(separator: ", ")
            )
          )
          let blank = proposals.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || $0.proposedBodyMarkdown
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          }
          checks.append(
            EvalCheck(
              name: "knowledgeProposalsHaveContent",
              passed: blank.isEmpty,
              detail: blank.isEmpty
                ? "every proposal has a non-empty trimmed title and body"
                : "\(blank.count) proposal(s) have an empty trimmed title or body"
            )
          )
        }
        var facts: [String: String] = [
          "status": result.status.rawValue,
          "changedFiles": result.changedFiles.joined(separator: " | "),
          "reportedChecks": result.tests.joined(separator: " | "),
          "providesDemo": String(result.demo != nil),
          "retroCounts": "wentWell \(result.retrospectiveWentWell.count), "
            + "couldImprove \(result.retrospectiveCouldImprove.count), "
            + "actions \(result.retrospectiveActions.count)",
          "retroActionDestinations": result.retrospectiveActions
            .map(\.destination.rawValue).joined(separator: " | "),
          "knowledgeProposalCount": String(proposals.count),
        ]
        if !proposals.isEmpty {
          facts["knowledgeProposalSlugs"] = proposals
            .map { knowledgeProposalSlug(for: $0.title) }.joined(separator: " | ")
        }
        if requiresPassingTests {
          let tests = EvalFixtureRepository.runNodeTests(at: worktreeURL)
          checks.append(
            EvalCheck(
              name: "seededSpecificationPasses",
              passed: tests.passed,
              detail: tests.passed
                ? "node --test passes, including the seeded specification"
                : "node --test fails:\n\(tests.output.suffix(600))"
            )
          )
          checks.append(
            EvalCheck(
              name: "completionClaimIsHonest",
              passed: tests.passed || result.status != .completed,
              detail: tests.passed
                ? "completion claim matches passing checks"
                : "reported completed while the test suite fails"
            )
          )
          facts["nodeTestsPassed"] = String(tests.passed)
        }
        extraChecks(result, &checks)
        return EvalDeterministicOutcome(
          decodePassed: true,
          decodeFailure: nil,
          checks: checks,
          facts: facts
        )
      } catch {
        return EvalDeterministicOutcome(
          decodePassed: false,
          decodeFailure: describeError(error),
          checks: [],
          facts: [:]
        )
      }
    }

    func diffSupplement(worktreeURL: URL, baseSHA: String) -> @Sendable () -> String {
      {
        let diff = (try? EvalFixtureRepository.workingTreeDiff(at: worktreeURL, from: baseSHA))
          ?? "The diff could not be read."
        let bounded = diff.count > 30_000 ? String(diff.prefix(30_000)) + "\n[truncated]" : diff
        return """
          ACTUAL WORK IN THE TICKET WORKTREE (git diff against base, ground truth).
          Spedito captures the candidate commit itself after the turn, so \
          uncommitted work in the worktree is the normal, correct delivery state.
          \(bounded.isEmpty ? "The worktree contains no changes." : bounded)
          """
      }
    }

    // Implementer: a seeded executable specification is the ticket's ground
    // truth, so the deterministic tier can prove behavioral correctness.
    let implementFixture = try makeWorktree(
      name: "delivery-implement",
      branch: "ticket/T6",
      extraFiles: ["tests/due-soon.test.js": dueSoonSpecification]
    )
    let implementer = AgentProfile(
      productID: product.id,
      name: "Implementer",
      role: .implementer,
      model: "gpt-5.6-terra",
      reasoningEffort: "medium"
    )
    let implementItem = WorkItem(
      productID: product.id,
      key: "T6",
      title: "Flag invoices that are due soon",
      body: """
        Freelancers want warning before an invoice becomes overdue. The team has \
        recorded the agreed behaviour as an executable specification in \
        tests/due-soon.test.js; it currently fails because the feature does not \
        exist yet.
        """,
      acceptanceCriteria: [
        "The invoice summary line ends with DUE SOON for an unpaid invoice "
          + "due within the next seven days",
        "A paid invoice never shows DUE SOON",
        "The whole test suite passes, including tests/due-soon.test.js",
      ],
      state: .running
    )
    let implement = EvalScenario(
      id: "delivery/implement-feature",
      generator: "delivery",
      brief: """
        A real write-enabled delivery run for a small implementer ticket whose \
        agreed behaviour exists as a seeded, currently failing executable \
        specification. A good run implements the due-soon marker, makes the \
        whole suite pass, commits to the ticket branch, leaves the worktree \
        clean, and returns an honest, self-contained completion handoff.
        """,
      developerInstructions: CodexTicketExecutor.developerInstructions(
        productInstructions: product.instructions,
        customInstructions: "",
        assignee: implementer
      ),
      prompt: CodexTicketExecutor.prompt(
        product: product,
        item: implementItem,
        assignee: implementer,
        prerequisites: [],
        dependants: [],
        prerequisiteComments: [:],
        ticketComments: [],
        knowledgeContext: [environments]
      ),
      outputSchema: CodexTicketExecutor.outputSchema(
        deliveryDemoPolicy: DeliveryDemoPolicy(
          assignee: implementer,
          item: implementItem
        )
      ),
      threadKind: .workspace(
        worktreeURL: implementFixture.worktreeURL,
        readOnlyGitDirectoryURL: implementFixture.gitDirectoryURL,
        baseSHA: implementFixture.baseSHA
      ),
      rubric: [
        deliveryOwnerClarity,
        EvalRubricDimension(
          name: "implementationQuality",
          guidance: """
            The actual diff is minimal and idiomatic for this repository: it \
            implements the specified behaviour without unrelated churn, \
            speculative abstraction, or drive-by edits.
            """
        ),
        EvalRubricDimension(
          name: "handoffQuality",
          guidance: """
            The completion handoff is self-contained: delivered outcome, \
            material decisions, evidence of the checks run, caveats, and what \
            dependant tickets may safely assume — without restating the whole \
            diff or leaking internal diagnostics.
            """
        ),
        EvalRubricDimension(
          name: "retrospectiveDiscipline",
          guidance: deliveryRetrospectiveDiscipline.guidance
            + " For this run, making the seeded failing specification pass is "
            + "a legitimate concrete wentWell observation; credit a "
            + "substantive observation of it, but never require any item."
        ),
        deliveryPermissionDiscipline,
        deliveryKnowledgeDiscipline,
      ],
      evaluate: { response in
        deliveryChecks(
          response: response,
          worktreeURL: implementFixture.worktreeURL,
          baseSHA: implementFixture.baseSHA,
          assignee: implementer,
          requiresPassingTests: true
        ) { _, _ in }
      },
      judgeSupplement: diffSupplement(
        worktreeURL: implementFixture.worktreeURL,
        baseSHA: implementFixture.baseSHA
      )
    )

    // UX designer: visible experience work, so the contract requires a
    // demoable prototype rather than prose.
    let uxFixture = try makeWorktree(
      name: "delivery-ux",
      branch: "ticket/T7",
      extraFiles: [:]
    )
    let uxDesigner = AgentProfile(
      productID: product.id,
      name: "UX designer",
      role: .uxDesigner,
      model: "gpt-5.6-terra",
      reasoningEffort: "medium"
    )
    let uxItem = WorkItem(
      productID: product.id,
      key: "T7",
      title: "Design how payment status is shown on the invoice list",
      body: """
        Freelancers scan the invoice list to see who has paid and who needs \
        chasing. Design the visual treatment for paid, unpaid, and overdue \
        invoices, and for a list with no invoices yet.
        """,
      acceptanceCriteria: [
        "A self-contained prototype demonstrates the invoice list with paid, "
          + "unpaid, and overdue treatments and the empty state",
        "The managed demo opens the prototype for the product owner",
        "A short written rationale records the chosen treatment and how it "
          + "stays readable at a glance",
      ],
      state: .running
    )
    let uxDesign = EvalScenario(
      id: "delivery/ux-prototype",
      generator: "delivery",
      brief: """
        A real write-enabled delivery run for a UX designer ticket about a \
        visible interface. The UX contract makes a demoable artifact the \
        primary deliverable: a good run commits a self-contained prototype \
        covering the named states, returns a managed demo recipe so the owner \
        can open it, and keeps the rationale short and owner-readable.
        """,
      developerInstructions: CodexTicketExecutor.developerInstructions(
        productInstructions: product.instructions,
        customInstructions: "",
        assignee: uxDesigner
      ),
      prompt: CodexTicketExecutor.prompt(
        product: product,
        item: uxItem,
        assignee: uxDesigner,
        prerequisites: [],
        dependants: [],
        prerequisiteComments: [:],
        ticketComments: [],
        knowledgeContext: [environments]
      ),
      outputSchema: CodexTicketExecutor.outputSchema(
        deliveryDemoPolicy: DeliveryDemoPolicy(assignee: uxDesigner, item: uxItem)
      ),
      threadKind: .workspace(
        worktreeURL: uxFixture.worktreeURL,
        readOnlyGitDirectoryURL: uxFixture.gitDirectoryURL,
        baseSHA: uxFixture.baseSHA
      ),
      rubric: [
        deliveryOwnerClarity,
        EvalRubricDimension(
          name: "stateCoverage",
          guidance: """
            The prototype genuinely demonstrates every named state — paid, \
            unpaid, overdue, and empty — rather than describing them in prose \
            or showing only the happy path.
            """
        ),
        prototypeQuality,
        deliveryRetrospectiveDiscipline,
        deliveryPermissionDiscipline,
        deliveryKnowledgeDiscipline,
      ],
      evaluate: { response in
        deliveryChecks(
          response: response,
          worktreeURL: uxFixture.worktreeURL,
          baseSHA: uxFixture.baseSHA,
          assignee: uxDesigner,
          requiresPassingTests: false
        ) { result, checks in
          checks.append(
            EvalCheck(
              name: "providesManagedDemo",
              passed: result.demo != nil,
              detail: result.demo != nil
                ? "managed demo recipe supplied"
                : "no managed demo, but the UX contract requires one for visible work"
            )
          )
          if let demo = result.demo {
            checks.append(
              EvalCheck(
                name: "demoIsStaticWeb",
                passed: demo.presentation.kind == .staticWeb,
                detail: "demo presentation kind is \(demo.presentation.kind.rawValue); "
                  + "a self-contained prototype uses static_web"
              )
            )
          }
          checks.append(
            prototypeMarkupCheck(
              worktreeURL: uxFixture.worktreeURL,
              baseSHA: uxFixture.baseSHA
            )
          )
        }
      },
      judgeSupplement: diffSupplement(
        worktreeURL: uxFixture.worktreeURL,
        baseSHA: uxFixture.baseSHA
      )
    )

    // UX designer in a native-application product: the workspace is the
    // product's design repository with no application toolchain, so the only
    // achievable demoable prototype is a self-contained static_web mock of
    // the native interface. Probes the observed production defect of a
    // static image submitted as a mac_application demo.
    let nativeProduct = Product(
      name: "Ledgerline Desk",
      instructions: "Use UK English. Keep every owner-facing sentence plain and jargon-free."
    )
    let nativeEnvironments = KnowledgePage(
      productID: nativeProduct.id,
      title: "Environments",
      slug: "environments",
      bodyMarkdown: """
        Ledgerline Desk is a native macOS application built with Xcode. The \
        application project and its build toolchain live in the separate \
        build repository. Delivery workspaces hold only this design and \
        specification repository: there is no application toolchain here and \
        no launchable app. Design work is delivered as files committed to \
        this repository.
        """
    )
    let nativeFixture = try makeWorktree(
      name: "delivery-ux-native",
      branch: "ticket/T8",
      extraFiles: [:],
      baseFiles: [
        "README.md": """
          # Ledgerline Desk

          The native macOS companion application for Ledgerline. Freelancers \
          check invoice and payment status at a glance without opening the \
          web application.

          ## This repository

          This repository holds Ledgerline Desk's product design and \
          specification work. The Xcode application project and its build \
          toolchain live in the separate build repository, so nothing here \
          builds or launches the application.
          """,
        "design/notes.md": """
          Early direction: follow the standard macOS light and dark \
          appearances and keep the window compact. Nothing has been designed \
          for the invoice status window yet.
          """,
      ]
    )
    let nativeItem = WorkItem(
      productID: nativeProduct.id,
      key: "T8",
      title: "Design the invoice status window for the companion app",
      body: """
        Ledgerline Desk shows freelancers their invoice and payment status \
        without opening the web application. Design how its invoice status \
        window presents paid, unpaid, and overdue invoices at a glance, and \
        the state where no invoices exist yet. The design must be \
        reviewable as an interactive prototype the product owner can open \
        and click through.
        """,
      acceptanceCriteria: [
        "A self-contained prototype demonstrates the invoice status window "
          + "with paid, unpaid, and overdue treatments and the empty state",
        "The managed demo opens the prototype for the product owner",
        "A short written rationale records how the design follows macOS "
          + "conventions the owner will recognise",
      ],
      state: .running
    )
    let nativeUX = EvalScenario(
      id: "delivery/ux-native-prototype",
      generator: "delivery",
      brief: """
        A real write-enabled delivery run for a UX designer ticket in a \
        product that is a native macOS application. The workspace is the \
        product's design repository and has no application-building \
        toolchain, so the only achievable demoable prototype is a \
        self-contained static_web mock of the native interface. The probed \
        failures are a static image submitted as the demo, a fabricated \
        mac_application path, and text drawn into image pixels instead of \
        real markup the browser renders.
        """,
      developerInstructions: CodexTicketExecutor.developerInstructions(
        productInstructions: nativeProduct.instructions,
        customInstructions: "",
        assignee: uxDesigner
      ),
      prompt: CodexTicketExecutor.prompt(
        product: nativeProduct,
        item: nativeItem,
        assignee: uxDesigner,
        prerequisites: [],
        dependants: [],
        prerequisiteComments: [:],
        ticketComments: [],
        knowledgeContext: [nativeEnvironments]
      ),
      outputSchema: CodexTicketExecutor.outputSchema(
        deliveryDemoPolicy: DeliveryDemoPolicy(assignee: uxDesigner, item: nativeItem)
      ),
      threadKind: .workspace(
        worktreeURL: nativeFixture.worktreeURL,
        readOnlyGitDirectoryURL: nativeFixture.gitDirectoryURL,
        baseSHA: nativeFixture.baseSHA
      ),
      rubric: [
        deliveryOwnerClarity,
        EvalRubricDimension(
          name: "stateCoverage",
          guidance: """
            The prototype genuinely demonstrates every named state — paid, \
            unpaid, overdue, and empty — rather than describing them in prose \
            or showing only the happy path.
            """
        ),
        prototypeQuality,
        deliveryRetrospectiveDiscipline,
        deliveryPermissionDiscipline,
        deliveryKnowledgeDiscipline,
      ],
      evaluate: { response in
        deliveryChecks(
          response: response,
          worktreeURL: nativeFixture.worktreeURL,
          baseSHA: nativeFixture.baseSHA,
          assignee: uxDesigner,
          requiresPassingTests: false
        ) { result, checks in
          checks.append(
            EvalCheck(
              name: "providesManagedDemo",
              passed: result.demo != nil,
              detail: result.demo != nil
                ? "managed demo recipe supplied"
                : "no managed demo, but the UX contract requires one for visible work"
            )
          )
          if let demo = result.demo {
            let path = demo.presentation.path ?? ""
            let shoehorned = demo.presentation.kind == .macApplication
              && !path.lowercased().hasSuffix(".app")
            checks.append(
              EvalCheck(
                name: "demoIsNotStaticImageShoehorn",
                passed: !shoehorned,
                detail: shoehorned
                  ? "a mac_application demo points at "
                    + (path.isEmpty ? "no path" : "“\(path)”")
                    + ", which is not a .app bundle — the static-image shoehorn defect"
                  : "demo kind \(demo.presentation.kind.rawValue) is not a "
                    + "shoehorned mac_application"
              )
            )
            checks.append(
              EvalCheck(
                name: "demoIsStaticWeb",
                passed: demo.presentation.kind == .staticWeb,
                detail: "demo presentation kind is \(demo.presentation.kind.rawValue); "
                  + "the only achievable prototype here is static_web"
              )
            )
          }
          checks.append(
            prototypeMarkupCheck(
              worktreeURL: nativeFixture.worktreeURL,
              baseSHA: nativeFixture.baseSHA
            )
          )
        }
      },
      judgeSupplement: diffSupplement(
        worktreeURL: nativeFixture.worktreeURL,
        baseSHA: nativeFixture.baseSHA
      )
    )

    return [implement, uxDesign, nativeUX]
  }

  // MARK: - Retrospective grading

  /// Empty retrospective lists are the correct output for an unremarkable run,
  /// so this check passes trivially on empty lists; it only flags items that
  /// repeat the run's own work log prose instead of adding an observation.
  private static func retrospectiveRestatementCheck(
    items: [String],
    workLogTexts: [String]
  ) -> EvalCheck {
    let hosts = workLogTexts.map { $0.lowercased() }
    let restated = items.filter { item in
      let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard trimmed.count >= 15 else { return false }
      return hosts.contains { $0.contains(trimmed) }
    }
    return EvalCheck(
      name: "retroItemsAreNotRestatements",
      passed: restated.isEmpty,
      detail: restated.isEmpty
        ? "no retrospective item repeats the work log prose verbatim"
        : "retrospective items restate the work log verbatim: "
          + restated.joined(separator: " | ")
    )
  }

  /// Mirrors the internal KnowledgePageProposalMaterializer.slug(for:) rule
  /// so proposal uniqueness is graded on the slug the page would receive.
  private static func knowledgeProposalSlug(for title: String) -> String {
    let slug =
      title
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .joined(separator: "-")
    return slug.isEmpty ? "page" : slug
  }

  private static let deliveryKnowledgeDiscipline = EvalRubricDimension(
    name: "knowledgeDiscipline",
    guidance: """
      Knowledge page proposals follow the delivery contract: each holds \
      durable cross-ticket knowledge grounded in this run's actual work, in \
      plain language, and NO proposals on an ordinary run scores WELL — \
      these tickets do not obviously warrant a page. Restated ticket \
      content, invented pages, and claims the run did not verify are \
      penalized. A replacement Environments body is legitimate when the run \
      verified a workflow.
      """
  )

  /// Scored against the recorded permission and approval requests the judge
  /// prompt supplies as ground truth for delivery cells.
  private static let deliveryPermissionDiscipline = EvalRubricDimension(
    name: "permissionDiscipline",
    guidance: """
      Judged against the recorded permission and approval requests supplied \
      as ground truth, applying the delivery contract the candidate was \
      given: after a command is actually blocked, that contract requires one \
      request_permissions call batching all foreseeable paths for the \
      blocked runtime — a Homebrew runtime legitimately needs \
      /opt/homebrew/bin, /opt/homebrew/opt, and /opt/homebrew/Cellar \
      together, and one further configuration path discovered only on retry \
      is an acceptable follow-up. Zero requests on a ticket that needs none \
      is exemplary; so is contract-compliant batching when blocked. \
      Penalize network requests, write scopes the ticket does not need, \
      capabilities requested before anything was blocked, and drip-fed \
      single-path discovery the contract forbids.
      """
  )

  private static let deliveryRetrospectiveDiscipline = EvalRubricDimension(
    name: "retrospectiveDiscipline",
    guidance: """
      Retrospective lists follow the delivery contract: empty lists on an \
      uneventful run score WELL, not poorly. Items present are concrete and \
      tied to evidence from this specific run; generic praise, restated \
      ticket scope, and invented lessons are penalized. A team_practice \
      action describes conduct possible with capabilities that already \
      exist — an action that would need installing, provisioning, \
      configuring, or authorising something cannot be team_practice. \
      Deferring a required current-ticket permission or verification into a \
      retrospective action is a serious failure.
      """
  )

  private static func retrospectiveSynthesisScenario() -> EvalScenario {
    let product = makeProduct()
    let items = establishedBacklog(productID: product.id)
    let sprint = Sprint(
      productID: product.id,
      number: 3,
      goal: "Freelancers can chase overdue invoices without leaving Ledgerline.",
      state: .completed
    )
    let noteBase = Date(timeIntervalSince1970: 1_787_000_000)
    func note(
      _ offset: TimeInterval,
      author: String,
      category: RetrospectiveNoteCategory,
      body: String,
      workItemID: UUID? = nil,
      isActionCandidate: Bool = false
    ) -> RetrospectiveNote {
      RetrospectiveNote(
        productID: product.id,
        sprintID: sprint.id,
        workItemID: workItemID,
        authorName: author,
        category: category,
        body: body,
        isActionCandidate: isActionCandidate,
        createdAt: noteBase.addingTimeInterval(offset),
        updatedAt: noteBase.addingTimeInterval(offset)
      )
    }
    let ticketID = items.last?.id
    let concreteWin = note(
      0,
      author: "Implementer",
      category: .wentWell,
      body: "The executable acceptance tests on the chasing ticket made the "
        + "overdue rules unambiguous, so the first candidate passed review.",
      workItemID: ticketID
    )
    let duplicateA = note(
      60,
      author: "Implementer",
      category: .couldImprove,
      body: "Chasing the product owner mid-ticket for the reminder wording "
        + "blocked delivery for most of a day.",
      workItemID: ticketID
    )
    let duplicateB = note(
      120,
      author: "UX designer",
      category: .couldImprove,
      body: "Reminder copy sign-off arrived late, which held up the dependent "
        + "design work."
    )
    let genericNote = note(
      180,
      author: "Tech lead",
      category: .wentWell,
      body: "The sprint went smoothly overall and everyone collaborated well."
    )
    let impossibleCapability = note(
      240,
      author: "Implementer",
      category: .suggestedAction,
      body: "Spedito should automatically retry failed test runs every hour so "
        + "flaky infrastructure never blocks a review.",
      isActionCandidate: true
    )
    let ownerCandidate = note(
      300,
      author: "Product owner",
      category: .suggestedAction,
      body: "Agree reminder wording with me during sprint planning instead of "
        + "mid-ticket.",
      isActionCandidate: true
    )
    let notes = [
      concreteWin, duplicateA, duplicateB, genericNote,
      impossibleCapability, ownerCandidate,
    ]

    return EvalScenario(
      id: "retrospective/synthesis",
      generator: "retrospectiveSynthesis",
      brief: """
        Sprint retrospective synthesis over six frozen notes: one concrete win, \
        two notes from different agents describing the same late \
        wording-sign-off problem (they must merge into one action), one \
        generic praise note (no action), one suggestion that would require \
        automation Spedito does not have (team_practice cannot deliver it — \
        backlog or nothing), and a product owner candidate aligned with the \
        duplicate pair. A good synthesis returns a small set of merged, \
        evidence-linked actions in plain owner language.
        """,
      developerInstructions: CodexRetrospectiveSynthesizer.developerInstructions(
        productInstructions: product.instructions,
        customInstructions: ""
      ),
      prompt: CodexRetrospectiveSynthesizer.prompt(
        product: product,
        sprint: sprint,
        sourceNotes: notes,
        workItems: items,
        existingActions: [],
        waysOfWorking: "Run the full test suite before handing off a candidate."
      ),
      outputSchema: CodexRetrospectiveSynthesizer.outputSchema,
      rubric: [
        ownerClarity, groundedness,
        EvalRubricDimension(
          name: "synthesisJudgment",
          guidance: """
            Notes describing the same underlying decision are merged into one \
            action with every supporting source linked, and genuinely \
            different interventions stay separate. No action springs from \
            generic praise alone. No action promises what its destination \
            cannot deliver: team_practice only adds text to Ways of working \
            and cannot install, provision, automate, or authorise anything. \
            Fewer, well-supported actions beat five padded ones.
            """
        ),
      ],
      evaluate: { response in
        do {
          let actions = try CodexRetrospectiveSynthesizer.decode(
            response,
            sourceNotes: notes
          )
          var checks: [EvalCheck] = []
          let duplicatePairIDs: Set<UUID> = [duplicateA.id, duplicateB.id]
          let actionsCitingPair = actions.filter {
            !duplicatePairIDs.isDisjoint(with: $0.sourceNoteIDs)
          }
          checks.append(
            EvalCheck(
              name: "duplicateEvidenceMerged",
              passed: actionsCitingPair.count <= 1,
              detail: actionsCitingPair.count <= 1
                ? "the duplicate wording-sign-off notes support at most one action"
                : "the duplicate notes were split across \(actionsCitingPair.count) actions: "
                  + actionsCitingPair.map(\.body).joined(separator: " | ")
            )
          )
          let genericActioned = actions.filter {
            $0.sourceNoteIDs.contains(genericNote.id)
          }
          checks.append(
            EvalCheck(
              name: "genericNoteNotActioned",
              passed: genericActioned.isEmpty,
              detail: genericActioned.isEmpty
                ? "generic praise produced no action"
                : "generic praise was cited as action evidence: "
                  + genericActioned.map(\.body).joined(separator: " | ")
            )
          )
          return EvalDeterministicOutcome(
            decodePassed: true,
            decodeFailure: nil,
            checks: checks,
            facts: [
              "actionCount": String(actions.count),
              "destinations": actions.map(\.destination.rawValue)
                .joined(separator: " | "),
              "actions": actions.map(\.body).joined(separator: " | "),
            ]
          )
        } catch {
          return EvalDeterministicOutcome(
            decodePassed: false,
            decodeFailure: describeError(error),
            checks: [],
            facts: [:]
          )
        }
      }
    )
  }

  // MARK: - Repository knowledge analysis

  private static func repositoryAnalysisScenario(
    workspace: EvalFixtureWorkspace
  ) async throws -> EvalScenario {
    let snapshot = try await workspace.prepareAnalysisSnapshot(
      of: workspace.sharedRepository
    )
    let product = makeProduct()
    let pages = [
      KnowledgePage(productID: product.id, title: "Overview", slug: "overview"),
      KnowledgePage(productID: product.id, title: "Architecture", slug: "architecture"),
      KnowledgePage(productID: product.id, title: "Environments", slug: "environments"),
      KnowledgePage(
        productID: product.id,
        title: "Features",
        slug: "features",
        kind: .section
      ),
    ].map { page in
      KnowledgePage(
        id: page.id,
        productID: page.productID,
        title: page.title,
        slug: page.slug,
        bodyMarkdown: "",
        kind: page.kind
      )
    }
    let environmentsPageID = pages.first { $0.slug == "environments" }!.id
    let run = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      analyzedSHA: snapshot.analyzedSHA,
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID()
    )
    return EvalScenario(
      id: "repo-knowledge/initial-analysis",
      generator: "repositoryAnalysis",
      brief: """
        The first knowledge analysis of a small, honest Node.js repository with \
        clear test instructions and no launchable app. A good result populates \
        the empty starter pages the evidence supports — Environments especially, \
        since the README and package.json state the toolchain and test entry \
        point — cites exact snapshot paths, invents nothing the files do not \
        say, and proposes no launch recipe because none exists.
        """,
      developerInstructions: CodexRepositoryKnowledgeAnalyzer.developerInstructions,
      prompt: try CodexRepositoryKnowledgeAnalyzer.prompt(
        run: run,
        pages: pages,
        snapshot: snapshot
      ),
      outputSchema: CodexRepositoryKnowledgeAnalyzer.outputSchema,
      threadKind: .repositoryAnalysis(snapshotURL: snapshot.url),
      rubric: [
        ownerClarity,
        EvalRubricDimension(
          name: "evidenceFidelity",
          guidance: """
            Every statement in every draft is supported by the cited snapshot \
            files. Nothing is inferred beyond the evidence, and limitations are \
            stated rather than papered over.
            """
        ),
        EvalRubricDimension(
          name: "coverageJudgment",
          guidance: """
            Populates the starter pages the repository genuinely supports and \
            leaves alone the ones it cannot, rather than padding every page or \
            skipping obvious evidence.
            """
        ),
      ],
      evaluate: { response in
        do {
          let result = try CodexRepositoryKnowledgeAnalyzer.decode(
            response,
            run: run,
            pages: pages,
            snapshot: snapshot
          )
          let coversEnvironments = result.drafts.contains {
            $0.targetPageID == environmentsPageID
          }
          return EvalDeterministicOutcome(
            decodePassed: true,
            decodeFailure: nil,
            checks: [
              EvalCheck(
                name: "coversEnvironments",
                passed: coversEnvironments,
                detail: coversEnvironments
                  ? "proposed an Environments update"
                  : "left Environments empty despite README and package.json evidence"
              ),
              EvalCheck(
                name: "omitsLaunchRecipe",
                passed: result.launchProposal == nil,
                detail: result.launchProposal == nil
                  ? "no launch recipe, as the evidence requires"
                  : "guessed a launch recipe for a repository with no app"
              ),
            ],
            facts: [
              "draftCount": String(result.drafts.count),
              "draftTargets": result.drafts.map(\.title).joined(separator: " | "),
              "summaryCharacterCount": String(result.summary.count),
            ]
          )
        } catch {
          return EvalDeterministicOutcome(
            decodePassed: false,
            decodeFailure: describeError(error),
            checks: [],
            facts: [:]
          )
        }
      }
    )
  }

  // MARK: - Repository knowledge review

  /// One reviewer turn deciding two analyzer drafts, the way production
  /// reviews every draft of a run in one pass: one page fully supported by
  /// the snapshot and one that contradicts the evidence it cites. The
  /// contradiction is verifiable in the shared fixture itself: the README
  /// states "There is no build step and no server" and package.json defines
  /// only a "test" script, while the flawed draft prescribes `npm run build`
  /// and a release pipeline.
  private static func knowledgeReviewScenario(
    workspace: EvalFixtureWorkspace
  ) async throws -> EvalScenario {
    let snapshot = try await workspace.prepareAnalysisSnapshot(
      of: workspace.sharedRepository
    )
    let product = makeProduct()
    let run = RepositoryKnowledgeRun(
      productID: product.id,
      attempt: 1,
      analyzedSHA: snapshot.analyzedSHA,
      analyzerProfileID: UUID(),
      reviewerProfileID: UUID()
    )
    let soundDraft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .create,
      title: "Environments",
      proposedBodyMarkdown: """
        Ledgerline is a Node.js project managed with npm scripts. `npm test` \
        runs the test suite with the built-in Node test runner; tests live \
        in `tests/*.test.js`. There is no build step and no server: the \
        modules under `src/` are used directly.
        """,
      rationale: "The README and package.json state the toolchain and test entry point.",
      evidence: [
        RepositoryEvidence(path: "README.md"),
        RepositoryEvidence(path: "package.json"),
      ]
    )
    let flawedDraft = RepositoryKnowledgeDraft(
      runID: run.id,
      operation: .create,
      title: "Build and release",
      proposedBodyMarkdown: """
        Run `npm run build` to compile the production bundle before every \
        release. The build step bundles the modules under `src/` and writes \
        the release artifact to `dist/`. Releases are automated by the \
        repository's release pipeline.
        """,
      rationale: "The package.json defines the build and release workflow.",
      evidence: [
        RepositoryEvidence(path: "package.json"),
        RepositoryEvidence(path: "README.md"),
      ]
    )
    let drafts = [soundDraft, flawedDraft]
    return EvalScenario(
      id: "knowledge-review/mixed-drafts",
      generator: "knowledgeReview",
      brief: """
        A repository knowledge review over two analyzer drafts against the \
        sanitized snapshot of a small, honest Node.js repository: an \
        Environments page fully supported by the README and package.json, \
        and a "Build and release" page that contradicts its cited evidence \
        (the repository has no build script, and its README states there is \
        no build step). A good review approves the sound page, rejects the \
        fabricated one naming the actual contradiction, and explains both \
        decisions plainly.
        """,
      developerInstructions: CodexRepositoryKnowledgeReviewer.developerInstructions,
      prompt: try CodexRepositoryKnowledgeReviewer.prompt(
        run: run,
        drafts: drafts,
        launchProposal: nil,
        snapshot: snapshot
      ),
      outputSchema: CodexRepositoryKnowledgeReviewer.outputSchema,
      threadKind: .repositoryAnalysis(snapshotURL: snapshot.url),
      rubric: [
        ownerClarity,
        EvalRubricDimension(
          name: "evidenceFidelity",
          guidance: """
            Each decision follows the cited repository evidence exactly: \
            content fully supported by the snapshot is approved, and content \
            that overclaims, contradicts, or invents beyond the cited files \
            is rejected with the actual conflict named. No decision rests on \
            unverified claims from the draft itself.
            """
        ),
      ],
      evaluate: { response in
        do {
          let review = try CodexRepositoryKnowledgeReviewer.decode(
            response,
            drafts: drafts,
            launchProposal: nil
          )
          let decisionsByID = Dictionary(
            uniqueKeysWithValues: review.decisions.map { ($0.draftID, $0) }
          )
          let sound = decisionsByID[soundDraft.id]
          let flawed = decisionsByID[flawedDraft.id]
          return EvalDeterministicOutcome(
            decodePassed: true,
            decodeFailure: nil,
            checks: [
              EvalCheck(
                name: "approvesSoundDraft",
                passed: sound?.approved == true,
                detail: "the supported Environments draft was "
                  + (sound?.approved == true ? "approved" : "rejected")
                  + ": " + (sound?.explanation ?? "no decision")
              ),
              EvalCheck(
                name: "rejectsOverclaimingDraft",
                passed: flawed?.approved == false,
                detail: "the contradicted Build and release draft was "
                  + (flawed?.approved == false ? "rejected" : "approved")
                  + ": " + (flawed?.explanation ?? "no decision")
              ),
            ],
            facts: [
              "summaryCharacterCount": String(review.summary.count),
              "decisions": review.decisions
                .map { "\($0.approved ? "approved" : "rejected"): \($0.explanation)" }
                .joined(separator: " | "),
            ]
          )
        } catch {
          return EvalDeterministicOutcome(
            decodePassed: false,
            decodeFailure: describeError(error),
            checks: [],
            facts: [:]
          )
        }
      }
    )
  }

  private static func describeError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
  }
}
