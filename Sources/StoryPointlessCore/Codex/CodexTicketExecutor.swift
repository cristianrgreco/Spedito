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

public struct TicketRevisionBaseline: Equatable, Sendable {
  public let candidateHeadSHA: String
  public let integratedSHA: String

  public init(candidateHeadSHA: String, integratedSHA: String) {
    self.candidateHeadSHA = candidateHeadSHA
    self.integratedSHA = integratedSHA
  }

  fileprivate var promptContext: String {
    """
    StoryPointless advanced this ticket workspace from immutable candidate
    \(candidateHeadSHA) to reviewed integration \(integratedSHA). The current files now include
    accepted trunk changes and any Integrator resolution. Treat the current workspace as the source
    of truth, preserve compatible accepted behaviour, and apply the requested correction on top.
    Do not undo or recreate this Git handoff; StoryPointless owns Git state.
    """
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

  public static func developerInstructions(
    productInstructions: String,
    customInstructions: String,
    assignee: AgentProfile
  ) -> String {
    let lifecycle = CodexLifecycleGuidance.ticketDeliveryInstructions(
      mode: CodexTicketDeliveryMode(assignee: assignee)
    )
    return """
      \(lifecycle)

      ASSIGNED TEAM MEMBER
      \(assignee.name) — \(assignee.role.title)

      \(CodexLifecycleGuidance.configuredRoleGuidance(
        role: assignee.role,
        productInstructions: productInstructions,
        customInstructions: customInstructions
      ))
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
    knowledgeDirectory: [KnowledgePage] = [],
    knowledgeDestinationIDs: Set<UUID> = [],
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
    func renderedKnowledge(_ pages: [KnowledgePage], emptyMessage: String) -> String {
      pages.isEmpty
        ? emptyMessage
        : pages.map { page in
        """
        ### \(page.title) [verified, page ID: \(page.id.uuidString)]
        \(page.bodyMarkdown)
        """
      }.joined(separator: "\n\n")
    }
    let mandatoryKnowledge = knowledgeContext.filter(
      KnowledgeContextSelector.isMandatory
    )
    let relevantKnowledge = knowledgeContext.filter {
      !KnowledgeContextSelector.isMandatory($0)
    }
    let referencePageIDs = Set(knowledgeContext.map(\.id))
    let directory = knowledgeDirectory.isEmpty
      ? "No canonical knowledge destinations were supplied."
      : knowledgeDirectory.map { page in
        let access: String
        switch page.kind {
        case .section:
          access = knowledgeDestinationIDs.contains(page.id)
            ? "Create child pages allowed"
            : "Routing reference only"
        case .page:
          if knowledgeDestinationIDs.contains(page.id) {
            access = referencePageIDs.contains(page.id)
              ? "Update allowed; current body is in the verified context above"
              : "Update allowed; this page is currently empty"
          } else if referencePageIDs.contains(page.id) {
            access = "Read-only reference for this run; do not update"
          } else {
            access = "Routing reference only; do not update because its current body was not supplied"
          }
        case .deliveryNote:
          access = "Ticket history only; never update"
        }
        let path = KnowledgeContextSelector.directoryPath(
          for: page,
          pages: knowledgeDirectory
        )
        let purpose = KnowledgeContextSelector.purpose(for: page.slug, kind: page.kind)
        return "- \(path) [\(page.kind.rawValue), page ID: \(page.id.uuidString)] — \(access). \(purpose)"
      }.joined(separator: "\n")
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
      Always included:
      \(renderedKnowledge(mandatoryKnowledge, emptyMessage: "No populated mandatory pages were available."))

      Relevant to this ticket:
      \(renderedKnowledge(relevantKnowledge, emptyMessage: "No additional verified pages were selected."))

      Canonical knowledge directory:
      \(directory)

      Use the directory to route reusable truth to its narrowest appropriate home. It is an
      authorization list, not extra verified content. Empty pages are writable destinations but do
      not count as knowledge supplied to this ticket.

      Existing active scope (do not duplicate it in follow-up proposals):
      \(existingScope.isEmpty ? "No other active tickets." : existingScope)

      \(continuationMessage.map { "Continuation instruction:\n\($0)" } ?? "Begin the authorised work now.")
      """
  }

  public static func revisionPrompt(
    item: WorkItem,
    reviewer: AgentProfile,
    feedback: String,
    recentComments: [TicketComment],
    adoptedBaseline: TicketRevisionBaseline? = nil
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

      Workspace baseline:
      \(adoptedBaseline?.promptContext ?? "The ticket workspace remains on the immutable candidate reviewed above.")

      Address the review findings in the existing workspace, rerun relevant checks, update the
      documentation and delivery notes, then return the structured execution result.
      """
  }

  public static func recoveryPrompt(
    item: WorkItem,
    interruptedPermission: AgentPermissionRequest?,
    recentComments: [TicketComment] = [],
    conversationIsAvailable: Bool = true,
    adoptedBaseline: TicketRevisionBaseline? = nil
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
    let permissionContext = CodexLifecycleGuidance.permissionRecoveryContext(
      for: interruptedPermission,
      lifecycle: .delivery
    )
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

      Workspace baseline:
      \(adoptedBaseline?.promptContext ?? "StoryPointless has not changed the ticket workspace baseline for this continuation.")

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
    Product Owner decision, credential, secret, or external service that remains unavailable after
    handling any required scoped capability prevents that, return awaiting_owner instead. A missing
    sandbox filesystem or network capability is not an unavailable external dependency: use the
    available `request_permissions` tool rather than asking the Product Owner to restore, enable,
    add, or confirm access in an ordinary Work log question. Return only the JSON required by the
    supplied schema.
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

  public static func developerInstructions(
    productInstructions: String,
    customInstructions: String,
    reviewer: AgentProfile
  ) -> String {
    return """
      \(CodexLifecycleGuidance.techLeadReview)

      REVIEWER
      \(reviewer.name) — \(reviewer.role.title)

      \(CodexLifecycleGuidance.configuredRoleGuidance(
        role: reviewer.role,
        productInstructions: productInstructions,
        customInstructions: customInstructions
      ))
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
      This is a focused re-review after conflict resolution changed the merge result. Inspect that
      exact range and the current detached integration workspace.
      """
    } else if let baseSHA, let candidateHeadSHA {
      """
      Immutable revision under review:
      - Candidate range: \(baseSHA)..\(candidateHeadSHA)
      - Candidate revision: \(candidateHeadSHA)
      Inspect that exact range and the current detached candidate workspace. A clean integration
      will not require another review; conflict resolution that changes the merge result will.
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
        First reassess the previous feedback against the current material-blocker threshold; its
        earlier classification is not binding. Do not restart a full review or introduce new
        optional scope. Do not verify or preserve a cosmetic, style-only, or otherwise non-material
        finding merely because an earlier review requested it. If no material finding remains, approve.

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

      Inspect the exact immutable workspace and return the bounded review described above. Treat a
      materially inaccurate canonical knowledge proposal as a blocker; minor incompleteness can be
      noted without preventing demonstration.
      """
  }

  public static func recoveryPrompt(
    item: WorkItem,
    reviewedSHA: String,
    isIntegratedRevision: Bool,
    interruptedPermission: AgentPermissionRequest?
  ) -> String {
    let permissionContext = CodexLifecycleGuidance.permissionRecoveryContext(
      for: interruptedPermission,
      lifecycle: .review
    )

    return """
      Continue the existing Tech Lead review for \(item.key) — \(item.title).

      StoryPointless restarted while the previous turn was incomplete. The candidate has not
      changed, and the detached workspace is still pinned to \(isIntegratedRevision ? "integrated" : "candidate") revision \(reviewedSHA).
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
