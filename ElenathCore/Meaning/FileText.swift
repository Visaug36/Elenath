import Foundation

/// What a file's text is read as, by its extension (docs/ARCHITECTURE.md, "PDFs, pictures and event files").
/// Every other file is found by its name only.
public enum FileTextKind: String, Hashable, Sendable {
    /// PDFKit's text by page, and Vision for pages that have none (scans).
    case pdf
    /// Vision's text recognition.
    case picture
    /// Read as UTF-8 by the indexer itself, on every platform. Markdown counts here only where it isn't a note:
    /// in an attachments folder or an event folder.
    case plainText

    public init?(fileName: String) {
        guard !fileName.hasPrefix("."), let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return nil
        }
        let ending = fileName[fileName.index(after: dot)...].lowercased()
        if ending == "pdf" {
            self = .pdf
        } else if FileTextKind.pictureEndings.contains(ending) {
            self = .picture
        } else if FileTextKind.plainTextEndings.contains(ending) {
            self = .plainText
        } else {
            return nil
        }
    }

    static let pictureEndings: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
    ]
    static let plainTextEndings: Set<String> = ["txt", "text", "csv", "tsv", "md", "markdown"]
}

/// How much of a file is read, so one huge or hostile file never holds up the rest.
public enum FileTextLimits {
    /// A PDF's first pages; the rest is found by the file's name only.
    public static let maximumPages = 200
    /// Of text per file, as much as `NoteLimits` reads of a note.
    public static let maximumTextBytes = NoteLimits.maximumIndexedBytes
    /// Pages without text (scans) that are recognized, per PDF.
    public static let maximumScannedPages = 20
    /// Larger pictures aren't decoded at all.
    public static let maximumPicturePixels = 100_000_000
    /// Pictures and scanned pages are decoded at most this many pixels on their longer side.
    public static let decodedSide = 4096
    /// A reading that takes longer is given up, and the file is marked unreadable.
    public static let timeout: Duration = .seconds(120)
    /// How often a file's reading may start without finishing (a crash, a quit) before it isn't tried again.
    public static let maximumAttempts = 2
}

/// A file's text: one entry per page of a PDF, one for a picture or a text file.
public struct ExtractedText: Hashable, Sendable {
    public var pages: [String]
    /// A PDF's: its chunks and search hits carry their page.
    public var isPaged: Bool

    public init(pages: [String], isPaged: Bool) {
        self.pages = pages
        self.isPaged = isPaged
    }

    /// The text of a plain text file: its first `FileTextLimits.maximumTextBytes`, as UTF-8 with anything else
    /// replaced, without a character cut in half.
    public static func plainText(_ data: Data) -> ExtractedText {
        let kept = data.count < FileTextLimits.maximumTextBytes ? data : NoteLimits.droppingSplitCharacter(data)
        return ExtractedText(pages: [String(decoding: kept, as: UTF8.self)], isPaged: false)
    }

    /// At most `FileTextLimits.maximumTextBytes` of UTF-8 over all pages, and at most `maximumPages` pages: a page
    /// past the budget is cut at a character, and the pages after it are left out.
    public func limited() -> ExtractedText {
        var budget = FileTextLimits.maximumTextBytes
        var kept: [String] = []
        for page in pages.prefix(FileTextLimits.maximumPages) {
            guard budget > 0 else { break }
            let size = page.utf8.count
            if size <= budget {
                kept.append(page)
                budget -= size
            } else {
                let head = NoteLimits.droppingSplitCharacter(Data(page.utf8.prefix(budget)))
                kept.append(String(decoding: head, as: UTF8.self))
                budget = 0
            }
        }
        return ExtractedText(pages: kept, isPaged: isPaged)
    }

    /// Whether any page has something other than whitespace.
    public var hasText: Bool {
        pages.contains { $0.contains { !$0.isWhitespace } }
    }
}

/// Reads PDFs and pictures (docs/ARCHITECTURE.md, "PDFs, pictures and event files"). The real one is
/// `SystemTextExtractor`; tests use a fake. Plain text never comes here: the indexer reads it.
public protocol TextExtractor: Sendable {
    /// The file's text, or nil when it can't be read as `kind`: not a PDF it can open, locked, broken, too large.
    func text(of url: URL, kind: FileTextKind) async throws -> ExtractedText?
}

/// Runs `work` in a task of its own and waits at most `limit` for it: nil when the time ran out. When the caller is
/// cancelled the wait ends at once with `CancellationError`. Either way the work is cancelled, and a call that
/// doesn't notice (PDFKit's, ImageIO's) finishes on its own, unwaited for.
func withDeadline<Value: Sendable>(
    _ limit: Duration, _ work: @escaping @Sendable () async throws -> Value
) async -> Result<Value, any Error>? {
    let race = DeadlineRace<Value>()
    race.setWorker(
        Task.detached(priority: .utility) {
            do {
                race.finish(.success(try await work()))
            } catch {
                race.finish(.failure(error))
            }
        })
    let timer = Task.detached(priority: .utility) {
        try? await Task.sleep(for: limit)
        race.finish(nil)
    }
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { race.wait(with: $0) }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
    timer.cancel()
    return outcome
}

/// The first of the work, the deadline and the caller's cancellation, resumed once.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    typealias Outcome = Result<Value, any Error>?

    private enum State {
        case running
        case waiting(CheckedContinuation<Outcome, Never>)
        case finished(Outcome)
    }

    private let lock = NSLock()
    private var state = State.running
    private var worker: Task<Void, Never>?

    /// Waits for the outcome, or resumes at once when it is already known.
    func wait(with continuation: CheckedContinuation<Outcome, Never>) {
        let known = lock.withLock { () -> Outcome? in
            switch state {
            case .running, .waiting:
                state = .waiting(continuation)
                return nil
            case .finished(let outcome):
                return .some(outcome)
            }
        }
        if let known {
            continuation.resume(returning: known)
        }
    }

    func setWorker(_ task: Task<Void, Never>) {
        let isOver = lock.withLock { () -> Bool in
            worker = task
            if case .finished = state {
                return true
            }
            return false
        }
        if isOver {
            task.cancel()
        }
    }

    /// Records `outcome` if it is the first, resumes the wait and cancels the work. Whether it was the first.
    @discardableResult
    func finish(_ outcome: Outcome) -> Bool {
        let (isFirst, waiting, task) = lock.withLock {
            () -> (Bool, CheckedContinuation<Outcome, Never>?, Task<Void, Never>?) in
            switch state {
            case .finished:
                return (false, nil, nil)
            case .running:
                state = .finished(outcome)
                return (true, nil, worker)
            case .waiting(let continuation):
                state = .finished(outcome)
                return (true, continuation, worker)
            }
        }
        guard isFirst else { return false }
        waiting?.resume(returning: outcome)
        task?.cancel()
        return true
    }
}
