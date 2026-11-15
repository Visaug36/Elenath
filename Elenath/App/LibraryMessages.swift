import ElenathCore
import Foundation

/// The user-facing explanations `AppModel` puts in its states and alerts. Technical details go to the
/// log, never here. Each sentence is its own localized string.
enum LibraryMessages {
    // MARK: - Opening

    static var damaged: String {
        joined(
            String(localized: "The library file is damaged, and there's no backup Elenath can restore it from."),
            String(localized: "Elenath left the file as it was. Your notes are untouched."))
    }

    static func couldNotOpen(_ error: any Error) -> String {
        joined(String(localized: "Elenath couldn't open the library in this folder."), error.localizedDescription)
    }

    static func couldNotCreate(_ error: any Error) -> String {
        joined(String(localized: "Elenath couldn't create a library in this folder."), error.localizedDescription)
    }

    static func couldNotSetUpDemo(_ error: any Error) -> String {
        joined(String(localized: "Elenath couldn't set up the demo folder."), error.localizedDescription)
    }

    // MARK: - Choosing a folder

    static func cannotUseFolder(_ error: any Error) -> String {
        if case FolderAccess.SetupError.noLibraryFound = error {
            return joined(
                String(localized: "That folder doesn't have an Elenath library in it."),
                String(localized: "To start a new library elsewhere, use Choose Another Folder instead."))
        }
        return error.localizedDescription
    }

    static var demoCannotChangeFolder: String {
        String(localized: "The demo uses a temporary folder, so it can't switch to another one.")
    }

    // MARK: - Recovery

    /// What happened to library.json or a space.json and what Elenath did.
    static func recovery(_ reports: [RecoveryReport], sealedByDefault: [String]) -> String? {
        var sentences: [String] = []
        for report in reports {
            if report.damagedFileMovedTo != nil {
                sentences.append(String(localized: "A settings file in your library was damaged."))
            } else {
                sentences.append(String(localized: "A settings file in your library was missing."))
            }
            let savedText = report.recoveredSavedAt?.formatted(date: .long, time: .shortened)
            switch (report.source, savedText) {
            case (.backup, let savedAt?):
                sentences.append(String(localized: "Elenath restored the backup saved \(savedAt)."))
            case (.backup, nil):
                sentences.append(String(localized: "Elenath restored its newest backup."))
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
        }
        if !sealedByDefault.isEmpty {
            let names = sealedByDefault.formatted(.list(type: .and))
            sentences.append(
                String(
                    localized:
                        "Elenath couldn't read the settings of \(names), so it is sealed until you decide: its notes stay out of everything else. You can change that in Settings › Spaces."
                ))
        }
        if !reports.isEmpty {
            sentences.append(String(localized: "Your notes themselves were not changed."))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    // MARK: - Notes

    /// Why something the user asked for couldn't be done.
    static func operationFailed(_ error: any Error) -> String {
        switch error {
        case NoteStoreError.nameTaken(let name):
            return String(localized: "There is already something called “\(name)” in that folder.")
        case NoteStoreError.reservedName(let name):
            return String(localized: "“\(name)” is a name Elenath keeps for itself. Choose another.")
        case NoteStoreError.readOnly, LibraryCatalogError.readOnly:
            return joined(
                String(localized: "This library was saved by a newer version of Elenath."),
                String(localized: "This version won't change it."))
        case NoteStoreError.notFound:
            return String(localized: "That file isn't there any more. It may have been moved or deleted in Finder.")
        case LibraryCatalogError.nameTaken(let name):
            return String(localized: "There is already something called “\(name)” in your library.")
        case LibraryCatalogError.reservedName(let name):
            return String(localized: "“\(name)” is a name Elenath keeps for itself. Choose another.")
        case LibraryCatalogError.outsideLibrary:
            return String(localized: "That would lead outside your library folder, so Elenath didn't do it.")
        default:
            return error.localizedDescription
        }
    }

    private static func joined(_ sentences: String...) -> String {
        sentences.joined(separator: " ")
    }
}
