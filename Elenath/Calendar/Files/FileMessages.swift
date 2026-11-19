import ElenathCore
import Foundation

/// Why a files action was refused before it touched the disk.
enum FilesError: Error, Equatable {
    /// The demo's folder is temporary, so it can't be moved or switched.
    case demoMode
    /// No calendar is open for changes (still loading, missing, or read-only).
    case notReady
    /// A move of the calendar is already running.
    case busy
    /// The calendar still had changes waiting to be saved, so it wasn't moved.
    case stillSaving
    /// The event the files were meant for no longer exists.
    case eventNotFound
    /// The folder chosen in Settings changed after it was checked.
    case folderChanged
    /// Files are still being copied into events, so the calendar can't move yet.
    case importsRunning
    /// The calendar moved to the new folder, but couldn't be opened there.
    case movedButNotOpened
}

/// The user-facing sentences for files and folders. Technical details go to the log, never here. Each
/// sentence is its own localized string.
enum FileMessages {
    // MARK: - Adding files

    static var cannotAddFilesNow: String {
        String(localized: "Files can't be added right now, because no calendar is open for changes.")
    }

    static var cannotAddWhileMoving: String {
        String(localized: "Elenath is moving your calendar. Add the files again once it's done.")
    }

    /// A copy that failed part-way: which item, why, and how many made it.
    static func importFailed(_ error: any Error, progress: FileCopyProgress?) -> String {
        var sentences: [String] = []
        if let name = progress?.currentName {
            sentences.append(String(localized: "Elenath couldn't copy “\(name)”."))
        } else {
            sentences.append(String(localized: "Elenath couldn't copy the files."))
        }
        sentences.append(reason(error))
        if let progress, progress.completedFiles > 0 {
            let done = progress.completedFiles
            let total = progress.totalFiles
            sentences.append(String(localized: "\(done) of \(total) items were copied and are in the event's folder."))
        }
        return joined(sentences)
    }

    // MARK: - Folders and files

    static func couldNotRenameFolder(title: String, error: any Error) -> String {
        joined([
            String(localized: "Elenath couldn't rename the folder of “\(title)”."),
            String(localized: "Its files are still in the old folder."),
            reason(error),
        ])
    }

    static func couldNotTrashFolder(title: String, error: any Error) -> String {
        joined([
            String(localized: "Elenath couldn't move the folder of “\(title)” to the Trash."),
            String(localized: "It's still in your library folder."),
            reason(error),
        ])
    }

    /// Undo brought an event back, but its folder couldn't come back from the Trash.
    static func couldNotPutBackFolder(title: String, error: any Error) -> String {
        let isGone = (error as? CocoaError)?.code == .fileNoSuchFile
        return joined([
            String(localized: "Elenath couldn't bring the folder of “\(title)” back from the Trash."),
            isGone ? "" : String(localized: "It's still in the Trash."),
            reason(error),
        ])
    }

    static func couldNotTrashFile(name: String, error: any Error) -> String {
        joined([String(localized: "Elenath couldn't move “\(name)” to the Trash."), reason(error)])
    }

    static func couldNotOpenFile(name: String) -> String {
        String(localized: "No app on this Mac could open “\(name)”.")
    }

    // MARK: - Choosing another folder

    static var alreadyUsingFolder: String {
        String(localized: "Elenath already keeps your calendar in that folder.")
    }

    static var folderInsideLibrary: String {
        String(localized: "That folder is inside your library folder. Choose a folder outside it.")
    }

    static var folderUnavailable: String {
        String(localized: "Elenath can't use that folder. Choose another one.")
    }

    // MARK: - Moving the calendar

    static func libraryMoveFailed(_ error: any Error) -> String {
        switch error as? FilesError {
        case .stillSaving:
            return String(localized: "Elenath is still saving your latest changes. Try again in a moment.")
        case .busy:
            return String(localized: "Your calendar is already being moved.")
        case .demoMode:
            return LibraryMessages.demoCannotChangeFolder
        case .notReady:
            return String(localized: "Your calendar can't be moved right now, because it isn't open for changes.")
        case .folderChanged:
            return String(localized: "That folder changed in the meantime. Choose it again.")
        case .importsRunning:
            return String(localized: "Elenath is still copying files into your events. Try again once they're done.")
        case .movedButNotOpened:
            return joined([
                String(
                    localized: "Your calendar and its files moved, but Elenath couldn't open them in the new folder."),
                String(localized: "Choose that folder with Change… to open it."),
            ])
        case .eventNotFound, nil:
            return joined([
                String(localized: "Elenath couldn't move your calendar, so it stays in its current folder."),
                reason(error),
            ])
        }
    }

    // MARK: - Reasons

    /// A short, plain explanation of `error`, or the system's own description.
    static func reason(_ error: any Error) -> String {
        if let folderError = error as? EventFoldersError {
            switch folderError {
            case .outsideRoot:
                return String(localized: "It would have ended up outside your library folder, so Elenath stopped.")
            case .notADirectory:
                return String(localized: "Elenath can't find its folder, or a file has the name a folder needs.")
            }
        }
        if let filesError = error as? FilesError {
            return filesReason(filesError)
        }
        if let cocoaError = error as? CocoaError, let text = codeReason(cocoaError.code) {
            return text
        }
        return error.localizedDescription
    }

    private static func filesReason(_ error: FilesError) -> String {
        switch error {
        case .demoMode:
            return LibraryMessages.demoCannotChangeFolder
        case .notReady:
            return String(localized: "No calendar is open for changes right now.")
        case .busy:
            return String(localized: "Elenath is moving your calendar.")
        case .stillSaving:
            return String(localized: "Elenath is still saving your latest changes.")
        case .eventNotFound:
            return String(localized: "The event no longer exists.")
        case .folderChanged:
            return String(localized: "The folder changed in the meantime.")
        case .importsRunning:
            return String(localized: "Elenath is still copying files into your events.")
        case .movedButNotOpened:
            return String(localized: "The calendar moved, but couldn't be opened in its new folder.")
        }
    }

    private static func codeReason(_ code: CocoaError.Code) -> String? {
        switch code {
        case .fileWriteOutOfSpace:
            return String(localized: "There isn't enough space on the disk.")
        case .fileReadNoPermission, .fileWriteNoPermission:
            return String(localized: "Elenath isn't allowed to use it.")
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return String(localized: "It's no longer there.")
        case .fileWriteFileExists:
            return String(localized: "Something with that name is already there.")
        case .fileWriteVolumeReadOnly:
            return String(localized: "The disk is read-only.")
        case .fileWriteInvalidFileName:
            return String(localized: "It can't be copied there. A folder can't be copied into itself.")
        default:
            return nil
        }
    }

    private static func joined(_ sentences: [String]) -> String {
        sentences.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
