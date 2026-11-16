import AppKit
import ElenathCore

/// Notes renamed or moved outside Elenath (in Finder, or by another app) inside one space or the Inbox,
/// and the notes whose links still point to where they were: what the banner at the foot of the window
/// offers to update.
struct LinkRepairOffer: Equatable {
    /// The space or the Inbox the notes moved in. Only a workplace that may read it sees the offer.
    var container: Container
    var moves: [NoteMove]
    /// The notes with links to update, named as `Retrieval.linkingNotes(toMoved:)` names them.
    var linking: [NoteRef]
}

/// A place one of Elenath's own steps wrote to, and when.
struct OwnChange {
    var container: Container
    var path: ItemPath
    var at: ContinuousClock.Instant
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
    /// How long a place Elenath wrote to counts as its own: a refresh that was already running can see
    /// the change a little later.
    private static let ownChangeLifetime: Duration = .seconds(30)

    /// One of Elenath's steps put a note or folder at `path`: a move the index reports there is Elenath's.
    func markOwnChange(_ container: Container, _ path: ItemPath) {
        let now = ContinuousClock.now
        ownChanges.removeAll { now - $0.at > AppModel.ownChangeLifetime }
        ownChanges.append(OwnChange(container: container, path: path, at: now))
    }

    private func isOwnChange(_ note: NoteRef) -> Bool {
        let now = ContinuousClock.now
        return ownChanges.contains {
            now - $0.at <= AppModel.ownChangeLifetime && $0.container == note.container && note.path.isInside($0.path)
        }
    }

    /// The offer the banner shows: the first one, in sidebar order, about a space (or the Inbox) the
    /// current workplace may read. A sealed space's moves show only inside it, and nothing from elsewhere
    /// shows there.
    var visibleLinkRepairOffer: LinkRepairOffer? {
        guard !linkRepairOffers.isEmpty else { return nil }
        let reach = Reach(workplace: workplace, spaces: spaces)
        for container in [Container.inbox] + spaces.map({ Container.space($0.id) }) where reach.allows(container) {
            if let offer = linkRepairOffers[container] {
                return offer
            }
        }
        return nil
    }

    /// The index recognized notes that were renamed or moved outside Elenath. When other notes link to
    /// them by their old places, the banner offers to update those links (docs/ARCHITECTURE.md, "Links").
    /// Elenath doesn't change the notes until that is accepted.
    func notesMovedOutside(_ moves: [NoteMove]) async {
        guard let services, canEdit else { return }
        let outside = moves.filter { $0.from.container == $0.to.container && !isOwnChange($0.to) }
        for (container, group) in Dictionary(grouping: outside, by: \.from.container) {
            var all = linkRepairOffers[container]?.moves ?? []
            for move in group {
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
            let linking =
                all.isEmpty
                ? []
                : ((try? await services.retrieval.linkingNotes(toMoved: all, from: Reach.workplace(of: container)))
                    ?? [])
            linkRepairOffers[container] =
                linking.isEmpty ? nil : LinkRepairOffer(container: container, moves: all, linking: linking)
        }
    }

    /// "Update Links" on the banner: one step that Undo takes back.
    func acceptLinkRepair(_ offer: LinkRepairOffer) {
        linkRepairOffers[offer.container] = nil
        run(String(localized: "Update Links", comment: "Undo action name"), AppModel.repairLinksStep(offer.moves))
    }

    /// "Not Now": the links stay as they are.
    func dismissLinkRepair(_ offer: LinkRepairOffer) {
        linkRepairOffers[offer.container] = nil
    }

    /// Rewrites the links that still point to where the notes were, as Elenath's own renames do. Undo puts
    /// back what each note said, if it still says what Elenath wrote. The open note was saved when the
    /// step began, and shows the result when it ends.
    private static func repairLinksStep(_ moves: [NoteMove]) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
            var rewritten: [BodyChange] = []
            for (container, group) in Dictionary(grouping: moves, by: \.from.container)
            where group.allSatisfy({ $0.to.container == container }) {
                let workplace = Reach.workplace(of: container)
                let after = try await services.retrieval.linkContext(for: container, from: workplace)
                // Only moves that still hold: the note is in its new place and nothing took its old one.
                let holding = group.filter { after.catalog.contains($0.to) && !after.catalog.contains($0.from) }
                guard !holding.isEmpty else { continue }
                let linking = try await services.retrieval.linkingNotes(toMoved: holding, from: workplace)
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
            await model.noteChanged(rewritten.map(\.note))
            return rewritten.isEmpty ? nil : replaceBodiesStep(rewritten.map(\.reversed))
        }
    }

    /// Gives each note the text `to` where it still says `from`. A note that says something else now is
    /// left as it is.
    private static func replaceBodiesStep(_ changes: [BodyChange]) -> UndoableStep {
        UndoableStep { model in
            guard let services = model.services else { return nil }
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
            await model.noteChanged(done.map(\.note))
            return done.isEmpty ? nil : replaceBodiesStep(done.map(\.reversed))
        }
    }
}
