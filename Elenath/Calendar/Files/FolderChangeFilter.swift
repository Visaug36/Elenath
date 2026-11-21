import ElenathCore
import Foundation

/// How much a batch of file system events changes what Elenath shows.
enum FolderChangeImpact: Comparable {
    /// Nothing Elenath shows: its own metadata (events.json saves), hidden files, or other files in the root.
    case unrelated
    /// Files inside event folders came, went or changed: counts and file lists need a refresh.
    case contents
    /// Day or event folders came, went or were renamed, or a marker changed: the marker index needs a
    /// rescan first.
    case structure
}

/// Sorts the paths `RootFolderWatcher` reports by what they mean for event folders, so a save of
/// events.json or a `.DS_Store` written by Finder doesn't cost a rescan.
enum FolderChangeFilter {
    /// The impact of a whole batch: the largest impact of any of its paths. Without the root's resolved
    /// path, or after dropped events, everything counts as structure.
    static func impact(of change: RootFolderChange, rootPath: String?) -> FolderChangeImpact {
        guard !change.needsRescan, let rootPath else { return .structure }
        var result = FolderChangeImpact.unrelated
        for path in change.paths {
            result = max(result, impact(ofPath: path, rootPath: rootPath))
            if result == .structure {
                break
            }
        }
        return result
    }

    /// The impact of one changed path, as FSEvents reports it (absolute, symbolic links resolved).
    ///
    /// - The root itself, a day folder (`yyyy-MM-dd`), or a visible item in a day folder (an event
    ///   folder), or a marker: structure.
    /// - A visible item inside an event folder, at any depth: contents.
    /// - `.ithil` (events.json, backups), other items in the root, and hidden items such as `.DS_Store`
    ///   or a copy in progress: unrelated.
    /// - A path outside the root (it can't be placed): structure, to be safe.
    static func impact(ofPath path: String, rootPath: String) -> FolderChangeImpact {
        guard path != rootPath else { return .structure }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return .structure }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let dayName = parts.first else { return .structure }
        guard CalendarDate(isoString: dayName) != nil else { return .unrelated }
        if parts.count == 1 {
            return .structure
        }
        if parts.count == 2 {
            return parts[1].hasPrefix(".") ? .unrelated : .structure
        }
        if parts[2] == EventFolderMarker.fileName {
            return .structure
        }
        if parts.dropFirst(2).contains(where: { $0.hasPrefix(".") }) {
            return .unrelated
        }
        return .contents
    }

    /// `url`'s path with every symbolic link resolved, the form FSEvents reports paths in (for example
    /// `/private/var/…` for a temporary folder). Reads the disk: call it off the main actor. Falls back to
    /// the path as written.
    static func resolvedPath(of url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { path -> String in
            guard let path, let resolved = realpath(path, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}
