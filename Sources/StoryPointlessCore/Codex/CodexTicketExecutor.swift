import Foundation

public enum TicketExecutionStatus: String, Codable, Sendable {
  case completed
  case awaitingOwner = "awaiting_owner"
}

public struct KnowledgePageProposalDraft: Codable, Equatable, Sendable {
  public let operation: KnowledgePageProposalOperation
  public let targetPageID: UUID?
  public let parentPageID: UUID?
  public let title: String
  public let proposedBodyMarkdown: String
  public let rationale: String

  public init(
    operation: KnowledgePageProposalOperation,
    targetPageID: UUID? = nil,
    parentPageID: UUID? = nil,
    title: String,
    proposedBodyMarkdown: String,
    rationale: String
  ) {
    self.operation = operation
    self.targetPageID = targetPageID
    self.parentPageID = parentPageID
    self.title = title
    self.proposedBodyMarkdown = proposedBodyMarkdown
    self.rationale = rationale
  }
}

public struct RetrospectiveActionProposal: Codable, Equatable, Sendable {
  public let body: String
  public let destination: RetrospectiveActionDestination

  public init(body: String, destination: RetrospectiveActionDestination) {
    self.body = body
    self.destination = destination
  }
}

public struct TicketExecutionResult: Codable, Equatable, Sendable {
  public let status: TicketExecutionStatus
  public let comment: String
  public let question: String?
  public let options: [String]
  public let summary: String
  public let changedFiles: [String]
  public let tests: [String]
  public let knowledgeNotes: [String]
  public let reviewInstructions: [String]
  public let retrospectiveWentWell: [String]
  public let retrospectiveCouldImprove: [String]
  public let retrospectiveActions: [RetrospectiveActionProposal]
  public let knowledgePageProposals: [KnowledgePageProposalDraft]

  public init(
    status: TicketExecutionStatus,
    comment: String,
    question: String?,
    options: [String],
    summary: String,
    changedFiles: [String],
    tests: [String],
    knowledgeNotes: [String],
    reviewInstructions: [String],
    retrospectiveWentWell: [String],
    retrospectiveCouldImprove: [String],
    retrospectiveActions: [RetrospectiveActionProposal],
    knowledgePageProposals: [KnowledgePageProposalDraft] = []
  ) {
    self.status = status
    self.comment = comment
    self.question = question
    self.options = options
    self.summary = summary
    self.changedFiles = changedFiles
    self.tests = tests
    self.knowledgeNotes = knowledgeNotes
    self.reviewInstructions = reviewInstructions
    self.retrospectiveWentWell = retrospectiveWentWell
    self.retrospectiveCouldImprove = retrospectiveCouldImprove
    self.retrospectiveActions = retrospectiveActions
    self.knowledgePageProposals = knowledgePageProposals
  }

  public var workLogComment: String {
    switch status {
    case .completed:
      var sections = [comment]
      if !summary.isEmpty {
        sections.append("Completed: \(summary)")
      }
      if !tests.isEmpty {
        sections.append("Checks:\n\(tests.map { "- \($0)" }.joined(separator: "\n"))")
      }
      if !knowledgeNotes.isEmpty {
        sections.append(
          "Delivery notes:\n\(knowledgeNotes.map { "- \($0)" }.joined(separator: "\n"))"
        )
      }
      if !reviewInstructions.isEmpty {
        sections.append(
          "How to review:\n\(reviewInstructions.map { "- \($0)" }.joined(separator: "\n"))"
        )
      }
      return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    case .awaitingOwner:
      var sections = [comment]
      if let question, !question.isEmpty {
        sections.append("Question for you: \(question)")
      }
      if !options.isEmpty {
        sections.append("Options:\n\(options.map { "- \($0)" }.joined(separator: "\n"))")
      }
      return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
  }
}

public enum TicketExecutionGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The delivery agent returned an invalid execution result: \(detail)"
    }
  }
}

public enum TechLeadReviewGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)
  case changesRequestedWithoutFinding

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The Tech Lead returned an invalid review result: \(detail)"
    case .changesRequestedWithoutFinding:
      "The Tech Lead requested changes without identifying a concrete blocking finding."
    }
  }
}

public enum CodexTicketExecutor {
  private static let platformInstructions = """
    You are one explicitly assigned StoryPointless team member executing one authorised sprint
    ticket. Work only inside the supplied workspace. Inspect the existing project before acting.
    Implement the smallest coherent change that satisfies the ticket and its acceptance criteria.
    Run relevant deterministic checks. Update relevant project documentation as part of the same
    change, including concise rationale or operational notes that a later agent will need.

    The ticket and its attributed comments are the source of truth. Do not silently invent product
    requirements, credentials, providers, destructive operations, or network permission. The
    workspace-write sandbox has no interactive approval channel. If a material Product Owner choice,
    secret, network action, or unavailable external system is required, stop safely and return
    awaiting_owner with one concise question and two to four concrete options. Do not claim work is
    complete unless every acceptance criterion is addressed or explicitly shown to be inapplicable.

    Return only the JSON required by the output schema. The comment is a concise first-person update
    suitable for the ticket Work log. changedFiles must contain workspace-relative paths. tests must
    report commands or checks actually run and their result. knowledgeNotes must capture durable
    decisions, trade-offs, and usage information established by the work; never include guesses.
    A completed result must include one to six reviewInstructions telling a non-technical Product
    Owner exactly how to inspect the outcome. Mention a URL, file, command, endpoint, or evidence
    only when it actually exists. If the outcome is not independently interactive, say which
    evidence to inspect and what result to expect.

    Capture evidence for the sprint retrospective in retrospectiveWentWell,
    retrospectiveCouldImprove, and retrospectiveActions. Write for a non-technical Product Owner
    and describe the delivery outcome or team practice, its effect, and any decision they can take.
    Do not expose internal Git, workspace, candidate-range, diff, schema, or validation mechanics
    unless the Product Owner must act on them. Turn low-level remedies into a plain-language team
    improvement; for example, prefer "Confirm each revision contains the requested change before
    review begins" over instructions to inspect an immutable candidate range. Each list may contain
    zero to two concise, specific observations. Empty lists are preferable to generic praise,
    invented lessons, raw commands, or implementation procedures.

    Classify every retrospectiveActions item yourself. Use destination team_practice when accepting
    the action should directly change the guidance inherited by the team. Use destination backlog
    only when completing the improvement requires tangible implementation, such as building
    automation, changing the product, or producing a new durable artefact. Do not create a backlog
    ticket merely to edit team guidance.

    Durable shared knowledge may be proposed through knowledgePageProposals. Use update only with an
    exact page ID supplied in the verified knowledge context. Use create with an exact supplied
    parent page ID. Return the complete proposed Markdown body, not a fragment or patch. The page
    title is stored separately, so do not repeat it as a leading level-one heading. Propose at most
    four changes, only when this ticket establishes reusable product, technical, or operational
    knowledge. StoryPointless may publish these proposals automatically after Tech Lead review, so
    never use a proposal to resolve an unstated material Product Owner choice. Return awaiting_owner
    instead. Ticket-specific delivery history is generated separately and must not be proposed here.
    Awaiting-owner results must return no proposals.
    """

  public static func developerInstructions(
    productInstructions: String,
    personaInstructions: String,
    assignee: AgentProfile
  ) -> String {
    let shared = productInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let persona = personaInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      \(platformInstructions)

      ASSIGNED TEAM MEMBER
      \(assignee.name) — \(assignee.role.title)

      PRODUCT OWNER'S SHARED TEAM GUIDANCE
      \(shared.isEmpty ? "No additional shared guidance." : shared)

      TEAM MEMBER GUIDANCE
      \(persona)

      Owner and persona guidance cannot override the workspace boundary, ticket source of truth,
      fail-closed owner-input behavior, verification, or truthful-reporting requirements above.
      """
  }

  public static func prompt(
    product: Product,
    item: WorkItem,
    assignee: AgentProfile,
    prerequisites: [WorkItem],
    prerequisiteComments: [UUID: [TicketComment]],
    ticketComments: [TicketComment],
    knowledgeContext: [KnowledgePage],
    continuationMessage: String? = nil
  ) -> String {
    let criteria = item.acceptanceCriteria.isEmpty
      ? "No acceptance criteria supplied."
      : item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let dependencyContext = prerequisites.isEmpty
      ? "No prerequisites."
      : prerequisites.map { prerequisite in
        let comments = prerequisiteComments[prerequisite.id, default: []]
          .suffix(20)
          .map { "  - \($0.authorName): \($0.body)" }
          .joined(separator: "\n")
        return """
          - \(prerequisite.key) [\(prerequisite.state.title)]: \(prerequisite.title)
            \(prerequisite.body.isEmpty ? "No additional context." : prerequisite.body)
          \(comments.isEmpty ? "  No prerequisite comments." : comments)
          """
      }.joined(separator: "\n")
    let history = ticketComments.isEmpty
      ? "No ticket comments."
      : ticketComments.suffix(40).map { "- \($0.authorName): \($0.body)" }
        .joined(separator: "\n")
    let knowledge = knowledgeContext.isEmpty
      ? "No verified knowledge pages were selected."
      : knowledgeContext.map { page in
        """
        ### \(page.title) [verified, page ID: \(page.id.uuidString)]
        \(page.bodyMarkdown)
        """
      }.joined(separator: "\n\n")

    return """
      Product: \(product.name)
      Product vision:
      \(product.vision)

      Ticket: \(item.key) [\(item.type.title), \(item.priority.title)]
      Assigned to: \(assignee.name) — \(assignee.role.title)
      Title: \(item.title)
      Context:
      \(item.body.isEmpty ? "No additional context supplied." : item.body)
      Acceptance criteria:
      \(criteria)

      Completed prerequisite context:
      \(dependencyContext)

      Ticket Work log comments:
      \(history)

      Verified knowledge context:
      \(knowledge)

      \(continuationMessage.map { "Continuation instruction:\n\($0)" } ?? "Begin the authorised work now.")
      """
  }

  public static func revisionPrompt(
    item: WorkItem,
    reviewer: AgentProfile,
    feedback: String,
    recentComments: [TicketComment]
  ) -> String {
    let history = recentComments.suffix(20).map { "- \($0.authorName): \($0.body)" }
      .joined(separator: "\n")
    return """
      Continue work on \(item.key): \(item.title).

      \(reviewer.name) requested changes:
      \(feedback)

      Recent Work log comments:
      \(history)

      Address the review findings in the existing workspace, rerun relevant checks, update the
      documentation and delivery notes, then return the structured execution result.
      """
  }

  public static func repairPrompt(validationError: String) -> String {
    """
    Your previous execution result could not be accepted:
    \(validationError)

    Continue the authorised ticket work in the existing workspace. Do not merely rewrite the JSON
    or describe work you intend to do. If the ticket can be completed, first create or update a
    durable, inspectable ticket artefact, run at least one relevant check, and provide specific
    Product Owner review instructions that refer only to evidence that now exists. If a material
    Product Owner decision or unavailable external dependency prevents that, return awaiting_owner
    instead. Return only the JSON required by the supplied schema.
    """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("status"),
        .string("comment"),
        .string("question"),
        .string("options"),
        .string("summary"),
        .string("changedFiles"),
        .string("tests"),
        .string("knowledgeNotes"),
        .string("reviewInstructions"),
        .string("retrospectiveWentWell"),
        .string("retrospectiveCouldImprove"),
        .string("retrospectiveActions"),
        .string("knowledgePageProposals"),
      ]),
      "properties": .object([
        "status": .object([
          "type": .string("string"),
          "enum": .array([
            .string(TicketExecutionStatus.completed.rawValue),
            .string(TicketExecutionStatus.awaitingOwner.rawValue),
          ]),
        ]),
        "comment": .object(["type": .string("string")]),
        "question": .object([
          "anyOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("null")]),
          ])
        ]),
        "options": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "summary": .object(["type": .string("string")]),
        "changedFiles": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "tests": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "knowledgeNotes": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "reviewInstructions": .object([
          "type": .string("array"),
          "maxItems": .number(6),
          "items": .object(["type": .string("string")]),
        ]),
        "retrospectiveWentWell": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "retrospectiveCouldImprove": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "retrospectiveActions": .object([
          "type": .string("array"),
          "maxItems": .number(2),
          "items": retrospectiveActionSchema,
        ]),
        "knowledgePageProposals": .object([
          "type": .string("array"),
          "maxItems": .number(4),
          "items": .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
              .string("operation"),
              .string("targetPageID"),
              .string("parentPageID"),
              .string("title"),
              .string("proposedBodyMarkdown"),
              .string("rationale"),
            ]),
            "properties": .object([
              "operation": .object([
                "type": .string("string"),
                "enum": .array([
                  .string(KnowledgePageProposalOperation.create.rawValue),
                  .string(KnowledgePageProposalOperation.update.rawValue),
                ]),
              ]),
              "targetPageID": nullableStringSchema,
              "parentPageID": nullableStringSchema,
              "title": .object(["type": .string("string")]),
              "proposedBodyMarkdown": .object(["type": .string("string")]),
              "rationale": .object(["type": .string("string")]),
            ]),
          ]),
        ]),
      ]),
    ])
  }

  public static func decode(_ text: String) throws -> TicketExecutionResult {
    guard let data = text.data(using: .utf8) else {
      throw TicketExecutionGenerationError.invalidResponse("The response was not UTF-8.")
    }
    let generated: GeneratedTicketExecutionResult
    do {
      generated = try JSONDecoder().decode(GeneratedTicketExecutionResult.self, from: data)
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(error.localizedDescription)
    }

    let comment = generated.comment.trimmingCharacters(in: .whitespacesAndNewlines)
    let question = generated.question?.trimmingCharacters(in: .whitespacesAndNewlines)
    let options = generated.options
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !comment.isEmpty else {
      throw TicketExecutionGenerationError.invalidResponse("A Work log comment is required.")
    }
    if generated.status == .awaitingOwner {
      guard let question, !question.isEmpty, (2...4).contains(options.count) else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Awaiting-owner results need one question and two to four options."
        )
      }
      guard generated.knowledgePageProposals.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Awaiting-owner results cannot propose canonical knowledge changes."
        )
      }
    }
    let summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let changedFiles = clean(generated.changedFiles)
    let tests = clean(generated.tests)
    var reviewInstructions = clean(generated.reviewInstructions)
    if generated.status == .completed {
      guard !summary.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Completed results need a concise outcome summary."
        )
      }
      guard !changedFiles.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Completed results need at least one durable changed-file artefact."
        )
      }
      guard !tests.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Completed results need at least one check that was actually performed."
        )
      }
      guard !reviewInstructions.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Completed results need one to six specific Product Owner review instructions."
        )
      }
    }
    if reviewInstructions.count > 6 {
      reviewInstructions = Array(reviewInstructions.prefix(6))
    }

    let proposals = try generated.knowledgePageProposals.prefix(4).map { proposal in
      let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let body = KnowledgeMarkdown.normalizedBody(proposal.proposedBodyMarkdown)
      let rationale = proposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, !body.isEmpty, !rationale.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Canonical knowledge proposals need a title, complete body, and rationale."
        )
      }
      let targetID = proposal.targetPageID.flatMap(UUID.init(uuidString:))
      let parentID = proposal.parentPageID.flatMap(UUID.init(uuidString:))
      switch proposal.operation {
      case .update:
        guard targetID != nil, parentID == nil else {
          throw TicketExecutionGenerationError.invalidResponse(
            "Knowledge-page updates need targetPageID and no parentPageID."
          )
        }
      case .create:
        guard targetID == nil, parentID != nil else {
          throw TicketExecutionGenerationError.invalidResponse(
            "Knowledge-page creates need parentPageID and no targetPageID."
          )
        }
      }
      return KnowledgePageProposalDraft(
        operation: proposal.operation,
        targetPageID: targetID,
        parentPageID: parentID,
        title: title,
        proposedBodyMarkdown: body,
        rationale: rationale
      )
    }

    return TicketExecutionResult(
      status: generated.status,
      comment: comment,
      question: question?.isEmpty == true ? nil : question,
      options: options,
      summary: summary,
      changedFiles: changedFiles,
      tests: tests,
      knowledgeNotes: clean(generated.knowledgeNotes),
      reviewInstructions: reviewInstructions,
      retrospectiveWentWell: Array(clean(generated.retrospectiveWentWell).prefix(2)),
      retrospectiveCouldImprove: Array(clean(generated.retrospectiveCouldImprove).prefix(2)),
      retrospectiveActions: cleanActions(generated.retrospectiveActions),
      knowledgePageProposals: proposals
    )
  }

  private static var nullableStringSchema: JSONValue {
    .object([
      "anyOf": .array([
        .object(["type": .string("string")]),
        .object(["type": .string("null")]),
      ])
    ])
  }

  private static var retrospectiveActionSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("body"),
        .string("destination"),
      ]),
      "properties": .object([
        "body": .object(["type": .string("string")]),
        "destination": .object([
          "type": .string("string"),
          "enum": .array([
            .string(RetrospectiveActionDestination.teamPractice.rawValue),
            .string(RetrospectiveActionDestination.backlog.rawValue),
          ]),
        ]),
      ]),
    ])
  }

  private static func cleanActions(
    _ values: [RetrospectiveActionProposal]
  ) -> [RetrospectiveActionProposal] {
    values.prefix(2).compactMap { value in
      let body = value.body.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return nil }
      return RetrospectiveActionProposal(body: body, destination: value.destination)
    }
  }

  private static func clean(_ values: [String]) -> [String] {
    values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

private struct GeneratedTicketExecutionResult: Codable {
  let status: TicketExecutionStatus
  let comment: String
  let question: String?
  let options: [String]
  let summary: String
  let changedFiles: [String]
  let tests: [String]
  let knowledgeNotes: [String]
  let reviewInstructions: [String]
  let retrospectiveWentWell: [String]
  let retrospectiveCouldImprove: [String]
  let retrospectiveActions: [RetrospectiveActionProposal]
  let knowledgePageProposals: [GeneratedKnowledgePageProposal]
}

private struct GeneratedKnowledgePageProposal: Codable {
  let operation: KnowledgePageProposalOperation
  let targetPageID: String?
  let parentPageID: String?
  let title: String
  let proposedBodyMarkdown: String
  let rationale: String
}

public enum TechLeadReviewDecision: String, Codable, Sendable {
  case approved
  case changesRequested = "changes_requested"
}

public struct TechLeadReviewResult: Equatable, Sendable {
  public let decision: TechLeadReviewDecision
  public let comment: String
  public let findings: [String]
  public let retrospectiveWentWell: [String]
  public let retrospectiveCouldImprove: [String]
  public let retrospectiveActions: [RetrospectiveActionProposal]

  public init(
    decision: TechLeadReviewDecision,
    comment: String,
    findings: [String],
    retrospectiveWentWell: [String],
    retrospectiveCouldImprove: [String],
    retrospectiveActions: [RetrospectiveActionProposal]
  ) {
    self.decision = decision
    self.comment = comment
    self.findings = findings
    self.retrospectiveWentWell = retrospectiveWentWell
    self.retrospectiveCouldImprove = retrospectiveCouldImprove
    self.retrospectiveActions = retrospectiveActions
  }

  public var workLogComment: String {
    guard !findings.isEmpty else { return comment }
    return "\(comment)\n\n\(findings.map { "- \($0)" }.joined(separator: "\n"))"
  }
}

public enum CodexTechLeadReviewer {
  private static let platformInstructions = """
    You are the configured StoryPointless Tech Lead reviewing the implementation of one sprint
    ticket. This is an independent, read-only review of the current workspace. Inspect the actual
    changes and only the directly relevant project files. Do not modify files.

    Perform one focused, proportionate pass and reach a decision promptly. Start with the delivered
    artefacts, candidate diff, reported checks, and acceptance criteria. Do not explore unrelated
    code, rerun broad test suites, or research the domain from scratch unless a specific piece of
    evidence exposes a material concern.

    Use a good-enough-for-demonstration threshold. Approve when the stated outcome and acceptance
    criteria are substantially satisfied and the Product Owner can meaningfully inspect the
    deliverable. Request changes only for a concrete material blocker: a violated acceptance
    criterion, a materially false claim, a correctness or security defect, or a missing artefact
    that prevents review. Optional polish, exhaustive completeness, production hardening, minor
    documentation imperfections, and plausible downstream implementation details are not blockers;
    mention them briefly in the comment and approve. Never increase the ticket’s scope during
    review. When the delivered outcome is reasonable and the remaining concern is a matter of
    preference, future hardening, or acceptable uncertainty, approve with a note.

    Do not redo the delivery agent’s task. For research, discovery, or analysis tickets, verify that
    the produced artefact gives a reasonable evidence-backed recommendation and records important
    assumptions or Product Owner decisions. Do not require an exhaustive specification, complete
    downstream implementation mappings, or fresh independent research unless the ticket explicitly
    asks for it. An acceptance criterion requiring Product Owner approval means the artefact must be
    ready for that approval; the approval does not need to pre-exist the demonstration.

    For implementation tickets, inspect the relevant diff, targeted checks, and resulting behaviour
    rather than attempting a second implementation. The purpose of review is to catch material
    omissions and risks, not to replace the assigned specialist with a stronger model.

    If requesting changes, return at most three small, actionable blocking findings. Do not use
    findings for non-blocking suggestions. Return only the JSON required by the output schema. The
    comment is an attributed ticket Work log entry. Confirm the Product Owner review instructions
    are truthful and actionable before approving. Capture at most two evidence-based observations
    per retrospective list; use empty lists when there is no useful signal. Write retrospective
    observations for a non-technical Product Owner: describe outcomes, friction, and actionable
    team practices in plain language. Do not mention internal Git ranges, workspaces, diffs, schemas,
    or validation plumbing unless the Product Owner must make a decision about them. Convert
    low-level corrective steps into the user-visible team improvement they are meant to achieve.
    Classify each retrospective action as team_practice when it should directly update inherited
    team guidance, or backlog only when it requires tangible implementation. Never create backlog
    work merely to change a team instruction.
    """

  public static func developerInstructions(
    productInstructions: String,
    personaInstructions: String,
    reviewer: AgentProfile
  ) -> String {
    let shared = productInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let persona = personaInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      \(platformInstructions)

      REVIEWER
      \(reviewer.name) — \(reviewer.role.title)

      PRODUCT OWNER'S SHARED TEAM GUIDANCE
      \(shared.isEmpty ? "No additional shared guidance." : shared)

      TECH LEAD GUIDANCE
      \(persona)
      """
  }

  public static func prompt(
    product: Product,
    item: WorkItem,
    implementation: TicketExecutionResult,
    assignee: AgentProfile,
    reviewCycle: Int = 0,
    priorReviewFeedback: String? = nil,
    recentComments: [TicketComment] = [],
    baseSHA: String? = nil,
    candidateHeadSHA: String? = nil,
    integratedSHA: String? = nil
  ) -> String {
    let criteria = item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let revision = if let baseSHA, let candidateHeadSHA, let integratedSHA {
      """
      Immutable revision under review:
      - Candidate range: \(baseSHA)..\(candidateHeadSHA)
      - Integrated revision: \(integratedSHA)
      Inspect that exact range and the current detached integration workspace.
      """
    } else {
      "No immutable revision metadata was supplied."
    }
    let knowledgeProposals = implementation.knowledgePageProposals.isEmpty
      ? "No canonical knowledge-page changes were proposed."
      : implementation.knowledgePageProposals.map { proposal in
        """
        - \(proposal.operation.rawValue.capitalized): \(proposal.title)
          Rationale: \(proposal.rationale)
        """
      }.joined(separator: "\n")
    let reviewMode: String
    if reviewCycle > 0 {
      reviewMode = """
        This is focused re-review \(reviewCycle) after the delivery specialist revised the work.
        Verify only the previous blocking feedback and the directly affected acceptance criteria.
        Do not restart a full review or introduce new optional scope. If the original material
        findings are resolved, approve.

        Previous blocking feedback:
        \(priorReviewFeedback ?? "No earlier review comment was available; use the revised delivery summary.")
        """
    } else {
      reviewMode = """
        This is the initial review. Make one focused pass over the delivered evidence and decide
        whether it is good enough for Product Owner demonstration.
        """
    }
    let history = recentComments
      .filter { $0.body != "I’m reviewing the implementation and its evidence against the ticket." }
      .suffix(12)
      .map { "- \($0.authorName): \($0.body)" }
      .joined(separator: "\n")
    return """
      Product: \(product.name)
      Product vision: \(product.vision)

      Ticket: \(item.key) — \(item.title)
      Delivered by: \(assignee.name) — \(assignee.role.title)
      Context: \(item.body)
      Acceptance criteria:
      \(criteria)

      \(reviewMode)

      \(revision)

      Implementer's summary:
      \(implementation.summary)

      Reported changed files:
      \(implementation.changedFiles.map { "- \($0)" }.joined(separator: "\n"))

      Reported checks:
      \(implementation.tests.map { "- \($0)" }.joined(separator: "\n"))

      Product Owner review instructions:
      \(implementation.reviewInstructions.map { "- \($0)" }.joined(separator: "\n"))

      Proposed durable knowledge:
      \(implementation.knowledgeNotes.map { "- \($0)" }.joined(separator: "\n"))

      Proposed canonical knowledge changes:
      \(knowledgeProposals)

      Recent ticket Work log:
      \(history.isEmpty ? "No earlier Work log context." : history)

      Inspect the exact integrated workspace and return the bounded review described above. Treat a
      materially inaccurate canonical knowledge proposal as a blocker; minor incompleteness can be
      noted without preventing demonstration.
      """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("decision"),
        .string("comment"),
        .string("findings"),
        .string("retrospectiveWentWell"),
        .string("retrospectiveCouldImprove"),
        .string("retrospectiveActions"),
      ]),
      "properties": .object([
        "decision": .object([
          "type": .string("string"),
          "enum": .array([
            .string(TechLeadReviewDecision.approved.rawValue),
            .string(TechLeadReviewDecision.changesRequested.rawValue),
          ]),
        ]),
        "comment": .object(["type": .string("string")]),
        "findings": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "retrospectiveWentWell": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "retrospectiveCouldImprove": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
        "retrospectiveActions": .object([
          "type": .string("array"),
          "maxItems": .number(2),
          "items": retrospectiveActionSchema,
        ]),
      ]),
    ])
  }

  public static func decode(_ text: String) throws -> TechLeadReviewResult {
    guard let data = text.data(using: .utf8) else {
      throw TechLeadReviewGenerationError.invalidResponse("The review was not UTF-8.")
    }
    let generated: GeneratedTechLeadReviewResult
    do {
      generated = try JSONDecoder().decode(GeneratedTechLeadReviewResult.self, from: data)
    } catch {
      throw TechLeadReviewGenerationError.invalidResponse(error.localizedDescription)
    }
    let comment = generated.comment.trimmingCharacters(in: .whitespacesAndNewlines)
    let findings = generated.findings
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !comment.isEmpty else {
      throw TechLeadReviewGenerationError.invalidResponse("A review comment is required.")
    }
    if generated.decision == .changesRequested, findings.isEmpty {
      throw TechLeadReviewGenerationError.changesRequestedWithoutFinding
    }
    return TechLeadReviewResult(
      decision: generated.decision,
      comment: comment,
      findings: findings,
      retrospectiveWentWell: Array(clean(generated.retrospectiveWentWell).prefix(2)),
      retrospectiveCouldImprove: Array(clean(generated.retrospectiveCouldImprove).prefix(2)),
      retrospectiveActions: cleanActions(generated.retrospectiveActions)
    )
  }

  private static func clean(_ values: [String]) -> [String] {
    values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static var retrospectiveActionSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("body"),
        .string("destination"),
      ]),
      "properties": .object([
        "body": .object(["type": .string("string")]),
        "destination": .object([
          "type": .string("string"),
          "enum": .array([
            .string(RetrospectiveActionDestination.teamPractice.rawValue),
            .string(RetrospectiveActionDestination.backlog.rawValue),
          ]),
        ]),
      ]),
    ])
  }

  private static func cleanActions(
    _ values: [RetrospectiveActionProposal]
  ) -> [RetrospectiveActionProposal] {
    values.prefix(2).compactMap { value in
      let body = value.body.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return nil }
      return RetrospectiveActionProposal(body: body, destination: value.destination)
    }
  }
}

private struct GeneratedTechLeadReviewResult: Codable {
  let decision: TechLeadReviewDecision
  let comment: String
  let findings: [String]
  let retrospectiveWentWell: [String]
  let retrospectiveCouldImprove: [String]
  let retrospectiveActions: [RetrospectiveActionProposal]
}
