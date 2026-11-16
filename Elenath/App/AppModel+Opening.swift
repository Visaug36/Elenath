import AppKit
import ElenathCore

/// Opening links and files from notes (docs/ARCHITECTURE.md, "Opening links and files"). Web pages and
/// e-mail open at once, and so do documents, pictures, sound and video; anything that could run as a
/// program, or open another app, is asked about first (`OpenPolicy`). Elenath itself never goes online.
extension AppModel {
    /// Opens a link written in a note: a web page or an e-mail at once, anything else once the user says.
    func openLink(_ address: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            NSSound.beep()
            return
        }
        if OpenPolicy.decision(forLink: address) == .open {
            NSWorkspace.shared.open(url)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Open this link in another app?")
        alert.informativeText = String(
            localized:
                "“\(url.absoluteString)” opens in \(FileManager.default.displayName(atPath: app.path)). Open it only if you know where the link came from."
        )
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Open Link"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a file of the library in the app the Mac uses for it. A file that could run as a program
    /// (an app, a script, an installer, a link file) is asked about first, and is shown in Finder unless
    /// the user chooses to open it.
    func openLibraryFile(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes?[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else {
            NSSound.beep()
            return
        }
        if type == .typeRegular, OpenPolicy.decision(forFileNamed: url.lastPathComponent) == .open {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Open “\(url.lastPathComponent)”?")
        alert.informativeText = String(
            localized:
                "This kind of file can run as a program or open another app. Open it only if you know where it came from."
        )
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }
}
