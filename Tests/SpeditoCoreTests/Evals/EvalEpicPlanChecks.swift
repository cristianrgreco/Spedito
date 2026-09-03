import Foundation
import SpeditoCore

/// Deterministic structural checks over a decoded epic plan draft, so each
/// proposed-ticket quality dimension is a named pass/fail outcome instead of
/// one blended judge score. Every check encodes an observed defect class with
/// a small literal term list, matching the suite's philosophy; the judge
/// remains the qualitative layer for wording no list can catch.
///
/// The production decoder already rejects dangling references, cycles,
/// self-dependencies, and empty criteria at decode time. The graph checks
/// here assert those properties anyway, so a future decoder loosening cannot
/// silently drop them and hand-built fixture drafts can prove each check.
enum EvalEpicPlanChecks {
  /// Mega-ticket proxy: a ticket carrying more acceptance criteria than this
  /// is doing several tickets' work under one title.
  static let acceptanceCriteriaBound = 7

  /// A title that is only a role label defers the outcome to the reader.
  static let bareRoleLabelTitles: Set<String> = [
    "research", "design", "implementation", "verification",
  ]

  /// Mined 2026-09-01 from the Battersea T1 criterion "Within two working
  /// days, review…": delivery has no calendar, so a calendar duration in a
  /// criterion is unfalsifiable noise. Literal patterns only; "time-boxed"
  /// as a research scope word elsewhere is a different, legitimate usage.
  static let calendarDeadlinePatterns = [
    #"\bworking days?\b"#,
    #"\bbusiness days?\b"#,
    #"\bwithin \d+ (day|week)s?\b"#,
    #"\bby end of\b"#,
  ]

  /// Mined from the pilot design-ticket failures: criteria that hard-required
  /// "a static PNG visual screen set" burned every run because the sandbox
  /// cannot rasterize PNG, and an SVG delivery was rejected as active
  /// content. The fixed guidance phrases requirements around the states
  /// covered, so no proposal criterion should name an exact image format at
  /// all — svg is never an accepted inert file, and mandating one accepted
  /// format by name removes delivery's freedom to pick a producible one.
  static let imageFormatPattern = #"\b(png|svg|jpe?g|gif|webp)\b"#

  private static let implementationRoles: Set<AgentRole> = [
    .implementer, .frontendEngineer, .backendEngineer,
  ]

  /// The full structural check set for one decoded plan, in the order the
  /// report should list them.
  static func structuralChecks(
    _ plan: EpicPlanDraft,
    existingItems: [WorkItem],
    expectedTicketCountRange: ClosedRange<Int>,
    legitimateExistingDependencyKeys: Set<String> = []
  ) -> [EvalCheck] {
    [
      ticketCountWithinExpectedShape(plan, expectedRange: expectedTicketCountRange),
      ticketScopeNotOverloaded(plan),
      titlesAreDistinctOutcomes(plan),
      everyTicketHasAcceptanceCriteria(plan),
      dependenciesResolveAndAreAcyclic(
        plan,
        existingItems: existingItems,
        legitimateExistingDependencyKeys: legitimateExistingDependencyKeys
      ),
      noRedundantTransitiveEdges(plan),
      verificationFollowsImplementation(plan),
      independentWorkNotSerialised(plan),
      dependantCriteriaCiteExactKeys(plan, existingItems: existingItems),
      criteriaAvoidCalendarDeadlines(plan),
      criteriaRespectDeliverableFormats(plan),
    ]
  }

  /// Numeric metrics recorded as facts per sample, so the report can show a
  /// prompt change moving them and aggregate their spread across samples.
  static func metricFacts(_ plan: EpicPlanDraft) -> [String: String] {
    let parallelism = parallelismWidth(plan)
    return [
      "parallelismWidth": String(format: "%.2f", parallelism.width),
      "criticalPathLength": String(parallelism.criticalPathLength),
      "archetypes": archetypes(plan).joined(separator: ", "),
    ]
  }

  // MARK: - Ticket count and right-sizing

  static func ticketCountWithinExpectedShape(
    _ plan: EpicPlanDraft,
    expectedRange: ClosedRange<Int>
  ) -> EvalCheck {
    let count = plan.ticketSuggestions.count
    return EvalCheck(
      name: "ticketCountWithinExpectedShape",
      passed: expectedRange.contains(count),
      detail: "\(count) ticket(s) against the expected "
        + "\(expectedRange.lowerBound)–\(expectedRange.upperBound) for this cell"
    )
  }

  static func ticketScopeNotOverloaded(_ plan: EpicPlanDraft) -> EvalCheck {
    let overloaded = plan.ticketSuggestions.filter {
      $0.acceptanceCriteria.count > acceptanceCriteriaBound
    }
    return EvalCheck(
      name: "ticketScopeNotOverloaded",
      passed: overloaded.isEmpty,
      detail: overloaded.isEmpty
        ? "no ticket exceeds \(acceptanceCriteriaBound) acceptance criteria"
        : overloaded.map {
          "\($0.reference) “\($0.title.prefix(60))” has \($0.acceptanceCriteria.count) "
            + "acceptance criteria against the bound of \(acceptanceCriteriaBound)"
        }.joined(separator: "; ")
    )
  }

  // MARK: - Title quality

  static func titlesAreDistinctOutcomes(_ plan: EpicPlanDraft) -> EvalCheck {
    var findings: [String] = []
    let byNormalizedTitle = Dictionary(
      grouping: plan.ticketSuggestions,
      by: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    )
    for (title, suggestions) in byNormalizedTitle.sorted(by: { $0.key < $1.key })
    where suggestions.count > 1 {
      findings.append(
        "“\(title.prefix(60))” is used by "
          + suggestions.map(\.reference).sorted().joined(separator: ", ")
      )
    }
    for suggestion in plan.ticketSuggestions {
      let normalized = suggestion.title
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      if bareRoleLabelTitles.contains(normalized) {
        findings.append("\(suggestion.reference) title is a bare role label “\(suggestion.title)”")
      }
    }
    return EvalCheck(
      name: "titlesAreDistinctOutcomes",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "every title is a distinct outcome"
        : findings.joined(separator: "; ")
    )
  }

  // MARK: - Dependency graph

  static func dependenciesResolveAndAreAcyclic(
    _ plan: EpicPlanDraft,
    existingItems: [WorkItem],
    legitimateExistingDependencyKeys: Set<String> = []
  ) -> EvalCheck {
    var findings: [String] = []
    let batchReferences = Set(plan.ticketSuggestions.map(\.reference))
    let existingByKey = Dictionary(
      existingItems.map { ($0.key, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for suggestion in plan.ticketSuggestions {
      if suggestion.dependsOnReferences.contains(suggestion.reference) {
        findings.append("\(suggestion.reference) depends on itself")
      }
      for reference in suggestion.dependsOnReferences
      where reference != suggestion.reference && !batchReferences.contains(reference) {
        findings.append(
          "\(suggestion.reference) depends on \(reference), which names no proposal in the batch"
        )
      }
      for key in suggestion.dependsOnExistingWorkItemKeys {
        guard let item = existingByKey[key] else {
          findings.append(
            "\(suggestion.reference) depends on \(key), which names no supplied backlog ticket"
          )
          continue
        }
        let isRetired = item.state == .cancelled || item.state == .released
        if isRetired, !legitimateExistingDependencyKeys.contains(key) {
          findings.append(
            "\(suggestion.reference) depends on \(item.state.title.lowercased()) ticket \(key)"
          )
        }
      }
    }
    if let cycle = firstDependencyCycle(in: plan) {
      findings.append("dependency cycle: " + cycle.joined(separator: " → "))
    }
    return EvalCheck(
      name: "dependenciesResolveAndAreAcyclic",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "every dependency resolves to live work and the graph is acyclic"
        : findings.joined(separator: "; ")
    )
  }

  /// An explicit edge that another dependency path already implies hides the
  /// real graph and serialises the board's presentation.
  static func noRedundantTransitiveEdges(_ plan: EpicPlanDraft) -> EvalCheck {
    var findings: [String] = []
    let adjacency = dependencyAdjacency(of: plan, includingExistingKeys: true)
    for suggestion in plan.ticketSuggestions {
      let direct = adjacency[suggestion.reference] ?? []
      for target in direct {
        let implied = direct.contains { intermediate in
          intermediate != target
            && reaches(from: intermediate, to: target, adjacency: adjacency)
        }
        if implied {
          findings.append(
            "\(suggestion.reference) → \(target) is already implied through "
              + "another declared dependency"
          )
        }
      }
    }
    return EvalCheck(
      name: "noRedundantTransitiveEdges",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "no explicit edge duplicates a transitive path"
        : findings.joined(separator: "; ")
    )
  }

  /// A quality assurance proposal that verifies nothing in particular floats
  /// parallel to the work it should follow. It must depend, directly or
  /// transitively, on an implementation-role proposal or on existing backlog
  /// work.
  static func verificationFollowsImplementation(_ plan: EpicPlanDraft) -> EvalCheck {
    var findings: [String] = []
    let adjacency = dependencyAdjacency(of: plan, includingExistingKeys: true)
    let suggestionByReference = Dictionary(
      plan.ticketSuggestions.map { ($0.reference, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let existingKeys = Set(plan.ticketSuggestions.flatMap(\.dependsOnExistingWorkItemKeys))
    for suggestion in plan.ticketSuggestions where suggestion.suggestedRole == .qualityAssurance {
      let reached = reachableReferences(from: suggestion.reference, adjacency: adjacency)
      let followsImplementation = reached.contains { reference in
        if let target = suggestionByReference[reference] {
          return implementationRoles.contains(target.suggestedRole)
        }
        return existingKeys.contains(reference)
      }
      if !followsImplementation {
        findings.append(
          "\(suggestion.reference) “\(suggestion.title.prefix(60))” verifies work "
            + "it does not depend on"
        )
      }
    }
    return EvalCheck(
      name: "verificationFollowsImplementation",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "every verification proposal follows the implementation it verifies"
        : findings.joined(separator: "; ")
    )
  }

  // MARK: - Parallelism

  /// The one declared-independent pair mined from live runs: a design ticket
  /// needs no toolchain, so it must not wait for the environment task — the
  /// canonical plan in the contributor instructions states design "may
  /// proceed in parallel". Only this declared pair fails; the check stays
  /// literal rather than guessing which other pairs could parallelise.
  static func independentWorkNotSerialised(_ plan: EpicPlanDraft) -> EvalCheck {
    var findings: [String] = []
    let adjacency = dependencyAdjacency(of: plan, includingExistingKeys: false)
    let setupReferences = Set(
      plan.ticketSuggestions
        .filter { $0.environmentRelationship == .establishes }
        .map(\.reference)
    )
    guard !setupReferences.isEmpty else {
      return EvalCheck(
        name: "independentWorkNotSerialised",
        passed: true,
        detail: "no environment task exists for design work to wait on"
      )
    }
    for suggestion in plan.ticketSuggestions where suggestion.suggestedRole == .uxDesigner {
      if let path = firstPath(
        from: suggestion.reference,
        toAnyOf: setupReferences,
        adjacency: adjacency
      ) {
        findings.append(
          "design ticket \(suggestion.reference) is serialised behind environment setup: "
            + path.joined(separator: " → ")
        )
      }
    }
    return EvalCheck(
      name: "independentWorkNotSerialised",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "design work proceeds in parallel with environment setup"
        : findings.joined(separator: "; ")
    )
  }

  /// Ticket count divided by the dependency graph's critical-path length,
  /// over proposal-to-proposal edges. 1.0 is fully serial; improvements to
  /// prompts should move this visibly on greenfield cells.
  static func parallelismWidth(
    _ plan: EpicPlanDraft
  ) -> (width: Double, criticalPathLength: Int) {
    let count = plan.ticketSuggestions.count
    guard count > 0 else { return (0, 0) }
    let adjacency = dependencyAdjacency(of: plan, includingExistingKeys: false)
    var memo: [String: Int] = [:]
    var inProgress: Set<String> = []
    func chainLength(from reference: String) -> Int {
      if let known = memo[reference] { return known }
      // A cycle cannot occur in a decoded draft; hand-built drafts stop the
      // walk at the back edge instead of recursing forever.
      guard inProgress.insert(reference).inserted else { return 0 }
      defer { inProgress.remove(reference) }
      let downstream = (adjacency[reference] ?? []).map(chainLength(from:)).max() ?? 0
      memo[reference] = downstream + 1
      return downstream + 1
    }
    let criticalPath = plan.ticketSuggestions
      .map { chainLength(from: $0.reference) }
      .max() ?? 1
    return (Double(count) / Double(max(1, criticalPath)), criticalPath)
  }

  // MARK: - Criteria discipline

  static func everyTicketHasAcceptanceCriteria(_ plan: EpicPlanDraft) -> EvalCheck {
    let missing = plan.ticketSuggestions.filter { suggestion in
      suggestion.acceptanceCriteria.allSatisfy {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
    return EvalCheck(
      name: "everyTicketHasAcceptanceCriteria",
      passed: missing.isEmpty,
      detail: missing.isEmpty
        ? "every proposal states an agreed outcome to verify"
        : "proposals without acceptance criteria: "
          + missing.map { "\($0.reference) “\($0.title.prefix(60))”" }.joined(separator: "; ")
    )
  }

  /// The generator instructs the model to cite the exact prerequisite ticket
  /// reference in a dependant criterion, and durable keys keep those
  /// citations stable. A criterion that names another ticket must use a
  /// reference the proposal actually declares as a dependency.
  static func dependantCriteriaCiteExactKeys(
    _ plan: EpicPlanDraft,
    existingItems: [WorkItem]
  ) -> EvalCheck {
    var findings: [String] = []
    let batchReferences = Set(plan.ticketSuggestions.map(\.reference))
    let existingKeys = Set(existingItems.map(\.key))
    for suggestion in plan.ticketSuggestions {
      let declared = Set(suggestion.dependsOnReferences)
        .union(suggestion.dependsOnExistingWorkItemKeys)
        .union([suggestion.reference])
      for criterion in suggestion.acceptanceCriteria {
        for token in referenceTokens(in: criterion) where !declared.contains(token) {
          if batchReferences.contains(token) || existingKeys.contains(token) {
            findings.append(
              "\(suggestion.reference): “\(criterion.prefix(90))” cites \(token) "
                + "without declaring it as a dependency"
            )
          } else {
            findings.append(
              "\(suggestion.reference): “\(criterion.prefix(90))” cites \(token), "
                + "which matches nothing in the batch or backlog"
            )
          }
        }
      }
    }
    return EvalCheck(
      name: "dependantCriteriaCiteExactKeys",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "every criterion citation resolves to a declared dependency"
        : findings.joined(separator: "; ")
    )
  }

  static func criteriaAvoidCalendarDeadlines(_ plan: EpicPlanDraft) -> EvalCheck {
    let findings = ownerTextFindings(in: plan) { text in
      calendarDeadlinePatterns.compactMap { pattern in
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
          .map { String(text[$0]) }
      }
    }
    return EvalCheck(
      name: "criteriaAvoidCalendarDeadlines",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "no criterion or ticket body imposes a calendar deadline"
        : "calendar deadlines in ticket text — " + findings.joined(separator: "; ")
    )
  }

  static func criteriaRespectDeliverableFormats(_ plan: EpicPlanDraft) -> EvalCheck {
    let findings = ownerTextFindings(in: plan) { text in
      guard
        let range = text.range(
          of: imageFormatPattern,
          options: [.regularExpression, .caseInsensitive]
        )
      else { return [] }
      let format = String(text[range]).lowercased()
      let reason =
        format == "svg"
        ? "svg is never an accepted inert review format"
        : "phrase requirements around the states covered instead of one exact format"
      return ["mandates the \(format) format (\(reason))"]
    }
    return EvalCheck(
      name: "criteriaRespectDeliverableFormats",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "no criterion or ticket body mandates an exact deliverable file format"
        : findings.joined(separator: "; ")
    )
  }

  // MARK: - Demo kind contract

  /// The planner's demo-kind rule is mechanical: setup and story tickets use
  /// the product surface the clarification round fixed, design tickets about
  /// a visible interface review as an HTML screen set or prototype under
  /// static_web, and research tickets — plus explicitly document-first design
  /// outcomes such as copy reviews, blueprints, and audits — review as an
  /// artifact. A plan that varies the kind per ticket re-opens the decision
  /// the contract exists to close, so every deviation is a named failure.
  /// Tickets outside those groups (code-only or supporting implementer tasks)
  /// keep the planner's judgment.
  static func plannedDemoKindMatchesProductSurface(
    _ plan: EpicPlanDraft,
    productSurface: TicketDemoKind
  ) -> EvalCheck {
    var findings: [String] = []
    for suggestion in plan.ticketSuggestions {
      guard let demoKind = suggestion.demoKind else {
        findings.append("\(suggestion.reference) has no demo kind")
        continue
      }
      let usesProductSurface =
        suggestion.environmentRelationship == .establishes || suggestion.type == .story
      if usesProductSurface {
        if demoKind != productSurface {
          findings.append(
            "\(suggestion.reference) “\(suggestion.title.prefix(60))” plans "
              + "\(demoKind.rawValue) instead of the product surface "
              + "\(productSurface.rawValue)"
          )
        }
      } else if suggestion.suggestedRole == .uxDesigner {
        let documentFirst = isDocumentFirstDesign(suggestion)
        if documentFirst, demoKind != .artifact {
          findings.append(
            "\(suggestion.reference) “\(suggestion.title.prefix(60))” plans "
              + "\(demoKind.rawValue) for document-first design work instead of artifact"
          )
        } else if !documentFirst, demoKind != .staticWeb {
          findings.append(
            "\(suggestion.reference) “\(suggestion.title.prefix(60))” plans "
              + "\(demoKind.rawValue) for design work instead of a static_web HTML screen set"
          )
        }
      } else if suggestion.suggestedRole == .businessAnalyst {
        if demoKind != .artifact {
          findings.append(
            "\(suggestion.reference) “\(suggestion.title.prefix(60))” plans "
              + "\(demoKind.rawValue) for research work instead of artifact"
          )
        }
      }
    }
    return EvalCheck(
      name: "plannedDemoKindMatchesProductSurface",
      passed: findings.isEmpty,
      detail: findings.isEmpty
        ? "every setup and story ticket demos as the product surface, design tickets "
          + "review as static_web screen sets, and research reviews as artifacts"
        : findings.joined(separator: "; ")
    )
  }

  /// Design outcomes the contract lets stay document-led: copy reviews,
  /// service blueprints, accessibility audits, and similar documents.
  static let documentFirstDesignPattern =
    #"\b(copy review|content review|service blueprint|blueprint|audit|guidelines?|tone of voice)\b"#

  static func isDocumentFirstDesign(_ suggestion: TicketSuggestionDraft) -> Bool {
    (suggestion.title + " " + suggestion.body).range(
      of: documentFirstDesignPattern,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  // MARK: - Consistency archetypes

  /// The ticket archetypes whose presence or absence across samples measures
  /// plan-shape consistency, in reporting order.
  static let archetypeNames = ["setup", "research", "design", "story", "verification"]

  static func archetypes(_ plan: EpicPlanDraft) -> [String] {
    var present: [String] = []
    if plan.ticketSuggestions.contains(where: { $0.environmentRelationship == .establishes }) {
      present.append("setup")
    }
    if plan.ticketSuggestions.contains(where: { $0.suggestedRole == .businessAnalyst }) {
      present.append("research")
    }
    if plan.ticketSuggestions.contains(where: { $0.suggestedRole == .uxDesigner }) {
      present.append("design")
    }
    if plan.ticketSuggestions.contains(where: { $0.type == .story }) {
      present.append("story")
    }
    if plan.ticketSuggestions.contains(where: { $0.suggestedRole == .qualityAssurance }) {
      present.append("verification")
    }
    return present
  }

  // MARK: - Graph helpers

  private static func dependencyAdjacency(
    of plan: EpicPlanDraft,
    includingExistingKeys: Bool
  ) -> [String: [String]] {
    let batchReferences = Set(plan.ticketSuggestions.map(\.reference))
    return Dictionary(
      plan.ticketSuggestions.map { suggestion in
        let proposalEdges = suggestion.dependsOnReferences.filter {
          batchReferences.contains($0) && $0 != suggestion.reference
        }
        let existingEdges = includingExistingKeys
          ? suggestion.dependsOnExistingWorkItemKeys
          : []
        return (suggestion.reference, proposalEdges + existingEdges)
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private static func reaches(
    from start: String,
    to target: String,
    adjacency: [String: [String]]
  ) -> Bool {
    start == target || reachableReferences(from: start, adjacency: adjacency).contains(target)
  }

  private static func reachableReferences(
    from start: String,
    adjacency: [String: [String]]
  ) -> Set<String> {
    var visited: Set<String> = []
    var frontier = adjacency[start] ?? []
    while let next = frontier.popLast() {
      guard visited.insert(next).inserted else { continue }
      frontier.append(contentsOf: adjacency[next] ?? [])
    }
    return visited
  }

  private static func firstPath(
    from start: String,
    toAnyOf targets: Set<String>,
    adjacency: [String: [String]]
  ) -> [String]? {
    var parents: [String: String] = [:]
    var visited: Set<String> = [start]
    var queue = [start]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      for next in adjacency[current] ?? [] where visited.insert(next).inserted {
        parents[next] = current
        if targets.contains(next) {
          var path = [next]
          var node = next
          while let parent = parents[node] {
            path.append(parent)
            node = parent
          }
          return path.reversed()
        }
        queue.append(next)
      }
    }
    return nil
  }

  private static func firstDependencyCycle(in plan: EpicPlanDraft) -> [String]? {
    let adjacency = dependencyAdjacency(of: plan, includingExistingKeys: false)
    var settled: Set<String> = []
    var stack: [String] = []
    var onStack: Set<String> = []
    var cycle: [String]?
    func visit(_ reference: String) {
      guard cycle == nil, !settled.contains(reference) else { return }
      if onStack.contains(reference) {
        let start = stack.firstIndex(of: reference) ?? 0
        cycle = Array(stack[start...]) + [reference]
        return
      }
      stack.append(reference)
      onStack.insert(reference)
      for next in adjacency[reference] ?? [] {
        visit(next)
      }
      stack.removeLast()
      onStack.remove(reference)
      settled.insert(reference)
    }
    for suggestion in plan.ticketSuggestions {
      visit(suggestion.reference)
      if cycle != nil { break }
    }
    return cycle
  }

  private static func referenceTokens(in text: String) -> [String] {
    guard
      let expression = try? NSRegularExpression(pattern: #"\b[ST]\d+\b"#)
    else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
  }

  /// Runs one matcher over every proposal's criteria and body, prefixing each
  /// finding with the offending ticket reference the way the established
  /// checks do.
  private static func ownerTextFindings(
    in plan: EpicPlanDraft,
    matching matcher: (String) -> [String]
  ) -> [String] {
    var findings: [String] = []
    for suggestion in plan.ticketSuggestions {
      for criterion in suggestion.acceptanceCriteria {
        let hits = matcher(criterion)
        if !hits.isEmpty {
          findings.append(
            "\(suggestion.reference): “\(criterion.prefix(90))” "
              + "(\(hits.joined(separator: ", ")))"
          )
        }
      }
      let bodyHits = matcher(suggestion.body)
      if !bodyHits.isEmpty {
        findings.append(
          "\(suggestion.reference) body (\(bodyHits.joined(separator: ", ")))"
        )
      }
    }
    return findings
  }
}
