import Foundation

enum ProductDatabaseSchema {
  static let version: Int32 = 1

  static let sql = """
    CREATE TABLE products (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        instructions TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'archived')),
        color TEXT NOT NULL DEFAULT 'accent'
          CHECK (
            color IN ('accent', 'blue', 'teal', 'green', 'orange', 'pink', 'indigo')
          ),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE agent_profiles (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        role TEXT NOT NULL,
        model TEXT NOT NULL,
        reasoning_effort TEXT NOT NULL,
        custom_instructions TEXT,
        is_builtin INTEGER NOT NULL DEFAULT 1,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE epics (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        goal TEXT NOT NULL,
        success_criteria_json TEXT NOT NULL,
        constraints TEXT NOT NULL,
        status TEXT NOT NULL,
        rank INTEGER NOT NULL DEFAULT 0,
        color TEXT NOT NULL DEFAULT 'blue',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE work_items (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        key_number INTEGER NOT NULL,
        item_key TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        acceptance_criteria_json TEXT NOT NULL,
        ticket_type TEXT NOT NULL DEFAULT 'story',
        state TEXT NOT NULL,
        priority INTEGER NOT NULL,
        rank INTEGER NOT NULL DEFAULT 0,
        custom_fields_json TEXT NOT NULL DEFAULT '{}',
        owner_profile_id TEXT REFERENCES agent_profiles(id),
        epic_id TEXT REFERENCES epics(id) ON DELETE SET NULL,
        version INTEGER NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(product_id, key_number),
        UNIQUE(product_id, item_key)
    );

    CREATE TABLE ticket_comments (
        id TEXT PRIMARY KEY,
        work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
        author_kind TEXT NOT NULL,
        author_name TEXT NOT NULL,
        body TEXT NOT NULL,
        owner_question_json TEXT,
        answered_questions_json TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE decision_records (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
        title TEXT NOT NULL,
        context TEXT NOT NULL,
        decision TEXT NOT NULL,
        alternatives_json TEXT NOT NULL,
        consequences TEXT NOT NULL,
        applicable_commit TEXT,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE knowledge_claims (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
        statement TEXT NOT NULL,
        provenance_json TEXT NOT NULL,
        verification_state TEXT NOT NULL,
        applicable_commit TEXT,
        invalidated_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE activity_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        work_item_id TEXT REFERENCES work_items(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        actor TEXT NOT NULL,
        detail TEXT NOT NULL,
        created_at REAL NOT NULL
    );

    CREATE TABLE sprints (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        sprint_number INTEGER NOT NULL,
        goal TEXT NOT NULL,
        state TEXT NOT NULL,
        token_budget_limit INTEGER,
        plan_version INTEGER NOT NULL,
        started_at REAL,
        completed_at REAL,
        retrospective_concluded_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(product_id, sprint_number)
    );

    CREATE TABLE sprint_items (
        id TEXT PRIMARY KEY,
        sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
        work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE RESTRICT,
        implementer_profile_id TEXT REFERENCES agent_profiles(id),
        reviewer_profile_id TEXT REFERENCES agent_profiles(id),
        estimated_tokens INTEGER NOT NULL,
        frozen_work_item_version INTEGER,
        frozen_title TEXT,
        frozen_body TEXT,
        frozen_acceptance_criteria_json TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(sprint_id, work_item_id)
    );

    CREATE TABLE suggestion_sessions (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        epic_id TEXT REFERENCES epics(id) ON DELETE SET NULL,
        source_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
        status TEXT NOT NULL,
        codex_thread_id TEXT,
        codex_turn_id TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE ticket_suggestions (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES suggestion_sessions(id) ON DELETE CASCADE,
        reference TEXT NOT NULL,
        position INTEGER NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        acceptance_criteria_json TEXT NOT NULL,
        suggested_role TEXT NOT NULL,
        priority INTEGER NOT NULL,
        rationale TEXT NOT NULL,
        status TEXT NOT NULL,
        accepted_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
        ticket_type TEXT NOT NULL DEFAULT 'story',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(session_id, reference),
        UNIQUE(session_id, position)
    );

    CREATE TABLE suggestion_dependencies (
        suggestion_id TEXT NOT NULL
          REFERENCES ticket_suggestions(id) ON DELETE CASCADE,
        depends_on_suggestion_id TEXT NOT NULL
          REFERENCES ticket_suggestions(id) ON DELETE CASCADE,
        PRIMARY KEY (suggestion_id, depends_on_suggestion_id),
        CHECK (suggestion_id <> depends_on_suggestion_id)
    );

    CREATE TABLE suggestion_existing_dependencies (
        suggestion_id TEXT NOT NULL
          REFERENCES ticket_suggestions(id) ON DELETE CASCADE,
        depends_on_work_item_id TEXT NOT NULL
          REFERENCES work_items(id) ON DELETE RESTRICT,
        PRIMARY KEY(suggestion_id, depends_on_work_item_id)
    );

    CREATE TABLE work_item_dependencies (
        work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
        depends_on_work_item_id TEXT NOT NULL
          REFERENCES work_items(id) ON DELETE CASCADE,
        source TEXT NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY (work_item_id, depends_on_work_item_id),
        CHECK (work_item_id <> depends_on_work_item_id)
    );

    CREATE TABLE agent_runs (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        sprint_id TEXT REFERENCES sprints(id),
        sprint_item_id TEXT REFERENCES sprint_items(id),
        work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
        profile_id TEXT NOT NULL REFERENCES agent_profiles(id),
        status TEXT NOT NULL,
        codex_thread_id TEXT,
        worktree_path TEXT,
        ticket_budget_used REAL NOT NULL DEFAULT 0,
        context_used_tokens INTEGER,
        context_window_tokens INTEGER,
        compaction_count INTEGER NOT NULL DEFAULT 0,
        turn_started_at REAL,
        last_activity_at REAL,
        last_activity_text TEXT,
        last_activity_kind TEXT,
        active_duration_seconds REAL NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE candidate_revisions (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
        sprint_item_id TEXT NOT NULL REFERENCES sprint_items(id) ON DELETE CASCADE,
        work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
        implementation_run_id TEXT NOT NULL
          REFERENCES agent_runs(id) ON DELETE CASCADE,
        version INTEGER NOT NULL,
        branch_name TEXT NOT NULL,
        base_sha TEXT NOT NULL,
        head_sha TEXT NOT NULL,
        integrated_sha TEXT,
        worktree_path TEXT NOT NULL,
        integration_worktree_path TEXT,
        status TEXT NOT NULL,
        commit_count INTEGER NOT NULL,
        execution_result_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(work_item_id, version)
    );

    CREATE TABLE demo_sessions (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        candidate_revision_id TEXT NOT NULL
          REFERENCES candidate_revisions(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        preview_worktree_path TEXT,
        allocated_port INTEGER,
        output TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(candidate_revision_id)
    );

    CREATE TABLE knowledge_pages (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        parent_id TEXT REFERENCES knowledge_pages(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        slug TEXT NOT NULL,
        body_markdown TEXT NOT NULL,
        kind TEXT NOT NULL,
        verification_status TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        source_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE knowledge_page_revisions (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
        version INTEGER NOT NULL,
        body_markdown TEXT NOT NULL,
        author_name TEXT NOT NULL,
        change_summary TEXT NOT NULL,
        created_at REAL NOT NULL,
        UNIQUE(page_id, version)
    );

    CREATE TABLE knowledge_page_links (
        source_page_id TEXT NOT NULL
          REFERENCES knowledge_pages(id) ON DELETE CASCADE,
        target_page_id TEXT NOT NULL
          REFERENCES knowledge_pages(id) ON DELETE CASCADE,
        PRIMARY KEY(source_page_id, target_page_id)
    );

    CREATE TABLE agent_run_knowledge_pages (
        run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
        page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
        PRIMARY KEY(run_id, page_id)
    );

    CREATE TABLE agent_run_knowledge_destinations (
        run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
        page_id TEXT NOT NULL REFERENCES knowledge_pages(id) ON DELETE CASCADE,
        PRIMARY KEY(run_id, page_id)
    );

    CREATE TABLE knowledge_page_proposals (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
        work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
        candidate_revision_id TEXT NOT NULL
          REFERENCES candidate_revisions(id) ON DELETE CASCADE,
        operation TEXT NOT NULL,
        target_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
        parent_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
        base_page_title TEXT,
        base_page_body_markdown TEXT,
        base_page_updated_at REAL,
        title TEXT NOT NULL,
        proposed_body_markdown TEXT NOT NULL,
        rationale TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          (operation = 'update' AND target_page_id IS NOT NULL AND parent_page_id IS NULL)
          OR
          (operation = 'create' AND target_page_id IS NULL AND parent_page_id IS NOT NULL)
        )
    );

    CREATE TABLE epic_planning_conversations (
        epic_id TEXT PRIMARY KEY REFERENCES epics(id) ON DELETE CASCADE,
        snapshot_json TEXT NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE agent_permission_requests (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        work_item_id TEXT NOT NULL REFERENCES work_items(id) ON DELETE CASCADE,
        agent_run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
        thread_id TEXT NOT NULL,
        turn_id TEXT NOT NULL,
        server_request_id TEXT NOT NULL,
        method TEXT NOT NULL,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        detail TEXT NOT NULL,
        reason TEXT,
        signature TEXT NOT NULL,
        product_grant_signature TEXT,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE agent_permission_grants (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        source_request_id TEXT
          REFERENCES agent_permission_requests(id) ON DELETE SET NULL,
        method TEXT NOT NULL,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        detail TEXT NOT NULL,
        signature TEXT NOT NULL,
        created_at REAL NOT NULL,
        revoked_at REAL
    );

    CREATE TABLE retrospective_syntheses (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
        profile_id TEXT REFERENCES agent_profiles(id) ON DELETE SET NULL,
        status TEXT NOT NULL,
        codex_thread_id TEXT,
        codex_turn_id TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(sprint_id)
    );

    CREATE TABLE retrospective_notes (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        sprint_id TEXT NOT NULL REFERENCES sprints(id) ON DELETE CASCADE,
        work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
        profile_id TEXT REFERENCES agent_profiles(id) ON DELETE SET NULL,
        synthesis_id TEXT
          REFERENCES retrospective_syntheses(id) ON DELETE SET NULL,
        author_name TEXT NOT NULL,
        category TEXT NOT NULL,
        body TEXT NOT NULL,
        is_action_candidate INTEGER NOT NULL DEFAULT 0,
        expected_effect TEXT,
        action_status TEXT,
        action_destination TEXT,
        accepted_work_item_id TEXT REFERENCES work_items(id) ON DELETE SET NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE retrospective_synthesis_sources (
        synthesis_id TEXT NOT NULL
          REFERENCES retrospective_syntheses(id) ON DELETE CASCADE,
        source_note_id TEXT NOT NULL
          REFERENCES retrospective_notes(id) ON DELETE CASCADE,
        PRIMARY KEY(synthesis_id, source_note_id)
    );

    CREATE TABLE retrospective_action_sources (
        action_note_id TEXT NOT NULL
          REFERENCES retrospective_notes(id) ON DELETE CASCADE,
        source_note_id TEXT NOT NULL
          REFERENCES retrospective_notes(id) ON DELETE CASCADE,
        PRIMARY KEY(action_note_id, source_note_id)
    );

    CREATE TABLE conversation_threads (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        recipient_profile_id TEXT NOT NULL
          REFERENCES agent_profiles(id) ON DELETE RESTRICT,
        subject TEXT NOT NULL,
        status TEXT NOT NULL,
        codex_thread_id TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE conversation_messages (
        id TEXT PRIMARY KEY,
        thread_id TEXT NOT NULL
          REFERENCES conversation_threads(id) ON DELETE CASCADE,
        author_kind TEXT NOT NULL,
        author_name TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at REAL NOT NULL
    );

    CREATE INDEX idx_products_status_created
      ON products(status, created_at);
    CREATE UNIQUE INDEX idx_agent_profiles_active_name
      ON agent_profiles(product_id, lower(name)) WHERE is_active = 1;
    CREATE INDEX idx_epics_product_status
      ON epics(product_id, status, created_at);
    CREATE INDEX idx_work_items_product_state
      ON work_items(product_id, state);
    CREATE INDEX idx_work_items_product_rank
      ON work_items(product_id, rank, key_number);
    CREATE INDEX idx_work_items_epic
      ON work_items(epic_id, rank);
    CREATE INDEX idx_comments_work_item
      ON ticket_comments(work_item_id, created_at);
    CREATE INDEX idx_activity_product_sequence
      ON activity_events(product_id, sequence DESC);
    CREATE UNIQUE INDEX idx_sprints_one_active
      ON sprints(product_id) WHERE state = 'active';
    CREATE UNIQUE INDEX idx_sprints_one_draft
      ON sprints(product_id) WHERE state = 'draft';
    CREATE INDEX idx_sprint_items_sprint
      ON sprint_items(sprint_id, created_at);
    CREATE UNIQUE INDEX idx_suggestion_sessions_one_generating
      ON suggestion_sessions(product_id) WHERE status = 'generating';
    CREATE INDEX idx_suggestion_sessions_product_created
      ON suggestion_sessions(product_id, created_at DESC);
    CREATE INDEX idx_suggestion_sessions_epic
      ON suggestion_sessions(epic_id, created_at DESC);
    CREATE UNIQUE INDEX idx_suggestion_sessions_source_work_item
      ON suggestion_sessions(source_work_item_id)
      WHERE source_work_item_id IS NOT NULL;
    CREATE INDEX idx_ticket_suggestions_session_position
      ON ticket_suggestions(session_id, position);
    CREATE INDEX idx_suggestion_existing_dependencies_item
      ON suggestion_existing_dependencies(depends_on_work_item_id);
    CREATE INDEX idx_agent_runs_sprint_item_created
      ON agent_runs(sprint_item_id, created_at)
      WHERE sprint_item_id IS NOT NULL;
    CREATE INDEX idx_candidate_revisions_sprint_status
      ON candidate_revisions(sprint_id, status, created_at);
    CREATE INDEX idx_candidate_revisions_work_item
      ON candidate_revisions(work_item_id, version DESC);
    CREATE INDEX idx_demo_sessions_product_status
      ON demo_sessions(product_id, status, updated_at);
    CREATE UNIQUE INDEX idx_knowledge_page_sibling_slug
      ON knowledge_pages(product_id, IFNULL(parent_id, ''), slug);
    CREATE INDEX idx_knowledge_pages_product_parent
      ON knowledge_pages(product_id, parent_id, sort_order);
    CREATE UNIQUE INDEX idx_knowledge_delivery_note_source
      ON knowledge_pages(product_id, source_work_item_id)
      WHERE kind = 'delivery_note' AND source_work_item_id IS NOT NULL;
    CREATE INDEX idx_agent_run_knowledge_page
      ON agent_run_knowledge_pages(page_id, run_id);
    CREATE INDEX idx_agent_run_knowledge_destination
      ON agent_run_knowledge_destinations(page_id, run_id);
    CREATE INDEX idx_knowledge_page_proposals_candidate
      ON knowledge_page_proposals(candidate_revision_id, status, created_at);
    CREATE INDEX idx_knowledge_page_proposals_product
      ON knowledge_page_proposals(product_id, status, created_at);
    CREATE INDEX idx_agent_permission_requests_product_status
      ON agent_permission_requests(product_id, status, updated_at);
    CREATE INDEX idx_agent_permission_requests_run_signature
      ON agent_permission_requests(agent_run_id, signature, status);
    CREATE UNIQUE INDEX idx_agent_permission_grants_active_signature
      ON agent_permission_grants(product_id, signature)
      WHERE revoked_at IS NULL;
    CREATE INDEX idx_agent_permission_grants_product_created
      ON agent_permission_grants(product_id, created_at);
    CREATE UNIQUE INDEX idx_retrospective_note_evidence
      ON retrospective_notes(
        sprint_id, work_item_id, profile_id, category, body
      );
    CREATE INDEX idx_retrospective_notes_sprint
      ON retrospective_notes(sprint_id, category, created_at);
    CREATE INDEX idx_conversation_threads_product_updated
      ON conversation_threads(product_id, updated_at DESC);
    CREATE INDEX idx_conversation_messages_thread_created
      ON conversation_messages(thread_id, created_at);

    CREATE VIEW agent_product AS
      SELECT id, name, instructions, status, created_at, updated_at
      FROM products;

    CREATE VIEW agent_team AS
      SELECT id, product_id, name, role, custom_instructions, is_active
      FROM agent_profiles;

    CREATE VIEW agent_epics AS
      SELECT
        id, product_id, title, goal, success_criteria_json,
        constraints, status, rank, created_at, updated_at
      FROM epics;

    CREATE VIEW agent_tickets AS
      SELECT
        item.id,
        item.product_id,
        item.item_key,
        item.title,
        item.body,
        item.acceptance_criteria_json,
        item.ticket_type,
        item.state,
        item.priority,
        item.rank,
        item.version,
        item.epic_id,
        epic.title AS epic_title,
        item.owner_profile_id,
        profile.name AS owner_name,
        item.created_at,
        item.updated_at
      FROM work_items AS item
      LEFT JOIN epics AS epic ON epic.id = item.epic_id
      LEFT JOIN agent_profiles AS profile ON profile.id = item.owner_profile_id;

    CREATE VIEW agent_ticket_dependencies AS
      SELECT
        dependency.work_item_id,
        item.item_key,
        dependency.depends_on_work_item_id,
        prerequisite.item_key AS depends_on_item_key,
        dependency.source,
        dependency.created_at
      FROM work_item_dependencies AS dependency
      JOIN work_items AS item ON item.id = dependency.work_item_id
      JOIN work_items AS prerequisite
        ON prerequisite.id = dependency.depends_on_work_item_id;

    CREATE VIEW agent_work_log AS
      SELECT
        comment.id,
        item.product_id,
        comment.work_item_id,
        item.item_key,
        comment.author_kind,
        comment.author_name,
        comment.body,
        comment.created_at
      FROM ticket_comments AS comment
      JOIN work_items AS item ON item.id = comment.work_item_id;

    CREATE VIEW agent_sprints AS
      SELECT
        sprint.id,
        sprint.product_id,
        sprint.sprint_number,
        sprint.goal,
        sprint.state,
        sprint.plan_version,
        sprint.started_at,
        sprint.completed_at,
        sprint.retrospective_concluded_at,
        item.work_item_id,
        work_item.item_key,
        item.frozen_work_item_version,
        item.frozen_title,
        item.frozen_body,
        item.frozen_acceptance_criteria_json
      FROM sprints AS sprint
      LEFT JOIN sprint_items AS item ON item.sprint_id = sprint.id
      LEFT JOIN work_items AS work_item ON work_item.id = item.work_item_id;

    CREATE VIEW agent_verified_knowledge AS
      SELECT
        page.id,
        page.product_id,
        page.parent_id,
        page.title,
        page.slug,
        page.body_markdown,
        page.kind,
        page.source_work_item_id,
        item.item_key AS source_item_key,
        page.updated_at
      FROM knowledge_pages AS page
      LEFT JOIN work_items AS item ON item.id = page.source_work_item_id
      WHERE page.verification_status = 'verified';

    CREATE VIEW agent_decisions AS
      SELECT
        decision.id,
        decision.product_id,
        decision.work_item_id,
        item.item_key,
        decision.title,
        decision.context,
        decision.decision,
        decision.alternatives_json,
        decision.consequences,
        decision.applicable_commit,
        decision.status,
        decision.created_at,
        decision.updated_at
      FROM decision_records AS decision
      LEFT JOIN work_items AS item ON item.id = decision.work_item_id;

    CREATE VIEW agent_delivery_provenance AS
      SELECT
        candidate.id AS candidate_id,
        candidate.product_id,
        candidate.work_item_id,
        item.item_key,
        item.title AS ticket_title,
        candidate.version AS candidate_version,
        candidate.branch_name,
        candidate.base_sha,
        candidate.head_sha,
        candidate.integrated_sha,
        candidate.status,
        candidate.commit_count,
        candidate.created_at,
        candidate.updated_at
      FROM candidate_revisions AS candidate
      JOIN work_items AS item ON item.id = candidate.work_item_id;

    CREATE VIEW agent_retrospectives AS
      SELECT
        note.id,
        note.product_id,
        sprint.sprint_number,
        note.work_item_id,
        item.item_key,
        note.author_name,
        note.category,
        note.body,
        note.expected_effect,
        note.action_status,
        note.action_destination,
        note.created_at,
        note.updated_at
      FROM retrospective_notes AS note
      JOIN sprints AS sprint ON sprint.id = note.sprint_id
      LEFT JOIN work_items AS item ON item.id = note.work_item_id;

    PRAGMA user_version = 1;
    """

  static let legacyCopyTableOrder = [
    "products",
    "agent_profiles",
    "epics",
    "work_items",
    "ticket_comments",
    "decision_records",
    "knowledge_claims",
    "activity_events",
    "sprints",
    "sprint_items",
    "suggestion_sessions",
    "ticket_suggestions",
    "suggestion_dependencies",
    "suggestion_existing_dependencies",
    "work_item_dependencies",
    "agent_runs",
    "candidate_revisions",
    "demo_sessions",
    "knowledge_pages",
    "knowledge_page_revisions",
    "knowledge_page_links",
    "agent_run_knowledge_pages",
    "agent_run_knowledge_destinations",
    "knowledge_page_proposals",
    "epic_planning_conversations",
    "agent_permission_requests",
    "agent_permission_grants",
    "retrospective_syntheses",
    "retrospective_notes",
    "retrospective_synthesis_sources",
    "retrospective_action_sources",
  ]
}
