import Foundation

/// Moves a library to another folder, for changing the folder in Settings (from Ithil's `LibraryMove`).
public enum LibraryMove {
    private static let log = CoreLog(category: "LibraryMove")

    /// Moves Elenath's items (every space's folder, `Inbox`, and `.elenath`) from `oldRoot` into
    /// `newRoot`. Loose files directly in `oldRoot` and hidden items stay where they are. On the same
    /// volume the moves are renames; across volumes each item is copied and then removed from the old
    /// place by `moveItem`. Nothing is deleted.
    ///
    /// `newRoot` must be a folder with nothing in it but Finder metadata, or not exist yet (it is then
    /// created, with its parents). Throws, moving nothing, when `oldRoot` isn't a folder, when `newRoot`
    /// has anything else in it or is a file, or when it is one of the items to move or inside one.
    ///
    /// The folders move first, by name, and `.elenath` last, so library.json stays in the old folder
    /// until everything else has moved. If a move fails, the items already moved are moved back (and a
    /// half-copied item left by a failed move across volumes goes to the Trash, the original being still
    /// in place), then the error is thrown. Call it off the main actor, with nothing saving meanwhile.
    public static func move(from oldRoot: URL, to newRoot: URL, fileSystem: any FileSystem) throws {
        let oldRoot = oldRoot.standardizedFileURL
        let newRoot = newRoot.standardizedFileURL
        guard fileSystem.isDirectory(at: oldRoot) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: oldRoot])
        }
        let items = try libraryItems(in: oldRoot, fileSystem: fileSystem)
        guard !items.contains(where: { PathContainment.contains(newRoot, in: $0) }),
            !PathContainment.contains(oldRoot, in: newRoot) || newRoot == oldRoot
        else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSURLErrorKey: newRoot])
        }
        guard newRoot != oldRoot else { return }
        if fileSystem.info(at: newRoot) != nil {
            guard fileSystem.isDirectory(at: newRoot),
                LibraryFolderPolicy.isEffectivelyEmpty(newRoot, fileSystem: fileSystem)
            else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: newRoot])
            }
        } else {
            try fileSystem.createDirectory(at: newRoot)
        }

        var moved: [(source: URL, destination: URL)] = []
        for item in items {
            let destination = newRoot.appending(component: item.lastPathComponent, directoryHint: .isDirectory)
            do {
                guard fileSystem.info(at: destination) == nil else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: destination])
                }
                do {
                    try fileSystem.moveItem(at: item, to: destination)
                } catch {
                    if !isDestinationTaken(error) {
                        putPartialCopyInTrash(source: item, destination: destination, fileSystem: fileSystem)
                    }
                    throw error
                }
                moved.append((item, destination))
            } catch {
                log.error("Could not move the library", private: String(describing: error))
                for step in moved.reversed() {
                    do {
                        try fileSystem.moveItem(at: step.destination, to: step.source)
                    } catch {
                        log.error("Could not move an item back", private: String(describing: error))
                    }
                }
                throw error
            }
        }
        log.notice("Moved the library")
    }

    /// The folders of the spaces and the Inbox, by name, then `.elenath`.
    static func libraryItems(in root: URL, fileSystem: any FileSystem) throws -> [URL] {
        var folders: [URL] = []
        var metadata: [URL] = []
        for item in try fileSystem.contentsOfDirectory(at: root) {
            guard let info = fileSystem.info(at: item), info.isDirectory, !info.isSymbolicLink else { continue }
            let name = item.lastPathComponent
            if name == LibraryLayout.metadataFolderName {
                metadata.append(item)
            } else if !name.hasPrefix(".") {
                folders.append(item)
            }
        }
        folders.sort { $0.lastPathComponent < $1.lastPathComponent }
        return folders + metadata
    }

    /// After a failed move across volumes, what it left at the destination is a partial copy, as long as
    /// the original is still in place: it goes to the Trash.
    private static func putPartialCopyInTrash(source: URL, destination: URL, fileSystem: any FileSystem) {
        guard fileSystem.fileExists(at: source), fileSystem.info(at: destination) != nil else { return }
        do {
            try fileSystem.trashItem(at: destination)
        } catch {
            log.error("Could not put a partial copy in the Trash", private: String(describing: error))
        }
    }

    private static func isDestinationTaken(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == CocoaError.Code.fileWriteFileExists.rawValue
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST)
    }
}
