import ElenathCore
import Foundation

/// Why a files action was refused before it touched the disk.
enum FilesError: Error, Equatable {
    /// No calendar is open for changes (still loading, missing, or read-only).
    case notReady
    /// The event the files were meant for no longer exists.
    case eventNotFound
}

/// The user-facing sentences for files and folders. Technical details go to the log, never here. Each
/// sentence is its own localized string.
enum FileMessages {
    // MARK: - Adding files

    static var cannotAddFilesNow: String {
        String(localized: "Files can't be added right now, because no calendar is open for changes.")
    }

    static var cannotAddWhileMoving: String {
        String(localized: "Elenath is moving your library. Add the files again once it's done.")
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
        case .notReady:
            return String(localized: "No calendar is open for changes right now.")
        case .eventNotFound:
            return String(localized: "The event no longer exists.")
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
