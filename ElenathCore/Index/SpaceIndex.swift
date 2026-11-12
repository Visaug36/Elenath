import Foundation

/// A link as the index keeps it.
struct LinkRecord: Hashable, Sendable {
    /// As written: a wiki link's target, or a Markdown link's destination.
    var target: String
    /// The key of the title the link names, to find the links that may point at a note.
    var titleKey: String
    var heading: String?
    var isEmbed: Bool
    var isMarkdown: Bool
    /// Where the link is in the body, in UTF-16 units.
    var location: Int
    var length: Int
    /// The line the link is on.
    var context: String
}

struct TaskRecord: Hashable, Sendable {
    var text: String
    var isDone: Bool
    /// Where the task's box is in the body, in UTF-16 units.
    var location: Int
}

/// Everything the index keeps about one note. It is derived from the file and nothing else.
struct NoteRecord: Sendable {
    var path: ItemPath
    var noteID: NoteID?
    var kind: NoteKind
    var created: Date?
    var modified: Date?
    var byteCount: Int64
    var contentHash: UInt64
    var identity: FileIdentity?
    var body: String
    var preview: String
    var tags: [String]
    var links: [LinkRecord]
    var tasks: [TaskRecord]

    /// Reads a note's bytes into what the index keeps.
    init(path: ItemPath, data: Data, info: FileInfo?, timeZone: TimeZone) {
        self.path = path
        let text = try? NoteText(data: data)
        // A file that isn't UTF-8 is still found by what can be read of it.
        body = text?.body ?? String(decoding: data, as: UTF8.self)
        noteID = text?.frontMatter?.id
        kind = text?.kind ?? .note
        created = text?.frontMatter?.created(in: timeZone) ?? info?.created
        modified = info?.modified
        byteCount = Int64(data.count)
        contentHash = ContentHash.of(data)
        identity = info?.identity

        let scan = MarkdownScanner.scan(body)
        var seenTags = Set<String>()
        tags = ((text?.frontMatter?.tags ?? []) + scan.tags.map(\.name)).filter {
            seenTags.insert(NameSanitizer.key($0)).inserted
        }
        let nsBody = body as NSString
        links = scan.links.compactMap { span in
            let line = nsBody.substring(with: nsBody.lineRange(for: span.range))
            let context = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            switch span.target {
            case .wiki(let link):
                guard let title = link.targetComponents.last else { return nil }
                return LinkRecord(
                    target: link.target, titleKey: NameSanitizer.key(title), heading: link.heading,
                    isEmbed: link.isEmbed, isMarkdown: false, location: span.range.location, length: span.range.length,
                    context: context)
            case .markdown(let destination, let isImage):
                // Only a path can point at a note. Anything with a scheme is a web link.
                let path = String(destination.prefix(while: { $0 != "#" }))
                if let colon = path.firstIndex(of: ":"), !path[..<colon].contains("/") {
                    return nil
                }
                guard let last = (path.removingPercentEncoding ?? path).split(separator: "/").last else { return nil }
                return LinkRecord(
                    target: destination, titleKey: NameSanitizer.key(ItemPath.title(ofFileNamed: String(last))),
                    heading: nil, isEmbed: isImage, isMarkdown: true, location: span.range.location,
                    length: span.range.length, context: context)
            case .url:
                return nil
            }
        }
        tasks = scan.tasks.map { TaskRecord(text: $0.text, isDone: $0.isDone, location: $0.boxRange.location) }
        preview = NoteRecord.preview(of: body, scan: scan)
    }

    /// The first lines of a note as one line of plain text, for lists.
    private static func preview(of body: String, scan: MarkdownScan) -> String {
        let nsBody = body as NSString
        var parts: [String] = []
        var length = 0
        for line in scan.lines {
            switch line.kind {
            case .blank, .codeFence, .thematicBreak:
                continue
            default:
                break
            }
            let start = min(max(line.textStart, line.contentRange.location), NSMaxRange(line.contentRange))
            let text = nsBody.substring(with: NSRange(location: start, length: NSMaxRange(line.contentRange) - start))
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            parts.append(text)
            length += text.count
            if length >= 200 || parts.count >= 4 {
                break
            }
        }
        return String(parts.joined(separator: " ").prefix(240))
    }
}

/// A file that isn't a note, or a folder.
struct FileRecord: Hashable, Sendable {
    var path: ItemPath
    var isFolder: Bool
    var modified: Date?
    var byteCount: Int64
}

/// What the indexer needs to tell whether a note file changed, without reading it.
struct IndexedNoteState: Sendable {
    var rowID: Int64
    var path: ItemPath
    var byteCount: Int64
    var modified: Date?
    var contentHash: UInt64
    var noteID: String?
    var identity: FileIdentity?
}

/// The rows a query returns, before they become public results.
struct IndexedNoteRow: Sendable {
    var path: ItemPath
    var title: String
    var kind: NoteKind
    var modified: Date?
    var created: Date?
    var preview: String
}

struct IndexedSearchRow: Sendable {
    var note: IndexedNoteRow
    /// With U+0002 before and U+0003 after each matched word.
    var markedSnippet: String
    var rank: Double
}

struct IndexedLinkRow: Sendable {
    var source: IndexedNoteRow
    var link: LinkRecord
}

struct IndexedTaskRow: Sendable {
    var note: IndexedNoteRow
    var text: String
    var location: Int
}

/// What a search is narrowed by, inside one database.
struct IndexFilter: Sendable {
    var folder: ItemPath?
    var tag: String?
    var kind: NoteKind?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
}

/// The index of one space, or of the Inbox: one SQLite database in Elenath's container.
///
/// It is a cache. Everything in it comes from the folder and it can be thrown away at any time. This
/// type is internal on purpose: the app and Nano bot can only ask `Retrieval`, which decides through
/// `Reach` which databases a question may read.
final class SpaceIndex {
    /// A database written with another version is emptied and filled again.
    static let schemaVersion: Int64 = 1

    let container: Container
    private let database: SQLiteDatabase

    init(url: URL, container: Container) throws {
        self.container = container
        database = try SQLiteDatabase(url: url)
        try prepareSchema()
    }

    /// The file name of a container's database.
    static func fileName(for container: Container) -> String {
        switch container {
        case .inbox: "inbox.sqlite"
        case .space(let id): "\(id.rawValue.uuidString).sqlite"
        }
    }

    // MARK: - Schema

    private func prepareSchema() throws {
        try database.transaction {
            let version = try database.first("PRAGMA user_version") { $0.int(0) } ?? 0
            if version == SpaceIndex.schemaVersion {
                return
            }
            for table in ["notes", "links", "tags", "tasks", "files", "note_text", "note_trigram"] {
                try database.execute("DROP TABLE IF EXISTS \(table)")
            }
            try database.execute(SpaceIndex.schema)
            try database.execute("PRAGMA user_version = \(SpaceIndex.schemaVersion)")
        }
    }

    private static let schema = """
        CREATE TABLE notes (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL,
            path_key TEXT NOT NULL UNIQUE,
            folder_key TEXT NOT NULL,
            title TEXT NOT NULL,
            title_key TEXT NOT NULL,
            note_id TEXT,
            kind TEXT NOT NULL,
            created REAL,
            modified REAL,
            byte_count INTEGER NOT NULL,
            content_hash INTEGER NOT NULL,
            file_volume INTEGER,
            file_number INTEGER,
            preview TEXT NOT NULL
        );
        CREATE INDEX notes_title ON notes(title_key);
        CREATE INDEX notes_modified ON notes(modified);
        CREATE INDEX notes_folder ON notes(folder_key);
        CREATE TABLE links (
            source INTEGER NOT NULL,
            target TEXT NOT NULL,
            title_key TEXT NOT NULL,
            heading TEXT,
            is_embed INTEGER NOT NULL,
            is_markdown INTEGER NOT NULL,
            location INTEGER NOT NULL,
            length INTEGER NOT NULL,
            context TEXT NOT NULL
        );
        CREATE INDEX links_title ON links(title_key);
        CREATE INDEX links_source ON links(source);
        CREATE TABLE tags (
            note INTEGER NOT NULL,
            tag TEXT NOT NULL,
            tag_key TEXT NOT NULL
        );
        CREATE INDEX tags_key ON tags(tag_key);
        CREATE INDEX tags_note ON tags(note);
        CREATE TABLE tasks (
            note INTEGER NOT NULL,
            text TEXT NOT NULL,
            is_done INTEGER NOT NULL,
            location INTEGER NOT NULL,
            position INTEGER NOT NULL
        );
        CREATE INDEX tasks_note ON tasks(note);
        CREATE TABLE files (
            path TEXT NOT NULL,
            path_key TEXT NOT NULL PRIMARY KEY,
            name_key TEXT NOT NULL,
            is_folder INTEGER NOT NULL,
            modified REAL,
            byte_count INTEGER NOT NULL
        ) WITHOUT ROWID;
        CREATE VIRTUAL TABLE note_text USING fts5(title, body, tags, tokenize = "unicode61 remove_diacritics 2");
        CREATE VIRTUAL TABLE note_trigram USING fts5(
            title, body, tokenize = 'trigram', content = '', contentless_delete = 1);
        """

    // MARK: - Writing (the indexer)

    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try database.transaction(body)
    }

    /// What is indexed for every note, to compare with the folder.
    func noteStates() throws -> [IndexedNoteState] {
        try database.query(
            "SELECT id, path, byte_count, modified, content_hash, note_id, file_volume, file_number FROM notes"
        ) { row in
            var identity: FileIdentity?
            if let volume = row.optionalInt(6), let file = row.optionalInt(7) {
                identity = FileIdentity(volume: UInt64(bitPattern: volume), file: UInt64(bitPattern: file))
            }
            return IndexedNoteState(
                rowID: row.int(0), path: ItemPath(row.string(1)) ?? .root, byteCount: row.int(2), modified: row.date(3),
                contentHash: UInt64(bitPattern: row.int(4)), noteID: row.text(5), identity: identity)
        }
    }

    /// Stores a note. With `existing`, that row is rewritten and keeps its number, also under a new
    /// path: that is a note that moved.
    @discardableResult
    func store(_ record: NoteRecord, replacing existing: Int64?) throws -> Int64 {
        let pathKey = NameSanitizer.key(record.path.description)
        // Another row may still claim this path (a case-only rename): it gives way.
        for other in try database.query(
            "SELECT id FROM notes WHERE path_key = ?", [.text(pathKey)], { $0.int(0) })
        where other != existing {
            try remove(rowID: other)
        }
        let values: [SQLiteValue] = [
            .text(record.path.description), .text(pathKey), .text(NameSanitizer.key(record.path.folder.description)),
            .text(record.path.title), .text(NameSanitizer.key(record.path.title)), .optional(record.noteID?.string),
            .text(record.kind.rawValue), .optional(record.created?.timeIntervalSince1970),
            .optional(record.modified?.timeIntervalSince1970), .integer(record.byteCount),
            .integer(Int64(bitPattern: record.contentHash)),
            .optional(record.identity.map { Int64(bitPattern: $0.volume) }),
            .optional(record.identity.map { Int64(bitPattern: $0.file) }), .text(record.preview),
        ]
        let rowID: Int64
        if let existing {
            try database.run(
                """
                UPDATE notes SET path = ?, path_key = ?, folder_key = ?, title = ?, title_key = ?, note_id = ?,
                    kind = ?, created = ?, modified = ?, byte_count = ?, content_hash = ?, file_volume = ?,
                    file_number = ?, preview = ? WHERE id = ?
                """, values + [.integer(existing)])
            rowID = existing
            try removeDerived(rowID: rowID)
        } else {
            try database.run(
                """
                INSERT INTO notes (path, path_key, folder_key, title, title_key, note_id, kind, created, modified,
                    byte_count, content_hash, file_volume, file_number, preview)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values)
            rowID = database.lastInsertedRowID
        }

        let id = SQLiteValue.integer(rowID)
        try database.run(
            "INSERT INTO note_text (rowid, title, body, tags) VALUES (?, ?, ?, ?)",
            [id, .text(record.path.title), .text(record.body), .text(record.tags.joined(separator: " "))])
        try database.run(
            "INSERT INTO note_trigram (rowid, title, body) VALUES (?, ?, ?)",
            [id, .text(record.path.title), .text(record.body)])
        for link in record.links {
            try database.run(
                """
                INSERT INTO links (source, target, title_key, heading, is_embed, is_markdown, location, length, context)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    id, .text(link.target), .text(link.titleKey), .optional(link.heading), .bool(link.isEmbed),
                    .bool(link.isMarkdown), .integer(Int64(link.location)), .integer(Int64(link.length)),
                    .text(link.context),
                ])
        }
        for tag in record.tags {
            try database.run(
                "INSERT INTO tags (note, tag, tag_key) VALUES (?, ?, ?)",
                [id, .text(tag), .text(NameSanitizer.key(tag))])
        }
        for (position, task) in record.tasks.enumerated() {
            try database.run(
                "INSERT INTO tasks (note, text, is_done, location, position) VALUES (?, ?, ?, ?, ?)",
                [id, .text(task.text), .bool(task.isDone), .integer(Int64(task.location)), .integer(Int64(position))])
        }
        return rowID
    }

    /// Records that a file was touched but holds the same bytes.
    func touch(rowID: Int64, modified: Date?, identity: FileIdentity?) throws {
        try database.run(
            "UPDATE notes SET modified = ?, file_volume = ?, file_number = ? WHERE id = ?",
            [
                .optional(modified?.timeIntervalSince1970), .optional(identity.map { Int64(bitPattern: $0.volume) }),
                .optional(identity.map { Int64(bitPattern: $0.file) }), .integer(rowID),
            ])
    }

    func remove(rowID: Int64) throws {
        try removeDerived(rowID: rowID)
        try database.run("DELETE FROM notes WHERE id = ?", [.integer(rowID)])
    }

    private func removeDerived(rowID: Int64) throws {
        let id = SQLiteValue.integer(rowID)
        try database.run("DELETE FROM note_text WHERE rowid = ?", [id])
        try database.run("DELETE FROM note_trigram WHERE rowid = ?", [id])
        try database.run("DELETE FROM links WHERE source = ?", [id])
        try database.run("DELETE FROM tags WHERE note = ?", [id])
        try database.run("DELETE FROM tasks WHERE note = ?", [id])
    }

    /// Replaces what is known about the files that aren't notes, and the folders.
    func replaceFiles(_ files: [FileRecord]) throws {
        try database.run("DELETE FROM files")
        for file in files {
            try database.run(
                "INSERT OR REPLACE INTO files (path, path_key, name_key, is_folder, modified, byte_count) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .text(file.path.description), .text(NameSanitizer.key(file.path.description)),
                    .text(NameSanitizer.key(file.path.name)), .bool(file.isFolder),
                    .optional(file.modified?.timeIntervalSince1970), .integer(file.byteCount),
                ])
        }
    }

    /// Empties the index. It fills again from the folder.
    func clear() throws {
        try database.transaction {
            for table in ["notes", "links", "tags", "tasks", "files", "note_text", "note_trigram"] {
                try database.run("DELETE FROM \(table)")
            }
        }
    }

    // MARK: - Reading (retrieval)

    /// A number that changes whenever another connection changes the database.
    func dataVersion() throws -> Int64 {
        try database.first("PRAGMA data_version") { $0.int(0) } ?? 0
    }

    private static let noteColumns = "n.path, n.title, n.kind, n.modified, n.created, n.preview"

    private static func noteRow(_ row: SQLiteRow, from column: Int32 = 0) -> IndexedNoteRow {
        IndexedNoteRow(
            path: ItemPath(row.string(column)) ?? .root, title: row.string(column + 1),
            kind: NoteKind(rawValue: row.string(column + 2)) ?? .note, modified: row.date(column + 3),
            created: row.date(column + 4), preview: row.string(column + 5))
    }

    /// The SQL conditions of a filter, on the `notes` table as `n`, and their values.
    private static func conditions(for filter: IndexFilter) -> (sql: [String], values: [SQLiteValue]) {
        var sql: [String] = []
        var values: [SQLiteValue] = []
        if let folder = filter.folder, !folder.isRoot {
            let key = NameSanitizer.key(folder.description)
            let prefix = key + "/"
            sql.append("(n.folder_key = ? OR substr(n.folder_key, 1, ?) = ?)")
            values += [.text(key), .integer(Int64(prefix.unicodeScalars.count)), .text(prefix)]
        }
        if let tag = filter.tag {
            let key = NameSanitizer.key(tag)
            let prefix = key + "/"
            sql.append(
                "EXISTS (SELECT 1 FROM tags t WHERE t.note = n.id AND (t.tag_key = ? OR substr(t.tag_key, 1, ?) = ?))")
            values += [.text(key), .integer(Int64(prefix.unicodeScalars.count)), .text(prefix)]
        }
        if let kind = filter.kind {
            sql.append("n.kind = ?")
            values.append(.text(kind.rawValue))
        }
        if let after = filter.modifiedAfter {
            sql.append("n.modified >= ?")
            values.append(.real(after.timeIntervalSince1970))
        }
        if let before = filter.modifiedBefore {
            sql.append("n.modified < ?")
            values.append(.real(before.timeIntervalSince1970))
        }
        return (sql, values)
    }

    /// Full-text search: `match` is an FTS5 query. Titles count most, then tags, then text; newer notes
    /// first on a tie.
    func search(match: String, filter: IndexFilter, limit: Int) throws -> [IndexedSearchRow] {
        let (conditions, values) = SpaceIndex.conditions(for: filter)
        let extra = conditions.map { " AND " + $0 }.joined()
        let sql = """
            SELECT \(SpaceIndex.noteColumns), snippet(note_text, 1, char(2), char(3), '…', 18),
                bm25(note_text, 10.0, 1.0, 4.0) AS rank
            FROM note_text JOIN notes n ON n.id = note_text.rowid
            WHERE note_text MATCH ?\(extra)
            ORDER BY rank, n.modified DESC LIMIT ?
            """
        return try database.query(sql, [.text(match)] + values + [.integer(Int64(limit))]) { row in
            IndexedSearchRow(note: SpaceIndex.noteRow(row), markedSnippet: row.string(6), rank: row.double(7) ?? 0)
        }
    }

    /// Notes that contain every one of `terms` anywhere in their title or text, also inside words and in
    /// text written without spaces. Returns each note with its body, for a snippet.
    func searchSubstrings(_ terms: [String], filter: IndexFilter, limit: Int) throws -> [(IndexedNoteRow, String)] {
        guard !terms.isEmpty else { return [] }
        let (conditions, values) = SpaceIndex.conditions(for: filter)
        let extra = conditions.map { " AND " + $0 }.joined()
        let limitValue = SQLiteValue.integer(Int64(limit))
        if terms.allSatisfy({ $0.unicodeScalars.count >= 3 }) {
            // The trigram index finds substrings of three characters and more.
            let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(
                separator: " ")
            let sql = """
                SELECT \(SpaceIndex.noteColumns), note_text.body
                FROM note_trigram JOIN notes n ON n.id = note_trigram.rowid
                    JOIN note_text ON note_text.rowid = n.id
                WHERE note_trigram MATCH ?\(extra)
                ORDER BY n.modified DESC LIMIT ?
                """
            return try database.query(sql, [.text(match)] + values + [limitValue]) { row in
                (SpaceIndex.noteRow(row), row.string(6))
            }
        }
        // Shorter than that (two characters of Chinese, say): look through the text itself.
        let contains = terms.map { _ in "(instr(note_text.body, ?) > 0 OR instr(note_text.title, ?) > 0)" }
        let sql = """
            SELECT \(SpaceIndex.noteColumns), note_text.body
            FROM note_text JOIN notes n ON n.id = note_text.rowid
            WHERE \(contains.joined(separator: " AND "))\(extra)
            ORDER BY n.modified DESC LIMIT ?
            """
        let termValues = terms.flatMap { [SQLiteValue.text($0), SQLiteValue.text($0)] }
        return try database.query(sql, termValues + values + [limitValue]) { row in
            (SpaceIndex.noteRow(row), row.string(6))
        }
    }

    /// Notes that pass a filter, newest first: a search without words.
    func notes(filter: IndexFilter, limit: Int) throws -> [IndexedNoteRow] {
        let (conditions, values) = SpaceIndex.conditions(for: filter)
        let condition = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        return try database.query(
            "SELECT \(SpaceIndex.noteColumns) FROM notes n\(condition) ORDER BY n.modified DESC LIMIT ?",
            values + [.integer(Int64(limit))]
        ) { SpaceIndex.noteRow($0) }
    }

    /// The notes directly inside a folder, by title.
    func notes(inFolder folder: ItemPath) throws -> [IndexedNoteRow] {
        try database.query(
            "SELECT \(SpaceIndex.noteColumns) FROM notes n WHERE n.folder_key = ? ORDER BY n.title_key",
            [.text(NameSanitizer.key(folder.description))]
        ) { SpaceIndex.noteRow($0) }
    }

    /// Notes whose title contains `titleKey`, those that start with it first, then the newest.
    func titles(containing titleKey: String, limit: Int) throws -> [IndexedNoteRow] {
        guard !titleKey.isEmpty else { return try notes(filter: IndexFilter(), limit: limit) }
        return try database.query(
            """
            SELECT \(SpaceIndex.noteColumns) FROM notes n WHERE instr(n.title_key, ?) > 0
            ORDER BY (instr(n.title_key, ?) = 1) DESC, n.modified DESC LIMIT ?
            """, [.text(titleKey), .text(titleKey), .integer(Int64(limit))]
        ) { SpaceIndex.noteRow($0) }
    }

    /// The path of every note, for a `TitleCatalog`.
    func allNotePaths() throws -> [ItemPath] {
        try database.query("SELECT path FROM notes") { ItemPath($0.string(0)) }.compactMap { $0 }
    }

    func noteCount() throws -> Int {
        Int(try database.first("SELECT count(*) FROM notes") { $0.int(0) } ?? 0)
    }

    /// One note's row, by where it is.
    func note(at path: ItemPath) throws -> IndexedNoteRow? {
        try database.first(
            "SELECT \(SpaceIndex.noteColumns) FROM notes n WHERE n.path_key = ?",
            [.text(NameSanitizer.key(path.description))]
        ) { SpaceIndex.noteRow($0) }
    }

    /// A note's text as it was last indexed. Nil when the note isn't in the index.
    func body(of path: ItemPath) throws -> String? {
        try database.first(
            "SELECT note_text.body FROM notes n JOIN note_text ON note_text.rowid = n.id WHERE n.path_key = ?",
            [.text(NameSanitizer.key(path.description))]
        ) { $0.string(0) }
    }

    /// The links whose target names a note with this title key, with the notes they are in.
    func links(toTitleKey titleKey: String) throws -> [IndexedLinkRow] {
        try database.query(
            """
            SELECT \(SpaceIndex.noteColumns), l.target, l.title_key, l.heading, l.is_embed, l.is_markdown, l.location,
                l.length, l.context
            FROM links l JOIN notes n ON n.id = l.source WHERE l.title_key = ? ORDER BY n.title_key, l.location
            """, [.text(titleKey)]
        ) { row in
            IndexedLinkRow(
                source: SpaceIndex.noteRow(row),
                link: LinkRecord(
                    target: row.string(6), titleKey: row.string(7), heading: row.text(8), isEmbed: row.bool(9),
                    isMarkdown: row.bool(10), location: Int(row.int(11)), length: Int(row.int(12)),
                    context: row.string(13)))
        }
    }

    /// The notes with a wiki link whose target has `name` as one of its folder parts.
    func noteLinking(throughFolderNamed name: String) throws -> [ItemPath] {
        let key = NameSanitizer.key(name)
        let rows = try database.query(
            """
            SELECT DISTINCT n.path, l.target FROM links l JOIN notes n ON n.id = l.source
            WHERE l.is_markdown = 0 AND instr(l.target, '/') > 0
            """
        ) { (ItemPath($0.string(0)), $0.string(1)) }
        var seen = Set<ItemPath>()
        var result: [ItemPath] = []
        for (path, target) in rows {
            guard let path, !seen.contains(path) else { continue }
            let folders = target.split(separator: "/").dropLast()
            if folders.contains(where: { NameSanitizer.key($0.trimmingCharacters(in: .whitespaces)) == key }) {
                seen.insert(path)
                result.append(path)
            }
        }
        return result
    }

    /// Every tag as first written, with how many notes have it.
    func tagCounts() throws -> [(key: String, tag: String, count: Int)] {
        try database.query(
            "SELECT tag_key, min(tag), count(DISTINCT note) FROM tags GROUP BY tag_key"
        ) { ($0.string(0), $0.string(1), Int($0.int(2))) }
    }

    func openTasks(limit: Int) throws -> [IndexedTaskRow] {
        try database.query(
            """
            SELECT \(SpaceIndex.noteColumns), t.text, t.location
            FROM tasks t JOIN notes n ON n.id = t.note WHERE t.is_done = 0
            ORDER BY n.modified DESC, n.id, t.position LIMIT ?
            """, [.integer(Int64(limit))]
        ) { IndexedTaskRow(note: SpaceIndex.noteRow($0), text: $0.string(6), location: Int($0.int(7))) }
    }

    /// Whether another note in this database carries the same `id` and is older: this one is then a
    /// duplicated file.
    func isLaterDuplicate(_ path: ItemPath) throws -> Bool {
        let count = try database.first(
            """
            SELECT count(*) FROM notes mine JOIN notes other ON other.note_id = mine.note_id AND other.id != mine.id
            WHERE mine.path_key = ? AND mine.note_id IS NOT NULL
                AND (coalesce(other.created, 0) < coalesce(mine.created, 0)
                    OR (coalesce(other.created, 0) = coalesce(mine.created, 0) AND other.id < mine.id))
            """, [.text(NameSanitizer.key(path.description))]
        ) { $0.int(0) }
        return (count ?? 0) > 0
    }

    /// The folders of the container, by path.
    func folders() throws -> [ItemPath] {
        try database.query("SELECT path FROM files WHERE is_folder = 1 ORDER BY path_key") { ItemPath($0.string(0)) }
            .compactMap { $0 }
    }

    /// Files that aren't notes whose name contains every one of `termKeys`.
    func files(named termKeys: [String], limit: Int) throws -> [FileRecord] {
        guard !termKeys.isEmpty else { return [] }
        let contains = termKeys.map { _ in "instr(name_key, ?) > 0" }.joined(separator: " AND ")
        return try database.query(
            "SELECT path, modified, byte_count FROM files WHERE is_folder = 0 AND \(contains) ORDER BY modified DESC LIMIT ?",
            termKeys.map { SQLiteValue.text($0) } + [.integer(Int64(limit))]
        ) { row in
            FileRecord(
                path: ItemPath(row.string(0)) ?? .root, isFolder: false, modified: row.date(1), byteCount: row.int(2))
        }
    }

    /// How many items are directly inside the container's folder: notes, files and folders.
    func topLevelItemCount() throws -> Int {
        let notes = try database.first("SELECT count(*) FROM notes WHERE folder_key = ''") { $0.int(0) } ?? 0
        let files = try database.first("SELECT count(*) FROM files WHERE instr(path_key, '/') = 0") { $0.int(0) } ?? 0
        return Int(notes + files)
    }
}
