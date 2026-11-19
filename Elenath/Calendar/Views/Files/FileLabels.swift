import AppKit
import ElenathCore
import UniformTypeIdentifiers

/// The words the files views show and speak. Each sentence is its own localized string.
enum FileLabels {
    // MARK: - Counts

    /// "1 file", "4 files".
    static func count(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 file")
        }
        return String(localized: "\(count) files")
    }

    /// "Files · 4" above the list; just "Files" while the folder hasn't been read yet.
    static func sectionTitle(count: Int?) -> String {
        guard let count else { return String(localized: "Files") }
        return String(localized: "Files · \(count)", comment: "Section label above an event's files, with how many")
    }

    // MARK: - One file

    /// "PDF document · 2.4 MB".
    static func details(of file: EventFile) -> String {
        EventFormatting.joined([kind(of: file), size(of: file)])
    }

    /// "Problem Set 4.pdf, PDF document, 380 KB", for VoiceOver.
    static func accessibilityLabel(of file: EventFile) -> String {
        EventFormatting.spokenJoined([file.name, kind(of: file), size(of: file)])
    }

    /// The kind of item, as Finder names it: "PDF document", "Folder", "Keynote Presentation".
    static func kind(of file: EventFile) -> String {
        if let description = FileTypes.type(of: file).localizedDescription, !description.isEmpty {
            return description
        }
        return file.isDirectory ? String(localized: "Folder") : String(localized: "Document")
    }

    /// "2.4 MB", the way Finder shows file sizes.
    static func size(of file: EventFile) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, file.byteCount), countStyle: .file)
    }

    // MARK: - Adding files

    /// "Drop to add 2 files" while files are dragged over an event.
    static func dropPrompt(itemCount: Int) -> String {
        switch itemCount {
        case 0:
            return String(localized: "Drop to add files")
        case 1:
            return String(localized: "Drop to add 1 file")
        default:
            return String(localized: "Drop to add \(itemCount) files")
        }
    }

    /// "Copied into 14.00 Physics Lecture".
    static func copiedInto(_ folderName: String) -> String {
        String(localized: "Copied into \(folderName)", comment: "Where dropped files go: the event's folder name")
    }

    /// "Copied to Calendar › 2026-10-08 › 10.00 Physics Quiz".
    static func copiedTo(_ path: String) -> String {
        String(localized: "Copied to \(path)", comment: "Where dropped files go: the path of the event's folder")
    }

    /// "Copying 2 of 3…" while an import runs: the item being copied, counted from 1.
    static func copying(_ progress: FileCopyProgress) -> String {
        let total = max(1, progress.totalFiles)
        let current = min(progress.completedFiles + 1, total)
        return String(
            localized: "Copying \(current) of \(total)…", comment: "Progress of copying files into an event")
    }

    /// "3 files to add" in a new event's drop zone: copied once the event is added.
    static func pending(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 file to add")
        }
        return String(localized: "\(count) files to add")
    }

    // MARK: - Deleting

    /// What deleting an event that has files does to them.
    static func deleteMessage(title: String, fileCount: Int) -> String {
        if fileCount == 1 {
            return String(localized: "“\(title)” has 1 file. Its folder will be moved to the Trash.")
        }
        return String(localized: "“\(title)” has \(fileCount) files. Its folder will be moved to the Trash.")
    }

    /// The extra sentence when deleting occurrences of a repeating event.
    static func repeatingDeleteNote(fileCount: Int) -> String {
        switch fileCount {
        case 0:
            return String(
                localized: "The folders of the deleted events, with any files in them, are moved to the Trash.")
        case 1:
            return String(localized: "This one has 1 file. The folders of the deleted events are moved to the Trash.")
        default:
            return String(
                localized: "This one has \(fileCount) files. The folders of the deleted events are moved to the Trash.")
        }
    }
}

/// The types and icons of the items in an event's folder, worked out from their names alone, so drawing
/// the list never reads the disk.
@MainActor
enum FileIcons {
    private static var cache: [UTType: NSImage] = [:]

    /// The system's icon for the item's type (`NSWorkspace.icon(for:)`), as Finder shows it.
    static func icon(for file: EventFile) -> NSImage {
        let type = FileTypes.type(of: file)
        if let cached = cache[type] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[type] = icon
        return icon
    }
}

/// The uniform type of an item from its name and whether it is a folder.
enum FileTypes {
    static func type(of file: EventFile) -> UTType {
        let pathExtension = file.url.pathExtension
        if file.isDirectory {
            return packageType(forExtension: pathExtension) ?? .folder
        }
        if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) {
            return type
        }
        return .data
    }

    /// The package type a folder's extension names (a Keynote document, an app), which Finder shows as a
    /// document; nil for a plain folder.
    private static func packageType(forExtension name: String) -> UTType? {
        guard !name.isEmpty, let type = UTType(filenameExtension: name, conformingTo: .package) else { return nil }
        return type.isDeclared ? type : nil
    }
}
