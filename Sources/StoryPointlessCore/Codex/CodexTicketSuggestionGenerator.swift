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
    Do not propose a conditional implementation ticket as committed scope when an unresolved product
    decision may determine that no implementation is needed. Consequential product choices belong in
    refinement, not in a ticket whose purpose is merely to ask the owner later. Create research or
    discovery work only when the Product Owner requested it or explicitly agreed that external evidence
    is needed before a responsible decision can be made. Such work must have a concrete comparison,
    recommendation, or decision-enabling output. Otherwise propose tickets that deliver the agreed
    outcome, not tickets that discover what the outcome should be. Desired constraints alone do not select
    a real external source when current evidence about candidates, terms, suitability, or operation is
    still needed. When the Product Owner authorises the Business Analyst or team to identify, compare,
    recommend, or choose such a source, treat that as authorised Business Analyst research and give it a
    separate ticket. Do not bury source selection inside design or implementation. Only assign selection
    to an implementer when the Product Owner explicitly chose implementation-time selection without a
    separate recommendation.
    Before proposing executable product work, inspect verified Environments knowledge and repository-owned
    manifests, scripts, CI, and documentation. Decide whether the current environment can build, test,
    prototype, demo, and locally run the planned outcome. Do not infer readiness from a runtime merely
    being installed somewhere on the Product Owner's Mac, scan the host for package managers, or silently
    pre-authorise machine paths. If the environment is insufficient, make a concrete Implementer-owned
    foundation task establish the approved toolchain, stable repository entry points, isolated temporary
    and cache locations, required capabilities, a managed demo with readiness evidence, and a verified
    Environments update. Create a separate Business Analyst research ticket before it only when the Product
    Owner authorised evidence gathering for a material stack, hosting, licensing, cost, maintenance, or
    deployment choice. Work that needs the missing environment must depend on the establishment task;
    research, product decisions, and neutral design artefacts that genuinely do not need it may proceed in
    parallel. Do not make an ordinary feature ticket rediscover or establish its environment incidentally.
    Classify user-visible outcomes as stories, supporting delivery or research work as tasks, and only
    classify a ticket as a bug when it corrects behaviour that should already work.
    Temporary proposal references belong only in the reference field. Never repeat one at the start
    of the owner-facing title; for example, use title "Choose a provider", not "S1 - Choose a provider".
    Do not modify files, browse the web, or make product decisions on the owner's behalf. You may use
    read-only local tools to query the live product database and inspect product Git history. Return only
    the JSON requested by the output schema. Every proposal must explain why it belongs in the backlog.
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

      Use temporary proposal references such as S1, S2, and S3. Return between 1 and 24 tickets; a typical
      new product will need 5 to 15, but scope—not persona count—determines the result. Split work where it
      creates an independently understandable, reviewable, or parallelizable outcome; do not manufacture
      tiny tickets to reach a count. Include testable acceptance criteria. Use dependsOn only for a real
      prerequisite. Every dependsOn entry must reference either another ticket in this same response or an
      exact active backlog key shown above. Use an existing key when the proposed work genuinely relies on
      that ticket.
      An implementation ticket may depend on an agreed UX direction and data contract while still noting
      that mocked data can let implementation begin. Research or provider selection should be a Business
      Analyst ticket, not a conclusion silently embedded in an implementation ticket.
      Return the top-level environmentAssessment using sufficient, foundation_required, or not_required
      with the same meanings as the output schema. Give a concise rationale. Set foundationTicketReference
      to null unless the environment is missing; then identify the exact proposed reference or active
      backlog key for the foundation.
      For every suggestion set environmentRelationship to independent when it needs no executable product
      environment, establishes when it creates or repairs the reusable delivery environment, or requires
      when it will build, test, run, prototype, or demo using that environment. If verified Environments
      guidance is absent or insufficient, include the establishment task and make every requires ticket
      depend on it. A Product Owner preference or a responsible recommendation must resolve the intended
      stack before that establishment task is delivered; do not use the task as a placeholder for asking
      the owner later.
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
      the supplied context. Use the decisions resolved in the preceding clarification conversation. Do
      not invent product decisions or disguise an unresolved Product Owner choice as a backlog ticket.
      A research or discovery ticket is valid only when the Product Owner explicitly requested research
      or agreed during clarification that external evidence is needed. Give such a ticket a time-bounded,
      decision-enabling output. An instruction for the Business Analyst or team to identify, compare,
      recommend, or choose a real external source using current evidence is explicit research
      authorisation, even when the Product Owner has already supplied the selection criteria. Create a
      separate Business Analyst ticket for that work and do not bury source selection inside a UX or
      implementation ticket. Only embed selection in implementation when the Product Owner explicitly
      chose implementation-time selection without a separate recommendation. Research is a prerequisite,
      not a substitute for delivery: when the epic's success criteria also describe a product change,
      include the downstream work needed to achieve it. Derive ticket boundaries from independently
      valuable outcomes, genuine dependencies, and useful parallelism; do not default to a fixed research,
      design, implementation, and verification sequence. Make verification explicit in the relevant
      acceptance criteria and create a separate design or verification ticket only when it produces a
      meaningful outcome that should be delivered, reviewed, or scheduled independently. Work that does
      not require the research conclusion may proceed in parallel, while work that does must depend on the
      approved output without guessing its conclusion. Never stop at a research ticket when the agreed
      outcome includes user-visible behaviour. Otherwise create tickets that deliver the agreed outcome.

      Assess delivery-environment readiness from verified Environments knowledge and repository evidence.
      In epic.environmentAssessment return:
      - sufficient when the existing verified environment covers the planned executable work;
      - foundation_required when an accepted existing ticket or one proposed Implementer task must establish
        the environment first; or
      - not_required when this epic has no executable product work.
      Give a concise rationale. foundationTicketReference must be null unless readiness is
      foundation_required; then it must identify the exact proposed reference or active ticket key that
      establishes the environment. Mark every suggestion's environmentRelationship as independent,
      establishes, or requires. Every requires ticket in a foundation_required plan must depend directly
      or transitively on foundationTicketReference. Do not block evidence research or a neutral design
      artefact that genuinely does not need the environment.

      An environment-establishment task is a concrete delivery outcome, not vague technical investigation.
      Its acceptance criteria cover the approved toolchain and supported versions; repository-owned build,
      test, local-run, and demo entry points; run-private temporary and cache locations; the complete
      filesystem, localhost, network, and service capability boundary; a successful managed readiness
      check; limitations; and a verified Environments Product knowledge update. Consider the intended
      deployment destination early when it affects the stack, but leave production accounts, credentials,
      signing identities, and irreversible release access to separately authorised release work.

      Use temporary proposal references such as S1, S2, and S3. Return between 1 and 24 tickets. Split work
      where it creates an independently understandable, reviewable, or parallelizable outcome. Include
      testable acceptance criteria, genuine dependencies, suitable ticket types, priorities, and future
      owners. Before returning, trace every epic success criterion to at least one delivery ticket and make
      sure the dependency graph reaches the agreed product outcome rather than ending at analysis. Every
      dependsOn entry must reference either another ticket in this response or an exact active ticket key
      shown above.
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
      Preserve or correct environmentAssessment and every environmentRelationship. If the assessment says
      foundation_required, its foundation ticket must exist and every requires ticket must depend on it
      directly or transitively.
      """
  }

  public static var outputSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([.string("environmentAssessment"), .string("suggestions")]),
      "properties": .object([
        "environmentAssessment": environmentAssessmentSchema,
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
            .string("constraints"), .string("environmentAssessment"),
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
            "environmentAssessment": environmentAssessmentSchema,
          ]),
        ]),
        "suggestions": suggestionArraySchema,
      ]),
    ])
  }

  private static var environmentAssessmentSchema: JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(false),
      "required": .array([
        .string("readiness"), .string("rationale"),
        .string("foundationTicketReference"),
      ]),
      "properties": .object([
        "readiness": .object([
          "type": .string("string"),
          "enum": .array(
            EpicEnvironmentReadiness.allCases.map { .string($0.rawValue) }
          ),
        ]),
        "rationale": .object(["type": .string("string")]),
        "foundationTicketReference": .object([
          "anyOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("null")]),
          ])
        ]),
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
          .string("rationale"), .string("dependsOn"), .string("environmentRelationship"),
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
          "environmentRelationship": .object([
            "type": .string("string"),
            "enum": .array(
              TicketEnvironmentRelationship.allCases.map { .string($0.rawValue) }
            ),
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
    let ticketSuggestions = try decodeSuggestions(
      response.suggestions,
      existingItems: existingItems
    )
    _ = try decodeEnvironmentAssessment(
      response.environmentAssessment,
      suggestions: response.suggestions,
      ticketSuggestions: ticketSuggestions,
      existingItems: existingItems
    )
    return ticketSuggestions
  }

  private static func decodeSuggestions(
    _ suggestions: [GeneratedSuggestion],
    existingItems: [WorkItem]
  ) throws -> [TicketSuggestionDraft] {
    guard (1...24).contains(suggestions.count) else {
      throw TicketSuggestionGenerationError.invalidResponse("Expected between 1 and 24 tickets.")
    }
    let references = suggestions.map { normalizedReference($0.reference) }
    guard references.allSatisfy({ !$0.isEmpty }) else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "Every ticket needs a non-empty reference."
      )
    }
    guard Set(references).count == references.count else {
      throw TicketSuggestionGenerationError.invalidResponse("Ticket references must be unique.")
    }
    let referenceSet = Set(references)
    let proposalReferenceByGeneratedReference = Dictionary(
      uniqueKeysWithValues: references.enumerated().map { index, reference in
        (reference, "S\(index + 1)")
      }
    )
    let activeExistingItems = existingItems.filter { $0.state != .cancelled }
    let existingItemByReference = Dictionary(
      activeExistingItems.map { (normalizedReference($0.key), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let validDependencyReferences = referenceSet.union(existingItemByReference.keys)
    guard suggestions.allSatisfy({ suggestion in
      suggestion.dependsOn.map(normalizedReference)
        .allSatisfy(validDependencyReferences.contains)
    }) else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "Every dependency must reference another proposed ticket or an active backlog ticket."
      )
    }
    let dependencies = Dictionary(
      uniqueKeysWithValues: suggestions.map {
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

    return try suggestions.map { suggestion in
      guard
        !suggestion.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !suggestion.acceptanceCriteria.isEmpty,
        let type = WorkItemType(rawValue: suggestion.type),
        let role = AgentRole(rawValue: suggestion.role),
        let priority = priority(named: suggestion.priority),
        let environmentRelationship = TicketEnvironmentRelationship(
          rawValue: suggestion.environmentRelationship
        )
      else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "Each ticket needs a reference, title, type, criteria, valid role, priority, "
            + "and environment relationship."
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
      guard let proposalReference = proposalReferenceByGeneratedReference[reference] else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "Every proposed ticket needs a temporary reference."
        )
      }
      return TicketSuggestionDraft(
        reference: proposalReference,
        title: suggestion.title,
        type: type,
        body: suggestion.body,
        acceptanceCriteria: suggestion.acceptanceCriteria,
        suggestedRole: role,
        priority: priority,
        rationale: suggestion.rationale,
        dependsOnReferences: Array(
          Set(
            dependencyReferences.compactMap {
              proposalReferenceByGeneratedReference[$0]
            }
          )
        ).sorted(),
        dependsOnExistingWorkItemKeys: Array(
          Set(
            dependencyReferences.compactMap { existingItemByReference[$0]?.key }
          )
        ).sorted(),
        environmentRelationship: environmentRelationship
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
    let ticketSuggestions = try decodeSuggestions(
      response.suggestions,
      existingItems: existingItems
    )
    let environmentAssessment = try decodeEnvironmentAssessment(
      response.epic.environmentAssessment,
      suggestions: response.suggestions,
      ticketSuggestions: ticketSuggestions,
      existingItems: existingItems
    )
    let decisionOutputTerms = [
      "analysis", "assessment", "comparison", "decision", "evaluate", "evaluation",
      "findings", "options", "recommend", "research", "select", "selection",
    ]
    let hasDeliveryCriterion = criteria.contains { criterion in
      let normalized = criterion.lowercased()
      return !decisionOutputTerms.contains { normalized.contains($0) }
    }
    guard
      !hasDeliveryCriterion
        || ticketSuggestions.contains(where: { $0.suggestedRole != .businessAnalyst })
    else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "The epic includes a product-delivery outcome, but its plan stops at Business Analyst work. "
          + "Include the downstream delivery tickets needed to achieve it."
      )
    }
    return EpicPlanDraft(
      title: title,
      goal: goal,
      successCriteria: criteria,
      constraints: response.epic.constraints.trimmingCharacters(in: .whitespacesAndNewlines),
      environmentAssessment: environmentAssessment,
      ticketSuggestions: ticketSuggestions
    )
  }

  private static func decodeEnvironmentAssessment(
    _ generated: GeneratedEnvironmentAssessment,
    suggestions: [GeneratedSuggestion],
    ticketSuggestions: [TicketSuggestionDraft],
    existingItems: [WorkItem]
  ) throws -> EpicEnvironmentAssessment {
    guard
      let readiness = EpicEnvironmentReadiness(rawValue: generated.readiness),
      !generated.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw TicketSuggestionGenerationError.invalidResponse(
        "The plan needs a valid environment readiness assessment and rationale."
      )
    }

    let generatedReferences = suggestions.map { normalizedReference($0.reference) }
    let proposalReferenceByGeneratedReference = Dictionary(
      uniqueKeysWithValues: generatedReferences.enumerated().map { index, reference in
        (reference, ticketSuggestions[index].reference)
      }
    )
    let activeExistingItems = existingItems.filter { $0.state != .cancelled }
    let existingItemByReference = Dictionary(
      activeExistingItems.map { (normalizedReference($0.key), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let trimmedFoundationReference = generated.foundationTicketReference?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let foundationReference = trimmedFoundationReference.isEmpty
      ? nil
      : normalizedReference(trimmedFoundationReference)
    let establishingReferences = Set(
      zip(generatedReferences, ticketSuggestions).compactMap { reference, suggestion in
        suggestion.environmentRelationship == .establishes ? reference : nil
      }
    )

    switch readiness {
    case .sufficient:
      guard foundationReference == nil, establishingReferences.isEmpty else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "A sufficient environment cannot also declare an environment-foundation ticket."
        )
      }
    case .notRequired:
      guard
        foundationReference == nil,
        ticketSuggestions.allSatisfy({ $0.environmentRelationship == .independent })
      else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "A plan that needs no executable environment must mark every ticket independent."
        )
      }
    case .foundationRequired:
      guard let foundationReference else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "A missing environment must identify its foundation ticket."
        )
      }
      let proposedFoundationIndex = generatedReferences.firstIndex(of: foundationReference)
      let isExistingFoundation = existingItemByReference[foundationReference] != nil
      guard proposedFoundationIndex != nil || isExistingFoundation else {
        throw TicketSuggestionGenerationError.invalidResponse(
          "The environment foundation must reference a proposed or active ticket."
        )
      }
      if let proposedFoundationIndex {
        let foundation = ticketSuggestions[proposedFoundationIndex]
        guard
          establishingReferences == Set([foundationReference]),
          foundation.environmentRelationship == .establishes,
          foundation.suggestedRole == .implementer,
          foundation.type == .task
        else {
          throw TicketSuggestionGenerationError.invalidResponse(
            "The proposed environment foundation must be the only establishes ticket "
              + "and must be an Implementer task."
          )
        }
      } else {
        guard establishingReferences.isEmpty else {
          throw TicketSuggestionGenerationError.invalidResponse(
            "A plan using an existing environment foundation cannot propose a second one."
          )
        }
      }

      let dependencies = Dictionary(
        uniqueKeysWithValues: zip(generatedReferences, suggestions).map {
          reference, suggestion in
          (reference, suggestion.dependsOn.map(normalizedReference))
        }
      )
      for (reference, suggestion) in zip(generatedReferences, ticketSuggestions)
      where suggestion.environmentRelationship == .requires {
        guard hasDependencyPath(
          from: reference,
          to: foundationReference,
          dependencies: dependencies
        ) else {
          throw TicketSuggestionGenerationError.invalidResponse(
            "Every ticket that requires the missing environment must depend on its foundation."
          )
        }
      }
    }

    let durableFoundationReference = foundationReference.flatMap {
      proposalReferenceByGeneratedReference[$0] ?? existingItemByReference[$0]?.key
    }
    return EpicEnvironmentAssessment(
      readiness: readiness,
      rationale: generated.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
      foundationTicketReference: durableFoundationReference
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

  private static func hasDependencyPath(
    from reference: String,
    to target: String,
    dependencies: [String: [String]]
  ) -> Bool {
    var pending = dependencies[reference] ?? []
    var visited: Set<String> = []
    while let current = pending.popLast() {
      if current == target { return true }
      guard visited.insert(current).inserted else { continue }
      pending.append(contentsOf: dependencies[current] ?? [])
    }
    return false
  }
}

private struct GeneratedResponse: Decodable {
  let environmentAssessment: GeneratedEnvironmentAssessment
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
  let environmentAssessment: GeneratedEnvironmentAssessment
}

private struct GeneratedEnvironmentAssessment: Decodable {
  let readiness: String
  let rationale: String
  let foundationTicketReference: String?
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
  let environmentRelationship: String
}
