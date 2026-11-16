import Foundation

/// One visible item in an event's folder: a file, or a folder the user put there.
public struct EventFile: Hashable, Sendable, Identifiable {
    public var url: URL
    /// The item's name on disk, extension included.
    public var name: String
    /// The file's size; for a folder (or a package such as a Keynote document), the total size of the
    /// files inside it. 0 for a symbolic link.
    public var byteCount: Int64
    /// When the item last changed, if known.
    public var modified: Date?
    public var isDirectory: Bool

    public var id: URL { url }

    public init(url: URL, name: String, byteCount: Int64, modified: Date?, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.byteCount = byteCount
        self.modified = modified
        self.isDirectory = isDirectory
    }
}
