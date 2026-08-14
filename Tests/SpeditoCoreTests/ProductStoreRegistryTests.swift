import Foundation
import SQLite3
import Testing

@testable import SpeditoCore

@Suite("Product database registry", .serialized)
@MainActor
struct ProductStoreRegistryTests {
  @Test("A product can be created with its name alone")
  func productCreationOnlyNeedsAName() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }

    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let product = try await registry.createProduct(name: "New product")

    #expect(product.name == "New product")

    let store = try #require(registry.store(for: product.id))
    let persistedProduct = try #require(try await store.fetchProducts().first)
    #expect(persistedProduct.name == "New product")

    await store.close()
  }

  @Test("Every product receives one final-schema database")
  func productsAreIsolatedAndKeepCatalogColors() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }

    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(
      name: "First"
    )
    let second = try await registry.createProduct(
      name: "Second"
    )
    let third = try await registry.createProduct(
      name: "Third"
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

  @Test("Archived colors are available to active products and resolved on restore")
  func activeProductColorsStayDistinctAcrossStores() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }

    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let first = try await registry.createProduct(name: "First")
    let archived = try await registry.createProduct(name: "Archived")
    let archivedStore = try #require(registry.store(for: archived.id))
    _ = try await archivedStore.archiveProduct(id: archived.id)

    let replacement = try await registry.createProduct(name: "Replacement")
    #expect(first.color == .accent)
    #expect(archived.color == .green)
    #expect(replacement.color == .green)

    let restored = try await registry.restoreProduct(id: archived.id)
    #expect(restored.color == .indigo)
    #expect(Set(try await registry.fetchProducts().map(\.color)).count == 3)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Preparation repairs active color collisions while colors remain available")
  func preparationRepairsActiveProductColorCollisions() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }
    let firstID = UUID()
    let secondID = UUID()
    let thirdID = UUID()
    let records: [(UUID, String, ProductColor)] = [
      (firstID, "First", .accent),
      (secondID, "Second", .teal),
      (thirdID, "Third", .teal),
    ]

    for (id, name, color) in records {
      let store = try SQLiteStore(
        url: ProductStoreRegistry.databaseURL(
          productID: id,
          productWorkspacesRootURL: fixture.workspacesURL
        )
      )
      _ = try await store.createProduct(name: name, color: color, id: id)
      await store.close()
    }

    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    try await registry.prepare()
    let colors = Dictionary(
      uniqueKeysWithValues: try await registry.fetchProducts().map { ($0.id, $0.color) }
    )
    #expect(colors[firstID] == .accent)
    #expect(colors[secondID] == .teal)
    #expect(colors[thirdID] == .green)

    try await registry.prepare()
    let preparedAgain = Dictionary(
      uniqueKeysWithValues: try await registry.fetchProducts().map { ($0.id, $0.color) }
    )
    #expect(preparedAgain == colors)

    let thirdStore = try #require(registry.store(for: thirdID))
    #expect(
      try await thirdStore.fetchActivity(productID: thirdID).first?.kind
        == "product.color_reassigned"
    )

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
      name: "Queryable"
    )
    let item = try await store.createWorkItem(
      productID: product.id,
      title: "Expose product context",
      acceptanceCriteria: ["Agents can find this ticket"]
    )
    _ = try await store.appendComment(
      workItemID: item.id,
      authorKind: .owner,
      authorName: "Product owner",
      body: "Keep the database authoritative."
    )
    await store.close()

    let database = try ProductRegistryFixture.openReadOnly(databaseURL)
    defer { sqlite3_close(database) }
    #expect(try ProductRegistryFixture.scalarInt("PRAGMA user_version;", in: database) == 9)
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('demo_sessions') WHERE name = 'source_kind';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('repository_knowledge_runs') WHERE name = 'purpose';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('ticket_comments') WHERE name = 'github_review_context_json';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('remote_publications') WHERE name = 'purpose';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('remote_publications') WHERE name = 'remote_branch_deleted_at';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('candidate_revisions') WHERE name = 'delivery_kind';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('agent_delivery_provenance') WHERE name = 'delivery_kind';",
        in: database
      ) == 1
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('sprints') WHERE name = 'concurrency_limit';",
        in: database
      ) == 0
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('agent_profiles') WHERE name = 'parallelism_limit';",
        in: database
      ) == 0
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('products') WHERE name = 'vision';",
        in: database
      ) == 0
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'schema_migrations';",
        in: database
      ) == 0
    )
    #expect(
      try ProductRegistryFixture.scalarInt(
        "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name LIKE 'remote_%';",
        in: database
      ) == 3
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

  @Test("Unknown product database versions fail closed")
  func unknownSchemaVersionFailsClosed() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }
    let databaseURL = fixture.directoryURL.appendingPathComponent("product.sqlite")
    let originalStore = try SQLiteStore(url: databaseURL)
    _ = try await originalStore.createProduct(name: "Versioned product")
    await originalStore.close()
    try ProductRegistryFixture.execute(
      """
      PRAGMA user_version = 10;
      """,
      at: databaseURL
    )

    #expect(throws: PersistenceError.self) {
      _ = try SQLiteStore(url: databaseURL)
    }
  }

  @Test("The legacy shared database is split once without changing product IDs")
  func legacySharedDatabaseImport() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }
    let legacyURL = fixture.directoryURL.appendingPathComponent("spedito.sqlite")
    let legacyStore = try SQLiteStore(url: legacyURL)
    let first = try await legacyStore.createProduct(
      name: "Imported first"
    )
    let second = try await legacyStore.createProduct(
      name: "Imported second"
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
    #expect(
      try await firstStore.fetchWorkItems(productID: first.id).map(\.title) == [
        "First product ticket"
      ])
    #expect(
      try await secondStore.fetchWorkItems(productID: second.id).map(\.title) == [
        "Second product ticket"
      ])
    #expect(try await firstStore.fetchWorkItems(productID: second.id).isEmpty)
    #expect(try await secondStore.fetchWorkItems(productID: first.id).isEmpty)

    for store in registry.allStores {
      await store.close()
    }
  }

  @Test("Legacy product control directories migrate without changing product data")
  func legacyControlDirectoryMigration() async throws {
    let fixture = try ProductRegistryFixture()
    defer { fixture.remove() }
    let productID = UUID()
    let workspaceURL = fixture.workspacesURL.appendingPathComponent(
      productID.uuidString,
      isDirectory: true
    )
    let legacyDatabaseURL =
      workspaceURL
      .appendingPathComponent(
        ProductStoreRegistry.legacyControlDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(ProductStoreRegistry.databaseFilename)
    let legacyStore = try SQLiteStore(url: legacyDatabaseURL)
    _ = try await legacyStore.createProduct(
      name: "Migrated product",
      id: productID
    )
    await legacyStore.close()

    let registry = try ProductStoreRegistry(
      productWorkspacesRootURL: fixture.workspacesURL
    )
    let migratedStore = try #require(registry.store(for: productID))
    #expect(migratedStore.url == registry.databaseURL(for: productID))
    #expect(try await migratedStore.fetchProducts().map(\.name) == ["Migrated product"])
    #expect(!FileManager.default.fileExists(atPath: legacyDatabaseURL.path))
    #expect(FileManager.default.fileExists(atPath: registry.databaseURL(for: productID).path))

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
      .appendingPathComponent("spedito-product-stores-\(UUID())", isDirectory: true)
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
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorMessage)
      throw PersistenceError.sqlite(code: result, message: message)
    }
  }
}
