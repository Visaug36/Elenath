import ElenathCore
import Foundation
import os

/// How one copy of files into an event folder ended.
enum FileImportOutcome: Sendable {
    /// Every item is in the event's folder.
    case finished(count: Int)
    /// The user stopped it, or its event was deleted. Items copied before stay in the folder.
    case cancelled
    /// An item couldn't be copied; the ones before it stay in the folder. `progress` is the last report
    /// (which item failed, how many were done), when there was one.
    case failed(any Error, progress: FileCopyProgress?)
}

/// One copy into an event folder that `FilesController` started: its number (so reports from an earlier
/// copy into the same event are told apart), the occurrence, its task, and whether the user stopped it.
struct FileImportJob {
    var number: Int
    var occurrence: Occurrence
    var task: Task<Void, Never>
    var isCancelled = false
}

/// Lets about ten progress reports a second through to the main actor (always the first and the last),
/// and remembers the latest report for error messages. `FileImport` calls it on background threads.
final class ImportProgressGate: Sendable {
    private struct State: Sendable {
        var lastAdmitted: ContinuousClock.Instant?
        var latest: FileCopyProgress?
    }

    /// The shortest time between two reports that are let through.
    static let interval: Duration = .milliseconds(100)

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Records `progress` and says whether to pass it on.
    func admit(_ progress: FileCopyProgress) -> Bool {
        let now = ContinuousClock.now
        let interval = Self.interval
        return state.withLock { state in
            state.latest = progress
            if progress.currentName != nil, let last = state.lastAdmitted, now - last < interval {
                return false
            }
            state.lastAdmitted = now
            return true
        }
    }

    /// The last report `FileImport` made, passed on or not.
    var latest: FileCopyProgress? {
        state.withLock { $0.latest }
    }
}
