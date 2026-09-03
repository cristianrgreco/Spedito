import Foundation

enum ProductDatabaseSchema {
  static let version: Int32 = 4

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
        updated_at REAL NOT NULL,
        next_ticket_key_number INTEGER NOT NULL DEFAULT 1
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
        created_at REAL NOT NULL,
        author_avatar_url TEXT,
        external_url TEXT,
        external_id TEXT,
        github_review_context_json TEXT
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
        updated_at REAL NOT NULL,
        execution_constraint_kind TEXT,
        execution_constraint_observed_at REAL,
        execution_constraint_retry_at REAL,
        execution_constraint_evidence TEXT,
        settlement_operation_id TEXT,
        settlement_candidate_version INTEGER,
        cumulative_used_tokens INTEGER
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
        delivery_kind TEXT NOT NULL DEFAULT 'repository_change'
          CHECK (delivery_kind IN ('repository_change', 'local_outcome')),
        reviewed_head_sha TEXT,
        review_run_id TEXT REFERENCES agent_runs(id),
        UNIQUE(work_item_id, version)
    );

    CREATE TABLE demo_sessions (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        source_kind TEXT NOT NULL
          CHECK (source_kind IN ('accepted_candidate', 'imported_repository')),
        launch_id TEXT NOT NULL,
        status TEXT NOT NULL,
        preview_worktree_path TEXT,
        allocated_port INTEGER,
        output TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(source_kind, launch_id)
    );

    CREATE TABLE product_repositories (
        product_id TEXT PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
        origin_url TEXT NOT NULL,
        source_default_branch TEXT NOT NULL,
        imported_sha TEXT NOT NULL,
        protected_knowledge_paths_json TEXT NOT NULL,
        blocks_knowledge_export INTEGER NOT NULL DEFAULT 0
          CHECK (blocks_knowledge_export IN (0, 1)),
        imported_at REAL NOT NULL
    );

    CREATE TABLE repository_knowledge_runs (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        attempt INTEGER NOT NULL CHECK (attempt > 0),
        purpose TEXT NOT NULL DEFAULT 'knowledge'
          CHECK (purpose IN ('knowledge', 'imported_app_launch')),
        analyzed_sha TEXT NOT NULL,
        analyzer_profile_id TEXT NOT NULL REFERENCES agent_profiles(id) ON DELETE RESTRICT,
        reviewer_profile_id TEXT NOT NULL REFERENCES agent_profiles(id) ON DELETE RESTRICT,
        analyzer_thread_id TEXT,
        analyzer_turn_id TEXT,
        reviewer_thread_id TEXT,
        reviewer_turn_id TEXT,
        status TEXT NOT NULL
          CHECK (
            status IN (
              'pending_analysis', 'analyzing', 'reviewing', 'publishing',
              'completed', 'failed', 'interrupted', 'stale'
            )
          ),
        analysis_summary TEXT,
        review_summary TEXT,
        error_message TEXT,
        knowledge_export_paths_json TEXT NOT NULL DEFAULT '[]',
        knowledge_commit_sha TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(product_id, attempt)
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
        updated_at REAL NOT NULL,
        source_repository_knowledge_run_id TEXT
          REFERENCES repository_knowledge_runs(id) ON DELETE SET NULL
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

    CREATE TABLE repository_knowledge_drafts (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL
          REFERENCES repository_knowledge_runs(id) ON DELETE CASCADE,
        operation TEXT NOT NULL CHECK (operation IN ('update', 'create')),
        target_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
        parent_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
        base_page_title TEXT,
        base_page_body_markdown TEXT,
        base_page_updated_at REAL,
        title TEXT NOT NULL,
        proposed_body_markdown TEXT NOT NULL,
        rationale TEXT NOT NULL,
        evidence_json TEXT NOT NULL,
        status TEXT NOT NULL
          CHECK (
            status IN ('proposed', 'approved', 'published', 'rejected', 'superseded')
          ),
        review_explanation TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          (
            operation = 'update'
            AND target_page_id IS NOT NULL
            AND parent_page_id IS NULL
            AND base_page_title IS NOT NULL
            AND base_page_body_markdown IS NOT NULL
            AND base_page_updated_at IS NOT NULL
          )
          OR
          (
            operation = 'create'
            AND target_page_id IS NULL
            AND parent_page_id IS NOT NULL
            AND base_page_title IS NULL
            AND base_page_body_markdown IS NULL
            AND base_page_updated_at IS NULL
          )
        )
    );

    CREATE TABLE repository_launch_proposals (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL UNIQUE
          REFERENCES repository_knowledge_runs(id) ON DELETE CASCADE,
        specification_json TEXT NOT NULL,
        evidence_json TEXT NOT NULL,
        status TEXT NOT NULL
          CHECK (status IN ('proposed', 'approved', 'published', 'rejected')),
        review_explanation TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
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

    CREATE TABLE remote_repository_connections (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL UNIQUE REFERENCES products(id) ON DELETE CASCADE,
        version INTEGER NOT NULL CHECK (version > 0),
        kind TEXT NOT NULL CHECK (kind IN ('imported_source', 'local_empty_repository')),
        account_id TEXT,
        installation_id INTEGER CHECK (installation_id IS NULL OR installation_id > 0),
        repository_id INTEGER CHECK (repository_id IS NULL OR repository_id > 0),
        owner TEXT,
        name TEXT,
        full_name TEXT,
        canonical_https_url TEXT,
        is_private INTEGER CHECK (is_private IS NULL OR is_private IN (0, 1)),
        default_branch TEXT,
        metadata_read INTEGER NOT NULL CHECK (metadata_read IN (0, 1)),
        contents_write INTEGER NOT NULL CHECK (contents_write IN (0, 1)),
        pull_requests_write INTEGER NOT NULL CHECK (pull_requests_write IN (0, 1)),
        workflows_write INTEGER NOT NULL CHECK (workflows_write IN (0, 1)),
        status TEXT NOT NULL
          CHECK (
            status IN (
              'selecting_repository', 'initializing_remote', 'connected',
              'disconnected', 'needs_authorization', 'needs_installation',
              'needs_target_review', 'unavailable'
            )
          ),
        error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
        latest_local_sha TEXT,
        latest_local_tree TEXT,
        latest_remote_sha TEXT,
        latest_remote_tree TEXT,
        latest_relationship TEXT
          CHECK (
            latest_relationship IS NULL OR latest_relationship IN (
              'aligned', 'local_ahead', 'remote_ahead',
              'history_alignment_available', 'diverged', 'unrelated'
            )
          ),
        latest_ahead_count INTEGER CHECK (latest_ahead_count IS NULL OR latest_ahead_count >= 0),
        latest_behind_count INTEGER CHECK (latest_behind_count IS NULL OR latest_behind_count >= 0),
        latest_checked_at REAL,
        pending_repository_id INTEGER CHECK (pending_repository_id IS NULL OR pending_repository_id > 0),
        pending_full_name TEXT,
        pending_canonical_https_url TEXT,
        pending_default_branch TEXT,
        pending_observed_at REAL,
        bootstrap_root_sha TEXT,
        bootstrap_root_tree TEXT,
        initialization_attempt_count INTEGER CHECK (
          initialization_attempt_count IS NULL OR initialization_attempt_count >= 0
        ),
        seeded_sha TEXT,
        origin_verified INTEGER CHECK (origin_verified IS NULL OR origin_verified IN (0, 1)),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          kind != 'imported_source'
          OR (
            bootstrap_root_sha IS NULL
            AND bootstrap_root_tree IS NULL
            AND initialization_attempt_count IS NULL
            AND seeded_sha IS NULL
            AND origin_verified IS NULL
            AND status NOT IN ('selecting_repository', 'initializing_remote')
          )
        ),
        CHECK (
          status != 'selecting_repository'
          OR (
            kind = 'local_empty_repository'
            AND account_id IS NOT NULL
            AND installation_id IS NOT NULL
          )
        ),
        CHECK (
          status != 'initializing_remote'
          OR (
            kind = 'local_empty_repository'
            AND account_id IS NOT NULL
            AND installation_id IS NOT NULL
            AND repository_id IS NOT NULL
            AND owner IS NOT NULL
            AND name IS NOT NULL
            AND full_name IS NOT NULL
            AND canonical_https_url IS NOT NULL
            AND is_private IS NOT NULL
            AND default_branch IS NOT NULL
            AND bootstrap_root_sha IS NOT NULL
            AND bootstrap_root_tree IS NOT NULL
            AND initialization_attempt_count > 0
          )
        ),
        CHECK (
          kind != 'local_empty_repository'
          OR status != 'connected'
          OR (
            bootstrap_root_sha IS NOT NULL
            AND bootstrap_root_tree IS NOT NULL
            AND seeded_sha = bootstrap_root_sha
            AND origin_verified = 1
          )
        ),
        CHECK (
          status NOT IN ('connected', 'needs_target_review', 'unavailable')
          OR (
            account_id IS NOT NULL
            AND installation_id IS NOT NULL
            AND repository_id IS NOT NULL
            AND owner IS NOT NULL
            AND name IS NOT NULL
            AND full_name IS NOT NULL
            AND canonical_https_url IS NOT NULL
            AND is_private IS NOT NULL
            AND default_branch IS NOT NULL
          )
        ),
        CHECK (
          (
            status = 'needs_target_review'
            AND pending_repository_id IS NOT NULL
            AND pending_full_name IS NOT NULL
            AND pending_canonical_https_url IS NOT NULL
            AND pending_default_branch IS NOT NULL
            AND pending_observed_at IS NOT NULL
          )
          OR
          (
            status != 'needs_target_review'
            AND pending_repository_id IS NULL
            AND pending_full_name IS NULL
            AND pending_canonical_https_url IS NULL
            AND pending_default_branch IS NULL
            AND pending_observed_at IS NULL
          )
        )
    );

    CREATE TABLE remote_publications (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        connection_id TEXT NOT NULL
          REFERENCES remote_repository_connections(id) ON DELETE RESTRICT,
        work_item_id TEXT
          REFERENCES work_items(id) ON DELETE RESTRICT,
        candidate_revision_id TEXT
          REFERENCES candidate_revisions(id) ON DELETE RESTRICT,
        purpose TEXT NOT NULL DEFAULT 'legacy_manual'
          CHECK (purpose IN ('legacy_manual', 'existing_product_history', 'ticket')),
        version INTEGER NOT NULL CHECK (version > 0),
        push_attempt_count INTEGER NOT NULL CHECK (push_attempt_count >= 0),
        pull_request_attempt_count INTEGER NOT NULL CHECK (pull_request_attempt_count >= 0),
        account_id TEXT NOT NULL,
        repository_id INTEGER NOT NULL CHECK (repository_id > 0),
        owner TEXT NOT NULL,
        name TEXT NOT NULL,
        full_name TEXT NOT NULL,
        canonical_https_url TEXT NOT NULL,
        is_private INTEGER NOT NULL CHECK (is_private IN (0, 1)),
        metadata_read INTEGER NOT NULL CHECK (metadata_read IN (0, 1)),
        contents_write INTEGER NOT NULL CHECK (contents_write IN (0, 1)),
        pull_requests_write INTEGER NOT NULL CHECK (pull_requests_write IN (0, 1)),
        workflows_write INTEGER NOT NULL CHECK (workflows_write IN (0, 1)),
        captured_local_sha TEXT NOT NULL,
        captured_local_tree TEXT NOT NULL,
        remote_base_sha TEXT NOT NULL,
        remote_base_tree TEXT NOT NULL,
        target_branch TEXT NOT NULL,
        publication_branch TEXT NOT NULL,
        manifest_digest TEXT NOT NULL,
        manifest_object_count INTEGER NOT NULL CHECK (manifest_object_count >= 0),
        manifest_commit_count INTEGER NOT NULL CHECK (manifest_commit_count >= 0),
        manifest_path_count INTEGER NOT NULL CHECK (manifest_path_count >= 0),
        commits_json TEXT NOT NULL,
        paths_json TEXT NOT NULL,
        title TEXT NOT NULL CHECK (length(title) > 0),
        body TEXT NOT NULL,
        text_revision INTEGER NOT NULL CHECK (text_revision > 0),
        status TEXT NOT NULL
          CHECK (
            status IN (
              'awaiting_confirmation', 'checking', 'pushing', 'branch_published',
              'creating_pull_request', 'open', 'open_outdated', 'open_stale',
              'merged', 'closed', 'cancelled', 'stale', 'failed'
            )
          ),
        pushed_sha TEXT,
        pull_request_number INTEGER CHECK (
          pull_request_number IS NULL OR pull_request_number > 0
        ),
        pull_request_node_id TEXT,
        pull_request_url TEXT,
        pull_request_state TEXT CHECK (
          pull_request_state IS NULL OR pull_request_state IN ('open', 'closed', 'merged')
        ),
        pull_request_is_draft INTEGER CHECK (
          pull_request_is_draft IS NULL OR pull_request_is_draft IN (0, 1)
        ),
        pull_request_head_sha TEXT,
        pull_request_base_branch TEXT,
        pull_request_base_sha TEXT,
        pull_request_merged_sha TEXT,
        pull_request_updated_at REAL,
        error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
        remote_branch_deleted_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          status NOT IN (
            'branch_published', 'creating_pull_request', 'open', 'open_outdated',
            'open_stale', 'merged', 'closed'
          )
          OR pushed_sha = captured_local_sha
        ),
        CHECK (
          (
            status IN ('open', 'open_outdated', 'open_stale', 'merged', 'closed')
            AND pull_request_number IS NOT NULL
            AND pull_request_node_id IS NOT NULL
            AND pull_request_url IS NOT NULL
            AND pull_request_state IS NOT NULL
            AND pull_request_is_draft IS NOT NULL
            AND pull_request_head_sha IS NOT NULL
            AND pull_request_base_branch IS NOT NULL
            AND pull_request_base_sha IS NOT NULL
            AND pull_request_updated_at IS NOT NULL
          )
          OR
          (
            status NOT IN ('open', 'open_outdated', 'open_stale', 'merged', 'closed')
            AND pull_request_number IS NULL
            AND pull_request_node_id IS NULL
            AND pull_request_url IS NULL
            AND pull_request_state IS NULL
            AND pull_request_is_draft IS NULL
            AND pull_request_head_sha IS NULL
            AND pull_request_base_branch IS NULL
            AND pull_request_base_sha IS NULL
            AND pull_request_merged_sha IS NULL
            AND pull_request_updated_at IS NULL
          )
        )
    );

    CREATE TABLE remote_safe_syncs (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        connection_id TEXT NOT NULL
          REFERENCES remote_repository_connections(id) ON DELETE RESTRICT,
        version INTEGER NOT NULL CHECK (version > 0),
        connection_version INTEGER NOT NULL CHECK (connection_version > 0),
        kind TEXT NOT NULL CHECK (kind IN ('fast_forward', 'history_alignment')),
        status TEXT NOT NULL
          CHECK (
            status IN (
              'awaiting_confirmation', 'accepting', 'accepted', 'rejected',
              'stale', 'failed'
            )
          ),
        observation_ref TEXT NOT NULL,
        local_sha TEXT NOT NULL,
        local_tree TEXT NOT NULL,
        remote_sha TEXT NOT NULL,
        remote_tree TEXT NOT NULL,
        merge_base_sha TEXT,
        candidate_sha TEXT NOT NULL,
        candidate_tree TEXT NOT NULL,
        proving_publication_id TEXT
          REFERENCES remote_publications(id) ON DELETE RESTRICT,
        published_sha TEXT,
        commits_json TEXT NOT NULL,
        paths_json TEXT NOT NULL,
        error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          (
            kind = 'fast_forward'
            AND candidate_sha = remote_sha
            AND candidate_tree = remote_tree
            AND proving_publication_id IS NULL
            AND published_sha IS NULL
          )
          OR
          (
            kind = 'history_alignment'
            AND candidate_tree = local_tree
            AND proving_publication_id IS NOT NULL
            AND published_sha IS NOT NULL
          )
        )
    );

    CREATE TABLE owner_notifications (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        kind TEXT NOT NULL
          CHECK (kind IN ('needs_input', 'refinement_complete', 'new_reply')),
        target_kind TEXT NOT NULL
          CHECK (target_kind IN ('ticket', 'epic', 'conversation_thread')),
        target_id TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at REAL NOT NULL,
        read_at REAL,
        resolved_at REAL,
        CHECK (
          resolved_at IS NULL
          OR (kind = 'needs_input' AND read_at IS NOT NULL)
        )
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
    CREATE UNIQUE INDEX idx_candidate_revisions_implementation_version
      ON candidate_revisions(implementation_run_id, version);
    CREATE INDEX idx_candidate_revisions_work_item
      ON candidate_revisions(work_item_id, version DESC);
    CREATE INDEX idx_demo_sessions_product_status
      ON demo_sessions(product_id, status, updated_at);
    CREATE INDEX idx_product_repositories_imported
      ON product_repositories(imported_at);
    CREATE INDEX idx_repository_knowledge_runs_product_status
      ON repository_knowledge_runs(product_id, status, attempt DESC);
    CREATE INDEX idx_repository_knowledge_drafts_run_status
      ON repository_knowledge_drafts(run_id, status, created_at);
    CREATE INDEX idx_repository_launch_proposals_status
      ON repository_launch_proposals(status, updated_at);
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
      ON retrospective_notes(sprint_id, work_item_id, profile_id, category, body);
    CREATE INDEX idx_retrospective_notes_sprint
      ON retrospective_notes(sprint_id, category, created_at);
    CREATE INDEX idx_conversation_threads_product_updated
      ON conversation_threads(product_id, updated_at DESC);
    CREATE INDEX idx_conversation_messages_thread_created
      ON conversation_messages(thread_id, created_at);

    CREATE UNIQUE INDEX idx_repository_knowledge_runs_one_active
      ON repository_knowledge_runs(product_id)
      WHERE status IN ('pending_analysis', 'analyzing', 'reviewing', 'publishing');
    CREATE INDEX idx_remote_repository_connections_product_status
      ON remote_repository_connections(product_id, status, updated_at);
    CREATE INDEX idx_remote_safe_syncs_product_status
      ON remote_safe_syncs(product_id, status, updated_at);
    CREATE INDEX idx_remote_publications_product_status
      ON remote_publications(product_id, status, updated_at);
    CREATE UNIQUE INDEX idx_remote_safe_syncs_one_active
      ON remote_safe_syncs(product_id)
      WHERE status IN ('awaiting_confirmation', 'accepting');
    CREATE UNIQUE INDEX idx_remote_publications_one_active_legacy
      ON remote_publications(product_id)
      WHERE work_item_id IS NULL
        AND status IN (
          'awaiting_confirmation', 'checking', 'pushing', 'branch_published',
          'creating_pull_request', 'open', 'open_outdated', 'open_stale'
        );
    CREATE UNIQUE INDEX idx_remote_publications_one_active_ticket
      ON remote_publications(work_item_id)
      WHERE work_item_id IS NOT NULL
        AND status IN (
          'awaiting_confirmation', 'checking', 'pushing', 'branch_published',
          'creating_pull_request', 'open', 'open_outdated', 'open_stale'
        );
    CREATE UNIQUE INDEX idx_ticket_comments_external_id
      ON ticket_comments(external_id)
      WHERE external_id IS NOT NULL;

    CREATE INDEX idx_owner_notifications_product_active
      ON owner_notifications(product_id, created_at DESC)
      WHERE read_at IS NULL
        OR (kind = 'needs_input' AND resolved_at IS NULL);
    CREATE INDEX idx_owner_notifications_target
      ON owner_notifications(product_id, target_kind, target_id, created_at DESC);

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
        page.source_repository_knowledge_run_id,
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
        candidate.delivery_kind,
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

    PRAGMA user_version = 4;
    """

  static let migrationV1ToV2 = """
    -- Spedito 0.1.0 shipped PRAGMA user_version = 1. This single migration carries a
    -- 0.1.0 database to the current schema; the pre-release chain it replaces is not
    -- reproduced here because no released build ever wrote versions 2 through 14.
    --
    -- Statement order is load-bearing:
    --   1. tables that do not exist at v1, created in their final shape;
    --   2. ALTER TABLE ... ADD COLUMN on tables that do exist at v1;
    --   3. the demo_sessions rebuild;
    --   4. indexes;
    --   5. data fix-ups;
    --   6. views last.
    -- ALTER TABLE ... RENAME reparses every view and fails on an unresolvable one,
    -- while CREATE VIEW accepts a missing column silently. The new view definitions
    -- must therefore come after both the ALTERs they depend on and the rebuild.

    CREATE TABLE product_repositories (
        product_id TEXT PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
        origin_url TEXT NOT NULL,
        source_default_branch TEXT NOT NULL,
        imported_sha TEXT NOT NULL,
        protected_knowledge_paths_json TEXT NOT NULL,
        blocks_knowledge_export INTEGER NOT NULL DEFAULT 0
          CHECK (blocks_knowledge_export IN (0, 1)),
        imported_at REAL NOT NULL
    );

    CREATE TABLE repository_knowledge_runs (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        attempt INTEGER NOT NULL CHECK (attempt > 0),
        purpose TEXT NOT NULL DEFAULT 'knowledge'
          CHECK (purpose IN ('knowledge', 'imported_app_launch')),
        analyzed_sha TEXT NOT NULL,
        analyzer_profile_id TEXT NOT NULL REFERENCES agent_profiles(id) ON DELETE RESTRICT,
        reviewer_profile_id TEXT NOT NULL REFERENCES agent_profiles(id) ON DELETE RESTRICT,
        analyzer_thread_id TEXT,
        analyzer_turn_id TEXT,
        reviewer_thread_id TEXT,
        reviewer_turn_id TEXT,
        status TEXT NOT NULL
          CHECK (
            status IN (
              'pending_analysis', 'analyzing', 'reviewing', 'publishing',
              'completed', 'failed', 'interrupted', 'stale'
            )
          ),
        analysis_summary TEXT,
        review_summary TEXT,
        error_message TEXT,
        knowledge_export_paths_json TEXT NOT NULL DEFAULT '[]',
        knowledge_commit_sha TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(product_id, attempt)
    );

    CREATE TABLE repository_knowledge_drafts (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL
          REFERENCES repository_knowledge_runs(id) ON DELETE CASCADE,
        operation TEXT NOT NULL CHECK (operation IN ('update', 'create')),
        target_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
        parent_page_id TEXT REFERENCES knowledge_pages(id) ON DELETE RESTRICT,
        base_page_title TEXT,
        base_page_body_markdown TEXT,
        base_page_updated_at REAL,
        title TEXT NOT NULL,
        proposed_body_markdown TEXT NOT NULL,
        rationale TEXT NOT NULL,
        evidence_json TEXT NOT NULL,
        status TEXT NOT NULL
          CHECK (
            status IN ('proposed', 'approved', 'published', 'rejected', 'superseded')
          ),
        review_explanation TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          (
            operation = 'update'
            AND target_page_id IS NOT NULL
            AND parent_page_id IS NULL
            AND base_page_title IS NOT NULL
            AND base_page_body_markdown IS NOT NULL
            AND base_page_updated_at IS NOT NULL
          )
          OR
          (
            operation = 'create'
            AND target_page_id IS NULL
            AND parent_page_id IS NOT NULL
            AND base_page_title IS NULL
            AND base_page_body_markdown IS NULL
            AND base_page_updated_at IS NULL
          )
        )
    );

    CREATE TABLE repository_launch_proposals (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL UNIQUE
          REFERENCES repository_knowledge_runs(id) ON DELETE CASCADE,
        specification_json TEXT NOT NULL,
        evidence_json TEXT NOT NULL,
        status TEXT NOT NULL
          CHECK (status IN ('proposed', 'approved', 'published', 'rejected')),
        review_explanation TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE remote_repository_connections (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL UNIQUE REFERENCES products(id) ON DELETE CASCADE,
        version INTEGER NOT NULL CHECK (version > 0),
        kind TEXT NOT NULL CHECK (kind IN ('imported_source', 'local_empty_repository')),
        account_id TEXT,
        installation_id INTEGER CHECK (installation_id IS NULL OR installation_id > 0),
        repository_id INTEGER CHECK (repository_id IS NULL OR repository_id > 0),
        owner TEXT,
        name TEXT,
        full_name TEXT,
        canonical_https_url TEXT,
        is_private INTEGER CHECK (is_private IS NULL OR is_private IN (0, 1)),
        default_branch TEXT,
        metadata_read INTEGER NOT NULL CHECK (metadata_read IN (0, 1)),
        contents_write INTEGER NOT NULL CHECK (contents_write IN (0, 1)),
        pull_requests_write INTEGER NOT NULL CHECK (pull_requests_write IN (0, 1)),
        workflows_write INTEGER NOT NULL CHECK (workflows_write IN (0, 1)),
        status TEXT NOT NULL
          CHECK (
            status IN (
              'selecting_repository', 'initializing_remote', 'connected',
              'disconnected', 'needs_authorization', 'needs_installation',
              'needs_target_review', 'unavailable'
            )
          ),
        error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
        latest_local_sha TEXT,
        latest_local_tree TEXT,
        latest_remote_sha TEXT,
        latest_remote_tree TEXT,
        latest_relationship TEXT
          CHECK (
            latest_relationship IS NULL OR latest_relationship IN (
              'aligned', 'local_ahead', 'remote_ahead',
              'history_alignment_available', 'diverged', 'unrelated'
            )
          ),
        latest_ahead_count INTEGER CHECK (latest_ahead_count IS NULL OR latest_ahead_count >= 0),
        latest_behind_count INTEGER CHECK (latest_behind_count IS NULL OR latest_behind_count >= 0),
        latest_checked_at REAL,
        pending_repository_id INTEGER CHECK (pending_repository_id IS NULL OR pending_repository_id > 0),
        pending_full_name TEXT,
        pending_canonical_https_url TEXT,
        pending_default_branch TEXT,
        pending_observed_at REAL,
        bootstrap_root_sha TEXT,
        bootstrap_root_tree TEXT,
        initialization_attempt_count INTEGER CHECK (
          initialization_attempt_count IS NULL OR initialization_attempt_count >= 0
        ),
        seeded_sha TEXT,
        origin_verified INTEGER CHECK (origin_verified IS NULL OR origin_verified IN (0, 1)),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          kind != 'imported_source'
          OR (
            bootstrap_root_sha IS NULL
            AND bootstrap_root_tree IS NULL
            AND initialization_attempt_count IS NULL
            AND seeded_sha IS NULL
            AND origin_verified IS NULL
            AND status NOT IN ('selecting_repository', 'initializing_remote')
          )
        ),
        CHECK (
          status != 'selecting_repository'
          OR (
            kind = 'local_empty_repository'
            AND account_id IS NOT NULL
            AND installation_id IS NOT NULL
          )
        ),
        CHECK (
          status != 'initializing_remote'
          OR (
            kind = 'local_empty_repository'
            AND account_id IS NOT NULL
            AND installation_id IS NOT NULL
            AND repository_id IS NOT NULL
            AND owner IS NOT NULL
            AND name IS NOT NULL
            AND full_name IS NOT NULL
            AND canonical_https_url IS NOT NULL
            AND is_private IS NOT NULL
            AND default_branch IS NOT NULL
            AND bootstrap_root_sha IS NOT NULL
            AND bootstrap_root_tree IS NOT NULL
            AND initialization_attempt_count > 0
          )
        ),
        CHECK (
          kind != 'local_empty_repository'
          OR status != 'connected'
          OR (
            bootstrap_root_sha IS NOT NULL
            AND bootstrap_root_tree IS NOT NULL
            AND seeded_sha = bootstrap_root_sha
            AND origin_verified = 1
          )
        ),
        CHECK (
          status NOT IN ('connected', 'needs_target_review', 'unavailable')
          OR (
            account_id IS NOT NULL
            AND installation_id IS NOT NULL
            AND repository_id IS NOT NULL
            AND owner IS NOT NULL
            AND name IS NOT NULL
            AND full_name IS NOT NULL
            AND canonical_https_url IS NOT NULL
            AND is_private IS NOT NULL
            AND default_branch IS NOT NULL
          )
        ),
        CHECK (
          (
            status = 'needs_target_review'
            AND pending_repository_id IS NOT NULL
            AND pending_full_name IS NOT NULL
            AND pending_canonical_https_url IS NOT NULL
            AND pending_default_branch IS NOT NULL
            AND pending_observed_at IS NOT NULL
          )
          OR
          (
            status != 'needs_target_review'
            AND pending_repository_id IS NULL
            AND pending_full_name IS NULL
            AND pending_canonical_https_url IS NULL
            AND pending_default_branch IS NULL
            AND pending_observed_at IS NULL
          )
        )
    );

    CREATE TABLE remote_publications (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        connection_id TEXT NOT NULL
          REFERENCES remote_repository_connections(id) ON DELETE RESTRICT,
        work_item_id TEXT
          REFERENCES work_items(id) ON DELETE RESTRICT,
        candidate_revision_id TEXT
          REFERENCES candidate_revisions(id) ON DELETE RESTRICT,
        purpose TEXT NOT NULL DEFAULT 'legacy_manual'
          CHECK (purpose IN ('legacy_manual', 'existing_product_history', 'ticket')),
        version INTEGER NOT NULL CHECK (version > 0),
        push_attempt_count INTEGER NOT NULL CHECK (push_attempt_count >= 0),
        pull_request_attempt_count INTEGER NOT NULL CHECK (pull_request_attempt_count >= 0),
        account_id TEXT NOT NULL,
        repository_id INTEGER NOT NULL CHECK (repository_id > 0),
        owner TEXT NOT NULL,
        name TEXT NOT NULL,
        full_name TEXT NOT NULL,
        canonical_https_url TEXT NOT NULL,
        is_private INTEGER NOT NULL CHECK (is_private IN (0, 1)),
        metadata_read INTEGER NOT NULL CHECK (metadata_read IN (0, 1)),
        contents_write INTEGER NOT NULL CHECK (contents_write IN (0, 1)),
        pull_requests_write INTEGER NOT NULL CHECK (pull_requests_write IN (0, 1)),
        workflows_write INTEGER NOT NULL CHECK (workflows_write IN (0, 1)),
        captured_local_sha TEXT NOT NULL,
        captured_local_tree TEXT NOT NULL,
        remote_base_sha TEXT NOT NULL,
        remote_base_tree TEXT NOT NULL,
        target_branch TEXT NOT NULL,
        publication_branch TEXT NOT NULL,
        manifest_digest TEXT NOT NULL,
        manifest_object_count INTEGER NOT NULL CHECK (manifest_object_count >= 0),
        manifest_commit_count INTEGER NOT NULL CHECK (manifest_commit_count >= 0),
        manifest_path_count INTEGER NOT NULL CHECK (manifest_path_count >= 0),
        commits_json TEXT NOT NULL,
        paths_json TEXT NOT NULL,
        title TEXT NOT NULL CHECK (length(title) > 0),
        body TEXT NOT NULL,
        text_revision INTEGER NOT NULL CHECK (text_revision > 0),
        status TEXT NOT NULL
          CHECK (
            status IN (
              'awaiting_confirmation', 'checking', 'pushing', 'branch_published',
              'creating_pull_request', 'open', 'open_outdated', 'open_stale',
              'merged', 'closed', 'cancelled', 'stale', 'failed'
            )
          ),
        pushed_sha TEXT,
        pull_request_number INTEGER CHECK (
          pull_request_number IS NULL OR pull_request_number > 0
        ),
        pull_request_node_id TEXT,
        pull_request_url TEXT,
        pull_request_state TEXT CHECK (
          pull_request_state IS NULL OR pull_request_state IN ('open', 'closed', 'merged')
        ),
        pull_request_is_draft INTEGER CHECK (
          pull_request_is_draft IS NULL OR pull_request_is_draft IN (0, 1)
        ),
        pull_request_head_sha TEXT,
        pull_request_base_branch TEXT,
        pull_request_base_sha TEXT,
        pull_request_merged_sha TEXT,
        pull_request_updated_at REAL,
        error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
        remote_branch_deleted_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          status NOT IN (
            'branch_published', 'creating_pull_request', 'open', 'open_outdated',
            'open_stale', 'merged', 'closed'
          )
          OR pushed_sha = captured_local_sha
        ),
        CHECK (
          (
            status IN ('open', 'open_outdated', 'open_stale', 'merged', 'closed')
            AND pull_request_number IS NOT NULL
            AND pull_request_node_id IS NOT NULL
            AND pull_request_url IS NOT NULL
            AND pull_request_state IS NOT NULL
            AND pull_request_is_draft IS NOT NULL
            AND pull_request_head_sha IS NOT NULL
            AND pull_request_base_branch IS NOT NULL
            AND pull_request_base_sha IS NOT NULL
            AND pull_request_updated_at IS NOT NULL
          )
          OR
          (
            status NOT IN ('open', 'open_outdated', 'open_stale', 'merged', 'closed')
            AND pull_request_number IS NULL
            AND pull_request_node_id IS NULL
            AND pull_request_url IS NULL
            AND pull_request_state IS NULL
            AND pull_request_is_draft IS NULL
            AND pull_request_head_sha IS NULL
            AND pull_request_base_branch IS NULL
            AND pull_request_base_sha IS NULL
            AND pull_request_merged_sha IS NULL
            AND pull_request_updated_at IS NULL
          )
        )
    );

    CREATE TABLE remote_safe_syncs (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        connection_id TEXT NOT NULL
          REFERENCES remote_repository_connections(id) ON DELETE RESTRICT,
        version INTEGER NOT NULL CHECK (version > 0),
        connection_version INTEGER NOT NULL CHECK (connection_version > 0),
        kind TEXT NOT NULL CHECK (kind IN ('fast_forward', 'history_alignment')),
        status TEXT NOT NULL
          CHECK (
            status IN (
              'awaiting_confirmation', 'accepting', 'accepted', 'rejected',
              'stale', 'failed'
            )
          ),
        observation_ref TEXT NOT NULL,
        local_sha TEXT NOT NULL,
        local_tree TEXT NOT NULL,
        remote_sha TEXT NOT NULL,
        remote_tree TEXT NOT NULL,
        merge_base_sha TEXT,
        candidate_sha TEXT NOT NULL,
        candidate_tree TEXT NOT NULL,
        proving_publication_id TEXT
          REFERENCES remote_publications(id) ON DELETE RESTRICT,
        published_sha TEXT,
        commits_json TEXT NOT NULL,
        paths_json TEXT NOT NULL,
        error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (
          (
            kind = 'fast_forward'
            AND candidate_sha = remote_sha
            AND candidate_tree = remote_tree
            AND proving_publication_id IS NULL
            AND published_sha IS NULL
          )
          OR
          (
            kind = 'history_alignment'
            AND candidate_tree = local_tree
            AND proving_publication_id IS NOT NULL
            AND published_sha IS NOT NULL
          )
        )
    );

    CREATE TABLE owner_notifications (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        kind TEXT NOT NULL
          CHECK (kind IN ('needs_input', 'refinement_complete', 'new_reply')),
        target_kind TEXT NOT NULL
          CHECK (target_kind IN ('ticket', 'epic', 'conversation_thread')),
        target_id TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at REAL NOT NULL,
        read_at REAL,
        resolved_at REAL,
        CHECK (
          resolved_at IS NULL
          OR (kind = 'needs_input' AND read_at IS NOT NULL)
        )
    );

    -- Columns added to tables that already exist at v1. Their order fixes the final
    -- column ordinals, so it matches the order the replaced chain applied them in.
    ALTER TABLE knowledge_pages
      ADD COLUMN source_repository_knowledge_run_id TEXT
      REFERENCES repository_knowledge_runs(id) ON DELETE SET NULL;

    ALTER TABLE ticket_comments
      ADD COLUMN author_avatar_url TEXT;
    ALTER TABLE ticket_comments
      ADD COLUMN external_url TEXT;
    ALTER TABLE ticket_comments
      ADD COLUMN external_id TEXT;
    ALTER TABLE ticket_comments
      ADD COLUMN github_review_context_json TEXT;

    ALTER TABLE candidate_revisions
      ADD COLUMN delivery_kind TEXT NOT NULL DEFAULT 'repository_change'
      CHECK (delivery_kind IN ('repository_change', 'local_outcome'));

    ALTER TABLE agent_runs ADD COLUMN execution_constraint_kind TEXT;
    ALTER TABLE agent_runs ADD COLUMN execution_constraint_observed_at REAL;
    ALTER TABLE agent_runs ADD COLUMN execution_constraint_retry_at REAL;
    ALTER TABLE agent_runs ADD COLUMN execution_constraint_evidence TEXT;

    -- demo_sessions is generalized from accepted candidates to any launch source.
    -- Nothing references demo_sessions, so the rename is safe; note that RENAME does
    -- rewrite the referencing text of inbound foreign keys, so a future table
    -- pointing here would need this block revisited.
    ALTER TABLE demo_sessions RENAME TO demo_sessions_v2;

    CREATE TABLE demo_sessions (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        source_kind TEXT NOT NULL
          CHECK (source_kind IN ('accepted_candidate', 'imported_repository')),
        launch_id TEXT NOT NULL,
        status TEXT NOT NULL,
        preview_worktree_path TEXT,
        allocated_port INTEGER,
        output TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(source_kind, launch_id)
    );

    INSERT INTO demo_sessions (
        id, product_id, source_kind, launch_id, status, preview_worktree_path,
        allocated_port, output, error_message, created_at, updated_at
    )
    SELECT
        id, product_id, 'accepted_candidate', candidate_revision_id, status,
        preview_worktree_path, allocated_port, output, error_message, created_at, updated_at
    FROM demo_sessions_v2;

    DROP TABLE demo_sessions_v2;

    CREATE INDEX idx_product_repositories_imported
      ON product_repositories(imported_at);
    CREATE INDEX idx_repository_knowledge_runs_product_status
      ON repository_knowledge_runs(product_id, status, attempt DESC);
    CREATE INDEX idx_repository_knowledge_drafts_run_status
      ON repository_knowledge_drafts(run_id, status, created_at);
    CREATE UNIQUE INDEX idx_repository_knowledge_runs_one_active
      ON repository_knowledge_runs(product_id)
      WHERE status IN ('pending_analysis', 'analyzing', 'reviewing', 'publishing');

    -- The v1 index on demo_sessions followed the renamed table and died with it.
    CREATE INDEX idx_demo_sessions_product_status
      ON demo_sessions(product_id, status, updated_at);
    CREATE INDEX idx_repository_launch_proposals_status
      ON repository_launch_proposals(status, updated_at);

    CREATE INDEX idx_remote_repository_connections_product_status
      ON remote_repository_connections(product_id, status, updated_at);
    CREATE INDEX idx_remote_safe_syncs_product_status
      ON remote_safe_syncs(product_id, status, updated_at);
    CREATE INDEX idx_remote_publications_product_status
      ON remote_publications(product_id, status, updated_at);
    CREATE UNIQUE INDEX idx_remote_safe_syncs_one_active
      ON remote_safe_syncs(product_id)
      WHERE status IN ('awaiting_confirmation', 'accepting');
    CREATE UNIQUE INDEX idx_remote_publications_one_active_legacy
      ON remote_publications(product_id)
      WHERE work_item_id IS NULL
        AND status IN (
          'awaiting_confirmation', 'checking', 'pushing', 'branch_published',
          'creating_pull_request', 'open', 'open_outdated', 'open_stale'
        );
    CREATE UNIQUE INDEX idx_remote_publications_one_active_ticket
      ON remote_publications(work_item_id)
      WHERE work_item_id IS NOT NULL
        AND status IN (
          'awaiting_confirmation', 'checking', 'pushing', 'branch_published',
          'creating_pull_request', 'open', 'open_outdated', 'open_stale'
        );
    CREATE UNIQUE INDEX idx_ticket_comments_external_id
      ON ticket_comments(external_id)
      WHERE external_id IS NOT NULL;

    CREATE INDEX idx_owner_notifications_product_active
      ON owner_notifications(product_id, created_at DESC)
      WHERE read_at IS NULL
        OR (kind = 'needs_input' AND resolved_at IS NULL);
    CREATE INDEX idx_owner_notifications_target
      ON owner_notifications(product_id, target_kind, target_id, created_at DESC);

    -- The only data fix-up that can still match on a 0.1.0 database. The replaced
    -- chain also cleaned up remote_publications rows (twice), unfinished
    -- repository_knowledge_runs, and empty GitHub review ticket_comments; every one
    -- of those targets a table or column that does not exist at v1, so none of them
    -- can affect a single row here.
    UPDATE sprints
    SET goal = ''
    WHERE state = 'draft' AND trim(goal) = 'Next valuable increment';

    DROP VIEW agent_verified_knowledge;
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
        page.source_repository_knowledge_run_id,
        page.updated_at
      FROM knowledge_pages AS page
      LEFT JOIN work_items AS item ON item.id = page.source_work_item_id
      WHERE page.verification_status = 'verified';

    DROP VIEW agent_delivery_provenance;
    CREATE VIEW agent_delivery_provenance AS
      SELECT
        candidate.id AS candidate_id,
        candidate.product_id,
        candidate.work_item_id,
        item.item_key,
        item.title AS ticket_title,
        candidate.version AS candidate_version,
        candidate.delivery_kind,
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

    PRAGMA user_version = 2;
    """

  static let migrationV2ToV3 = """
    ALTER TABLE agent_runs ADD COLUMN settlement_operation_id TEXT;
    ALTER TABLE agent_runs ADD COLUMN settlement_candidate_version INTEGER;
    ALTER TABLE agent_runs ADD COLUMN cumulative_used_tokens INTEGER;
    ALTER TABLE candidate_revisions ADD COLUMN reviewed_head_sha TEXT;
    ALTER TABLE candidate_revisions ADD COLUMN review_run_id TEXT REFERENCES agent_runs(id);
    CREATE UNIQUE INDEX idx_candidate_revisions_implementation_version
      ON candidate_revisions(implementation_run_id, version);
    PRAGMA user_version = 3;
    """

  /// Adds the durable ticket key counter. Ticket suggestions persisted from
  /// this version on carry final `T` keys allocated from this counter, so the
  /// reference the product owner reads on a proposal is the key the accepted
  /// ticket keeps. The Swift migration step in
  /// `SQLiteStore.assignDurableKeysToPendingSuggestions` runs in the same
  /// transaction and re-keys still-proposed suggestions.
  static let migrationV3ToV4 = """
    ALTER TABLE products
      ADD COLUMN next_ticket_key_number INTEGER NOT NULL DEFAULT 1;
    UPDATE products
    SET next_ticket_key_number = COALESCE(
        (
          SELECT MAX(key_number) FROM work_items
          WHERE work_items.product_id = products.id
        ),
        0
    ) + 1;
    PRAGMA user_version = 4;
    """

  static let legacyCopyTableOrder = [
    "products",
    "remote_repository_connections",
    "remote_publications",
    "remote_safe_syncs",
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
    "product_repositories",
    "repository_knowledge_runs",
    "repository_knowledge_drafts",
    "repository_launch_proposals",
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
    "owner_notifications",
    "conversation_threads",
    "conversation_messages",
  ]
}
