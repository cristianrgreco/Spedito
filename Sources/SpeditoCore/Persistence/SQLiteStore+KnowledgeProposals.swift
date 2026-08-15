import Foundation
import SQLite3

extension SQLiteStore {
  public func createKnowledgePageProposals(
    _ proposals: [KnowledgePageProposal]
  ) throws {
    try transaction {
      for proposal in proposals {
        try withStatement(
          """
          INSERT INTO knowledge_page_proposals (
              id, product_id, sprint_id, work_item_id, candidate_revision_id,
              operation, target_page_id, parent_page_id, base_page_title,
              base_page_body_markdown, base_page_updated_at, title,
              proposed_body_markdown, rationale, status, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          """
        ) { statement in
          try bind(proposal.id.uuidString, to: 1, in: statement)
          try bind(proposal.productID.uuidString, to: 2, in: statement)
          try bind(proposal.sprintID.uuidString, to: 3, in: statement)
          try bind(proposal.workItemID.uuidString, to: 4, in: statement)
          try bind(proposal.candidateRevisionID.uuidString, to: 5, in: statement)
          try bind(proposal.operation.rawValue, to: 6, in: statement)
          try bindOptionalUUID(proposal.targetPageID, to: 7, in: statement)
          try bindOptionalUUID(proposal.parentPageID, to: 8, in: statement)
          try bindOptionalString(proposal.basePageTitle, to: 9, in: statement)
          try bindOptionalString(proposal.basePageBodyMarkdown, to: 10, in: statement)
          try bindOptionalDate(proposal.basePageUpdatedAt, to: 11, in: statement)
          try bind(proposal.title, to: 12, in: statement)
          try bind(
            KnowledgeMarkdown.normalizedBody(proposal.proposedBodyMarkdown),
            to: 13,
            in: statement
          )
          try bind(proposal.rationale, to: 14, in: statement)
          try bind(proposal.status.rawValue, to: 15, in: statement)
          try bind(proposal.createdAt.timeIntervalSince1970, to: 16, in: statement)
          try bind(proposal.updatedAt.timeIntervalSince1970, to: 17, in: statement)
          try stepDone(statement)
        }
      }
    }
  }

  public func fetchKnowledgePageProposals(
    productID: UUID
  ) throws -> [KnowledgePageProposal] {
    try withStatement(
      """
      SELECT id, product_id, sprint_id, work_item_id, candidate_revision_id,
             operation, target_page_id, parent_page_id, base_page_title,
             base_page_body_markdown, base_page_updated_at, title,
             proposed_body_markdown, rationale, status, created_at, updated_at
      FROM knowledge_page_proposals
      WHERE product_id = ?
      ORDER BY created_at ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var proposals: [KnowledgePageProposal] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        proposals.append(try decodeKnowledgePageProposal(statement))
      }
      return proposals
    }
  }

  public func markKnowledgePageProposals(
    candidateRevisionID: UUID,
    status: KnowledgePageProposalStatus
  ) throws {
    try withStatement(
      """
      UPDATE knowledge_page_proposals
      SET status = ?, updated_at = ?
      WHERE candidate_revision_id = ?
        AND status IN ('proposed', 'reviewed');
      """
    ) { statement in
      try bind(status.rawValue, to: 1, in: statement)
      try bind(Date().timeIntervalSince1970, to: 2, in: statement)
      try bind(candidateRevisionID.uuidString, to: 3, in: statement)
      try stepDone(statement)
    }
  }

  public func decideKnowledgePageProposal(
    id: UUID,
    accept: Bool,
    authorName: String
  ) throws -> KnowledgePageProposal {
    if accept {
      return try publishKnowledgePageProposal(
        id: id,
        authorName: authorName
      )
    }
    return try recordKnowledgePageProposalDecision(
      id: id,
      accept: false,
      authorName: authorName
    )
  }

  public func recordKnowledgePageProposalDecision(
    id: UUID,
    accept: Bool,
    authorName: String
  ) throws -> KnowledgePageProposal {
    var proposal = try fetchKnowledgePageProposal(id: id)
    guard proposal.status == .reviewed || proposal.status == .proposed else {
      return proposal
    }
    let now = Date()
    try transaction {
      proposal.status = accept ? .accepted : .rejected
      proposal.updatedAt = now
      try withStatement(
        """
        UPDATE knowledge_page_proposals
        SET status = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(proposal.status.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: proposal.productID,
        workItemID: proposal.workItemID,
        kind: accept ? "knowledge.proposal.accepted" : "knowledge.proposal.rejected",
        actor: authorName,
        detail: proposal.title
      )
    }
    return try fetchKnowledgePageProposal(id: id)
  }

  public func publishKnowledgePageProposal(
    id: UUID,
    authorName: String
  ) throws -> KnowledgePageProposal {
    var proposal = try fetchKnowledgePageProposal(id: id)
    guard proposal.status == .reviewed || proposal.status == .accepted else {
      return proposal
    }
    try ensureKnowledgeMutationAllowed(productID: proposal.productID)
    let wasAlreadyAccepted = proposal.status == .accepted
    let now = Date()
    try transaction {
      try applyKnowledgePageProposal(
        proposal,
        authorName: authorName,
        at: now
      )
      proposal.status = .accepted
      proposal.updatedAt = now
      try withStatement(
        """
        UPDATE knowledge_page_proposals
        SET status = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(proposal.status.rawValue, to: 1, in: statement)
        try bind(now.timeIntervalSince1970, to: 2, in: statement)
        try bind(id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      if !wasAlreadyAccepted {
        _ = try insertEvent(
          productID: proposal.productID,
          workItemID: proposal.workItemID,
          kind: "knowledge.proposal.accepted",
          actor: authorName,
          detail: proposal.title
        )
      }
    }
    return try fetchKnowledgePageProposal(id: id)
  }

  func applyKnowledgePageProposal(
    _ proposal: KnowledgePageProposal,
    authorName: String,
    at now: Date
  ) throws {
    switch proposal.operation {
    case .update:
      guard let targetPageID = proposal.targetPageID else {
        throw PersistenceError.corruptData("Knowledge update has no target page")
      }
      let target = try fetchKnowledgePage(id: targetPageID)
      guard target.productID == proposal.productID else {
        throw PersistenceError.corruptData("Knowledge update targets another product")
      }
      let normalizedBody = KnowledgeMarkdown.normalizedBody(
        proposal.proposedBodyMarkdown
      )
      if target.title == proposal.title,
        target.bodyMarkdown == normalizedBody,
        target.verificationStatus == .verified
      {
        if target.sourceWorkItemID != proposal.workItemID {
          try withStatement(
            """
            UPDATE knowledge_pages
            SET source_work_item_id = ?
            WHERE id = ?;
            """
          ) { statement in
            try bind(proposal.workItemID.uuidString, to: 1, in: statement)
            try bind(targetPageID.uuidString, to: 2, in: statement)
            try stepDone(statement)
          }
        }
        return
      }
      guard
        let baseTitle = proposal.basePageTitle,
        let baseBody = proposal.basePageBodyMarkdown,
        let baseUpdatedAt = proposal.basePageUpdatedAt,
        target.title == baseTitle,
        target.bodyMarkdown == baseBody,
        abs(target.updatedAt.timeIntervalSince(baseUpdatedAt)) < 0.001
      else {
        throw PersistenceError.corruptData(
          "The canonical page changed after this proposal was prepared. Review a fresh proposal instead of overwriting the newer page."
        )
      }
      try withStatement(
        """
        UPDATE knowledge_pages
        SET title = ?, body_markdown = ?, verification_status = 'verified',
            source_work_item_id = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(proposal.title, to: 1, in: statement)
        try bind(normalizedBody, to: 2, in: statement)
        try bind(proposal.workItemID.uuidString, to: 3, in: statement)
        try bind(now.timeIntervalSince1970, to: 4, in: statement)
        try bind(targetPageID.uuidString, to: 5, in: statement)
        try stepDone(statement)
      }
      try insertKnowledgeRevision(
        pageID: targetPageID,
        bodyMarkdown: normalizedBody,
        authorName: authorName,
        changeSummary: proposal.rationale,
        createdAt: now
      )

    case .create:
      guard let parentPageID = proposal.parentPageID else {
        throw PersistenceError.corruptData("Knowledge creation has no parent page")
      }
      let parent = try fetchKnowledgePage(id: parentPageID)
      guard parent.productID == proposal.productID else {
        throw PersistenceError.corruptData("Knowledge creation targets another product")
      }
      let normalizedBody = KnowledgeMarkdown.normalizedBody(
        proposal.proposedBodyMarkdown
      )
      let siblingPages = try fetchKnowledgePages(productID: proposal.productID)
        .filter { $0.parentID == parentPageID }
      if siblingPages.contains(where: {
        $0.title == proposal.title
          && $0.bodyMarkdown == normalizedBody
          && $0.sourceWorkItemID == proposal.workItemID
      }) {
        return
      }
      let baseSlug = KnowledgePageProposalMaterializer.slug(for: proposal.title)
      var slug = baseSlug
      var suffix = 2
      while siblingPages.contains(where: { $0.slug == slug }) {
        slug = "\(baseSlug)-\(suffix)"
        suffix += 1
      }
      let page = KnowledgePage(
        productID: proposal.productID,
        parentID: parentPageID,
        title: proposal.title,
        slug: slug,
        bodyMarkdown: normalizedBody,
        verificationStatus: .verified,
        sortOrder: (siblingPages.map(\.sortOrder).max() ?? -1) + 1,
        sourceWorkItemID: proposal.workItemID,
        createdAt: now,
        updatedAt: now
      )
      try insertKnowledgePage(
        page,
        authorName: authorName,
        changeSummary: proposal.rationale
      )
    }
  }

}
