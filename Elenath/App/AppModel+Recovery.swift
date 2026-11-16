import AppKit
import ElenathCore

/// Edits Elenath couldn't save before it last closed, kept in its own Recovery folder (docs/FORMAT.md,
/// "Outside the library"). When the library opens, an alert offers to put them back as notes of their
/// own: each where its note was, the Inbox or its space, so a sealed space's text goes back to that space
/// only. Nothing is deleted: a copy that was put back goes to the Trash.
extension AppModel {
    /// The open library's Recovery folder.
    private var recovery: RecoveryFolder? {
        guard let services, let libraryID else { return nil }
        return RecoveryFolder(
            folder: services.support.recovery.appending(
                component: libraryID.rawValue.uuidString, directoryHint: .isDirectory),
            fileSystem: LocalFileSystem())
    }

    /// Looks for kept edits, off the main thread.
    func findRecoveredEdits() {
        guard let recovery else { return }
        let id = libraryID
        Task {
            let found = await Task.detached(priority: .utility) {
                recovery.copies()
            }.value
            guard libraryID == id, state == .ready else { return }
            recoveredEdits = found
        }
    }

    /// "Put Them Back": each kept copy becomes a note at the top of the Inbox or of its space, then goes
    /// to the Trash. A copy whose space is gone stays where it is and is shown in Finder: it may come from
    /// a sealed space, so it never goes to the Inbox.
    func putRecoveredEditsBack() {
        let copies = recoveredEdits
        recoveredEdits = []
        guard let services, !copies.isEmpty else { return }
        Task {
            var made: [NoteRef] = []
            var putBack: [URL] = []
            var leftOver: [URL] = []
            for copy in copies {
                let container: Container
                if let id = copy.space {
                    guard space(id) != nil else {
                        leftOver.append(copy.file)
                        continue
                    }
                    container = .space(id)
                } else {
                    container = .inbox
                }
                guard canEdit(container) else {
                    leftOver.append(copy.file)
                    continue
                }
                do {
                    let note = try await services.notes.importNote(
                        from: copy.file, title: copy.title, in: .root, container: container)
                    made.append(note)
                    putBack.append(copy.file)
                } catch {
                    report(error)
                }
            }
            let toTrash = putBack
            await Task.detached(priority: .utility) {
                for url in toTrash {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }.value
            await noteChanged(made)
            if !leftOver.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(leftOver)
            } else if made.count == 1, let note = made.first {
                open(note)
            } else if let first = made.first {
                go(to: first.container == .inbox ? .inbox : .folder(first.container, .root))
            }
        }
    }

    /// "Later": the alert comes back the next time the library opens.
    func postponeRecoveredEdits() {
        recoveredEdits = []
    }
}
