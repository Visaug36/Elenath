import Foundation

/// Edits Elenath couldn't save in the library, kept in its own Recovery folder until the user puts them
/// back (docs/FORMAT.md, "Outside the library").
///
/// A library's copies are in `Recovery/<library id>/`: those of the Inbox's notes at its top, those of a
/// space's notes in a folder named by the space's id. So the text of a note in a sealed space goes back
/// to that space, never to the Inbox. A copy is never replaced: each is written under a name of its own.
public struct RecoveryFolder: Sendable {
    /// One kept copy.
    public struct Copy: Hashable, Sendable {
        public var file: URL
        /// The space the note was in. Nil for the Inbox, and for the copies Elenath 0.1.0 kept, which
        /// didn't say.
        public var space: SpaceID?

        /// "Title (unsaved 2026-11-10 14.30.05)", as the copy is named.
        public var title: String {
            file.deletingPathExtension().lastPathComponent
        }
    }

    /// `Recovery/<library id>`.
    public let folder: URL
    private let fileSystem: any FileSystem

    public init(folder: URL, fileSystem: any FileSystem) {
        self.folder = folder
        self.fileSystem = fileSystem
    }

    /// Writes a new copy of a note's text and returns it.
    ///
    /// The text is written in full under a hidden name first and then given its name, which fails rather
    /// than replace a file that took the name meanwhile; the next number is tried then.
    @discardableResult
    public func keep(
        _ data: Data, title: String, from container: Container, now: Date, timeZone: TimeZone
    ) throws
        -> URL
    {
        let place = self.place(of: container)
        try fileSystem.createDirectory(at: place)
        let temporary = place.appending(
            component: ".elenath-keeping-\(UUID().uuidString)", directoryHint: .notDirectory)
        try fileSystem.writeAtomically(data, to: temporary)
        let wanted = NameSanitizer.recoveryTitle(for: title, now: now, timeZone: timeZone)
        var claimed = Set<String>()
        for _ in 0..<100 {
            let taken = Set(
                ((try? fileSystem.contentsOfDirectory(at: place)) ?? []).map {
                    NameSanitizer.key($0.lastPathComponent)
                }
            ).union(claimed)
            let name = UniqueName.available(wanted) { taken.contains(NameSanitizer.key($0 + ".md")) } + ".md"
            let file = place.appending(component: name, directoryHint: .notDirectory)
            do {
                try fileSystem.moveItem(at: temporary, to: file)
                return file
            } catch {
                guard fileSystem.info(at: file) != nil else {
                    try? fileSystem.removeItem(at: temporary)
                    throw error
                }
                claimed.insert(NameSanitizer.key(name))
            }
        }
        try? fileSystem.removeItem(at: temporary)
        throw CocoaError(.fileWriteFileExists)
    }

    /// Every kept copy: the Inbox's first, then each space's, each by name.
    public func copies() -> [Copy] {
        var found: [Copy] = []
        var spaces: [(SpaceID, URL)] = []
        for item in ((try? fileSystem.contentsOfDirectory(at: folder)) ?? []) {
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), let info = fileSystem.info(at: item), !info.isSymbolicLink, !info.isSpecial
            else { continue }
            if info.isDirectory {
                if let id = UUID(uuidString: name) {
                    spaces.append((SpaceID(id), item))
                }
            } else if name.lowercased().hasSuffix(".md") {
                found.append(Copy(file: item, space: nil))
            }
        }
        found.sort { $0.file.lastPathComponent < $1.file.lastPathComponent }
        for (space, place) in spaces.sorted(by: { $0.1.lastPathComponent < $1.1.lastPathComponent }) {
            let names = ((try? fileSystem.contentsOfDirectory(at: place)) ?? []).map(\.lastPathComponent).filter {
                !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md")
            }
            for name in names.sorted() {
                let file = place.appending(component: name, directoryHint: .notDirectory)
                if let info = fileSystem.info(at: file), !info.isDirectory, !info.isSymbolicLink, !info.isSpecial {
                    found.append(Copy(file: file, space: space))
                }
            }
        }
        return found
    }

    /// Where the copies of a container's notes go.
    private func place(of container: Container) -> URL {
        switch container {
        case .inbox: folder
        case .space(let id): folder.appending(component: id.rawValue.uuidString, directoryHint: .isDirectory)
        }
    }
}
