import Foundation

/// Where things are inside a library folder (docs/FORMAT.md, "The library folder").
public enum LibraryLayout {
    /// The hidden folder inside the library that holds library.json and its backups.
    public static let metadataFolderName = ".elenath"
    /// The hidden folder inside a space that holds space.json and its backups.
    public static let spaceMetadataFolderName = ".space"
    public static let libraryFileName = "library.json"
    public static let spaceFileName = "space.json"
    public static let backupsFolderName = "backups"

    /// `<root>/.elenath`
    public static func metadataFolder(in root: URL) -> URL {
        root.appending(component: metadataFolderName, directoryHint: .isDirectory)
    }

    /// `<root>/Inbox`
    public static func inboxFolder(in root: URL) -> URL {
        root.appending(component: NameSanitizer.inboxFolderName, directoryHint: .isDirectory)
    }

    /// `<space folder>/.space`
    public static func spaceMetadataFolder(in spaceFolder: URL) -> URL {
        spaceFolder.appending(component: spaceMetadataFolderName, directoryHint: .isDirectory)
    }
}
