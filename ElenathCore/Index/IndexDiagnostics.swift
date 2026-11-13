import Foundation
import SQLite3

/// Facts about the system's SQLite, for the diagnostics report.
public enum IndexDiagnostics {
    /// "3.51.0".
    public static var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }

    /// Whether FTS5, which keyword search needs, is built in.
    public static var hasFullTextSearch: Bool {
        sqlite3_compileoption_used("ENABLE_FTS5") == 1
    }
}
