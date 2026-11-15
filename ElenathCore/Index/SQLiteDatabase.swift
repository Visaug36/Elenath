import Foundation
import SQLite3

/// An error from the system's SQLite.
struct SQLiteError: Error, CustomStringConvertible, Sendable {
    var code: Int32
    var message: String

    var description: String {
        "SQLite error \(code): \(message)"
    }
}

/// A value bound to a statement.
enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    static func optional(_ text: String?) -> SQLiteValue {
        text.map { .text($0) } ?? .null
    }

    static func optional(_ number: Double?) -> SQLiteValue {
        number.map { .real($0) } ?? .null
    }

    static func optional(_ number: Int64?) -> SQLiteValue {
        number.map { .integer($0) } ?? .null
    }

    static func bool(_ value: Bool) -> SQLiteValue {
        .integer(value ? 1 : 0)
    }
}

/// One row of a result, valid only while the query's closure runs.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }

    func double(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    func optionalInt(_ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    /// The column's text, or "" when it is NULL.
    func string(_ column: Int32) -> String {
        text(column) ?? ""
    }

    func date(_ column: Int32) -> Date? {
        double(column).map { Date(timeIntervalSince1970: $0) }
    }
}

/// One connection to a SQLite database file, through the system's library.
///
/// A connection is not shared: each one belongs to a single actor. Statements are prepared once and
/// kept.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// Opens the database at `url`, creating the file if it isn't there. WAL mode, so one connection can
    /// write while others read.
    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open the database"
            sqlite3_close_v2(handle)
            handle = nil
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close_v2(handle)
    }

    /// Runs SQL that takes no values and returns nothing, such as a schema.
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: status, message: message)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw lastError(status) }
    }

    /// Runs a query and maps each row.
    func query<Result>(
        _ sql: String, _ values: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> Result
    ) throws -> [Result] {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        var results: [Result] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return results
            }
            guard status == SQLITE_ROW else { throw lastError(status) }
            results.append(try map(SQLiteRow(statement: statement)))
        }
    }

    /// The first row of a query, or nil when there is none.
    func first<Result>(
        _ sql: String, _ values: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> Result
    ) throws -> Result? {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE {
            return nil
        }
        guard status == SQLITE_ROW else { throw lastError(status) }
        return try map(SQLiteRow(statement: statement))
    }

    /// Runs `body` in one transaction that takes the write lock at once. Everything is undone if `body`
    /// throws.
    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertedRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    // MARK: - Private

    private func prepared(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var created: OpaquePointer?
            let status = sqlite3_prepare_v2(handle, sql, -1, &created, nil)
            guard status == SQLITE_OK, let created else { throw lastError(status) }
            statements[sql] = created
            statement = created
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .integer(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                status = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                // SQLITE_TRANSIENT: SQLite copies the text before the call returns.
                status = sqlite3_bind_text(
                    statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else { throw lastError(status) }
        }
        return statement
    }

    private func lastError(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }
}
