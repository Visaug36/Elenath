import Foundation

/// Why something that was dropped is not imported.
public enum SkipReason: Hashable, Sendable {
    /// Its name starts with a dot: another app's settings (".obsidian"), a trash folder, a system file.
    case hidden
    /// A link to something elsewhere. Only real files are copied.
    case symbolicLink
    /// It could not be read.
    case unreadable
}

/// What will happen to one dropped item (docs/ARCHITECTURE.md, "Import").
public indirect enum ImportItem: Hashable, Sendable {
    /// A Markdown or plain-text file: copied as a note, its bytes unchanged.
    case note(source: URL, title: String)
    /// A rich-text or Word document: its text becomes a note, and the original is kept beside it.
    case document(source: URL, title: String)
    /// A chat exported from WhatsApp: its messages become notes.
    case chatExport(source: URL)
    /// A PDF, an image or anything else: copied as it is.
    case file(source: URL)
    /// A folder: made again, with what is in it.
    case folder(name: String, items: [ImportItem])
    case skipped(source: URL, reason: SkipReason)
}

/// Decides what to do with dropped files and folders, before anything is copied.
public enum ImportPlanner {
    /// File endings that are notes already.
    static let noteExtensions: Set<String> = ["md", "markdown", "txt", "text"]
    /// File endings whose text is turned into a note.
    static let documentExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"]
    /// The name WhatsApp gives the text file of an exported chat on an iPhone.
    static let chatFileName = "_chat.txt"

    /// The plan for `sources`, in their order. Folders are read through to the bottom.
    public static func plan(_ sources: [URL], fileSystem: any FileSystem) -> [ImportItem] {
        sources.map { item(for: $0, fileSystem: fileSystem, depth: 0) }
    }

    /// How many notes, documents, chats and files a plan holds: what a progress bar counts.
    public static func count(_ items: [ImportItem]) -> Int {
        items.reduce(0) { total, item in
            switch item {
            case .folder(_, let items): total + count(items)
            case .skipped: total
            default: total + 1
            }
        }
    }

    private static func item(for url: URL, fileSystem: any FileSystem, depth: Int) -> ImportItem {
        let name = url.lastPathComponent
        if name.hasPrefix(".") {
            return .skipped(source: url, reason: .hidden)
        }
        guard let info = fileSystem.info(at: url) else { return .skipped(source: url, reason: .unreadable) }
        if info.isSymbolicLink {
            return .skipped(source: url, reason: .symbolicLink)
        }
        let fileExtension = url.pathExtension.lowercased()
        let title = fileExtension.isEmpty ? name : String(name.dropLast(fileExtension.count + 1))
        if info.isDirectory {
            if fileExtension == "rtfd" {
                return .document(source: url, title: title)
            }
            guard depth < 32, let contents = try? fileSystem.contentsOfDirectory(at: url) else {
                return .skipped(source: url, reason: .unreadable)
            }
            // An exported chat that was unpacked: the text file with its photos beside it.
            if let chat = contents.first(where: { $0.lastPathComponent.lowercased() == chatFileName }),
                isChat(chat, fileSystem: fileSystem)
            {
                return .chatExport(source: chat)
            }
            let sorted = contents.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive, .numeric])
                    == .orderedAscending
            }
            return .folder(name: name, items: sorted.map { item(for: $0, fileSystem: fileSystem, depth: depth + 1) })
        }
        if noteExtensions.contains(fileExtension) {
            if fileExtension == "txt", isChat(url, fileSystem: fileSystem) {
                return .chatExport(source: url)
            }
            return .note(source: url, title: title)
        }
        if documentExtensions.contains(fileExtension) {
            return .document(source: url, title: title)
        }
        return .file(source: url)
    }

    /// Whether a text file is an exported chat, judged by its first lines.
    private static func isChat(_ url: URL, fileSystem: any FileSystem) -> Bool {
        guard let info = fileSystem.info(at: url), !info.isDirectory, info.byteCount < 64 * 1024 * 1024,
            let data = try? fileSystem.readData(at: url)
        else { return false }
        return ChatExport.isChatExport(String(decoding: data.prefix(8192), as: UTF8.self))
    }
}
