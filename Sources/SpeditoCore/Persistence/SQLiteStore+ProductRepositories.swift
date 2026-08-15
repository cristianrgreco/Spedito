import Foundation
import SQLite3

extension SQLiteStore {
  public func createProductRepository(_ repository: ProductRepository) throws {
    let protectedPathsJSON = try encodeJSON(repository.protectedKnowledgePaths)
    try withStatement(
      """
      INSERT INTO product_repositories (
          product_id, origin_url, source_default_branch, imported_sha,
          protected_knowledge_paths_json, blocks_knowledge_export, imported_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      try bind(repository.productID.uuidString, to: 1, in: statement)
      try bind(repository.originURL.absoluteString, to: 2, in: statement)
      try bind(repository.sourceDefaultBranch, to: 3, in: statement)
      try bind(repository.importedSHA, to: 4, in: statement)
      try bind(protectedPathsJSON, to: 5, in: statement)
      try bind(repository.blocksKnowledgeExport ? Int64(1) : Int64(0), to: 6, in: statement)
      try bind(repository.importedAt.timeIntervalSince1970, to: 7, in: statement)
      try stepDone(statement)
    }
  }

  public func fetchProductRepository(productID: UUID) throws -> ProductRepository? {
    try withStatement(
      """
      SELECT product_id, origin_url, source_default_branch, imported_sha,
             protected_knowledge_paths_json, blocks_knowledge_export, imported_at
      FROM product_repositories
      WHERE product_id = ?;
      """
    ) { statement in
      try bind(productID.uuidString, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      guard
        let storedProductID = UUID(uuidString: try text(statement, column: 0)),
        let originURL = URL(string: try text(statement, column: 1))
      else {
        throw PersistenceError.corruptData("Invalid imported repository metadata")
      }
      return ProductRepository(
        productID: storedProductID,
        originURL: originURL,
        sourceDefaultBranch: try text(statement, column: 2),
        importedSHA: try text(statement, column: 3),
        protectedKnowledgePaths: try decodeJSON(
          [ProtectedRepositoryPath].self,
          from: try text(statement, column: 4)
        ),
        blocksKnowledgeExport: sqlite3_column_int64(statement, 5) != 0,
        importedAt: date(statement, column: 6)
      )
    }
  }

}
