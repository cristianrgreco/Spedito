import Foundation
import SQLite3
import Testing

@testable import SpeditoCore

/// Spedito 0.1.0 shipped `PRAGMA user_version = 1`, and ordered migrations
/// carry released databases to the current schema. Fresh installs instead run
/// one declarative schema. These are two independent sources of truth for the same
/// shape, so they are compared object by object.
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

    // Automatic indexes are included: their names encode which UNIQUE clause
    // produced them, so a reordered constraint shows up here.
    #expect(try fresh.objectIdentities() == migrated.objectIdentities())

    let freshDefinitions = try fresh.objectDefinitions()
    let migratedDefinitions = try migrated.objectDefinitions()
    for name in Set(freshDefinitions.keys).union(migratedDefinitions.keys).sorted() {
      #expect(
        freshDefinitions[name] == migratedDefinitions[name],
        "\(name) is declared differently by the schema and the migration"
      )
    }

    for table in try fresh.tableNames() {
      #expect(
        try fresh.rows("PRAGMA table_info(\(table));")
          == migrated.rows("PRAGMA table_info(\(table));"),
        "\(table) has different columns, types, defaults, or column order"
      )
      #expect(
        try fresh.rows("PRAGMA foreign_key_list(\(table));")
          == migrated.rows("PRAGMA foreign_key_list(\(table));"),
        "\(table) has different foreign keys"
      )
    }
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
