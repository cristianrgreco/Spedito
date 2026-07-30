import Foundation
import SQLite3
import Testing

@testable import StoryPointlessCore

@Suite("Product database registry", .serialized)
@MainActor
struct ProductStoreRegistryTests {
  @Test("Every product receives one final-schema database")
  func productsAreIsolatedAndKeepCatalogColors() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }

    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(
      name: "First",
      vision: "Keep one source of product truth"
    )
    let second = try await registry.createProduct(
      name: "Second",
      vision: "Remain isolated from the first"
    )
    let third = try await registry.createProduct(
      name: "Third",
      vision: "Keep the product palette predictable"
    )

    #expect(first.color == .accent)
    #expect(second.color == .green)
    #expect(third.color == .indigo)
    #expect(registry.store(for: first.id)?.url != registry.store(for: second.id)?.url)

    let firstStore = try #require(registry.store(for: first.id))
    let secondStore = try #require(registry.store(for: second.id))
    let firstProducts = try await firstStore.fetchProducts()
    let secondProducts = try await secondStore.fetchProducts()
    #expect(firstProducts.count == 1)
    #expect(firstProducts.first?.id == first.id)
    #expect(firstProducts.first?.name == first.name)
    #expect(firstProducts.first?.color == first.color)
    #expect(secondProducts.count == 1)
    #expect(secondProducts.first?.id == second.id)
    #expect(secondProducts.first?.name == second.name)
    #expect(secondProducts.first?.color == second.color)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("The final schema is created once and exposes live read-only agent views")
  func finalSchemaAndAgentViews() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }
    let databaseURL = fixture.directoryURL.appendingPathComponent("product.sqlite")
    let store = try SQLiteStore(url: databaseURL)
    let product = try await store.createProduct(
      name: "Queryable",
      vision: "Let the team discover current product evidence"
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Expose product context",
      acceptanceCriteria: ["Agents can find this ticket"]
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Product Owner",
      body: "Keep the database authoritative."
    )
    await store.close()

    let database = try ProductRegistryFixture.openReadOnly(databaseURL)
    defer { sqlite3_close(database) }
    #expect(try ProductRegistryFixture.scalarInt("PRAGMA user_version;", in: database) == 1)
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'schema_migrations';",
        in: database
      ) == 0
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM agent_tickets WHERE item_key = 'T1';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM agent_work_log WHERE item_key = 'T1';",
        in: database
      ) == 1
    )
    #expect(
      sqlite3_exec(
        database,
        "UPDATE products SET name = 'Not allowed';",
        nil,
        nil,
        nil
      ) == SQLITE_READONLY
    )
  }

  @Test("The legacy shared database is split once without changing product IDs")
  func legacySharedDatabaseImport() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }
    let legacyURL = fixture.directoryURL.appendingPathComponent("storypointless.sqlite")
    let legacyStore = try SQLiteStore(url: legacyURL)
    let first = try await legacyStore.createProduct(
      name: "Imported first",
      vision: "Preserve the first product"
    )
    let second = try await legacyStore.createProduct(
      name: "Imported second",
      vision: "Preserve the second product"
    )
    _ = try await legacyStore.createWorkItem(
      productID: first.id,
      title: "First product ticket",
      acceptanceCriteria: ["It remains isolated"]
    )
    _ = try await legacyStore.createWorkItem(
      productID: second.id,
      title: "Second product ticket",
      acceptanceCriteria: ["It remains isolated"]
    )
    await legacyStore.close()
    try ProductRegistryFixture.execute(
      """
      CREATE TABLE schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at REAL NOT NULL
      );
      INSERT INTO schema_migrations (version, applied_at) VALUES (53, unixepoch());
      PRAGMA user_version = 0;
      """,
      at: legacyURL
    )

    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL,
      legacyDatabaseURL: legacyURL
    )
    try await registry.prepare()
    try await registry.prepare()

    #expect(Set(try await registry.fetchProducts().map(\.id)) == [first.id, second.id])
    let firstStore = try #require(registry.store(for: first.id))
    let secondStore = try #require(registry.store(for: second.id))
    #expect(try await firstStore.fetchWorkItems(productID: first.id).map(\.title) == [
      "First product ticket"
    ])
    #expect(try await secondStore.fetchWorkItems(productID: second.id).map(\.title) == [
      "Second product ticket"
    ])
    #expect(try await firstStore.fetchWorkItems(productID: second.id).isEmpty)
    #expect(try await secondStore.fetchWorkItems(productID: first.id).isEmpty)

    for store in registry.allStores {
      await store.close()
    }
  }
}

private struct ProductRegistryFixture {
  let directoryURL: URL
  let workspacesURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("storypointless-product-stores-\(UUID())", isDirectory: true)
    workspacesURL = directoryURL.appendingPathComponent("Product Workspaces", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspacesURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  static func openReadOnly(_ url: URL) throws -> OpaquePointer {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
    guard result == SQLITE_OK, let database else {
      defer { if let database { sqlite3_close(database) } }
      throw PersistenceError.sqlite(
        code: result,
        message: database.map { String(cString: sqlite3_errmsg($0)) }
          ?? "Could not open test database."
      )
    }
    return database
  }

  static func scalarInt(_ sql: String, in database: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw PersistenceError.sqlite(
        code: result,
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw PersistenceError.sqlite(
        code: sqlite3_errcode(database),
        message: String(cString: sqlite3_errmsg(database))
      )
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  static func execute(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open(url.path, &database)
    guard openResult == SQLITE_OK, let database else {
      defer { if let database { sqlite3_close(database) } }
      throw PersistenceError.sqlite(
        code: openResult,
        message: database.map { String(cString: sqlite3_errmsg($0)) }
          ?? "Could not open test database."
      )
    }
    defer { sqlite3_close(database) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorMessage)
      throw PersistenceError.sqlite(code: result, message: message)
    }
  }
}
