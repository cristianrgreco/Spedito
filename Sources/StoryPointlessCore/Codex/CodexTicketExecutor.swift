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

public struct FollowUpTicketProposalDraft: Codable, Equatable, Sendable {
  public let reference: String
  public let title: String
  public let type: WorkItemType
  public let body: String
  public let acceptanceCriteria: [String]
  public let suggestedRole: AgentRole
  public let priority: WorkItemPriority
  public let rationale: String
  public let dependsOnReferences: [String]

  public init(
    reference: String,
    title: String,
    type: WorkItemType,
    body: String,
    acceptanceCriteria: [String],
    suggestedRole: AgentRole,
    priority: WorkItemPriority,
    rationale: String,
    dependsOnReferences: [String] = []
  ) {
    self.reference = reference
    self.title = title
    self.type = type
    self.body = body
    self.acceptanceCriteria = acceptanceCriteria
    self.suggestedRole = suggestedRole
    self.priority = priority
    self.rationale = rationale
    self.dependsOnReferences = dependsOnReferences
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
  public let demo: DemoLaunchSpecification?
  public let retrospectiveWentWell: [String]
  public let retrospectiveCouldImprove: [String]
  public let retrospectiveActions: [RetrospectiveActionProposal]
  public let knowledgePageProposals: [KnowledgePageProposalDraft]
  public let followUpTicketProposals: [FollowUpTicketProposalDraft]

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
    demo: DemoLaunchSpecification? = nil,
    retrospectiveWentWell: [String],
    retrospectiveCouldImprove: [String],
    retrospectiveActions: [RetrospectiveActionProposal],
    knowledgePageProposals: [KnowledgePageProposalDraft] = [],
    followUpTicketProposals: [FollowUpTicketProposalDraft] = []
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
    self.demo = demo
    self.retrospectiveWentWell = retrospectiveWentWell
    self.retrospectiveCouldImprove = retrospectiveCouldImprove
    self.retrospectiveActions = retrospectiveActions
    self.knowledgePageProposals = knowledgePageProposals
    self.followUpTicketProposals = followUpTicketProposals
  }

  public var workLogComment: String {
    switch status {
    case .completed:
      var sections = [comment]
      if !summary.isEmpty {
        sections.append("Completion handoff:\n\(summary)")
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
      if let demo {
        sections.append("Demo: \(demo.title) · \(demo.presentation.kind.title)")
      }
      if !followUpTicketProposals.isEmpty {
        sections.append(
          "Recommended follow-up tickets:\n"
            + followUpTicketProposals.map { "- \($0.reference): \($0.title)" }
              .joined(separator: "\n")
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
    You may use read-only Git inspection such as status, diff, log, show, and blame. StoryPointless
    owns every Git mutation, including staging, commits, branches, integration, and promotion. Do
    not run Git commands that change repository state. Inspect and edit the supplied product files
    directly; StoryPointless will capture the resulting change. Product Git reads and their
    noninteractive environment are already available inside the sandbox. Run them normally without
    requesting permission or adding environment prefixes.

    The ticket and its attributed comments are the source of truth. Do not silently invent product
    requirements, credentials, providers, destructive operations, or network permission. The
    ticket workspace starts with no external network or access to secrets and unrelated products.
    When the authorised implementation genuinely needs a capability outside that boundary, request
    the narrowest exact filesystem, network, or command permission through the available approval
    channel and explain why it is needed. Never copy, mirror, archive, or stage the ticket workspace
    in /tmp or another location to work around a permission boundary. Never request general access
    when a narrower capability will work.

    If a command fails with `operation not permitted` or `permission denied`, do not merely repeat
    it, add another shell wrapper, or ask for the same command approval again. First use non-mutating
    diagnostics such as `command -v` or `type -a` to resolve the executable, inspect its symlink
    target when permitted, and distinguish a missing filesystem or network capability from command
    approval. Use the `request_permissions` tool to request only the exact path and access needed,
    then retry the original command without wrapping it. If that tool is unavailable or the missing
    capability cannot be diagnosed inside the current boundary, stop safely and report the exact
    diagnostic and capability still needed; do not substitute older evidence when the ticket
    requires a fresh check.

    If a material Product Owner choice, secret, credential, or unavailable external system is
    required instead of a permission, stop safely and return awaiting_owner with one concise question
    and two to four concrete options. Do not claim work is complete unless every acceptance criterion
    is addressed or explicitly shown to be inapplicable.

    Return only the JSON required by the output schema. The comment is a concise first-person update
    suitable for the ticket Work log. changedFiles must contain workspace-relative paths. tests must
    report commands or checks actually run and their result. knowledgeNotes must capture durable
    decisions, trade-offs, and usage information established by the work; never include guesses.
    For every completed ticket, comment, summary, and knowledgeNotes together must form a
    self-contained completion handoff for its planned direct dependants. State the delivered outcome,
    decisions, selected providers or contracts, operating requirements, evidence, caveats, and what
    downstream work may safely assume. Put reusable cross-ticket truth in knowledgePageProposals as
    well as the handoff. Do not rely on private agent context or an unrecorded implementation detail.
    A completed result must include one to six reviewInstructions telling a non-technical Product
    Owner exactly how to inspect the outcome. Mention a URL, file, command, endpoint, or evidence
    only when it actually exists. If the outcome is not independently interactive, say which
    evidence to inspect and what result to expect.

    A completed result must also include a typed demo recipe in demo so StoryPointless can give the
    Product Owner one Demo button. Use presentation kind browser for a local web service,
    mac_application for a built .app bundle, artifact for a workspace-relative document, image,
    HTML file, or other reviewable file, and command_output for a bounded command whose captured
    result is the demonstration. preparationCommands are bounded build or generation steps.
    launchCommand is the long-running service for browser demos or the bounded scenario for
    command_output. Use executable plus argument arrays; never use sh, bash, zsh, osascript,
    redirection, pipelines, or a compound shell command. Every working directory and presentation
    path is relative to the ticket workspace. Browser presentation and readiness paths begin with
    "/" and never contain a host; StoryPointless allocates a loopback port, substitutes {{PORT}} in
    arguments, and provides it through portEnvironmentVariable (or PORT when that field is null).
    Use HTTP readiness for browser demos. Use no launchCommand for app and artifact demos. If a
    completed outcome is not interactive, present its primary durable artefact or a bounded
    command_output demonstration. awaiting_owner results must set demo to null.

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

    A Business Analyst completing an explicitly authorised research, discovery, or decision ticket
    may return zero to twelve followUpTicketProposals when the evidence establishes concrete product
    work that is not already in the supplied active scope. These are reviewable recommendations, not
    authorised scope. Planned direct dependants and the supplied active scope are already accepted work:
    use the completion handoff and Product knowledge to give them the decision, contract, and caveats they
    need. Do not reword, split, replace, or duplicate them as follow-up proposals. Return an empty
    followUpTicketProposals array whenever they already cover the downstream work. If the evidence
    materially conflicts with an existing ticket contract, return awaiting_owner with one decision
    question instead of silently changing that contract or proposing a substitute.

    Only propose follow-up tickets for genuinely new scope that no planned dependant or active ticket
    covers. Explain through each rationale why the work is new rather than a detail for an existing
    ticket. When that exceptional case applies, propose the smallest coherent downstream delivery graph,
    with testable acceptance criteria and genuine dependencies between temporary references such as F1
    and F2. Do not restate the research ticket, speculate beyond its evidence, or propose follow-up
    tickets from an ordinary implementation ticket. StoryPointless will add the completed research ticket
    as a durable prerequisite and will publish the proposals only after Product Owner approval.
    Awaiting-owner results must return no follow-up ticket proposals.
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
    dependants: [WorkItem],
    prerequisiteComments: [UUID: [TicketComment]],
    ticketComments: [TicketComment],
    knowledgeContext: [KnowledgePage],
    existingItems: [WorkItem] = [],
    continuationMessage: String? = nil
  ) -> String {
    let criteria = item.acceptanceCriteria.isEmpty
      ? "No acceptance criteria supplied."
      : item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let dependencyContext = prerequisites.isEmpty
      ? "No prerequisites."
      : prerequisites.map { prerequisite in
        let criteria = prerequisite.acceptanceCriteria.isEmpty
          ? "  - No acceptance criteria supplied."
          : prerequisite.acceptanceCriteria.map { "  - \($0)" }.joined(separator: "\n")
        let comments = prerequisiteComments[prerequisite.id, default: []]
          .suffix(20)
          .map { "  - \($0.authorName): \($0.body)" }
          .joined(separator: "\n")
        return """
          - \(prerequisite.key) [\(prerequisite.state.title)]: \(prerequisite.title)
            Context: \(prerequisite.body.isEmpty ? "No additional context." : prerequisite.body)
            Acceptance criteria:
          \(criteria)
            Recent Work log:
          \(comments.isEmpty ? "  - No prerequisite comments." : comments)
          """
      }.joined(separator: "\n")
    let dependantContext = dependants
      .filter { $0.state != .cancelled }
      .map { dependant in
        let criteria = dependant.acceptanceCriteria.isEmpty
          ? "  - No acceptance criteria supplied."
          : dependant.acceptanceCriteria.map { "  - \($0)" }.joined(separator: "\n")
        return """
          - \(dependant.key) [\(dependant.state.title), \(dependant.type.title)]: \(dependant.title)
            Context: \(dependant.body.isEmpty ? "No additional context." : dependant.body)
            Acceptance criteria:
          \(criteria)
          """
      }
      .joined(separator: "\n")
    let relevantTicketComments = ticketComments.filter {
      !$0.body.hasPrefix("Permission requested:")
    }
    let history = relevantTicketComments.isEmpty
      ? "No ticket comments."
      : relevantTicketComments.suffix(40).map { "- \($0.authorName): \($0.body)" }
        .joined(separator: "\n")
    let knowledge = knowledgeContext.isEmpty
      ? "No verified knowledge pages were selected."
      : knowledgeContext.map { page in
        """
        ### \(page.title) [verified, page ID: \(page.id.uuidString)]
        \(page.bodyMarkdown)
        """
      }.joined(separator: "\n\n")
    let existingScope = existingItems
      .filter { $0.id != item.id && $0.state != .cancelled }
      .map { "- \($0.key) [\($0.type.title)]: \($0.title)" }
      .joined(separator: "\n")

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

      Planned direct dependant tickets:
      \(dependantContext.isEmpty ? "No active tickets directly depend on this ticket." : dependantContext)

      These dependant tickets already represent planned downstream work. Do not duplicate, replace,
      reword, or split them into follow-up proposals. Use the completion handoff and verified Product
      knowledge to give them the decisions and operating details they need. Return an empty
      followUpTicketProposals array when they and the existing active scope cover the work.

      Ticket Work log comments:
      \(history)

      Verified knowledge context:
      \(knowledge)

      Existing active scope (do not duplicate it in follow-up proposals):
      \(existingScope.isEmpty ? "No other active tickets." : existingScope)

      \(continuationMessage.map { "Continuation instruction:\n\($0)" } ?? "Begin the authorised work now.")
      """
  }

  public static func revisionPrompt(
    item: WorkItem,
    reviewer: AgentProfile,
    feedback: String,
    recentComments: [TicketComment]
  ) -> String {
    let history = recentComments
      .filter { !$0.body.hasPrefix("Permission requested:") }
      .suffix(20)
      .map { "- \($0.authorName): \($0.body)" }
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

  public static func recoveryPrompt(
    item: WorkItem,
    interruptedPermission: AgentPermissionRequest?,
    recentComments: [TicketComment] = [],
    conversationIsAvailable: Bool = true
  ) -> String {
    let conversationContext =
      if conversationIsAvailable {
        """
        Continue in the existing Conversation and ticket workspace. Use the implementation work,
        decisions, and evidence already present there.
        """
      } else {
        """
        The previous Conversation is unavailable, but the existing ticket workspace and its changes
        have been preserved. Treat the current workspace as the source of truth for completed work.
        """
      }
    let permissionContext =
      if let interruptedPermission {
        switch interruptedPermission.status {
        case .allowed:
          """
          The Product Owner already allowed this matching capability for the existing run:
          \(interruptedPermission.detail)
          Reissue it only if it is still needed; StoryPointless will apply the saved scoped decision.
          """
        case .interrupted:
          """
          The previous live permission request expired when the app stopped:
          \(interruptedPermission.detail)
          Reissue the same request only if it is still needed so the Product Owner can answer it.
          """
        case .denied:
          """
          The Product Owner denied this matching capability for the existing run:
          \(interruptedPermission.detail)
          Do not reissue the same request. Adapt within the existing permission boundary.
          """
        case .pending:
          "No reusable permission decision was recorded."
        }
      } else {
        "No interrupted permission request was recorded."
      }
    let workLogContext = recentComments
      .filter { !$0.body.hasPrefix("Permission requested:") }
      .suffix(12)
      .map { "- \($0.authorName): \($0.body)" }
      .joined(separator: "\n")

    return """
      Continue the existing implementation of \(item.key) — \(item.title).

      StoryPointless is starting a continuation turn after the previous turn stopped or paused.
      \(conversationContext)
      Do not restart the ticket, discard partial changes, redo completed work, or repeat checks
      merely because a new turn started. Inspect the current diff and rerun a check only when needed
      to finish or validate the remaining work.

      \(permissionContext)

      Recent ticket Work log:
      \(workLogContext.isEmpty ? "No new Work log context." : workLogContext)

      Apply the latest Product Owner or reviewer direction above, finish the remaining authorised
      work, and return the complete structured execution result. If another material Product Owner
      decision is required, return awaiting_owner under the existing contract.
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
        .string("demo"),
        .string("retrospectiveWentWell"),
        .string("retrospectiveCouldImprove"),
        .string("retrospectiveActions"),
        .string("knowledgePageProposals"),
        .string("followUpTicketProposals"),
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
        "demo": nullableDemoLaunchSpecificationSchema,
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
        "followUpTicketProposals": .object([
          "type": .string("array"),
          "maxItems": .number(12),
          "items": followUpTicketProposalSchema,
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
      guard generated.followUpTicketProposals?.isEmpty != false else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Awaiting-owner results cannot propose follow-up tickets."
        )
      }
      guard generated.demo == nil else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Awaiting-owner results cannot include a demo recipe."
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
    if let demo = generated.demo {
      do {
        try DemoLaunchSpecificationValidator.validate(demo)
      } catch {
        throw TicketExecutionGenerationError.invalidResponse(error.localizedDescription)
      }
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
    let followUpTicketProposals = try decodeFollowUpTicketProposals(
      generated.followUpTicketProposals ?? []
    )

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
      demo: generated.demo,
      retrospectiveWentWell: Array(clean(generated.retrospectiveWentWell).prefix(2)),
      retrospectiveCouldImprove: Array(clean(generated.retrospectiveCouldImprove).prefix(2)),
      retrospectiveActions: cleanActions(generated.retrospectiveActions),
      knowledgePageProposals: proposals,
      followUpTicketProposals: followUpTicketProposals
    )
  }

  public static func validateFollowUpTicketProposals(
    in result: TicketExecutionResult,
    assignee: AgentProfile
  ) throws {
    guard !result.followUpTicketProposals.isEmpty else { return }
    guard assignee.role == .businessAnalyst else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Only an assigned Business Analyst may propose follow-up tickets from authorised "
          + "research, discovery, or decision work."
      )
    }
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

  private static var nullableDemoLaunchSpecificationSchema: JSONValue {
    let command = JSONValue.object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("executable"),
        .string("arguments"),
        .string("workingDirectory"),
        .string("timeoutSeconds"),
      ]),
      "properties": .object([
        "executable": .object(["type": .string("string")]),
        "arguments": .object([
          "type": .string("array"),
          "maxItems": .integer(64),
          "items": .object(["type": .string("string")]),
        ]),
        "workingDirectory": .object(["type": .string("string")]),
        "timeoutSeconds": .object([
          "type": .string("integer"),
          "minimum": .integer(1),
          "maximum": .integer(900),
        ]),
      ]),
    ])
    let nullableString = JSONValue.object([
      "anyOf": .array([
        .object(["type": .string("string")]),
        .object(["type": .string("null")]),
      ])
    ])
    let nullableCommand = JSONValue.object([
      "anyOf": .array([
        command,
        .object(["type": .string("null")]),
      ])
    ])
    let readiness = JSONValue.object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("kind"),
        .string("path"),
        .string("timeoutSeconds"),
      ]),
      "properties": .object([
        "kind": .object([
          "type": .string("string"),
          "enum": .array(DemoReadinessKind.allCases.map { .string($0.rawValue) }),
        ]),
        "path": nullableString,
        "timeoutSeconds": .object([
          "type": .string("integer"),
          "minimum": .integer(1),
          "maximum": .integer(120),
        ]),
      ]),
    ])
    let specification = JSONValue.object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("schemaVersion"),
        .string("title"),
        .string("preparationCommands"),
        .string("launchCommand"),
        .string("portEnvironmentVariable"),
        .string("readiness"),
        .string("presentation"),
      ]),
      "properties": .object([
        "schemaVersion": .object([
          "type": .string("integer"),
          "enum": .array([.integer(1)]),
        ]),
        "title": .object(["type": .string("string")]),
        "preparationCommands": .object([
          "type": .string("array"),
          "maxItems": .integer(6),
          "items": command,
        ]),
        "launchCommand": nullableCommand,
        "portEnvironmentVariable": nullableString,
        "readiness": .object([
          "anyOf": .array([
            readiness,
            .object(["type": .string("null")]),
          ])
        ]),
        "presentation": .object([
          "type": .string("object"),
          "additionalProperties": .bool(false),
          "required": .array([
            .string("kind"),
            .string("path"),
          ]),
          "properties": .object([
            "kind": .object([
              "type": .string("string"),
              "enum": .array(DemoPresentationKind.allCases.map { .string($0.rawValue) }),
            ]),
            "path": nullableString,
          ]),
        ]),
      ]),
    ])
    return .object([
      "anyOf": .array([
        specification,
        .object(["type": .string("null")]),
      ])
    ])
  }

  private static var followUpTicketProposalSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("reference"),
        .string("title"),
        .string("type"),
        .string("body"),
        .string("acceptanceCriteria"),
        .string("role"),
        .string("priority"),
        .string("rationale"),
        .string("dependsOn"),
      ]),
      "properties": .object([
        "reference": .object(["type": .string("string")]),
        "title": .object(["type": .string("string")]),
        "type": .object([
          "type": .string("string"),
          "enum": .array(WorkItemType.allCases.map { .string($0.rawValue) }),
        ]),
        "body": .object(["type": .string("string")]),
        "acceptanceCriteria": .object([
          "type": .string("array"),
          "minItems": .integer(1),
          "items": .object(["type": .string("string")]),
        ]),
        "role": .object([
          "type": .string("string"),
          "enum": .array([
            .string(AgentRole.businessAnalyst.rawValue),
            .string(AgentRole.uxDesigner.rawValue),
            .string(AgentRole.implementer.rawValue),
          ]),
        ]),
        "priority": .object([
          "type": .string("string"),
          "enum": .array([
            .string("urgent"), .string("high"), .string("normal"), .string("low"),
          ]),
        ]),
        "rationale": .object(["type": .string("string")]),
        "dependsOn": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
      ]),
    ])
  }

  private static func decodeFollowUpTicketProposals(
    _ generated: [GeneratedFollowUpTicketProposal]
  ) throws -> [FollowUpTicketProposalDraft] {
    guard generated.count <= 12 else {
      throw TicketExecutionGenerationError.invalidResponse(
        "A research result can propose at most twelve follow-up tickets."
      )
    }
    let references = generated.map { normalizedReference($0.reference) }
    guard references.allSatisfy({ !$0.isEmpty }), Set(references).count == references.count else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Follow-up ticket references must be non-empty and unique."
      )
    }
    let referenceSet = Set(references)
    let dependencies = Dictionary(
      uniqueKeysWithValues: zip(references, generated).map { reference, proposal in
        (reference, proposal.dependsOn.map(normalizedReference))
      }
    )
    guard dependencies.values.flatMap({ $0 }).allSatisfy(referenceSet.contains) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Every follow-up dependency must reference another follow-up ticket."
      )
    }
    guard dependencies.allSatisfy({ reference, values in !values.contains(reference) }) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "A follow-up ticket cannot depend on itself."
      )
    }
    guard !hasDependencyCycle(dependencies) else {
      throw TicketExecutionGenerationError.invalidResponse(
        "Follow-up ticket dependencies must not contain a cycle."
      )
    }

    return try zip(references, generated).map { reference, proposal in
      let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let body = proposal.body.trimmingCharacters(in: .whitespacesAndNewlines)
      let criteria = clean(proposal.acceptanceCriteria)
      let rationale = proposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !title.isEmpty,
        !body.isEmpty,
        !criteria.isEmpty,
        !rationale.isEmpty,
        let type = WorkItemType(rawValue: proposal.type),
        let role = AgentRole(rawValue: proposal.role),
        [.businessAnalyst, .uxDesigner, .implementer].contains(role),
        let priority = priority(named: proposal.priority)
      else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Each follow-up ticket needs a title, context, criteria, role, priority, and rationale."
        )
      }
      return FollowUpTicketProposalDraft(
        reference: reference,
        title: title,
        type: type,
        body: body,
        acceptanceCriteria: criteria,
        suggestedRole: role,
        priority: priority,
        rationale: rationale,
        dependsOnReferences: dependencies[reference] ?? []
      )
    }
  }

  private static func normalizedReference(_ value: String) -> String {
    String(
      value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .uppercased()
        .filter { $0.isLetter || $0.isNumber }
    )
  }

  private static func priority(named value: String) -> WorkItemPriority? {
    switch value {
    case "urgent": .urgent
    case "high": .high
    case "normal": .normal
    case "low": .low
    default: nil
    }
  }

  private static func hasDependencyCycle(_ dependencies: [String: [String]]) -> Bool {
    var visiting: Set<String> = []
    var visited: Set<String> = []

    func visit(_ reference: String) -> Bool {
      if visiting.contains(reference) { return true }
      if visited.contains(reference) { return false }
      visiting.insert(reference)
      for dependency in dependencies[reference] ?? [] where visit(dependency) {
        return true
      }
      visiting.remove(reference)
      visited.insert(reference)
      return false
    }

    return dependencies.keys.contains { visit($0) }
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
  let demo: DemoLaunchSpecification?
  let retrospectiveWentWell: [String]
  let retrospectiveCouldImprove: [String]
  let retrospectiveActions: [RetrospectiveActionProposal]
  let knowledgePageProposals: [GeneratedKnowledgePageProposal]
  let followUpTicketProposals: [GeneratedFollowUpTicketProposal]?
}

private struct GeneratedKnowledgePageProposal: Codable {
  let operation: KnowledgePageProposalOperation
  let targetPageID: String?
  let parentPageID: String?
  let title: String
  let proposedBodyMarkdown: String
  let rationale: String
}

private struct GeneratedFollowUpTicketProposal: Codable {
  let reference: String
  let title: String
  let type: String
  let body: String
  let acceptanceCriteria: [String]
  let role: String
  let priority: String
  let rationale: String
  let dependsOn: [String]
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
    asks for it. Review any follow-up ticket proposals for a clear connection to the evidence, useful
    acceptance criteria, and duplication of existing scope; they remain optional Product Owner
    recommendations. An acceptance criterion requiring Product Owner approval means the artefact must
    be ready for that approval; the approval does not need to pre-exist the demonstration.

    For implementation tickets, inspect the relevant diff, targeted checks, and resulting behaviour
    rather than attempting a second implementation. The purpose of review is to catch material
    omissions and risks, not to replace the assigned specialist with a stronger model.

    Confirm that the typed demo recipe truthfully opens the delivered outcome from the exact
    integrated workspace. Inspect its executable, arguments, working directory, readiness path, and
    presentation path. Request changes when the recipe points outside the workspace, invokes a shell
    or unrelated tool, needs an undeclared external dependency, opens a non-loopback web address, or
    would demonstrate something other than the reviewed candidate. For a non-interactive outcome,
    approve an artifact or captured command result when it gives the Product Owner meaningful
    acceptance evidence.

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
    let followUpProposals = implementation.followUpTicketProposals.isEmpty
      ? "No follow-up tickets were proposed."
      : implementation.followUpTicketProposals.map { proposal in
        """
        - \(proposal.reference): \(proposal.title) [\(proposal.type.title), \(proposal.suggestedRole.title)]
          Rationale: \(proposal.rationale)
        """
      }.joined(separator: "\n")
    let demoRecipe: String
    if let demo = implementation.demo,
      let encoded = try? JSONEncoder().encode(demo),
      let json = String(data: encoded, encoding: .utf8)
    {
      demoRecipe = json
    } else {
      demoRecipe = "No managed demo recipe was supplied."
    }
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
      .filter {
        $0.body != "I’m reviewing the implementation and its evidence against the ticket."
          && !$0.body.hasPrefix("Permission requested:")
      }
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

      Managed demo recipe:
      \(demoRecipe)

      Proposed durable knowledge:
      \(implementation.knowledgeNotes.map { "- \($0)" }.joined(separator: "\n"))

      Proposed canonical knowledge changes:
      \(knowledgeProposals)

      Proposed follow-up tickets:
      \(followUpProposals)

      Recent ticket Work log:
      \(history.isEmpty ? "No earlier Work log context." : history)

      Inspect the exact integrated workspace and return the bounded review described above. Treat a
      materially inaccurate canonical knowledge proposal as a blocker; minor incompleteness can be
      noted without preventing demonstration.
      """
  }

  public static func recoveryPrompt(
    item: WorkItem,
    integratedSHA: String,
    interruptedPermission: AgentPermissionRequest?
  ) -> String {
    let permissionContext =
      if let interruptedPermission {
        switch interruptedPermission.status {
        case .allowed:
          """
          The Product Owner already allowed this matching capability for the existing review run:
          \(interruptedPermission.detail)
          Reissue it only if it is still needed; StoryPointless will apply the saved scoped decision.
          """
        case .interrupted:
          """
          The previous live permission request expired when the app stopped:
          \(interruptedPermission.detail)
          Reissue the same request only if it is still needed so the Product Owner can answer it.
          """
        case .denied:
          """
          The Product Owner denied this matching capability for the existing review run:
          \(interruptedPermission.detail)
          Do not reissue the same request. Finish within the existing permission boundary.
          """
        case .pending:
          "No reusable permission decision was recorded."
        }
      } else {
        "No interrupted permission request was recorded."
      }

    return """
      Continue the existing Tech Lead review for \(item.key) — \(item.title).

      StoryPointless restarted while the previous turn was incomplete. The candidate has not
      changed, and the detached workspace is still pinned to integrated revision \(integratedSHA).
      Use the review work and evidence already present in this Conversation. Do not restart a full
      review, widen the ticket scope, repeat checks that already completed, or redo implementation.

      \(permissionContext)

      Finish the remaining focused inspection and return the complete structured Tech Lead review.
      Approve if no concrete material blocker remains; otherwise return the small actionable
      findings required by the review contract.
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
