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

    /// The context once a note has left it: moved to where these links can't reach, or deleted.
    public func removing(_ note: NoteRef) -> LinkContext {
        var copy = self
        copy.catalog.remove(note)
        return copy
    }

    /// The context once a space has another name, for links written as `[[Space/Title]]`.
    public func renaming(_ space: SpaceID, to name: String) -> LinkContext {
        var copy = self
        if copy.spaceNames[space] != nil {
            copy.spaceNames[space] = name
        }
        return copy
    }
}

/// The only way to read the index, and the choke point of sealing (docs/ARCHITECTURE.md).
///
/// Every query names the `Workplace` it is asked from. `Retrieval` builds the `Reach` itself, from the
/// spaces as they are at that moment, and opens only the databases that reach allows: a caller can't
/// hand it a wider one. Queries about one note use the note's own container as the workplace.
///
/// So a sealed space's notes, tags, tasks, file names and folder names come out only when the question
/// is asked from inside that space, and nothing else comes out there. Every query takes the workplace it
/// is asked from, also those about one note: asked about a note the workplace may not read, a query
/// answers with nothing, so a caller that passes the wrong note can't reach across a seal. `SealingLeakTests` plants marker
/// words and checks every query below; `scripts/check-rules.sh` fails when a query is missing there.
public actor Retrieval {
    private static let log = CoreLog(category: "Retrieval")
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
                for (row, body) in try index.searchSubstrings(terms.substringWords, filter: filter, limit: query.limit)
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
    public func notes(
        in folder: ItemPath, of container: Container, from workplace: Workplace
    ) async throws
        -> [NoteHit]
    {
        var hits: [NoteHit] = []
        for index in try await readable(from: workplace) where index.container == container {
            hits += try index.notes(inFolder: folder).map { Retrieval.hit($0, in: container) }
        }
        return hits
    }

    /// The folders of a space or of the Inbox, by path, for a workplace that may read it. Nothing for
    /// any other: a sealed space's folder names stay inside it.
    public func folders(of container: Container, from workplace: Workplace) async throws -> [ItemPath] {
        for index in try await readable(from: workplace) where index.container == container {
            return try index.folders()
        }
        return []
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

    /// The notes for one event occurrence (front matter `event`), newest first: "Notes for this lecture".
    /// Like every query, only from the containers the workplace may read; the calendar shows them only
    /// where the event's own content may be read (`CalendarReach.mayReadContent(of:)`).
    public func notes(linkedTo event: EventLink, from workplace: Workplace) async throws -> [NoteHit] {
        var hits: [NoteHit] = []
        for index in try await readable(from: workplace) {
            hits += try index.notes(filter: IndexFilter(event: event), limit: 1_000).map {
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
    /// `LinkRewriter` when a note is renamed or moved. Empty for a container the workplace may not read.
    public func linkContext(for container: Container, from workplace: Workplace) async throws -> LinkContext {
        let allSpaces = await spaces()
        guard Reach(workplace: workplace, spaces: allSpaces).allows(container) else {
            return LinkContext(catalog: TitleCatalog(), spaceNames: [:])
        }
        let readable = try self.readable(from: workplace, spaces: allSpaces)
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
    public func resolve(
        _ link: WikiLink, in source: NoteRef, from workplace: Workplace
    ) async throws
        -> LinkResolution
    {
        try await linkContext(for: source.container, from: workplace).resolver.resolve(link, from: source)
    }

    /// The links that point at a note, from the notes its own container may read.
    public func backlinks(to note: NoteRef, from workplace: Workplace) async throws -> [Backlink] {
        guard await allows(note.container, from: workplace) else { return [] }
        let resolver = try await linkContext(for: note.container, from: workplace).resolver
        var result: [Backlink] = []
        for index in try await readable(from: workplace) {
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

    /// The notes with a link whose target starts with a folder or space name, as `[[Uni/Reading list]]`
    /// starts with "Uni": the ones to look at when that folder or space is renamed.
    public func notesLinking(throughFolderNamed name: String, from workplace: Workplace) async throws -> [NoteRef] {
        var result: [NoteRef] = []
        for index in try await readable(from: workplace) {
            result += try index.noteLinking(throughFolderNamed: name).map {
                NoteRef(container: index.container, path: $0)
            }
        }
        return result
    }

    /// The files a note refers to that other notes in its space (or the Inbox) refer to as well, by
    /// name key: what moving the note must copy rather than move.
    public func attachmentNamesShared(by note: NoteRef, from workplace: Workplace) async throws -> Set<String> {
        for index in try await readable(from: workplace) where index.container == note.container {
            return try index.linkKeysShared(with: note.path)
        }
        return []
    }

    /// The notes that link to a note, each once: the ones `LinkRewriter` has to look at when it moves.
    public func linkingNotes(to note: NoteRef, from workplace: Workplace) async throws -> [NoteRef] {
        var seen = Set<NoteRef>()
        return try await backlinks(to: note, from: workplace).map(\.source.note).filter { seen.insert($0).inserted }
    }

    /// The notes whose links pointed at notes that have since been renamed or moved outside Elenath (in
    /// Finder, or by another app), each once: what `LinkRewriter` repairs once the index has followed the
    /// moves. The links are judged as they were, with every moved note back in its old place, from each
    /// moved note's own container. A moved note that links to itself or to another moved note is named
    /// by its old place, as `LinkRewriter` expects. Moves in a container the workplace may not read are
    /// left out.
    public func linkingNotes(toMoved moves: [NoteMove], from workplace: Workplace) async throws -> [NoteRef] {
        var seen = Set<NoteRef>()
        var result: [NoteRef] = []
        for (container, group) in Dictionary(grouping: moves, by: \.from.container)
        where group.allSatisfy({ $0.to.container == container }) {
            guard await allows(container, from: workplace) else { continue }
            var context = try await linkContext(for: container, from: workplace)
            for move in group {
                context = context.moving(move.to, to: move.from)
            }
            let resolver = context.resolver
            let old = Set(group.map(\.from))
            let oldPlace = Dictionary(group.map { ($0.to, $0.from) }, uniquingKeysWith: { first, _ in first })
            let keys = Set(group.map { NameSanitizer.key($0.from.title) })
            for index in try await readable(from: workplace) {
                for key in keys.sorted() {
                    for row in try index.links(toTitleKey: key) {
                        let current = NoteRef(container: index.container, path: row.source.path)
                        let source = oldPlace[current] ?? current
                        let resolution: LinkResolution
                        if row.link.isMarkdown {
                            resolution = resolver.resolve(markdownDestination: row.link.target, from: source)
                        } else {
                            let link = WikiLink(
                                target: row.link.target, heading: row.link.heading, isEmbed: row.link.isEmbed)
                            resolution = resolver.resolve(link, from: source)
                        }
                        guard case .resolved(let target) = resolution, old.contains(target) else { continue }
                        if seen.insert(source).inserted {
                            result.append(source)
                        }
                    }
                }
            }
        }
        return result
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

    /// What the index holds about one note.
    public func note(_ note: NoteRef, from workplace: Workplace) async throws -> NoteHit? {
        for index in try await readable(from: workplace) where index.container == note.container {
            return try index.note(at: note.path).map { Retrieval.hit($0, in: note.container) }
        }
        return nil
    }

    /// Whether the note is a duplicated file: an older note beside it in the same space carries the same
    /// `id`. The next save gives it an id of its own.
    public func hasDuplicatedIdentity(_ note: NoteRef, from workplace: Workplace) async throws -> Bool {
        for index in try await readable(from: workplace) where index.container == note.container {
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

    /// Whether a workplace may read a container, with the spaces as they are now.
    private func allows(_ container: Container, from workplace: Workplace) async -> Bool {
        Reach(workplace: workplace, spaces: await spaces()).allows(container)
    }

    /// A database that can't be opened is left out, so one damaged space doesn't empty every search; the
    /// indexer replaces it at its next pass.
    private func readable(from workplace: Workplace, spaces: [Space]) throws -> [SpaceIndex] {
        let reach = Reach(workplace: workplace, spaces: spaces)
        let containers = spaces.map { Container.space($0.id) } + [.inbox]
        var result: [SpaceIndex] = []
        for container in containers where reach.allows(container) {
            do {
                result.append(try index(for: container))
            } catch {
                Retrieval.log.error("Could not open an index", private: String(describing: error))
            }
        }
        return result
    }

    private func index(for container: Container) throws -> SpaceIndex {
        let url = indexDirectory.appending(component: SpaceIndex.fileName(for: container), directoryHint: .notDirectory)
        // The indexer replaces a damaged database with a new file; a handle on the old one is let go.
        if let index = indexes[container], index.isStillOpen(at: url) {
            return index
        }
        indexes[container] = nil
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true, attributes: nil)
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
    /// Words after this many are left out. A longer search is pasted text, and every word makes the
    /// full-text query bigger: a thousand would be more than SQLite takes.
    static let maximumWords = 32

    /// What was typed, split at spaces, without quotes and control characters, and without anything that
    /// has no letter or digit.
    var words: [String]

    init(_ text: String) {
        var words: [String] = []
        for part in text.split(whereSeparator: \.isWhitespace) {
            var kept = String.UnicodeScalarView()
            kept.append(
                contentsOf: part.unicodeScalars.filter { $0 != "\"" && $0.properties.generalCategory != .control })
            let word = String(kept)
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            words.append(word)
            if words.count == SearchTerms.maximumWords {
                break
            }
        }
        self.words = words
    }

    /// Every word must match, the last one as the start of a word, unless it is a single character: as
    /// the start of a word, one letter matches nearly every note, and the search would be slow for nothing.
    /// Nil when there are no words.
    var fullTextQuery: String? {
        guard let last = words.last else { return nil }
        let prefix = last.unicodeScalars.count > 1 ? "*" : ""
        return words.map { "\"\($0)\"" }.joined(separator: " ") + prefix
    }

    /// The words to look for inside other words and in text without spaces: those of three characters and
    /// more, and shorter ones in scripts written without spaces. One or two letters of a language with
    /// spaces are inside too many words to mean anything, and finding them means reading every note.
    var substringWords: [String] {
        words.filter { $0.unicodeScalars.count >= 3 || $0.unicodeScalars.contains { $0.value >= 0x2E80 } }
    }
}
