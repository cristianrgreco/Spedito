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
  let rubric: [EvalRubricDimension]
  let evaluate: @Sendable (String) -> EvalDeterministicOutcome

  init(
    id: String,
    generator: String,
    brief: String,
    developerInstructions: String,
    prompt: String,
    outputSchema: JSONValue,
    threadKind: EvalThreadKind = .readOnly(workingDirectoryURL: nil),
    rubric: [EvalRubricDimension],
    evaluate: @escaping @Sendable (String) -> EvalDeterministicOutcome
  ) {
    self.id = id
    self.generator = generator
    self.brief = brief
    self.developerInstructions = developerInstructions
    self.prompt = prompt
    self.outputSchema = outputSchema
    self.threadKind = threadKind
    self.rubric = rubric
    self.evaluate = evaluate
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
        Freelancers can send a saved invoice to the client by email as a PDF \
        attachment, directly from Ledgerline.
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
      title: "Invoice reminders",
      goal: """
        Automatically remind a client about an unpaid invoice by email three days \
        after its due date, at most once per invoice.
        """,
      successCriteria: [
        "An unpaid invoice sends exactly one reminder email three days after its due date",
        "Paid invoices never send a reminder",
        "The owner can see whether a reminder was sent for each invoice",
      ],
      constraints: "No third-party email marketing services."
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

    return [greenfield, established]
  }

  private static func evaluateEpicPlan(
    _ response: String,
    existingItems: [WorkItem],
    extraChecks: (EpicPlanDraft, inout [EvalCheck]) -> Void
  ) -> EvalDeterministicOutcome {
    do {
      let plan = try CodexTicketSuggestionGenerator.decodeEpicPlan(
        response,
        existingItems: existingItems
      )
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
          Answer options are concise, realistic, mutually exclusive, and cover the \
          plausible choice space without steering the owner.
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
        evaluateClarification(response) { reply, checks in
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
        evaluateClarification(response) { reply, checks in
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

    return [vague, resolved]
  }

  private static func evaluateClarification(
    _ response: String,
    extraChecks: (EpicClarificationReply, inout [EvalCheck]) -> Void
  ) -> EvalDeterministicOutcome {
    do {
      let reply = try CodexEpicClarificationGenerator.decode(response)
      var checks: [EvalCheck] = []
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
        retrospectiveWentWell: [],
        retrospectiveCouldImprove: [],
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
                )
              ],
              facts: [
                "decision": review.decision.rawValue,
                "findingCount": String(review.findings.count),
                "findings": review.findings.joined(separator: " | "),
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

  private static func describeError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
  }
}
