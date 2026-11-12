import Foundation

/// The library as `LibraryCatalog.open()` found it.
public struct LibrarySnapshot: Sendable {
    public var id: LibraryID
    /// The spaces in sidebar order.
    public var spaces: [Space]
    /// library.json was written by a newer Elenath, so nothing in the library is changed.
    public var isReadOnly: Bool
    /// What was restored from a backup or a safety copy while opening. The app tells the user.
    public var recoveries: [RecoveryReport]
    /// Spaces whose space.json could not be read or restored. They count as sealed until the user decides.
    public var sealedByDefault: [SpaceID]

    public init(
        id: LibraryID, spaces: [Space], isReadOnly: Bool, recoveries: [RecoveryReport], sealedByDefault: [SpaceID]
    ) {
        self.id = id
        self.spaces = spaces
        self.isReadOnly = isReadOnly
        self.recoveries = recoveries
        self.sealedByDefault = sealedByDefault
    }
}

/// A note in a folder listing.
public struct NoteEntry: Hashable, Sendable {
    public var path: ItemPath
    public var modified: Date?
    public var byteCount: Int64

    public var title: String { path.title }
}

/// A file that isn't a note, in a folder listing.
public struct FileEntry: Hashable, Sendable {
    public var path: ItemPath
    public var modified: Date?
    public var byteCount: Int64

    public var name: String { path.name }
}

/// What is directly inside one folder of a space or of the Inbox, each kind sorted by name.
public struct FolderListing: Hashable, Sendable {
    public var folders: [ItemPath]
    public var notes: [NoteEntry]
    public var files: [FileEntry]
}

public enum LibraryCatalogError: Error, Equatable, Sendable {
    /// The library, or the space, was written by a newer Elenath.
    case readOnly
    /// No space has this id.
    case unknownSpace
    /// Another item in the same folder already has this name (compared as the file system does).
    case nameTaken(String)
    /// The name is one Elenath keeps for itself ("Inbox", "Attachments", a board package).
    case reservedName(String)
    /// The path would lead outside the library, for example through a symbolic link.
    case outsideLibrary
    /// The library must be opened or created first.
    case notOpen
}

/// The library folder: its library.json, its spaces and what is in their folders.
///
/// The folder is the truth (docs/FORMAT.md). Every visible folder directly inside the library, except
/// `Inbox`, is a space. A folder without `.space` gets a space.json the first time the library is opened.
///
/// **Sealing fails closed.** A space.json that is missing or damaged is restored from its backups or its
/// safety copy. When that isn't possible for a space Elenath has seen before, or the file is there but
/// can't be read, the space counts as sealed until the user decides, so its content is never shown
/// elsewhere by mistake.
///
/// All disk work happens on the actor. Nothing is created, written, moved or trashed outside `root`,
/// except the safety copies in `safetyDirectory`.
public actor LibraryCatalog {
    /// The library folder chosen by the user.
    public nonisolated let root: URL

    private let safetyDirectory: URL
    private let fileSystem: any FileSystem
    private let timeSource: any TimeSource
    private let backupInterval: TimeInterval
    private let maxBackups: Int
    private let log = CoreLog(category: "LibraryCatalog")

    private let libraryStore: DocumentStore<LibraryDocument>
    private var library: LibraryDocument?
    private var isReadOnly = false
    private var entries: [SpaceID: Entry] = [:]

    private struct Entry {
        var space: Space
        var store: DocumentStore<SpaceDocument>
    }

    /// - Parameters:
    ///   - root: The library folder (the one containing `.elenath`).
    ///   - safetyDirectory: Where safety copies live, e.g. Application Support/Elenath/SafetyCopies.
    ///   - knownLibraryID: The id of the library last opened from this folder, to find its safety copy.
    public init(
        root: URL,
        safetyDirectory: URL,
        knownLibraryID: LibraryID? = nil,
        fileSystem: any FileSystem,
        timeSource: any TimeSource,
        backupInterval: TimeInterval = 15 * 60,
        maxBackups: Int = 50
    ) {
        self.root = root
        self.safetyDirectory = safetyDirectory
        self.fileSystem = fileSystem
        self.timeSource = timeSource
        self.backupInterval = backupInterval
        self.maxBackups = maxBackups
        libraryStore = DocumentStore(
            owner: root, metadataFolderName: LibraryLayout.metadataFolderName, safetyDirectory: safetyDirectory,
            knownDocumentID: knownLibraryID?.rawValue, fileSystem: fileSystem, timeSource: timeSource,
            backupInterval: backupInterval, maxBackups: maxBackups)
    }

    // MARK: - Opening

    /// Writes a brand-new library into an empty folder: library.json and the Inbox. Refuses (throws) when
    /// the folder already holds a library.
    public func create(id: LibraryID = LibraryID()) async throws -> LibrarySnapshot {
        let document = LibraryDocument(id: id)
        try await libraryStore.create(document)
        library = document
        isReadOnly = false
        entries = [:]
        try fileSystem.createDirectory(at: LibraryLayout.inboxFolder(in: root))
        return snapshot(recoveries: [], sealedByDefault: [])
    }

    /// Loads library.json and finds the spaces.
    ///
    /// Throws `DocumentStoreError.missing` when there is no library here (or the folder is gone) and
    /// `.unreadable` when library.json is damaged beyond recovery. A library.json from a newer Elenath
    /// opens read-only.
    public func open() async throws -> LibrarySnapshot {
        var recoveries: [RecoveryReport] = []
        do {
            let load = try await libraryStore.load()
            library = load.document
            isReadOnly = false
            if let recovery = load.recovery {
                recoveries.append(recovery)
            }
        } catch DocumentStoreError.newerSchema {
            // Shown as far as this version understands it, and never written.
            let file = LibraryLayout.metadataFolder(in: root).appending(
                component: LibraryLayout.libraryFileName, directoryHint: .notDirectory)
            guard let document = try? JSONDecoder().decode(LibraryDocument.self, from: fileSystem.readData(at: file))
            else {
                throw DocumentStoreError.unreadable("library.json is from a newer Elenath and can't be shown")
            }
            library = document
            isReadOnly = true
        }
        guard let library else { throw LibraryCatalogError.notOpen }

        let known = readKnownFolders(of: library.id)
        var found: [SpaceID: Entry] = [:]
        var sealedByDefault: [SpaceID] = []
        for name in spaceFolderNames() {
            let knownID = known[NameSanitizer.key(name)]
            let result = await loadSpace(folderName: name, knownID: knownID, libraryID: library.id)
            found[result.entry.space.id] = result.entry
            if let recovery = result.recovery {
                recoveries.append(recovery)
            }
            if result.sealedByDefault {
                sealedByDefault.append(result.entry.space.id)
            }
        }
        entries = found
        writeKnownFolders(of: library.id)
        return snapshot(recoveries: recoveries, sealedByDefault: sealedByDefault)
    }

    /// The spaces as last opened or changed, in sidebar order.
    public func spaces() -> [Space] {
        orderedSpaces()
    }

    // MARK: - Spaces

    /// Makes a new space: its folder, with a space.json. The name is made safe first.
    public func createSpace(
        named name: String,
        color: SpaceColor = .fallback,
        symbol: String = Space.fallbackSymbol,
        sealed: Bool = false,
        description: String = "",
        keywords: [String] = [],
        id: SpaceID = SpaceID()
    ) async throws -> Space {
        var library = try editableLibrary()
        let folderName = try freeSpaceName(name)
        let folder = root.appending(component: folderName, directoryHint: .isDirectory)
        guard PathContainment.isStrictlyInside(folder, folder: root) else { throw LibraryCatalogError.outsideLibrary }
        let document = SpaceDocument(
            id: id, color: color, symbol: symbol, sealed: sealed, description: description, keywords: keywords)
        try fileSystem.createDirectory(at: folder)
        let store = makeSpaceStore(folder: folder, knownID: document.id, libraryID: library.id)
        try await store.create(document)
        let space = Self.space(named: folderName, from: document, isReadOnly: false)
        entries[space.id] = Entry(space: space, store: store)
        library.spaces.append(space.id)
        try await save(library)
        writeKnownFolders(of: library.id)
        return space
    }

    /// Saves a space's settings: color, symbol, sealed, description and keywords. Its name is changed
    /// with `renameSpace`. Sealing or unsealing takes effect at once: `Reach` reads it at every query.
    public func update(_ space: Space) async throws {
        _ = try editableLibrary()
        guard var entry = entries[space.id] else { throw LibraryCatalogError.unknownSpace }
        guard !entry.space.isReadOnly else { throw LibraryCatalogError.readOnly }
        let document = SpaceDocument(
            id: space.id, color: space.color, symbol: space.symbol, sealed: space.isSealed,
            description: space.description, keywords: space.keywords)
        try await entry.store.save(document)
        entry.space = Self.space(named: entry.space.name, from: document, isReadOnly: false)
        entries[space.id] = entry
    }

    /// Renames a space's folder. The name is made safe first; a name already taken is refused. Links that
    /// name the space are the caller's to rewrite, in the same undo step.
    public func renameSpace(_ id: SpaceID, to name: String) async throws -> Space {
        let library = try editableLibrary()
        guard var entry = entries[id] else { throw LibraryCatalogError.unknownSpace }
        guard !entry.space.isReadOnly else { throw LibraryCatalogError.readOnly }
        let newName = NameSanitizer.sanitizedTitle(name)
        if newName == entry.space.name {
            return entry.space
        }
        // Changing only the letter case of a name is a rename of the same folder, not a clash.
        if NameSanitizer.key(newName) != NameSanitizer.key(entry.space.name) {
            try checkSpaceNameIsFree(newName)
        } else if NameSanitizer.isReservedAtLibraryRoot(newName) {
            throw LibraryCatalogError.reservedName(newName)
        }
        let oldFolder = root.appending(component: entry.space.name, directoryHint: .isDirectory)
        let newFolder = root.appending(component: newName, directoryHint: .isDirectory)
        guard PathContainment.isStrictlyInside(oldFolder, folder: root),
            PathContainment.isStrictlyInside(newFolder, folder: root)
        else { throw LibraryCatalogError.outsideLibrary }
        try fileSystem.moveItem(at: oldFolder, to: newFolder)
        entry.space.name = newName
        entry.store = makeSpaceStore(folder: newFolder, knownID: id, libraryID: library.id)
        entries[id] = entry
        writeKnownFolders(of: library.id)
        return entry.space
    }

    /// Sets the order of the spaces in the sidebar. Spaces left out keep their place after the ones named.
    public func reorderSpaces(_ order: [SpaceID]) async throws {
        var library = try editableLibrary()
        var seen = Set<SpaceID>()
        var result: [SpaceID] = []
        for id in order + library.spaces where seen.insert(id).inserted {
            result.append(id)
        }
        library.spaces = result
        try await save(library)
    }

    /// Moves a space's whole folder to the Trash and returns where it went, when the file system says.
    /// Its place in the sidebar order is kept, so putting the folder back restores it where it was.
    public func trashSpace(_ id: SpaceID) async throws -> URL? {
        _ = try editableLibrary()
        guard let entry = entries[id] else { throw LibraryCatalogError.unknownSpace }
        let folder = root.appending(component: entry.space.name, directoryHint: .isDirectory)
        guard PathContainment.isStrictlyInside(folder, folder: root) else { throw LibraryCatalogError.outsideLibrary }
        let trashed = try fileSystem.trashItemReturningURL(at: folder)
        entries[id] = nil
        return trashed
    }

    // MARK: - Folders

    /// Whether nothing may be changed in a container: the library, or the space, was written by a newer
    /// Elenath. A space that doesn't exist is read-only too.
    public func isReadOnly(_ container: Container) -> Bool {
        if isReadOnly || library == nil {
            return true
        }
        switch container {
        case .inbox:
            return false
        case .space(let id):
            return entries[id]?.space.isReadOnly ?? true
        }
    }

    /// The folder of a space or of the Inbox.
    public func folderURL(of container: Container) throws -> URL {
        switch container {
        case .inbox:
            return LibraryLayout.inboxFolder(in: root)
        case .space(let id):
            guard let entry = entries[id] else { throw LibraryCatalogError.unknownSpace }
            return root.appending(component: entry.space.name, directoryHint: .isDirectory)
        }
    }

    /// The URL of an item in a container, checked to be inside the library with symbolic links resolved.
    public func url(for path: ItemPath, in container: Container, isDirectory: Bool) throws -> URL {
        let url = path.url(under: try folderURL(of: container), isDirectory: isDirectory)
        guard PathContainment.contains(url, in: root) else { throw LibraryCatalogError.outsideLibrary }
        return url
    }

    /// Creates the Inbox folder when it isn't there yet.
    public func ensureInbox() throws {
        _ = try editableLibrary()
        try fileSystem.createDirectory(at: LibraryLayout.inboxFolder(in: root))
    }

    /// What is directly inside `folder`: its subfolders, its notes and its other files. Hidden items,
    /// Elenath's own folders, attachments folders, board packages and symbolic links are left out. A
    /// folder that doesn't exist lists as empty.
    public func listing(of folder: ItemPath, in container: Container) throws -> FolderListing {
        let url = try url(for: folder, in: container, isDirectory: true)
        var listing = FolderListing(folders: [], notes: [], files: [])
        guard fileSystem.isDirectory(at: url) else { return listing }
        for item in try fileSystem.contentsOfDirectory(at: url) {
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), let path = folder.appending(name), let info = fileSystem.info(at: item),
                !info.isSymbolicLink
            else { continue }
            if info.isDirectory {
                if !NameSanitizer.isReservedInSpace(name) {
                    listing.folders.append(path)
                }
            } else if ItemPath.isNoteFileName(name) {
                listing.notes.append(NoteEntry(path: path, modified: info.modified, byteCount: info.byteCount))
            } else {
                listing.files.append(FileEntry(path: path, modified: info.modified, byteCount: info.byteCount))
            }
        }
        listing.folders.sort { Self.comesBefore($0.name, $1.name) }
        listing.notes.sort { Self.comesBefore($0.path.name, $1.path.name) }
        listing.files.sort { Self.comesBefore($0.path.name, $1.path.name) }
        return listing
    }

    /// Whether `url` is the library folder or inside it, with symbolic links resolved.
    public nonisolated func contains(_ url: URL) -> Bool {
        PathContainment.contains(url, in: root)
    }

    // MARK: - Private

    private func editableLibrary() throws -> LibraryDocument {
        guard let library else { throw LibraryCatalogError.notOpen }
        guard !isReadOnly else { throw LibraryCatalogError.readOnly }
        return library
    }

    private func save(_ document: LibraryDocument) async throws {
        try await libraryStore.save(document)
        library = document
    }

    private func snapshot(recoveries: [RecoveryReport], sealedByDefault: [SpaceID]) -> LibrarySnapshot {
        LibrarySnapshot(
            id: library?.id ?? LibraryID(), spaces: orderedSpaces(), isReadOnly: isReadOnly, recoveries: recoveries,
            sealedByDefault: sealedByDefault)
    }

    /// The spaces listed in library.json first, in that order, then the rest by name.
    private func orderedSpaces() -> [Space] {
        var remaining = entries
        var result: [Space] = []
        for id in library?.spaces ?? [] {
            if let entry = remaining.removeValue(forKey: id) {
                result.append(entry.space)
            }
        }
        result.append(contentsOf: remaining.values.map(\.space).sorted { Self.comesBefore($0.name, $1.name) })
        return result
    }

    /// The names of the visible folders directly inside the library that are spaces, by name.
    private func spaceFolderNames() -> [String] {
        let contents = (try? fileSystem.contentsOfDirectory(at: root)) ?? []
        var names: [String] = []
        for item in contents {
            let name = item.lastPathComponent
            guard !NameSanitizer.isReservedAtLibraryRoot(name), !NameSanitizer.isReservedInSpace(name),
                let info = fileSystem.info(at: item), info.isDirectory, !info.isSymbolicLink
            else { continue }
            names.append(name)
        }
        return names.sorted(by: Self.comesBefore)
    }

    private struct LoadedSpace {
        var entry: Entry
        var recovery: RecoveryReport?
        var sealedByDefault: Bool
    }

    private func loadSpace(folderName: String, knownID: SpaceID?, libraryID: LibraryID) async -> LoadedSpace {
        let folder = root.appending(component: folderName, directoryHint: .isDirectory)
        let store = makeSpaceStore(folder: folder, knownID: knownID, libraryID: libraryID)
        do {
            let load = try await store.load()
            let space = Self.space(named: folderName, from: load.document, isReadOnly: isReadOnly)
            return LoadedSpace(
                entry: Entry(space: space, store: store), recovery: load.recovery, sealedByDefault: false)
        } catch DocumentStoreError.missing where knownID == nil {
            // A folder Elenath has never seen: it becomes a space that mixes, like any new space.
            let document = SpaceDocument()
            if !isReadOnly {
                do {
                    try await store.create(document)
                } catch {
                    log.error("Could not write a new space.json", private: String(describing: error))
                }
            }
            let adopted = makeSpaceStore(folder: folder, knownID: document.id, libraryID: libraryID)
            let space = Self.space(named: folderName, from: document, isReadOnly: isReadOnly)
            return LoadedSpace(entry: Entry(space: space, store: adopted), recovery: nil, sealedByDefault: false)
        } catch DocumentStoreError.newerSchema {
            // Shown as far as this version understands it. If even that fails, it stays sealed.
            let file = LibraryLayout.spaceMetadataFolder(in: folder).appending(
                component: LibraryLayout.spaceFileName, directoryHint: .notDirectory)
            if let document = try? JSONDecoder().decode(SpaceDocument.self, from: fileSystem.readData(at: file)) {
                let space = Self.space(named: folderName, from: document, isReadOnly: true)
                return LoadedSpace(entry: Entry(space: space, store: store), recovery: nil, sealedByDefault: false)
            }
            return sealedSpace(folderName: folderName, id: knownID, store: store, isReadOnly: true)
        } catch {
            // Missing for a space Elenath knows, or damaged with nothing to restore from.
            log.error("A space.json could not be read or restored", private: String(describing: error))
            return sealedSpace(folderName: folderName, id: knownID, store: store, isReadOnly: isReadOnly)
        }
    }

    private func sealedSpace(
        folderName: String, id: SpaceID?, store: DocumentStore<SpaceDocument>, isReadOnly: Bool
    ) -> LoadedSpace {
        let space = Space(id: id ?? SpaceID(), name: folderName, isSealed: true, isReadOnly: isReadOnly)
        return LoadedSpace(entry: Entry(space: space, store: store), recovery: nil, sealedByDefault: true)
    }

    private func makeSpaceStore(folder: URL, knownID: SpaceID?, libraryID: LibraryID) -> DocumentStore<SpaceDocument> {
        DocumentStore(
            owner: folder, metadataFolderName: LibraryLayout.spaceMetadataFolderName,
            safetyDirectory: spaceSafetyDirectory(of: libraryID), knownDocumentID: knownID?.rawValue,
            fileSystem: fileSystem, timeSource: timeSource, backupInterval: backupInterval, maxBackups: maxBackups)
    }

    private static func space(named name: String, from document: SpaceDocument, isReadOnly: Bool) -> Space {
        Space(
            id: document.id, name: name, color: document.color, symbol: document.symbol, isSealed: document.sealed,
            description: document.description, keywords: document.keywords, isReadOnly: isReadOnly)
    }

    /// `name` made safe, or an error when it is reserved or taken.
    private func freeSpaceName(_ name: String) throws -> String {
        let folderName = NameSanitizer.sanitizedTitle(name)
        try checkSpaceNameIsFree(folderName)
        return folderName
    }

    private func checkSpaceNameIsFree(_ name: String) throws {
        if NameSanitizer.isReservedAtLibraryRoot(name) || NameSanitizer.isReservedInSpace(name) {
            throw LibraryCatalogError.reservedName(name)
        }
        let key = NameSanitizer.key(name)
        let existing = (try? fileSystem.contentsOfDirectory(at: root)) ?? []
        if existing.contains(where: { NameSanitizer.key($0.lastPathComponent) == key }) {
            throw LibraryCatalogError.nameTaken(name)
        }
    }

    /// Names in the order the sidebar shows them: without regard to case, numbers by value.
    private static func comesBefore(_ first: String, _ second: String) -> Bool {
        let result = first.compare(second, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
        if result != .orderedSame {
            return result == .orderedAscending
        }
        return first < second
    }

    // MARK: - Which folder was which space

    /// Safety copies of this library's space.json files, and the record of which folder is which space.
    private func spaceSafetyDirectory(of libraryID: LibraryID) -> URL {
        safetyDirectory.appending(component: libraryID.rawValue.uuidString, directoryHint: .isDirectory)
    }

    private func knownFoldersFile(of libraryID: LibraryID) -> URL {
        spaceSafetyDirectory(of: libraryID).appending(component: "folders.json", directoryHint: .notDirectory)
    }

    /// Which space each folder name was the last time the library was open here, by name key. With it, a
    /// space whose `.space` folder vanished is recognized instead of being taken for a new folder.
    private func readKnownFolders(of libraryID: LibraryID) -> [String: SpaceID] {
        guard let data = try? fileSystem.readData(at: knownFoldersFile(of: libraryID)),
            let stored = try? JSONDecoder().decode([String: SpaceID].self, from: data)
        else { return [:] }
        return stored
    }

    private func writeKnownFolders(of libraryID: LibraryID) {
        var folders: [String: SpaceID] = [:]
        for entry in entries.values {
            folders[NameSanitizer.key(entry.space.name)] = entry.space.id
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(folders)
            try fileSystem.createDirectory(at: spaceSafetyDirectory(of: libraryID))
            try fileSystem.writeAtomically(data, to: knownFoldersFile(of: libraryID))
        } catch {
            log.error("Could not record the spaces' folders", private: String(describing: error))
        }
    }
}
