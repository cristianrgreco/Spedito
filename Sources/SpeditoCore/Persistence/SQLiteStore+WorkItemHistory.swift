import Foundation
import SQLite3

extension SQLiteStore {
  public func fetchWorkItemDependencies(productID: UUID) throws -> [WorkItemDependency] {
    try withStatement(
      """
      SELECT d.work_item_id, d.depends_on_work_item_id
      FROM work_item_dependencies d
      JOIN work_items w ON w.id = d.work_item_id
      WHERE w.product_id = ?
      ORDER BY d.work_item_id, d.depends_on_work_item_id;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var dependencies: [WorkItemDependency] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let workItemID = UUID(uuidString: try text(statement, column: 0)),
          let dependsOnID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid work item dependency")
        }
        dependencies.append(
          WorkItemDependency(workItemID: workItemID, dependsOnWorkItemID: dependsOnID)
        )
      }
      return dependencies
    }
  }

  func fetchSprintExecutionDependencies(sprintID: UUID) throws -> [WorkItemDependency] {
    try withStatement(
      """
      SELECT dependency.work_item_id, dependency.depends_on_work_item_id
      FROM work_item_dependencies AS dependency
      JOIN sprint_items AS item
        ON item.work_item_id = dependency.work_item_id
      WHERE item.sprint_id = ?
      ORDER BY dependency.work_item_id, dependency.depends_on_work_item_id;
      """
    ) { statement in
      try bind(sprintID.uuidString, to: 1, in: statement)
      var dependencies: [WorkItemDependency] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let workItemID = UUID(uuidString: try text(statement, column: 0)),
          let dependsOnID = UUID(uuidString: try text(statement, column: 1))
        else {
          throw PersistenceError.corruptData("Invalid work item dependency")
        }
        dependencies.append(
          WorkItemDependency(workItemID: workItemID, dependsOnWorkItemID: dependsOnID)
        )
      }
      return dependencies
    }
  }

  public func transitionWorkItem(
    id: UUID,
    to newState: WorkItemState,
    actor: String,
    reason: String
  ) throws -> WorkItem {
    var workItem = try fetchWorkItem(id: id)
    try workflowPolicy.validateTransition(from: workItem.state, to: newState)

    let previousState = workItem.state
    workItem.state = newState
    workItem.version += 1
    workItem.updatedAt = Date()

    try transaction {
      try withStatement(
        """
        UPDATE work_items
        SET state = ?, version = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(newState.rawValue, to: 1, in: statement)
        try bind(Int64(workItem.version), to: 2, in: statement)
        try bind(workItem.updatedAt.timeIntervalSince1970, to: 3, in: statement)
        try bind(workItem.id.uuidString, to: 4, in: statement)
        try stepDone(statement)
      }

      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItem.id,
        kind: "work_item.transitioned",
        actor: actor,
        detail: "\(previousState.rawValue) -> \(newState.rawValue): \(reason)"
      )
    }

    return workItem
  }

  public func appendComment(
    workItemID: UUID,
    authorKind: CommentAuthorKind,
    authorName: String,
    body: String,
    ownerQuestion: TicketOwnerQuestion? = nil,
    answeredQuestions: [TicketAnsweredQuestion] = [],
    authorAvatarURL: URL? = nil,
    externalURL: URL? = nil,
    externalID: String? = nil,
    githubReviewContext: GitHubReviewCommentContext? = nil,
    createdAt: Date = Date()
  ) throws -> TicketComment {
    let workItem = try fetchWorkItem(id: workItemID)
    let comment = TicketComment(
      workItemID: workItemID,
      authorKind: authorKind,
      authorName: authorName,
      body: body,
      ownerQuestion: ownerQuestion,
      answeredQuestions: answeredQuestions,
      authorAvatarURL: authorAvatarURL,
      externalURL: externalURL,
      externalID: externalID,
      githubReviewContext: githubReviewContext,
      createdAt: createdAt
    )
    let ownerQuestionJSON = try ownerQuestion.map { question in
      let data = try encoder.encode(question)
      guard let json = String(data: data, encoding: .utf8) else {
        throw PersistenceError.corruptData("Could not encode the product owner question")
      }
      return json
    }
    let answeredQuestionsJSON: String?
    if answeredQuestions.isEmpty {
      answeredQuestionsJSON = nil
    } else {
      let data = try encoder.encode(answeredQuestions)
      guard let json = String(data: data, encoding: .utf8) else {
        throw PersistenceError.corruptData("Could not encode answered questions")
      }
      answeredQuestionsJSON = json
    }
    let githubReviewContextJSON = try githubReviewContext.map { context in
      let data = try encoder.encode(context)
      guard let json = String(data: data, encoding: .utf8) else {
        throw PersistenceError.corruptData("Could not encode the GitHub review context")
      }
      return json
    }

    try transaction {
      try withStatement(
        """
        INSERT INTO ticket_comments (
            id, work_item_id, author_kind, author_name, body, owner_question_json,
            answered_questions_json, author_avatar_url, external_url, external_id,
            github_review_context_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
      ) { statement in
        try bind(comment.id.uuidString, to: 1, in: statement)
        try bind(comment.workItemID.uuidString, to: 2, in: statement)
        try bind(comment.authorKind.rawValue, to: 3, in: statement)
        try bind(comment.authorName, to: 4, in: statement)
        try bind(comment.body, to: 5, in: statement)
        try bindOptionalString(ownerQuestionJSON, to: 6, in: statement)
        try bindOptionalString(answeredQuestionsJSON, to: 7, in: statement)
        try bindOptionalString(comment.authorAvatarURL?.absoluteString, to: 8, in: statement)
        try bindOptionalString(comment.externalURL?.absoluteString, to: 9, in: statement)
        try bindOptionalString(comment.externalID, to: 10, in: statement)
        try bindOptionalString(githubReviewContextJSON, to: 11, in: statement)
        try bind(comment.createdAt.timeIntervalSince1970, to: 12, in: statement)
        try stepDone(statement)
      }

      _ = try insertEvent(
        productID: workItem.productID,
        workItemID: workItemID,
        kind: "comment.created",
        actor: authorName,
        detail: comment.body
      )
    }

    return comment
  }

  public func fetchComments(workItemID: UUID) throws -> [TicketComment] {
    try fetchComments(workItemIDs: [workItemID])[workItemID, default: []]
  }

  public func fetchComments(
    workItemIDs: Set<UUID>
  ) throws -> [UUID: [TicketComment]] {
    guard !workItemIDs.isEmpty else { return [:] }
    let orderedIDs = workItemIDs.sorted {
      $0.uuidString < $1.uuidString
    }
    let placeholders = Array(repeating: "?", count: orderedIDs.count).joined(separator: ", ")
    return try withStatement(
      """
      SELECT id, work_item_id, author_kind, author_name, body, owner_question_json,
             answered_questions_json, author_avatar_url, external_url, external_id,
             github_review_context_json, created_at
      FROM ticket_comments
      WHERE work_item_id IN (\(placeholders))
      ORDER BY work_item_id ASC, created_at ASC;
      """
    ) { statement in
      for (offset, workItemID) in orderedIDs.enumerated() {
        try bind(workItemID.uuidString, to: Int32(offset + 1), in: statement)
      }
      var commentsByWorkItemID: [UUID: [TicketComment]] = [:]
      while sqlite3_step(statement) == SQLITE_ROW {
        let comment = try decodeTicketComment(statement)
        commentsByWorkItemID[comment.workItemID, default: []].append(comment)
      }
      return commentsByWorkItemID
    }
  }

  func decodeTicketComment(_ statement: OpaquePointer) throws -> TicketComment {
    guard
      let id = UUID(uuidString: try text(statement, column: 0)),
      let itemID = UUID(uuidString: try text(statement, column: 1)),
      let authorKind = CommentAuthorKind(rawValue: try text(statement, column: 2))
    else {
      throw PersistenceError.corruptData("Invalid ticket comment")
    }
    return TicketComment(
      id: id,
      workItemID: itemID,
      authorKind: authorKind,
      authorName: try text(statement, column: 3),
      body: try text(statement, column: 4),
      ownerQuestion: try optionalText(statement, column: 5).map { json in
        guard let data = json.data(using: .utf8) else {
          throw PersistenceError.corruptData("Invalid product owner question text")
        }
        return try decoder.decode(TicketOwnerQuestion.self, from: data)
      },
      answeredQuestions: try optionalText(statement, column: 6).map { json in
        guard let data = json.data(using: .utf8) else {
          throw PersistenceError.corruptData("Invalid answered question text")
        }
        return try decoder.decode([TicketAnsweredQuestion].self, from: data)
      } ?? [],
      authorAvatarURL: try optionalText(statement, column: 7).flatMap(URL.init(string:)),
      externalURL: try optionalText(statement, column: 8).flatMap(URL.init(string:)),
      externalID: try optionalText(statement, column: 9),
      githubReviewContext: try optionalText(statement, column: 10).map { json in
        guard let data = json.data(using: .utf8) else {
          throw PersistenceError.corruptData("Invalid GitHub review context text")
        }
        return try decoder.decode(GitHubReviewCommentContext.self, from: data)
      },
      createdAt: date(statement, column: 11)
    )
  }

  public func appendExternalCommentIfNeeded(
    workItemID: UUID,
    authorName: String,
    body: String,
    authorAvatarURL: URL?,
    externalURL: URL,
    externalID: String,
    createdAt: Date,
    githubReviewContext: GitHubReviewCommentContext? = nil
  ) throws -> TicketComment? {
    guard !externalID.isEmpty, externalID.unicodeScalars.count <= 256,
      externalURL.scheme == "https", externalURL.host?.lowercased() == "github.com"
    else {
      throw PersistenceError.corruptData("The external work log reference is invalid.")
    }
    if let authorAvatarURL {
      guard authorAvatarURL.scheme == "https",
        authorAvatarURL.host?.lowercased() == "avatars.githubusercontent.com"
      else {
        throw PersistenceError.corruptData("The external reviewer avatar URL is invalid.")
      }
    }
    let exists = try withStatement(
      "SELECT 1 FROM ticket_comments WHERE external_id = ? LIMIT 1;"
    ) { statement in
      try bind(externalID, to: 1, in: statement)
      return sqlite3_step(statement) == SQLITE_ROW
    }
    guard !exists else { return nil }
    return try appendComment(
      workItemID: workItemID,
      authorKind: .external,
      authorName: authorName,
      body: body,
      authorAvatarURL: authorAvatarURL,
      externalURL: externalURL,
      externalID: externalID,
      githubReviewContext: githubReviewContext,
      createdAt: createdAt
    )
  }

}
