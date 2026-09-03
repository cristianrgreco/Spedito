import Foundation
import SQLite3

extension SQLiteStore {
  @discardableResult
  public func seedKnowledgeBase(productID: UUID) throws -> [KnowledgePage] {
    try ensureKnowledgeMutationAllowed(productID: productID)
    let existing = try fetchKnowledgePages(productID: productID)
    if !existing.isEmpty {
      var pages = existing
      try transaction {
        let operations: KnowledgePage
        if let existingOperations = pages.first(where: { $0.slug == "operations" }) {
          operations = existingOperations
        } else {
          let page = KnowledgePage(
            productID: productID,
            title: "Operations",
            slug: "operations",
            kind: .section,
            sortOrder: (pages.filter { $0.parentID == nil }.map(\.sortOrder).max() ?? -1) + 1
          )
          try insertKnowledgePage(
            page,
            authorName: "Spedito",
            changeSummary: "Backfilled canonical Operations section"
          )
          pages.append(page)
          operations = page
        }

        let missingChildren: [(title: String, slug: String, body: String, summary: String)] = [
          (
            "Environments",
            "environments",
            "",
            "Backfilled mandatory Environments page"
          ),
          (
            "Ways of working",
            "ways-of-working",
            """
            Shared delivery practices adopted by the product owner live here. Every team member receives this page as part of their working context.

            ## Adopted practices
            """,
            "Created inherited team-practices page"
          ),
        ]
        for child in missingChildren where !pages.contains(where: { $0.slug == child.slug }) {
          let page = KnowledgePage(
            productID: productID,
            parentID: operations.id,
            title: child.title,
            slug: child.slug,
            bodyMarkdown: child.body,
            sortOrder: (pages.filter { $0.parentID == operations.id }.map(\.sortOrder).max() ?? -1)
              + 1
          )
          try insertKnowledgePage(
            page,
            authorName: "Spedito",
            changeSummary: child.summary
          )
          pages.append(page)
        }
      }
      return try fetchKnowledgePages(productID: productID)
    }

    let now = Date()
    let rootDefinitions: [(String, String, KnowledgePageKind)] = [
      ("Home", "home", .page),
      ("Product", "product", .section),
      ("Features", "features", .section),
      ("Technical", "technical", .section),
      ("Operations", "operations", .section),
      ("Decisions", "decisions", .section),
      ("Known limitations", "known-limitations", .page),
      ("Delivery history", "delivery-history", .section),
    ]
    var roots: [String: KnowledgePage] = [:]

    try transaction {
      for (index, definition) in rootDefinitions.enumerated() {
        let body =
          definition.1 == "home"
          ? "Verified product and delivery knowledge lives here."
          : ""
        let page = KnowledgePage(
          productID: productID,
          title: definition.0,
          slug: definition.1,
          bodyMarkdown: body,
          kind: definition.2,
          sortOrder: index,
          createdAt: now,
          updatedAt: now
        )
        try insertKnowledgePage(page, authorName: "Spedito", changeSummary: "Created page")
        roots[definition.1] = page
      }

      let children: [(String, String, String)] = [
        ("product", "Overview", "overview"),
        ("product", "Users & journeys", "users-and-journeys"),
        ("product", "Product principles", "product-principles"),
        ("product", "Glossary", "glossary"),
        ("technical", "Architecture", "architecture"),
        ("technical", "Components & data", "components-and-data"),
        ("technical", "Integrations", "integrations"),
        ("operations", "Environments", "environments"),
        ("operations", "Runbooks", "runbooks"),
        ("operations", "Release & rollback", "release-and-rollback"),
        ("operations", "Ways of working", "ways-of-working"),
      ]
      var childOrder: [String: Int] = [:]
      for child in children {
        guard let parent = roots[child.0] else { continue }
        let order = childOrder[child.0, default: 0]
        childOrder[child.0] = order + 1
        let page = KnowledgePage(
          productID: productID,
          parentID: parent.id,
          title: child.1,
          slug: child.2,
          bodyMarkdown: child.2 == "ways-of-working"
            ? """
            Shared delivery practices adopted by the product owner live here. Every team member receives this page as part of their working context.

            ## Adopted practices
            """
            : "",
          sortOrder: order,
          createdAt: now,
          updatedAt: now
        )
        try insertKnowledgePage(page, authorName: "Spedito", changeSummary: "Created page")
      }
    }
    return try fetchKnowledgePages(productID: productID)
  }

  public func fetchKnowledgePages(productID: UUID) throws -> [KnowledgePage] {
    try withStatement(
      """
      SELECT id, product_id, parent_id, title, slug, body_markdown, kind,
             verification_status, sort_order, source_work_item_id,
             source_repository_knowledge_run_id, created_at, updated_at
      FROM knowledge_pages
      WHERE product_id = ?
      ORDER BY sort_order ASC, title COLLATE NOCASE ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var pages: [KnowledgePage] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        pages.append(try decodeKnowledgePage(statement))
      }
      return pages
    }
  }

  public func setAgentRunKnowledgeContext(runID: UUID, pageIDs: [UUID]) throws {
    try transaction {
      try withStatement(
        "DELETE FROM agent_run_knowledge_pages WHERE run_id = ?;"
      ) { statement in
        try bind(runID.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      for pageID in Set(pageIDs) {
        try withStatement(
          """
          INSERT INTO agent_run_knowledge_pages (run_id, page_id) VALUES (?, ?);
          """
        ) { statement in
          try bind(runID.uuidString, to: 1, in: statement)
          try bind(pageID.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
    }
  }

  public func fetchAgentRunKnowledgeContext(
    productID: UUID
  ) throws -> [AgentRunKnowledgePage] {
    try withStatement(
      """
      SELECT context.run_id, context.page_id
      FROM agent_run_knowledge_pages AS context
      JOIN agent_runs AS run ON run.id = context.run_id
      WHERE run.product_id = ?
      ORDER BY run.created_at ASC, context.page_id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var links: [AgentRunKnowledgePage] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let runID = UUID(uuidString: try text(statement, column: 0)),
          let pageID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid agent knowledge context")
        }
        links.append(AgentRunKnowledgePage(runID: runID, pageID: pageID))
      }
      return links
    }
  }

  public func setAgentRunKnowledgeDestinations(runID: UUID, pageIDs: [UUID]) throws {
    try transaction {
      try withStatement(
        "DELETE FROM agent_run_knowledge_destinations WHERE run_id = ?;"
      ) { statement in
        try bind(runID.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      for pageID in Set(pageIDs) {
        try withStatement(
          """
          INSERT INTO agent_run_knowledge_destinations (run_id, page_id) VALUES (?, ?);
          """
        ) { statement in
          try bind(runID.uuidString, to: 1, in: statement)
          try bind(pageID.uuidString, to: 2, in: statement)
          try stepDone(statement)
        }
      }
    }
  }

  public func fetchAgentRunKnowledgeDestinations(
    productID: UUID
  ) throws -> [AgentRunKnowledgeDestination] {
    try withStatement(
      """
      SELECT destination.run_id, destination.page_id
      FROM agent_run_knowledge_destinations AS destination
      JOIN agent_runs AS run ON run.id = destination.run_id
      WHERE run.product_id = ?
      ORDER BY run.created_at ASC, destination.page_id ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var links: [AgentRunKnowledgeDestination] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let runID = UUID(uuidString: try text(statement, column: 0)),
          let pageID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid agent knowledge destination")
        }
        links.append(AgentRunKnowledgeDestination(runID: runID, pageID: pageID))
      }
      return links
    }
  }

  public func fetchKnowledgePageRevisions(pageID: UUID) throws -> [KnowledgePageRevision] {
    try withStatement(
      """
      SELECT id, page_id, version, body_markdown, author_name, change_summary, created_at
      FROM knowledge_page_revisions
      WHERE page_id = ?
      ORDER BY version DESC;
      """
    ) { statement in
      try bind(pageID.uuidString, to: 1, in: statement)
      var revisions: [KnowledgePageRevision] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let storedPageID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid knowledge page revision")
        }
        revisions.append(
          KnowledgePageRevision(
            id: id,
            pageID: storedPageID,
            version: Int(sqlite3_column_int64(statement, 2)),
            bodyMarkdown: try text(statement, column: 3),
            authorName: try text(statement, column: 4),
            changeSummary: try text(statement, column: 5),
            createdAt: date(statement, column: 6)
          )
        )
      }
      return revisions
    }
  }

  public func createKnowledgePage(
    productID: UUID,
    parentID: UUID?,
    title: String
  ) throws -> KnowledgePage {
    try ensureKnowledgeMutationAllowed(productID: productID)
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw PersistenceError.corruptData("A knowledge page needs a title")
    }
    if let parentID {
      let parent = try fetchKnowledgePage(id: parentID)
      guard parent.productID == productID else {
        throw PersistenceError.corruptData(
          "A product knowledge page and its parent must belong to the same product"
        )
      }
    }
    let baseSlug =
      trimmedTitle
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .joined(separator: "-")
    let siblingSlugs = try fetchKnowledgePages(productID: productID)
      .filter { $0.parentID == parentID }
      .map(\.slug)
    var slug = baseSlug.isEmpty ? "page" : baseSlug
    var suffix = 2
    while siblingSlugs.contains(slug) {
      slug = "\(baseSlug)-\(suffix)"
      suffix += 1
    }
    let sortOrder = try withStatement(
      """
      SELECT COALESCE(MAX(sort_order), -1) + 1
      FROM knowledge_pages
      WHERE product_id = ?
        AND ((parent_id IS NULL AND ? IS NULL) OR parent_id = ?);
      """
    ) { statement -> Int in
      try bind(productID.uuidString, to: 1, in: statement)
      try bindOptionalUUID(parentID, to: 2, in: statement)
      try bindOptionalUUID(parentID, to: 3, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw currentSQLiteError() }
      return Int(sqlite3_column_int64(statement, 0))
    }
    let page = KnowledgePage(
      productID: productID,
      parentID: parentID,
      title: trimmedTitle,
      slug: slug,
      bodyMarkdown: "",
      sortOrder: sortOrder
    )
    try insertKnowledgePage(page, authorName: "Me", changeSummary: "Created page")
    return page
  }

  public func updateKnowledgePage(
    id: UUID,
    title: String,
    bodyMarkdown: String,
    authorName: String,
    changeSummary: String
  ) throws -> KnowledgePage {
    var page = try fetchKnowledgePage(id: id)
    try ensureKnowledgeMutationAllowed(productID: page.productID)
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw PersistenceError.corruptData("A knowledge page needs a title")
    }
    let now = Date()
    page.title = trimmedTitle
    page.bodyMarkdown = KnowledgeMarkdown.normalizedBody(bodyMarkdown)
    page.verificationStatus = .verified
    page.updatedAt = now
    try transaction {
      try withStatement(
        """
        UPDATE knowledge_pages
        SET title = ?, body_markdown = ?, verification_status = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(page.title, to: 1, in: statement)
        try bind(page.bodyMarkdown, to: 2, in: statement)
        try bind(page.verificationStatus.rawValue, to: 3, in: statement)
        try bind(now.timeIntervalSince1970, to: 4, in: statement)
        try bind(id.uuidString, to: 5, in: statement)
        try stepDone(statement)
      }
      try insertKnowledgeRevision(
        pageID: id,
        bodyMarkdown: page.bodyMarkdown,
        authorName: authorName,
        changeSummary: changeSummary,
        createdAt: now
      )
    }
    return page
  }

  /// Publishes or updates the canonical demo recipe page for the accepted
  /// candidate's presentation kind — one verified page per kind the product
  /// has shipped, under the Operations section next to Environments. The
  /// operation is idempotent: re-acceptance with the same recipe body leaves
  /// the page and its revision history untouched, so a preserved interruption
  /// cannot duplicate it.
  @discardableResult
  public func upsertCanonicalDemoRecipePage(
    productID: UUID,
    specification: DemoLaunchSpecification
  ) throws -> KnowledgePage {
    let kind = specification.presentation.kind
    let slug = CanonicalDemoRecipeKnowledge.slug(for: kind)
    let title = CanonicalDemoRecipeKnowledge.title(for: kind)
    let body = KnowledgeMarkdown.normalizedBody(
      try CanonicalDemoRecipeKnowledge.bodyMarkdown(for: specification)
    )
    _ = try seedKnowledgeBase(productID: productID)
    let pages = try fetchKnowledgePages(productID: productID)
    if let existing = pages.first(where: { $0.slug == slug && $0.kind == .page }) {
      guard existing.bodyMarkdown != body || existing.verificationStatus != .verified
      else {
        return existing
      }
      return try updateKnowledgePage(
        id: existing.id,
        title: existing.title,
        bodyMarkdown: body,
        authorName: "Spedito",
        changeSummary: "Updated the canonical demo recipe from the accepted candidate"
      )
    }
    guard
      let operations = pages.first(where: { $0.parentID == nil && $0.slug == "operations" })
    else {
      throw PersistenceError.corruptData("The canonical Operations section is missing")
    }
    let page = KnowledgePage(
      productID: productID,
      parentID: operations.id,
      title: title,
      slug: slug,
      bodyMarkdown: body,
      sortOrder: (pages.filter { $0.parentID == operations.id }.map(\.sortOrder).max() ?? -1)
        + 1
    )
    try insertKnowledgePage(
      page,
      authorName: "Spedito",
      changeSummary: "Published the canonical demo recipe from the accepted candidate"
    )
    return page
  }

  public func upsertDeliveryNote(
    productID: UUID,
    sprint: Sprint,
    item: WorkItem,
    bodyMarkdown: String,
    authorName: String
  ) throws -> KnowledgePage {
    _ = try seedKnowledgeBase(productID: productID)
    let pages = try fetchKnowledgePages(productID: productID)
    guard let history = pages.first(where: { $0.parentID == nil && $0.slug == "delivery-history" })
    else {
      throw PersistenceError.corruptData("Delivery history is missing")
    }

    var sprintPage = pages.first {
      $0.parentID == history.id && $0.slug == "sprint-\(sprint.number)"
    }
    if sprintPage == nil {
      let created = KnowledgePage(
        productID: productID,
        parentID: history.id,
        title: "Sprint \(sprint.number)",
        slug: "sprint-\(sprint.number)",
        kind: .section,
        sortOrder: sprint.number
      )
      try insertKnowledgePage(
        created,
        authorName: "Spedito",
        changeSummary: "Created sprint delivery section"
      )
      sprintPage = created
    }
    guard let sprintPage else {
      throw PersistenceError.corruptData("Could not create sprint delivery section")
    }

    if let existing = try fetchKnowledgePages(productID: productID).first(where: {
      $0.sourceWorkItemID == item.id && $0.kind == .deliveryNote
    }) {
      var updated = existing
      updated.bodyMarkdown = KnowledgeMarkdown.normalizedBody(bodyMarkdown)
      updated.verificationStatus = .proposed
      updated.updatedAt = Date()
      try transaction {
        try withStatement(
          """
          UPDATE knowledge_pages
          SET body_markdown = ?, verification_status = ?, updated_at = ?
          WHERE id = ?;
          """
        ) { statement in
          try bind(updated.bodyMarkdown, to: 1, in: statement)
          try bind(updated.verificationStatus.rawValue, to: 2, in: statement)
          try bind(updated.updatedAt.timeIntervalSince1970, to: 3, in: statement)
          try bind(updated.id.uuidString, to: 4, in: statement)
          try stepDone(statement)
        }
        try insertKnowledgeRevision(
          pageID: updated.id,
          bodyMarkdown: updated.bodyMarkdown,
          authorName: authorName,
          changeSummary: "Updated delivery note"
        )
      }
      return updated
    }

    let page = KnowledgePage(
      productID: productID,
      parentID: sprintPage.id,
      title: "\(item.key) · \(item.title)",
      slug: item.key.lowercased(),
      bodyMarkdown: KnowledgeMarkdown.normalizedBody(bodyMarkdown),
      kind: .deliveryNote,
      verificationStatus: .proposed,
      sortOrder: item.rank,
      sourceWorkItemID: item.id
    )
    try insertKnowledgePage(page, authorName: authorName, changeSummary: "Proposed delivery note")
    return page
  }

  public func verifyDeliveryNote(workItemID: UUID, authorName: String) throws {
    guard
      let page = try withStatement(
        """
        SELECT id, product_id, parent_id, title, slug, body_markdown, kind,
               verification_status, sort_order, source_work_item_id,
               source_repository_knowledge_run_id, created_at, updated_at
        FROM knowledge_pages
        WHERE source_work_item_id = ? AND kind = 'delivery_note'
        LIMIT 1;
        """,
        operation: { statement -> KnowledgePage? in
          try bind(workItemID.uuidString, to: 1, in: statement)
          guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
          return try decodeKnowledgePage(statement)
        })
    else { return }
    try ensureKnowledgeMutationAllowed(productID: page.productID)

    let now = Date()
    try transaction {
      try withStatement(
        """
        UPDATE knowledge_pages SET verification_status = 'verified', updated_at = ? WHERE id = ?;
        """
      ) { statement in
        try bind(now.timeIntervalSince1970, to: 1, in: statement)
        try bind(page.id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      try insertKnowledgeRevision(
        pageID: page.id,
        bodyMarkdown: page.bodyMarkdown,
        authorName: authorName,
        changeSummary: "Verified during tech lead review",
        createdAt: now
      )
    }
  }

}
