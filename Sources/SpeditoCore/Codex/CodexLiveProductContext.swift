public enum CodexLiveProductContext {
  public static let stableViewSchemas = """
    agent_product(
      id, name, instructions, status, created_at, updated_at
    )
    agent_team(
      id, product_id, name, role, custom_instructions, is_active
    )
    agent_epics(
      id, product_id, title, goal, success_criteria_json, constraints, status, rank,
      created_at, updated_at
    )
    agent_tickets(
      id, product_id, item_key, title, body, acceptance_criteria_json, ticket_type,
      state, priority, rank, version, epic_id, epic_title, owner_profile_id, owner_name,
      created_at, updated_at
    )
    agent_ticket_dependencies(
      work_item_id, item_key, depends_on_work_item_id, depends_on_item_key, source,
      created_at
    )
    agent_work_log(
      id, product_id, work_item_id, item_key, author_kind, author_name, body, created_at
    )
    agent_sprints(
      id, product_id, sprint_number, goal, state, plan_version, started_at, completed_at,
      retrospective_concluded_at, work_item_id, item_key, frozen_work_item_version,
      frozen_title, frozen_body, frozen_acceptance_criteria_json
    )
    agent_verified_knowledge(
      id, product_id, parent_id, title, slug, body_markdown, kind, source_work_item_id,
      source_item_key, updated_at
    )
    agent_decisions(
      id, product_id, work_item_id, item_key, title, context, decision, alternatives_json,
      consequences, applicable_commit, status, created_at, updated_at
    )
    agent_delivery_provenance(
      candidate_id, product_id, work_item_id, item_key, ticket_title, candidate_version,
      delivery_kind, branch_name, base_sha, head_sha, integrated_sha, status, commit_count,
      created_at, updated_at
    )
    agent_retrospectives(
      id, product_id, sprint_number, work_item_id, item_key, author_name, category, body,
      expected_effect, action_status, action_destination, created_at, updated_at
    )
    """

  /// Product chat is the only agent whose sandbox contains the live product
  /// database, so it is the only agent whose instructions may name it.
  public static func conversationInstructions(
    sharedInstructions: String,
    databasePath: String
  ) -> String {
    let shared = sharedInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = """
      LIVE PRODUCT CONTEXT
      The authoritative, live product database is at:
      \(databasePath)

      You may inspect it read-only with `/usr/bin/sqlite3 -readonly`. Use the stable agent_product,
      agent_team, agent_epics, agent_tickets, agent_ticket_dependencies, agent_work_log,
      agent_sprints, agent_verified_knowledge, agent_decisions, agent_delivery_provenance, and
      agent_retrospectives views. The exact stable view schemas are:
      \(stableViewSchemas)

      Search the product Git history when repository evidence is useful.
      The database can change while you work, so re-read a record before relying on mutable state.
      Read agent_verified_knowledge before acting on product or operating assumptions. Treat only
      rows in that view as verified reusable knowledge.
      """
    return [shared, context]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  /// Every other agent works from the bounded context in its prompt. Naming the
  /// database here would invite delivery agents to request read access to
  /// Spedito's own control plane, which their sandbox correctly denies.
  public static func inheritedInstructions(
    sharedInstructions: String,
    allowsRepositoryInspection: Bool
  ) -> String {
    let shared = sharedInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let repositoryScope =
      allowsRepositoryInspection
      ? """
      Search the product Git history when repository evidence is useful.
      """
      : """
      This is a planning turn. Use the ticket contracts and verified product knowledge supplied in the
      prompt. Do not inspect repository files or Git history.
      """
    let context = """
      PRODUCT CONTEXT
      Your prompt supplies the ticket contracts and verified product knowledge selected for this work.
      \(repositoryScope)
      Spedito's own product database is not part of your context. Do not locate or query it. If needed
      product context is missing from your prompt, say so in your result instead of searching for it.
      """
    return [shared, context]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }
}
