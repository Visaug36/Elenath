import Foundation

/// What a file looked like when Elenath last read or wrote it.
public struct DiskStamp: Hashable, Sendable {
    public var contentHash: UInt64
    public var byteCount: Int
    public var modified: Date?

    public init(contentHash: UInt64, byteCount: Int, modified: Date?) {
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.modified = modified
    }

    public init(data: Data, modified: Date?) {
        self.init(contentHash: ContentHash.of(data), byteCount: data.count, modified: modified)
    }

    /// Whether both stamps are of the same bytes. The date is not compared: a file that was only touched
    /// has not changed.
    public func hasSameContent(as other: DiskStamp) -> Bool {
        contentHash == other.contentHash && byteCount == other.byteCount
    }
}

/// A hash of a file's bytes, to tell whether it changed and to recognize a file that moved. FNV-1a, 64
/// bits: stable across launches and platforms, which Swift's `Hasher` is not.
public enum ContentHash {
    public static func of(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }
}

/// A note as it was read from disk.
public struct LoadedNote: Hashable, Sendable {
    public var ref: NoteRef
    /// The note's parts. Nil when the file isn't UTF-8.
    public var text: NoteText?
    /// What to show for a file that isn't UTF-8: its bytes read leniently. It is never written back.
    public var fallbackText: String?
    public var stamp: DiskStamp
    /// Nothing may be saved: the library or the space comes from a newer Elenath, or the file isn't
    /// UTF-8.
    public var isReadOnly: Bool
    /// When the file was created, for notes without a `created` key.
    public var fileCreated: Date?
}

public enum SaveOutcome: Hashable, Sendable {
    /// The note is on disk as given (with an `id`, if this was its first edit).
    case saved(LoadedNote)
    /// The file was gone, so it was written again.
    case recreated(LoadedNote)
    /// The file changed on disk since it was read. It was left as it is, and the text being saved went
    /// into a new note beside it: both are kept.
    case conflict(yourEdits: LoadedNote, onDisk: DiskStamp)
}

public enum NoteStoreError: Error, Equatable, Sendable {
    /// No file is there.
    case notFound
    /// The library or the space comes from a newer Elenath, or the note isn't UTF-8.
    case readOnly
    /// Another item in the folder already has this name.
    case nameTaken(String)
    /// The name is one Elenath keeps for itself ("Attachments", a hidden name, a board package).
    case reservedName(String)
    /// The path doesn't name a note file.
    case notANote
}

/// Reads and writes the notes, folders and attachments of a library (docs/ARCHITECTURE.md, "Notes").
///
/// - Saves are atomic: a note is written beside itself and renamed into place, so an interrupted save
///   leaves the old note whole.
/// - A save never overwrites a change made elsewhere: both versions are kept.
/// - Nothing is deleted. Notes and folders go to the Trash.
/// - Every path comes from `LibraryCatalog`, which checks that it is inside the library.
public actor NoteStore {
    private let catalog: LibraryCatalog
    private let fileSystem: any FileSystem
    private let timeSource: any TimeSource
    private let timeZone: @Sendable () -> TimeZone
    private let makeID: @Sendable () -> NoteID
    private let log = CoreLog(category: "NoteStore")

    public init(
        catalog: LibraryCatalog,
        fileSystem: any FileSystem,
        timeSource: any TimeSource,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        makeID: @escaping @Sendable () -> NoteID = { NoteID() }
    ) {
        self.catalog = catalog
        self.fileSystem = fileSystem
        self.timeSource = timeSource
        self.timeZone = timeZone
        self.makeID = makeID
    }

    // MARK: - Reading and saving

    public func read(_ ref: NoteRef) async throws -> LoadedNote {
        let url = try await noteURL(ref)
        guard let info = fileSystem.info(at: url), !info.isDirectory else { throw NoteStoreError.notFound }
        let data = try fileSystem.readData(at: url)
        return loaded(ref, data: data, info: info, containerIsReadOnly: await catalog.isReadOnly(ref.container))
    }

    /// Saves a note that was read with `stamp`.
    ///
    /// If the file still has the bytes it had then, it is replaced atomically. If it changed meanwhile,
    /// it is left alone and `text` is saved beside it as "Title (conflict 2026-11-10 14.30).md". If it is
    /// gone, it is written again. A note without an `id` gets one, with a `created` date: this is the
    /// first edit of a note that came from elsewhere.
    public func save(_ text: NoteText, to ref: NoteRef, expecting stamp: DiskStamp) async throws -> SaveOutcome {
        let url = try await writableNoteURL(ref)
        var text = text
        guard let info = fileSystem.info(at: url), !info.isDirectory else {
            addIdentity(to: &text, created: timeSource.now)
            try fileSystem.createDirectory(at: url.deletingLastPathComponent())
            return .recreated(try write(text, to: url, as: ref))
        }
        let current = try fileSystem.readData(at: url)
        let onDisk = DiskStamp(data: current, modified: info.modified)
        addIdentity(to: &text, created: info.created ?? timeSource.now)
        let data = text.data()
        if data == current {
            return .saved(loaded(ref, data: current, info: info, containerIsReadOnly: false))
        }
        guard stamp.hasSameContent(as: onDisk) else {
            // Someone else changed the file. Its copy with the user's edits is a note of its own.
            var copy = text
            if copy.frontMatter?.id != nil {
                copy.frontMatter?.id = makeID()
            }
            let title = NameSanitizer.conflictTitle(for: ref.title, now: timeSource.now, timeZone: timeZone())
            let folder = url.deletingLastPathComponent()
            let name = availableNoteName(for: title + ".md", in: folder)
            guard let path = ref.path.folder.appending(name) else { throw NoteStoreError.notANote }
            let copyRef = NoteRef(container: ref.container, path: path)
            let saved = try write(copy, to: try await noteURL(copyRef), as: copyRef)
            return .conflict(yourEdits: saved, onDisk: onDisk)
        }
        return .saved(try write(text, to: url, as: ref))
    }

    /// Makes a new note in `folder`, which is created if it isn't there. The title is made safe as a
    /// name, and a title that is taken gets a number, as in Finder.
    public func create(
        title: String, in folder: ItemPath, container: Container, kind: NoteKind = .note, body: String = "",
        created: Date? = nil
    ) async throws -> LoadedNote {
        let folderURL = try await writableFolderURL(folder, in: container)
        try fileSystem.createDirectory(at: folderURL)
        let name = availableNoteName(for: NameSanitizer.sanitizedTitle(title) + ".md", in: folderURL)
        guard let path = folder.appending(name) else { throw NoteStoreError.notANote }
        let ref = NoteRef(container: container, path: path)
        let text = NoteText(
            newNoteWithID: makeID(), created: created ?? timeSource.now, timeZone: timeZone(), kind: kind, body: body)
        return try write(text, to: try await noteURL(ref), as: ref)
    }

    // MARK: - Importing

    /// Copies a Markdown or text file from outside the library in as a note called `title`. The bytes are
    /// unchanged when the file is UTF-8, and the copy keeps the file's dates. Text in another encoding is
    /// read as well as it can be and written as UTF-8. The original is never moved or changed.
    public func importNote(
        from source: URL, title: String, in folder: ItemPath, container: Container
    ) async throws -> NoteRef {
        let folderURL = try await writableFolderURL(folder, in: container)
        try fileSystem.createDirectory(at: folderURL)
        let keepsExtension = source.pathExtension.lowercased() == "markdown"
        let name = availableNoteName(
            for: NameSanitizer.sanitizedTitle(title) + (keepsExtension ? ".markdown" : ".md"), in: folderURL)
        guard let path = folder.appending(name) else { throw NoteStoreError.notANote }
        let ref = NoteRef(container: container, path: path)
        let destination = try await noteURL(ref)
        let data = try fileSystem.readData(at: source)
        if (try? NoteText(data: data)) != nil {
            try fileSystem.copyItem(at: source, to: destination)
        } else {
            try fileSystem.writeAtomically(Data(NoteStore.decodedLeniently(data).utf8), to: destination)
        }
        return ref
    }

    /// Copies files or folders from outside the library into a folder, as they are. Names that are taken
    /// get a number. Returns where the copies are, in the order of `sources`.
    public func importFiles(
        _ sources: [URL], into folder: ItemPath, container: Container,
        progress: @escaping @Sendable (FileCopyProgress) -> Void = { _ in }
    ) async throws -> [ItemPath] {
        let folderURL = try await writableFolderURL(folder, in: container)
        try fileSystem.createDirectory(at: folderURL)
        let copies = try await FileCopier.copy(
            sources, into: folderURL, root: catalog.root, fileSystem: fileSystem, progress: progress)
        return copies.compactMap { folder.appending($0.lastPathComponent) }
    }

    /// Text that isn't UTF-8, read as UTF-16 when it starts with that encoding's mark and as Windows
    /// Latin otherwise, which gives every byte a character.
    static func decodedLeniently(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
            let text = String(data: data, encoding: .utf16)
        {
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Renaming, moving, deleting

    /// Renames a note's file. The title is made safe as a name; one that another item has is refused.
    /// The links that point to the note are the caller's to rewrite (`LinkRewriter`), in the same step.
    public func rename(_ ref: NoteRef, to title: String) async throws -> NoteRef {
        let url = try await writableNoteURL(ref)
        guard fileSystem.info(at: url) != nil else { throw NoteStoreError.notFound }
        let fileExtension = String(ref.path.name.dropFirst(ref.path.title.count))
        let newName = NameSanitizer.sanitizedTitle(title) + fileExtension
        guard newName != ref.path.name else { return ref }
        guard let newPath = ref.path.folder.appending(newName), ItemPath.isNoteFileName(newName) else {
            throw NoteStoreError.notANote
        }
        let folder = url.deletingLastPathComponent()
        if NameSanitizer.key(newName) != NameSanitizer.key(ref.path.name),
            noteNameIsTaken(newName, in: folder, except: ref.path.name)
        {
            throw NoteStoreError.nameTaken(NameSanitizer.sanitizedTitle(title))
        }
        let newRef = NoteRef(container: ref.container, path: newPath)
        try rename(url, to: try await noteURL(newRef))
        return newRef
    }

    /// Moves a note to another folder, in its space or another container: this is also how an Inbox item
    /// is filed. A name that is taken there gets a number.
    ///
    /// The files in the `Attachments` folder beside the note that it embeds or links go with it. One is
    /// moved only when `sharedAttachments` is given and doesn't name it, which says that no other note
    /// uses it (`Retrieval.attachmentNamesShared(by:)`); otherwise it is copied, so a note elsewhere that
    /// uses it never loses it.
    public func move(
        _ ref: NoteRef, to folder: ItemPath, in container: Container, sharedAttachments: Set<String>? = nil
    ) async throws -> NoteRef {
        let url = try await writableNoteURL(ref)
        guard let info = fileSystem.info(at: url), !info.isDirectory else { throw NoteStoreError.notFound }
        let folderURL = try await writableFolderURL(folder, in: container)
        let sourceFolderURL = url.deletingLastPathComponent()
        if PathContainment.resolvedComponents(of: folderURL) == PathContainment.resolvedComponents(of: sourceFolderURL)
        {
            return ref
        }
        try fileSystem.createDirectory(at: folderURL)
        let name = availableNoteName(for: ref.path.name, in: folderURL)
        guard let path = folder.appending(name) else { throw NoteStoreError.notANote }
        let newRef = NoteRef(container: container, path: path)
        let newURL = try await noteURL(newRef)
        try fileSystem.moveItem(at: url, to: newURL)
        do {
            try await carryAttachments(
                of: newRef, at: newURL, from: ref, sourceFolder: sourceFolderURL, shared: sharedAttachments)
        } catch {
            // The note has moved. Its files are still where they were and can be moved by hand.
            log.error("Could not move a note's attachments", private: String(describing: error))
        }
        return newRef
    }

    /// Moves a file that isn't a note, or a folder, into another folder. A name that is taken there gets
    /// a number.
    public func moveItem(
        _ path: ItemPath, in container: Container, to folder: ItemPath, in destination: Container
    ) async throws -> ItemPath {
        guard !path.isRoot else { throw NoteStoreError.notFound }
        try await requireWritable(container)
        let isDirectory = fileSystem.isDirectory(at: try await catalog.url(for: path, in: container, isDirectory: true))
        let url = try await catalog.url(for: path, in: container, isDirectory: isDirectory)
        guard fileSystem.info(at: url) != nil else { throw NoteStoreError.notFound }
        let folderURL = try await writableFolderURL(folder, in: destination)
        if PathContainment.contains(folderURL, in: url) {
            throw NoteStoreError.reservedName(path.name)
        }
        if PathContainment.resolvedComponents(of: folderURL)
            == PathContainment.resolvedComponents(of: url.deletingLastPathComponent())
        {
            return path
        }
        try fileSystem.createDirectory(at: folderURL)
        let name = availableNoteName(for: path.name, in: folderURL)
        guard let newPath = folder.appending(name) else { throw NoteStoreError.notFound }
        try fileSystem.moveItem(
            at: url, to: try await catalog.url(for: newPath, in: destination, isDirectory: isDirectory))
        return newPath
    }

    /// Moves a note to the Trash and returns where it went, when the file system says.
    public func trash(_ ref: NoteRef) async throws -> URL? {
        let url = try await writableNoteURL(ref)
        guard fileSystem.info(at: url) != nil else { throw NoteStoreError.notFound }
        return try fileSystem.trashItemReturningURL(at: url)
    }

    /// Moves a file that isn't a note, or a folder with everything in it, to the Trash.
    public func trashItem(_ path: ItemPath, in container: Container) async throws -> URL? {
        guard !path.isRoot else { throw NoteStoreError.notFound }
        try await requireWritable(container)
        let isDirectory = fileSystem.isDirectory(at: try await catalog.url(for: path, in: container, isDirectory: true))
        let url = try await catalog.url(for: path, in: container, isDirectory: isDirectory)
        guard fileSystem.info(at: url) != nil else { throw NoteStoreError.notFound }
        return try fileSystem.trashItemReturningURL(at: url)
    }

    /// Puts something back from the Trash: the undo of a delete. If its old name is taken by now, it
    /// gets a number. Returns where it is.
    public func restore(from trashed: URL, to path: ItemPath, in container: Container) async throws -> ItemPath {
        guard !path.isRoot else { throw NoteStoreError.notFound }
        let folderURL = try await writableFolderURL(path.folder, in: container)
        guard fileSystem.info(at: trashed) != nil else { throw NoteStoreError.notFound }
        try fileSystem.createDirectory(at: folderURL)
        let name = availableNoteName(for: path.name, in: folderURL)
        guard let restored = path.folder.appending(name) else { throw NoteStoreError.notFound }
        let isDirectory = fileSystem.isDirectory(at: trashed)
        try fileSystem.moveItem(
            at: trashed, to: try await catalog.url(for: restored, in: container, isDirectory: isDirectory))
        return restored
    }

    // MARK: - Folders

    /// Makes a folder. The name is made safe; one that is taken gets a number, as in Finder.
    public func createFolder(named name: String, in folder: ItemPath, container: Container) async throws -> ItemPath {
        let parent = try await writableFolderURL(folder, in: container)
        let safeName = NameSanitizer.sanitizedTitle(name)
        guard !NameSanitizer.isReservedInSpace(safeName) else { throw NoteStoreError.reservedName(safeName) }
        try fileSystem.createDirectory(at: parent)
        let finalName = FileCopier.availableName(for: safeName, in: parent, fileSystem: fileSystem)
        guard let path = folder.appending(finalName) else { throw NoteStoreError.reservedName(safeName) }
        try fileSystem.createDirectory(at: try await catalog.url(for: path, in: container, isDirectory: true))
        return path
    }

    /// Renames a folder. The name is made safe; one that another item has is refused.
    public func renameFolder(_ folder: ItemPath, in container: Container, to name: String) async throws -> ItemPath {
        guard !folder.isRoot else { throw NoteStoreError.notFound }
        let url = try await writableFolderURL(folder, in: container)
        guard fileSystem.isDirectory(at: url) else { throw NoteStoreError.notFound }
        let newName = NameSanitizer.sanitizedTitle(name)
        guard newName != folder.name else { return folder }
        guard !NameSanitizer.isReservedInSpace(newName), let newPath = folder.folder.appending(newName) else {
            throw NoteStoreError.reservedName(newName)
        }
        if NameSanitizer.key(newName) != NameSanitizer.key(folder.name),
            nameIsTaken(newName, in: url.deletingLastPathComponent())
        {
            throw NoteStoreError.nameTaken(newName)
        }
        try rename(url, to: try await catalog.url(for: newPath, in: container, isDirectory: true))
        return newPath
    }

    // MARK: - Attachments

    /// Copies files into the `Attachments` folder beside a note and returns where the copies are, in the
    /// order of `sources`. Originals are never moved. Names that are taken get a number.
    public func addAttachments(
        _ sources: [URL], to ref: NoteRef, progress: @escaping @Sendable (FileCopyProgress) -> Void = { _ in }
    ) async throws -> [ItemPath] {
        try await requireWritable(ref.container)
        guard let attachments = ref.path.folder.appending(NameSanitizer.attachmentsFolderName) else {
            throw NoteStoreError.notANote
        }
        let folderURL = try await catalog.url(for: attachments, in: ref.container, isDirectory: true)
        try fileSystem.createDirectory(at: folderURL)
        let copies = try await FileCopier.copy(
            sources, into: folderURL, root: catalog.root, fileSystem: fileSystem, progress: progress)
        return copies.compactMap { attachments.appending($0.lastPathComponent) }
    }

    /// Writes data (a pasted image, for one) as a new file in the `Attachments` folder beside a note.
    public func addAttachment(_ data: Data, named name: String, to ref: NoteRef) async throws -> ItemPath {
        try await requireWritable(ref.container)
        guard let attachments = ref.path.folder.appending(NameSanitizer.attachmentsFolderName) else {
            throw NoteStoreError.notANote
        }
        let folderURL = try await catalog.url(for: attachments, in: ref.container, isDirectory: true)
        try fileSystem.createDirectory(at: folderURL)
        let finalName = FileCopier.availableName(for: name, in: folderURL, fileSystem: fileSystem)
        guard let path = attachments.appending(finalName) else { throw NoteStoreError.reservedName(name) }
        try fileSystem.writeAtomically(
            data, to: try await catalog.url(for: path, in: ref.container, isDirectory: false))
        return path
    }

    /// The file an embed names (docs/FORMAT.md, "Embeds"): in `Attachments` beside the note, then in the
    /// note's own folder. Nil when it is in neither.
    public func attachmentURL(named name: String, for ref: NoteRef) async -> URL? {
        guard let relative = ItemPath(name), !relative.isRoot else { return nil }
        let folder = ref.path.folder.components
        let places = [
            folder + [NameSanitizer.attachmentsFolderName] + relative.components, folder + relative.components,
        ]
        for components in places {
            guard let path = ItemPath(components.joined(separator: "/")),
                let url = try? await catalog.url(for: path, in: ref.container, isDirectory: false),
                let info = fileSystem.info(at: url), !info.isDirectory
            else { continue }
            return url
        }
        return nil
    }

    // MARK: - Private: paths

    private func noteURL(_ ref: NoteRef) async throws -> URL {
        guard ItemPath.isNoteFileName(ref.path.name) else { throw NoteStoreError.notANote }
        return try await catalog.url(for: ref.path, in: ref.container, isDirectory: false)
    }

    private func writableNoteURL(_ ref: NoteRef) async throws -> URL {
        try await requireWritable(ref.container)
        return try await noteURL(ref)
    }

    private func requireWritable(_ container: Container) async throws {
        if await catalog.isReadOnly(container) {
            throw NoteStoreError.readOnly
        }
    }

    /// The URL of a folder that notes may be put in: no part of its path is a name Elenath keeps for
    /// itself.
    private func writableFolderURL(_ folder: ItemPath, in container: Container) async throws -> URL {
        try await requireWritable(container)
        if let reserved = folder.components.first(where: NameSanitizer.isReservedInSpace) {
            throw NoteStoreError.reservedName(reserved)
        }
        return try await catalog.url(for: folder, in: container, isDirectory: true)
    }

    private func nameIsTaken(_ name: String, in folder: URL) -> Bool {
        let key = NameSanitizer.key(name)
        let contents = (try? fileSystem.contentsOfDirectory(at: folder)) ?? []
        return contents.contains { NameSanitizer.key($0.lastPathComponent) == key }
    }

    /// Whether `name` can't be given to an item in `folder`: something has that name, or `name` is a
    /// note's and another note there has the same title under the other extension. A folder never holds
    /// two notes with one title, because a link couldn't tell them apart.
    private func noteNameIsTaken(_ name: String, in folder: URL, except own: String? = nil) -> Bool {
        let key = NameSanitizer.key(name)
        let titleKey = ItemPath.isNoteFileName(name) ? NameSanitizer.key(ItemPath(name: name)?.title ?? name) : nil
        let contents = (try? fileSystem.contentsOfDirectory(at: folder)) ?? []
        return contents.contains { item in
            let other = item.lastPathComponent
            if other == own {
                return false
            }
            if NameSanitizer.key(other) == key {
                return true
            }
            guard let titleKey, ItemPath.isNoteFileName(other) else { return false }
            return NameSanitizer.key(ItemPath(name: other)?.title ?? other) == titleKey
        }
    }

    /// `name`, or its first numbered variant that nothing in `folder` clashes with.
    private func availableNoteName(for name: String, in folder: URL) -> String {
        UniqueName.available(name) { noteNameIsTaken($0, in: folder) }
    }

    /// Gives a note that has no `id` key one, made only when it is needed.
    private func addIdentity(to text: inout NoteText, created: Date) {
        guard text.needsIdentity else { return }
        text.addIdentity(id: makeID(), created: created, timeZone: timeZone())
    }

    /// Renames within one folder. A change of letter case alone goes through a temporary name, because
    /// on a volume that ignores case the new name "exists" already.
    private func rename(_ source: URL, to destination: URL) throws {
        guard NameSanitizer.key(source.lastPathComponent) == NameSanitizer.key(destination.lastPathComponent) else {
            try fileSystem.moveItem(at: source, to: destination)
            return
        }
        let temporary = source.deletingLastPathComponent().appending(
            component: ".elenath-renaming-" + UUID().uuidString, directoryHint: .notDirectory)
        try fileSystem.moveItem(at: source, to: temporary)
        do {
            try fileSystem.moveItem(at: temporary, to: destination)
        } catch {
            try? fileSystem.moveItem(at: temporary, to: source)
            throw error
        }
    }

    // MARK: - Private: reading and writing

    private func loaded(_ ref: NoteRef, data: Data, info: FileInfo?, containerIsReadOnly: Bool) -> LoadedNote {
        let text = try? NoteText(data: data)
        return LoadedNote(
            ref: ref, text: text, fallbackText: text == nil ? String(decoding: data, as: UTF8.self) : nil,
            stamp: DiskStamp(data: data, modified: info?.modified), isReadOnly: containerIsReadOnly || text == nil,
            fileCreated: info?.created)
    }

    private func write(_ text: NoteText, to url: URL, as ref: NoteRef) throws -> LoadedNote {
        let data = text.data()
        try fileSystem.writeAtomically(data, to: url)
        return loaded(ref, data: data, info: fileSystem.info(at: url), containerIsReadOnly: false)
    }

    // MARK: - Private: attachments that follow a note

    /// What a note's body refers to in the `Attachments` folder beside it.
    private struct AttachmentReference {
        var name: String
        var span: LinkSpan
        /// Whether the link names the folder too ("Attachments/diagram.png").
        var namesFolder: Bool
    }

    private static func attachmentReferences(in body: String) -> [AttachmentReference] {
        let folderKey = NameSanitizer.key(NameSanitizer.attachmentsFolderName)
        var result: [AttachmentReference] = []
        for span in MarkdownScanner.scan(body).links {
            let path: String
            switch span.target {
            case .wiki(let link): path = link.target
            case .markdown(let destination, _): path = destination.removingPercentEncoding ?? destination
            case .url: continue
            }
            var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.first == "." {
                parts.removeFirst()
            }
            if parts.count == 2, NameSanitizer.key(parts[0]) == folderKey {
                result.append(AttachmentReference(name: parts[1], span: span, namesFolder: true))
            } else if parts.count == 1, case .wiki = span.target {
                result.append(AttachmentReference(name: parts[0], span: span, namesFolder: false))
            }
        }
        return result
    }

    /// After `moved` has taken the place of `old`: brings along the files in the old `Attachments` folder
    /// that the note refers to. A file no other note beside the old place mentions is moved; one that
    /// others use is copied. If a different file already has the name in the new place, the newcomer
    /// gets a number and the note's references follow.
    private func carryAttachments(
        of moved: NoteRef, at movedURL: URL, from old: NoteRef, sourceFolder: URL, shared: Set<String>?
    ) async throws {
        let data = try fileSystem.readData(at: movedURL)
        guard var text = try? NoteText(data: data) else { return }
        let references = NoteStore.attachmentReferences(in: text.body)
        guard !references.isEmpty else { return }
        let oldAttachments = sourceFolder.appending(
            component: NameSanitizer.attachmentsFolderName, directoryHint: .isDirectory)
        guard fileSystem.isDirectory(at: oldAttachments),
            let newAttachmentsPath = moved.path.folder.appending(NameSanitizer.attachmentsFolderName)
        else { return }
        let newAttachments = try await catalog.url(for: newAttachmentsPath, in: moved.container, isDirectory: true)

        // What the other notes in the old folder say, to see which files they use too.
        var neighbours: [String] = []
        for item in (try? fileSystem.contentsOfDirectory(at: sourceFolder)) ?? []
        where ItemPath.isNoteFileName(item.lastPathComponent) {
            if let neighbour = try? fileSystem.readData(at: item) {
                neighbours.append(String(decoding: neighbour, as: UTF8.self))
            }
        }

        var newNames: [String: String] = [:]
        var handled = Set<String>()
        for reference in references where handled.insert(NameSanitizer.key(reference.name)).inserted {
            let source = oldAttachments.appending(component: reference.name, directoryHint: .notDirectory)
            guard catalog.contains(source), let info = fileSystem.info(at: source), !info.isDirectory,
                !info.isSymbolicLink
            else { continue }
            try fileSystem.createDirectory(at: newAttachments)
            var name = reference.name
            var destination = newAttachments.appending(component: name, directoryHint: .notDirectory)
            if fileSystem.info(at: destination) != nil {
                if let there = try? fileSystem.readData(at: destination),
                    let here = try? fileSystem.readData(at: source),
                    there == here
                {
                    continue  // The same file is already there.
                }
                name = FileCopier.availableName(for: reference.name, in: newAttachments, fileSystem: fileSystem)
                destination = newAttachments.appending(component: name, directoryHint: .notDirectory)
                newNames[NameSanitizer.key(reference.name)] = name
            }
            guard catalog.contains(destination) else { continue }
            let encoded = reference.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reference.name
            // Without word from the index that no other note uses it, a file is copied, never moved. The
            // notes beside the old place are read as well, in case the index hasn't caught up with them.
            let usedElsewhere = shared?.contains(NameSanitizer.key(reference.name)) ?? true
            let isShared = usedElsewhere || neighbours.contains { $0.contains(reference.name) || $0.contains(encoded) }
            if isShared {
                try fileSystem.copyItem(at: source, to: destination)
            } else {
                try fileSystem.moveItem(at: source, to: destination)
            }
        }

        guard !newNames.isEmpty else { return }
        var edits: [LinkEdit] = []
        for reference in references {
            guard let newName = newNames[NameSanitizer.key(reference.name)] else { continue }
            switch reference.span.target {
            case .wiki(var link):
                link.target = reference.namesFolder ? "\(NameSanitizer.attachmentsFolderName)/\(newName)" : newName
                edits.append(LinkEdit(note: moved, range: reference.span.range, replacement: link.written))
            case .markdown:
                guard let range = reference.span.destinationRange else { continue }
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "()[]<>/%#?")
                let encodedName = newName.addingPercentEncoding(withAllowedCharacters: allowed) ?? newName
                edits.append(
                    LinkEdit(
                        note: moved, range: range,
                        replacement: "\(NameSanitizer.attachmentsFolderName)/\(encodedName)"))
            case .url:
                continue
            }
        }
        text.body = LinkRewriter.apply(edits, to: text.body)
        try fileSystem.writeAtomically(text.data(), to: movedURL)
    }
}
