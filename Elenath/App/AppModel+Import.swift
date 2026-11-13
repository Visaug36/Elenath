import AppKit
import ElenathCore
import Foundation

/// A file or a pasted image that comes with a capture.
enum CaptureAttachment: Hashable {
    case file(URL)
    case image(Data, name: String)

    var name: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .image(_, let name): name
        }
    }
}

/// Bringing things in: dropped files, File › Import…, and Quick Capture.
extension AppModel {
    // MARK: - Names of places

    /// "Uni › Physics", "Inbox" or "Inbox › Scans": where something is, in words.
    func placeName(_ container: Container, _ folder: ItemPath = .root) -> String {
        let top: String
        switch container {
        case .inbox:
            top = String(localized: "Inbox")
        case .space(let id):
            top = space(id)?.name ?? ""
        }
        return ([top] + folder.components).joined(separator: " › ")
    }

    /// The URL of an item in the library, for dragging it. Built from names alone: nothing is read.
    func url(for path: ItemPath, in container: Container, isDirectory: Bool = false) -> URL? {
        guard let rootURL else { return nil }
        let base: URL
        switch container {
        case .inbox:
            base = rootURL.appending(component: NameSanitizer.inboxFolderName, directoryHint: .isDirectory)
        case .space(let id):
            guard let space = space(id) else { return nil }
            base = rootURL.appending(component: space.name, directoryHint: .isDirectory)
        }
        return path.url(under: base, isDirectory: isDirectory)
    }

    /// The place in the library a URL names, when it is inside the library folder.
    func libraryItem(at url: URL) -> (container: Container, path: ItemPath)? {
        guard let rootURL else { return nil }
        let root = rootURL.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return nil }
        let inside = Array(parts.dropFirst(root.count))
        guard let first = inside.first, let path = ItemPath(inside.dropFirst().joined(separator: "/")) else {
            return nil
        }
        if NameSanitizer.key(first) == NameSanitizer.key(NameSanitizer.inboxFolderName) {
            return (.inbox, path)
        }
        guard let space = spaces.first(where: { NameSanitizer.key($0.name) == NameSanitizer.key(first) }) else {
            return nil
        }
        return (.space(space.id), path)
    }

    // MARK: - Drops

    /// Something was dropped on a place in the library. Items of the library itself are moved there;
    /// files from anywhere else are copied in.
    func handleDropped(_ urls: [URL], into container: Container, folder: ItemPath) {
        guard canEdit(container) else {
            NSSound.beep()
            return
        }
        var outside: [URL] = []
        for url in urls {
            guard let item = libraryItem(at: url) else {
                outside.append(url)
                continue
            }
            guard !item.path.isRoot, !(item.container == container && item.path.folder == folder) else { continue }
            if ItemPath.isNoteFileName(item.path.name) {
                move(NoteRef(container: item.container, path: item.path), to: folder, in: container)
            } else {
                moveItem(item.path, in: item.container, to: folder, in: container)
            }
        }
        if !outside.isEmpty {
            importItems(outside, into: container, folder: folder)
        }
    }

    // MARK: - Import

    /// File › Import…: asks for files and folders and copies them into the place that is open.
    func chooseAndImport() {
        let urls = FolderAccess.chooseItemsToImport()
        guard !urls.isEmpty else { return }
        let place = currentPlace
        importItems(urls, into: place.container, folder: place.folder)
    }

    /// Copies files and folders into a place. The originals are never moved or changed.
    func importItems(_ urls: [URL], into container: Container, folder: ItemPath) {
        guard let services, canEdit(container), importTask == nil else {
            NSSound.beep()
            return
        }
        importDismissal?.cancel()
        let destination: Route = container == .inbox && folder.isRoot ? .inbox : .folder(container, folder)
        let name = placeName(container, folder)
        importStatus = ImportStatus(
            phase: .running(completed: 0, total: urls.count, currentName: nil), destination: destination,
            destinationName: name)
        importTask = Task {
            defer { importTask = nil }
            let plan = await Task.detached(priority: .userInitiated) {
                ImportPlanner.plan(urls, fileSystem: LocalFileSystem())
            }.value
            do {
                let report = try await services.importer.run(plan, into: folder, container: container) { progress in
                    Task { @MainActor [weak self] in
                        self?.importProgressed(progress)
                    }
                }
                await containerChanged([container])
                importStatus?.phase = .finished(
                    notes: report.notes.count, files: report.files.count, skipped: report.skipped.count,
                    failed: report.failed.count)
                importDismissal = Task {
                    do {
                        try await Task.sleep(for: .seconds(8))
                    } catch {
                        return
                    }
                    if case .finished = importStatus?.phase {
                        importStatus = nil
                    }
                }
            } catch {
                // Cancelled, or the destination couldn't be written. What was copied so far stays.
                await containerChanged([container])
                importStatus = nil
                report(error)
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    func dismissImportStatus() {
        if case .finished = importStatus?.phase {
            importStatus = nil
        }
    }

    private func importProgressed(_ progress: ImportProgress) {
        guard case .running = importStatus?.phase else { return }
        importStatus?.phase = .running(
            completed: progress.completed, total: progress.total, currentName: progress.currentName)
    }

    // MARK: - Attachments

    /// Copies files, and writes pasted pictures, into the `Attachments` folder beside a note, and returns
    /// the text that refers to them, one per line. Empty when nothing could be attached.
    func attach(files: [URL], images: [(Data, String)], to note: NoteRef) async -> String {
        guard let services, canEdit(note.container) else {
            NSSound.beep()
            return ""
        }
        var links: [String] = []
        do {
            if !files.isEmpty {
                for copy in try await services.notes.addAttachments(files, to: note) {
                    links.append(Importer.link(to: copy.name))
                }
            }
            for (data, name) in images {
                let copy = try await services.notes.addAttachment(data, named: name, to: note)
                links.append(Importer.link(to: copy.name))
            }
        } catch {
            report(error)
        }
        if !links.isEmpty {
            await containerChanged([note.container])
        }
        return links.joined(separator: "\n")
    }

    /// The file an embed or a link to a file names, from a note (docs/FORMAT.md, "Embeds"): in
    /// `Attachments` beside the note, then in the note's folder, then anywhere in the same space when
    /// exactly one file there has that name. A Markdown destination is a path from the note's folder.
    func embedURL(for key: EmbedKey, from note: NoteRef) async -> URL? {
        guard let services else { return nil }
        let decoded = key.target.removingPercentEncoding ?? key.target
        if !key.isWikiLink {
            var components = note.path.folder.components
            for part in decoded.split(separator: "/") {
                switch part {
                case ".": continue
                case "..":
                    guard !components.isEmpty else { return nil }
                    components.removeLast()
                default: components.append(String(part))
                }
            }
            guard let path = ItemPath(components.joined(separator: "/")),
                let url = try? await services.catalog.url(for: path, in: note.container, isDirectory: false),
                FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url
        }
        if let url = await services.notes.attachmentURL(named: decoded, for: note) {
            return url
        }
        // Anywhere in the space, when exactly one file has that name.
        let name = decoded.split(separator: "/").last.map(String.init) ?? decoded
        let workplace = Reach.workplace(of: note.container)
        let hits = (try? await services.retrieval.search(SearchQuery(text: name, limit: 200), from: workplace)) ?? []
        let matches = hits.compactMap { hit -> ItemPath? in
            guard case .file(let container, let path) = hit.item, container == note.container,
                NameSanitizer.key(path.name) == NameSanitizer.key(name)
            else { return nil }
            return path
        }
        guard matches.count == 1 else { return nil }
        return try? await services.catalog.url(for: matches[0], in: note.container, isDirectory: false)
    }

    // MARK: - Capture

    /// Where a capture would go, and under which title: what the panel shows while typing.
    func captureDraft(for text: String) -> CaptureDraft? {
        CaptureParser(spaces: spaces).parse(text, now: timeSource.now, timeZone: .current)
    }

    /// Saves a capture as a note, in the Inbox or in the space its first words name, with its files
    /// beside it. Throws when it couldn't be saved, so the panel keeps the text.
    func capture(_ text: String, attachments: [CaptureAttachment]) async throws -> NoteRef {
        guard let services, state == .ready else { throw NoteStoreError.readOnly }
        let now = timeSource.now
        var draft = captureDraft(for: text)
        if draft == nil, !attachments.isEmpty {
            let title = NameSanitizer.captureTitle(firstLine: nil, now: now, timeZone: .current)
            draft = CaptureDraft(destination: .inbox, title: title, body: "")
        }
        guard let draft else { throw NoteStoreError.notANote }
        let container: Container
        switch draft.destination {
        case .inbox: container = .inbox
        case .space(let id, _): container = .space(id)
        }
        let note = try await services.notes.create(
            title: draft.title, in: .root, container: container, body: draft.body)
        var links: [String] = []
        for attachment in attachments {
            switch attachment {
            case .file(let url):
                if let copy = try await services.notes.addAttachments([url], to: note.ref).first {
                    links.append(Importer.link(to: copy.name))
                }
            case .image(let data, let name):
                let copy = try await services.notes.addAttachment(data, named: name, to: note.ref)
                links.append(Importer.link(to: copy.name))
            }
        }
        if !links.isEmpty, var text = note.text {
            let separator = text.body.isEmpty ? "" : "\n"
            text.body += separator + links.joined(separator: "\n") + "\n"
            _ = try await services.notes.save(text, to: note.ref, expecting: note.stamp)
        }
        await noteChanged([note.ref])
        await containerChanged([container])
        return note.ref
    }
}
