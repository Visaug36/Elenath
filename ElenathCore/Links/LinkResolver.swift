import Foundation

/// What a link points at.
public enum LinkResolution: Hashable, Sendable {
    case resolved(NoteRef)
    /// Several notes fit and nothing tells them apart.
    case ambiguous([NoteRef])
    case unresolved
}

/// The notes a link may point to, by title.
///
/// A catalog holds the notes of the containers one `Reach` allows and nothing else. That is how sealing
/// holds for links: a resolver can't find a note that isn't in its catalog.
public struct TitleCatalog: Sendable {
    struct Entry: Hashable, Sendable {
        var ref: NoteRef
        /// The keys of the folders the note is in, outermost first.
        var folderKeys: [String]
    }

    private var entries: [String: [Entry]] = [:]
    public private(set) var count = 0

    public init(notes: some Sequence<NoteRef> = []) {
        for note in notes {
            insert(note)
        }
    }

    public mutating func insert(_ note: NoteRef) {
        let entry = Entry(ref: note, folderKeys: note.path.folder.components.map(NameSanitizer.key))
        let key = NameSanitizer.key(note.title)
        guard entries[key]?.contains(where: { $0.ref == note }) != true else { return }
        entries[key, default: []].append(entry)
        count += 1
    }

    public mutating func remove(_ note: NoteRef) {
        let key = NameSanitizer.key(note.title)
        guard var list = entries[key], let index = list.firstIndex(where: { $0.ref == note }) else { return }
        list.remove(at: index)
        entries[key] = list.isEmpty ? nil : list
        count -= 1
    }

    /// The catalog as it is once `old` has become `new`: after a rename or a move.
    public func replacing(_ old: NoteRef, with new: NoteRef) -> TitleCatalog {
        var copy = self
        copy.remove(old)
        copy.insert(new)
        return copy
    }

    /// Every note in the catalog, in no particular order.
    public var notes: [NoteRef] {
        entries.values.flatMap { $0.map(\.ref) }
    }

    public func contains(_ note: NoteRef) -> Bool {
        entries[NameSanitizer.key(note.title)]?.contains { $0.ref == note } ?? false
    }

    /// The notes with this title, compared as names are.
    func notes(titled title: String) -> [Entry] {
        entries[NameSanitizer.key(title)] ?? []
    }
}

/// Resolves links the way docs/FORMAT.md describes ("Links"). It is pure: it sees only its catalog.
public struct LinkResolver: Sendable {
    private let catalog: TitleCatalog
    private let spaceNames: [SpaceID: String]
    private let spacesByName: [String: SpaceID]

    /// - Parameters:
    ///   - catalog: The notes a link may point to: those of one `Reach`.
    ///   - spaceNames: The names of the spaces in that reach, for `[[Space/Title]]`.
    public init(catalog: TitleCatalog, spaceNames: [SpaceID: String]) {
        self.catalog = catalog
        self.spaceNames = spaceNames
        var byName: [String: SpaceID] = [:]
        for (id, name) in spaceNames {
            byName[NameSanitizer.key(name)] = id
        }
        spacesByName = byName
    }

    /// The note a wiki link in `source` points at.
    public func resolve(_ link: WikiLink, from source: NoteRef) -> LinkResolution {
        if link.target.isEmpty {
            return .resolved(source)
        }
        let result = resolve(components: link.targetComponents, from: source)
        // "C# notes" reads as the note "C" and the heading " notes". If that leads nowhere, the whole
        // text may be a title.
        if result == .unresolved, let heading = link.heading {
            var whole = link
            whole.target = link.target + "#" + heading
            whole.heading = nil
            return resolve(components: whole.targetComponents, from: source)
        }
        return result
    }

    /// The note a Markdown link's destination points at: a path from the linking note's folder, such as
    /// "Other%20note.md" or "../Physics/Lecture%207.md". Anything with a scheme is not a note.
    public func resolve(markdownDestination destination: String, from source: NoteRef) -> LinkResolution {
        guard let path = LinkResolver.notePath(forDestination: destination, from: source) else { return .unresolved }
        let wanted = path.components.map(NameSanitizer.key)
        for entry in catalog.notes(titled: path.title) where entry.ref.container == source.container {
            if entry.ref.path.components.map(NameSanitizer.key) == wanted {
                return .resolved(entry.ref)
            }
        }
        // A destination without an extension may mean the note of that name.
        if !ItemPath.isNoteFileName(path.name), let withExtension = path.folder.appending(path.name + ".md") {
            let alternative = withExtension.components.map(NameSanitizer.key)
            for entry in catalog.notes(titled: withExtension.title) where entry.ref.container == source.container {
                if entry.ref.path.components.map(NameSanitizer.key) == alternative {
                    return .resolved(entry.ref)
                }
            }
        }
        return .unresolved
    }

    /// The shortest target that resolves to `note` when written in `source`: "Title", then
    /// "Folder/Title", then "Space/Title", each with as many folders as it takes.
    public func shortestTarget(for note: NoteRef, from source: NoteRef) -> String {
        let title = note.title
        let folders = note.path.folder.components
        var candidates = [title]
        if !folders.isEmpty {
            for depth in 1...folders.count {
                candidates.append((folders.suffix(depth) + [title]).joined(separator: "/"))
            }
        }
        if case .space(let id) = note.container, let spaceName = spaceNames[id] {
            for depth in 0...folders.count {
                candidates.append(([spaceName] + folders.suffix(depth) + [title]).joined(separator: "/"))
            }
        }
        for candidate in candidates
        where resolve(WikiLink(target: candidate), from: source) == .resolved(note) {
            return candidate
        }
        return candidates.last ?? title
    }

    /// The destination of a Markdown link from `source` to `note`: the path between their folders,
    /// percent-encoded. Nil when they are not in the same space.
    public func markdownDestination(for note: NoteRef, from source: NoteRef) -> String? {
        guard note.container == source.container else { return nil }
        let from = source.path.folder.components
        let to = note.path.components
        var shared = 0
        while shared < from.count, shared < to.count - 1,
            NameSanitizer.key(from[shared]) == NameSanitizer.key(to[shared])
        {
            shared += 1
        }
        let parts = Array(repeating: "..", count: from.count - shared) + to[shared...]
        return parts.map(LinkResolver.percentEncoded).joined(separator: "/")
    }

    // MARK: - Private

    private func resolve(components: [String], from source: NoteRef) -> LinkResolution {
        guard let title = components.last else { return .unresolved }
        let folders = components.dropLast().map(NameSanitizer.key)
        let named = catalog.notes(titled: title)

        // 1. Inside the linking note's own space (or the Inbox).
        let own = named.filter { $0.ref.container == source.container && $0.folderKeys.ends(with: folders) }
        if !own.isEmpty {
            return LinkResolver.pick(own, preferring: folders.isEmpty ? source.path.folder : nil)
        }

        if folders.isEmpty {
            // 2. A title that the linking note's space doesn't have: one note elsewhere, if exactly one.
            let elsewhere = named.filter { $0.ref.container != source.container }
            switch elsewhere.count {
            case 0: return .unresolved
            case 1: return .resolved(elsewhere[0].ref)
            default: return .ambiguous(elsewhere.map(\.ref).sorted(by: LinkResolver.comesBefore))
            }
        }

        // 3. A path from the library folder: the first part names a space.
        guard let spaceID = spacesByName[folders[0]] else { return .unresolved }
        let rest = Array(folders.dropFirst())
        let inSpace = named.filter { $0.ref.container == .space(spaceID) && $0.folderKeys.ends(with: rest) }
        return inSpace.isEmpty ? .unresolved : LinkResolver.pick(inSpace, preferring: nil)
    }

    /// One of several notes that fit: the one in `folder` if there is exactly one, else the one with the
    /// shortest path. A tie is ambiguous.
    private static func pick(_ entries: [TitleCatalog.Entry], preferring folder: ItemPath?) -> LinkResolution {
        if entries.count == 1 {
            return .resolved(entries[0].ref)
        }
        if let folder {
            let folderKeys = folder.components.map(NameSanitizer.key)
            let beside = entries.filter { $0.folderKeys == folderKeys }
            if beside.count == 1 {
                return .resolved(beside[0].ref)
            }
        }
        let shortest = entries.map(\.folderKeys.count).min() ?? 0
        let nearest = entries.filter { $0.folderKeys.count == shortest }
        if nearest.count == 1 {
            return .resolved(nearest[0].ref)
        }
        return .ambiguous(nearest.map(\.ref).sorted(by: comesBefore))
    }

    private static func comesBefore(_ first: NoteRef, _ second: NoteRef) -> Bool {
        first.path.description < second.path.description
    }

    /// The path a Markdown destination names, from the linking note's folder. Nil for a URL with a
    /// scheme, an absolute path, or a path that leaves the space.
    private static func notePath(forDestination destination: String, from source: NoteRef) -> ItemPath? {
        var text = destination.trimmingCharacters(in: .whitespaces)
        if let hash = text.firstIndex(of: "#") {
            text = String(text[..<hash])
        }
        guard !text.isEmpty, !text.hasPrefix("/") else { return nil }
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            return nil
        }
        guard let decoded = text.removingPercentEncoding else { return nil }
        var components = source.path.folder.components
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(part))
            }
        }
        return ItemPath(components.joined(separator: "/"))
    }

    private static func percentEncoded(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()[]<>/%#?")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}

extension Array where Element: Equatable {
    /// Whether the array ends with `suffix`. Every array ends with the empty one.
    fileprivate func ends(with suffix: [Element]) -> Bool {
        suffix.count <= count && Array(self.suffix(suffix.count)) == suffix
    }
}
