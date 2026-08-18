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
  public let decisionArtifact: TicketDecisionArtifact?
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
    decisionArtifact: TicketDecisionArtifact? = nil,
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
    self.decisionArtifact = decisionArtifact
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
      if let decisionArtifact {
        sections.append(
          "Decision evidence: \(decisionArtifact.title) (`\(decisionArtifact.path)`)"
        )
      }
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

public enum TicketDecisionArtifactValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let detail):
      "The decision evidence is invalid: \(detail)"
    }
  }
}

public enum TicketDecisionArtifactValidator {
  public static func normalized(
    _ artifact: TicketDecisionArtifact
  ) throws -> TicketDecisionArtifact {
    let title = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = artifact.path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw TicketExecutionGenerationError.invalidResponse(
        "decisionArtifact needs a short product owner-facing title."
      )
    }
    guard !path.isEmpty else {
      throw TicketExecutionGenerationError.invalidResponse(
        "decisionArtifact needs a workspace-relative file path."
      )
    }
    do {
      _ = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        path,
        in: URL(fileURLWithPath: "/private/tmp/spedito-decision-artifact")
      )
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(
        "decisionArtifact path is unsafe: \(error.localizedDescription)"
      )
    }
    do {
      try DemoArtifactPolicy.validatePath(path)
    } catch {
      throw TicketExecutionGenerationError.invalidResponse(
        "decisionArtifact must be an inert review file: \(error.localizedDescription)"
      )
    }
    return TicketDecisionArtifact(
      title: title,
      path: path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    )
  }

  public static func resolveExistingFile(
    _ artifact: TicketDecisionArtifact,
    in workspaceURL: URL
  ) throws -> URL {
    let target: URL
    do {
      target = try DemoLaunchSpecificationValidator.resolveWorkspacePath(
        artifact.path,
        in: workspaceURL
      )
    } catch {
      throw TicketDecisionArtifactValidationError.invalid(error.localizedDescription)
    }
    do {
      try DemoArtifactPolicy.validateExistingFile(at: target)
    } catch {
      throw TicketDecisionArtifactValidationError.invalid(error.localizedDescription)
    }
    return target
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
    Spedito advanced this ticket workspace from immutable candidate
    \(candidateHeadSHA) to reviewed integration \(integratedSHA). The current files now include
    accepted trunk changes and any integrator resolution. Treat the current workspace as the source
    of truth, preserve compatible accepted behaviour, and apply the requested correction on top.
    Do not undo or recreate this Git handoff; Spedito owns Git state.
    """
  }
}

public enum TechLeadReviewGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)
  case changesRequestedWithoutFinding

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The tech lead returned an invalid review result: \(detail)"
    case .changesRequestedWithoutFinding:
      "The tech lead requested changes without identifying a concrete blocking finding."
    }
  }
}

public enum CodexTicketExecutor {

  public static func developerInstructions(
    productInstructions: String,
    customInstructions: String,
    assignee: AgentProfile,
    savedPermissionGrants: [AgentPermissionGrant] = []
  ) -> String {
    let lifecycle = CodexLifecycleGuidance.ticketDeliveryInstructions(
      mode: CodexTicketDeliveryMode(assignee: assignee)
    )
    return """
      \(lifecycle)

      ASSIGNED TEAM MEMBER
      \(assignee.name) — \(assignee.role.title)

      \(AgentPermissionGrantPolicy.agentContext(for: savedPermissionGrants))

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
    let criteria =
      item.acceptanceCriteria.isEmpty
      ? "No acceptance criteria supplied."
      : item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let dependencyContext =
      prerequisites.isEmpty
      ? "No prerequisites."
      : prerequisites.map { prerequisite in
        let criteria =
          prerequisite.acceptanceCriteria.isEmpty
          ? "  - No acceptance criteria supplied."
          : prerequisite.acceptanceCriteria.map { "  - \($0)" }.joined(separator: "\n")
        let comments = prerequisiteComments[prerequisite.id, default: []]
          .suffix(20)
          .map { "  - \($0.authorName): \($0.agentContextBody)" }
          .joined(separator: "\n")
        return """
          - \(prerequisite.key) [\(prerequisite.state.title)]: \(prerequisite.title)
            Context: \(prerequisite.body.isEmpty ? "No additional context." : prerequisite.body)
            Acceptance criteria:
          \(criteria)
            Recent work log:
          \(comments.isEmpty ? "  - No prerequisite comments." : comments)
          """
      }.joined(separator: "\n")
    let dependantContext =
      dependants
      .filter { $0.state != .cancelled }
      .map { dependant in
        let criteria =
          dependant.acceptanceCriteria.isEmpty
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
    let history =
      relevantTicketComments.isEmpty
      ? "No ticket comments."
      : relevantTicketComments.suffix(40).map { "- \($0.authorName): \($0.agentContextBody)" }
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
    let directory =
      knowledgeDirectory.isEmpty
      ? "No canonical knowledge destinations were supplied."
      : knowledgeDirectory.map { page in
        let access: String
        switch page.kind {
        case .section:
          access =
            knowledgeDestinationIDs.contains(page.id)
            ? "Create child pages allowed"
            : "Routing reference only"
        case .page:
          if knowledgeDestinationIDs.contains(page.id) {
            access =
              referencePageIDs.contains(page.id)
              ? "Update allowed; current body is in the verified context above"
              : "Update allowed; this page is currently empty"
          } else if referencePageIDs.contains(page.id) {
            access = "Read-only reference for this run; do not update"
          } else {
            access =
              "Routing reference only; do not update because its current body was not supplied"
          }
        case .deliveryNote:
          access = "Ticket history only; never update"
        }
        let path = KnowledgeContextSelector.directoryPath(
          for: page,
          pages: knowledgeDirectory
        )
        let purpose = KnowledgeContextSelector.purpose(for: page.slug, kind: page.kind)
        return
          "- Path: \(path); page title: \(page.title) [\(page.kind.rawValue), page ID: \(page.id.uuidString)] — \(access). \(purpose)"
      }.joined(separator: "\n")
    let existingScope =
      existingItems
      .filter {
        $0.id != item.id && $0.state != .cancelled && $0.state != .released
      }
      .map { "- \($0.key) [\($0.type.title)]: \($0.title)" }
      .joined(separator: "\n")

    return """
      Product: \(product.name)
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
      reword, or split them into follow-up proposals. Use the completion handoff and verified product
      knowledge to give them the decisions and operating details they need. Return an empty
      followUpTicketProposals array when they and the existing active scope cover the work.

      Ticket work log comments:
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
    let history =
      recentComments
      .filter { !$0.body.hasPrefix("Permission requested:") }
      .suffix(20)
      .map { "- \($0.authorName): \($0.agentContextBody)" }
      .joined(separator: "\n")
    return """
      Continue work on \(item.key): \(item.title).

      \(reviewer.name) requested changes:
      \(feedback)

      Recent work log comments:
      \(history)

      Workspace baseline:
      \(adoptedBaseline?.promptContext ?? "The ticket workspace remains on the immutable candidate reviewed above.")


      A review finding that asks for missing evidence remains implementation work.
      \(CodexLifecycleGuidance.failedCheckRecovery)

      Address the review findings in the existing workspace, rerun relevant checks, and update
      documentation and delivery notes only to match verified final behavior. Do not document a
      failed check as a product limitation. Then return the structured execution result.
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
        Continue in the existing conversation and ticket workspace. Use the implementation work,
        decisions, and evidence already present there.
        """
      } else {
        """
        The previous conversation is unavailable, but the existing ticket workspace and its changes
        have been preserved. Treat the current workspace as the source of truth for completed work.
        """
      }
    let permissionContext = CodexLifecycleGuidance.permissionRecoveryContext(
      for: interruptedPermission
    )
    let workLogContext =
      recentComments
      .filter { !$0.body.hasPrefix("Permission requested:") }
      .suffix(12)
      .map { "- \($0.authorName): \($0.agentContextBody)" }
      .joined(separator: "\n")

    return """
      Continue the existing implementation of \(item.key) — \(item.title).

      Spedito is starting a continuation turn after the previous turn stopped or paused.
      \(conversationContext)
      Do not restart the ticket, discard partial changes, redo completed work, or repeat checks
      merely because a new turn started. Inspect the current diff and rerun a check only when needed
      to finish or validate the remaining work.

      \(CodexLifecycleGuidance.failedCheckRecovery)

      Workspace baseline:
      \(adoptedBaseline?.promptContext ?? "Spedito has not changed the ticket workspace baseline for this continuation.")

      \(permissionContext)

      Recent ticket work log:
      \(workLogContext.isEmpty ? "No new work log context." : workLogContext)

      Apply the latest product owner or reviewer direction above, finish the remaining authorised
      work, and return the complete structured execution result. If another material product owner
      decision is required, return awaiting_owner under the existing contract.
      """
  }

  public static func repairPrompt(validationError: String) -> String {
    """
    Your previous execution result could not be accepted:
    \(validationError)

    Continue the authorised ticket work in the existing workspace. Do not merely rewrite the JSON
    or describe work you intend to do. Complete the ticket's actual durable outcome, run at least
    one relevant check, and provide specific product owner review instructions that refer only to
    evidence that now exists. Research may persist its outcome in the completion handoff and
    proposed product knowledge without creating a repository file solely as delivery evidence.
    Product-changing work must still leave its inspectable repository changes and managed demo.
    If a material product owner decision, credential, secret, or external service prevents completion
    after handling any required scoped capability, return awaiting_owner instead. A missing
    sandbox filesystem or network capability is not an unavailable external dependency: use the
    available `request_permissions` tool rather than asking the product owner to restore, enable,
    add, or confirm access in an ordinary work log question. For awaiting_owner, return one question
    and two to four options, empty knowledgePageProposals and followUpTicketProposals, and a null
    demo. Put any existing workspace evidence needed for the decision in decisionArtifact; do not
    turn an undecided outcome into a product knowledge proposal. Return only the JSON required by
    the supplied schema.
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
        .string("decisionArtifact"),
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
          "description": .string(
            "Use awaiting_owner only for an unresolved product owner decision; it is not completion."
          ),
          "enum": .array([
            .string(TicketExecutionStatus.completed.rawValue),
            .string(TicketExecutionStatus.awaitingOwner.rawValue),
          ]),
        ]),
        "comment": .object(["type": .string("string")]),
        "question": .object([
          "description": .string(
            "One decision question for awaiting_owner; null for completed."
          ),
          "anyOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("null")]),
          ]),
        ]),
        "options": .object([
          "type": .string("array"),
          "description": .string(
            "Two to four decision options for awaiting_owner; empty for completed."
          ),
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
        "decisionArtifact": nullableDecisionArtifactSchema,
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
          "description": .string(
            "Final candidate-bound product knowledge proposals. Must be empty for awaiting_owner."
          ),
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
              "title": .object([
                "type": .string("string"),
                "description": .string(
                  "For an update, copy the target page's existing leaf title exactly; never use its breadcrumb path. For a creation, use only the new child page's leaf title."
                ),
              ]),
              "proposedBodyMarkdown": .object(["type": .string("string")]),
              "rationale": .object(["type": .string("string")]),
            ]),
          ]),
        ]),
        "followUpTicketProposals": .object([
          "type": .string("array"),
          "description": .string(
            "Final research follow-up proposals. Must be empty for awaiting_owner."
          ),
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
    let decisionArtifact = try generated.decisionArtifact.map {
      try TicketDecisionArtifactValidator.normalized($0)
    }
    guard !comment.isEmpty else {
      throw TicketExecutionGenerationError.invalidResponse("A work log comment is required.")
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
    } else if decisionArtifact != nil {
      throw TicketExecutionGenerationError.invalidResponse(
        "Completed results must use their managed demo rather than decisionArtifact."
      )
    }
    let summary = generated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let changedFiles = clean(generated.changedFiles)
    let tests = clean(generated.tests)
    var reviewInstructions = clean(generated.reviewInstructions)
    if let decisionArtifact {
      let normalizedChangedFiles = Set(
        changedFiles.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
      )
      guard normalizedChangedFiles.contains(decisionArtifact.path) else {
        throw TicketExecutionGenerationError.invalidResponse(
          "decisionArtifact must also be listed in changedFiles."
        )
      }
    }
    if generated.status == .completed {
      guard !summary.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Completed results need a concise outcome summary."
        )
      }
      guard !tests.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Completed results need at least one check that was actually performed."
        )
      }
      guard !reviewInstructions.isEmpty else {
        throw TicketExecutionGenerationError.invalidResponse(
          "Completed results need one to six specific product owner review instructions."
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
      decisionArtifact: decisionArtifact,
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
        "Only an assigned business analyst may propose follow-up tickets from authorised "
          + "research, discovery, or decision work."
      )
    }
  }

  public static func validateKnowledgePageProposals(
    in result: TicketExecutionResult,
    canonicalPages: [KnowledgePage],
    writablePageIDs: Set<UUID>
  ) throws {
    let pagesByID = Dictionary(
      uniqueKeysWithValues: canonicalPages.map { ($0.id, $0) }
    )
    for proposal in result.knowledgePageProposals {
      switch proposal.operation {
      case .update:
        guard
          let targetPageID = proposal.targetPageID,
          let targetPage = pagesByID[targetPageID]
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page update referenced a page that does not exist."
          )
        }
        guard targetPage.kind == .page, writablePageIDs.contains(targetPageID) else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page update referenced a page that was not writable for this run."
          )
        }
        guard proposal.title == targetPage.title else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page update must keep the existing page title “\(targetPage.title)”. "
              + "Use that leaf title exactly, not its breadcrumb path."
          )
        }
      case .create:
        guard
          let parentPageID = proposal.parentPageID,
          let parentPage = pagesByID[parentPageID]
        else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page creation referenced a section that does not exist."
          )
        }
        guard parentPage.kind == .section, writablePageIDs.contains(parentPageID) else {
          throw TicketExecutionGenerationError.invalidResponse(
            "A canonical-page creation referenced a section that was not writable for this run."
          )
        }
      }
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

  private static var nullableDecisionArtifactSchema: JSONValue {
    .object([
      "description": .string(
        "Workspace evidence for an awaiting_owner decision. Use null for completed results."
      ),
      "anyOf": .array([
        .object([
          "type": .string("object"),
          "additionalProperties": .bool(false),
          "required": .array([
            .string("title"),
            .string("path"),
          ]),
          "properties": .object([
            "title": .object([
              "type": .string("string"),
              "description": .string("Short product owner-facing evidence title."),
            ]),
            "path": .object([
              "type": .string("string"),
              "description": .string(
                "Workspace-relative file path also present in changedFiles."
              ),
            ]),
          ]),
        ]),
        .object(["type": .string("null")]),
      ]),
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

  static var demoLaunchSpecificationSchema: JSONValue {
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
    return specification
  }

  private static var nullableDemoLaunchSpecificationSchema: JSONValue {
    .object([
      "description": .string(
        "Managed review recipe for a completed candidate. Must be null for awaiting_owner."
      ),
      "anyOf": .array([
        demoLaunchSpecificationSchema,
        .object(["type": .string("null")]),
      ]),
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
  let decisionArtifact: TicketDecisionArtifact?
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

  public static let allowsApprovals = false

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
    knowledgePageProposals: [KnowledgePageProposal],
    assignee: AgentProfile,
    reviewCycle: Int = 0,
    priorReviewFeedback: String? = nil,
    recentComments: [TicketComment] = [],
    deliveryKind: CandidateDeliveryKind = .repositoryChange,
    baseSHA: String? = nil,
    candidateHeadSHA: String? = nil,
    integratedSHA: String? = nil
  ) -> String {
    let criteria = item.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
    let revision =
      if deliveryKind == .localOutcome {
        """
        Immutable local outcome under review:
        - Candidate outcome version is persisted in Spedito.
        - No repository files or Git revision are part of this delivery.
        Review the candidate-bound completion handoff, reported evidence, recent work log, and
        proposed product knowledge below. The detached workspace is contextual only.
        """
      } else if let baseSHA, let candidateHeadSHA, let integratedSHA {
        """
        Immutable integrated revision under review:
        - Delivered candidate range: \(baseSHA)..\(candidateHeadSHA)
        - Integrated revision: \(integratedSHA)
        The current detached integration workspace already combines the delivered candidate with
        the latest accepted local trunk and the verified GitHub default-branch head.
        Review this exact integrated result once.
        """
      } else if let baseSHA, let candidateHeadSHA {
        """
        Immutable revision under review:
        - Candidate range: \(baseSHA)..\(candidateHeadSHA)
        - Candidate revision: \(candidateHeadSHA)
        Inspect that exact range and the current detached candidate workspace.
        """
      } else {
        "No immutable revision metadata was supplied."
      }
    let knowledgeProposals =
      knowledgePageProposals.isEmpty
      ? "No canonical knowledge-page changes were proposed."
      : knowledgePageProposals.enumerated().map { index, proposal in
        let destination =
          if let targetPageID = proposal.targetPageID {
            "Existing page ID: \(targetPageID.uuidString)"
          } else if let parentPageID = proposal.parentPageID {
            "Parent section ID: \(parentPageID.uuidString)"
          } else {
            "No valid destination was recorded."
          }
        let baseSnapshot: String
        if proposal.operation == .update {
          let body =
            proposal.basePageBodyMarkdown.flatMap { body in
              body.isEmpty ? nil : body
            } ?? "[The candidate-captured page body was empty.]"
          baseSnapshot = """
            Candidate-captured base title: \(proposal.basePageTitle ?? proposal.title)
            Candidate-captured base Markdown:
            ----- BEGIN BASE MARKDOWN -----
            \(body)
            ----- END BASE MARKDOWN -----
            """
        } else {
          baseSnapshot = "This proposal creates a child page, so there is no base page body."
        }
        return """
          Proposal \(index + 1):
          - Proposal ID: \(proposal.id.uuidString)
          - Candidate revision ID: \(proposal.candidateRevisionID.uuidString)
          - Operation: \(proposal.operation.rawValue)
          - Title: \(proposal.title)
          - Destination: \(destination)
          - Candidate-bound status: \(proposal.status.rawValue)
          - Rationale: \(proposal.rationale)

          \(baseSnapshot)

          Proposed complete Markdown:
          ----- BEGIN PROPOSED MARKDOWN -----
          \(proposal.proposedBodyMarkdown)
          ----- END PROPOSED MARKDOWN -----
          """
      }.joined(separator: "\n\n")
    let followUpProposals =
      implementation.followUpTicketProposals.isEmpty
      ? "No follow-up tickets were proposed."
      : implementation.followUpTicketProposals.map { proposal in
        let acceptanceCriteria =
          proposal.acceptanceCriteria.isEmpty
          ? "- No acceptance criteria supplied."
          : proposal.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
        let dependencies =
          proposal.dependsOnReferences.isEmpty
          ? "None"
          : proposal.dependsOnReferences.joined(separator: ", ")
        return """
          - \(proposal.reference): \(proposal.title)
            Type: \(proposal.type.title)
            Suggested team member: \(proposal.suggestedRole.title)
            Priority: \(proposal.priority.title)
            Body: \(proposal.body)
            Acceptance criteria:
          \(acceptanceCriteria)
            Depends on proposed references: \(dependencies)
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
        This is the initial review. Make one focused read-only pass over the delivered evidence and
        decide whether it is good enough for product owner demonstration. Do not reproduce delivery
        checks or execute the candidate.
        """
    }
    let history =
      recentComments
      .filter {
        $0.body != "I’m reviewing the implementation and its evidence against the ticket."
          && !$0.body.hasPrefix("Permission requested:")
      }
      .suffix(12)
      .map { "- \($0.authorName): \($0.body)" }
      .joined(separator: "\n")
    return """
      Product: \(product.name)
      Ticket: \(item.key) — \(item.title)
      Delivered by: \(assignee.name) — \(assignee.role.title)
      Context: \(item.body)
      Acceptance criteria:
      \(criteria)

      \(reviewMode)

      \(revision)

      Implementer's candidate-bound completion comment:
      \(implementation.comment)

      Implementer's completion handoff:
      \(implementation.summary)

      Reported changed files:
      \(implementation.changedFiles.isEmpty
        ? "No repository files changed."
        : implementation.changedFiles.map { "- \($0)" }.joined(separator: "\n"))

      Reported checks:
      \(implementation.tests.map { "- \($0)" }.joined(separator: "\n"))

      Product owner review instructions:
      \(implementation.reviewInstructions.map { "- \($0)" }.joined(separator: "\n"))

      Managed demo recipe:
      \(demoRecipe)

      Proposed durable knowledge:
      \(implementation.knowledgeNotes.map { "- \($0)" }.joined(separator: "\n"))

      Proposed canonical knowledge changes:
      \(knowledgeProposals)

      Candidate-bound product knowledge lifecycle:
      - The proposal records above belong to the exact candidate revision under review. Review their
        complete proposed Markdown and candidate-captured base snapshots as delivery evidence.
      - `agent_verified_knowledge` contains accepted canonical knowledge only. It is expected to remain
        unchanged while these proposals are under review. Do not require a pending proposal to be
        published there, or duplicated in an ordinary repository document, before approval.
      - Tech lead approval makes an accurate proposal eligible for candidate materialization. The
        reviewed Markdown becomes canonical product knowledge only when the product owner accepts the
        ticket. A missing, materially inaccurate, or destructive proposal may still block approval.

      Proposed follow-up tickets:
      \(followUpProposals)

      Recent ticket work log:
      \(history.isEmpty ? "No earlier work log context." : history)

      \(deliveryKind.changesRepository
        ? "Inspect the exact immutable workspace using repository and file reads only."
        : "Review the exact persisted local outcome supplied above; do not require a repository diff or duplicate document.")
      Return the bounded review described above. Do not run checks, launch the product or demo,
      browse external sources, or request permissions. Treat a materially inaccurate canonical
      knowledge proposal as a blocker; minor incompleteness can be noted without preventing
      demonstration.
      """
  }

  public static func recoveryPrompt(
    item: WorkItem,
    reviewedSHA: String,
    isIntegratedRevision: Bool,
    interruptedPermission: AgentPermissionRequest?
  ) -> String {
    let permissionContext =
      interruptedPermission == nil
      ? "No earlier review capability request was recorded."
      : """
      An earlier version of the review contract attempted a capability request. It is obsolete for
      this evidence-only review. Do not reissue it or repeat the operation that prompted it.
      """

    return """
      Continue the existing tech lead review for \(item.key) — \(item.title).

      Spedito restarted while the previous turn was incomplete. The candidate has not
      changed, and the detached workspace is still pinned to \(isIntegratedRevision ? "integrated" : "candidate") revision \(reviewedSHA).
      Use the review work and evidence already present in this conversation. Do not restart a full
      review, widen the ticket scope, run or repeat checks, launch the candidate, research external
      sources, request permissions, or redo implementation.

      \(permissionContext)

      Finish the remaining focused inspection and return the complete structured tech lead review.
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
