import ElenathCore
import Foundation

/// The calendar's sentences for the user (from Ithil's `LibraryMessages`). Technical details go to the log,
/// never here. Each sentence is its own localized string.
enum CalendarMessages {
    // MARK: - Opening

    static func couldNotOpen(_ error: any Error) -> String {
        if (error as? CalendarStoreError) == .notAFolder {
            return joined(
                String(
                    localized: "The calendar's folder can't be used: “Calendar” in your library is a file or a link."),
                String(localized: "Move it out of the library folder, and Elenath makes a calendar folder there."))
        }
        if let storeError = error as? DocumentStoreError, case .unreadable = storeError {
            return joined(
                String(localized: "The calendar file is damaged, and there's no backup Elenath can restore it from."),
                String(localized: "Elenath left the file as it was."))
        }
        return joined(String(localized: "Elenath couldn't open the calendar."), error.localizedDescription)
    }

    // MARK: - Saving

    static func saveFailed(_ error: any Error) -> String {
        if (error as? DocumentStoreError) == .readOnly {
            return joined(
                String(localized: "This calendar was saved by a newer version."),
                String(localized: "This version of Elenath won't change it."))
        }
        if (error as? CocoaError)?.code == .fileNoSuchFile {
            return joined(
                String(localized: "Elenath can't find its folder. Your changes are still open in Elenath."),
                String(localized: "Reconnect the drive or put the folder back, then try again."))
        }
        return joined(String(localized: "Elenath couldn't save your latest changes."), error.localizedDescription)
    }

    static func settingsSaveFailed(_ error: any Error) -> String {
        joined(String(localized: "Elenath couldn't save the calendar's settings."), error.localizedDescription)
    }

    // MARK: - Recovery

    /// What happened and what Elenath did, for the "Elenath restored your calendar" alert.
    static func recovery(_ report: RecoveryReport) -> String {
        var sentences: [String] = []
        if report.damagedFileMovedTo != nil {
            sentences.append(String(localized: "Your calendar file was damaged."))
        } else {
            sentences.append(String(localized: "Your calendar file was missing."))
        }
        let savedText = report.recoveredSavedAt?.formatted(date: .long, time: .shortened)
        switch (report.source, savedText) {
        case (.backup, let savedAt?):
            sentences.append(String(localized: "Elenath restored the backup saved \(savedAt)."))
            sentences.append(String(localized: "Changes made after that may be missing."))
        case (.backup, nil):
            sentences.append(String(localized: "Elenath restored its newest backup."))
            sentences.append(String(localized: "Changes made after that may be missing."))
        case (.safetyCopy, let savedAt?):
            sentences.append(
                String(localized: "Elenath restored the safety copy it keeps on this Mac, saved \(savedAt)."))
        case (.safetyCopy, nil):
            sentences.append(String(localized: "Elenath restored the safety copy it keeps on this Mac."))
        }
        if let damaged = report.damagedFileMovedTo {
            let path = FolderAccess.displayPath(damaged.path)
            sentences.append(String(localized: "The damaged file was kept at \(path)."))
        }
        return sentences.joined(separator: " ")
    }

    static var startedOverLostFile: String {
        joined(
            String(localized: "The calendar's file was missing, and there was no backup to bring it back from."),
            String(localized: "Elenath started an empty calendar. The event folders and their files are untouched."))
    }

    private static func joined(_ sentences: String...) -> String {
        sentences.joined(separator: " ")
    }
}
