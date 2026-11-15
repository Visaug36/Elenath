import CoreServices
import Foundation

/// What the watcher saw in one batch of file system events.
struct WatchedChange: Sendable {
    /// The changed files and folders, as FSEvents reports them (absolute, symbolic links resolved).
    var paths: [String]
    /// Events were dropped or merged, or the root itself was moved or deleted, so anything may have
    /// changed.
    var needsRescan: Bool
}

/// Watches the library folder with an FSEvents stream, so changes made in Finder or another editor show
/// up while Elenath runs (from Ithil's `RootFolderWatcher`).
///
/// File-level events, delivered on the main queue about 0.3 s after they happen (the first one at once).
/// Create and use it on the main actor. `stop()`, also called on deinit, ends the stream; a watcher
/// watches one folder, so make a new one when the folder changes.
final class LibraryWatcher {
    /// Event flags after which a full rescan is needed.
    static let rescanFlags: FSEventStreamEventFlags = {
        let dropped = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        return FSEventStreamEventFlags(dropped | rescan)
    }()

    private let root: URL
    private let latency: CFTimeInterval
    private let sink: LibraryWatcherSink
    private var stream: FSEventStreamRef?

    init(
        root: URL,
        latency: CFTimeInterval = 0.3,
        onChange: @escaping @MainActor @Sendable (WatchedChange) -> Void
    ) {
        self.root = root
        self.latency = latency
        self.sink = LibraryWatcherSink(handler: onChange)
    }

    deinit {
        stop()
    }

    /// Starts watching. Returns false if the stream couldn't be created or started.
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        // The stream retains the sink through these callbacks and releases it when it is released, so a
        // callback can never reach a freed object.
        let retain: CFAllocatorRetainCallBack = { info in
            guard let info else { return nil }
            _ = Unmanaged<LibraryWatcherSink>.fromOpaque(info).retain()
            return info
        }
        let release: CFAllocatorReleaseCallBack = { info in
            guard let info else { return }
            Unmanaged<LibraryWatcherSink>.fromOpaque(info).release()
        }
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let sink = Unmanaged<LibraryWatcherSink>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the paths are a CFArray of CFStrings.
            let reported = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue()
            var changedPaths: [String] = []
            for case let path as String in reported {
                changedPaths.append(path)
            }
            var needsRescan = false
            for index in 0..<count where flags[index] & LibraryWatcher.rescanFlags != 0 {
                needsRescan = true
            }
            let change = WatchedChange(paths: changedPaths, needsRescan: needsRescan)
            MainActor.assumeIsolated {
                sink.handler(change)
            }
        }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(sink).toOpaque()
        context.retain = retain
        context.release = release
        var options = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        options |= kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        let createFlags = FSEventStreamCreateFlags(options)
        let watched = [root.path] as CFArray
        let since = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let created = FSEventStreamCreate(nil, callback, &context, watched, since, latency, createFlags)
        guard let created else { return false }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Stops watching. Safe to call more than once.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Holds the watcher's handler for the FSEvents callback, which gets it through the stream's context.
private final class LibraryWatcherSink: Sendable {
    let handler: @MainActor @Sendable (WatchedChange) -> Void

    init(handler: @escaping @MainActor @Sendable (WatchedChange) -> Void) {
        self.handler = handler
    }
}
