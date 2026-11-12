import Foundation

/// A note as a query returns it.
public struct NoteHit: Hashable, Sendable {
    public var note: NoteRef
    public var title: String
    public var kind: NoteKind
    /// The first lines of the note as one line of plain text.
    public var preview: String
    public var modified: Date?
    public var created: Date?
}

/// Text with the stretches that matched a search.
public struct MarkedText: Hashable, Sendable {
    public var text: String
    /// In UTF-16 units of `text`.
    public var marks: [NSRange]

    public init(text: String, marks: [NSRange] = []) {
        self.text = text
        self.marks = marks
    }
}

public struct SearchQuery: Hashable, Sendable {
    /// The words to find. Empty means: everything the filters leave.
    public var text: String
    /// Only this space, when the workplace may read it.
    public var space: SpaceID?
    /// Only this folder and what is inside it. It is a folder of the workplace's own space, or of
    /// `space`.
    public var folder: ItemPath?
    public var tag: String?
    public var kind: NoteKind?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var limit: Int

    public init(
        text: String, space: SpaceID? = nil, folder: ItemPath? = nil, tag: String? = nil, kind: NoteKind? = nil,
        modifiedAfter: Date? = nil, modifiedBefore: Date? = nil, limit: Int = 50
    ) {
        self.text = text
        self.space = space
        self.folder = folder
        self.tag = tag
        self.kind = kind
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.limit = limit
    }
}

public struct SearchHit: Hashable, Sendable {
    public enum Item: Hashable, Sendable {
        case note(NoteRef)
        /// A file that isn't a note, found by its name.
        case file(Container, ItemPath)
    }

    public var item: Item
    public var title: String
    public var snippet: MarkedText
    /// The words that were looked for, so the note can be opened at the first of them.
    public var matchedTerms: [String]
    public var modified: Date?
}

/// A link to a note, from another note.
public struct Backlink: Hashable, Sendable {
    public var source: NoteHit
    /// Where the link is in the source's body, in UTF-16 units.
    public var range: NSRange
    /// The line the link is on.
    public var context: String
}

public struct TagCount: Hashable, Sendable {
    /// The tag as it was first written, without "#".
    public var tag: String
    /// How many notes have it.
    public var count: Int
}

public struct TaskHit: Hashable, Sendable {
    public var note: NoteHit
    public var text: String
    /// Where the task's box is in the note's body, in UTF-16 units.
    public var location: Int
}

/// A place something can be filed: a space, with its folders unless it is sealed.
public struct FilingDestination: Hashable, Sendable {
    public var space: SpaceID
    public var name: String
    public var description: String
    public var keywords: [String]
    public var isSealed: Bool
    /// The space's folders. Always empty for a sealed space: only its name, description and keywords
    /// are known outside it.
    public var folders: [ItemPath]
}

/// What links in one container can resolve to: the notes its reach allows, and the names of the spaces
/// in that reach.
public struct LinkContext: Sendable {
    public var catalog: TitleCatalog
    public var spaceNames: [SpaceID: String]

    public var resolver: LinkResolver {
        LinkResolver(catalog: catalog, spaceNames: spaceNames)
    }

    /// The context once `old` has become `new`, for `LinkRewriter`.
    public func moving(_ old: NoteRef, to new: NoteRef) -> LinkContext {
        LinkContext(catalog: catalog.replacing(old, with: new), spaceNames: spaceNames)
    }
}

/// The only way to read the index, and the choke point of sealing (docs/ARCHITECTURE.md).
///
/// Every query names the `Workplace` it is asked from. `Retrieval` builds the `Reach` itself, from the
/// spaces as they are at that moment, and opens only the databases that reach allows: a caller can't
/// hand it a wider one. Queries about one note use the note's own container as the workplace.
///
/// So a sealed space's notes, tags, tasks, file names and folder names come out only when the question
/// is asked from inside that space, and nothing else comes out there. `SealingLeakTests` plants marker
/// words and checks every query below; `scripts/check-rules.sh` fails when a query is missing there.
public actor Retrieval {
    private let indexDirectory: URL
    private let spaces: @Sendable () async -> [Space]
    private var indexes: [Container: SpaceIndex] = [:]
    private var contexts: [Set<Container>: CachedContext] = [:]

    private struct CachedContext {
        var versions: [Container: Int64]
        var context: LinkContext
    }

    /// - Parameters:
    ///   - indexDirectory: Where this library's databases are: `Index/<library id>` in Elenath's container.
    ///   - spaces: The library's spaces as they are now, sealed or not.
    public init(indexDirectory: URL, spaces: @escaping @Sendable () async -> [Space]) {
        self.indexDirectory = indexDirectory
        self.spaces = spaces
    }

    // MARK: - Search

    /// Notes that have every word of the query, best match first. Titles count most. The last word may
    /// be the start of a word, for search as you type. When words alone find little, text that merely
    /// contains the letters is found too, and files by their names.
    public func search(_ query: SearchQuery, from workplace: Workplace) async throws -> [SearchHit] {
        let terms = SearchTerms(query.text)
        var ranked: [(hit: SearchHit, rank: Double)] = []
        var loose: [SearchHit] = []
        var files: [SearchHit] = []
        for index in try await readable(from: workplace) {
            if let space = query.space, index.container != .space(space) {
                continue
            }
            var filter = IndexFilter(
                tag: query.tag, kind: query.kind, modifiedAfter: query.modifiedAfter,
                modifiedBefore: query.modifiedBefore)
            if let folder = query.folder, !folder.isRoot {
                // A folder belongs to one space: the one named, or the one the user is in.
                let owner: Container?
                if let space = query.space {
                    owner = .space(space)
                } else if case .space(let id) = workplace {
                    owner = .space(id)
                } else {
                    owner = workplace == .inbox ? .inbox : nil
                }
                guard index.container == owner else { continue }
                filter.folder = folder
            }
            guard let match = terms.fullTextQuery else {
                for row in try index.notes(filter: filter, limit: query.limit) {
                    let hit = Retrieval.hit(row, in: index.container)
                    ranked.append(
                        (
                            SearchHit(
                                item: .note(hit.note), title: hit.title, snippet: MarkedText(text: hit.preview),
                                matchedTerms: [], modified: hit.modified), 0
                        ))
                }
                continue
            }
            var found = Set<ItemPath>()
            for row in try index.search(match: match, filter: filter, limit: query.limit) {
                found.insert(row.note.path)
                ranked.append(
                    (
                        SearchHit(
                            item: .note(NoteRef(container: index.container, path: row.note.path)),
                            title: row.note.title, snippet: Retrieval.unmark(row.markedSnippet, terms: terms.words),
                            matchedTerms: terms.words, modified: row.note.modified), row.rank
                    ))
            }
            if found.count < query.limit {
                for (row, body) in try index.searchSubstrings(terms.words, filter: filter, limit: query.limit)
                where !found.contains(row.path) {
                    loose.append(
                        SearchHit(
                            item: .note(NoteRef(container: index.container, path: row.path)), title: row.title,
                            snippet: Retrieval.snippet(of: body, around: terms.words), matchedTerms: terms.words,
                            modified: row.modified))
                }
            }
            if query.tag == nil && query.kind == nil && filter.folder == nil {
                for file in try index.files(named: terms.words.map(NameSanitizer.key), limit: query.limit) {
                    files.append(
                        SearchHit(
                            item: .file(index.container, file.path), title: file.path.name,
                            snippet: MarkedText(text: file.path.folder.description), matchedTerms: terms.words,
                            modified: file.modified))
                }
            }
        }
        ranked.sort { first, second in
            if first.rank != second.rank {
                return first.rank < second.rank
            }
            return Retrieval.isNewer(first.hit.modified, than: second.hit.modified)
        }
        loose.sort { Retrieval.isNewer($0.modified, than: $1.modified) }
        files.sort { Retrieval.isNewer($0.modified, than: $1.modified) }
        return Array((ranked.map(\.hit) + loose + files).prefix(query.limit))
    }

    /// Notes whose title contains `text`, those that start with it first: for "[[" and for jumping to a
    /// note. Empty text gives the most recent notes.
    public func titles(matching text: String, from workplace: Workplace, limit: Int) async throws -> [NoteHit] {
        let key = NameSanitizer.key(text.trimmingCharacters(in: .whitespaces))
        var hits: [NoteHit] = []
        for index in try await readable(from: workplace) {
            hits += try index.titles(containing: key, limit: limit).map { Retrieval.hit($0, in: index.container) }
        }
        hits.sort { first, second in
            let firstStarts = NameSanitizer.key(first.title).hasPrefix(key)
            let secondStarts = NameSanitizer.key(second.title).hasPrefix(key)
            if firstStarts != secondStarts {
                return firstStarts
            }
            return Retrieval.isNewer(first.modified, than: second.modified)
        }
        return Array(hits.prefix(limit))
    }

    // MARK: - Lists

    /// The notes directly inside a folder of a space or of the Inbox, by title.
    public func notes(in folder: ItemPath, of container: Container) async throws -> [NoteHit] {
        var hits: [NoteHit] = []
        for index in try await readable(from: Reach.workplace(of: container)) where index.container == container {
            hits += try index.notes(inFolder: folder).map { Retrieval.hit($0, in: container) }
        }
        return hits
    }

    public func recentNotes(from workplace: Workplace, limit: Int) async throws -> [NoteHit] {
        var hits: [NoteHit] = []
        for index in try await readable(from: workplace) {
            hits += try index.notes(filter: IndexFilter(), limit: limit).map { Retrieval.hit($0, in: index.container) }
        }
        hits.sort { Retrieval.isNewer($0.modified, than: $1.modified) }
        return Array(hits.prefix(limit))
    }

    /// Every tag the workplace may see, with how many notes have it, by name.
    public func tags(from workplace: Workplace) async throws -> [TagCount] {
        var counts: [String: TagCount] = [:]
        for index in try await readable(from: workplace) {
            for (key, tag, count) in try index.tagCounts() {
                counts[key, default: TagCount(tag: tag, count: 0)].count += count
            }
        }
        return counts.values.sorted {
            $0.tag.compare($1.tag, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
    }

    /// The notes with a tag, or with one nested under it ("uni" finds "uni/physics"), newest first.
    public func notes(tagged tag: String, from workplace: Workplace) async throws -> [NoteHit] {
        var hits: [NoteHit] = []
        for index in try await readable(from: workplace) {
            hits += try index.notes(filter: IndexFilter(tag: tag), limit: 10_000).map {
                Retrieval.hit($0, in: index.container)
            }
        }
        hits.sort { Retrieval.isNewer($0.modified, than: $1.modified) }
        return hits
    }

    /// Tasks that aren't done, those in the most recently changed notes first.
    public func openTasks(from workplace: Workplace, limit: Int) async throws -> [TaskHit] {
        var hits: [TaskHit] = []
        for index in try await readable(from: workplace) {
            hits += try index.openTasks(limit: limit).map {
                TaskHit(note: Retrieval.hit($0.note, in: index.container), text: $0.text, location: $0.location)
            }
        }
        // A stable sort keeps the tasks of one note in their order.
        let ordered = hits.enumerated().sorted { first, second in
            if first.element.note.modified != second.element.note.modified {
                return Retrieval.isNewer(first.element.note.modified, than: second.element.note.modified)
            }
            return first.offset < second.offset
        }
        return Array(ordered.map(\.element).prefix(limit))
    }

    // MARK: - Links

    /// What links written in a container can resolve to. Use it to resolve many links at once, and with
    /// `LinkRewriter` when a note is renamed or moved.
    public func linkContext(for container: Container) async throws -> LinkContext {
        let allSpaces = await spaces()
        let readable = try self.readable(from: Reach.workplace(of: container), spaces: allSpaces)
        var versions: [Container: Int64] = [:]
        for index in readable {
            versions[index.container] = try index.dataVersion()
        }
        var names: [SpaceID: String] = [:]
        for space in allSpaces where versions[.space(space.id)] != nil {
            names[space.id] = space.name
        }
        let key = Set(versions.keys)
        if let cached = contexts[key], cached.versions == versions, cached.context.spaceNames == names {
            return cached.context
        }
        var catalog = TitleCatalog()
        for index in readable {
            for path in try index.allNotePaths() {
                catalog.insert(NoteRef(container: index.container, path: path))
            }
        }
        let context = LinkContext(catalog: catalog, spaceNames: names)
        contexts[key] = CachedContext(versions: versions, context: context)
        return context
    }

    /// The note a link written in `source` points at.
    public func resolve(_ link: WikiLink, from source: NoteRef) async throws -> LinkResolution {
        try await linkContext(for: source.container).resolver.resolve(link, from: source)
    }

    /// The links that point at a note, from the notes its own container may read.
    public func backlinks(to note: NoteRef) async throws -> [Backlink] {
        let resolver = try await linkContext(for: note.container).resolver
        var result: [Backlink] = []
        for index in try await readable(from: Reach.workplace(of: note.container)) {
            for row in try index.links(toTitleKey: NameSanitizer.key(note.title)) {
                let source = NoteRef(container: index.container, path: row.source.path)
                guard source != note else { continue }
                let resolution: LinkResolution
                if row.link.isMarkdown {
                    resolution = resolver.resolve(markdownDestination: row.link.target, from: source)
                } else {
                    let link = WikiLink(target: row.link.target, heading: row.link.heading, isEmbed: row.link.isEmbed)
                    resolution = resolver.resolve(link, from: source)
                }
                guard resolution == .resolved(note) else { continue }
                result.append(
                    Backlink(
                        source: Retrieval.hit(row.source, in: index.container),
                        range: NSRange(location: row.link.location, length: row.link.length),
                        context: row.link.context))
            }
        }
        return result
    }

    /// The notes that link to a note, each once: the ones `LinkRewriter` has to look at when it moves.
    public func linkingNotes(to note: NoteRef) async throws -> [NoteRef] {
        var seen = Set<NoteRef>()
        return try await backlinks(to: note).map(\.source.note).filter { seen.insert($0).inserted }
    }

    // MARK: - One note

    /// A note's text as it was last indexed, for anything other than showing the note to the user: a
    /// summary, related notes, whatever is put in front of the model. Nil for a note the workplace may
    /// not read.
    public func text(of note: NoteRef, from workplace: Workplace) async throws -> String? {
        for index in try await readable(from: workplace) where index.container == note.container {
            return try index.body(of: note.path)
        }
        return nil
    }

    /// What the index holds about one note, asked from the note's own container.
    public func note(_ note: NoteRef) async throws -> NoteHit? {
        for index in try await readable(from: Reach.workplace(of: note.container))
        where index.container == note.container {
            return try index.note(at: note.path).map { Retrieval.hit($0, in: note.container) }
        }
        return nil
    }

    /// Whether the note is a duplicated file: an older note beside it in the same space carries the same
    /// `id`. The next save gives it an id of its own.
    public func hasDuplicatedIdentity(_ note: NoteRef) async throws -> Bool {
        for index in try await readable(from: Reach.workplace(of: note.container))
        where index.container == note.container {
            return try index.isLaterDuplicate(note.path)
        }
        return false
    }

    // MARK: - Filing

    /// How many items wait in the Inbox. A number, never content, so it may be shown anywhere.
    public func inboxCount() async throws -> Int {
        try index(for: .inbox).topLevelItemCount()
    }

    /// Where something can be filed: every space by name, description and keywords, sealed ones too.
    /// This is the one crossing of a seal, and it carries no content: a sealed space gives no folder
    /// names.
    public func filingDestinations() async -> [FilingDestination] {
        var destinations: [FilingDestination] = []
        for space in await spaces() {
            var folders: [ItemPath] = []
            if !space.isSealed {
                folders = (try? index(for: .space(space.id)).folders()) ?? []
            }
            destinations.append(
                FilingDestination(
                    space: space.id, name: space.name, description: space.description, keywords: space.keywords,
                    isSealed: space.isSealed, folders: folders))
        }
        return destinations
    }

    // MARK: - Private: the choke point

    /// The databases a workplace may read, spaces in sidebar order, then the Inbox. Every query that
    /// returns content gets its databases here and nowhere else.
    private func readable(from workplace: Workplace) async throws -> [SpaceIndex] {
        try readable(from: workplace, spaces: await spaces())
    }

    private func readable(from workplace: Workplace, spaces: [Space]) throws -> [SpaceIndex] {
        let reach = Reach(workplace: workplace, spaces: spaces)
        var result: [SpaceIndex] = []
        for space in spaces where reach.allows(.space(space.id)) {
            result.append(try index(for: .space(space.id)))
        }
        if reach.allows(.inbox) {
            result.append(try index(for: .inbox))
        }
        return result
    }

    private func index(for container: Container) throws -> SpaceIndex {
        if let index = indexes[container] {
            return index
        }
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true, attributes: nil)
        let url = indexDirectory.appending(component: SpaceIndex.fileName(for: container), directoryHint: .notDirectory)
        let index = try SpaceIndex(url: url, container: container)
        indexes[container] = index
        return index
    }

    // MARK: - Private: results

    private static func hit(_ row: IndexedNoteRow, in container: Container) -> NoteHit {
        NoteHit(
            note: NoteRef(container: container, path: row.path), title: row.title, kind: row.kind,
            preview: row.preview, modified: row.modified, created: row.created)
    }

    private static func isNewer(_ first: Date?, than second: Date?) -> Bool {
        (first ?? .distantPast) > (second ?? .distantPast)
    }

    /// Turns the control characters SQLite puts around matches into ranges, and line breaks into spaces.
    ///
    /// SQLite marks whole words. In text written without spaces a "word" can be a whole sentence, so a
    /// mark is narrowed to the term itself when the term is in such a script.
    private static func unmark(_ marked: String, terms: [String]) -> MarkedText {
        var text = String.UnicodeScalarView()
        var marks: [NSRange] = []
        var length = 0
        var markStart: Int?
        for scalar in marked.unicodeScalars {
            switch scalar {
            case "\u{2}":
                markStart = length
            case "\u{3}":
                if let start = markStart, length > start {
                    marks.append(NSRange(location: start, length: length - start))
                }
                markStart = nil
            case "\n", "\r", "\t":
                text.append(" ")
                length += 1
            default:
                text.append(scalar)
                length += scalar.utf16.count
            }
        }
        let result = String(text)
        let unspaced = terms.filter { $0.unicodeScalars.contains { $0.value >= 0x2E80 } }
        guard !unspaced.isEmpty else { return MarkedText(text: result, marks: marks) }
        let whole = result as NSString
        let narrowed = marks.map { mark -> NSRange in
            for term in unspaced {
                let found = whole.range(of: term, options: [.caseInsensitive], range: mark)
                if found.location != NSNotFound {
                    return found
                }
            }
            return mark
        }
        return MarkedText(text: result, marks: narrowed)
    }

    /// A stretch of `body` around the first of `terms`, with every term in it marked.
    private static func snippet(of body: String, around terms: [String]) -> MarkedText {
        let flat = body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let first = terms.compactMap { flat.range(of: $0, options: options)?.lowerBound }.min() ?? flat.startIndex
        let start = flat.index(first, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(first, offsetBy: 140, limitedBy: flat.endIndex) ?? flat.endIndex
        var text = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flat.startIndex {
            text = "…" + text
        }
        if end < flat.endIndex {
            text += "…"
        }
        var marks: [NSRange] = []
        let whole = text as NSString
        for term in terms {
            var searchRange = NSRange(location: 0, length: whole.length)
            while searchRange.length > 0 {
                let found = whole.range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                marks.append(found)
                searchRange = NSRange(location: NSMaxRange(found), length: whole.length - NSMaxRange(found))
            }
        }
        return MarkedText(text: text, marks: marks.sorted { $0.location < $1.location })
    }
}

/// The words of a search, and the full-text query made of them.
struct SearchTerms {
    /// What was typed, split at spaces, without quotes and without anything that has no letter or digit.
    var words: [String]

    init(_ text: String) {
        words = text.split(whereSeparator: \.isWhitespace).compactMap { part in
            let word = part.replacingOccurrences(of: "\"", with: "")
            return word.contains(where: { $0.isLetter || $0.isNumber }) ? word : nil
        }
    }

    /// Every word must match, the last one as the start of a word. Nil when there are no words.
    var fullTextQuery: String? {
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"" }.joined(separator: " ") + "*"
    }
}
