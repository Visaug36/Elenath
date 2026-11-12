import Foundation

/// What a batch of file system changes inside the library folder means for Elenath.
public struct LibraryChange: Hashable, Sendable {
    /// The library's own shape may have changed: a space's folder came, went or was renamed, or a
    /// space's settings were written. The catalog has to be opened again.
    public var reloadsCatalog = false
    /// The containers in which something changed. Their index needs a refresh.
    public var containers: Set<Container> = []
    /// The notes that changed, so that one that is open can react.
    public var notes: Set<NoteRef> = []

    public init() {}

    public var isEmpty: Bool {
        !reloadsCatalog && containers.isEmpty && notes.isEmpty
    }
}

/// Sorts the paths a folder watcher reports by what they mean (docs/ARCHITECTURE.md, "The watcher"), so
/// that a `.DS_Store` written by Finder, a backup of space.json or a file that is still being copied
/// doesn't cost anything.
public enum LibraryPathClassifier {
    /// - Parameters:
    ///   - paths: Absolute paths with symbolic links resolved, as FSEvents reports them.
    ///   - rootPath: The library folder, resolved the same way.
    ///   - spaces: The spaces as the catalog last found them.
    public static func classify(paths: [String], rootPath: String, spaces: [Space]) -> LibraryChange {
        var change = LibraryChange()
        var spacesByName: [String: SpaceID] = [:]
        for space in spaces {
            spacesByName[NameSanitizer.key(space.name)] = space.id
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for path in paths {
            guard path.hasPrefix(prefix) else {
                // The library folder itself, or something that can't be placed: look at everything.
                change.reloadsCatalog = true
                continue
            }
            let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            guard let first = parts.first else {
                change.reloadsCatalog = true
                continue
            }
            if first.hasPrefix(".") {
                continue  // Elenath's own files, and other hidden items.
            }
            let container: Container
            if NameSanitizer.key(first) == NameSanitizer.key(NameSanitizer.inboxFolderName) {
                container = .inbox
            } else if let space = spacesByName[NameSanitizer.key(first)] {
                container = .space(space)
            } else {
                // A folder Elenath doesn't know yet, or a file beside the spaces. A file there is nothing
                // to Elenath, but only the catalog can tell the two apart.
                change.reloadsCatalog = true
                continue
            }
            let rest = Array(parts.dropFirst())
            guard !rest.isEmpty else {
                if container == .inbox {
                    change.containers.insert(.inbox)
                } else {
                    change.reloadsCatalog = true  // A space's folder was renamed, moved or deleted.
                }
                continue
            }
            if rest[0] == LibraryLayout.spaceMetadataFolderName {
                if rest.last == LibraryLayout.spaceFileName && rest.count == 2 {
                    change.reloadsCatalog = true
                }
                continue
            }
            if rest.contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            change.containers.insert(container)
            if let name = rest.last, ItemPath.isNoteFileName(name),
                !rest.dropLast().contains(where: NameSanitizer.isReservedInSpace),
                let itemPath = ItemPath(rest.joined(separator: "/"))
            {
                change.notes.insert(NoteRef(container: container, path: itemPath))
            }
        }
        return change
    }
}
