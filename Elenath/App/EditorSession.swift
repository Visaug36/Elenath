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
    /// The note is larger than Elenath opens (`NoteLimits.maximumOpenedBytes`): nothing of it is shown.
    case tooLarge
}

/// What closing a note had to do with edits it couldn't save where the note was.
enum EditorSessionNotice: Error, LocalizedError {
    /// The file was gone, so the edits became a note of their own, in `place`.
    case rescued(title: String, copy: String, place: String)
    /// Nothing could be written to the library: the text is in Elenath's Recovery folder.
    case keptInRecovery(title: String)

    var errorDescription: String? {
        switch self {
        case .rescued(let title, let copy, let place):
            String(
                localized:
                    "“\(title)” was moved or deleted outside Elenath while it had unsaved edits. They are in “\(place)” as “\(copy)”."
            )
        case .keptInRecovery(let title):
            String(
                localized:
                    "Elenath couldn't save “\(title)”. Its text is kept, and Elenath offers to put it back the next time the library opens."
            )
        }
    }
}

/// One open note: what the editor shows, autosave, and what happens when the file changes underneath.
///
/// The text view holds the body while the note is open. It registers with `attachTextView`, and the
/// session reads its text when it saves. The session keeps the newest text it has read in
/// `bodyToShow`: when the text view goes away (the window closes, the note is closed) the session takes
/// its text first, so a text view made later shows what was typed and a save after that still has it.
///
/// - **Autosave** half a second after the last change, and at once when the note is closed, the window
///   closes or the app quits. A save is atomic and never overwrites a change made elsewhere.
/// - **Elenath's own steps** (a rename, a move, ticking a task from a list, updating links) save what is
///   typed first and write nothing until they are done (`beginStep`, `endStep`). Then the note shows
///   what the step did to it, and what was typed meanwhile is saved where the note is now.
/// - **Changed on disk:** without unsaved edits the editor shows the new text. With unsaved edits both
///   versions are kept: the edits go into "Title (conflict …)" and the session moves there.
/// - **The file is gone:** nothing is written until the user says (Save It Again). Closing the note with
///   unsaved edits puts them in a new note in the Inbox.
/// - **A save that fails** keeps the text in the editor, puts a copy in Elenath's Recovery folder, says
///   so and tries again. If the note is closed before a save works, the user is told.
@Observable @MainActor
final class EditorSession {
    private(set) var ref: NoteRef
    private(set) var isLoading = true
    private(set) var isReadOnly = false
    private(set) var banner: EditorBanner? = nil
    /// Goes up every time the text view must show `bodyToShow` again: the note was loaded or reloaded.
    private(set) var bodyGeneration = 0
    private(set) var kind: NoteKind = .note
    private(set) var tags: [String] = []
    /// When the file last changed, for "Edited 14:30".
    private(set) var modified: Date? = nil

    /// The newest text the session knows: as loaded, or as last read from the text view. A text view
    /// that is made shows this.
    @ObservationIgnored private(set) var bodyToShow = ""

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let services: LibraryServices?
    @ObservationIgnored private var text: NoteText?
    @ObservationIgnored private var stamp: DiskStamp?
    @ObservationIgnored private var isDirty = false
    /// The file is gone and the user hasn't said what to do: nothing is written until they do.
    @ObservationIgnored private var isDetached = false
    /// Elenath itself moved the note to the Trash while it was open: nothing is written to its place.
    @ObservationIgnored private var wasTrashed = false
    /// How many of Elenath's own steps are running since this note was open. Nothing is saved meanwhile.
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var autosave: Task<Void, Never>?
    /// The write in progress. It gives the notes to index again, which is done after the write is over.
    @ObservationIgnored private var saving: Task<[NoteRef], Never>?
    @ObservationIgnored private var needsFreshIdentity = false
    /// The text view showing the note, and how to read its text (nil once that view is gone).
    @ObservationIgnored private var textViewOwner: ObjectIdentifier?
    @ObservationIgnored private var readTextView: (@MainActor () -> String?)?
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
            needsFreshIdentity =
                (try? await services.retrieval.hasDuplicatedIdentity(ref, from: Reach.workplace(of: ref.container)))
                ?? false
        } catch NoteStoreError.notFound {
            isLoading = false
            isDetached = true
            banner = .missing
        } catch NoteStoreError.tooLarge {
            // Nothing is shown and nothing can be typed, so nothing is ever written over the file.
            isLoading = false
            isReadOnly = true
            banner = .tooLarge
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
        } else if banner == .readOnly || banner == .notUTF8 || banner == .missing || banner == .tooLarge {
            banner = nil
        }
    }

    // MARK: - The text view

    /// A text view takes over showing the note, and gives a way to read its text (nil once it is gone).
    /// Returns the text it must show. If another text view still shows the note, its text is read
    /// first, so nothing typed there is lost.
    func attachTextView(_ owner: AnyObject, read: @escaping @MainActor () -> String?) -> String {
        let id = ObjectIdentifier(owner)
        if textViewOwner != id {
            captureText()
        }
        textViewOwner = id
        readTextView = read
        return bodyToShow
    }

    /// The text view stops showing the note: its text is kept first.
    func detachTextView(_ owner: AnyObject) {
        guard textViewOwner == ObjectIdentifier(owner) else { return }
        captureText()
        textViewOwner = nil
        readTextView = nil
    }

    /// Takes the text view's text as the newest text. Called on every save, and synchronously whenever
    /// the text view may go away.
    func captureText() {
        if let text = readTextView?() {
            bodyToShow = text
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

    /// Saves now if there is anything to save, and waits until it is on disk and indexed. While one of
    /// Elenath's steps runs, it saves nothing: the step's end does.
    func flush() async {
        autosave?.cancel()
        autosave = nil
        await save()
    }

    /// The note is being closed: everything is saved (`saveEverything`), and the text view is let go.
    func close() async {
        await saveEverything(tellsUser: true)
        readTextView = nil
        textViewOwner = nil
    }

    /// Waits for Elenath's steps to finish with the note, saves what is left, and makes sure no edit is
    /// dropped: edits to a file that is gone become a note of their own (`rescueEdits`), and edits that
    /// can't be saved go to Recovery (offered at the next launch). When `tellsUser`, an alert says where the edits
    /// went. Used when the note closes and (without the alert) when the app quits.
    func saveEverything(tellsUser: Bool) async {
        while holds > 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        captureText()
        await flush()
        guard isDirty else { return }
        if wasTrashed {
            // Typed while the note went to the Trash.
            await keepRecoveryCopy(of: editedText())
            isDirty = false
        } else if isDetached {
            await rescueEdits(tellsUser: tellsUser)
        } else {
            // The save failed. The newest text goes to Recovery as well.
            await keepRecoveryCopy(of: editedText())
            isDirty = false
            if tellsUser {
                model?.report(EditorSessionNotice.keptInRecovery(title: ref.title))
            }
        }
    }

    /// The text as it would be saved now.
    private func editedText() -> NoteText {
        var edited = text ?? NoteText(body: "")
        edited.body = bodyToShow
        return edited
    }

    private func save() async {
        // One write at a time. A request that arrives meanwhile waits, then saves what changed since.
        if let saving {
            _ = await saving.value
        }
        guard isDirty, holds == 0, !isReadOnly, !isDetached, var edited = text, let stamp, services != nil else {
            return
        }
        captureText()
        edited.body = bodyToShow
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
        let changed = await task.value
        if saving == task {
            saving = nil
        }
        // Indexing waits behind other work on the index; the next save doesn't wait for it.
        if !changed.isEmpty {
            await model?.noteChanged(changed)
        }
    }

    /// Writes the note and returns the notes to index again.
    private func write(_ edited: NoteText, to target: NoteRef, expecting stamp: DiskStamp) async -> [NoteRef] {
        guard let services else { return [] }
        do {
            switch try await services.notes.save(edited, to: target, expecting: stamp) {
            case .saved(let note), .recreated(let note):
                adopt(note)
                if case .saveFailed = banner {
                    banner = nil
                }
                return [note.ref]
            case .conflict(let mine, _):
                // The file changed elsewhere. The edits are in a note of their own now, and that is the
                // one that stays open.
                ref = mine.ref
                adopt(mine)
                banner = .conflict(original: target)
                model?.sessionMoved(from: target, to: mine.ref)
                return [target, mine.ref]
            }
        } catch NoteStoreError.notFound {
            // The note's space, or the whole library, is gone: as for a file that is gone, nothing is
            // written until the user says, and closing puts the edits somewhere safe.
            isDirty = true
            isDetached = true
            banner = .missing
            return []
        } catch {
            EditorSession.log.error("A note could not be saved", private: String(describing: error))
            isDirty = true
            banner = .saveFailed(error.localizedDescription)
            await keepRecoveryCopy(of: edited)
            scheduleAutosave(after: .seconds(5))
            return []
        }
    }

    /// Puts text that couldn't be saved into Elenath's own Recovery folder, so it survives even if the app
    /// is quit before the library can be written again. Each copy is kept under a name of its own, with
    /// the space it came from (`RecoveryFolder`); the next time the library opens, Elenath offers to put
    /// them back.
    private func keepRecoveryCopy(of edited: NoteText) async {
        guard let services, let libraryID = model?.libraryID else { return }
        let recovery = RecoveryFolder(
            folder: services.support.recovery.appending(
                component: libraryID.rawValue.uuidString, directoryHint: .isDirectory),
            fileSystem: LocalFileSystem())
        let title = ref.title
        let container = ref.container
        let data = edited.data()
        await Task.detached(priority: .utility) {
            do {
                try recovery.keep(data, title: title, from: container, now: .now, timeZone: .current)
            } catch {
                EditorSession.log.error("Could not keep a recovery copy", private: String(describing: error))
            }
        }.value
    }

    /// The file is gone and the note is closing with unsaved edits: they become a note of their own, named
    /// like a conflict copy, and the user is told where. It goes where the note was (its folder is made
    /// again if it was deleted), as long as the note's space is there. The Inbox takes it only from a
    /// space that mixes: a sealed space's text never leaves the space, so when the space is gone it goes
    /// to Recovery, like edits that can't be written anywhere.
    private func rescueEdits(tellsUser: Bool) async {
        guard let services else { return }
        let title = NameSanitizer.conflictTitle(for: ref.title, now: .now, timeZone: .current)
        var places = [(container: ref.container, folder: ref.path.folder)]
        if case .space = ref.container, model?.space(of: ref.container)?.isSealed == false {
            places.append((.inbox, .root))
        }
        for place in places {
            guard
                let copy = try? await services.notes.create(
                    title: title, in: place.folder, container: place.container, kind: kind, body: bodyToShow)
            else { continue }
            isDirty = false
            if tellsUser {
                let placeName = model?.placeName(place.container, place.folder) ?? ""
                model?.report(EditorSessionNotice.rescued(title: ref.title, copy: copy.ref.title, place: placeName))
            }
            await model?.noteChanged([copy.ref])
            return
        }
        await keepRecoveryCopy(of: editedText())
        isDirty = false
        if tellsUser {
            model?.report(EditorSessionNotice.keptInRecovery(title: ref.title))
        }
    }

    /// "Try Again" on the banner of a save that failed.
    func retrySave() {
        Task {
            await flush()
        }
    }

    // MARK: - Elenath's own steps

    /// One of Elenath's steps is about to change notes or folders: what was typed is saved first, and
    /// nothing is written again until `endStep`.
    func beginStep() async {
        await flush()
        holds += 1
    }

    /// The step is done. The note shows what the step did to it, and what was typed meanwhile is saved
    /// where the note is now.
    func endStep() async {
        holds = max(holds - 1, 0)
        guard holds == 0 else { return }
        if wasTrashed {
            return
        }
        await fileMayHaveChanged()
        if isDirty {
            await flush()
        }
    }

    /// Elenath moved this note to the Trash: nothing is written to its place again.
    func noteWasTrashed() {
        wasTrashed = true
        isDetached = true
    }

    // MARK: - Changes from outside

    /// The watcher saw the file change, or everything may have changed, or one of Elenath's steps is done.
    func fileMayHaveChanged() async {
        guard let services, !isLoading, !wasTrashed else { return }
        do {
            let onDisk = try await services.notes.read(ref)
            if isDetached {
                // The file is back.
                isDetached = false
                if banner == .missing {
                    banner = nil
                }
                if !isDirty {
                    show(onDisk)
                    return
                }
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
        guard isDetached, !wasTrashed, text != nil else { return }
        captureText()
        isDetached = false
        banner = nil
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
