import ElenathCore
import Foundation
import Observation

/// What the strip above a note's title says, when something needs saying.
enum EditorBanner: Equatable {
    /// The library or the space comes from a newer Elenath.
    case readOnly
    /// The file isn't UTF-8, so it is shown and never rewritten.
    case notUTF8
    /// The file changed on disk while there were unsaved edits. The edits went into a copy, which is what
    /// is open now; `original` is the note as it is on disk.
    case conflict(original: NoteRef)
    case saveFailed(String)
    /// The file was moved or deleted outside Elenath.
    case missing
}

/// One open note: what the editor shows, autosave, and what happens when the file changes underneath.
///
/// The text view holds the body while the note is open. The session asks it for the text when it saves
/// (`currentBody`), and hands it new text only when the note is loaded or loaded again
/// (`bodyGeneration`).
///
/// - **Autosave** half a second after the last change, and at once when the note is closed, the window
///   closes or the app quits. A save is atomic and never overwrites a change made elsewhere.
/// - **Changed on disk:** without unsaved edits the editor shows the new text. With unsaved edits both
///   versions are kept: the edits go into "Title (conflict …)" and the session moves there.
/// - **A save that fails** keeps the text in the editor, puts a copy in Elenath's Recovery folder, says
///   so and tries again.
@Observable @MainActor
final class EditorSession {
    private(set) var ref: NoteRef
    private(set) var isLoading = true
    private(set) var isReadOnly = false
    private(set) var banner: EditorBanner? = nil
    /// The text for the text view. It changes only when the note is loaded.
    private(set) var bodyToShow = ""
    /// Goes up every time `bodyToShow` must be put into the text view.
    private(set) var bodyGeneration = 0
    private(set) var kind: NoteKind = .note
    private(set) var tags: [String] = []
    /// When the file last changed, for "Edited 14:30".
    private(set) var modified: Date? = nil

    /// The text in the editor right now. Set by the text view.
    @ObservationIgnored var currentBody: (@MainActor () -> String)?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let services: LibraryServices?
    @ObservationIgnored private var text: NoteText?
    @ObservationIgnored private var stamp: DiskStamp?
    @ObservationIgnored private var isDirty = false
    /// The file is gone and the user hasn't said what to do: nothing is written until they do.
    @ObservationIgnored private var isDetached = false
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var needsFreshIdentity = false
    private nonisolated static let log = CoreLog(category: "EditorSession")

    init(ref: NoteRef, model: AppModel) {
        self.ref = ref
        self.model = model
        services = model.services
    }

    // MARK: - Loading

    func load() {
        Task {
            await reload()
        }
    }

    /// Reads the note from disk and shows it, dropping nothing: only call it without unsaved edits.
    func reload() async {
        guard let services else { return }
        do {
            let note = try await services.notes.read(ref)
            show(note)
            needsFreshIdentity = (try? await services.retrieval.hasDuplicatedIdentity(ref)) ?? false
        } catch NoteStoreError.notFound {
            isLoading = false
            isDetached = true
            banner = .missing
        } catch {
            isLoading = false
            model?.report(error)
        }
    }

    private func show(_ note: LoadedNote) {
        adopt(note)
        bodyToShow = note.text?.body ?? note.fallbackText ?? ""
        bodyGeneration += 1
        isDirty = false
        isDetached = false
        isLoading = false
    }

    /// Takes over what is on disk now, without touching the text in the editor.
    private func adopt(_ note: LoadedNote) {
        text = note.text
        stamp = note.stamp
        modified = note.stamp.modified
        kind = note.text?.kind ?? .note
        tags = note.text?.frontMatter?.tags ?? []
        let canEdit = model?.canEdit(ref.container) ?? false
        isReadOnly = note.isReadOnly || !canEdit
        if note.text == nil {
            banner = .notUTF8
        } else if isReadOnly {
            banner = .readOnly
        } else if banner == .readOnly || banner == .notUTF8 || banner == .missing {
            banner = nil
        }
    }

    // MARK: - Editing

    /// The text view changed. Saves half a second after the last change.
    func textDidChange() {
        guard !isReadOnly else { return }
        isDirty = true
        scheduleAutosave(after: .milliseconds(500))
    }

    func setKind(_ newKind: NoteKind) {
        guard !isReadOnly, newKind != kind, var edited = text else { return }
        if edited.frontMatter == nil {
            edited.frontMatter = FrontMatter(lineEnding: edited.lineEnding)
        }
        edited.frontMatter?.kind = newKind
        text = edited
        kind = newKind
        isDirty = true
        scheduleAutosave(after: .milliseconds(100))
    }

    func setTags(_ newTags: [String]) {
        guard !isReadOnly, var edited = text else { return }
        if edited.frontMatter == nil {
            edited.frontMatter = FrontMatter(lineEnding: edited.lineEnding)
        }
        edited.frontMatter?.tags = newTags
        let cleaned = edited.frontMatter?.tags ?? []
        guard cleaned != tags else { return }
        text = edited
        tags = cleaned
        isDirty = true
        scheduleAutosave(after: .milliseconds(100))
    }

    var hasUnsavedChanges: Bool {
        isDirty || saving != nil
    }

    // MARK: - Saving

    private func scheduleAutosave(after delay: Duration) {
        autosave?.cancel()
        autosave = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.save()
        }
    }

    /// Saves now if there is anything to save, and waits until it is on disk.
    func flush() async {
        autosave?.cancel()
        autosave = nil
        await save()
    }

    /// The note is being closed.
    func close() async {
        await flush()
        currentBody = nil
    }

    private func save() async {
        // One save at a time. A request that arrives meanwhile waits, then saves what changed since.
        if let saving {
            await saving.value
        }
        guard isDirty, !isReadOnly, !isDetached, var edited = text, let stamp, services != nil else { return }
        if let currentBody {
            edited.body = currentBody()
        }
        if needsFreshIdentity {
            // A duplicated file carries its original's id. This one gets its own.
            edited.frontMatter?.id = NoteID()
            needsFreshIdentity = false
        }
        isDirty = false
        let target = ref
        let task = Task {
            await self.write(edited, to: target, expecting: stamp)
        }
        saving = task
        await task.value
        saving = nil
    }

    private func write(_ edited: NoteText, to target: NoteRef, expecting stamp: DiskStamp) async {
        guard let services else { return }
        do {
            switch try await services.notes.save(edited, to: target, expecting: stamp) {
            case .saved(let note), .recreated(let note):
                adopt(note)
                if case .saveFailed = banner {
                    banner = nil
                }
                await model?.noteChanged([note.ref])
            case .conflict(let mine, _):
                // The file changed elsewhere. The edits are in a note of their own now, and that is the
                // one that stays open.
                ref = mine.ref
                adopt(mine)
                banner = .conflict(original: target)
                model?.sessionMoved(from: target, to: mine.ref)
                await model?.noteChanged([target, mine.ref])
            }
        } catch {
            EditorSession.log.error("A note could not be saved", private: String(describing: error))
            isDirty = true
            banner = .saveFailed(error.localizedDescription)
            keepRecoveryCopy(of: edited)
            scheduleAutosave(after: .seconds(5))
        }
    }

    /// Puts the text that couldn't be saved into Elenath's own Recovery folder, so it survives even if
    /// the app is quit before the library can be written again.
    private func keepRecoveryCopy(of edited: NoteText) {
        guard let services, let libraryID = model?.libraryID else { return }
        let folder = services.support.recovery.appending(
            component: libraryID.rawValue.uuidString, directoryHint: .isDirectory)
        let name = NameSanitizer.sanitizedTitle(ref.title) + ".md"
        let data = edited.data()
        Task.detached(priority: .utility) {
            let fileSystem = LocalFileSystem()
            do {
                try fileSystem.createDirectory(at: folder)
                try fileSystem.writeAtomically(
                    data, to: folder.appending(component: name, directoryHint: .notDirectory))
            } catch {
                EditorSession.log.error("Could not keep a recovery copy", private: String(describing: error))
            }
        }
    }

    /// "Try Again" on the banner of a save that failed.
    func retrySave() {
        Task {
            await flush()
        }
    }

    // MARK: - Changes from outside

    /// The watcher saw the file change, or everything may have changed.
    func fileMayHaveChanged() async {
        guard let services, !isLoading else { return }
        do {
            let onDisk = try await services.notes.read(ref)
            if isDetached {
                // The file is back.
                if !isDirty {
                    show(onDisk)
                }
                return
            }
            guard let stamp, !onDisk.stamp.hasSameContent(as: stamp) else { return }
            if hasUnsavedChanges {
                // Both sides changed. Saving now keeps both and says so.
                await flush()
            } else {
                show(onDisk)
            }
        } catch NoteStoreError.notFound {
            isDetached = true
            banner = .missing
        } catch {
            EditorSession.log.error("Could not look at a changed note", private: String(describing: error))
        }
    }

    /// The note was renamed or moved: the session goes with it.
    func follow(to new: NoteRef) async {
        let old = ref
        guard new != old else { return }
        ref = new
        isDetached = false
        if banner == .missing {
            banner = nil
        }
        model?.sessionMoved(from: old, to: new)
    }

    /// "Save It Again" on the banner of a note whose file is gone: writes it back where it was.
    func saveAgain() {
        guard isDetached, var edited = text else { return }
        if let currentBody {
            edited.body = currentBody()
        }
        isDetached = false
        banner = nil
        text = edited
        isDirty = true
        Task {
            await flush()
        }
    }

    /// Clears a banner that only informs.
    func dismissBanner() {
        if case .conflict = banner {
            banner = nil
        }
    }
}
