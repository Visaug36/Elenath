import AppKit
import ElenathCore
import Foundation

/// One change to the library that can be taken back. Doing it gives the step that undoes it, which in
/// turn gives the step that does it again: that is all Undo and Redo need.
struct UndoableStep: Sendable {
    /// Nil when the change can't be undone (the Trash didn't say where the item went, for one).
    let perform: @MainActor @Sendable (AppModel) async throws -> UndoableStep?
}

/// Everything the user can do to notes, folders and spaces. Each change runs on the library's actors,
/// reports a failure in an alert, and registers Undo with the window's undo manager, so ⌘Z and ⇧⌘Z work
/// for it like for typing.
extension AppModel {
    // MARK: - Running steps

    /// Runs a step and registers its undo.
    ///
    /// The work is asynchronous, but the undo is registered at once, while the undo manager still knows
    /// whether this call is itself an undo. That is what makes it a Redo when it is. The registered action
    /// waits for the work and then runs what it returned.
    func run(_ name: String, _ step: UndoableStep) {
        guard canEdit else {
            NSSound.beep()
            return
        }
        stepsInFlight += 1
        let work = Task { @MainActor () -> UndoableStep? in
            defer {
                self.stepsInFlight -= 1
                self.stepsFinished()
            }
            do {
                return try await step.perform(self)
            } catch {
                self.report(error)
                return nil
            }
        }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.run(
                    name,
                    UndoableStep { model in
                        guard let inverse = await work.value else { return nil }
                        return try await inverse.perform(model)
                    })
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: - Notes

    /// ⌘N: a new note where the user is, opened with its title selected.
    func newNote() {
        let place = currentPlace
        newNote(in: place.container, folder: place.folder)
    }

    func newNote(in container: Container, folder: ItemPath, kind: NoteKind = .note) {
        guard canEdit(container) else {
            NSSound.beep()
            return
        }
        let title = String(localized: "Untitled", comment: "The title of a new note")
        run(
            String(localized: "New Note", comment: "Undo action name"),
            UndoableStep { model in
                guard let services = model.services else { return nil }
                let note = try await services.notes.create(title: title, in: folder, container: container, kind: kind)
                await model.noteChanged([note.ref])
                await model.containerChanged([container])
                model.open(note.ref)
                model.requestTitleFocus(for: note.ref)
                return AppModel.trashNoteStep(note.ref)
            })
    }

    /// A new note with a given title, opened at once: what following a link to a note that doesn't exist
    /// yet makes.
    func newNote(titled title: String, in container: Container, folder: ItemPath) {
        guard canEdit(container) else {
            NSSound.beep()
            return
        }
        run(
            String(localized: "New Note", comment: "Undo action name"),
            UndoableStep { model in
                guard let services = model.services else { return nil }
                let note = try await services.notes.create(title: title, in: folder, container: container)
                await model.noteChanged([note.ref])
                await model.containerChanged([container])
                model.open(note.ref)
                return AppModel.trashNoteStep(note.ref)
            })
    }

    /// Renames a note and rewrites the links that point to it.
    func rename(_ note: NoteRef, to title: String) {
        let cleaned = NameSanitizer.sanitizedTitle(title)
        guard cleaned != note.title else { return }
        run(String(localized: "Rename", comment: "Undo action name"), AppModel.renameNoteStep(note, to: cleaned))
    }

    /// Moves a note to another folder or space: also how an Inbox item is filed.
    func move(_ note: NoteRef, to folder: ItemPath, in container: Container) {
        guard canEdit(container), canEdit(note.container) else {
            NSSound.beep()
            return
        }
        let name =
            note.container == .inbox
            ? String(localized: "File", comment: "Undo action name: filing an Inbox item")
            : String(localized: "Move", comment: "Undo action name")
        run(name, AppModel.moveNoteStep(note, to: folder, in: container))
    }

    func trash(_ note: NoteRef) {
        run(String(localized: "Move to Trash", comment: "Undo action name"), AppModel.trashNoteStep(note))
    }

    /// Ticks or unticks a task from a list outside the editor.
    func toggleTask(in note: NoteRef, at location: Int, text: String) {
        run(
            String(localized: "Change Task", comment: "Undo action name"),
            AppModel.toggleTaskStep(in: note, at: location, text: text))
    }

    // MARK: - Folders and files

    func newFolder(in container: Container, folder: ItemPath) {
        guard canEdit(container) else {
            NSSound.beep()
            return
        }
        let name = String(localized: "New Folder", comment: "The name of a new folder")
        run(
            String(localized: "New Folder", comment: "Undo action name"),
            UndoableStep { model in
                guard let services = model.services else { return nil }
                let created = try await services.notes.createFolder(named: name, in: folder, container: container)
                await model.containerChanged([container])
                model.go(to: .folder(container, created))
                return AppModel.trashItemStep(created, in: container)
            })
    }

    func renameFolder(_ folder: ItemPath, in container: Container, to name: String) {
        let cleaned = NameSanitizer.sanitizedTitle(name)
        guard cleaned != folder.name else { return }
        run(
            String(localized: "Rename", comment: "Undo action name"),
            AppModel.renameFolderStep(folder, in: container, to: cleaned))
    }

    /// Moves a file that isn't a note, or a folder.
    func moveItem(_ path: ItemPath, in container: Container, to folder: ItemPath, in destination: Container) {
        guard canEdit(container), canEdit(destination) else {
            NSSound.beep()
            return
        }
        run(
            String(localized: "Move", comment: "Undo action name"),
            AppModel.moveItemStep(path, in: container, to: folder, in: destination))
    }

    func trashItem(_ path: ItemPath, in container: Container) {
        run(
            String(localized: "Move to Trash", comment: "Undo action name"), AppModel.trashItemStep(path, in: container)
        )
    }

    /// Shows a note, a file or a folder in Finder.
    func revealInFinder(_ path: ItemPath, in container: Container) {
        guard let services else { return }
        Task {
            let isFolder = self.folders(in: container).contains(path) || path.isRoot
            guard let url = try? await services.catalog.url(for: path, in: container, isDirectory: isFolder) else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Opens a file that isn't a note in the app the Mac uses for it.
    func openFile(_ path: ItemPath, in container: Container) {
        guard let services else { return }
        Task {
            guard let url = try? await services.catalog.url(for: path, in: container, isDirectory: false) else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    /// The folders known for a container.
    func folders(in container: Container) -> [ItemPath] {
        if case .space(let id) = container {
            return folders[id] ?? []
        }
        return []
    }

    // MARK: - Spaces

    func createSpace(_ draft: Space) {
        run(
            String(localized: "New Space", comment: "Undo action name"),
            UndoableStep { model in
                guard let services = model.services else { return nil }
                let space = try await services.catalog.createSpace(
                    named: draft.name, color: draft.color, symbol: draft.symbol, sealed: draft.isSealed,
                    description: draft.description, keywords: draft.keywords)
                await model.reloadSpaces()
                await model.containerChanged([.space(space.id)])
                model.go(to: .folder(.space(space.id), .root))
                return AppModel.trashSpaceStep(space.id)
            })
    }

    /// Saves a space's settings and, when it changed, its name. Sealing and unsealing take effect at
    /// once.
    /// The spaces onboarding makes. Not undoable: there is nothing before them to go back to.
    func createFirstSpaces(_ drafts: [Space]) async {
        guard let services, canEdit else { return }
        for draft in drafts {
            do {
                _ = try await services.catalog.createSpace(
                    named: draft.name, color: draft.color, symbol: draft.symbol, sealed: draft.isSealed,
                    description: draft.description, keywords: draft.keywords)
            } catch {
                report(error)
            }
        }
        await reloadSpaces()
        await containerChanged(Set(spaces.map { Container.space($0.id) }))
    }

    func updateSpace(_ edited: Space) {
        guard let current = space(edited.id), current != edited else { return }
        run(String(localized: "Edit Space", comment: "Undo action name"), AppModel.updateSpaceStep(edited))
    }

    func trashSpace(_ id: SpaceID) {
        run(String(localized: "Move to Trash", comment: "Undo action name"), AppModel.trashSpaceStep(id))
    }

    func moveSpaces(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = spaces.map(\.id)
        let moving = source.map { order[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        order.removeAll { moving.contains($0) }
        order.insert(contentsOf: moving, at: min(max(insertion, 0), order.count))
        guard order != spaces.map(\.id) else { return }
        run(String(localized: "Reorder Spaces", comment: "Undo action name"), AppModel.reorderSpacesStep(order))
    }

    // MARK: - Steps: notes

    private static func trashNoteStep(_ note: NoteRef) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            if model.session?.ref == note {
                await model.session?.flush()
            }
            let trashed = try await services.notes.trash(note)
            model.removeFromNavigation { $0 == .note(note) }
            await model.noteChanged([note])
            await model.containerChanged([note.container])
            guard let trashed else { return nil }
            return restoreNoteStep(from: trashed, to: note)
        }
    }

    private static func restoreNoteStep(from trashed: URL, to note: NoteRef) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            let path = try await services.notes.restore(from: trashed, to: note.path, in: note.container)
            let restored = NoteRef(container: note.container, path: path)
            await model.noteChanged([restored])
            await model.containerChanged([note.container])
            return trashNoteStep(restored)
        }
    }

    private static func renameNoteStep(_ note: NoteRef, to title: String) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            let isOpen = model.session?.ref == note
            if isOpen {
                await model.session?.flush()
            }
            let context = try await services.retrieval.linkContext(for: note.container)
            let linking = try await services.retrieval.linkingNotes(to: note)
            let renamed = try await services.notes.rename(note, to: title)
            guard renamed != note else { return nil }
            let changed = await model.rewriteLinks(
                moves: [note: renamed], linking: linking, before: context, after: context.moving(note, to: renamed))
            if isOpen {
                await model.session?.follow(to: renamed)
                await model.session?.reload()
            } else {
                model.replaceInNavigation(.note(note), with: .note(renamed))
            }
            await model.noteChanged(changed + [note, renamed])
            return renameNoteStep(renamed, to: note.title)
        }
    }

    private static func moveNoteStep(_ note: NoteRef, to folder: ItemPath, in container: Container) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            let isOpen = model.session?.ref == note
            if isOpen {
                await model.session?.flush()
            }
            let context = try await services.retrieval.linkContext(for: note.container)
            let linking = try await services.retrieval.linkingNotes(to: note)
            // Attachments other notes use are copied, not moved. Until the index is complete, all are.
            let shared = model.isIndexing ? nil : try? await services.retrieval.attachmentNamesShared(by: note)
            let moved = try await services.notes.move(note, to: folder, in: container, sharedAttachments: shared)
            guard moved != note else { return nil }
            // Links follow the note only where they can still reach it.
            let reach = Reach(workplace: Reach.workplace(of: note.container), spaces: model.spaces)
            let after = reach.allows(moved.container) ? context.moving(note, to: moved) : context.removing(note)
            let changed = await model.rewriteLinks(
                moves: [note: moved], linking: linking, before: context, after: after)
            if isOpen {
                await model.session?.follow(to: moved)
                await model.session?.reload()
            } else {
                model.replaceInNavigation(.note(note), with: .note(moved))
            }
            await model.noteChanged(changed + [note, moved])
            await model.containerChanged([note.container, moved.container])
            return moveNoteStep(moved, to: note.path.folder, in: note.container)
        }
    }

    private static func toggleTaskStep(in note: NoteRef, at location: Int, text: String) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            let isOpen = model.session?.ref == note
            if isOpen {
                await model.session?.flush()
            }
            let loaded = try await services.notes.read(note)
            guard var edited = loaded.text else { return nil }
            // The index may be a moment behind: find the task again in the text as it is now.
            let tasks = MarkdownScanner.scan(edited.body).tasks
            guard
                let task = tasks.first(where: { $0.boxRange.location == location && $0.text == text })
                    ?? tasks.first(where: { $0.text == text })
            else { return nil }
            let body = NSMutableString(string: edited.body)
            body.replaceCharacters(in: task.markRange, with: task.isDone ? " " : "x")
            edited.body = body as String
            _ = try await services.notes.save(edited, to: note, expecting: loaded.stamp)
            if isOpen {
                await model.session?.reload()
            }
            await model.noteChanged([note])
            return toggleTaskStep(in: note, at: task.boxRange.location, text: text)
        }
    }

    // MARK: - Steps: folders and files

    private static func trashItemStep(_ path: ItemPath, in container: Container) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            if let open = model.session?.ref, open.container == container, open.path.isInside(path) {
                await model.session?.flush()
            }
            let trashed = try await services.notes.trashItem(path, in: container)
            model.removeFromNavigation { route in
                switch route {
                case .folder(container, let folder): return folder.isInside(path)
                case .note(let note): return note.container == container && note.path.isInside(path)
                default: return false
                }
            }
            await model.containerChanged([container])
            guard let trashed else { return nil }
            return UndoableStep { model in
                guard let services = model.services else { return nil }
                let restored = try await services.notes.restore(from: trashed, to: path, in: container)
                await model.containerChanged([container])
                return trashItemStep(restored, in: container)
            }
        }
    }

    private static func moveItemStep(
        _ path: ItemPath, in container: Container, to folder: ItemPath, in destination: Container
    ) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            if let open = model.session?.ref, open.container == container, open.path.isInside(path) {
                await model.session?.flush()
            }
            let moved = try await services.notes.moveItem(path, in: container, to: folder, in: destination)
            guard !(moved == path && container == destination) else { return nil }
            model.removeFromNavigation { route in
                switch route {
                case .folder(container, let shown): return shown.isInside(path)
                case .note(let note): return note.container == container && note.path.isInside(path)
                default: return false
                }
            }
            await model.containerChanged([container, destination])
            return moveItemStep(moved, in: destination, to: path.folder, in: container)
        }
    }

    private static func renameFolderStep(_ folder: ItemPath, in container: Container, to name: String) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            if let open = model.session?.ref, open.container == container, open.path.isInside(folder) {
                await model.session?.flush()
            }
            let workplace = Reach.workplace(of: container)
            let context = try await services.retrieval.linkContext(for: container)
            let linking = try await services.retrieval.notesLinking(throughFolderNamed: folder.name, from: workplace)
            let renamed = try await services.notes.renameFolder(folder, in: container, to: name)
            guard renamed != folder else { return nil }
            // Every note inside has a new path. The index still has the old ones: that is where the list
            // of what moved comes from.
            var moves: [NoteRef: NoteRef] = [:]
            var after = context
            for note in try await services.retrieval.search(
                SearchQuery(text: "", folder: folder, limit: 100_000), from: workplace)
            {
                guard case .note(let old) = note.item, old.container == container else { continue }
                let rest = old.path.components.dropFirst(folder.components.count)
                guard let path = ItemPath((renamed.components + rest).joined(separator: "/")) else { continue }
                let new = NoteRef(container: container, path: path)
                moves[old] = new
                after = after.moving(old, to: new)
            }
            let changed = await model.rewriteLinks(
                moves: moves, linking: linking + Array(moves.keys), before: context, after: after)
            let open = model.session?.ref
            for (old, new) in moves {
                if open == old {
                    await model.session?.follow(to: new)
                    await model.session?.reload()
                } else {
                    model.replaceInNavigation(.note(old), with: .note(new))
                }
            }
            model.replaceFolderInNavigation(folder, with: renamed, in: container)
            await model.containerChanged([container])
            await model.noteChanged(changed)
            return renameFolderStep(renamed, in: container, to: folder.name)
        }
    }

    // MARK: - Steps: spaces

    private static func updateSpaceStep(_ edited: Space) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services, let current = model.space(edited.id) else { return nil }
            var saved = edited
            var changed: [NoteRef] = []
            if edited.name != current.name {
                let container = Container.space(edited.id)
                if let open = model.session?.ref, open.container == container {
                    await model.session?.flush()
                }
                let workplace = Reach.workplace(of: container)
                let context = try await services.retrieval.linkContext(for: container)
                let linking = try await services.retrieval.notesLinking(
                    throughFolderNamed: current.name, from: workplace)
                saved = try await services.catalog.renameSpace(edited.id, to: edited.name)
                saved.color = edited.color
                saved.symbol = edited.symbol
                saved.isSealed = edited.isSealed
                saved.description = edited.description
                saved.keywords = edited.keywords
                changed = await model.rewriteLinks(
                    moves: [:], linking: linking, before: context, after: context.renaming(edited.id, to: saved.name))
            }
            try await services.catalog.update(saved)
            await model.reloadSpaces()
            await model.noteChanged(changed)
            if let open = model.session?.ref, changed.contains(open) {
                await model.session?.reload()
            }
            return updateSpaceStep(current)
        }
    }

    private static func trashSpaceStep(_ id: SpaceID) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services, let space = model.space(id) else { return nil }
            if let open = model.session?.ref, open.container == .space(id) {
                await model.session?.flush()
            }
            let trashed = try await services.catalog.trashSpace(id)
            await model.reloadSpaces()
            model.contentChanged()
            guard let trashed else { return nil }
            return UndoableStep { model in
                guard let services = model.services else { return nil }
                try await services.catalog.restoreSpace(from: trashed, named: space.name)
                await model.reloadSpaces()
                await model.containerChanged([.space(id)])
                return trashSpaceStep(id)
            }
        }
    }

    private static func reorderSpacesStep(_ order: [SpaceID]) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            let before = model.spaces.map(\.id)
            try await services.catalog.reorderSpaces(order)
            await model.reloadSpaces()
            return reorderSpacesStep(before)
        }
    }

    // MARK: - Links

    /// Rewrites the links that a rename or a move would break, in the notes that have them, and returns
    /// the notes it changed. A note it can't read or save is skipped: its links stay as written.
    private func rewriteLinks(
        moves: [NoteRef: NoteRef], linking: [NoteRef], before: LinkContext, after: LinkContext
    ) async -> [NoteRef] {
        guard let services else { return [] }
        // Every note is named by where it was before the move, and read from where it is now.
        var seen = Set<NoteRef>()
        var loaded: [NoteRef: LoadedNote] = [:]
        var bodies: [(note: NoteRef, body: String)] = []
        for note in linking + Array(moves.keys) where seen.insert(note).inserted {
            let current = moves[note] ?? note
            guard let read = try? await services.notes.read(current), let text = read.text else { continue }
            loaded[current] = read
            bodies.append((note, text.body))
        }
        let edits = LinkRewriter.edits(forMoving: moves, notes: bodies, before: before.resolver, after: after.resolver)
        var changed: [NoteRef] = []
        for (note, noteEdits) in Dictionary(grouping: edits, by: \.note) {
            guard let read = loaded[note], var text = read.text else { continue }
            text.body = LinkRewriter.apply(noteEdits, to: text.body)
            do {
                _ = try await services.notes.save(text, to: note, expecting: read.stamp)
                changed.append(note)
            } catch {
                report(error)
            }
        }
        return changed
    }

    /// Every place in the history that showed `old` or a folder inside it now shows the renamed one.
    func replaceFolderInNavigation(_ old: ItemPath, with new: ItemPath, in container: Container) {
        func moved(_ route: Route) -> Route {
            guard case .folder(container, let folder) = route, folder.isInside(old) else { return route }
            let rest = folder.components.dropFirst(old.components.count)
            guard let path = ItemPath((new.components + rest).joined(separator: "/")) else { return route }
            return .folder(container, path)
        }
        for route in Set(backStack + forwardStack + [route]) {
            let replacement = moved(route)
            if replacement != route {
                replaceInNavigation(route, with: replacement)
            }
        }
    }
}
