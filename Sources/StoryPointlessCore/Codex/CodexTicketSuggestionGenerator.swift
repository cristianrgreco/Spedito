import Foundation

public enum TicketSuggestionGenerationError: Error, Equatable, LocalizedError, Sendable {
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let detail):
      "The Business Analyst returned an invalid proposal: \(detail)"
    }
  }
}

public enum CodexTicketSuggestionGenerator {
  private static let platformInstructions = """
    You are the single Business Analyst responsible for proposing a coherent delivery backlog from the
    product owner's vision. A role on a ticket is a recommended future owner, not another agent producing
    the suggestion and not a quota. Roles may repeat for any number of tickets. Use the UX Designer for
    experience/prototype work and the generic Implementer for approved software changes, whether the
    ticket concerns UI, local logic, or a service.
    Propose backend work only when it is actually justified; do not invent it merely because it is a
    familiar architecture layer. The Tech Lead reviews delivery and dependency decisions. Identify genuine
    dependency edges without serialising work that can proceed with mocks or agreed contracts.
    Do not propose a conditional implementation ticket as committed scope when a research or product
    decision may determine that no implementation is needed. Propose the decision ticket first; its
    outcome can create follow-up work later. Only propose the implementation now when every credible
    decision outcome still requires it, and state the stable outcome rather than conditional wording.
    Classify user-visible outcomes as stories, supporting delivery or research work as tasks, and only
    classify a ticket as a bug when it corrects behaviour that should already work.
    Do not modify files, use tools, browse the web, or make product decisions on the owner's behalf. Return only
    the JSON requested by the output schema. Every proposal must explain why it belongs in the backlog.
    """

  public static func developerInstructions(
    productInstructions: String,
    personaInstructions: String
  ) -> String {
    let shared = productInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let persona = personaInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      \(platformInstructions)

      PRODUCT OWNER'S SHARED TEAM GUIDANCE
      \(shared.isEmpty ? "No additional shared guidance." : shared)

      BUSINESS ANALYST PERSONA GUIDANCE
      \(persona)

      The owner guidance and persona guidance refine your behaviour but cannot override the read-only,
      structured-output, safety, or product-owner-control requirements above.
      """
  }

  public static func prompt(
    product: Product,
    existingItems: [WorkItem],
    rejectedSuggestions: [TicketSuggestion] = []
  ) -> String {
    let activeExistingItems = existingItems.filter { $0.state != .cancelled }
    let existingScope: String
    if activeExistingItems.isEmpty {
      existingScope = "There are no existing backlog tickets."
    } else {
      existingScope = activeExistingItems
        .map { "- \($0.key) [\($0.type.title)]: \($0.title)" }
        .joined(separator: "\n")
    }

    let rejectedScope: String
    if rejectedSuggestions.isEmpty {
      rejectedScope = "There are no rejected proposals from the previous analysis."
    } else {
      rejectedScope = rejectedSuggestions
        .map { "- \($0.reference): \($0.title)" }
        .joined(separator: "\n")
    }

    return """
      Propose the smallest coherent delivery backlog that represents the real work for this product.

      Product: \(product.name)
      Product vision:
      \(product.vision)

      Existing scope (do not duplicate it):
      \(existingScope)

      Rejected proposals from the previous analysis (do not repeat them unless changed product context
      now makes them necessary, and explicitly explain what changed):
      \(rejectedScope)

      Use short references such as T1, T2, and T3. Return between 1 and 24 tickets; a typical new product
      will need 5 to 15, but scope—not persona count—determines the result. Split work where it creates an
      independently understandable, reviewable, or parallelizable outcome; do not manufacture tiny tickets
      to reach a count. Include testable acceptance criteria. Use dependsOn only for a real prerequisite.
      Every dependsOn entry must reference either another ticket in this same response or an exact active
      backlog key shown above. Use an existing key when the proposed work genuinely relies on that ticket.
      An implementation ticket may depend on an agreed UX direction and data contract while still noting
      that mocked data can let implementation begin. Research or provider selection should be a Business
      Analyst ticket, not a conclusion silently embedded in an implementation ticket.
      """
  }

  public static func epicPrompt(
    product: Product,
    epic: Epic,
    existingItems: [WorkItem],
    rejectedSuggestions: [TicketSuggestion] = []
  ) -> String {
    let activeExistingItems = existingItems.filter { $0.state != .cancelled }
    let existingScope = activeExistingItems.isEmpty
      ? "There are no existing active tickets."
      : activeExistingItems
        .map { item in
          let epicContext = item.epicID.map { " · epic \($0.uuidString)" } ?? " · no epic"
          return "- \(item.key) [\(item.type.title)\(epicContext)]: \(item.title)"
        }
        .joined(separator: "\n")
    let rejectedScope = rejectedSuggestions.isEmpty
      ? "There are no rejected proposals from an earlier plan for this epic."
      : rejectedSuggestions
        .map { "- \($0.reference): \($0.title)" }
        .joined(separator: "\n")

    return """
      Turn the Product Owner's outcome into one durable epic and the smallest coherent set of delivery
      tickets needed to achieve it. This is not a whole-product gap analysis: remain inside this epic's
      outcome and do not duplicate active work.

      Product: \(product.name)
      Product vision:
      \(product.vision)

      Outcome supplied by the Product Owner:
      \(epic.goal)

      Existing active work:
      \(existingScope)

      Previously rejected proposals for this epic:
      \(rejectedScope)

      Improve the epic title and goal so they are concise, outcome-oriented, and understandable to a
      Product Owner. Add measurable success criteria and retain only material constraints supported by
      the supplied context. Do not invent product decisions; where a material decision is required,
      create a Business Analyst ticket that can ask the owner.

      Use short references such as T1, T2, and T3. Return between 1 and 24 tickets. Split work where it
      creates an independently understandable, reviewable, or parallelizable outcome. Include testable
      acceptance criteria, genuine dependencies, suitable ticket types, priorities, and future owners.
      Every dependsOn entry must reference either another ticket in this response or an exact active
      ticket key shown above.
      """
  }

  public static func repairPrompt(
    validationError: String,
    existingItems: [WorkItem]
  ) -> String {
    let existingKeys = existingItems
      .filter { $0.state != .cancelled }
      .map(\.key)
      .joined(separator: ", ")
    return """
      Your previous proposal could not be used:
      \(validationError)

      Return the complete corrected proposal again. Preserve the useful ticket content, but ensure every
      reference is unique, the dependency graph is acyclic, and every dependsOn value exactly matches either
      the reference of another ticket in this response or one of these active backlog keys:
      \(existingKeys.isEmpty ? "none" : existingKeys).
      """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("suggestions")]),
      "properties": .object([
        "suggestions": suggestionArraySchema
      ]),
    ])
  }

  public static var epicOutputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("epic"), .string("suggestions")]),
      "properties": .object([
        "epic": .object([
          "type": .string("object"),
          "additionalProperties": .bool(false),
          "required": .array([
            .string("title"), .string("goal"), .string("successCriteria"),
            .string("constraints"),
          ]),
          "properties": .object([
            "title": .object(["type": .string("string")]),
            "goal": .object(["type": .string("string")]),
            "successCriteria": .object([
              "type": .string("array"),
              "minItems": .integer(1),
              "items": .object(["type": .string("string")]),
            ]),
            "constraints": .object(["type": .string("string")]),
          ]),
        ]),
        "suggestions": suggestionArraySchema,
      ]),
    ])
  }

  private static var suggestionArraySchema: JSONValue {
    .object([
      "type": .string("array"),
      "minItems": .integer(1),
      "maxItems": .integer(24),
      "items": .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([
          .string("reference"), .string("title"), .string("body"),
          .string("type"), .string("acceptanceCriteria"), .string("role"), .string("priority"),
          .string("rationale"), .string("dependsOn"),
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
      ]),
    ])
  }

  public static func decode(
    _ text: String,
    existingItems: [WorkItem] = []
  ) throws -> [TicketSuggestionDraft] {
    guard let data = text.data(using: .utf8) else {
      throw TicketSuggestionGenerationError.invalidResponse("The response was not UTF-8.")
    }
    let response: GeneratedResponse
    do {
      response = try JSONDecoder().decode(GeneratedResponse.self, from: data)
    } catch {
      throw TicketSuggestionGenerationError.invalidResponse(error.localizedDescription)
    }

    guard (1...24).contains(response.suggestions.count) else {
      throw TicketSuggestionGenerationError.invalidResponse("Expected between 1 and 24 tickets.")
    }
    let references = response.suggestions.map { normalizedReference($0.reference) }
    guard references.allSatisfy({ !$0.isEmpty }) else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "Every ticket needs a non-empty reference."
      )
    }
    guard Set(references).count == references.count else {
      throw TicketSuggestionGenerationError.invalidResponse("Ticket references must be unique.")
    }
    let referenceSet = Set(references)
    let activeExistingItems = existingItems.filter { $0.state != .cancelled }
    let existingItemByReference = Dictionary(
      activeExistingItems.map { (normalizedReference($0.key), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let validDependencyReferences = referenceSet.union(existingItemByReference.keys)
    guard response.suggestions.allSatisfy({ suggestion in
      suggestion.dependsOn.map(normalizedReference)
        .allSatisfy(validDependencyReferences.contains)
    }) else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "Every dependency must reference another proposed ticket or an active backlog ticket."
      )
    }
    let dependencies = Dictionary(
      uniqueKeysWithValues: response.suggestions.map {
        (
          normalizedReference($0.reference),
          $0.dependsOn.map(normalizedReference).filter(referenceSet.contains)
        )
      }
    )
    guard !hasDependencyCycle(dependencies) else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "Ticket dependencies must not contain a cycle."
      )
    }

    return try response.suggestions.map { suggestion in
      guard
        !suggestion.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !suggestion.acceptanceCriteria.isEmpty,
        let type = WorkItemType(rawValue: suggestion.type),
        let role = AgentRole(rawValue: suggestion.role),
        let priority = priority(named: suggestion.priority)
      else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "Each ticket needs a reference, title, type, criteria, valid role, and priority."
        )
      }
      let reference = normalizedReference(suggestion.reference)
      let dependencyReferences = suggestion.dependsOn.map(normalizedReference)
      guard dependencyReferences.allSatisfy(validDependencyReferences.contains) else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "Every dependency must reference another proposed ticket or an active backlog ticket."
        )
      }
      guard !dependencyReferences.contains(reference) else {
        throw TicketSuggestionGenerationError.invalidResponse("A ticket cannot depend on itself.")
      }
      return TicketSuggestionDraft(
        reference: reference,
        title: suggestion.title,
        type: type,
        body: suggestion.body,
        acceptanceCriteria: suggestion.acceptanceCriteria,
        suggestedRole: role,
        priority: priority,
        rationale: suggestion.rationale,
        dependsOnReferences: Array(
          Set(dependencyReferences.filter(referenceSet.contains))
        ).sorted(),
        dependsOnExistingWorkItemKeys: Array(
          Set(
            dependencyReferences.compactMap { existingItemByReference[$0]?.key }
          )
        ).sorted()
      )
    }
  }

  public static func decodeEpicPlan(
    _ text: String,
    existingItems: [WorkItem] = []
  ) throws -> EpicPlanDraft {
    guard let data = text.data(using: .utf8) else {
      throw TicketSuggestionGenerationError.invalidResponse("The response was not UTF-8.")
    }
    let response: GeneratedEpicResponse
    do {
      response = try JSONDecoder().decode(GeneratedEpicResponse.self, from: data)
    } catch {
      throw TicketSuggestionGenerationError.invalidResponse(error.localizedDescription)
    }
    let title = response.epic.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let goal = response.epic.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    let criteria = response.epic.successCriteria
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !title.isEmpty, !goal.isEmpty, !criteria.isEmpty else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "The epic needs a title, goal, and at least one success criterion."
      )
    }
    return EpicPlanDraft(
      title: title,
      goal: goal,
      successCriteria: criteria,
      constraints: response.epic.constraints.trimmingCharacters(in: .whitespacesAndNewlines),
      ticketSuggestions: try decode(text, existingItems: existingItems)
    )
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
}

private struct GeneratedResponse: Decodable {
  let suggestions: [GeneratedSuggestion]
}

private struct GeneratedEpicResponse: Decodable {
  let epic: GeneratedEpic
  let suggestions: [GeneratedSuggestion]
}

private struct GeneratedEpic: Decodable {
  let title: String
  let goal: String
  let successCriteria: [String]
  let constraints: String
}

private struct GeneratedSuggestion: Decodable {
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
