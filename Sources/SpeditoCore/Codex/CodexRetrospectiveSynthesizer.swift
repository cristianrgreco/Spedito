import Foundation

public struct RetrospectiveSynthesisActionDraft: Equatable, Sendable {
  public let body: String
  public let destination: RetrospectiveActionDestination
  public let expectedEffect: String
  public let sourceNoteIDs: [UUID]

  public init(
    body: String,
    destination: RetrospectiveActionDestination,
    expectedEffect: String,
    sourceNoteIDs: [UUID]
  ) {
    self.body = body
    self.destination = destination
    self.expectedEffect = expectedEffect
    self.sourceNoteIDs = sourceNoteIDs
  }
}

public enum RetrospectiveSynthesisGenerationError:
  Error, Equatable, LocalizedError, Sendable
{
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The Business Analyst returned invalid retrospective actions: \(detail)"
    }
  }
}

public enum CodexRetrospectiveSynthesizer {
  public static let maximumActionCount = 5

  private static let platformInstructions = """
    You are the Business Analyst facilitating a sprint retrospective for a non-technical Product
    Owner. This is a read-only synthesis task. Do not modify files, browse the web, or make decisions on
    the Product Owner's behalf. You may use read-only local tools to query the live product database and
    inspect product Git history. Return only the JSON requested by the output schema.

    The supplied notes are immutable evidence. Several agents may describe the same underlying
    problem or proposed remedy in different words. Consolidate them by the single decision the
    Product Owner would take, not by superficial keyword overlap. Repetition is supporting
    evidence, not a reason to create another action. Keep genuinely different interventions
    separate even when they share a broad theme.

    Return no more than five final actions. Fewer actions are better when the evidence does not
    justify five. Every action must be concise, supported by one or more supplied evidence
    references, and state an observable expected effect. Do not create an action for generic
    praise, an isolated low-value preference, or work already covered by an existing practice,
    retrospective decision, or active backlog ticket.

    Before returning an action, confirm that accepting it can achieve its stated effect through the
    selected destination. Accepting team_practice only adds its text to verified Ways of working
    inherited by future runs; it cannot install, provision, configure, authorise, or make available
    a runtime, service, account, credential, permission, automation, or other capability. A team
    practice must describe conduct a future team member can carry out using capabilities that
    already exist, such as attempting required checks early and requesting scoped access when
    blocked. Do not use a retrospective action to excuse or defer missing required verification
    from the completed ticket. Use destination team_practice when accepting the action should
    directly change inherited guidance. Use destination backlog when the improvement requires
    tangible implementation, provisioning tooling, or another durable deliverable. Do not create
    backlog work merely to edit team guidance. Before returning, compare every pair of actions and
    combine any that would ask the Product Owner to make substantially the same decision.
    """

  public static func developerInstructions(
    productInstructions: String,
    customInstructions: String
  ) -> String {
    return """
      \(platformInstructions)

      \(CodexLifecycleGuidance.configuredRoleGuidance(
        role: .businessAnalyst,
        productInstructions: productInstructions,
        customInstructions: customInstructions
      ))
      """
  }

  public static func prompt(
    product: Product,
    sprint: Sprint,
    sourceNotes: [RetrospectiveNote],
    workItems: [WorkItem],
    existingActions: [RetrospectiveNote],
    waysOfWorking: String
  ) -> String {
    let itemByID = Dictionary(uniqueKeysWithValues: workItems.map { ($0.id, $0) })
    let evidence = referencedNotes(sourceNotes).map { reference, note in
      let ticket = note.workItemID.flatMap { itemByID[$0]?.key } ?? "Sprint"
      let kind =
        if note.isActionCandidate {
          note.authorName == "Product Owner"
            ? "Product Owner action candidate"
            : "Agent action candidate"
        } else {
          note.category.title
        }
      return "- \(reference) [\(kind) · \(ticket) · \(note.authorName)]: \(note.body)"
    }.joined(separator: "\n")

    let activeScope = workItems
      .filter { $0.state != .cancelled && $0.state != .released }
      .map { "- \($0.key) [\($0.type.title)]: \($0.title)" }
      .joined(separator: "\n")

    let priorDecisions = existingActions
      .filter { !$0.isActionCandidate }
      .map { action in
        let status = action.actionStatus?.rawValue ?? "recorded"
        return "- [\(status) · \(action.actionDestination?.title ?? "Ways of working")]: \(action.body)"
      }
      .joined(separator: "\n")

    let practices = waysOfWorking.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      Prepare the final reviewable actions for Sprint \(sprint.number).

      Product: \(product.name)
      Frozen sprint evidence:
      \(evidence.isEmpty ? "No retrospective evidence was recorded." : evidence)

      Existing Ways of working:
      \(practices.isEmpty ? "No verified practices are recorded." : practices)

      Existing retrospective actions and decisions:
      \(priorDecisions.isEmpty ? "No earlier or Product Owner actions are recorded." : priorDecisions)

      Active backlog scope:
      \(activeScope.isEmpty ? "No active backlog tickets." : activeScope)

      Return zero to five actions. Use the exact E references shown above in sourceReferences.
      Multiple references may support one action. It is valid to return an empty actions array when
      the evidence is not actionable or existing work already covers it. Preserve recurring evidence
      by linking every relevant source to the one consolidated action rather than repeating the action.
      """
  }

  public static func repairPrompt(validationError: String) -> String {
    """
      Your previous retrospective synthesis could not be used:
      \(validationError)

      Return the complete corrected synthesis again. Use only the supplied E references, include at
      least one source per action, return no more than five actions, and combine actions that ask the
      Product Owner to make substantially the same decision.
      """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("actions")]),
      "properties": .object([
        "actions": .object([
          "type": .string("array"),
          "maxItems": .integer(Int64(maximumActionCount)),
          "items": .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
              .string("body"),
              .string("destination"),
              .string("expectedEffect"),
              .string("sourceReferences"),
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
              "expectedEffect": .object(["type": .string("string")]),
              "sourceReferences": .object([
                "type": .string("array"),
                "minItems": .integer(1),
                "items": .object(["type": .string("string")]),
              ]),
            ]),
          ]),
        ])
      ]),
    ])
  }

  public static func decode(
    _ text: String,
    sourceNotes: [RetrospectiveNote]
  ) throws -> [RetrospectiveSynthesisActionDraft] {
    guard let data = text.data(using: .utf8) else {
      throw RetrospectiveSynthesisGenerationError.invalidResponse(
        "The response was not UTF-8."
      )
    }
    let generated: GeneratedResponse
    do {
      generated = try JSONDecoder().decode(GeneratedResponse.self, from: data)
    } catch {
      throw RetrospectiveSynthesisGenerationError.invalidResponse(
        error.localizedDescription
      )
    }
    guard generated.actions.count <= maximumActionCount else {
      throw RetrospectiveSynthesisGenerationError.invalidResponse(
        "Expected no more than five actions."
      )
    }

    let references = Dictionary(
      uniqueKeysWithValues: referencedNotes(sourceNotes).map {
        ($0.reference.uppercased(), $0.note.id)
      }
    )
    var normalizedBodies: Set<String> = []
    return try generated.actions.map { action in
      let body = action.body.trimmingCharacters(in: .whitespacesAndNewlines)
      let expectedEffect = action.expectedEffect.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      let sourceReferences = action.sourceReferences.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      }
      guard !body.isEmpty, !expectedEffect.isEmpty, !sourceReferences.isEmpty else {
        throw RetrospectiveSynthesisGenerationError.invalidResponse(
          "Every action needs a description, expected effect, and supporting evidence."
        )
      }
      guard Set(sourceReferences).count == sourceReferences.count else {
        throw RetrospectiveSynthesisGenerationError.invalidResponse(
          "An action cannot repeat an evidence reference."
        )
      }
      let sourceNoteIDs = try sourceReferences.map { reference in
        guard let noteID = references[reference] else {
          throw RetrospectiveSynthesisGenerationError.invalidResponse(
            "\(reference) is not a supplied evidence reference."
          )
        }
        return noteID
      }
      let normalizedBody = String(
        body.lowercased().filter { $0.isLetter || $0.isNumber }
      )
      guard normalizedBodies.insert(normalizedBody).inserted else {
        throw RetrospectiveSynthesisGenerationError.invalidResponse(
          "Final actions must not contain duplicate descriptions."
        )
      }
      return RetrospectiveSynthesisActionDraft(
        body: body,
        destination: action.destination,
        expectedEffect: expectedEffect,
        sourceNoteIDs: sourceNoteIDs
      )
    }
  }

  private static func referencedNotes(
    _ notes: [RetrospectiveNote]
  ) -> [(reference: String, note: RetrospectiveNote)] {
    notes
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.createdAt < $1.createdAt
      }
      .enumerated()
      .map { ("E\($0.offset + 1)", $0.element) }
  }
}

private struct GeneratedResponse: Codable {
  let actions: [GeneratedAction]
}

private struct GeneratedAction: Codable {
  let body: String
  let destination: RetrospectiveActionDestination
  let expectedEffect: String
  let sourceReferences: [String]
}
