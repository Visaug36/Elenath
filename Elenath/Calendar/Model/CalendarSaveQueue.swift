import ElenathCore
import Foundation
import os

private let logger = Logger(subsystem: "io.github.visaug36.Elenath", category: "CalendarSaveQueue")

/// Saves library snapshots on a `CalendarStore` in the background, one at a time.
///
/// `CalendarModel` updates its library first and then hands the snapshot here, so the UI never waits for the
/// disk. A snapshot that arrives while a save is running replaces any snapshot still waiting (latest
/// wins), so saves never pile up. Snapshots carry an increasing number: one that arrives after a newer
/// one is dropped.
///
/// Each finished save is reported on the main actor with the number it wrote and its error, if any.
actor CalendarSaveQueue {
    typealias Completion = @MainActor @Sendable (_ number: Int, _ error: (any Error)?) -> Void

    private let store: CalendarStore
    private let completion: Completion
    private var pending: PendingSave?
    private var newestNumber = Int.min
    private var isSaving = false

    init(store: CalendarStore, completion: @escaping Completion) {
        self.store = store
        self.completion = completion
    }

    /// Whether a save is running or waiting.
    var isBusy: Bool { isSaving || pending != nil }

    func enqueue(_ library: CalendarDocument, number: Int) {
        guard number > newestNumber else { return }
        newestNumber = number
        pending = PendingSave(library: library, number: number)
        guard !isSaving else { return }
        isSaving = true
        Task { await self.drain() }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            let error = await save(next.library)
            let handler = self.completion
            let number = next.number
            Task { @MainActor in
                handler(number, error)
            }
        }
        isSaving = false
    }

    private func save(_ library: CalendarDocument) async -> (any Error)? {
        do {
            try await store.save(library)
            return nil
        } catch {
            let reason = String(describing: error)
            logger.error("Saving the library failed: \(reason, privacy: .private)")
            return error
        }
    }
}

private struct PendingSave: Sendable {
    var library: CalendarDocument
    var number: Int
}
