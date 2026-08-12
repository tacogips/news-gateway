import Foundation

/// SQLite-backed strategy store. All SQL is serialized through the actor.
public actor SQLiteStrategyStore: StrategyStore {
  private let database: SQLiteDatabase

  /// Opens (and migrates) the database at `path`, creating parent
  /// directories as needed. Use ":memory:" for tests.
  public init(path: String) throws {
    if path != ":memory:" {
      let directory = (path as NSString).deletingLastPathComponent
      if !directory.isEmpty {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      }
    }
    database = try SQLiteDatabase(path: path)
    try database.execute("PRAGMA journal_mode = WAL")
    try database.execute("PRAGMA foreign_keys = ON")
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS strategies (
        id TEXT PRIMARY KEY,
        source_url TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        body_json TEXT NOT NULL,
        version INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        success_count INTEGER NOT NULL DEFAULT 0,
        failure_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        last_fetched_at TEXT
      )
      """
    )
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS strategy_revisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strategy_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        body_json TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
      """
    )
  }

  public func save(_ strategy: Strategy) async throws {
    let body = String(decoding: try JSONCoding.encoder.encode(strategy), as: UTF8.self)
    let existing = try database.query(
      "SELECT body_json, version FROM strategies WHERE id = ?",
      [.text(strategy.id)]
    )
    if let row = existing.first, let previousBody = row[0].textValue, let previousVersion = row[1].intValue {
      try database.execute(
        "INSERT INTO strategy_revisions (strategy_id, version, body_json, created_at) VALUES (?, ?, ?, ?)",
        [.text(strategy.id), .int(previousVersion), .text(previousBody), .text(isoString(strategy.updatedAt))]
      )
      try database.execute(
        """
        UPDATE strategies
        SET source_url = ?, name = ?, body_json = ?, version = ?, updated_at = ?
        WHERE id = ?
        """,
        [
          .text(strategy.sourceURL), .text(strategy.name), .text(body),
          .int(Int64(strategy.version)), .text(isoString(strategy.updatedAt)), .text(strategy.id)
        ]
      )
    } else {
      try database.execute(
        """
        INSERT INTO strategies (id, source_url, name, body_json, version, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .text(strategy.id), .text(strategy.sourceURL), .text(strategy.name), .text(body),
          .int(Int64(strategy.version)), .text(isoString(strategy.createdAt)), .text(isoString(strategy.updatedAt))
        ]
      )
    }
  }

  public func find(sourceURL: String) async throws -> StoredStrategy? {
    try row(where: "source_url = ?", binding: sourceURL)
  }

  public func find(id: String) async throws -> StoredStrategy? {
    try row(where: "id = ?", binding: id)
  }

  public func list() async throws -> [StoredStrategy] {
    let rows = try database.query(
      "SELECT \(columns) FROM strategies ORDER BY updated_at DESC"
    )
    return try rows.map(decodeRow)
  }

  public func delete(idOrURL: String) async throws -> Bool {
    let normalized = (try? SourceURLNormalizer.normalize(idOrURL)) ?? idOrURL
    let existing = try database.query(
      "SELECT id FROM strategies WHERE id = ? OR source_url = ?",
      [.text(idOrURL), .text(normalized)]
    )
    guard let id = existing.first?[0].textValue else {
      return false
    }
    try database.execute("DELETE FROM strategy_revisions WHERE strategy_id = ?", [.text(id)])
    try database.execute("DELETE FROM strategies WHERE id = ?", [.text(id)])
    return true
  }

  public func recordOutcome(id: String, success: Bool, error: String?, at date: Date) async throws {
    let column = success ? "success_count" : "failure_count"
    try database.execute(
      """
      UPDATE strategies
      SET \(column) = \(column) + 1, last_error = ?, last_fetched_at = ?
      WHERE id = ?
      """,
      [error.map(SQLiteValue.text) ?? .null, .text(isoString(date)), .text(id)]
    )
  }

  /// Archived prior versions of a strategy, newest first.
  public func revisions(strategyID: String) async throws -> [Strategy] {
    let rows = try database.query(
      "SELECT body_json FROM strategy_revisions WHERE strategy_id = ? ORDER BY version DESC",
      [.text(strategyID)]
    )
    return try rows.compactMap { row in
      guard let body = row[0].textValue else { return nil }
      return try JSONCoding.decoder.decode(Strategy.self, from: Data(body.utf8))
    }
  }

  private let columns = "body_json, success_count, failure_count, last_error, last_fetched_at"

  private func row(where clause: String, binding: String) throws -> StoredStrategy? {
    let rows = try database.query(
      "SELECT \(columns) FROM strategies WHERE \(clause)",
      [.text(binding)]
    )
    guard let row = rows.first else { return nil }
    return try decodeRow(row)
  }

  private func decodeRow(_ row: [SQLiteValue]) throws -> StoredStrategy {
    guard let body = row[0].textValue else {
      throw GatewayError.configuration(message: "Corrupt strategy row (missing body)")
    }
    let strategy = try JSONCoding.decoder.decode(Strategy.self, from: Data(body.utf8))
    return StoredStrategy(
      strategy: strategy,
      successCount: Int(row[1].intValue ?? 0),
      failureCount: Int(row[2].intValue ?? 0),
      lastError: row[3].textValue,
      lastFetchedAt: row[4].textValue.flatMap(isoDate)
    )
  }

  private func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private func isoDate(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
  }
}
