import Foundation
import SQLite3
import Testing

@testable import SpeditoCore

/// A throwaway on-disk product database plus the raw SQL access the persistence
/// and migration tests need. Shared so schema tests and store tests build their
/// databases the same way.
struct DatabaseFixture {
  let directoryURL: URL
  let databaseURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spedito-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    databaseURL = directoryURL.appendingPathComponent("test.sqlite")
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func execute(_ sql: String) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open(databaseURL.path, &database)
    guard openResult == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw PersistenceError.sqlite(code: openResult, message: "Could not open test database")
    }
    defer { sqlite3_close(database) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "Could not execute test SQL"
      sqlite3_free(errorMessage)
      throw PersistenceError.sqlite(code: result, message: message)
    }
  }

  func scalarInt(_ sql: String) throws -> Int32 {
    var database: OpaquePointer?
    let openResult = sqlite3_open(databaseURL.path, &database)
    guard openResult == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw PersistenceError.sqlite(code: openResult, message: "Could not open test database")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
      throw PersistenceError.sqlite(
        code: prepareResult,
        message: "Could not prepare scalar test query"
      )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw PersistenceError.sqlite(
        code: SQLITE_ERROR, message: "Scalar test query returned no row")
    }
    return sqlite3_column_int(statement, 0)
  }
}

/// Materializes the schema Spedito 0.1.0 shipped (`PRAGMA user_version = 1`) so
/// tests can drive the real upgrade path instead of mutating a current database
/// backwards.
func createVersionOneDatabase(at url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  let fixtureURL = try #require(
    Bundle.module.url(
      forResource: "product-schema-v1",
      withExtension: "sql"
    )
  )
  let sql = try String(contentsOf: fixtureURL, encoding: .utf8)
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw PersistenceError.corruptData("Could not create the version one fixture")
  }
  defer { sqlite3_close(database) }
  var message: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &message)
  guard result == SQLITE_OK else {
    let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
    sqlite3_free(message)
    throw PersistenceError.corruptData(detail)
  }
}

extension DatabaseFixture {
  /// Every column of every row rendered as text, so schema introspection
  /// queries can be compared without knowing their column types.
  func rows(_ sql: String) throws -> [[String?]] {
    var database: OpaquePointer?
    let openResult = sqlite3_open(databaseURL.path, &database)
    guard openResult == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw PersistenceError.sqlite(code: openResult, message: "Could not open test database")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
      throw PersistenceError.sqlite(code: prepareResult, message: "Could not prepare \(sql)")
    }
    defer { sqlite3_finalize(statement) }

    var results: [[String?]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      var row: [String?] = []
      for column in 0..<sqlite3_column_count(statement) {
        if let text = sqlite3_column_text(statement, column) {
          row.append(String(cString: text))
        } else {
          row.append(nil)
        }
      }
      results.append(row)
    }
    return results
  }
}
