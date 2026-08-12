import CSQLite
import Foundation

public enum SQLiteValue: Sendable, Equatable {
  case text(String)
  case int(Int64)
  case real(Double)
  case null

  public var textValue: String? {
    if case .text(let value) = self { return value }
    return nil
  }

  public var intValue: Int64? {
    if case .int(let value) = self { return value }
    return nil
  }
}

/// Thin serialized wrapper over the SQLite C API. Not thread-safe on its own;
/// SQLiteStrategyStore (an actor) owns the only instance.
final class SQLiteDatabase {
  enum Failure: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    var description: String {
      switch self {
      case .open(let message): return "SQLite open failed: \(message)"
      case .prepare(let message, let sql): return "SQLite prepare failed (\(sql)): \(message)"
      case .step(let message, let sql): return "SQLite step failed (\(sql)): \(message)"
      }
    }
  }

  private var handle: OpaquePointer?

  init(path: String) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      sqlite3_close_v2(handle)
      throw Failure.open(message)
    }
  }

  deinit {
    sqlite3_close_v2(handle)
  }

  func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
    _ = try query(sql, bindings)
  }

  func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw Failure.prepare(errorMessage, sql: sql)
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in bindings.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .text(let text):
        sqlite3_bind_text(statement, index, text, -1, transient)
      case .int(let integer):
        sqlite3_bind_int64(statement, index, integer)
      case .real(let double):
        sqlite3_bind_double(statement, index, double)
      case .null:
        sqlite3_bind_null(statement, index)
      }
    }

    var rows: [[SQLiteValue]] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE {
        break
      }
      guard code == SQLITE_ROW else {
        throw Failure.step(errorMessage, sql: sql)
      }
      let columnCount = sqlite3_column_count(statement)
      var row: [SQLiteValue] = []
      for column in 0..<columnCount {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
          row.append(.int(sqlite3_column_int64(statement, column)))
        case SQLITE_FLOAT:
          row.append(.real(sqlite3_column_double(statement, column)))
        case SQLITE_TEXT:
          if let text = sqlite3_column_text(statement, column) {
            row.append(.text(String(cString: text)))
          } else {
            row.append(.null)
          }
        default:
          row.append(.null)
        }
      }
      rows.append(row)
    }
    return rows
  }

  private var errorMessage: String {
    handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
  }
}
