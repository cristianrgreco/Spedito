import Foundation
import SQLite3
import Testing

@testable import SpeditoCore

/// Spedito 0.1.0 shipped `PRAGMA user_version = 1`, and one idempotent upgrade
/// carries a released database to the current version. Fresh installs instead
/// run one declarative schema. These are two independent sources of truth for
/// the same shape, so they are compared object by object. The versions that
/// development builds wrote between the two releases fold forward through the
/// same upgrade.
@Suite("Product database schema", .serialized)
struct ProductDatabaseSchemaTests {
  @Test("A fresh install and a migrated version one database have identical schemas")
  func freshInstallMatchesMigratedVersionOneDatabase() async throws {
    let fresh = try DatabaseFixture()
    defer { fresh.remove() }
    let migrated = try DatabaseFixture()
    defer { migrated.remove() }

    let freshStore = try SQLiteStore(url: fresh.databaseURL)
    await freshStore.close()

    try createVersionOneDatabase(at: migrated.databaseURL)
    let migratedStore = try SQLiteStore(url: migrated.databaseURL)
    await migratedStore.close()

    #expect(try fresh.scalarInt("PRAGMA user_version;") == ProductDatabaseSchema.version)
    #expect(try migrated.scalarInt("PRAGMA user_version;") == ProductDatabaseSchema.version)
    try expectIdenticalSchemas(fresh: fresh, upgraded: migrated)
  }

  /// No fixture shipped for the versions development builds wrote between
  /// 0.1.0 and 0.2.0, so each shape is derived from the current schema by
  /// removing what that version still lacked: version 3 predates the ticket key
  /// counter and the demo kind columns, version 4 only the demo kind columns,
  /// version 5 carried an enumerated demo kind CHECK, and version 6 already has
  /// the current shape.
  @Test(
    "Unreleased development databases fold forward to version two without losing rows",
    arguments: [Int32(3), 4, 5, 6]
  )
  func preReleaseDatabaseFoldsForward(version: Int32) async throws {
    let fresh = try DatabaseFixture()
    defer { fresh.remove() }
    let freshStore = try SQLiteStore(url: fresh.databaseURL)
    await freshStore.close()

    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    let product = try await store.createProduct(name: "Development product")
    let first = try await store.createWorkItem(productID: product.id, title: "First ticket")
    _ = try await store.createWorkItem(productID: product.id, title: "Second ticket")
    _ = try await store.updateWorkItemDemoKind(id: first.id, demoKind: .browser)
    _ = try await store.appendComment(
      workItemID: first.id,
      authorKind: .owner,
      authorName: "Me",
      body: "Keep this through the upgrade."
    )
    let session = try await store.beginTicketSuggestionSession(productID: product.id)
    let batch = try await store.completeTicketSuggestionSession(
      sessionID: session.id,
      drafts: [
        TicketSuggestionDraft(
          reference: "S1",
          title: "A pending proposal",
          body: "Deliver the proposed outcome.",
          acceptanceCriteria: ["The outcome is visible"],
          suggestedRole: .implementer,
          priority: .normal,
          rationale: "The owner has not decided yet.",
          demoKind: .artifact
        )
      ]
    )
    let proposal = try #require(batch.suggestions.first)
    #expect(proposal.reference == "T3")
    #expect(
      try await store.createOwnerNotification(
        OwnerNotification(
          productID: product.id,
          kind: .refinementComplete,
          target: OwnerNotificationTarget(kind: .ticket, id: first.id),
          title: "Refinement complete",
          body: "The proposal is ready to review."
        )
      )
    )
    await store.close()

    try fixture.execute(
      Self.preReleaseShape(version: version, workItemID: first.id, suggestionID: proposal.id)
    )
    #expect(try fixture.scalarInt("PRAGMA user_version;") == version)
    let countsBefore = try fixture.rowCounts()

    let upgraded = try SQLiteStore(url: fixture.databaseURL)
    #expect(try fixture.scalarInt("PRAGMA user_version;") == ProductDatabaseSchema.version)
    #expect(try fixture.rowCounts() == countsBefore)
    try expectIdenticalSchemas(fresh: fresh, upgraded: fixture)

    // Versions 3 and 4 had no demo kind column, so their rows read back as
    // pre-contract; the kinds version 5 stored survive the CHECK removal.
    let items = try await upgraded.fetchWorkItems(productID: product.id)
    #expect(Set(items.map(\.key)) == ["T1", "T2"])
    #expect(items.first { $0.id == first.id }?.demoKind == (version >= 5 ? .browser : nil))
    // Version 3 stored the proposal with a temporary S reference and gains T3
    // from the derived counter; later versions already carried T3 and keep it.
    let recovered = try await upgraded.fetchTicketSuggestionBatch(sessionID: session.id)
    #expect(recovered.suggestions.map(\.reference) == ["T3"])
    #expect(recovered.suggestions.first?.demoKind == (version >= 5 ? .artifact : nil))
    #expect(try await upgraded.fetchActiveOwnerNotifications(productID: product.id).count == 1)
    let next = try await upgraded.createWorkItem(productID: product.id, title: "After the upgrade")
    #expect(next.key == "T4")
    await upgraded.close()
  }

  @Test("The version two upgrade changes nothing when it runs again")
  func upgradeIsIdempotent() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    try createVersionOneDatabase(at: fixture.databaseURL)

    let productID = UUID()
    let sessionID = UUID()
    let now = Date().timeIntervalSince1970
    try fixture.execute(
      """
      INSERT INTO products (id, name, instructions, status, color, created_at, updated_at)
      VALUES ('\(productID.uuidString)', 'Released product', '', 'active', 'accent', \(now), \(now));

      INSERT INTO work_items (
        id, product_id, key_number, item_key, title, body, acceptance_criteria_json,
        ticket_type, state, priority, rank, custom_fields_json, version, created_at, updated_at
      ) VALUES (
        '\(UUID().uuidString)', '\(productID.uuidString)', 1, 'T1',
        'A released ticket', '', '[]', 'story', 'backlog', 2, 0, '{}', 1, \(now), \(now)
      );

      INSERT INTO suggestion_sessions (id, product_id, status, created_at, updated_at)
      VALUES ('\(sessionID.uuidString)', '\(productID.uuidString)', 'ready', \(now), \(now));

      INSERT INTO ticket_suggestions (
        id, session_id, reference, position, title, body, acceptance_criteria_json,
        suggested_role, priority, rationale, status, accepted_work_item_id,
        created_at, updated_at
      ) VALUES (
        '\(UUID().uuidString)', '\(sessionID.uuidString)', 'S1', 0,
        'A pending proposal', 'Deliver it.', '["The outcome is visible"]',
        'implementer', 2, 'It delivers the outcome.', 'proposed', NULL, \(now), \(now)
      );

      INSERT INTO sprints (
        id, product_id, sprint_number, goal, state, plan_version, created_at, updated_at
      ) VALUES (
        '\(UUID().uuidString)', '\(productID.uuidString)', 1,
        'Next valuable increment', 'draft', 1, \(now), \(now)
      );
      """
    )

    let store = try SQLiteStore(url: fixture.databaseURL)
    await store.close()
    #expect(try fixture.scalarInt("PRAGMA user_version;") == ProductDatabaseSchema.version)
    let identities = try fixture.objectIdentities()
    let definitions = try fixture.objectDefinitions()
    let columns = try fixture.columnLayouts()
    let contents = try fixture.contents()
    #expect(
      try fixture.rows("SELECT reference FROM ticket_suggestions;") == [["T2"]]
    )
    #expect(try fixture.scalarInt("SELECT next_ticket_key_number FROM products;") == 3)
    #expect(try fixture.rows("SELECT goal FROM sprints;") == [[""]])

    // Stamping the upgraded database back to version 1 makes every step run
    // again against objects that already exist.
    try fixture.execute("PRAGMA user_version = 1;")
    let reopened = try SQLiteStore(url: fixture.databaseURL)
    await reopened.close()

    #expect(try fixture.scalarInt("PRAGMA user_version;") == ProductDatabaseSchema.version)
    #expect(try fixture.objectIdentities() == identities)
    #expect(try fixture.objectDefinitions() == definitions)
    #expect(try fixture.columnLayouts() == columns)
    #expect(try fixture.contents() == contents)
  }

  @Test("Every product table takes part in a legacy import")
  func legacyCopyOrderCoversEveryTable() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try SQLiteStore(url: fixture.databaseURL)
    await store.close()

    #expect(
      Set(try fixture.tableNames()) == Set(ProductDatabaseSchema.legacyCopyTableOrder),
      "a table is missing from legacyCopyTableOrder, so a legacy import would drop its rows"
    )
  }

  private static func preReleaseShape(
    version: Int32,
    workItemID: UUID,
    suggestionID: UUID
  ) -> String {
    let enumeration = """
      TEXT CHECK (
        demo_kind IN (
          'browser', 'static_web', 'mac_application', 'artifact',
          'command_output', 'none'
        )
      )
      """
    var sql = ""
    if version <= 4 {
      sql += """
        ALTER TABLE work_items DROP COLUMN demo_kind;
        ALTER TABLE ticket_suggestions DROP COLUMN demo_kind;

        """
    }
    if version == 3 {
      sql += """
        ALTER TABLE products DROP COLUMN next_ticket_key_number;
        UPDATE ticket_suggestions SET reference = 'S1' WHERE id = '\(suggestionID.uuidString)';

        """
    }
    if version == 5 {
      sql += """
        ALTER TABLE work_items DROP COLUMN demo_kind;
        ALTER TABLE work_items ADD COLUMN demo_kind \(enumeration);
        UPDATE work_items SET demo_kind = 'browser' WHERE id = '\(workItemID.uuidString)';
        ALTER TABLE ticket_suggestions DROP COLUMN demo_kind;
        ALTER TABLE ticket_suggestions ADD COLUMN demo_kind \(enumeration);
        UPDATE ticket_suggestions SET demo_kind = 'artifact'
        WHERE id = '\(suggestionID.uuidString)';

        """
    }
    sql += "PRAGMA user_version = \(version);"
    return sql
  }
}

/// Automatic indexes are included: their names encode which UNIQUE clause
/// produced them, so a reordered constraint shows up here.
private func expectIdenticalSchemas(fresh: DatabaseFixture, upgraded: DatabaseFixture) throws {
  #expect(try fresh.objectIdentities() == upgraded.objectIdentities())

  let freshDefinitions = try fresh.objectDefinitions()
  let upgradedDefinitions = try upgraded.objectDefinitions()
  for name in Set(freshDefinitions.keys).union(upgradedDefinitions.keys).sorted() {
    #expect(
      freshDefinitions[name] == upgradedDefinitions[name],
      "\(name) is declared differently by the schema and the upgrade"
    )
  }

  for table in try fresh.tableNames() {
    #expect(
      try fresh.rows("PRAGMA table_info(\(table));")
        == upgraded.rows("PRAGMA table_info(\(table));"),
      "\(table) has different columns, types, defaults, or column order"
    )
    #expect(
      try fresh.rows("PRAGMA foreign_key_list(\(table));")
        == upgraded.rows("PRAGMA foreign_key_list(\(table));"),
      "\(table) has different foreign keys"
    )
  }
}

extension DatabaseFixture {
  fileprivate func tableNames() throws -> [String] {
    try rows(
      """
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
      ORDER BY name;
      """
    ).compactMap { $0.first ?? nil }
  }

  fileprivate func rowCounts() throws -> [String: Int32] {
    var counts: [String: Int32] = [:]
    for table in try tableNames() {
      counts[table] = try scalarInt("SELECT COUNT(*) FROM \(table);")
    }
    return counts
  }

  fileprivate func columnLayouts() throws -> [String: [[String?]]] {
    var layouts: [String: [[String?]]] = [:]
    for table in try tableNames() {
      layouts[table] = try rows("PRAGMA table_info(\(table));")
    }
    return layouts
  }

  fileprivate func contents() throws -> [String: [[String?]]] {
    var contents: [String: [[String?]]] = [:]
    for table in try tableNames() {
      contents[table] = try rows("SELECT * FROM \(table) ORDER BY 1;")
    }
    return contents
  }

  fileprivate func objectIdentities() throws -> Set<String> {
    Set(
      try rows("SELECT type, name FROM sqlite_master;").map {
        "\($0.first.flatMap { $0 } ?? "") \($0.last.flatMap { $0 } ?? "")"
      }
    )
  }

  fileprivate func objectDefinitions() throws -> [String: String] {
    var definitions: [String: String] = [:]
    for row in try rows("SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL;") {
      guard let name = row.first.flatMap({ $0 }), let sql = row.last.flatMap({ $0 }) else {
        continue
      }
      definitions[name] = Self.normalized(sql)
    }
    return definitions
  }

  /// SQLite splices an added column in with its own spacing, so the comparison
  /// ignores whitespace that carries no meaning.
  fileprivate static func normalized(_ sql: String) -> String {
    var collapsed = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    for token in ["(", ")", ","] {
      collapsed = collapsed.replacingOccurrences(of: " \(token)", with: token)
      collapsed = collapsed.replacingOccurrences(of: "\(token) ", with: token)
    }
    return collapsed
  }
}
