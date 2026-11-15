import AppKit
import ElenathCore

/// Edits Elenath couldn't save before it last closed, kept in its own Recovery folder (docs/FORMAT.md,
/// "Outside the library"). When the library opens, an alert offers to put them in the Inbox as notes of
/// their own. Nothing is deleted: a copy that went into the Inbox goes to the Trash.
extension AppModel {
    /// The open library's Recovery folder.
    private var recoveryFolder: URL? {
        guard let services, let libraryID else { return nil }
        return services.support.recovery.appending(
            component: libraryID.rawValue.uuidString, directoryHint: .isDirectory)
    }

    /// Looks for kept edits, off the main thread.
    func findRecoveredEdits() {
        guard let folder = recoveryFolder else { return }
        let id = libraryID
        Task {
            let found = await Task.detached(priority: .utility) {
                AppModel.keptNotes(in: folder)
            }.value
            guard libraryID == id, state == .ready else { return }
            recoveredEdits = found
        }
    }

    private nonisolated static func keptNotes(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md") }.sorted().map {
            folder.appending(component: $0, directoryHint: .notDirectory)
        }
    }

    /// "Put Them in the Inbox": each kept copy becomes a note in the Inbox, then goes to the Trash.
    func putRecoveredEditsInInbox() {
        let urls = recoveredEdits
        recoveredEdits = []
        guard let services, canEdit(.inbox), !urls.isEmpty else { return }
        Task {
            var made: [NoteRef] = []
            var imported: [URL] = []
            for url in urls {
                do {
                    let title = url.deletingPathExtension().lastPathComponent
                    let note = try await services.notes.importNote(
                        from: url, title: title, in: .root, container: .inbox)
                    made.append(note)
                    imported.append(url)
                } catch {
                    report(error)
                }
            }
            let toTrash = imported
            await Task.detached(priority: .utility) {
                for url in toTrash {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }.value
            await noteChanged(made)
            if made.count == 1, let note = made.first {
                open(note)
            } else if !made.isEmpty {
                go(to: .inbox)
            }
        }
    }

    /// "Later": the alert comes back the next time the library opens.
    func postponeRecoveredEdits() {
        recoveredEdits = []
    }
}
