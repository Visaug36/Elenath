import ElenathCore
import Foundation

/// What a batch of folder changes did.
struct EventFolderWorkReport: Sendable {
    /// How many folders were renamed, moved, put in the Trash or brought back from it.
    var changed = 0
    var failures: [EventFolderFailure] = []
    /// The folders put in the Trash, where the file system said where they went.
    var trashed: [TrashedEventFolder] = []
}

/// One folder change that failed.
struct EventFolderFailure: Sendable {
    /// The event's title, for the message.
    var title: String
    var error: any Error
}

/// The app's batch operations on event folders. Each runs in one turn on the actor, so nothing else can
/// change the index halfway through.
extension EventFolders {
    /// How many items are in each occurrence's folder (0 when it has none). Never creates a folder.
    func fileCounts(for occurrences: [Occurrence]) -> [Occurrence.ID: Int] {
        var counts: [Occurrence.ID: Int] = [:]
        for occurrence in occurrences {
            counts[occurrence.id] = fileCount(for: occurrence)
        }
        return counts
    }

    /// Where Finder should go for an occurrence: its folder; else its day folder, if that exists; else
    /// the root.
    func finderTarget(for occurrence: Occurrence) -> URL {
        if let folder = existingFolder(for: occurrence) {
            return folder
        }
        let day = root.appending(component: FolderNaming.dayFolderName(for: occurrence), directoryHint: .isDirectory)
        if LocalFileSystem().isDirectory(at: day), contains(day) {
            return day
        }
        return root
    }

    /// Renames and moves the edited event's folders to match the edit (`FolderCarryPlan.moves`). A folder
    /// that can't be moved stays where it is; the others still move.
    func carryFolders(_ update: FolderUpdate) -> EventFolderWorkReport {
        let markedIDs = markedOccurrenceIDs(concerning: update.occurrence, scope: update.scope, in: update.old)
        var report = EventFolderWorkReport()
        for move in FolderCarryPlan.moves(forMarked: markedIDs, update: update) {
            do {
                if try relocate(from: move.from, to: move.to) != nil {
                    report.changed += 1
                }
            } catch {
                report.failures.append(EventFolderFailure(title: move.from.event.title, error: error))
            }
        }
        return report
    }

    /// Puts the folders of the deleted occurrences in the Trash (`FolderCarryPlan.trashTargets`); never
    /// deletes anything.
    func trashFolders(_ deletion: FolderDeletion) -> EventFolderWorkReport {
        let markedIDs = markedOccurrenceIDs(concerning: deletion.occurrence, scope: deletion.scope, in: deletion.old)
        var report = EventFolderWorkReport()
        for target in FolderCarryPlan.trashTargets(forMarked: markedIDs, deletion: deletion) {
            guard existingFolder(for: target) != nil else { continue }
            do {
                if let trashed = try trashFolder(for: target) {
                    report.trashed.append(TrashedEventFolder(occurrence: target, trashedURL: trashed))
                }
                report.changed += 1
            } catch {
                report.failures.append(EventFolderFailure(title: target.event.title, error: error))
            }
        }
        return report
    }

    /// After Undo or Redo: renames and moves the folders of the events it changed so they match the
    /// library put back (`FolderRestorePlan`). Never trashes anything; a folder that can't move stays where
    /// it is, and the others still move.
    func followRestore(_ restore: FolderRestore) -> EventFolderWorkReport {
        let changed = FolderRestorePlan.changedEvents(restore)
        var report = EventFolderWorkReport()
        guard !changed.isEmpty else { return report }
        let markedIDs: [Occurrence.ID]
        if FolderRestorePlan.needsFullScan(changed) {
            markedIDs = Array(markedFolders().keys)
        } else {
            markedIDs = FolderRestorePlan.singleOccurrenceIDs(changed)
        }
        for move in FolderRestorePlan.moves(forMarked: markedIDs, restore: restore, changed: changed) {
            do {
                if try relocate(from: move.from, to: move.to) != nil {
                    report.changed += 1
                }
            } catch {
                report.failures.append(EventFolderFailure(title: move.from.event.title, error: error))
            }
        }
        return report
    }

    /// Brings folders back from the Trash, each to where its occurrence expects it now
    /// (`restoreFolder(from:for:)`). `items` pair each trashed folder with the occurrence as it is now. A
    /// folder that can't come back stays in the Trash.
    func putBack(_ items: [TrashedEventFolder]) -> EventFolderWorkReport {
        var report = EventFolderWorkReport()
        for item in items {
            do {
                _ = try restoreFolder(from: item.trashedURL, for: item.occurrence)
                report.changed += 1
            } catch {
                report.failures.append(EventFolderFailure(title: item.occurrence.event.title, error: error))
            }
        }
        return report
    }

    /// The occurrences with marked folders that a change of `occurrence` can concern: for "all future
    /// events" of a repeating event every marked folder in the root (after a full rescan), otherwise just
    /// the occurrence's own.
    private func markedOccurrenceIDs(
        concerning occurrence: Occurrence,
        scope: SeriesEditing.Scope,
        in library: CalendarDocument
    ) -> [Occurrence.ID] {
        guard scope == .allFutureEvents, FolderCarryPlan.concernsSeries(occurrence, in: library) else {
            return [occurrence.id]
        }
        return Array(markedFolders().keys)
    }
}
