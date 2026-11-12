import Foundation

/// How far a `FileCopier.copy` call has got.
///
/// Items are what was passed to `copy` (a folder counts as one item); bytes include everything inside
/// folders.
public struct FileCopyProgress: Hashable, Sendable {
    /// Bytes copied so far, across all items.
    public var completedBytes: Int64
    /// The size of all items together, measured before the first one is copied.
    public var totalBytes: Int64
    /// Items copied and in place under their final names.
    public var completedFiles: Int
    /// How many items `copy` was given.
    public var totalFiles: Int
    /// The original name of the item being copied; nil once every item is done.
    public var currentName: String?

    public init(
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        completedFiles: Int = 0,
        totalFiles: Int = 0,
        currentName: String? = nil
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentName = currentName
    }

    /// 0…1 by bytes; by items when there are no bytes to copy (only empty files); 0 when there is
    /// nothing to copy at all.
    public var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        if totalFiles > 0 {
            return min(1, max(0, Double(completedFiles) / Double(totalFiles)))
        }
        return 0
    }
}

public enum FileCopyError: Error, Equatable, Sendable {
    /// The destination isn't inside the library.
    case outsideLibrary
    /// The destination folder doesn't exist.
    case noSuchFolder
    /// An item has no usable name, or a folder would be copied into itself.
    case unusableSource(String)
}

/// Copies the user's files into the library (from Ithil's `FileImport`).
///
/// Originals are never moved or changed. Each item is copied under a hidden temporary name and renamed
/// into place once it is complete, so neither Finder nor Elenath ever shows a half-copied file.
public enum FileCopier {
    /// The start of the hidden name an item has while it is being copied (a UUID follows).
    static let temporaryNamePrefix = ".elenath-copying-"
    /// How often `copy` reports progress while one item is being copied.
    static let progressIntervalMilliseconds = 200

    private static let log = CoreLog(category: "FileCopier")

    /// Copies (never moves) `sources` into `folder`, one at a time, off the caller's thread, and returns
    /// the copies' URLs in the order of `sources`.
    ///
    /// A name that is taken gets a number, as in Finder. On failure or cancellation the temporary item is
    /// removed, items already in place are kept, and the error (or `CancellationError`) is thrown.
    ///
    /// `FileManager.copyItem` clones on APFS, so copies on the same volume are instant. `progress` is
    /// called on a background thread: when each item starts, about every 0.2 s while one copies, and once
    /// at the end with `currentName` nil. Reports never go backwards and end at `totalBytes`.
    ///
    /// Refuses, touching nothing, when `folder` (with `..` and symbolic links resolved) isn't inside
    /// `root`, or isn't an existing folder.
    public static func copy(
        _ sources: [URL],
        into folder: URL,
        root: URL,
        fileSystem: any FileSystem,
        progress: @escaping @Sendable (FileCopyProgress) -> Void = { _ in }
    ) async throws -> [URL] {
        let folder = folder.standardizedFileURL
        guard PathContainment.isStrictlyInside(folder, folder: root) else { throw FileCopyError.outsideLibrary }
        guard fileSystem.isDirectory(at: folder) else { throw FileCopyError.noSuchFolder }
        guard !sources.isEmpty else { return [] }
        try Task.checkCancellation()

        let items = sources.map(\.standardizedFileURL)
        let sizes = items.map { byteCount(of: $0) }
        var state = FileCopyProgress(totalBytes: sizes.reduce(0, +), totalFiles: items.count)
        var copied: [URL] = []
        for (index, source) in items.enumerated() {
            try Task.checkCancellation()
            state.currentName = source.lastPathComponent
            progress(state)
            let destination = try await copyOne(
                source, byteCount: sizes[index], into: folder, root: root, fileSystem: fileSystem, base: state,
                report: progress)
            copied.append(destination)
            state.completedBytes += sizes[index]
            state.completedFiles += 1
        }
        state.currentName = nil
        progress(state)
        return copied
    }

    /// A name for `name` that nothing in `folder` has, compared as the file system compares names.
    public static func availableName(for name: String, in folder: URL, fileSystem: any FileSystem) -> String {
        let taken = Set(
            ((try? fileSystem.contentsOfDirectory(at: folder)) ?? []).map { NameSanitizer.key($0.lastPathComponent) })
        return UniqueName.available(name) { taken.contains(NameSanitizer.key($0)) }
    }

    /// The size of a file, or the total size of the regular files inside a folder. Symbolic links count
    /// as 0 and aren't followed; a missing item is 0.
    public static func byteCount(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeRegular {
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard type == .typeDirectory, let enumerator = FileManager.default.enumerator(atPath: url.path) else {
            return 0
        }
        var total: Int64 = 0
        while enumerator.nextObject() != nil {
            let entry = enumerator.fileAttributes ?? [:]
            if (entry[.type] as? FileAttributeType) == FileAttributeType.typeRegular {
                total += (entry[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    // MARK: - Private

    /// Copies one item to a temporary name in `folder`, reporting its bytes on top of `base` while it
    /// runs, then renames it into place. Removes the temporary item on failure or cancellation.
    private static func copyOne(
        _ source: URL,
        byteCount: Int64,
        into folder: URL,
        root: URL,
        fileSystem: any FileSystem,
        base: FileCopyProgress,
        report: @Sendable (FileCopyProgress) -> Void
    ) async throws -> URL {
        let name = source.lastPathComponent
        guard isUsableName(name), !PathContainment.contains(folder, in: source) else {
            // No name to give the copy, or a folder being copied into itself, which would never end.
            throw FileCopyError.unusableSource(name)
        }
        let temporary = folder.appending(
            component: temporaryNamePrefix + UUID().uuidString, directoryHint: .notDirectory)
        guard PathContainment.isStrictlyInside(temporary, folder: root) else { throw FileCopyError.outsideLibrary }

        let job = CopyJob()
        job.start { try fileSystem.copyItem(at: source, to: temporary) }
        var reportedBytes = base.completedBytes
        var outcome: Result<Void, any Error>?
        while outcome == nil {
            outcome = await job.outcome(waitingUpToMilliseconds: progressIntervalMilliseconds)
            if outcome == nil && !Task.isCancelled {
                let copiedBytes = min(self.byteCount(of: temporary), byteCount)
                if base.completedBytes + copiedBytes > reportedBytes {
                    reportedBytes = base.completedBytes + copiedBytes
                    var update = base
                    update.completedBytes = reportedBytes
                    report(update)
                }
            }
        }

        do {
            try outcome?.get()
            try Task.checkCancellation()
            return try moveIntoPlace(temporary, as: name, in: folder, root: root, fileSystem: fileSystem)
        } catch {
            try? fileSystem.removeItem(at: temporary)
            if !(error is CancellationError) {
                log.error("Could not copy a file", private: "\(name): \(error)")
            }
            throw error
        }
    }

    /// Renames the finished temporary item to a free name, moving on to the next name if another copy
    /// took this one in the meantime.
    private static func moveIntoPlace(
        _ temporary: URL, as name: String, in folder: URL, root: URL, fileSystem: any FileSystem
    ) throws -> URL {
        // A name that would be hidden loses its dots, so a copy is always visible.
        var wanted = name
        while wanted.hasPrefix(".") {
            wanted.removeFirst()
        }
        if wanted.isEmpty {
            wanted = NameSanitizer.fallbackTitle
        }
        let attempts = 5
        var claimed: Set<String> = []
        for attempt in 1...attempts {
            let taken = Set(
                ((try? fileSystem.contentsOfDirectory(at: folder)) ?? []).map {
                    NameSanitizer.key($0.lastPathComponent)
                })
            let finalName = UniqueName.available(wanted) {
                claimed.contains(NameSanitizer.key($0)) || taken.contains(NameSanitizer.key($0))
            }
            let destination = folder.appending(component: finalName, directoryHint: .notDirectory)
            guard PathContainment.isStrictlyInside(destination, folder: root) else {
                throw FileCopyError.outsideLibrary
            }
            do {
                try fileSystem.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                guard fileSystem.info(at: destination) != nil, attempt < attempts else { throw error }
                claimed.insert(NameSanitizer.key(finalName))
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Whether `name` can be a file name in a folder: one path component, not "." or "..".
    private static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}

/// One copy running on a background queue (so blocking file work stays off Swift's cooperative
/// threads), and the copy task waiting for it with a timeout.
private final class CopyJob: @unchecked Sendable {
    typealias Outcome = Result<Void, any Error>

    private let lock = NSLock()
    private var finished: Outcome?
    private var waiter: CheckedContinuation<Outcome?, Never>?
    /// Counts waits, so a timer left over from an earlier wait can't end a later one.
    private var waitNumber = 0

    /// Runs `work` once on a background queue.
    func start(_ work: @escaping @Sendable () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Outcome(catching: work)
            self.finish(with: outcome)
        }
    }

    /// The outcome once `work` has returned, or nil if `milliseconds` pass first.
    func outcome(waitingUpToMilliseconds milliseconds: Int) async -> Outcome? {
        await withCheckedContinuation { continuation in
            install(continuation, milliseconds: milliseconds)
        }
    }

    private func install(_ continuation: CheckedContinuation<Outcome?, Never>, milliseconds: Int) {
        lock.lock()
        if let finished {
            lock.unlock()
            continuation.resume(returning: finished)
            return
        }
        waitNumber += 1
        let number = waitNumber
        waiter = continuation
        lock.unlock()
        let deadline = DispatchTime.now() + .milliseconds(milliseconds)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) {
            self.endWait(number)
        }
    }

    private func finish(with outcome: Outcome) {
        lock.lock()
        finished = outcome
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }

    /// Ends wait `number` with nil if it is still the one waiting.
    private func endWait(_ number: Int) {
        lock.lock()
        guard number == waitNumber, let continuation = waiter else {
            lock.unlock()
            return
        }
        waiter = nil
        lock.unlock()
        continuation.resume(returning: nil)
    }
}
