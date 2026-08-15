import Foundation
import SQLite3

extension SQLiteStore {
  public func createRepositoryKnowledgeRun(
    _ run: RepositoryKnowledgeRun
  ) throws {
    try withStatement(
      """
      INSERT INTO repository_knowledge_runs (
          id, product_id, attempt, purpose, analyzed_sha, analyzer_profile_id,
          reviewer_profile_id, analyzer_thread_id, analyzer_turn_id,
          reviewer_thread_id, reviewer_turn_id, status, analysis_summary,
          review_summary, error_message, knowledge_export_paths_json,
          knowledge_commit_sha, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bindRepositoryKnowledgeRun(run, to: statement)
      try stepDone(statement)
    }
  }

  public func fetchRepositoryKnowledgeRuns(
    productID: UUID
  ) throws -> [RepositoryKnowledgeRun] {
    try withStatement(
      """
      SELECT id, product_id, attempt, purpose, analyzed_sha, analyzer_profile_id,
             reviewer_profile_id, analyzer_thread_id, analyzer_turn_id,
             reviewer_thread_id, reviewer_turn_id, status, analysis_summary,
             review_summary, error_message, knowledge_export_paths_json,
             knowledge_commit_sha, created_at, updated_at
      FROM repository_knowledge_runs
      WHERE product_id = ?
      ORDER BY attempt DESC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var runs: [RepositoryKnowledgeRun] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        runs.append(try decodeRepositoryKnowledgeRun(statement))
      }
      return runs
    }
  }

  public func fetchLatestRepositoryKnowledgeRun(
    productID: UUID
  ) throws -> RepositoryKnowledgeRun? {
    try fetchRepositoryKnowledgeRuns(productID: productID).first
  }

  public func fetchRepositoryKnowledgeRun(id: UUID) throws -> RepositoryKnowledgeRun {
    try withStatement(
      """
      SELECT id, product_id, attempt, purpose, analyzed_sha, analyzer_profile_id,
             reviewer_profile_id, analyzer_thread_id, analyzer_turn_id,
             reviewer_thread_id, reviewer_turn_id, status, analysis_summary,
             review_summary, error_message, knowledge_export_paths_json,
             knowledge_commit_sha, created_at, updated_at
      FROM repository_knowledge_runs
      WHERE id = ?;
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw PersistenceError.recordNotFound("repository knowledge run \(id)")
      }
      return try decodeRepositoryKnowledgeRun(statement)
    }
  }

  @discardableResult
  public func updateRepositoryKnowledgeRun(
    id: UUID,
    status: RepositoryKnowledgeRunStatus,
    analyzerThreadID: String? = nil,
    analyzerTurnID: String? = nil,
    reviewerThreadID: String? = nil,
    reviewerTurnID: String? = nil,
    analysisSummary: String? = nil,
    reviewSummary: String? = nil,
    errorMessage: String? = nil
  ) throws -> RepositoryKnowledgeRun {
    let now = Date()
    try withStatement(
      """
      UPDATE repository_knowledge_runs
      SET status = ?,
          analyzer_thread_id = COALESCE(?, analyzer_thread_id),
          analyzer_turn_id = COALESCE(?, analyzer_turn_id),
          reviewer_thread_id = COALESCE(?, reviewer_thread_id),
          reviewer_turn_id = COALESCE(?, reviewer_turn_id),
          analysis_summary = COALESCE(?, analysis_summary),
          review_summary = COALESCE(?, review_summary),
          error_message = ?,
          updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bindOptionalString(analyzerThreadID, to: 2, in: statement)
      try bindOptionalString(analyzerTurnID, to: 3, in: statement)
      try bindOptionalString(reviewerThreadID, to: 4, in: statement)
      try bindOptionalString(reviewerTurnID, to: 5, in: statement)
      try bindOptionalString(analysisSummary, to: 6, in: statement)
      try bindOptionalString(reviewSummary, to: 7, in: statement)
      try bindOptionalString(errorMessage, to: 8, in: statement)
      try bind(now.timeIntervalSince1970, to: 9, in: statement)
      try bind(id.uuidString, to: 10, in: statement)
      try stepDone(statement)
    }
    return try fetchRepositoryKnowledgeRun(id: id)
  }

  public func recordRepositoryKnowledgeAnalysis(
    runID: UUID,
    summary: String,
    drafts: [RepositoryKnowledgeDraft],
    launchProposal: RepositoryLaunchProposal? = nil,
    analyzerThreadID: String,
    analyzerTurnID: String
  ) throws -> RepositoryKnowledgeRun {
    let run = try fetchRepositoryKnowledgeRun(id: runID)
    guard run.status == .analyzing || run.status == .pendingAnalysis else {
      throw PersistenceError.corruptData("Repository analysis is not active")
    }
    guard run.purpose == .knowledge || drafts.isEmpty else {
      throw PersistenceError.corruptData(
        "An imported app launch check cannot change product knowledge"
      )
    }
    guard drafts.allSatisfy({ $0.runID == runID && $0.status == .proposed }) else {
      throw PersistenceError.corruptData("Repository knowledge drafts do not match the run")
    }
    guard
      launchProposal == nil
        || (launchProposal?.runID == runID && launchProposal?.status == .proposed)
    else {
      throw PersistenceError.corruptData("Imported app launch proposal does not match the run")
    }
    let now = Date()
    try transaction {
      for draft in drafts {
        try insertRepositoryKnowledgeDraft(draft)
      }
      if let launchProposal {
        try insertRepositoryLaunchProposal(launchProposal)
      }
      try withStatement(
        """
        UPDATE repository_knowledge_runs
        SET status = ?, analysis_summary = ?, analyzer_thread_id = ?,
            analyzer_turn_id = ?, error_message = NULL, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(
          drafts.isEmpty && launchProposal == nil
            ? RepositoryKnowledgeRunStatus.completed.rawValue
            : RepositoryKnowledgeRunStatus.reviewing.rawValue,
          to: 1,
          in: statement
        )
        try bind(summary, to: 2, in: statement)
        try bind(analyzerThreadID, to: 3, in: statement)
        try bind(analyzerTurnID, to: 4, in: statement)
        try bind(now.timeIntervalSince1970, to: 5, in: statement)
        try bind(runID.uuidString, to: 6, in: statement)
        try stepDone(statement)
      }
    }
    return try fetchRepositoryKnowledgeRun(id: runID)
  }

  public func fetchRepositoryKnowledgeDrafts(
    runID: UUID
  ) throws -> [RepositoryKnowledgeDraft] {
    try withStatement(
      """
      SELECT id, run_id, operation, target_page_id, parent_page_id,
             base_page_title, base_page_body_markdown, base_page_updated_at,
             title, proposed_body_markdown, rationale, evidence_json, status,
             review_explanation, created_at, updated_at
      FROM repository_knowledge_drafts
      WHERE run_id = ?
      ORDER BY created_at ASC, id ASC;
      """
    ) { statement in
      try bind(runID.uuidString, to: 1, in: statement)
      var drafts: [RepositoryKnowledgeDraft] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        drafts.append(try decodeRepositoryKnowledgeDraft(statement))
      }
      return drafts
    }
  }

  public func fetchRepositoryLaunchProposal(
    runID: UUID
  ) throws -> RepositoryLaunchProposal? {
    try withStatement(
      """
      SELECT id, run_id, specification_json, evidence_json, status,
             review_explanation, created_at, updated_at
      FROM repository_launch_proposals
      WHERE run_id = ?;
      """
    ) { statement in
      try bind(runID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return try decodeRepositoryLaunchProposal(statement)
    }
  }

  public func fetchImportedAppLaunch(productID: UUID) throws -> ImportedAppLaunch? {
    try withStatement(
      """
      SELECT proposal.id, proposal.run_id, run.product_id, run.analyzed_sha,
             proposal.specification_json, proposal.evidence_json, proposal.updated_at
      FROM repository_launch_proposals AS proposal
      JOIN repository_knowledge_runs AS run ON run.id = proposal.run_id
      JOIN product_repositories AS repository ON repository.product_id = run.product_id
      WHERE run.product_id = ?
        AND run.status = 'completed'
        AND proposal.status = 'published'
        AND run.analyzed_sha = repository.imported_sha
      ORDER BY proposal.updated_at DESC, proposal.id DESC
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      guard
        let id = UUID(uuidString: try text(statement, column: 0)),
        let runID = UUID(uuidString: try text(statement, column: 1)),
        let storedProductID = UUID(uuidString: try text(statement, column: 2))
      else {
        throw PersistenceError.corruptData("Invalid imported app launch")
      }
      return ImportedAppLaunch(
        id: id,
        runID: runID,
        productID: storedProductID,
        revisionSHA: try text(statement, column: 3),
        specification: try decodeJSON(
          DemoLaunchSpecification.self,
          from: try text(statement, column: 4)
        ),
        evidence: try decodeJSON(
          [RepositoryEvidence].self,
          from: try text(statement, column: 5)
        ),
        publishedAt: date(statement, column: 6)
      )
    }
  }

  public func recordRepositoryKnowledgeReview(
    runID: UUID,
    summary: String,
    decisions: [RepositoryKnowledgeReviewDecision],
    launchDecision: RepositoryLaunchReviewDecision? = nil,
    reviewerThreadID: String,
    reviewerTurnID: String
  ) throws -> RepositoryKnowledgeRun {
    let run = try fetchRepositoryKnowledgeRun(id: runID)
    guard run.status == .reviewing else {
      throw PersistenceError.corruptData("Repository knowledge is not awaiting review")
    }
    let drafts = try fetchRepositoryKnowledgeDrafts(runID: runID)
    for draft in drafts {
      switch draft.operation {
      case .update:
        guard
          let targetID = draft.targetPageID,
          let target = try? fetchKnowledgePage(id: targetID),
          target.title == draft.basePageTitle,
          target.bodyMarkdown == draft.basePageBodyMarkdown,
          target.updatedAt == draft.basePageUpdatedAt
        else {
          throw PersistenceError.corruptData(
            "Repository knowledge changed after analysis and must be analyzed again"
          )
        }
      case .create:
        guard
          let parentID = draft.parentPageID,
          let parent = try? fetchKnowledgePage(id: parentID),
          parent.productID == run.productID,
          parent.kind == .section
        else {
          throw PersistenceError.corruptData(
            "Repository knowledge creation parent changed after analysis"
          )
        }
      }
    }
    let draftIDs = Set(drafts.map(\.id))
    let decisionIDs = Set(decisions.map(\.draftID))
    guard decisions.count == draftIDs.count, decisionIDs == draftIDs else {
      throw PersistenceError.corruptData(
        "The tech lead must return exactly one decision for every repository knowledge draft"
      )
    }
    guard
      decisions.allSatisfy({
        !$0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw PersistenceError.corruptData("Every repository knowledge decision needs an explanation")
    }
    let launchProposal = try fetchRepositoryLaunchProposal(runID: runID)
    guard
      (launchProposal == nil && launchDecision == nil)
        || (launchProposal?.id == launchDecision?.proposalID
          && !(launchDecision?.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true))
    else {
      throw PersistenceError.corruptData(
        "The tech lead must decide the exact imported app launch proposal"
      )
    }
    let now = Date()
    try transaction {
      for decision in decisions {
        try withStatement(
          """
          UPDATE repository_knowledge_drafts
          SET status = ?, review_explanation = ?, updated_at = ?
          WHERE id = ? AND run_id = ? AND status = 'proposed';
          """
        ) { statement in
          try bind(
            decision.approved
              ? RepositoryKnowledgeDraftStatus.approved.rawValue
              : RepositoryKnowledgeDraftStatus.rejected.rawValue,
            to: 1,
            in: statement
          )
          try bind(decision.explanation, to: 2, in: statement)
          try bind(now.timeIntervalSince1970, to: 3, in: statement)
          try bind(decision.draftID.uuidString, to: 4, in: statement)
          try bind(runID.uuidString, to: 5, in: statement)
          try stepDone(statement)
        }
      }
      if let launchDecision {
        try withStatement(
          """
          UPDATE repository_launch_proposals
          SET status = ?, review_explanation = ?, updated_at = ?
          WHERE id = ? AND run_id = ? AND status = 'proposed';
          """
        ) { statement in
          try bind(
            launchDecision.approved
              ? RepositoryLaunchProposalStatus.approved.rawValue
              : RepositoryLaunchProposalStatus.rejected.rawValue,
            to: 1,
            in: statement
          )
          try bind(launchDecision.explanation, to: 2, in: statement)
          try bind(now.timeIntervalSince1970, to: 3, in: statement)
          try bind(launchDecision.proposalID.uuidString, to: 4, in: statement)
          try bind(runID.uuidString, to: 5, in: statement)
          try stepDone(statement)
        }
      }
      try withStatement(
        """
        UPDATE repository_knowledge_runs
        SET status = 'publishing', review_summary = ?, reviewer_thread_id = ?,
            reviewer_turn_id = ?, error_message = NULL, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(summary, to: 1, in: statement)
        try bind(reviewerThreadID, to: 2, in: statement)
        try bind(reviewerTurnID, to: 3, in: statement)
        try bind(now.timeIntervalSince1970, to: 4, in: statement)
        try bind(runID.uuidString, to: 5, in: statement)
        try stepDone(statement)
      }
    }
    return try fetchRepositoryKnowledgeRun(id: runID)
  }

  public func projectRepositoryKnowledgePublication(
    runID: UUID
  ) throws -> RepositoryKnowledgePublicationProjection {
    let run = try fetchRepositoryKnowledgeRun(id: runID)
    guard run.status == .publishing else {
      throw PersistenceError.corruptData("Repository knowledge is not ready to publish")
    }
    var pages = try fetchKnowledgePages(productID: run.productID)
    let drafts = try fetchRepositoryKnowledgeDrafts(runID: runID)
      .filter { $0.status == .approved || $0.status == .published }
    var changedPageIDs: [UUID] = []
    for draft in drafts {
      switch draft.operation {
      case .update:
        guard
          let targetID = draft.targetPageID,
          let index = pages.firstIndex(where: { $0.id == targetID }),
          pages[index].title == draft.basePageTitle,
          pages[index].bodyMarkdown == draft.basePageBodyMarkdown,
          pages[index].updatedAt == draft.basePageUpdatedAt
        else {
          throw PersistenceError.corruptData(
            "Repository knowledge changed after analysis and must be analyzed again"
          )
        }
        pages[index].title = draft.title
        pages[index].bodyMarkdown = KnowledgeMarkdown.normalizedBody(
          draft.proposedBodyMarkdown
        )
        pages[index].sourceRepositoryKnowledgeRunID = run.id
        pages[index].updatedAt = draft.updatedAt
        changedPageIDs.append(targetID)
      case .create:
        guard
          let parentID = draft.parentPageID,
          let parent = pages.first(where: { $0.id == parentID }),
          parent.productID == run.productID,
          parent.kind == .section
        else {
          throw PersistenceError.corruptData("Repository knowledge creation parent is unavailable")
        }
        let siblingSlugs = Set(pages.filter { $0.parentID == parentID }.map(\.slug))
        let slug = uniqueKnowledgeSlug(title: draft.title, existing: siblingSlugs)
        let sortOrder =
          (pages.filter { $0.parentID == parentID }.map(\.sortOrder).max() ?? -1) + 1
        pages.append(
          KnowledgePage(
            id: draft.id,
            productID: run.productID,
            parentID: parentID,
            title: draft.title,
            slug: slug,
            bodyMarkdown: KnowledgeMarkdown.normalizedBody(draft.proposedBodyMarkdown),
            verificationStatus: .verified,
            sortOrder: sortOrder,
            sourceRepositoryKnowledgeRunID: run.id,
            createdAt: draft.updatedAt,
            updatedAt: draft.updatedAt
          )
        )
        changedPageIDs.append(draft.id)
      }
    }
    pages.sort {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      return $0.id.uuidString < $1.id.uuidString
    }
    return RepositoryKnowledgePublicationProjection(
      pages: pages,
      changedPageIDs: changedPageIDs.sorted { $0.uuidString < $1.uuidString }
    )
  }

  @discardableResult
  public func recordRepositoryKnowledgeExport(
    runID: UUID,
    paths: [String]
  ) throws -> RepositoryKnowledgeRun {
    let run = try fetchRepositoryKnowledgeRun(id: runID)
    guard run.status == .publishing else {
      throw PersistenceError.corruptData("Repository knowledge is not ready to publish")
    }
    let sortedPaths = Array(Set(paths)).sorted()
    try withStatement(
      """
      UPDATE repository_knowledge_runs
      SET knowledge_export_paths_json = ?, updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(try encodeStringArray(sortedPaths), to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(runID.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
    return try fetchRepositoryKnowledgeRun(id: runID)
  }

  @discardableResult
  public func recordRepositoryKnowledgeCommitSHA(
    runID: UUID,
    sha: String
  ) throws -> RepositoryKnowledgeRun {
    let run = try fetchRepositoryKnowledgeRun(id: runID)
    guard run.status == .publishing else {
      throw PersistenceError.corruptData("Repository knowledge is not ready to publish")
    }
    try withStatement(
      """
      UPDATE repository_knowledge_runs
      SET knowledge_commit_sha = ?, updated_at = ?
      WHERE id = ?;
      """
    ) { statement in
      try bind(sha, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(runID.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
    return try fetchRepositoryKnowledgeRun(id: runID)
  }

  @discardableResult
  public func finalizeRepositoryKnowledgePublication(
    runID: UUID
  ) throws -> RepositoryKnowledgeRun {
    let run = try fetchRepositoryKnowledgeRun(id: runID)
    guard run.status == .publishing else {
      throw PersistenceError.corruptData("Repository knowledge is not ready to publish")
    }
    let projection = try projectRepositoryKnowledgePublication(runID: runID)
    let drafts = try fetchRepositoryKnowledgeDrafts(runID: runID)
      .filter { $0.status == .approved }
    if !run.knowledgeExportPaths.isEmpty, run.knowledgeCommitSHA == nil {
      throw PersistenceError.corruptData(
        "Repository knowledge cannot become verified before its Git commit is proven"
      )
    }
    let approvedLaunchProposal = try fetchRepositoryLaunchProposal(runID: runID)
      .flatMap { $0.status == .approved ? $0 : nil }
    if approvedLaunchProposal != nil {
      guard
        let repository = try fetchProductRepository(productID: run.productID),
        repository.importedSHA == run.analyzedSHA
      else {
        throw PersistenceError.corruptData(
          "An imported app baseline must remain pinned to the imported revision"
        )
      }
    }
    let now = Date()
    try transaction {
      for draft in drafts {
        guard
          let page = projection.pages.first(where: { $0.id == (draft.targetPageID ?? draft.id) })
        else {
          throw PersistenceError.corruptData("Projected repository knowledge page is missing")
        }
        switch draft.operation {
        case .update:
          try withStatement(
            """
            UPDATE knowledge_pages
            SET title = ?, body_markdown = ?, verification_status = 'verified',
                source_repository_knowledge_run_id = ?, updated_at = ?
            WHERE id = ?;
            """
          ) { statement in
            try bind(page.title, to: 1, in: statement)
            try bind(page.bodyMarkdown, to: 2, in: statement)
            try bind(runID.uuidString, to: 3, in: statement)
            try bind(now.timeIntervalSince1970, to: 4, in: statement)
            try bind(page.id.uuidString, to: 5, in: statement)
            try stepDone(statement)
          }
          try insertKnowledgeRevision(
            pageID: page.id,
            bodyMarkdown: page.bodyMarkdown,
            authorName: "Spedito tech lead",
            changeSummary: draft.rationale,
            createdAt: now
          )
        case .create:
          var publishedPage = page
          publishedPage.updatedAt = now
          try insertKnowledgePage(
            publishedPage,
            authorName: "Spedito tech lead",
            changeSummary: draft.rationale
          )
        }
        try withStatement(
          """
          UPDATE repository_knowledge_drafts
          SET status = 'published', updated_at = ?
          WHERE id = ?;
          """
        ) { statement in
          try bind(now.timeIntervalSince1970, to: 1, in: statement)
          try bind(draft.id.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
      if let approvedLaunchProposal {
        try withStatement(
          """
          UPDATE repository_launch_proposals
          SET status = 'published', updated_at = ?
          WHERE id = ? AND status = 'approved';
          """
        ) { statement in
          try bind(now.timeIntervalSince1970, to: 1, in: statement)
          try bind(approvedLaunchProposal.id.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
      try withStatement(
        """
        UPDATE repository_knowledge_runs
        SET status = 'completed', error_message = NULL, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(runID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: run.productID,
        kind: "repository.knowledge.published",
        actor: "tech_lead",
        detail: "\(drafts.count) verified repository knowledge page(s)"
      )
    }
    return try fetchRepositoryKnowledgeRun(id: runID)
  }

  public func recoverRepositoryKnowledgeRun(
    interruptedRunID: UUID,
    errorMessage: String,
    analyzedSHA: String,
    analyzerProfileID: UUID,
    reviewerProfileID: UUID
  ) throws -> RepositoryKnowledgeRun {
    let interrupted = try fetchRepositoryKnowledgeRun(id: interruptedRunID)
    guard
      interrupted.status == .analyzing || interrupted.status == .reviewing
        || interrupted.status == .interrupted
    else {
      throw PersistenceError.corruptData(
        "Only interrupted repository analysis can create a recovery attempt"
      )
    }
    let runs = try fetchRepositoryKnowledgeRuns(productID: interrupted.productID)
    let recovered = RepositoryKnowledgeRun(
      productID: interrupted.productID,
      attempt: (runs.map(\.attempt).max() ?? 0) + 1,
      purpose: interrupted.purpose,
      analyzedSHA: analyzedSHA,
      analyzerProfileID: analyzerProfileID,
      reviewerProfileID: reviewerProfileID
    )
    let now = Date()
    try transaction {
      try withStatement(
        """
        UPDATE repository_knowledge_runs
        SET status = 'interrupted', error_message = ?, updated_at = ?
        WHERE id = ? AND status IN ('analyzing', 'reviewing', 'interrupted');
        """
      ) { statement in
        try bind(errorMessage, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(interruptedRunID.uuidString, to: 3, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else {
          throw PersistenceError.corruptData(
            "Repository analysis changed before recovery could claim it"
          )
        }
      }
      try withStatement(
        """
        UPDATE repository_knowledge_drafts
        SET status = 'superseded', updated_at = ?
        WHERE run_id IN (
          SELECT id FROM repository_knowledge_runs WHERE product_id = ?
        ) AND status IN ('proposed', 'approved');
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(interrupted.productID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        """
        INSERT INTO repository_knowledge_runs (
            id, product_id, attempt, purpose, analyzed_sha, analyzer_profile_id,
            reviewer_profile_id, analyzer_thread_id, analyzer_turn_id,
            reviewer_thread_id, reviewer_turn_id, status, analysis_summary,
            review_summary, error_message, knowledge_export_paths_json,
            knowledge_commit_sha, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bindRepositoryKnowledgeRun(recovered, to: statement)
        try stepDone(statement)
      }
    }
    return try fetchRepositoryKnowledgeRun(id: recovered.id)
  }

  public func createRepositoryKnowledgeRetry(
    productID: UUID,
    analyzedSHA: String,
    purpose: RepositoryKnowledgeRunPurpose = .knowledge,
    analyzerProfileID: UUID,
    reviewerProfileID: UUID
  ) throws -> RepositoryKnowledgeRun {
    let runs = try fetchRepositoryKnowledgeRuns(productID: productID)
    let run = RepositoryKnowledgeRun(
      productID: productID,
      attempt: (runs.map(\.attempt).max() ?? 0) + 1,
      purpose: purpose,
      analyzedSHA: analyzedSHA,
      analyzerProfileID: analyzerProfileID,
      reviewerProfileID: reviewerProfileID
    )
    try transaction {
      try withStatement(
        """
        UPDATE repository_knowledge_drafts
        SET status = 'superseded', updated_at = ?
        WHERE run_id IN (
          SELECT id FROM repository_knowledge_runs WHERE product_id = ?
        ) AND status IN ('proposed', 'approved');
        """
      ) { statement in
        try bind(Date().timeIntervalSince1970, to: 1, in: statement)
        try bind(productID.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      try withStatement(
        """
        INSERT INTO repository_knowledge_runs (
            id, product_id, attempt, purpose, analyzed_sha, analyzer_profile_id,
            reviewer_profile_id, analyzer_thread_id, analyzer_turn_id,
            reviewer_thread_id, reviewer_turn_id, status, analysis_summary,
            review_summary, error_message, knowledge_export_paths_json,
            knowledge_commit_sha, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bindRepositoryKnowledgeRun(run, to: statement)
        try stepDone(statement)
      }
    }
    return try fetchRepositoryKnowledgeRun(id: run.id)
  }

}
