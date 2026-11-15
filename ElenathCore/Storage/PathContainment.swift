import Foundation

/// Whether a path lies inside a folder once `.`, `..` and symbolic links are resolved. Everything Elenath
/// creates, writes, moves or trashes is checked with this, so nothing can be reached outside the library
/// through a link or a crafted name.
public enum PathContainment {
    /// Whether `url` is `folder` or inside it.
    public static func contains(_ url: URL, in folder: URL) -> Bool {
        guard let folderComponents = resolvedComponents(of: folder), let components = resolvedComponents(of: url)
        else { return false }
        return components.starts(with: folderComponents)
    }

    /// Whether `url` is inside `folder` and not the folder itself.
    public static func isStrictlyInside(_ url: URL, folder: URL) -> Bool {
        guard let folderComponents = resolvedComponents(of: folder), let components = resolvedComponents(of: url)
        else { return false }
        return components.count > folderComponents.count && components.starts(with: folderComponents)
    }

    /// The absolute path of `url` as components, with `.` and `..` applied and every symbolic link in the
    /// existing part of the path resolved (components that don't exist are kept as written). Nil for a
    /// URL that isn't a file URL, or for a loop of links.
    static func resolvedComponents(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        var pending = Array(url.absoluteURL.path.split(separator: "/").map { String($0) }.reversed())
        var resolved: [String] = []
        var linksFollowed = 0
        while let component = pending.popLast() {
            if component == "." {
                continue
            }
            if component == ".." {
                if !resolved.isEmpty {
                    resolved.removeLast()
                }
                continue
            }
            let path = "/" + (resolved + [component]).joined(separator: "/")
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                resolved.append(component)
                continue
            }
            linksFollowed += 1
            guard linksFollowed <= 64 else { return nil }
            if destination.hasPrefix("/") {
                resolved.removeAll()
            }
            pending.append(contentsOf: destination.split(separator: "/").map { String($0) }.reversed())
        }
        return resolved
    }
}
