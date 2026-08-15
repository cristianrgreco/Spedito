import Foundation
import SQLite3

@MainActor
public final class ProductStoreRegistry: ImportedProductRegistering {
  public nonisolated static let controlDirectoryName = ".spedito"
  nonisolated static let legacyControlDirectoryName = ".storypointless"
  public nonisolated static let databaseFilename = "product.sqlite"
  private nonisolated static let legacyImportMarkerFilename =
    ".legacy-shared-import-complete"

  public let productWorkspacesRootURL: URL
  public let legacyDatabaseURL: URL?

  private var stores: [UUID: SQLiteStore] = [:]

  public init(
    productWorkspacesRootURL: URL,
    legacyDatabaseURL: URL? = nil
  ) throws {
    self.productWorkspacesRootURL = productWorkspacesRootURL
    self.legacyDatabaseURL = legacyDatabaseURL
    try FileManager.default.createDirectory(
      at: productWorkspacesRootURL,
      withIntermediateDirectories: true
    )
    try loadExistingStores()
  }

  public func prepare() async throws {
    if let legacyDatabaseURL,
      FileManager.default.fileExists(atPath: legacyDatabaseURL.path),
      !legacyImportIsComplete()
    {
      let importedStores = try await LegacyProductDatabaseImporter.importProducts(
        from: legacyDatabaseURL,
        productWorkspacesRootURL: productWorkspacesRootURL
      )
      for (productID, importedStore) in importedStores {
        if stores[productID] == nil {
          stores[productID] = importedStore
        } else {
          await importedStore.close()
        }
      }
      try writeLegacyImportMarker(productIDs: Set(importedStores.keys))
    }
    try loadExistingStores()
    try await repairActiveProductColorCollisions()
  }

  public func store(for productID: UUID) -> SQLiteStore? {
    stores[productID]
  }

  public var allStores: [SQLiteStore] {
    Array(stores.values)
  }

  public func fetchProducts(status: ProductStatus? = .active) async throws -> [Product] {
    var products: [Product] = []
    for store in stores.values {
      products.append(contentsOf: try await store.fetchProducts(status: status))
    }
    return products.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  public func createProduct(name: String) async throws -> Product {
    let existingProducts = try await fetchProducts()
    let productID = UUID()
    let store = try SQLiteStore(url: databaseURL(for: productID))
    do {
      let product = try await store.createProduct(
        name: name,
        color: nextColor(existingProducts: existingProducts),
        id: productID
      )
      stores[product.id] = store
      return product
    } catch {
      await store.close()
      throw error
    }
  }

  public func restoreProduct(id: UUID) async throws -> Product {
    guard let store = stores[id] else {
      throw PersistenceError.recordNotFound("product \(id)")
    }
    let storedProducts =
      try await store.fetchProducts()
      + store.fetchProducts(status: .archived)
    guard let product = storedProducts.first(where: { $0.id == id }) else {
      throw PersistenceError.recordNotFound("product \(id)")
    }
    guard product.status == .archived else { return product }

    let existingProducts = try await fetchProducts()
    let orderedProducts = existingProducts.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    let existingColors = orderedProducts.map(\.color)
    let restoredColor =
      existingColors.contains(product.color)
      ? ProductColor.nextUnassigned(after: existingColors) ?? product.color
      : product.color
    return try await store.restoreProduct(id: id, color: restoredColor)
  }

  public func prepareImportedProduct(
    name: String,
    id: UUID,
    workspaceURL: URL,
    repository: ProductRepository
  ) async throws -> Product {
    guard repository.productID == id else {
      throw PersistenceError.corruptData("Imported repository metadata does not match its product")
    }
    let existingProducts = try await fetchProducts()
    let databaseURL =
      workspaceURL
      .appendingPathComponent(Self.controlDirectoryName, isDirectory: true)
      .appendingPathComponent(Self.databaseFilename)
    let store = try SQLiteStore(url: databaseURL)
    do {
      let product = try await store.createProduct(
        name: name,
        color: nextColor(existingProducts: existingProducts),
        id: id
      )
      let profiles = try await store.seedDefaultProfiles(productID: id)
      _ = try await store.seedKnowledgeBase(productID: id)
      guard
        let analyzer = profiles.first(where: { $0.role == .businessAnalyst }),
        let reviewer = profiles.first(where: { $0.role == .lead })
      else {
        throw PersistenceError.corruptData(
          "Imported products need an active business analyst and tech lead"
        )
      }
      try await store.createProductRepository(repository)
      try await store.createRepositoryKnowledgeRun(
        RepositoryKnowledgeRun(
          productID: id,
          attempt: 1,
          analyzedSHA: repository.importedSHA,
          analyzerProfileID: analyzer.id,
          reviewerProfileID: reviewer.id
        )
      )
      await store.close()
      return product
    } catch {
      await store.close()
      throw error
    }
  }

  public func registerPreparedProduct(id: UUID) async throws -> ImportedProduct {
    guard stores[id] == nil else {
      throw PersistenceError.corruptData("The imported product is already registered")
    }
    let store = try SQLiteStore(url: databaseURL(for: id))
    do {
      let products =
        try await store.fetchProducts(status: .active)
        + store.fetchProducts(status: .archived)
      guard products.count == 1, let product = products.first, product.id == id else {
        throw PersistenceError.corruptData(
          "The prepared product database does not contain exactly one matching product"
        )
      }
      guard let repository = try await store.fetchProductRepository(productID: id) else {
        throw PersistenceError.corruptData(
          "The prepared product database is missing repository provenance"
        )
      }
      guard let knowledgeRun = try await store.fetchLatestRepositoryKnowledgeRun(productID: id)
      else {
        throw PersistenceError.corruptData(
          "The prepared product database is missing its repository analysis"
        )
      }
      stores[id] = store
      return ImportedProduct(
        product: product,
        repository: repository,
        knowledgeRun: knowledgeRun
      )
    } catch {
      await store.close()
      throw error
    }
  }

  public func findStore(
    containingAgentRun runID: UUID
  ) async -> SQLiteStore? {
    for store in stores.values {
      if (try? await store.fetchAgentRun(id: runID)) != nil {
        return store
      }
    }
    return nil
  }

  public func databaseURL(for productID: UUID) -> URL {
    Self.databaseURL(
      productID: productID,
      productWorkspacesRootURL: productWorkspacesRootURL
    )
  }

  public nonisolated static func databaseURL(
    productID: UUID,
    productWorkspacesRootURL: URL
  ) -> URL {
    productWorkspacesRootURL
      .appendingPathComponent(productID.uuidString, isDirectory: true)
      .appendingPathComponent(controlDirectoryName, isDirectory: true)
      .appendingPathComponent(databaseFilename)
  }

  private func loadExistingStores() throws {
    let directories = try FileManager.default.contentsOfDirectory(
      at: productWorkspacesRootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    for directory in directories {
      guard
        let productID = UUID(uuidString: directory.lastPathComponent),
        stores[productID] == nil
      else { continue }
      try migrateLegacyControlDirectoryIfNeeded(
        productID: productID,
        workspaceURL: directory
      )
      let databaseURL = Self.databaseURL(
        productID: productID,
        productWorkspacesRootURL: productWorkspacesRootURL
      )
      guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
      stores[productID] = try SQLiteStore(url: databaseURL)
    }
  }

  private func migrateLegacyControlDirectoryIfNeeded(
    productID: UUID,
    workspaceURL: URL
  ) throws {
    let currentDirectoryURL = workspaceURL.appendingPathComponent(
      Self.controlDirectoryName,
      isDirectory: true
    )
    let currentDatabaseURL = currentDirectoryURL.appendingPathComponent(
      Self.databaseFilename
    )
    guard !FileManager.default.fileExists(atPath: currentDatabaseURL.path) else {
      return
    }

    let legacyDirectoryURL = workspaceURL.appendingPathComponent(
      Self.legacyControlDirectoryName,
      isDirectory: true
    )
    let legacyDatabaseURL = legacyDirectoryURL.appendingPathComponent(
      Self.databaseFilename
    )
    guard FileManager.default.fileExists(atPath: legacyDatabaseURL.path) else {
      return
    }

    if !FileManager.default.fileExists(atPath: currentDirectoryURL.path) {
      try FileManager.default.moveItem(
        at: legacyDirectoryURL,
        to: currentDirectoryURL
      )
      return
    }

    let legacyContents = try FileManager.default.contentsOfDirectory(
      at: legacyDirectoryURL,
      includingPropertiesForKeys: nil
    )
    for sourceURL in legacyContents {
      let destinationURL = currentDirectoryURL.appendingPathComponent(
        sourceURL.lastPathComponent
      )
      guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
        throw PersistenceError.corruptData(
          "Spedito cannot migrate legacy product \(productID) because \(destinationURL.lastPathComponent) already exists in the new control directory."
        )
      }
      try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
    try FileManager.default.removeItem(at: legacyDirectoryURL)
  }

  private var legacyImportMarkerURL: URL {
    productWorkspacesRootURL.appendingPathComponent(
      Self.legacyImportMarkerFilename
    )
  }

  private func legacyImportIsComplete() -> Bool {
    guard
      let data = try? Data(contentsOf: legacyImportMarkerURL),
      let values = try? JSONDecoder().decode([String].self, from: data)
    else {
      return false
    }
    let productIDs = values.compactMap(UUID.init(uuidString:))
    return productIDs.count == values.count
      && productIDs.allSatisfy { stores[$0] != nil }
  }

  private func writeLegacyImportMarker(productIDs: Set<UUID>) throws {
    let values = productIDs.map(\.uuidString).sorted()
    let data = try JSONEncoder().encode(values)
    try data.write(to: legacyImportMarkerURL, options: .atomic)
  }

  private func repairActiveProductColorCollisions() async throws {
    let products = try await fetchProducts()
    var reservedColors = products.map(\.color)
    var seenColors: Set<ProductColor> = []

    for product in products {
      guard !seenColors.insert(product.color).inserted else { continue }
      guard let replacementColor = ProductColor.nextUnassigned(after: reservedColors) else {
        continue
      }
      guard let store = stores[product.id] else {
        throw PersistenceError.recordNotFound("product \(product.id)")
      }
      _ = try await store.reassignProductColor(id: product.id, to: replacementColor)
      seenColors.insert(replacementColor)
      reservedColors.append(replacementColor)
    }
  }

  private func nextColor(existingProducts: [Product]) -> ProductColor {
    let orderedProducts = existingProducts.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    return ProductColor.nextAssigned(after: orderedProducts.map(\.color))
  }
}

private enum LegacyProductDatabaseImporter {
  static let expectedSchemaVersion = 53

  static func importProducts(
    from legacyDatabaseURL: URL,
    productWorkspacesRootURL: URL
  ) async throws -> [UUID: SQLiteStore] {
    let productIDs = try legacyProductIDs(at: legacyDatabaseURL)
    var importedStores: [UUID: SQLiteStore] = [:]

    for productID in productIDs {
      let finalURL = ProductStoreRegistry.databaseURL(
        productID: productID,
        productWorkspacesRootURL: productWorkspacesRootURL
      )
      if FileManager.default.fileExists(atPath: finalURL.path) {
        let existing = try SQLiteStore(url: finalURL)
        let products =
          try await existing.fetchProducts(status: .active)
          + existing.fetchProducts(status: .archived)
        guard products.count == 1, products.first?.id == productID else {
          await existing.close()
          throw PersistenceError.corruptData(
            "The existing product database at \(finalURL.path) belongs to another product."
          )
        }
        importedStores[productID] = existing
        continue
      }

      let controlDirectory = finalURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: controlDirectory,
        withIntermediateDirectories: true
      )
      let importID = UUID().uuidString
      let legacySliceURL =
        controlDirectory
        .appendingPathComponent("legacy-\(importID).sqlite")
      let stagedURL =
        controlDirectory
        .appendingPathComponent("product-\(importID).sqlite")
      do {
        try backupDatabase(from: legacyDatabaseURL, to: legacySliceURL)
        try retainOnlyProduct(productID, in: legacySliceURL)

        let stagedStore = try SQLiteStore(url: stagedURL)
        do {
          try await stagedStore.importAllRows(from: legacySliceURL)
          let importedProducts =
            try await stagedStore.fetchProducts(status: .active)
            + stagedStore.fetchProducts(status: .archived)
          guard importedProducts.count == 1, importedProducts.first?.id == productID else {
            throw PersistenceError.corruptData(
              "The imported database did not contain exactly product \(productID)."
            )
          }
          await stagedStore.close()
        } catch {
          await stagedStore.close()
          throw error
        }

        try FileManager.default.moveItem(at: stagedURL, to: finalURL)
        removeSQLiteSidecars(for: stagedURL)
        let finalStore = try SQLiteStore(url: finalURL)
        importedStores[productID] = finalStore
        try? FileManager.default.removeItem(at: legacySliceURL)
        removeSQLiteSidecars(for: legacySliceURL)
      } catch {
        try? FileManager.default.removeItem(at: stagedURL)
        removeSQLiteSidecars(for: stagedURL)
        try? FileManager.default.removeItem(at: legacySliceURL)
        removeSQLiteSidecars(for: legacySliceURL)
        throw error
      }
    }
    return importedStores
  }

  private static func legacyProductIDs(at url: URL) throws -> [UUID] {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
    guard result == SQLITE_OK, let database else {
      defer { if let database { sqlite3_close(database) } }
      throw sqliteError(database, code: result, fallback: "Could not open the legacy database.")
    }
    defer { sqlite3_close(database) }

    let version = try scalarInt(
      "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;",
      database: database
    )
    guard version == expectedSchemaVersion else {
      throw PersistenceError.corruptData(
        "The development database uses legacy schema \(version); expected \(expectedSchemaVersion)."
      )
    }

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(
      database,
      "SELECT id FROM products ORDER BY created_at, id;",
      -1,
      &statement,
      nil
    )
    guard prepareResult == SQLITE_OK, let statement else {
      throw sqliteError(database, code: prepareResult, fallback: "Could not list products.")
    }
    defer { sqlite3_finalize(statement) }
    var ids: [UUID] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard
        let value = sqlite3_column_text(statement, 0),
        let id = UUID(uuidString: String(cString: value))
      else {
        throw PersistenceError.corruptData("The legacy database contains an invalid product ID.")
      }
      ids.append(id)
    }
    return ids
  }

  private static func backupDatabase(from sourceURL: URL, to destinationURL: URL) throws {
    var source: OpaquePointer?
    var destination: OpaquePointer?
    let sourceResult = sqlite3_open_v2(
      sourceURL.path,
      &source,
      SQLITE_OPEN_READONLY,
      nil
    )
    guard sourceResult == SQLITE_OK, let source else {
      defer { if let source { sqlite3_close(source) } }
      throw sqliteError(source, code: sourceResult, fallback: "Could not read legacy data.")
    }
    defer { sqlite3_close(source) }

    let destinationResult = sqlite3_open_v2(
      destinationURL.path,
      &destination,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
      nil
    )
    guard destinationResult == SQLITE_OK, let destination else {
      defer { if let destination { sqlite3_close(destination) } }
      throw sqliteError(
        destination,
        code: destinationResult,
        fallback: "Could not stage legacy data."
      )
    }
    defer { sqlite3_close(destination) }

    guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
      throw sqliteError(
        destination,
        code: sqlite3_errcode(destination),
        fallback: "Could not start the legacy database backup."
      )
    }
    let stepResult = sqlite3_backup_step(backup, -1)
    let finishResult = sqlite3_backup_finish(backup)
    guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
      throw sqliteError(
        destination,
        code: finishResult == SQLITE_OK ? stepResult : finishResult,
        fallback: "Could not finish the legacy database backup."
      )
    }
  }

  private static func retainOnlyProduct(_ productID: UUID, in url: URL) throws {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path,
      &database,
      SQLITE_OPEN_READWRITE,
      nil
    )
    guard result == SQLITE_OK, let database else {
      defer { if let database { sqlite3_close(database) } }
      throw sqliteError(database, code: result, fallback: "Could not prepare legacy data.")
    }
    defer { sqlite3_close(database) }
    try execute("PRAGMA foreign_keys = ON;", database: database)
    try execute("BEGIN IMMEDIATE;", database: database)
    do {
      var statement: OpaquePointer?
      let prepareResult = sqlite3_prepare_v2(
        database,
        "DELETE FROM products WHERE id <> ?;",
        -1,
        &statement,
        nil
      )
      guard prepareResult == SQLITE_OK, let statement else {
        throw sqliteError(
          database,
          code: prepareResult,
          fallback: "Could not isolate a legacy product."
        )
      }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      guard
        sqlite3_bind_text(
          statement,
          1,
          productID.uuidString,
          -1,
          transient
        ) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_DONE
      else {
        throw sqliteError(
          database,
          code: sqlite3_errcode(database),
          fallback: "Could not isolate a legacy product."
        )
      }
      try execute("COMMIT;", database: database)
    } catch {
      try? execute("ROLLBACK;", database: database)
      throw error
    }
  }

  private static func scalarInt(
    _ sql: String,
    database: OpaquePointer
  ) throws -> Int {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw sqliteError(database, code: result, fallback: "Could not inspect legacy data.")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw sqliteError(
        database,
        code: sqlite3_errcode(database),
        fallback: "Could not inspect legacy data."
      )
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func execute(_ sql: String, database: OpaquePointer) throws {
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

  private static func sqliteError(
    _ database: OpaquePointer?,
    code: Int32,
    fallback: String
  ) -> PersistenceError {
    let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? fallback
    return .sqlite(code: code, message: message)
  }

  private static func removeSQLiteSidecars(for databaseURL: URL) {
    for suffix in ["-wal", "-shm"] {
      try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: databaseURL.path + suffix)
      )
    }
  }
}
