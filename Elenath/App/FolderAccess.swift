import AppKit
import ElenathCore
import Foundation

/// The library folder Elenath remembers between launches: a security-scoped bookmark, the path it had
/// when it was last opened (to show when the bookmark no longer resolves), and the id of the library
/// found there (so its safety copy can be found if library.json is damaged).
///
/// Never read or written in `-demo` mode.
struct SavedFolder: Equatable, Sendable {
    var bookmark: Data
    var path: String
    var libraryID: UUID?
    /// The version of Elenath that made the bookmark, for the diagnostics report: it shows whether a
    /// bookmark survives an update to a newly signed build.
    var madeByVersion: String?

    static func load(from defaults: UserDefaults) -> SavedFolder? {
        guard let bookmark = defaults.data(forKey: Key.bookmark) else { return nil }
        let path = defaults.string(forKey: Key.path) ?? ""
        let libraryID = defaults.string(forKey: Key.libraryID).flatMap { UUID(uuidString: $0) }
        return SavedFolder(
            bookmark: bookmark, path: path, libraryID: libraryID, madeByVersion: defaults.string(forKey: Key.version))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(bookmark, forKey: Key.bookmark)
        defaults.set(path, forKey: Key.path)
        defaults.set(madeByVersion, forKey: Key.version)
        if let libraryID {
            defaults.set(libraryID.uuidString, forKey: Key.libraryID)
        } else {
            defaults.removeObject(forKey: Key.libraryID)
        }
    }

    private enum Key {
        static let bookmark = "libraryFolderBookmark"
        static let path = "libraryFolderPath"
        static let libraryID = "libraryFolderLibraryID"
        static let version = "libraryFolderBookmarkVersion"
    }

    /// This build's version, as "0.1.0 (12)".
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Security-scoped bookmarks, the folder panels, and the small bits of disk work around choosing and
/// opening a library folder (from Ithil's `FolderAccess`).
///
/// Everything except the panels is plain synchronous code meant to run off the main thread (in a
/// detached task); the panels are `@MainActor`.
enum FolderAccess {
    private static let log = CoreLog(category: "FolderAccess")

    // MARK: - Bookmarks

    enum Resolution: Sendable {
        /// The folder is there. Its security scope has been entered when `isAccessing` is true; a stale
        /// bookmark comes with a fresh one to save.
        case available(URL, refreshedBookmark: Data?, isAccessing: Bool)
        /// The bookmark resolves, but not to a folder (deleted, or moved to the Trash).
        case missing
        /// The bookmark no longer resolves (folder gone, drive unplugged, bookmark damaged).
        case unresolvable
    }

    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a saved bookmark and enters its security scope. A bookmark of a folder that was moved or
    /// renamed resolves to its new place (and is stale, so it gets refreshed); one that now points into
    /// the Trash counts as missing, so Elenath never keeps working in a deleted folder.
    static func resolve(_ bookmark: Data) -> Resolution {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        } catch {
            log.error("The folder bookmark doesn't resolve", private: String(describing: error))
            return .unresolvable
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        guard LocalFileSystem().isDirectory(at: url), !isInTrash(url) else {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            log.error("The library folder is missing")
            return .missing
        }
        var refreshed: Data?
        if isStale {
            do {
                refreshed = try makeBookmark(for: url)
            } catch {
                log.error("Could not refresh a stale folder bookmark", private: String(describing: error))
            }
        }
        return .available(url, refreshedBookmark: refreshed, isAccessing: isAccessing)
    }

    private static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    // MARK: - Choosing a folder

    /// A folder the user chose, turned into a library folder.
    struct PreparedFolder: Sendable {
        var root: URL
        /// The folder already has `.elenath`, so it is opened rather than created.
        var hasLibrary: Bool
        /// A security-scoped bookmark of `root`, to open it again at the next launch.
        var bookmark: Data
    }

    enum SetupError: Error {
        /// "Locate Folder…" was pointed at a folder that holds no Elenath library.
        case noLibraryFound
    }

    /// Turns the folder the user chose into a library folder.
    ///
    /// - Choosing (`relocating == false`): a folder that doesn't exist yet (from "Create Elenath Folder…")
    ///   is created, then `LibraryFolderPolicy` picks the folder itself (empty or already a library) or an
    ///   `Elenath` subfolder inside it.
    /// - Relocating ("Locate Folder…"): the folder must be a library, or contain one named `Elenath`;
    ///   anything else throws `noLibraryFound`, so a missing library is never replaced by an empty one.
    static func prepare(_ chosen: URL, relocating: Bool) throws -> PreparedFolder {
        let fileSystem = LocalFileSystem()
        let root: URL
        if relocating {
            root = try existingLibraryFolder(in: chosen, fileSystem: fileSystem)
        } else {
            if !fileSystem.fileExists(at: chosen) {
                try fileSystem.createDirectory(at: chosen)
            }
            root = try LibraryFolderPolicy.libraryFolder(forChosen: chosen, fileSystem: fileSystem)
        }
        let hasLibrary = LibraryFolderPolicy.isLibrary(root, fileSystem: fileSystem)
        let bookmark = try makeBookmark(for: root)
        return PreparedFolder(root: root, hasLibrary: hasLibrary, bookmark: bookmark)
    }

    private static func existingLibraryFolder(in chosen: URL, fileSystem: any FileSystem) throws -> URL {
        if LibraryFolderPolicy.isLibrary(chosen, fileSystem: fileSystem) {
            return chosen
        }
        let child = chosen.appending(component: LibraryFolderPolicy.defaultFolderName, directoryHint: .isDirectory)
        if LibraryFolderPolicy.isLibrary(child, fileSystem: fileSystem) {
            return child
        }
        throw SetupError.noLibraryFound
    }

    static func folderExists(at url: URL) -> Bool {
        LocalFileSystem().isDirectory(at: url)
    }

    /// Creates a folder in Elenath's container if needed. Failures are only logged: whoever writes there
    /// tries again.
    static func prepareDirectory(_ url: URL) {
        do {
            try LocalFileSystem().createDirectory(at: url)
        } catch {
            log.error("Could not create a folder in the container", private: String(describing: error))
        }
    }

    // MARK: - Elenath's own folders

    /// Where Elenath keeps what is derived from the library: safety copies, the index and edits that
    /// could not be saved (docs/FORMAT.md, "Outside the library").
    struct SupportFolders: Sendable {
        var safetyCopies: URL
        var index: URL
        var recovery: URL

        /// Application Support/Elenath in the app's container.
        static var standard: SupportFolders {
            SupportFolders(
                base: URL.applicationSupportDirectory.appending(component: "Elenath", directoryHint: .isDirectory))
        }

        init(base: URL) {
            safetyCopies = base.appending(component: "SafetyCopies", directoryHint: .isDirectory)
            index = base.appending(component: "Index", directoryHint: .isDirectory)
            recovery = base.appending(component: "Recovery", directoryHint: .isDirectory)
        }
    }

    // MARK: - Demo

    struct DemoFolders: Sendable {
        var root: URL
        var support: SupportFolders
    }

    /// A fresh temporary folder for `-demo`: `<tmp>/Elenath Demo <UUID>/Elenath` plus its own safety
    /// copies and index beside it, so demo runs never touch the user's data or Application Support.
    static func makeDemoFolders() throws -> DemoFolders {
        let base = URL.temporaryDirectory.appending(
            component: "Elenath Demo \(UUID().uuidString)", directoryHint: .isDirectory)
        let folders = DemoFolders(
            root: base.appending(component: LibraryFolderPolicy.defaultFolderName, directoryHint: .isDirectory),
            support: SupportFolders(base: base.appending(component: "Support", directoryHint: .isDirectory)))
        let fileSystem = LocalFileSystem()
        try fileSystem.createDirectory(at: folders.root)
        try fileSystem.createDirectory(at: folders.support.safetyCopies)
        return folders
    }

    // MARK: - Paths

    /// The user's real home folder (not the sandbox container's).
    static var userHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return URL.homeDirectory
    }

    /// ~/Documents, where Elenath suggests its folder.
    static var documentsFolder: URL {
        userHome.appending(component: "Documents", directoryHint: .isDirectory)
    }

    /// "~/Documents/Elenath".
    static var suggestedFolderDisplayPath: String {
        let suggested = documentsFolder.appending(
            component: LibraryFolderPolicy.defaultFolderName, directoryHint: .isDirectory)
        return displayPath(suggested.path)
    }

    /// `path` with the home folder shown as "~".
    static func displayPath(_ path: String) -> String {
        let home = userHome.path
        guard home.count > 1, path == home || path.hasPrefix(home + "/") else { return path }
        return "~\(path.dropFirst(home.count))"
    }

    /// `url`'s path with every symbolic link resolved, the form FSEvents reports paths in (for example
    /// `/private/var/…` for a temporary folder). Reads the disk: call it off the main actor.
    static func resolvedPath(of url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { path -> String in
            guard let path, let resolved = realpath(path, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    // MARK: - Panels

    /// Asks where to create the Elenath folder, suggesting ~/Documents/Elenath. Returns the chosen URL;
    /// the folder itself is created by `prepare(_:relocating:)`.
    @MainActor
    static func createFolder() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Create Your Elenath Folder")
        panel.message = String(localized: "Elenath keeps your notes and their files in this folder.")
        panel.prompt = String(localized: "Create")
        panel.nameFieldLabel = String(localized: "Folder name:")
        panel.nameFieldStringValue = LibraryFolderPolicy.defaultFolderName
        panel.canCreateDirectories = true
        panel.directoryURL = documentsFolder
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Asks for an existing folder to keep the library in.
    @MainActor
    static func chooseExistingFolder() -> URL? {
        chooseFolder(
            title: String(localized: "Choose a Folder for Elenath"),
            message: String(localized: "Choose an Elenath folder, or a folder to create one in."),
            startingAt: documentsFolder)
    }

    /// Asks where the missing Elenath folder went, starting next to where it used to be.
    @MainActor
    static func locateFolder(lastKnownPath: String) -> URL? {
        var start = documentsFolder
        if !lastKnownPath.isEmpty {
            start = URL(filePath: lastKnownPath, directoryHint: .isDirectory).deletingLastPathComponent()
        }
        return chooseFolder(
            title: String(localized: "Locate Your Elenath Folder"),
            message: String(localized: "Choose the folder that has your Elenath notes in it."),
            startingAt: start)
    }

    /// Asks for files and folders to import.
    @MainActor
    static func chooseItemsToImport() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import")
        panel.message = String(
            localized: "Choose files or folders to copy into Elenath. The originals stay where they are.")
        panel.prompt = String(localized: "Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    @MainActor
    private static func chooseFolder(title: String, message: String, startingAt directory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = String(localized: "Use This Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
