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
}
