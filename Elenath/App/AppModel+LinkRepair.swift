import AppKit
import ElenathCore

/// Notes renamed or moved outside Elenath (in Finder, or by another app), and the notes whose links still
/// point to where they were: what the banner at the foot of the window offers to update.
struct LinkRepairOffer: Equatable {
    var moves: [NoteMove]
    /// The notes with links to update, named as `Retrieval.linkingNotes(toMoved:)` names them.
    var linking: [NoteRef]
}

/// One note's text before and after a change Elenath made to it, so the change can be undone while the
/// note still says what Elenath wrote.
struct BodyChange: Sendable {
    var note: NoteRef
    var from: String
    var to: String

    var reversed: BodyChange {
        BodyChange(note: note, from: to, to: from)
    }
}

extension AppModel {
    /// The index recognized notes that were renamed or moved outside Elenath. When other notes link to
    /// them by their old places, the banner offers to update those links (docs/ARCHITECTURE.md, "Links").
    /// Elenath doesn't change the notes until that is accepted.
    func notesMovedOutside(_ moves: [NoteMove]) async {
        guard let services, canEdit, !moves.isEmpty else { return }
        var all = linkRepairOffer?.moves ?? []
        for move in moves {
            if let index = all.firstIndex(where: { $0.to == move.from }) {
                // Moved again: from its first place to its latest, or nowhere if it came back.
                all[index].to = move.to
                if all[index].from == all[index].to {
                    all.remove(at: index)
                }
            } else {
                all.append(move)
            }
        }
        let linking = (try? await services.retrieval.linkingNotes(toMoved: all)) ?? []
        linkRepairOffer = linking.isEmpty ? nil : LinkRepairOffer(moves: all, linking: linking)
    }

    /// "Update Links" on the banner: one step that Undo takes back.
    func acceptLinkRepair() {
        guard let offer = linkRepairOffer else { return }
        linkRepairOffer = nil
        run(String(localized: "Update Links", comment: "Undo action name"), AppModel.repairLinksStep(offer.moves))
    }

    /// "Not Now": the links stay as they are.
    func dismissLinkRepair() {
        linkRepairOffer = nil
    }

    /// Rewrites the links that still point to where the notes were, as Elenath's own renames do. Undo puts
    /// back what each note said, if it still says what Elenath wrote.
    private static func repairLinksStep(_ moves: [NoteMove]) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            await model.session?.flush()
            var rewritten: [BodyChange] = []
            for (container, group) in Dictionary(grouping: moves, by: \.from.container)
            where group.allSatisfy({ $0.to.container == container }) {
                let after = try await services.retrieval.linkContext(for: container)
                // Only moves that still hold: the note is in its new place and nothing took its old one.
                let holding = group.filter { after.catalog.contains($0.to) && !after.catalog.contains($0.from) }
                guard !holding.isEmpty else { continue }
                let linking = try await services.retrieval.linkingNotes(toMoved: holding)
                guard !linking.isEmpty else { continue }
                let before = holding.reduce(after) { context, move in context.moving(move.to, to: move.from) }
                let newPlace = Dictionary(holding.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
                // A linking note is named by where it was; it is read from, and its edits name, where it is.
                var loaded: [NoteRef: LoadedNote] = [:]
                var bodies: [(note: NoteRef, body: String)] = []
                for note in linking {
                    let place = newPlace[note] ?? note
                    guard let read = try? await services.notes.read(place), let text = read.text else { continue }
                    loaded[place] = read
                    bodies.append((note, text.body))
                }
                let edits = LinkRewriter.edits(
                    forMoving: newPlace, notes: bodies, before: before.resolver, after: after.resolver)
                for (place, noteEdits) in Dictionary(grouping: edits, by: \.note) {
                    guard let read = loaded[place], var text = read.text else { continue }
                    let old = text.body
                    text.body = LinkRewriter.apply(noteEdits, to: old)
                    guard text.body != old else { continue }
                    do {
                        // A note that changed on disk meanwhile keeps both versions; it isn't undone later.
                        if case .conflict = try await services.notes.save(text, to: place, expecting: read.stamp) {
                            continue
                        }
                        rewritten.append(BodyChange(note: place, from: old, to: text.body))
                    } catch {
                        model.report(error)
                    }
                }
            }
            await model.bodiesChanged(rewritten.map(\.note))
            return rewritten.isEmpty ? nil : replaceBodiesStep(rewritten.map(\.reversed))
        }
    }

    /// Gives each note the text `to` where it still says `from`. A note that says something else now is
    /// left as it is.
    private static func replaceBodiesStep(_ changes: [BodyChange]) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            await model.session?.flush()
            var done: [BodyChange] = []
            for change in changes {
                guard let read = try? await services.notes.read(change.note), var text = read.text,
                    text.body == change.from
                else { continue }
                text.body = change.to
                do {
                    if case .conflict = try await services.notes.save(text, to: change.note, expecting: read.stamp) {
                        continue
                    }
                    done.append(change)
                } catch {
                    model.report(error)
                }
            }
            await model.bodiesChanged(done.map(\.note))
            return done.isEmpty ? nil : replaceBodiesStep(done.map(\.reversed))
        }
    }

    /// Indexes notes whose text Elenath changed on disk, and shows the open one's new text.
    private func bodiesChanged(_ notes: [NoteRef]) async {
        guard !notes.isEmpty else { return }
        await noteChanged(notes)
        if let session, notes.contains(session.ref) {
            await session.fileMayHaveChanged()
        }
    }
}
