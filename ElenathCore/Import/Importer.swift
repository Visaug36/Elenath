import Foundation

/// Turns a rich-text document into Markdown. The app's implementation uses AppKit; tests use a fake.
public protocol DocumentConverting: Sendable {
    func markdown(from url: URL) throws -> String
}

public struct ImportProgress: Hashable, Sendable {
    /// Notes, documents, chats and files done so far.
    public var completed: Int
    public var total: Int
    /// The name of what is being imported; nil once everything is done.
    public var currentName: String?

    public init(completed: Int, total: Int, currentName: String?) {
        self.completed = completed
        self.total = total
        self.currentName = currentName
    }
}

/// What an import did.
public struct ImportReport: Hashable, Sendable {
    public var container: Container
    /// The notes that were made.
    public var notes: [NoteRef] = []
    /// The files and folders that were copied as they are.
    public var files: [ItemPath] = []
    public var skipped: [URL] = []
    /// What could not be imported, with the reason. Everything else was.
    public var failed: [Failure] = []

    public struct Failure: Hashable, Sendable {
        public var source: URL
        public var message: String

        public init(source: URL, message: String) {
            self.source = source
            self.message = message
        }
    }

    public init(container: Container) {
        self.container = container
    }
}

/// Carries out an import plan (docs/ARCHITECTURE.md, "Import").
///
/// Everything is copied: originals are never moved or changed. One item that fails doesn't stop the
/// rest, and cancelling leaves what is already done.
public actor Importer {
    /// Messages of a chat sent within this many seconds of each other become one note.
    public static let chatGap: TimeInterval = 5 * 60

    private let noteStore: NoteStore
    private let converter: any DocumentConverting
    private let fileSystem: any FileSystem
    private let timeSource: any TimeSource
    private let timeZone: @Sendable () -> TimeZone

    public init(
        noteStore: NoteStore, converter: any DocumentConverting, fileSystem: any FileSystem,
        timeSource: any TimeSource, timeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.noteStore = noteStore
        self.converter = converter
        self.fileSystem = fileSystem
        self.timeSource = timeSource
        self.timeZone = timeZone
    }

    public func run(
        _ items: [ImportItem], into folder: ItemPath, container: Container,
        progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportReport {
        var report = ImportReport(container: container)
        var state = ImportProgress(completed: 0, total: ImportPlanner.count(items), currentName: nil)
        try await run(items, into: folder, container: container, report: &report, state: &state, progress: progress)
        state.currentName = nil
        progress(state)
        return report
    }

    // MARK: - Private

    private func run(
        _ items: [ImportItem], into folder: ItemPath, container: Container, report: inout ImportReport,
        state: inout ImportProgress, progress: @Sendable (ImportProgress) -> Void
    ) async throws {
        for item in items {
            try Task.checkCancellation()
            switch item {
            case .skipped(let source, _):
                report.skipped.append(source)
                continue
            case .folder(let name, let children):
                do {
                    let created = try await noteStore.createFolder(named: name, in: folder, container: container)
                    report.files.append(created)
                    try await run(
                        children, into: created, container: container, report: &report, state: &state,
                        progress: progress)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    report.failed.append(.init(source: URL(fileURLWithPath: name), message: String(describing: error)))
                }
                continue
            default:
                break
            }
            state.currentName = item.sourceName
            progress(state)
            do {
                try await importOne(item, into: folder, container: container, report: &report)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let source = item.source {
                    report.failed.append(.init(source: source, message: String(describing: error)))
                }
            }
            state.completed += 1
        }
    }

    private func importOne(
        _ item: ImportItem, into folder: ItemPath, container: Container, report: inout ImportReport
    ) async throws {
        switch item {
        case .note(let source, let title):
            report.notes.append(
                try await noteStore.importNote(from: source, title: title, in: folder, container: container))
        case .file(let source):
            report.files += try await noteStore.importFiles([source], into: folder, container: container)
        case .document(let source, let title):
            let text = try converter.markdown(from: source)
            let created = fileSystem.info(at: source)?.created
            let note = try await noteStore.create(
                title: title, in: folder, container: container, body: text, created: created)
            report.notes.append(note.ref)
            // The original stays beside the note, linked from its first line.
            if let original = try await noteStore.addAttachments([source], to: note.ref).first, var body = note.text {
                body.body = "Original: \(Importer.link(to: original.name))\n\n" + body.body
                _ = try await noteStore.save(body, to: note.ref, expecting: note.stamp)
            }
        case .chatExport(let source):
            try await importChat(source, into: folder, container: container, report: &report)
        case .folder, .skipped:
            break
        }
    }

    /// A chat with oneself: each thought becomes a note, dated when it was sent, with its photos and files
    /// in `Attachments`.
    private func importChat(
        _ source: URL, into folder: ItemPath, container: Container, report: inout ImportReport
    ) async throws {
        let data = try fileSystem.readData(at: source)
        let text = (try? NoteText(data: data))?.body ?? NoteStore.decodedLeniently(data)
        let messages = ChatExport.messages(from: text, timeZone: timeZone())
        let mediaFolder = source.deletingLastPathComponent()
        for group in ChatExport.notes(from: messages, gap: Importer.chatGap) {
            try Task.checkCancellation()
            let sent = group.first?.sent ?? timeSource.now
            let firstLine = group.lazy.flatMap { $0.text.split(whereSeparator: \.isNewline) }.first.map(String.init)
            let title = NameSanitizer.captureTitle(firstLine: firstLine, now: sent, timeZone: timeZone())
            let note = try await noteStore.create(title: title, in: folder, container: container, created: sent)
            var parts: [String] = []
            for message in group {
                if !message.text.isEmpty {
                    parts.append(message.text)
                }
                for name in message.attachmentNames {
                    let file = mediaFolder.appending(component: name, directoryHint: .notDirectory)
                    guard fileSystem.info(at: file) != nil,
                        let copy = try await noteStore.addAttachments([file], to: note.ref).first
                    else {
                        parts.append("(\(name) was not in the export)")
                        continue
                    }
                    parts.append(Importer.link(to: copy.name))
                }
            }
            var body = parts.joined(separator: "\n\n") + "\n"
            // One line that is the title, letter for letter, needs no body that repeats it.
            if parts.count == 1, parts[0] == title {
                body = ""
            }
            if var noteText = note.text, !body.isEmpty {
                noteText.body = body
                _ = try await noteStore.save(noteText, to: note.ref, expecting: note.stamp)
            }
            report.notes.append(note.ref)
        }
    }

    /// How a note refers to a file in the `Attachments` folder beside it: an embed for what can be shown
    /// in place, a link for everything else (docs/FORMAT.md, "Attachments").
    public static func link(to attachmentName: String) -> String {
        let embeddable: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg", "pdf"]
        let fileExtension = attachmentName.split(separator: ".").last.map { $0.lowercased() } ?? ""
        if embeddable.contains(fileExtension) && !attachmentName.contains("]") && !attachmentName.contains("|") {
            return "![[\(attachmentName)]]"
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()[]<>/%#?")
        let encoded = attachmentName.addingPercentEncoding(withAllowedCharacters: allowed) ?? attachmentName
        let label = attachmentName.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(label)](\(NameSanitizer.attachmentsFolderName)/\(encoded))"
    }
}

extension ImportItem {
    /// The file or folder the item comes from, when it has one.
    var source: URL? {
        switch self {
        case .note(let source, _), .document(let source, _), .chatExport(let source), .file(let source),
            .skipped(let source, _):
            source
        case .folder:
            nil
        }
    }

    var sourceName: String? {
        switch self {
        case .folder(let name, _): name
        default: source?.lastPathComponent
        }
    }
}
