import Foundation

/// The file operations Elenath's storage needs, behind a protocol so tests can use a
/// temporary folder or a double that fails on purpose.
///
/// URLs are file URLs. Methods that change the disk throw the underlying Foundation error.
public protocol FileSystem: Sendable {
    /// Whether anything (file, folder or link) exists at `url`.
    func fileExists(at url: URL) -> Bool
    /// Whether a folder exists at `url`.
    func isDirectory(at url: URL) -> Bool
    /// The items directly inside a folder, hidden files included, in no particular order.
    func contentsOfDirectory(at url: URL) throws -> [URL]
    /// Creates a folder and any missing parents. Succeeds if the folder already exists.
    func createDirectory(at url: URL) throws
    func readData(at url: URL) throws -> Data
    /// Writes to a temporary file first and then renames it over `url`, so readers see either the old
    /// or the new contents, never a half-written file.
    func writeAtomically(_ data: Data, to url: URL) throws
    /// Copies a file or folder. Fails if `destination` exists.
    func copyItem(at source: URL, to destination: URL) throws
    /// Moves or renames a file or folder. Fails if `destination` exists.
    func moveItem(at source: URL, to destination: URL) throws
    /// Deletes permanently. Only for Elenath's own housekeeping files (old backups); the user's notes and files go
    /// to the Trash instead.
    func removeItem(at url: URL) throws
    /// Moves a file or folder to the Trash.
    func trashItem(at url: URL) throws
    /// Moves a file or folder to the Trash, like `trashItem(at:)`, and returns where it is in the Trash now,
    /// so it can be put back; nil when that isn't known. The default implementation calls `trashItem(at:)`
    /// and returns nil.
    func trashItemReturningURL(at url: URL) throws -> URL?
    /// When the item's contents last changed, or nil if it doesn't exist.
    func modificationDate(at url: URL) -> Date?
    /// What is at `url`, without following a symbolic link there. Nil when nothing is.
    func info(at url: URL) -> FileInfo?
}

/// What identifies a file on its volume. It survives a rename or a move within the volume, so Elenath can
/// follow a note that was renamed in Finder.
public struct FileIdentity: Hashable, Sendable {
    public var volume: UInt64
    public var file: UInt64

    public init(volume: UInt64, file: UInt64) {
        self.volume = volume
        self.file = file
    }
}

/// The facts about one item on disk.
public struct FileInfo: Hashable, Sendable {
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var byteCount: Int64
    public var modified: Date?
    public var created: Date?
    public var identity: FileIdentity?

    public init(
        isDirectory: Bool, isSymbolicLink: Bool = false, byteCount: Int64 = 0, modified: Date? = nil,
        created: Date? = nil, identity: FileIdentity? = nil
    ) {
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.byteCount = byteCount
        self.modified = modified
        self.created = created
        self.identity = identity
    }
}

extension FileSystem {
    /// For file systems that can't tell where a trashed item went: trashes it with `trashItem(at:)` and
    /// returns nil.
    public func trashItemReturningURL(at url: URL) throws -> URL? {
        try trashItem(at: url)
        return nil
    }
}

/// The real disk, through `FileManager.default`.
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        var directoryFlag: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directoryFlag)
        return exists && directoryFlag.boolValue
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func trashItem(at url: URL) throws {
        #if canImport(Darwin)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
            // Only macOS has a Trash that Foundation knows. ElenathCore still builds elsewhere (see
            // docs/ARCHITECTURE.md), where trashing reports that it isn't supported.
            throw CocoaError(.featureUnsupported)
        #endif
    }

    public func trashItemReturningURL(at url: URL) throws -> URL? {
        #if canImport(Darwin)
            var resultingItem: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItem)
            return resultingItem.map { $0 as URL }
        #else
            throw CocoaError(.featureUnsupported)
        #endif
    }

    public func modificationDate(at url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    public func info(at url: URL) -> FileInfo? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let type = attributes[.type] as? FileAttributeType
        var identity: FileIdentity?
        if let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        {
            identity = FileIdentity(volume: volume, file: file)
        }
        return FileInfo(
            isDirectory: type == .typeDirectory,
            isSymbolicLink: type == .typeSymbolicLink,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date,
            created: attributes[.creationDate] as? Date,
            identity: identity)
    }
}
