import Foundation
import SQLite3

extension SQLiteStore {
  public func seedDefaultProfiles(productID: UUID) throws -> [AgentProfile] {
    let existing = try fetchAgentProfiles(productID: productID)
    let defaultRoles: [(String, AgentRole)] = [
      ("Business analyst", .businessAnalyst),
      ("UX designer", .uxDesigner),
      ("Tech lead", .lead),
      ("Implementer", .implementer),
    ]
    let desired = defaultRoles.map { name, role in
      let defaults = AgentPersonaDefaults.configuration(for: role)
      return AgentProfile(
        productID: productID,
        name: name,
        role: role,
        model: defaults.model,
        reasoningEffort: defaults.effort
      )
    }
    let existingRoles = Set(existing.map(\.role))
    let missing = desired.filter { !existingRoles.contains($0.role) }
    guard !missing.isEmpty else { return existing }

    try transaction {
      for profile in missing {
        try insertAgentProfile(profile)
      }
      _ = try insertEvent(
        productID: productID,
        kind: "team.profiles_seeded",
        actor: "system",
        detail: missing.map(\.name).joined(separator: ", ")
      )
    }

    return try fetchAgentProfiles(productID: productID)
  }

  public func fetchAgentProfiles(productID: UUID) throws -> [AgentProfile] {
    try withStatement(
      """
      SELECT id, product_id, name, role, model, reasoning_effort,
             custom_instructions, is_builtin, created_at, updated_at
      FROM agent_profiles
      WHERE product_id = ? AND is_active = 1
      ORDER BY
        CASE WHEN is_builtin = 1 THEN
          CASE role
            WHEN 'business_analyst' THEN 0
            WHEN 'ux_designer' THEN 1
            WHEN 'lead' THEN 2
            WHEN 'implementer' THEN 3
            WHEN 'frontend_engineer' THEN 4
            WHEN 'backend_engineer' THEN 5
            WHEN 'reviewer' THEN 6
            WHEN 'quality_assurance' THEN 7
            WHEN 'knowledge_curator' THEN 8
            ELSE 9
          END
        ELSE 100 END,
        created_at ASC,
        name ASC;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      var profiles: [AgentProfile] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard
          let id = UUID(uuidString: try text(statement, column: 0)),
          let storedProductID = UUID(uuidString: try text(statement, column: 1)),
          let role = AgentRole(rawValue: try text(statement, column: 3))
        else {
          throw PersistenceError.corruptData("Invalid agent profile")
        }
        profiles.append(
          AgentProfile(
            id: id,
            productID: storedProductID,
            name: try text(statement, column: 2),
            role: role,
            model: try text(statement, column: 4),
            reasoningEffort: try text(statement, column: 5),
            customInstructions: try optionalText(statement, column: 6),
            isBuiltIn: sqlite3_column_int64(statement, 7) != 0,
            createdAt: date(statement, column: 8),
            updatedAt: date(statement, column: 9)
          )
        )
      }
      return profiles
    }
  }

  public func updateTeamSettings(
    productID: UUID,
    productInstructions: String,
    profiles updates: [TeamProfileSettingsUpdate]
  ) throws -> TeamSettingsSnapshot {
    let product = try fetchProduct(id: productID)
    guard product.status == .active else {
      throw PersistenceError.corruptData(
        "Restore this product before changing its team settings"
      )
    }
    let currentProfiles = try fetchAgentProfiles(productID: productID)
    let updateIDs = updates.map(\.profileID)
    let expectedIDs = Set(currentProfiles.map(\.id))
    guard updateIDs.count == Set(updateIDs).count, Set(updateIDs) == expectedIDs else {
      throw PersistenceError.corruptData(
        "The product team changed while these settings were open. Review the current team and try again."
      )
    }

    let normalizedUpdates = try Dictionary(
      uniqueKeysWithValues: updates.map { update in
        guard
          !update.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !update.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw PersistenceError.corruptData("Model and reasoning effort cannot be empty")
        }
        let trimmedInstructions =
          update.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedInstructions = trimmedInstructions?.isEmpty == false ? trimmedInstructions : nil
        return (
          update.profileID,
          TeamProfileSettingsUpdate(
            profileID: update.profileID,
            model: update.model,
            reasoningEffort: update.reasoningEffort,
            customInstructions: storedInstructions
          )
        )
      }
    )
    let instructions = productInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let updatedAt = Date()
    try transaction {
      try withStatement(
        "UPDATE products SET instructions = ?, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(instructions, to: 1, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 2, in: statement)
        try bind(productID.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
      for profile in currentProfiles {
        guard let update = normalizedUpdates[profile.id] else {
          throw PersistenceError.corruptData("Team settings are incomplete")
        }
        try withStatement(
          """
          UPDATE agent_profiles
          SET model = ?, reasoning_effort = ?, custom_instructions = ?, updated_at = ?
          WHERE id = ? AND product_id = ? AND is_active = 1;
          """
        ) { statement in
          try bind(update.model, to: 1, in: statement)
          try bind(update.reasoningEffort, to: 2, in: statement)
          try bindOptionalString(update.customInstructions, to: 3, in: statement)
          try bind(updatedAt.timeIntervalSince1970, to: 4, in: statement)
          try bind(profile.id.uuidString, to: 5, in: statement)
          try bind(productID.uuidString, to: 6, in: statement)
          try stepDone(statement)
        }
      }
      _ = try insertEvent(
        productID: productID,
        kind: "team.settings_updated",
        actor: "owner",
        detail: "Shared guidance and \(currentProfiles.count) team members updated"
      )
    }
    return TeamSettingsSnapshot(
      product: try fetchProduct(id: productID),
      profiles: try fetchAgentProfiles(productID: productID)
    )
  }

  public func updateAgentProfileConfiguration(
    id: UUID,
    model: String,
    reasoningEffort: String,
    customInstructions: String?
  ) throws -> AgentProfile {
    guard
      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PersistenceError.corruptData("Model and reasoning effort cannot be empty")
    }
    let profile = try fetchAgentProfile(id: id)
    let trimmedInstructions = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedInstructions = trimmedInstructions?.isEmpty == false ? trimmedInstructions : nil
    let updatedAt = Date()
    try transaction {
      try withStatement(
        """
        UPDATE agent_profiles
        SET model = ?, reasoning_effort = ?, custom_instructions = ?, updated_at = ?
        WHERE id = ?;
        """
      ) { statement in
        try bind(model, to: 1, in: statement)
        try bind(reasoningEffort, to: 2, in: statement)
        try bindOptionalString(storedInstructions, to: 3, in: statement)
        try bind(updatedAt.timeIntervalSince1970, to: 4, in: statement)
        try bind(id.uuidString, to: 5, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: profile.productID,
        kind: "team.profile_configured",
        actor: "owner",
        detail: "\(profile.name): \(model) · \(reasoningEffort)"
      )
    }
    return try fetchAgentProfile(id: id)
  }

  public func createCustomAgentProfile(
    productID: UUID,
    name: String,
    capability: AgentRole,
    model: String,
    reasoningEffort: String,
    instructions: String
  ) throws -> AgentProfile {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw PersistenceError.corruptData("A team member needs a name")
    }
    guard
      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PersistenceError.corruptData("A team member needs a model and reasoning effort")
    }
    let duplicateExists = try withStatement(
      """
      SELECT 1 FROM agent_profiles
      WHERE product_id = ? AND lower(name) = lower(?) AND is_active = 1
      LIMIT 1;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      try bind(trimmedName, to: 2, in: statement)
      return sqlite3_step(statement) == SQLITE_ROW
    }
    guard !duplicateExists else {
      throw PersistenceError.corruptData("A team member named \(trimmedName) already exists")
    }
    let profile = AgentProfile(
      productID: productID,
      name: trimmedName,
      role: capability,
      model: model,
      reasoningEffort: reasoningEffort,
      customInstructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
      isBuiltIn: false
    )
    try transaction {
      try insertAgentProfile(profile)
      _ = try insertEvent(
        productID: productID,
        kind: "team.custom_persona_created",
        actor: "owner",
        detail: "\(profile.name) · \(capability.capabilityTitle)"
      )
    }
    return profile
  }

  public func archiveCustomAgentProfile(id: UUID) throws {
    let profile = try fetchAgentProfile(id: id)
    guard !profile.isBuiltIn else {
      throw PersistenceError.corruptData("Default team members cannot be removed")
    }
    let hasCurrentAssignments = try withStatement(
      """
      SELECT 1
      WHERE EXISTS (
        SELECT 1 FROM agent_runs
        WHERE profile_id = ? AND status IN ('queued', 'running', 'awaiting_owner')
      ) OR EXISTS (
        SELECT 1
        FROM sprint_items si
        JOIN sprints s ON s.id = si.sprint_id
        WHERE (si.implementer_profile_id = ? OR si.reviewer_profile_id = ?)
          AND s.state IN ('draft', 'active', 'paused')
      );
      """
    ) { statement in
      try bind(id.uuidString, to: 1, in: statement)
      try bind(id.uuidString, to: 2, in: statement)
      try bind(id.uuidString, to: 3, in: statement)
      return sqlite3_step(statement) == SQLITE_ROW
    }
    guard !hasCurrentAssignments else {
      throw PersistenceError.corruptData(
        "Remove \(profile.name) from the current sprint before archiving the team member"
      )
    }
    try transaction {
      try withStatement(
        "UPDATE agent_profiles SET is_active = 0, updated_at = ? WHERE id = ?;"
      ) { statement in
        try bind(Date().timeIntervalSince1970, to: 1, in: statement)
        try bind(id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      _ = try insertEvent(
        productID: profile.productID,
        kind: "team.custom_persona_archived",
        actor: "owner",
        detail: profile.name
      )
    }
  }

}
