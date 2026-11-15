import Foundation

/// Where an item lives: in a space or in the Inbox.
public enum Container: Hashable, Sendable {
    case space(SpaceID)
    case inbox
}

/// A path inside a container, such as "Physics/Lecture 7 notes.md". Never absolute, never empty
/// components, never "." or "..": a path can't point outside its container.
public struct ItemPath: Hashable, Sendable, CustomStringConvertible {
    /// The container's own folder.
    public static let root = ItemPath(components: [])

    public let components: [String]

    /// Reads a "/"-separated path. Nil when a component is empty, "." or "..", or when the path is
    /// absolute. The empty string is the root.
    public init?(_ string: String) {
        if string.isEmpty {
            self = .root
            return
        }
        let parts = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy(ItemPath.isValidComponent) else { return nil }
        components = parts
    }

    private init(components: [String]) {
        self.components = components
    }

    /// A single name as a path. Nil when it isn't a valid component (see `init(_:)`).
    public init?(name: String) {
        guard ItemPath.isValidComponent(name) else { return nil }
        components = [name]
    }

    public var isRoot: Bool {
        components.isEmpty
    }

    /// The last component, or "" for the root.
    public var name: String {
        components.last ?? ""
    }

    /// The name without its extension: a note's title. "Lecture 7 notes.md" gives "Lecture 7 notes".
    public var title: String {
        ItemPath.title(ofFileNamed: name)
    }

    /// The folder this path is in. The root's folder is the root.
    public var folder: ItemPath {
        ItemPath(components: Array(components.dropLast()))
    }

    /// This path with one more component. Nil when the component isn't valid.
    public func appending(_ component: String) -> ItemPath? {
        guard ItemPath.isValidComponent(component) else { return nil }
        return ItemPath(components: components + [component])
    }

    /// Whether this path is `other` or lies inside it.
    public func isInside(_ other: ItemPath) -> Bool {
        components.count >= other.components.count
            && Array(components.prefix(other.components.count)) == other.components
    }

    /// The "/"-separated form, "" for the root.
    public var description: String {
        components.joined(separator: "/")
    }

    /// The URL of this path under `base`, the container's folder.
    public func url(under base: URL, isDirectory: Bool) -> URL {
        guard !components.isEmpty else { return base }
        var url = base
        for component in components.dropLast() {
            url = url.appending(component: component, directoryHint: .isDirectory)
        }
        return url.appending(component: name, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    /// A file name without its extension, when it has one that Elenath treats as a note's.
    static func title(ofFileNamed name: String) -> String {
        for ending in noteExtensions where name.lowercased().hasSuffix(ending) && name.count > ending.count {
            return String(name.dropLast(ending.count))
        }
        return name
    }

    /// Whether a file with this name is a note (docs/FORMAT.md, "Notes").
    public static func isNoteFileName(_ name: String) -> Bool {
        !name.hasPrefix(".") && title(ofFileNamed: name) != name
    }

    /// The endings of note files, lowercase, with their dot.
    static let noteExtensions = [".md", ".markdown"]

    private static func isValidComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
            && !component.contains("\0")
    }
}

/// A note, by where it is.
public struct NoteRef: Hashable, Sendable {
    public var container: Container
    public var path: ItemPath

    public init(container: Container, path: ItemPath) {
        self.container = container
        self.path = path
    }

    /// The note's title: its file name without the extension.
    public var title: String {
        path.title
    }
}

/// What a note is, from its front matter. A missing or unknown kind is `.note`.
public enum NoteKind: String, CaseIterable, Sendable {
    case note
    case idea
    case goal
}
