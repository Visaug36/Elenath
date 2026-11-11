import Foundation
import SQLite3
import Testing

/// Facts about the system's SQLite that Elenath's index depends on. If macOS ever ships a SQLite without
/// them, these fail on CI before anything is built on top.
struct SQLiteProbeTests {
    @Test func fullTextSearchIsBuiltIn() throws {
        let database = try ProbeDatabase()
        try database.execute(
            "CREATE VIRTUAL TABLE notes USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2')")
        try database.execute(
            "INSERT INTO notes (title, body) VALUES ('Lecture 7', 'Rotational motion and the moment of inertia')")
        try database.execute(
            "INSERT INTO notes (title, body) VALUES ('Café ideas', 'A naïve plan for the résumé workshop')")
        #expect(try database.count("SELECT count(*) FROM notes WHERE notes MATCH 'inertia'") == 1)
        // Diacritics are folded, so "resume" finds "résumé".
        #expect(try database.count("SELECT count(*) FROM notes WHERE notes MATCH 'resume'") == 1)
        // Prefix queries, for search as you type.
        #expect(try database.count("SELECT count(*) FROM notes WHERE notes MATCH 'rota*'") == 1)
        // A column filter, for searching titles only.
        #expect(try database.count("SELECT count(*) FROM notes WHERE notes MATCH 'title : lecture'") == 1)
    }

    @Test func theTrigramTokenizerIsBuiltIn() throws {
        // For text written without spaces between words, where unicode61 finds no word boundaries.
        let database = try ProbeDatabase()
        try database.execute("CREATE VIRTUAL TABLE notes USING fts5(body, tokenize = 'trigram')")
        try database.execute("INSERT INTO notes (body) VALUES ('東京都の天気')")
        #expect(try database.count("SELECT count(*) FROM notes WHERE notes MATCH '東京都'") == 1)
    }

    @Test func theLibraryIsRecentEnough() {
        // 3.43 has everything the index uses: FTS5 with the trigram tokenizer (3.34) and
        // contentless-delete tables (3.43).
        #expect(sqlite3_libversion_number() >= 3_043_000)
    }
}

/// An in-memory database for the probes.
private final class ProbeDatabase {
    private var handle: OpaquePointer?

    init() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(":memory:", &handle, flags, nil) == SQLITE_OK else {
            throw ProbeError(message: "could not open an in-memory database")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw ProbeError(message: message)
        }
    }

    /// The first column of the first row, as an integer.
    func count(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProbeError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ProbeError(message: String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    var message: String

    var description: String { message }
}
