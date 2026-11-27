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
    /// The event occurrence the note is for (front matter `event`): "Notes for this lecture".
    var event: EventLink?

    /// Reads a note's bytes into what the index keeps.
    init(path: ItemPath, data: Data, info: FileInfo?, timeZone: TimeZone) {
        self.path = path
        let text = try? NoteText(data: data)
        // A file that isn't UTF-8 is still found by what can be read of it.
        body = text?.body ?? String(decoding: data, as: UTF8.self)
        noteID = text?.frontMatter?.id
        event = text?.frontMatter?.event
        kind = text?.kind ?? .note
        created = text?.frontMatter?.created(in: timeZone) ?? info?.created
        modified = info?.modified
        // The file's size, also when only its beginning was read (`NoteLimits.maximumIndexedBytes`).
        byteCount = info?.byteCount ?? Int64(data.count)
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

/// Where a file row's file is.
enum FileOrigin: Int64, Sendable {
    /// In the container's folder, attachments included; the path is relative to that folder.
    case folder = 0
    /// In an event folder, indexed into its event's home space; the path is relative to the calendar folder.
    case event = 1
}

/// A file that isn't a note, or a folder.
struct FileRecord: Hashable, Sendable {
    var origin: FileOrigin = .folder
    var path: ItemPath
    var isFolder: Bool
    var modified: Date?
    var byteCount: Int64
    /// Where a search narrowed to a folder finds it: the folder it is in, or an event file's home folder.
    var folder: ItemPath
    /// An event file's occurrence.
    var event: EventLink?

    init(
        origin: FileOrigin = .folder, path: ItemPath, isFolder: Bool, modified: Date?, byteCount: Int64,
        folder: ItemPath? = nil, event: EventLink? = nil
    ) {
        self.origin = origin
        self.path = path
        self.isFolder = isFolder
        self.modified = modified
        self.byteCount = byteCount
        self.folder = folder ?? path.folder
        self.event = event
    }
}

/// What became of a file's text. A row without one is waiting to be read.
enum FileTextState: Int64, Sendable {
    case read = 1
    /// Nothing to read: no text in it, or not a kind of file whose text is read.
    case none = 2
    /// Couldn't be read: broken, locked, too slow, or its reading never finished.
    case failed = 3
}

/// A file whose text is waiting to be read.
struct FileToRead: Hashable, Sendable {
    var id: Int64
    var origin: FileOrigin
    var path: ItemPath
    var kind: FileTextKind
    var byteCount: Int64
    var modified: Date?
}

/// A file as a query returns it.
struct IndexedFileRow: Hashable, Sendable {
    var id: Int64
    var origin: FileOrigin
    var path: ItemPath
    var event: EventLink?
    var modified: Date?
}

struct IndexedFileSearchRow: Sendable {
    var file: IndexedFileRow
    /// The PDF page that matched.
    var page: Int?
    /// With U+0002 before and U+0003 after each matched word, or the page's text for a substring match.
    var markedSnippet: String
    var rank: Double
}

/// A chunk waiting for its vector, with the text the embedder reads.
struct PendingChunk: Sendable {
    var id: Int64
    var script: String
    var text: String
}

/// A chunk's vector and where the chunk is.
struct ChunkVector: Sendable {
    var chunk: Int64
    /// The note it is from, or nil for a file's chunk.
    var note: Int64?
    /// The file it is from, or nil for a note's chunk.
    var file: Int64?
    var page: Int?
    var range: NSRange
    var vector: [Float]
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
    /// Notes for one event occurrence.
    var event: EventLink?
}

/// The index of one space, or of the Inbox: one SQLite database in Elenath's container.
///
/// It is a cache. Everything in it comes from the folder and it can be thrown away at any time. This
/// type is internal on purpose: the app and Nano bot can only ask `Retrieval`, which decides through
/// `Reach` which databases a question may read.
final class SpaceIndex {
    /// A database written with another version is emptied and filled again.
    static let schemaVersion: Int64 = 5

    let container: Container
    private let database: SQLiteDatabase
    /// The database file this was opened on, to notice when it has been replaced.
    private let fileNumber: UInt64?

    init(url: URL, container: Container) throws {
        self.container = container
        database = try SQLiteDatabase(url: url)
        fileNumber = SpaceIndex.fileNumber(at: url)
        try prepareSchema()
    }

    /// Whether the file at `url` is still the one this was opened on.
    func isStillOpen(at url: URL) -> Bool {
        fileNumber != nil && SpaceIndex.fileNumber(at: url) == fileNumber
    }

    private static func fileNumber(at url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
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
            for table in SpaceIndex.tables {
                try database.execute("DROP TABLE IF EXISTS \(table)")
            }
            try database.execute(SpaceIndex.schema)
            try database.execute("PRAGMA user_version = \(SpaceIndex.schemaVersion)")
        }
    }

    /// Every table, for dropping and emptying.
    private static let tables = [
        "notes", "links", "tags", "tasks", "files", "file_pages", "note_text", "note_trigram", "file_text",
        "file_trigram", "chunks", "meta",
    ]

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
            preview TEXT NOT NULL,
            event TEXT
        );
        CREATE INDEX notes_title ON notes(title_key);
        CREATE INDEX notes_event ON notes(event);
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
            id INTEGER PRIMARY KEY,
            origin INTEGER NOT NULL,
            path TEXT NOT NULL,
            path_key TEXT NOT NULL,
            name_key TEXT NOT NULL,
            folder_key TEXT NOT NULL,
            is_folder INTEGER NOT NULL,
            modified REAL,
            byte_count INTEGER NOT NULL,
            event TEXT,
            text_state INTEGER,
            attempts INTEGER NOT NULL DEFAULT 0,
            UNIQUE (origin, path_key)
        );
        CREATE INDEX files_folder ON files(folder_key);
        CREATE INDEX files_waiting ON files(text_state, attempts);
        CREATE TABLE file_pages (
            id INTEGER PRIMARY KEY,
            file INTEGER NOT NULL,
            page INTEGER
        );
        CREATE INDEX file_pages_file ON file_pages(file);
        CREATE TABLE chunks (
            id INTEGER PRIMARY KEY,
            note INTEGER,
            file INTEGER,
            page INTEGER,
            location INTEGER NOT NULL,
            length INTEGER NOT NULL,
            headings TEXT NOT NULL,
            text TEXT NOT NULL,
            script TEXT,
            model TEXT,
            vector BLOB
        );
        CREATE INDEX chunks_note ON chunks(note);
        CREATE INDEX chunks_file ON chunks(file);
        CREATE INDEX chunks_model ON chunks(model);
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE VIRTUAL TABLE note_text USING fts5(title, body, tags, tokenize = "unicode61 remove_diacritics 2");
        CREATE VIRTUAL TABLE note_trigram USING fts5(
            title, body, tokenize = 'trigram', content = '', contentless_delete = 1);
        CREATE VIRTUAL TABLE file_text USING fts5(body, tokenize = "unicode61 remove_diacritics 2");
        CREATE VIRTUAL TABLE file_trigram USING fts5(
            body, tokenize = 'trigram', content = '', contentless_delete = 1);
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
            .optional(record.event?.string),
        ]
        let rowID: Int64
        if let existing {
            try database.run(
                """
                UPDATE notes SET path = ?, path_key = ?, folder_key = ?, title = ?, title_key = ?, note_id = ?,
                    kind = ?, created = ?, modified = ?, byte_count = ?, content_hash = ?, file_volume = ?,
                    file_number = ?, preview = ?, event = ? WHERE id = ?
                """, values + [.integer(existing)])
            rowID = existing
            try removeDerived(rowID: rowID)
        } else {
            try database.run(
                """
                INSERT INTO notes (path, path_key, folder_key, title, title_key, note_id, kind, created, modified,
                    byte_count, content_hash, file_volume, file_number, preview, event)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            // "[[C# notes]]" may name the note "C" (heading " notes") or, when there is no "C", the note
            // "C# notes": it is found under both titles, and resolving tells which it is.
            var keys = [link.titleKey]
            if !link.isMarkdown, let heading = link.heading,
                let whole = WikiLink(target: link.target + "#" + heading).targetComponents.last.map(NameSanitizer.key),
                whole != link.titleKey
            {
                keys.append(whole)
            }
            for key in keys {
                try database.run(
                    """
                    INSERT INTO links (source, target, title_key, heading, is_embed, is_markdown, location, length, context)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        id, .text(link.target), .text(key), .optional(link.heading), .bool(link.isEmbed),
                        .bool(link.isMarkdown), .integer(Int64(link.location)), .integer(Int64(link.length)),
                        .text(link.context),
                    ])
            }
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
        try storeChunks(Chunker.chunks(ofNote: record.body), note: rowID)
        return rowID
    }

    // MARK: - Chunks and vectors (meaning)

    /// How headings are joined in the `headings` column.
    static let headingSeparator: Character = "\u{1F}"

    /// The chunks of a note, without vectors yet: the indexer's embedding pass makes those.
    private func storeChunks(_ chunks: [Chunk], note rowID: Int64) throws {
        for chunk in chunks {
            try database.run(
                """
                INSERT INTO chunks (note, file, page, location, length, headings, text, script, model, vector)
                VALUES (?, NULL, ?, ?, ?, ?, ?, ?, NULL, NULL)
                """,
                [
                    .integer(rowID), .optional(chunk.page.map(Int64.init)), .integer(Int64(chunk.range.location)),
                    .integer(Int64(chunk.range.length)),
                    .text(chunk.headings.joined(separator: String(SpaceIndex.headingSeparator))),
                    .text(chunk.text), .optional(Script.dominant(in: chunk.embeddingText)),
                ])
        }
        if !chunks.isEmpty {
            try bumpChunksVersion()
        }
    }

    private static func headings(_ stored: String) -> [String] {
        stored.split(separator: headingSeparator).map(String.init)
    }

    /// Chunks without a vector in one of `scripts`, oldest first, with the text the embedder reads.
    func pendingChunks(scripts: Set<String>, limit: Int) throws -> [PendingChunk] {
        guard !scripts.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: scripts.count).joined(separator: ", ")
        return try database.query(
            "SELECT id, script, headings, text FROM chunks WHERE vector IS NULL AND script IN (\(marks)) ORDER BY id LIMIT ?",
            scripts.sorted().map { .text($0) } + [.integer(Int64(limit))]
        ) { row in
            let chunk = Chunk(
                headings: SpaceIndex.headings(row.string(2)), text: row.string(3),
                range: NSRange(location: 0, length: 0))
            return PendingChunk(id: row.int(0), script: row.string(1), text: chunk.embeddingText)
        }
    }

    /// The scripts of chunks still waiting for a vector, other than `scripts`.
    func waitingScripts(besides scripts: Set<String>) throws -> Set<String> {
        let found = try database.query(
            "SELECT DISTINCT script FROM chunks WHERE vector IS NULL AND script IS NOT NULL"
        ) { $0.string(0) }
        return Set(found).subtracting(scripts)
    }

    func setVector(_ vector: [Float], model: EmbedderStamp, forChunk id: Int64) throws {
        try database.run(
            "UPDATE chunks SET model = ?, vector = ? WHERE id = ?",
            [.text(model.key), .blob(VectorMath.encode(vector)), .integer(id)])
        try bumpChunksVersion()
    }

    /// Marks a chunk the model couldn't read, so it isn't asked again until its note changes.
    func setUnreadable(chunk id: Int64, model: EmbedderStamp) throws {
        try database.run("UPDATE chunks SET model = ?, vector = X'' WHERE id = ?", [.text(model.key), .integer(id)])
    }

    /// The model last used for a script's vectors; when it differs from the model now, its vectors are made
    /// again (`forgetVectors(script:)`).
    func modelStamp(forScript script: String) throws -> String? {
        try database.first("SELECT value FROM meta WHERE key = ?", [.text("model." + script)]) { $0.string(0) }
    }

    func setModelStamp(_ stamp: EmbedderStamp, forScript script: String) throws {
        try database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text("model." + script), .text(stamp.key)])
    }

    func forgetVectors(script: String) throws {
        try database.run("UPDATE chunks SET model = NULL, vector = NULL WHERE script = ?", [.text(script)])
        try bumpChunksVersion()
    }

    /// Goes up whenever chunks or their vectors change, so a reader knows when what it holds is stale.
    func chunksVersion() throws -> Int64 {
        try database.first("SELECT value FROM meta WHERE key = 'chunks_version'") { Int64($0.string(0)) ?? 0 } ?? 0
    }

    private func bumpChunksVersion() throws {
        try database.run(
            """
            INSERT INTO meta (key, value) VALUES ('chunks_version', '1')
            ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
            """)
    }

    /// Every vector a model made, with where its chunk is: what meaning search compares a question with.
    func chunkVectors(model: EmbedderStamp, dimension: Int) throws -> [ChunkVector] {
        try database.query(
            "SELECT id, note, file, page, location, length, vector FROM chunks WHERE model = ? AND length(vector) = ?",
            [.text(model.key), .integer(Int64(dimension * 4))]
        ) { row -> ChunkVector? in
            guard let data = row.blob(6), let vector = VectorMath.decode(data, dimension: dimension) else { return nil }
            return ChunkVector(
                chunk: row.int(0), note: row.optionalInt(1), file: row.optionalInt(2),
                page: row.optionalInt(3).map(Int.init),
                range: NSRange(location: Int(row.int(4)), length: Int(row.int(5))), vector: vector)
        }.compactMap { $0 }
    }

    /// A chunk's headings and text.
    func chunkText(_ id: Int64) throws -> (headings: [String], text: String)? {
        try database.first("SELECT headings, text FROM chunks WHERE id = ?", [.integer(id)]) { row in
            (SpaceIndex.headings(row.string(0)), row.string(1))
        }
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
        try database.run("DELETE FROM chunks WHERE note = ?", [id])
        try bumpChunksVersion()
        try database.run("DELETE FROM note_text WHERE rowid = ?", [id])
        try database.run("DELETE FROM note_trigram WHERE rowid = ?", [id])
        try database.run("DELETE FROM links WHERE source = ?", [id])
        try database.run("DELETE FROM tags WHERE note = ?", [id])
        try database.run("DELETE FROM tasks WHERE note = ?", [id])
    }

    // MARK: - Files

    /// Brings the rows of one origin in step with `files`: what is new is added, to be read; what changed size
    /// or date has its text thrown away, to be read again; what is gone is removed with its text. A file that
    /// only moved to another home folder, or whose name changed case, keeps its text. Returns how many rows
    /// changed.
    @discardableResult
    func syncFiles(_ files: [FileRecord], origin: FileOrigin) throws -> Int {
        var known: [String: KnownFile] = [:]
        for (pathKey, file) in try database.query(
            "SELECT path_key, id, path, byte_count, modified, folder_key, event FROM files WHERE origin = ?",
            [.integer(origin.rawValue)],
            { row in
                (
                    row.string(0),
                    KnownFile(
                        id: row.int(1), path: row.string(2), byteCount: row.int(3), modified: row.date(4),
                        folderKey: row.string(5), event: row.text(6))
                )
            })
        {
            known[pathKey] = file
        }
        var changed = 0
        var seen = Set<String>()
        for file in files {
            let pathKey = NameSanitizer.key(file.path.description)
            // Two names that differ only in case are one file to a Mac's disk: the first stays.
            guard seen.insert(pathKey).inserted else { continue }
            let folderKey = NameSanitizer.key(file.folder.description)
            let state = SpaceIndex.initialTextState(of: file)
            if let existing = known[pathKey] {
                if existing.byteCount == file.byteCount && SpaceIndex.sameMoment(existing.modified, file.modified) {
                    guard
                        existing.path != file.path.description || existing.folderKey != folderKey
                            || existing.event != file.event?.string
                    else { continue }
                    try database.run(
                        "UPDATE files SET path = ?, name_key = ?, folder_key = ?, event = ? WHERE id = ?",
                        [
                            .text(file.path.description), .text(NameSanitizer.key(file.path.name)),
                            .text(folderKey), .optional(file.event?.string), .integer(existing.id),
                        ])
                } else {
                    try removeText(ofFile: existing.id)
                    try database.run(
                        """
                        UPDATE files SET path = ?, name_key = ?, folder_key = ?, event = ?, modified = ?, byte_count = ?,
                            text_state = ?, attempts = 0 WHERE id = ?
                        """,
                        [
                            .text(file.path.description), .text(NameSanitizer.key(file.path.name)),
                            .text(folderKey), .optional(file.event?.string),
                            .optional(file.modified?.timeIntervalSince1970), .integer(file.byteCount),
                            .optional(state?.rawValue), .integer(existing.id),
                        ])
                }
            } else {
                try database.run(
                    """
                    INSERT INTO files (origin, path, path_key, name_key, folder_key, is_folder, modified, byte_count,
                        event, text_state, attempts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    """,
                    [
                        .integer(origin.rawValue), .text(file.path.description), .text(pathKey),
                        .text(NameSanitizer.key(file.path.name)), .text(folderKey), .bool(file.isFolder),
                        .optional(file.modified?.timeIntervalSince1970), .integer(file.byteCount),
                        .optional(file.event?.string), .optional(state?.rawValue),
                    ])
            }
            changed += 1
        }
        for (pathKey, existing) in known where !seen.contains(pathKey) {
            try removeText(ofFile: existing.id)
            try database.run("DELETE FROM files WHERE id = ?", [.integer(existing.id)])
            changed += 1
        }
        return changed
    }

    private struct KnownFile {
        var id: Int64
        var path: String
        var byteCount: Int64
        var modified: Date?
        var folderKey: String
        var event: String?
    }

    /// Removes the event files of every occurrence but those in `kept` (`EventLink.string`), with their text:
    /// what leaves a space when an event's home changes, before anything is added elsewhere.
    @discardableResult
    func removeEventFiles(keeping kept: Set<String>) throws -> Int {
        let rows = try database.query(
            "SELECT id, event FROM files WHERE origin = ?", [.integer(FileOrigin.event.rawValue)]
        ) { ($0.int(0), $0.text(1)) }
        var removed = 0
        for (id, event) in rows where !(event.map(kept.contains) ?? false) {
            try removeText(ofFile: id)
            try database.run("DELETE FROM files WHERE id = ?", [.integer(id)])
            removed += 1
        }
        return removed
    }

    /// The occurrences this index holds event files of (`EventLink.string`).
    func eventFileOccurrences() throws -> Set<String> {
        Set(
            try database.query(
                "SELECT DISTINCT event FROM files WHERE origin = ? AND event IS NOT NULL",
                [.integer(FileOrigin.event.rawValue)]
            ) { $0.string(0) })
    }

    /// The state a new or changed file's text starts in: nil (to be read) for a file whose text is read.
    private static func initialTextState(of file: FileRecord) -> FileTextState? {
        file.isFolder || FileTextKind(fileName: file.path.name) == nil ? FileTextState.none : nil
    }

    private static func sameMoment(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case (let first?, let second?): abs(first.timeIntervalSince(second)) < 0.001
        default: false
        }
    }

    /// The next file after `cursor` whose text waits to be read, the oldest row first. A file whose reading was started
    /// `FileTextLimits.maximumAttempts` times without finishing is marked as failed instead.
    func nextFileToRead(after cursor: Int64 = 0) throws -> FileToRead? {
        let attempts = SQLiteValue.integer(Int64(FileTextLimits.maximumAttempts))
        try database.run(
            "UPDATE files SET text_state = ? WHERE text_state IS NULL AND attempts >= ?",
            [.integer(FileTextState.failed.rawValue), attempts])
        while true {
            let found = try database.first(
                """
                SELECT id, origin, path, byte_count, modified FROM files
                WHERE text_state IS NULL AND attempts < ? AND is_folder = 0 AND id > ? ORDER BY id LIMIT 1
                """, [attempts, .integer(cursor)]
            ) { row in
                (
                    id: row.int(0), origin: FileOrigin(rawValue: row.int(1)), path: ItemPath(row.string(2)),
                    byteCount: row.int(3), modified: row.date(4)
                )
            }
            guard let found else { return nil }
            if let origin = found.origin, let path = found.path, let kind = FileTextKind(fileName: path.name) {
                return FileToRead(
                    id: found.id, origin: origin, path: path, kind: kind, byteCount: found.byteCount,
                    modified: found.modified)
            }
            try database.run(
                "UPDATE files SET text_state = ? WHERE id = ?",
                [.integer(FileTextState.none.rawValue), .integer(found.id)])
        }
    }

    /// Counts a reading as started, before it starts: one that never finishes (a crash, a quit) still counts.
    func startReading(_ file: FileToRead) throws {
        try database.run("UPDATE files SET attempts = attempts + 1 WHERE id = ?", [.integer(file.id)])
    }

    /// Stores what was read of a file, with its chunks, or, for nil, that it couldn't be read. False when the
    /// file changed or left since its reading began: what was read is then thrown away.
    @discardableResult
    func finishReading(_ file: FileToRead, text: ExtractedText?) throws -> Bool {
        let current = try database.first(
            "SELECT byte_count, modified FROM files WHERE id = ? AND text_state IS NULL", [.integer(file.id)]
        ) { (byteCount: $0.int(0), modified: $0.date(1)) }
        guard let current, current.byteCount == file.byteCount,
            SpaceIndex.sameMoment(current.modified, file.modified)
        else { return false }
        try removeText(ofFile: file.id)
        let state: FileTextState
        if let text, text.hasText {
            state = .read
            try storeText(text, ofFile: file.id)
        } else {
            state = text == nil ? .failed : .none
        }
        try database.run(
            "UPDATE files SET text_state = ?, attempts = 0 WHERE id = ?",
            [.integer(state.rawValue), .integer(file.id)])
        return true
    }

    private func storeText(_ text: ExtractedText, ofFile id: Int64) throws {
        let file = SQLiteValue.integer(id)
        for (index, page) in text.pages.enumerated() where page.contains(where: { !$0.isWhitespace }) {
            let number: SQLiteValue = text.isPaged ? .integer(Int64(index + 1)) : .null
            try database.run("INSERT INTO file_pages (file, page) VALUES (?, ?)", [file, number])
            let pageRow = SQLiteValue.integer(database.lastInsertedRowID)
            try database.run("INSERT INTO file_text (rowid, body) VALUES (?, ?)", [pageRow, .text(page)])
            try database.run("INSERT INTO file_trigram (rowid, body) VALUES (?, ?)", [pageRow, .text(page)])
        }
        for chunk in Chunker.chunks(ofPages: text.pages) {
            let page: SQLiteValue = text.isPaged ? .optional(chunk.page.map(Int64.init)) : .null
            try database.run(
                """
                INSERT INTO chunks (note, file, page, location, length, headings, text, script, model, vector)
                VALUES (NULL, ?, ?, ?, ?, '', ?, ?, NULL, NULL)
                """,
                [
                    file, page, .integer(Int64(chunk.range.location)), .integer(Int64(chunk.range.length)),
                    .text(chunk.text), .optional(Script.dominant(in: chunk.text)),
                ])
        }
        try bumpChunksVersion()
    }

    /// Removes a file's pages and chunks.
    private func removeText(ofFile id: Int64) throws {
        let file = SQLiteValue.integer(id)
        for page in try database.query("SELECT id FROM file_pages WHERE file = ?", [file], { $0.int(0) }) {
            try database.run("DELETE FROM file_text WHERE rowid = ?", [.integer(page)])
            try database.run("DELETE FROM file_trigram WHERE rowid = ?", [.integer(page)])
        }
        try database.run("DELETE FROM file_pages WHERE file = ?", [file])
        if try database.first("SELECT count(*) FROM chunks WHERE file = ?", [file], { $0.int(0) }) ?? 0 > 0 {
            try database.run("DELETE FROM chunks WHERE file = ?", [file])
            try bumpChunksVersion()
        }
    }

    /// How many files wait to be read.
    func filesWaiting() throws -> Int {
        let count = try database.first(
            "SELECT count(*) FROM files WHERE text_state IS NULL AND attempts < ?",
            [.integer(Int64(FileTextLimits.maximumAttempts))]
        ) { $0.int(0) }
        return Int(count ?? 0)
    }

    /// Empties the index. It fills again from the folder.
    func clear() throws {
        try database.transaction {
            for table in SpaceIndex.tables {
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
        if let event = filter.event {
            sql.append("n.event = ?")
            values.append(.text(event.string))
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

    /// The notes among `ids` that pass the filter, by row id.
    func noteRows(ids: [Int64], filter: IndexFilter) throws -> [Int64: IndexedNoteRow] {
        var result: [Int64: IndexedNoteRow] = [:]
        let (conditions, values) = SpaceIndex.conditions(for: filter)
        // In batches, under SQLite's limit on bound values.
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = ids[start..<min(start + 500, ids.count)]
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let condition = (["n.id IN (\(marks))"] + conditions).joined(separator: " AND ")
            let rows = try database.query(
                "SELECT n.id, \(SpaceIndex.noteColumns) FROM notes n WHERE \(condition)",
                batch.map { .integer($0) } + values
            ) { ($0.int(0), SpaceIndex.noteRow($0, from: 1)) }
            for (id, row) in rows {
                result[id] = row
            }
        }
        return result
    }

    /// A note's row id, by its path.
    func rowID(of path: ItemPath) throws -> Int64? {
        try database.first(
            "SELECT id FROM notes WHERE path_key = ?", [.text(NameSanitizer.key(path.description))]
        ) { $0.int(0) }
    }

    /// The notes a note links to and those that link to it, in this index, by row id.
    func linkedRows(around rowID: Int64) throws -> Set<Int64> {
        let outgoing = try database.query(
            "SELECT n.id FROM links l JOIN notes n ON n.title_key = l.title_key WHERE l.source = ?", [.integer(rowID)]
        ) { $0.int(0) }
        let incoming = try database.query(
            "SELECT l.source FROM notes n JOIN links l ON l.title_key = n.title_key WHERE n.id = ?", [.integer(rowID)]
        ) { $0.int(0) }
        return Set(outgoing + incoming)
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

    /// The title keys (file names, for attachments) that a note links to and that some other note in
    /// this database links to as well.
    func linkKeysShared(with path: ItemPath) throws -> Set<String> {
        let rows = try database.query(
            """
            SELECT DISTINCT l.title_key FROM links l JOIN notes n ON n.id = l.source
            WHERE n.path_key != ?1 AND l.title_key IN (
                SELECT mine.title_key FROM links mine JOIN notes me ON me.id = mine.source WHERE me.path_key = ?1)
            """, [.text(NameSanitizer.key(path.description))]
        ) { $0.string(0) }
        return Set(rows)
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
        try database.query(
            "SELECT path FROM files WHERE is_folder = 1 AND origin = ? ORDER BY path_key",
            [.integer(FileOrigin.folder.rawValue)]
        ) { ItemPath($0.string(0)) }.compactMap { $0 }
    }

    // MARK: - Reading files (retrieval)

    private static let fileColumns = "f.id, f.origin, f.path, f.event, f.modified"

    /// A file row from `fileColumns`, starting at `column`.
    private static func fileRow(_ row: SQLiteRow, from column: Int32 = 0) -> IndexedFileRow? {
        guard let origin = FileOrigin(rawValue: row.int(column + 1)), let path = ItemPath(row.string(column + 2))
        else { return nil }
        return IndexedFileRow(
            id: row.int(column), origin: origin, path: path,
            event: row.text(column + 3).flatMap(EventLink.init(string:)), modified: row.date(column + 4))
    }

    /// The SQL conditions of a filter on the `files` table as `f`, or nil when the filter leaves files out: a
    /// tag, a kind or an event narrows the search to notes.
    private static func fileConditions(for filter: IndexFilter) -> (sql: [String], values: [SQLiteValue])? {
        guard filter.tag == nil, filter.kind == nil, filter.event == nil else { return nil }
        var sql = ["f.is_folder = 0"]
        var values: [SQLiteValue] = []
        if let folder = filter.folder, !folder.isRoot {
            let key = NameSanitizer.key(folder.description)
            let prefix = key + "/"
            sql.append("(f.folder_key = ? OR substr(f.folder_key, 1, ?) = ?)")
            values += [.text(key), .integer(Int64(prefix.unicodeScalars.count)), .text(prefix)]
        }
        if let after = filter.modifiedAfter {
            sql.append("f.modified >= ?")
            values.append(.real(after.timeIntervalSince1970))
        }
        if let before = filter.modifiedBefore {
            sql.append("f.modified < ?")
            values.append(.real(before.timeIntervalSince1970))
        }
        return (sql, values)
    }

    /// Files with a page that has every word of `match` (an FTS5 query), the best page of each, best first.
    func searchFiles(match: String, filter: IndexFilter, limit: Int) throws -> [IndexedFileSearchRow] {
        guard let (conditions, values) = SpaceIndex.fileConditions(for: filter) else { return [] }
        let sql = """
            SELECT \(SpaceIndex.fileColumns), p.page, snippet(file_text, 0, char(2), char(3), '…', 18),
                bm25(file_text) AS rank
            FROM file_text JOIN file_pages p ON p.id = file_text.rowid JOIN files f ON f.id = p.file
            WHERE file_text MATCH ? AND \(conditions.joined(separator: " AND "))
            ORDER BY rank, f.modified DESC LIMIT ?
            """
        let rows = try database.query(sql, [.text(match)] + values + [.integer(Int64(limit * 4))]) { row in
            SpaceIndex.fileRow(row).map {
                IndexedFileSearchRow(
                    file: $0, page: row.optionalInt(5).map(Int.init), markedSnippet: row.string(6),
                    rank: row.double(7) ?? 0)
            }
        }
        return SpaceIndex.bestPerFile(rows.compactMap { $0 }, limit: limit)
    }

    /// Files with a page that contains every one of `terms`, also inside words and in text without spaces, newest
    /// first, with the page's text for a snippet.
    func searchFileSubstrings(_ terms: [String], filter: IndexFilter, limit: Int) throws -> [IndexedFileSearchRow] {
        guard !terms.isEmpty, let (conditions, values) = SpaceIndex.fileConditions(for: filter) else { return [] }
        let extra = conditions.map { " AND " + $0 }.joined()
        let limitValue = SQLiteValue.integer(Int64(limit * 4))
        let rows: [IndexedFileSearchRow?]
        if terms.allSatisfy({ $0.unicodeScalars.count >= 3 }) {
            let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(
                separator: " ")
            rows = try database.query(
                """
                SELECT \(SpaceIndex.fileColumns), p.page, file_text.body
                FROM file_trigram JOIN file_pages p ON p.id = file_trigram.rowid JOIN files f ON f.id = p.file
                    JOIN file_text ON file_text.rowid = p.id
                WHERE file_trigram MATCH ?\(extra)
                ORDER BY f.modified DESC LIMIT ?
                """, [.text(match)] + values + [limitValue]
            ) { row in
                SpaceIndex.fileRow(row).map {
                    IndexedFileSearchRow(
                        file: $0, page: row.optionalInt(5).map(Int.init), markedSnippet: row.string(6), rank: 0)
                }
            }
        } else {
            let contains = terms.map { _ in "instr(file_text.body, ?) > 0" }.joined(separator: " AND ")
            rows = try database.query(
                """
                SELECT \(SpaceIndex.fileColumns), p.page, file_text.body
                FROM file_text JOIN file_pages p ON p.id = file_text.rowid JOIN files f ON f.id = p.file
                WHERE \(contains)\(extra)
                ORDER BY f.modified DESC LIMIT ?
                """, terms.map { SQLiteValue.text($0) } + values + [limitValue]
            ) { row in
                SpaceIndex.fileRow(row).map {
                    IndexedFileSearchRow(
                        file: $0, page: row.optionalInt(5).map(Int.init), markedSnippet: row.string(6), rank: 0)
                }
            }
        }
        return SpaceIndex.bestPerFile(rows.compactMap { $0 }, limit: limit)
    }

    /// The first row of each file, in the order given.
    private static func bestPerFile(_ rows: [IndexedFileSearchRow], limit: Int) -> [IndexedFileSearchRow] {
        var seen = Set<Int64>()
        return Array(rows.filter { seen.insert($0.file.id).inserted }.prefix(limit))
    }

    /// Files whose name contains every one of `termKeys`, newest first.
    func files(named termKeys: [String], filter: IndexFilter, limit: Int) throws -> [IndexedFileRow] {
        guard !termKeys.isEmpty, let (conditions, values) = SpaceIndex.fileConditions(for: filter) else { return [] }
        let contains = termKeys.map { _ in "instr(f.name_key, ?) > 0" }
        return try database.query(
            """
            SELECT \(SpaceIndex.fileColumns) FROM files f WHERE \((contains + conditions).joined(separator: " AND "))
            ORDER BY f.modified DESC LIMIT ?
            """,
            termKeys.map { SQLiteValue.text($0) } + values + [.integer(Int64(limit))]
        ) { SpaceIndex.fileRow($0) }.compactMap { $0 }
    }

    /// The files among `ids` that pass the filter, by row id.
    func fileRows(ids: [Int64], filter: IndexFilter) throws -> [Int64: IndexedFileRow] {
        guard let (conditions, values) = SpaceIndex.fileConditions(for: filter) else { return [:] }
        var result: [Int64: IndexedFileRow] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = ids[start..<min(start + 500, ids.count)]
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let condition = (["f.id IN (\(marks))"] + conditions).joined(separator: " AND ")
            for row in try database.query(
                "SELECT \(SpaceIndex.fileColumns) FROM files f WHERE \(condition)", batch.map { .integer($0) } + values,
                { SpaceIndex.fileRow($0) })
            {
                if let row {
                    result[row.id] = row
                }
            }
        }
        return result
    }

    /// The files a note links to or embeds, by row id: matched by name, as links to attachments are.
    func linkedFileRows(of rowID: Int64) throws -> Set<Int64> {
        Set(
            try database.query(
                "SELECT DISTINCT f.id FROM links l JOIN files f ON f.name_key = l.title_key WHERE l.source = ?",
                [.integer(rowID)]
            ) { $0.int(0) })
    }

    /// How many items are directly inside the container's folder: notes, files and folders.
    func topLevelItemCount() throws -> Int {
        let notes = try database.first("SELECT count(*) FROM notes WHERE folder_key = ''") { $0.int(0) } ?? 0
        let files =
            try database.first(
                "SELECT count(*) FROM files WHERE origin = ? AND instr(path_key, '/') = 0",
                [.integer(FileOrigin.folder.rawValue)]
            ) { $0.int(0) } ?? 0
        return Int(notes + files)
    }
}
