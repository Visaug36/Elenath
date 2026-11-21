# Elenath architecture

Elenath is one Xcode project with three targets:

| Target | What lives there |
|---|---|
| `Elenath` (app) | SwiftUI views, AppKit where SwiftUI falls short (the text editor, floating panels), the `@Observable` app model, user-facing strings (`Localizable.xcstrings`). |
| `ElenathCore` (static framework) | Every piece of logic that can be tested without a window: the folder format, storage, notes, Markdown scanning, links, the index and retrieval, capture, import planning. No SwiftUI, no AppKit, no user-facing strings. |
| `ElenathCoreTests` | Swift Testing tests for `ElenathCore`. Not hosted, so they run without launching the app. |

`ElenathCore` is static so ad-hoc-signed builds don't trip hardened-runtime library validation.

This document is the contract. Each module's API is written here first, then implemented against it, reviewed
independently and integrated; CI on the pushed branch is the judge. Everything below is built for version 0.1
(Phase 2) unless it says otherwise. The signatures show the shape of each API; the code's documentation
comments are the detail.

## Rules that apply everywhere

- **The folder is the truth** (docs/FORMAT.md). Everything else is derived from it and can be rebuilt.
- **The main thread never waits** on disk, the index or the model. Storage and index work run on actors or
  background tasks; the app model updates its in-memory state first and saves asynchronously.
- **Nothing is written outside the library folder**, except Elenath's index, safety copies and recovery files
  in its container. Every operation that creates, writes, moves or trashes checks that its target is inside
  the library, with symbolic links resolved.
- **Nothing is deleted.** Notes, files and folders go to the Trash. Only Elenath's own old backups are removed.
- **Sealing has one choke point.** Only `Retrieval` reads the index, and every query passes through `Reach`
  (see "Index and retrieval"). Nothing else may read a space's content on behalf of another space.
- **Time, the file system, the embedder, the language model and Ithil's folder sit behind protocols**
  (`TimeSource`, `FileSystem`, and later `Embedder`, `BotModel`, `IthilReading`), so tests use fakes. No test
  needs Apple Intelligence.
- **Logs** go through `CoreLog`, which is `os.Logger` on macOS. Note titles, note text, file names and prompts
  are always private.
- **No third-party packages, no network.** `scripts/check-rules.sh` fails the build on a Swift package, on a UI
  import in `ElenathCore`, and on any entitlement beyond the App Sandbox, app-scope bookmarks and user-selected
  read-write files, both in the project and in the built app.
- **macOS 26.0 is the deployment target, arm64 only.** Anything newer sits behind an availability check.

### ElenathCore builds without a Mac

`ElenathCore` and its tests also build and run with the open-source Swift toolchain on Linux
(`scripts/dev/core-test.sh`). That is how most logic is checked in seconds before CI builds the app with Xcode,
and it keeps the door open for the folder format to be read on another platform.

- Code that only exists on Apple platforms sits behind `#if canImport(…)` with a plain fallback (the Trash,
  `os.Logger`), or behind a protocol whose Apple implementation is the only one that imports the framework.
- Tests never depend on the machine's time zone, locale, current date or home folder.

## Foundations (`ElenathCore/`): built

```swift
public protocol TimeSource: Sendable { var now: Date { get } }
public struct SystemTimeSource: TimeSource { public init() }
public struct FixedTimeSource: TimeSource { public init(_ now: Date) }      // tests and -demo

public protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]   // includes hidden files
    func createDirectory(at url: URL) throws                  // with intermediates; fine if it exists
    func readData(at url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws    // temp file in the same folder, then rename
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws                       // only for Elenath's own housekeeping files
    func trashItem(at url: URL) throws
    func trashItemReturningURL(at url: URL) throws -> URL?   // where it went, for Undo (nil = unknown)
    func modificationDate(at url: URL) -> Date?
}
public struct LocalFileSystem: FileSystem { public init() }
```

Added in Phase 2:

```swift
public struct FileIdentity: Hashable, Sendable { }           // volume and file number: survives a rename
public struct FileInfo: Hashable, Sendable {
    public var isDirectory: Bool
    public var byteCount: Int64
    public var modified: Date?
    public var created: Date?
    public var identity: FileIdentity?
}
extension FileSystem { func info(at url: URL) -> FileInfo? }  // nil when nothing is there

public struct CoreLog: Sendable {
    public init(category: String)                             // subsystem io.github.visaug36.Elenath
    public func notice(_ message: StaticString)
    public func error(_ message: StaticString)
    public func error(_ message: StaticString, private detail: String)   // detail is never public
}
```

`CoreLog` has no way to log a dynamic value publicly, so the privacy rule can't be broken by accident.

## Model (`ElenathCore/Model`): built

```swift
public struct LibraryID: Hashable, Sendable, Codable { public var rawValue: UUID }
public struct SpaceID: Hashable, Sendable, Codable { public var rawValue: UUID }
public struct NoteID: Hashable, Sendable, Codable { public var rawValue: UUID }

public enum PaletteColor: String, CaseIterable, Codable, Sendable { case clay, teal, iris, fern, rose }
public enum SpaceColor: Hashable, Sendable, Codable {          // stored as "teal" or "#RRGGBB"
    case palette(PaletteColor)
    case custom(red: UInt8, green: UInt8, blue: UInt8)
    public init?(hexString: String)
    public var hexString: String? { get }
}

public struct Space: Hashable, Sendable, Identifiable {
    public var id: SpaceID
    public var name: String                 // the folder's name
    public var color: SpaceColor
    public var symbol: String               // an SF Symbol name
    public var isSealed: Bool
    public var description: String
    public var keywords: [String]
    public var isReadOnly: Bool             // its space.json comes from a newer Elenath
}

public enum NoteKind: String, CaseIterable, Sendable { case note, idea, goal }

/// Where an item lives: in a space or in the Inbox.
public enum Container: Hashable, Sendable { case space(SpaceID), inbox }

/// A path inside a container, e.g. "Physics/Lecture 7 notes.md". Never absolute, never contains "..".
public struct ItemPath: Hashable, Sendable {
    public static let root: ItemPath
    public init?(_ string: String)
    public var components: [String] { get }
    public var name: String { get }                 // last component
    public var title: String { get }                // name without its extension
    public var folder: ItemPath { get }
    public func appending(_ component: String) -> ItemPath
}

public struct NoteRef: Hashable, Sendable {
    public var container: Container
    public var path: ItemPath
}
```

All model types are `Sendable` and `Hashable`. A note's identity for the app is its `NoteRef`; the `NoteID` in
its front matter is what lets the index follow it when the file moves outside Elenath.

## Names (`ElenathCore/Names`): built

```swift
public enum NameSanitizer {
    public static let maximumTitleLength = 120       // characters; at most 200 UTF-8 bytes
    public static let maximumCaptureTitleLength = 60
    public static let fallbackTitle = "Untitled"
    public static func sanitizedTitle(_ title: String) -> String
    public static func captureTitle(firstLine: String?, now: Date, timeZone: TimeZone) -> String
        // the first line, or "Capture 2026-11-10 14.30"
    public static func conflictTitle(for title: String, now: Date, timeZone: TimeZone) -> String
        // "Title (conflict 2026-11-10 14.30)"
    public static func key(_ name: String) -> String    // case-folded, NFC: how names are compared
    public static func isReservedAtLibraryRoot(_ name: String) -> Bool   // ".elenath", "Inbox", hidden names
    public static func isReservedInSpace(_ name: String) -> Bool         // ".space", "Attachments", "*.board"
}
public enum UniqueName {
    /// "Notes.md", then "Notes 2.md", "Notes 3.md"…, like Finder. The number goes before the extension.
    public static func available(_ name: String, isTaken: (String) -> Bool) -> String
}
```

The rules are the "Names" section of docs/FORMAT.md. Sanitizing follows Ithil's `FolderNaming.sanitizedTitle`.

## Storage (`ElenathCore/Storage`): built

`library.json` and `space.json` are saved by one generic store, which is Ithil's `LibraryStore` with the
document type taken out.

```swift
public protocol VersionedDocument: Codable, Hashable, Sendable {
    static var fileName: String { get }                 // "library.json"
    static var backupPrefix: String { get }             // "library-"
    static var corruptPrefix: String { get }            // "library.corrupt-"
    static var currentSchemaVersion: Int { get }
    static var migrator: SchemaMigrator { get }         // JSON-object steps, version n → n + 1
    var documentID: UUID { get }
}
public struct LibraryDocument: VersionedDocument {      // library.json
    public var id: LibraryID
    public var spaces: [SpaceID]                        // sidebar order
    public var settings: [String: JSONValue]            // unknown keys are kept
}
public struct SpaceDocument: VersionedDocument {        // space.json
    public var id: SpaceID
    public var color: SpaceColor
    public var symbol: String
    public var sealed: Bool
    public var description: String
    public var keywords: [String]
}

public enum DocumentStoreError: Error, Equatable, Sendable {
    case missing                                     // nothing to load and nothing to recover from
    case newerSchema(found: Int, supported: Int)     // never overwritten: opened read-only
    case unreadable(String)                          // damaged, and no good backup or safety copy
    case readOnly                                    // save() after a newerSchema load
}
public struct RecoveryReport: Hashable, Sendable {
    public enum Source: Hashable, Sendable { case backup(URL), safetyCopy(URL) }
    public var source: Source
    public var recoveredSavedAt: Date?
    public var damagedFileMovedTo: URL?
}
public struct DocumentLoad<Document: VersionedDocument>: Sendable {
    public var document: Document
    public var recovery: RecoveryReport?
}

public actor DocumentStore<Document: VersionedDocument> {
    public init(owner: URL,                            // the library folder, or a space's folder
                metadataFolderName: String,            // ".elenath" or ".space"
                safetyDirectory: URL,                  // the safety copy is <safetyDirectory>/<document id>.json
                knownDocumentID: UUID?,                // finds the safety copy when the file is damaged
                fileSystem: any FileSystem, timeSource: any TimeSource,
                backupInterval: TimeInterval, maxBackups: Int)
    public func load() throws -> DocumentLoad<Document>
    public func create(_ document: Document) throws    // refuses when the file already exists
    public func save(_ document: Document) throws
}

public enum LibraryFolderPolicy {                      // Ithil's RootFolderPolicy, for ".elenath"
    public static let defaultFolderName = "Elenath"
    public static func isLibrary(_ url: URL, fileSystem: any FileSystem) -> Bool
    public static func isEffectivelyEmpty(_ url: URL, fileSystem: any FileSystem) -> Bool
    public static func libraryFolder(forChosen url: URL, fileSystem: any FileSystem) throws -> URL
}
public enum LibraryMove {
    public static func move(from oldRoot: URL, to newRoot: URL, fileSystem: any FileSystem) throws
}
/// What a batch of FSEvents paths means: noise, a container's index to refresh, a note to look at again,
/// or the catalog to open again.
public enum LibraryPathClassifier {
    public static func classify(paths: [String], rootPath: String, spaces: [Space]) -> LibraryChange
}
```

- Loading, saving, backups, the safety copy, recovery and newer schemas behave exactly as described in
  docs/FORMAT.md ("Saving, backups and recovery") and as in Ithil: the first candidate that decodes wins, by
  newest `savedAt`; the damaged file is set aside, never overwritten; nothing is written when the folder is
  missing.
- **Choosing a folder:** an empty folder or an existing library is used as is. Any other folder gets an
  `Elenath` subfolder (`Elenath 2`… if that name is taken by something else).
- `LibraryMove` moves the spaces' folders and the Inbox, then `.elenath` last, leaves loose files, and moves
  everything back if one item fails.

### The library on disk

```swift
public struct LibrarySnapshot: Sendable {
    public var id: LibraryID
    public var spaces: [Space]                        // in sidebar order
    public var isReadOnly: Bool
    public var recoveries: [RecoveryReport]           // tell the user
    public var sealedByDefault: [SpaceID]             // spaces whose space.json could not be restored
}
public struct FolderListing: Sendable {
    public var folders: [ItemPath]
    public var notes: [NoteEntry]                     // path, title, modified, byteCount
    public var files: [FileEntry]                     // other documents
}

public actor LibraryCatalog {
    public init(root: URL, safetyDirectory: URL, knownLibraryID: LibraryID? = nil,
                fileSystem: any FileSystem, timeSource: any TimeSource,
                backupInterval: TimeInterval = 15 * 60, maxBackups: Int = 50)
    public nonisolated let root: URL
    public func open() async throws -> LibrarySnapshot     // loads library.json, finds and adopts spaces
    public func create() async throws -> LibrarySnapshot   // a brand-new library in an empty folder
    public func spaces() -> [Space]
    public func createSpace(named name: String, color: SpaceColor, symbol: String, sealed: Bool,
                            description: String, keywords: [String]) async throws -> Space
    public func update(_ space: Space) async throws        // everything but the name
    public func renameSpace(_ id: SpaceID, to name: String) async throws -> Space
    public func reorderSpaces(_ order: [SpaceID]) async throws
    public func trashSpace(_ id: SpaceID) async throws -> URL?   // the whole folder goes to the Trash
    public func folderURL(of container: Container) throws -> URL
    public func url(for path: ItemPath, in container: Container, isDirectory: Bool) throws -> URL
    public func ensureInbox() throws
    public func listing(of folder: ItemPath, in container: Container) throws -> FolderListing
    public nonisolated func contains(_ url: URL) -> Bool   // inside the root, links resolved
}
public enum LibraryCatalogError: Error, Equatable, Sendable {
    case readOnly, unknownSpace, nameTaken(String), reservedName(String), outsideLibrary, notOpen
}
```

- `open()` reads every visible top-level folder except `Inbox` as a space. A folder Elenath has never seen
  gets a `space.json` (not sealed). A `space.json` that can't be read or restored makes the space sealed and
  lists it in `sealedByDefault`; so does a `.space` folder that vanished from a space Elenath knows, when
  its safety copy is gone too. To tell the two apart, the safety directory keeps a record of which folder
  was which space (`<library id>/folders.json`).
- Every path it hands out is checked with `PathContainment`: inside the library, symbolic links resolved.
  Listings leave out hidden items, Elenath's own folders, `Attachments`, board packages and links.
- Sealing a space, or unsealing one, is `update(_:)`. The index needs no rebuild: each space has its own
  database, and `Reach` decides at query time what may be read.

## Notes (`ElenathCore/Notes`): built

```swift
public enum LineEnding: Sendable { case lf, crlf }
public enum NoteTextError: Error, Sendable { case notUTF8 }

/// A note file split into its parts without losing a byte.
public struct NoteText: Hashable, Sendable {
    public var hasByteOrderMark: Bool
    public var lineEnding: LineEnding          // what new lines Elenath adds will use
    public var frontMatter: FrontMatter?
    public var body: String
    public init(data: Data) throws(NoteTextError)
    public init(newNoteWithID id: NoteID, created: Date, timeZone: TimeZone, kind: NoteKind, body: String)
    public func data() -> Data
}

/// The front matter block. Its text is kept as written; each setter rewrites only its own key's lines.
public struct FrontMatter: Hashable, Sendable {
    public var id: NoteID?
    public var created: Date?
    public var kind: NoteKind
    public var tags: [String]
    public var goals: [String]                 // link targets, without the brackets
    public var event: EventLink?
    public var rawText: String { get }         // the block between the two "---" lines
}
public struct EventLink: Hashable, Sendable { public var eventID: UUID; public var day: String }
```

- **Round trip:** `try NoteText(data: d).data() == d` for every `d` that is valid UTF-8, whatever its front
  matter, line endings or byte order mark. Reading a key never changes the text.
- Changing a key touches that key's lines only. Unknown keys, comments, order and quoting stay byte for byte.
- A key at its default is removed rather than written (`kind: note`, an empty `tags`).

```swift
/// What a file looked like when Elenath last read or wrote it.
public struct DiskStamp: Hashable, Sendable {
    public var contentHash: UInt64
    public var byteCount: Int
    public var modified: Date?
}
public struct LoadedNote: Sendable {
    public var ref: NoteRef
    public var text: NoteText?                 // nil when the file isn't UTF-8: shown read-only as raw text
    public var stamp: DiskStamp
    public var isReadOnly: Bool
}
public enum SaveOutcome: Sendable {
    case saved(DiskStamp)
    case conflict(yourEditsSavedAs: NoteRef, stamp: DiskStamp)   // the file changed on disk meanwhile
    case recreated(DiskStamp)                                     // the file was gone; it was written again
}

public actor NoteStore {
    public init(catalog: LibraryCatalog, fileSystem: any FileSystem, timeSource: any TimeSource,
                timeZone: @escaping @Sendable () -> TimeZone = { .current },
                makeID: @escaping @Sendable () -> NoteID = { NoteID() })
    public func read(_ ref: NoteRef) async throws -> LoadedNote
    public func save(_ text: NoteText, to ref: NoteRef, expecting stamp: DiskStamp) async throws -> SaveOutcome
    public func create(title: String, in folder: ItemPath, container: Container, kind: NoteKind = .note,
                       body: String = "", created: Date? = nil) async throws -> LoadedNote
    public func importNote(from source: URL, title: String, in folder: ItemPath, container: Container) async throws -> NoteRef
    public func importFiles(_ sources: [URL], into folder: ItemPath, container: Container,
                            progress: ...) async throws -> [ItemPath]
    public func rename(_ ref: NoteRef, to title: String) async throws -> NoteRef
    public func move(_ ref: NoteRef, to folder: ItemPath, in container: Container,
                     sharedAttachments: Set<String>? = nil) async throws -> NoteRef
    public func moveItem(_ path: ItemPath, in container: Container, to folder: ItemPath,
                         in destination: Container) async throws -> ItemPath
    public func trash(_ ref: NoteRef) async throws -> URL?
    public func trashItem(_ path: ItemPath, in container: Container) async throws -> URL?
    public func restore(from trashed: URL, to path: ItemPath, in container: Container) async throws -> ItemPath
    public func createFolder(named name: String, in folder: ItemPath, container: Container) async throws -> ItemPath
    public func renameFolder(_ folder: ItemPath, in container: Container, to name: String) async throws -> ItemPath
    public func addAttachments(_ sources: [URL], to ref: NoteRef, progress: ...) async throws -> [ItemPath]
    public func addAttachment(_ data: Data, named name: String, to ref: NoteRef) async throws -> ItemPath
    public func attachmentURL(named name: String, for ref: NoteRef) async -> URL?
}
```

- **Autosave is atomic.** `save` writes a temporary file beside the note and renames it over the note. A save
  that is interrupted leaves the old note whole; tests cut writes midway to prove it.
- **Conflicts.** `save` compares the file on disk with `stamp`. If the file changed (another editor, a sync)
  the note on disk is left as it is, the text being saved goes to `Title (conflict yyyy-MM-dd HH.mm).md`
  beside it, and the outcome says so. Nothing is ever picked silently.
- **First edit of a foreign note** adds `id` and `created` to its front matter (docs/FORMAT.md).
- **Rename and move** change the file only. The links that point to it are rewritten by the caller with
  `LinkRewriter`, in the same undo step. A move takes the note's attachments along: moved when the index says
  no other note uses them (`Retrieval.attachmentNamesShared(by:)`), copied otherwise.
- **A folder never holds two notes with one title**, whatever their extensions, since a link couldn't tell
  them apart. A second "Lecture 7" is "Lecture 7 2", never "Lecture 8".
- **Attachments** are copied under a hidden temporary name and renamed into place when complete, with
  Finder-style numbers on clashes (Ithil's `FileImport`). Originals are never moved.
- **A vanished space or library is never brought back.** Saving a note whose file is gone writes it again,
  but only while its space's folder (for the Inbox, the library's folder) is there; otherwise `save` and
  `create` throw `notFound` and write nothing.
- **A note that can't be saved** (the disk is full, the drive is gone) is never dropped: the app keeps the
  text, writes it to `Recovery/` in its container, says what happened and retries.
- **Edits to a note whose file vanished** become a conflict copy where the note was (its folder is made
  again), while its space is there. Only a space that mixes may send them to the Inbox; a sealed space's
  text never leaves the space, and goes to Recovery when the space is gone.
- **Files that aren't regular files** (named pipes, sockets, devices) are never opened: `readData` refuses
  them before opening, and listings, the index, attachments and imports leave them out.

### Recovery (`RecoveryFolder`)

```swift
public struct RecoveryFolder: Sendable {
    public struct Copy: Hashable, Sendable {
        public var file: URL
        public var space: SpaceID?               // nil: the Inbox, or a copy kept by 0.1.0
        public var title: String                 // "Title (unsaved 2026-11-10 14.30.05)"
    }
    public init(folder: URL, fileSystem: any FileSystem)   // Recovery/<library id>
    public func keep(_ data: Data, title: String, from container: Container, now: Date,
                     timeZone: TimeZone) throws -> URL
    public func copies() -> [Copy]
}
```

- Copies of the Inbox's notes are at the top of the library's Recovery folder, those of a space's notes in a
  folder named by the space's id (docs/FORMAT.md, "Outside the library").
- A copy is never replaced: it is written under a hidden name and then renamed, which fails rather than
  replace a copy that took the name meanwhile, and the next number is tried. A long title is shortened so
  the time always fits.
- At the next launch each copy is put back at the top of its own space or of the Inbox. A copy whose space is
  gone stays in Recovery and is shown in Finder: it may come from a sealed space.

### Opening links and files (`OpenPolicy`)

```swift
public enum OpenPolicy {
    public enum Decision: Hashable, Sendable { case open, ask }
    public static func decision(forLink address: String) -> Decision
    public static func decision(forFileNamed name: String) -> Decision
}
```

- Web and mail links (`http`, `https`, `mailto`) open at once. Any other scheme asks first, naming the app
  that would open it.
- Documents, pictures, sound and video open at once, by extension. Anything else, unknown kinds included,
  asks first, with "Show in Finder" as the default: an app, a script, an installer or a link file could run
  something.
- A Markdown link to a file opens regular files only.

### Limits (`NoteLimits`)

| | |
|---|---|
| A note isn't opened over | 16 MB (`NoteStore.read` throws `tooLarge`; a banner offers another app) |
| A note is shown as plain text over | 2 MB (typing stays quick) |
| The index reads a note's first | 4 MB |
| Text is imported as a file, not a note, over | 16 MB |
| A document's text isn't converted over | 64 MB (it is imported as a file) |
| A settings file (library.json, space.json) is refused over | 8 MB or 64 levels of nesting |

`FileSystem.readData(at:upTo:)` reads a file's beginning without reading the rest.

## Markdown (`ElenathCore/Markdown`): built

A small scanner of our own: the editor needs source ranges for every construct, which Foundation's Markdown
parsing doesn't give. Ranges are UTF-16 offsets into the body, the unit the text view uses.

```swift
public struct MarkdownScan: Sendable {
    public var lines: [LineInfo]                  // each line's range and block kind
    public var spans: [InlineSpan]                // emphasis, code, links, tags, task boxes, markers
    public var headings: [Heading]                // level, text, range
    public var links: [LinkSpan]                  // wiki links, embeds and Markdown links
    public var tags: [TagSpan]
    public var tasks: [TaskSpan]                  // text, isDone, the range of the box
}
public enum BlockKind: Hashable, Sendable {
    case paragraph, heading(level: Int), quote, listItem(indent: Int), codeFence, codeBlock, table,
         thematicBreak, blank
}
/// What the scanner carries from one line to the next, so the editor can rescan only what an edit changed.
public struct BlockState: Hashable, Sendable { public static let start: BlockState }

public enum MarkdownScanner {
    public static func scan(_ body: String) -> MarkdownScan
    public static func scanLines(_ body: String, in range: NSRange, from state: BlockState)
        -> (lines: [LineInfo], spans: [InlineSpan], endState: BlockState)
}
```

- Blocks: ATX headings, block quotes, bullet and numbered lists with tasks, fenced and indented code, pipe
  tables, thematic breaks. Inlines: emphasis, strong, strikethrough, code spans, links, images, wiki links,
  embeds, tags, bare URLs.
- Nothing inside code is a link, a tag or a task.
- `scanLines` is incremental: after an edit the editor rescans from the first changed line until the block
  state at a line's end equals what it was before the edit. A 1 MB note never rescans whole on a keystroke.
- **Linear time, whatever the text.** Brackets and parentheses are matched once per stretch of a line, a code
  span looks up the next run of backticks of its length, a URL's parentheses are counted once, and emphasis
  keeps CommonMark's "openers bottom", so no line costs more than a few passes over it. `HostileInputTests`
  checks that pathological notes take time that grows with their length, not faster.
- Tags and tasks follow docs/FORMAT.md.

## Links (`ElenathCore/Links`): built

```swift
public struct WikiLink: Hashable, Sendable {
    public var target: String                    // "Title", "Folder/Title", "Space/Folder/Title"
    public var heading: String?                  // after "#"
    public var shownText: String?                // after "|"
    public var isEmbed: Bool
    public init?(inner: String, isEmbed: Bool)   // the text between "[[" and "]]"
    public var written: String { get }           // "[[Folder/Title#Heading|shown]]"
}
public enum LinkResolution: Hashable, Sendable {
    case resolved(NoteRef)
    case ambiguous([NoteRef])
    case unresolved
}
/// The notes a link may point to: every note within one `Reach`, by title.
public struct TitleCatalog: Sendable { }
public struct LinkResolver: Sendable {
    public init(catalog: TitleCatalog, spaceNames: [SpaceID: String])
    public func resolve(_ link: WikiLink, from source: NoteRef) -> LinkResolution
    public func shortestTarget(for note: NoteRef, from source: NoteRef) -> String
}
public struct LinkEdit: Hashable, Sendable {
    public var note: NoteRef
    public var range: NSRange                    // in that note's body
    public var replacement: String
}
public enum LinkRewriter {
    /// The edits that keep every link pointing at a note after it is renamed or moved.
    public static func edits(forMoving old: NoteRef, to new: NoteRef, linkingNotes: [(NoteRef, String)],
                             before: LinkResolver, after: LinkResolver) -> [LinkEdit]
}
```

- Resolution is the "Links" section of docs/FORMAT.md, and it is pure: the resolver only sees the
  `TitleCatalog` it is given. `Retrieval` builds that catalog from a `Reach`, so a link can never resolve
  across a sealed boundary.
- `LinkRewriter` only rewrites links that resolved to the note before the move. Shown text and headings are
  kept. The app applies the edits and the file move as one undo step.
- When a file is renamed or moved outside Elenath, the indexer recognizes it (by `id`, else by file identity,
  else by content hash) and reports it in `IndexReport.moved`. `Retrieval.linkingNotes(toMoved:)` finds the
  notes whose links pointed at it, judged with the catalog as it was (every moved note back in its old place).
  The app offers the same rewrite in a banner ("Update Links"); accepted, it is one undo step, and Undo puts
  back each note's text if the note still says what Elenath wrote. Nothing is changed until it is accepted.
  Moves are looked for whenever the watcher's changes are processed and when the index is refreshed at launch;
  while one of Elenath's own steps runs, the watcher's changes wait, so its own renames are never offered.

## Index and retrieval (`ElenathCore/Index`): built

The index is a cache that can be rebuilt at any time: one SQLite database per space and one for the Inbox,
in Elenath's container (`Index/<library id>/<space id>.sqlite`), never inside the library. SQLite is the
system's library. Its FTS5 and trigram tokenizer are checked by `SQLiteProbeTests`.

Version 0.1 indexes notes (title, text, links, tags, tasks) and the names of other files. Chunks, vectors and
the text of PDFs, pictures and event files come in 0.3 ("Meaning" below).

### Sealing: `Reach` is the choke point

```swift
/// Where the user is working.
public enum Workplace: Hashable, Sendable {
    case space(SpaceID)
    case everywhere            // Today, search everywhere, jump to a note
    case inbox
}

/// The containers whose content a workplace may read. This is the only place that decides it.
public struct Reach: Hashable, Sendable {
    public let workplace: Workplace
    public let containers: Set<Container>
    public init(workplace: Workplace, spaces: [Space])
    public func allows(_ container: Container) -> Bool
}
```

| Workplace | May read |
|---|---|
| a sealed space | that space only |
| an unsealed space | every unsealed space |
| everywhere | every unsealed space |
| the Inbox | the Inbox only |
| a space that doesn't exist | nothing |

- A sealed space's content is read only from inside it, and nothing else is read from inside it. The Inbox is
  read only from the Inbox.
- **One crossing:** `filingDestinations()` returns every space's name, description and keywords, sealed ones
  included, so something can be filed there. For a sealed space it returns no folder names.
- `SpaceIndex`, the type that opens a database, is internal to `ElenathCore`. The app and Nano bot can only
  ask `Retrieval`.
- `Retrieval` takes a `Workplace`, never a `Reach`: it builds the reach itself from the spaces as they are
  now, so a caller can't hand it a wider one. **Every query takes the workplace it is asked from**, also the
  queries about one note (`backlinks`, `resolve`, `note`, `linkContext` …): asked about a note in a container
  the workplace may not read, they answer with nothing, so a caller that passes the wrong note can't reach
  across a seal. Views that show a container ask from that container's workplace
  (`Reach.workplace(of:)`); anything that builds content for somewhere else asks from there.
- **Reading a note for anything other than showing it to the user** (related notes, a summary, anything put
  in front of the model) goes through `Retrieval.text(of:from:)`, which gives nothing for a note outside the
  workplace's reach. `NoteStore` and `LibraryCatalog` are for the editor and the sidebar, which show the user
  the place they opened. Nano bot is handed a `Retrieval` and nothing else.

```swift
public actor Retrieval {
    public init(indexDirectory: URL, spaces: @escaping @Sendable () async -> [Space])

    public func search(_ query: SearchQuery, from workplace: Workplace) async throws -> [SearchHit]
    public func titles(matching text: String, from workplace: Workplace, limit: Int) async throws -> [TitleHit]
    public func resolve(_ link: WikiLink, in source: NoteRef, from workplace: Workplace) async throws -> LinkResolution
    public func backlinks(to note: NoteRef, from workplace: Workplace) async throws -> [Backlink]
    public func tags(from workplace: Workplace) async throws -> [TagCount]
    public func notes(tagged tag: String, from workplace: Workplace) async throws -> [NoteHit]
    public func openTasks(from workplace: Workplace, limit: Int) async throws -> [TaskHit]
    public func recentNotes(from workplace: Workplace, limit: Int) async throws -> [NoteHit]
    public func linkingNotes(to note: NoteRef, from workplace: Workplace) async throws -> [NoteRef]  // LinkRewriter
    public func linkingNotes(toMoved moves: [NoteMove], from workplace: Workplace) async throws -> [NoteRef]
    public func notesLinking(throughFolderNamed name: String, from workplace: Workplace) async throws -> [NoteRef]
    public func linkContext(for container: Container, from workplace: Workplace) async throws -> LinkContext
    public func attachmentNamesShared(by note: NoteRef, from workplace: Workplace) async throws -> Set<String>
    public func notes(in folder: ItemPath, of container: Container, from workplace: Workplace) async throws
        -> [NoteHit]
    public func folders(of container: Container, from workplace: Workplace) async throws -> [ItemPath]
    public func note(_ note: NoteRef, from workplace: Workplace) async throws -> NoteHit?
    public func hasDuplicatedIdentity(_ note: NoteRef, from workplace: Workplace) async throws -> Bool
    public func text(of note: NoteRef, from workplace: Workplace) async throws -> String?   // nil outside the reach
    public func inboxCount() async throws -> Int                             // a number, never content
    public func filingDestinations() async -> [FilingDestination]
}

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    public var folder: ItemPath?            // within the workplace's space
    public var tag: String?
    public var kind: NoteKind?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var limit: Int
}
public struct SearchHit: Hashable, Sendable {
    public var note: NoteRef
    public var title: String
    public var snippet: String              // with the matched words marked
    public var matchedTerms: [String]       // so the editor can open at the first match
    public var modified: Date?
}
```

- **Keyword search** is FTS5 with `unicode61 remove_diacritics 2`: every term must match, the last term as a
  prefix (search as you type), titles weighted above text, newer notes first on a tie. A second table with
  the `trigram` tokenizer serves text written without spaces between words.
- **Search terms** (`SearchTerms`): words split at whitespace, without quotes and control characters, at most
  32 of them (a thousand would be more than SQLite takes). A last word of one character is matched as a whole
  word, not as a prefix, which would read nearly every note; one or two letters of a script with spaces
  aren't looked for inside words. Scripts without spaces are looked for inside text at any length.
- **Text is bound and read by its length in bytes**, so a NUL inside a note doesn't cut it short.
- Results from several databases are merged by rank, then by date.
- **Leak tests** (`SealingLeakTests`) plant one marker word in a sealed space (title, text, tag, task, file
  name, folder name) and another in an unsealed one. For every query of `Retrieval` and every workplace, the
  sealed marker appears only from inside the sealed space and the other marker never appears inside it.
  `scripts/check-rules.sh` fails when a public query of `Retrieval` has no entry in that test.

```swift
public actor Indexer {
    public init(catalog: LibraryCatalog, indexDirectory: URL, fileSystem: any FileSystem)
    public func refresh(_ container: Container) async throws -> IndexReport   // only what changed
    public func update(_ paths: [ItemPath], in container: Container) async throws
    public func rebuild(_ container: Container) async throws
    public func pause()
    public func resume()
    public func status() -> IndexStatus
}
```

- **Incremental:** a file is read again only when its size, date or content hash changed. A file that
  disappeared and one that appeared with the same `id`, file identity or content hash are one note that
  moved.
- Each database records its schema version; a different one means the database is dropped and rebuilt.
- One writer (the indexer) and many readers per database (WAL mode).
- **A damaged database** (`SQLITE_CORRUPT`, `SQLITE_NOTADB`) is thrown away, with its `-wal` and `-shm`, and
  the container is indexed again from its folder. A database that can't be opened is left out of queries, so
  one damaged space doesn't empty every search; `Retrieval` lets go of a database file that was replaced.
- **Big notes:** the index reads at most a note's first `NoteLimits.maximumIndexedBytes` (4 MB), cut where no
  character is split, and records the file's real size, so the next pass sees nothing changed.

## Capture (`ElenathCore/Capture`): built

```swift
public enum CaptureDestination: Hashable, Sendable {
    case inbox
    case space(SpaceID, matched: String)       // the name or keyword that was typed
}
public struct CaptureDraft: Hashable, Sendable {
    public var destination: CaptureDestination
    public var title: String
    public var body: String                    // without the "uni: " prefix
}
public struct CaptureParser: Sendable {
    public init(spaces: [Space])
    public func parse(_ text: String, now: Date, timeZone: TimeZone) -> CaptureDraft?   // nil for blank text
    public func split(_ text: String) -> (destination: CaptureDestination, content: String)?
}
/// Quick Capture's event (⌥↩), in ElenathCore/Calendar/QuickAdd.
public enum CaptureEvent {
    public enum Reading { case event(QuickAddDraft), noSubjectIn(SpaceID) }
    public static func read(_ text: String, spaces: [Space], subjects: [Subject], settings: CalendarSettings,
                            parse: (String) -> QuickAddDraft?) -> Reading?
}
```

- Text that starts with a space's name or one of its keywords, a colon and whitespace (`uni: ask about the
  exam`) goes straight to that space, sealed ones included: it is the user's own choice, not retrieval. The
  longest match wins. Anything else goes to the Inbox.
- A pasted link stays a link. Elenath can't fetch pages.
- **An event goes where the text says** (`CaptureEvent`): Quick Add reads only the first line after the
  space's name, at most 300 characters, so the name isn't part of the event and a pasted page is never
  read at every keystroke. The event's subject is one whose home is that space (Quick Add's, if it lives
  there, else the first that does). Text for a sealed space where no subject lives gives no event, since
  it would have no home and show everywhere; the panel says so.

## Import (`ElenathCore/Import`): built

```swift
public indirect enum ImportItem: Hashable, Sendable {
    case note(source: URL, title: String)             // .md, .markdown, .txt: copied as a note, bytes unchanged
    case document(source: URL, title: String)         // .rtf, .rtfd, .doc, .docx, .odt, .html: text becomes a note
    case chatExport(source: URL)                      // a WhatsApp export: its messages become Inbox notes
    case file(source: URL)                            // PDFs, images and everything else: copied as they are
    case folder(name: String, items: [ImportItem])
    case skipped(source: URL, reason: SkipReason)     // hidden items, another app's settings folder
}
public enum ImportPlanner {
    public static func plan(_ sources: [URL], fileSystem: any FileSystem) throws -> [ImportItem]
}
/// Turns a rich-text document into Markdown. The app's implementation uses AppKit; tests use a fake.
public protocol DocumentConverting: Sendable {
    func markdown(from url: URL) throws -> String
}
public actor Importer {
    public init(noteStore: NoteStore, converter: any DocumentConverting, fileSystem: any FileSystem)
    public func run(_ items: [ImportItem], into folder: ItemPath, container: Container,
                    progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportReport
}
public struct ChatMessage: Hashable, Sendable {
    public var sent: Date?
    public var sender: String
    public var text: String
    public var attachmentNames: [String]
}
public enum ChatExport {
    public static func isChatExport(_ text: String) -> Bool
    public static func messages(from text: String, timeZone: TimeZone) -> [ChatMessage]
    /// Messages sent within `gap` of each other become one note, dated when the first was sent.
    public static func notes(from messages: [ChatMessage], gap: TimeInterval) -> [[ChatMessage]]
}
```

- Everything is **copied**. Originals are never moved or changed.
- A converted document keeps its original: it is copied to `Attachments` and linked from the top of the note.
- **Web pages and web archives** are read by `HTMLText`, never by WebKit: headings, paragraphs, lists,
  quotes, line breaks and `<pre>` as a fenced block; scripts, styles and the page's head are left out, and
  nothing is fetched. The app reads other documents with AppKit as the type their extension names, so AppKit
  never guesses a file is a web page. All of it runs off the main thread.
- **Links, named pipes and devices** in a dropped folder are skipped; a copied folder never holds a link.
- **A vault's own `Attachments` folder** (Obsidian keeps one) is merged into Elenath's `Attachments` beside
  the notes, where embeds find it.
- **A chat's attachment names** come from the chat's text, so a name is used only when it is a regular file
  right in the export's folder: never a path, a hidden name, a folder, a link or a pipe.
- A chat export is a chat with oneself: every message is a note to file. Its notes go where it was dropped
  (usually the Inbox), each with `created` set to when it was sent, and its photos and files in `Attachments`.
- Folders keep their structure. Clashes get Finder-style numbers. Cancelling leaves what is already done.
- docs/IMPORT.md has the steps for each place notes come from.

## Demo (`ElenathCore/Demo`): built

```swift
public enum DemoLibrary {
    /// Writes an invented library: Uni, a sealed Red Cross space, Ideas, and an Inbox with a few captures.
    public static func write(to root: URL, now: Date, timeZone: TimeZone, fileSystem: any FileSystem) throws
}
```

The `-demo` launch argument writes it into a temporary folder with its own safety copies and index, so the
user's library, bookmark and settings are never touched. Every id is fixed, so equal arguments give equal
libraries.

## App layer (`Elenath/`)

Built so far:

```
Elenath/
  ElenathApp.swift               scenes, commands, environment wiring
  App/AppSettings.swift          @Observable UserDefaults-backed settings (appearance)
  App/Appearance.swift           Night / Dawn / Match System → NSApp.appearance
  App/LaunchOptions.swift        -demo
  App/DemoScene.swift            -demoAppearance, -demoWindowSize
  App/DemoSceneDirector.swift    sets a screenshot scene up
  App/AppLinks.swift             GitHub URLs for the Help menu, opened in the browser
  App/ElenathCommands.swift      the menu bar
  Views/MainView.swift           the themed shell
  Views/StarField.swift          the star-field tile and .starryBackground
  Views/EmptyStateView.swift     illustration, headline, secondary line
  Views/Settings/*.swift         General: the appearance choice
  Theme/Metrics.swift, Theme/Typography.swift
```

Contract for version 0.1, by area. Each area has one owner when the work is split; shared types are declared
once by the owner listed.

```
  App/AppModel.swift             library state, workplace, selection, navigation history        (shell)
  App/FolderAccess.swift         security-scoped bookmark, open and save panels (from Ithil)    (shell)
  App/LibraryWatcher.swift       FSEvents on the library, classified by ElenathCore             (shell)
  App/IndexController.swift      runs the Indexer in the background, pauses on Low Power Mode   (shell)
  App/AppDelegate.swift          quitting waits (up to 5 s) for the last saves                  (shell)
  Views/MainView.swift           one screen per library state; alerts                           (shell)
  Views/FolderSetup/*.swift      choose folder, folder missing, library problems (from Ithil)   (shell)
  Views/LibraryWindow.swift      NavigationSplitView, toolbar, search field                     (sidebar)
  Views/Sidebar/*.swift          Today, Inbox, spaces with folders, tags                        (sidebar)
  Views/Today/*.swift            the landing screen                                             (sidebar)
  Views/Search/*.swift           search results, jump to a note                                 (sidebar)
  Views/Editor/*.swift           MarkdownTextView, styling, autocomplete, backlinks             (editor)
  App/EditorSession.swift        one open note: text, autosave, conflicts, undo                 (editor)
  Views/Inbox/*.swift            the Inbox list, filing by hand                                 (capture)
  Views/Capture/*.swift          the Quick Capture panel                                        (capture)
  App/HotKey/*.swift             the global shortcut (from Ithil), default ⌥⇧Space              (capture)
  App/Import/*.swift             drop targets, DocumentConverter (AppKit), progress             (import)
  Views/Onboarding/*.swift       welcome, choose folder, first spaces                           (onboarding)
  Views/Settings/*.swift         General, Spaces, Files                                         (settings)
  App/Diagnostics.swift          the report for the checks only a real Mac can make             (settings)
```

### `AppModel` (`@Observable @MainActor final class`)

```swift
enum LibraryState: Equatable {
    case needsFolder                                 // first launch
    case loading
    case ready
    case folderMissing(path: String)                 // "Locate or choose folder": never quietly empty
    case noLibrary(path: String)                     // the folder exists but holds no library
    case unreadable(path: String, message: String)
}
private(set) var state: LibraryState
private(set) var spaces: [Space]
private(set) var isReadOnly: Bool
var workplace: Workplace                             // follows what is open: a space, the Inbox, Today
var selection: SidebarItem?                          // Today, Inbox, a space, a folder, a tag
var openNote: NoteRef?
func open(_ note: NoteRef)                           // adds to the back and forward history
func goBack(); func goForward()
func useFolder(_ chosen: URL)                        // LibraryFolderPolicy, then create or open
func relocateFolder(_ chosen: URL)                   // only an existing library
```

- The states, the folder screens, the security-scoped bookmark, the recovery and save-error alerts, the
  read-only banner and moving the library all work as in Ithil (`AppModel`, `FolderAccess`, `MainView`,
  `FilesController.moveLibrary`), with `LibraryCatalog` in place of `LibraryStore`.
- **Undo and Redo.** Text edits use the text view's own undo. Everything else (create, rename, move, delete,
  file, tick a task from a list, a link rewrite, a space change, every calendar change) registers one step on
  the window's undo manager that does the opposite through the same code path. Each step is an undo group of
  its own (`UndoManager.registerAsOwnGroup`), also when it happens without a key press or click: AppKit
  groups by event and closes a group only after the next event, and an explicit `beginUndoGrouping()` at
  level 0 opens that event group too, so such steps used to share one group. The group is opened with
  `groupsByEvent` off. The crash check names every Undo and Redo it expects.
- **The watcher.** FSEvents on the library folder (file level, 0.3 s). `ElenathCore` sorts the paths:
  Elenath's own writes and noise are dropped; a changed note goes to the indexer and, if it is open, to its
  `EditorSession`; a structural change reloads the sidebar.

### The editor

- An `NSTextView` on TextKit 1 (`NSLayoutManager`, non-contiguous layout). TextKit 1 is chosen for now because
  its behavior with megabyte documents and attribute-only restyling is well known; the choice is contained
  in `MarkdownTextView`.
- The text view holds the note's body. Front matter is not in the text: the title field shows the file name,
  and kind and tags sit in a row under it.
- **Styling** applies attributes over the source text, which is never changed by styling: markers are dimmed,
  not hidden. Only the lines the scanner reports as changed are restyled.
- **Autosave** 0.5 s after the last change, and at once when the note loses focus, another note opens, the
  window closes or the app quits.
- **`EditorSession` owns the text when no view does.** The text view registers with `attachTextView`; the
  session reads it on every save and, synchronously, whenever the view may go away (`captureText` when the
  note closes, `detachTextView` when the view is taken down). A text view made later (the window opened
  again) shows the newest text, and a save after the view is gone still has every keystroke.
- **Elenath's own steps hold the open note.** `AppModel.run` calls `beginStep` (save what was typed, then
  write nothing) and `endStep` (show what the step did to the file; save what was typed meanwhile where the
  note is now). A step that moves the open note calls `follow(to:)`; one that trashes it calls
  `noteWasTrashed()`, and the note is never written back.
- **Nothing typed is dropped when a note closes or the app quits** (`saveEverything`): edits to a note whose
  file, space or library vanished become "Title (conflict …)" in the Inbox; edits that can't be written at
  all go to `Recovery/` with the time in their name, and the next time the library opens an alert offers to
  put them in the Inbox (each copy then goes to the Trash). Quitting waits at most five seconds; indexing is
  never waited for.
- **Moving the library** closes the open note, refuses while a step runs, and pauses the watcher, so files
  leaving don't look like changes; nothing can be edited, captured or imported meanwhile.
- Writing direction is natural per paragraph, so right-to-left and mixed text work.
- ⌘F is the text view's own find bar. `[[` opens a completion list fed by `Retrieval.titles`.

### What CI can't check

A real Mac is needed for: the on-device model answering from the sandboxed, ad-hoc-signed app; the embedding
assets arriving without a network entitlement; and the folder bookmark surviving an update to a new
ad-hoc-signed build. Version 0.1 has a diagnostics report (Settings → Files) that checks all three and can be
copied.

## Calendar (`ElenathCore/Calendar`): phase 4

Elenath takes over everything Ithil 1.0.0 does. IthilCore's code and its tests are **ported, not
rewritten**: the files keep their logic and comments, and only what clashes with Elenath's own types is
renamed. The Ithil repository stays as it is at 1.0.0, and Elenath's repository never depends on it.

### What comes across, and under which names

| Ithil 1.0.0 | Elenath | Notes |
|---|---|---|
| `CalendarDate`, `Event`, `EventTiming`, `AlertOffset`, `RecurrenceRule`, `SeriesOccurrence`, `Occurrence` | the same | `ElenathCore/Calendar/Model` |
| `Subject`, `SubjectColor`, `PaletteColor` | the same | a subject's palette is the spaces' palette |
| `Library` (the events.json document) | `CalendarDocument` | `Library` would clash with Elenath's library |
| `CalendarSpan`, `RelativeDay`, `CalendarMath`, `OccurrenceExpander`, `OccurrenceDayMath`, `DayLayout`, `SeriesEditing`, `EventSearch` | the same | `ElenathCore/Calendar/Dates` |
| `QuickAddDraft`, `QuickAddParser` | the same | `ElenathCore/Calendar/QuickAdd`; `NSDataDetector` behind `#if canImport(Darwin)`, so the core still builds on Linux |
| `PlannedAlert`, `AlertPlanner`, `NotificationScheduling`, `AlertSynchronizer`, `AlertSyncResult` | the same | identifiers start `elenath.alert.`, so Elenath's alerts never touch Ithil's |
| `EventFolders`, `EventFoldersError`, `EventFolderMarker`, `EventFile`, `FolderNaming` | the same | `ElenathCore/Calendar/Files` |
| `LibraryStore`, `LibraryCodec`, `DecodedLibrary`, `LibraryLoad`, `LibraryStoreError`, `RecoveryReport`, `SchemaMigrator` | `DocumentStore<CalendarDocument>`, `DocumentCodec`, `DecodedDocument`, `DocumentLoad`, `DocumentStoreError`, `RecoveryReport`, `SchemaMigrator` | Elenath's store was made from Ithil's; it keeps the same backups, safety copy and recovery |
| `FileImport`, `FileCopyProgress` | `FileCopier`, `FileCopyProgress` | already ported in 0.1 |
| `FileSystem`, `LocalFileSystem`, `TimeSource` | Elenath's | already ported in 0.1 |
| `RootFolderPolicy`, `LibraryMove` | not needed | the calendar lives inside the library and moves with it |
| `DemoLibrary` | `DemoCalendar` | Ithil's sample week, placed in Elenath's demo library |

Ithil's tests come across into `ElenathCoreTests/Calendar` the same way. Its contracts (docs/ARCHITECTURE.md
of Ithil 1.0.0: Model, Dates, Storage, Quick Add, Notifications, Files) hold unchanged unless this section
says otherwise.

One change to Ithil's Dates, found in the review for 0.2.0: a repeating event whose occurrences last for
years (only a hand-edited or damaged events.json has one) expanded its whole series for every query, which
froze the calendar. `OccurrenceExpander` now looks back at most `maximumLookbackDays` (366) for occurrences
that last into a range, and keeps the latest `maximumSpanningOccurrences` (32) of them per series.

### The calendar in the library

```
<library>/Calendar/                      reserved, like Inbox: never a space
  .ithil/events.json                     Ithil's format, unchanged (schema version 1)
  .ithil/backups/events-yyyyMMdd-HHmmss.json
  2026-11-16/14.00 Physics Lecture/      one folder per occurrence, made when the first file arrives
  2026-11-16/14.00 Physics Lecture/.ithil-event
```

```swift
/// events.json: the subjects and events (Ithil's `Library`).
public struct CalendarDocument: VersionedDocument {      // fileName "events.json", backups "events-",
    public var id: UUID                                   // damaged files "events.corrupt-", schema 1,
    public var subjects: [Subject]                        // read up to 128 MB (settings files: 8 MB)
    public var events: [Event]
}

/// The calendar folder of a library: its store and its event folders.
public actor CalendarStore {
    public init(libraryRoot: URL, libraryID: LibraryID, safetyDirectory: URL, knownCalendarID: UUID?,
                fileSystem: any FileSystem, timeSource: any TimeSource,
                backupInterval: TimeInterval = 15 * 60, maxBackups: Int = 50)
    public nonisolated let folder: URL                    // <library>/Calendar
    public nonisolated let eventFolders: EventFolders     // rooted at the Calendar folder
    public func load(readOnly: Bool = false) async throws -> CalendarLoad
    public func save(_ document: CalendarDocument) async throws
}
public struct CalendarLoad {
    public var document: CalendarDocument
    public var recovery: RecoveryReport?                  // came back from a backup or the safety copy
    public var isReadOnly: Bool                           // newer schema, or a read-only library
    public var isNew: Bool                                // made just now
    public var startedOverLostFile: Bool                  // made although event folders or backups were there
}
public enum CalendarStoreError { case nameTakenBySpace, notAFolder }
```

- **The format on disk is Ithil's.** Elenath writes events.json with Ithil's keys and schema version, byte
  for byte as Ithil 1.0.0 does (`CalendarFormatTests.bytesAreIthils`), so the `Calendar` folder stays a
  valid Ithil folder and Ithil 1.0.0 could still open it. Nothing of Elenath's goes into events.json.
- **The first launch with a calendar** makes `Calendar/.ithil/events.json` with no subjects and no events.
  A library made by Elenath 0.1 gets its `Calendar` folder then. `load(readOnly: true)` (a library from a
  newer Elenath) makes, recovers and writes nothing.
- **A space called "Calendar"** made by Elenath 0.1 (a `.space` folder and no `.ithil`) stays a space, so
  nothing in it leaves the sidebar: `LibrarySnapshot.spaceNamedCalendar` names it, `load` throws
  `nameTakenBySpace`, and the app asks the user to rename it. A new space can't take the name, and a
  space put back from the Trash under it becomes "Calendar 2".
- **Never through a link:** a `Calendar` that is a link or a file is refused (`notAFolder`), and the
  library folder is never recreated.
- **Backups, the safety copy and recovery** are `DocumentStore`'s: `SafetyCopies/<library id>/` holds the
  calendar's safety copy as `<calendar id>.json`, beside the spaces'. The calendar's id is kept in
  library.json (`CalendarSettings.calendarID`), so the safety copy is found when the calendar's own
  folder is gone. With nothing to recover from, an empty calendar starts and `startedOverLostFile` says so.
- **The watcher** (`LibraryChange`): `reloadsCalendar` when `.ithil/events.json` changed (or the folder
  came or went), `calendarFiles` when anything in an event folder did. Backups and `.DS_Store` cost
  nothing.
- **Markers** are read up to 64 KB, never through a link.

### Subjects and their homes

```swift
/// Where a subject's notes go and where its events' files belong: a space and a folder in it.
public struct SubjectHome: Hashable, Sendable {
    public var space: SpaceID
    public var folder: ItemPath                           // root for the top of the space
}
public enum SubjectHomeEntry { case none, home(SubjectHome), unreadable }
/// Elenath's own calendar settings, kept in library.json under settings["calendar"], so events.json
/// stays Ithil's. Keys this version doesn't know are kept.
public struct CalendarSettings: Hashable, Sendable {
    public var calendarID: UUID?
    public private(set) var homes: [UUID: SubjectHome]    // by subject id
    public init(from settings: [String: JSONValue])
    public func entry(forSubject: UUID?) -> SubjectHomeEntry
    public mutating func setHome(_ home: SubjectHome?, forSubject: UUID)
    public var isDamaged: Bool                            // settings.calendar or its homes isn't an object
    public mutating func settleDamage(subjects: [UUID]) -> Bool
    public func written(into settings: inout [String: JSONValue])
}
// LibraryCatalog: calendarSettings(), saveCalendarSettings(_:); LibrarySnapshot.calendarSettings
```

- A subject without a home, and an event without a subject, have **no home**: never sealed, and their notes
  go to the Inbox.
- **A home that can't be used fails closed.** An entry that can't be read, two entries for one subject
  (keys that differ only in case), or a home whose space is gone may have named a sealed space: the
  subject's events are read from nowhere (`CalendarReach.hasMissingHome`) until the user gives the subject
  a home again in Settings. Their notes go to the Inbox meanwhile.
- **Damaged settings fail closed too.** When `settings.calendar` or its `homes` isn't an object at all,
  every subject's home reads as unreadable (`isDamaged`) and the value is written back as it was found.
  When the calendar opens, the app settles it (`settleDamage(subjects:)`): each of the calendar's subjects
  gets an entry that can't be read, so its events stay sealed until it gets a home again, and what was
  found is kept under `foundUnreadable`. A subject made later has no home, as usual.
- **A home is backed up at once.** `saveCalendarSettings` writes a backup of the new library.json whenever
  the settings change, as a space's seal does: a library recovered from a backup never forgets a sealed
  home.
- **Deleting a subject never unseals its events.** Its events would have no home, and an event without a
  home is read wherever the spaces that mix are. So a subject with events whose home is a sealed space, a
  space that is gone or an entry that can't be read isn't deleted (`CalendarReach.deletingSubjectWouldUnseal`);
  Settings says why, and its events need another subject first. The editor doesn't change the subject of
  an event whose notes it doesn't show.
- A home folder through a hidden, attachments or board folder reads as the top of the space.
- **Sealing follows the home.** An event whose subject's home is a sealed space is a sealed event.
- **Notes for an occurrence:** a note's front matter `event` (`EventLink`: the event's id and the
  occurrence's original day) links it to one occurrence. The index keeps it (schema 3);
  `Retrieval.notes(linkedTo:from:)` finds them through `Reach`, and `NoteStore.create(…, event:)` makes one
  in the subject's home folder ("Notes for this lecture").

### The sealing exception

The calendar is the one deliberate exception to sealing (CLAUDE.md, "Spaces"):

- **Crosses the seal:** an event's title, time, location and file count, on the calendar, Today, in
  notifications and the menu bar, and opening its folder in Finder ("Open Files").
- **Stays sealed:** the event's notes, its files' names and contents, and the notes linked to it. Outside
  its home space a sealed event is left out of the main search, suggestions, the Sky and anything Nano bot
  is shown. The calendar's own search finds every event by title and location, and a sealed event never by
  its notes or files.
- `CalendarReach` is the calendar's one decision point, beside `Reach`:

```swift
public struct CalendarReach: Hashable, Sendable {
    public init(workplace: Workplace, spaces: [Space], settings: CalendarSettings)
    public func home(of event: Event) -> SubjectHome?
    public func hasMissingHome(_ event: Event) -> Bool
    /// Whether an event's notes, files and linked notes may be read from the workplace.
    public func mayReadContent(of event: Event) -> Bool
    public func notes(of event: Event) -> String?                                  // nil where sealed
    public func files(for occurrence: Occurrence, in folders: EventFolders) async -> [EventFile]?
    public func matches(_ event: Event, query: String) -> Bool
    /// The calendar's own search: title and location for every event; notes only where they may be read.
    public func search(_ document: CalendarDocument, query: String, now: Date,
                       expander: OccurrenceExpander) -> [Occurrence]
    /// Whether deleting the subject would bring its events' content out of a seal.
    public func deletingSubjectWouldUnseal(_ subject: UUID, in document: CalendarDocument) -> Bool
}
```

| The event | Its content is read from |
|---|---|
| no subject, or a subject without a home | where the spaces that mix are read: everywhere, an unsealed space |
| homed in a space | where `Reach` allows that space |
| homed in a space that is gone, or whose entry can't be read | nowhere |

- The app shows an event's notes, file names and linked notes only through `CalendarReach`, and the file
  count and "Open Files" (Finder) for every event.
- **Event files join the main search in 0.3** (phase 5), by name and by text, indexed into the home space
  so `Retrieval` and `Reach` apply to them like any file of that space; files of events without a home go
  nowhere. In 0.2 they are found from the calendar (the event's Files), and the leak tests check that they
  never reach the index.
- The leak tests (`SealingLeakTests`) prove both halves: a marker in a sealed event's notes and in its files'
  names never comes out of any `CalendarReach` query or `Retrieval` query from outside, nothing of other
  events' content comes out inside the sealed space, and every event's title, time, location and file
  count show from every workplace. `scripts/check-rules.sh` (rule 4b) fails when a public query of
  `CalendarReach` isn't asked there.

### Bringing in an Ithil calendar

```swift
public struct CalendarImportReport: Hashable, Sendable {
    public var subjectsInSource, eventsInSource, foldersInSource, filesInSource: Int
    public var subjectsAdded, eventsAdded, filesCopied: Int                 // brought in this time
    public var subjectsAlreadyThere, eventsAlreadyThere, filesAlreadyThere: Int
    public var readFromBackup: Bool
    public var missingFiles: [String]                                       // not there after copying
    public var countsMatch: Bool                                             // everything is there
}
public enum CalendarImport {
    /// Reads an Ithil folder, copies its event folders into the calendar's folder, and returns the
    /// calendar with its subjects and events merged in, for the app to save as one change.
    public static func run(from ithilFolder: URL, into calendar: CalendarDocument, calendarFolder: URL,
                           libraryRoot: URL, eventFolders: EventFolders, fileSystem: any FileSystem,
                           progress: @escaping @Sendable (FileCopyProgress) -> Void) async throws
        -> CalendarImportResult                     // document, source (Ithil's calendar as read), report
    /// Merges what `run` read into the calendar as it is once the files are copied: only Ithil's
    /// subjects and events, so nothing deleted meanwhile comes back.
    public static func merge(_ result: CalendarImportResult, into current: CalendarDocument)
        -> CalendarImportResult
}
public enum CalendarImportError { case notAnIthilFolder, newerSchema(found:supported:), unreadable,
                                  insideLibrary }
```

- **Read-only source:** nothing is written inside the Ithil folder, and links in it are never followed
  (a `.ithil` or `backups` that is a link isn't read); its events.json is read, never recovered or
  migrated in place. A damaged one is read around from its
  newest readable backup. A newer schema is refused. The library itself, a folder inside it or one that
  holds it is refused.
- **Copy, check, never duplicate:** subjects and events are merged by id (an id already in Elenath's
  calendar is left alone; a subject the calendar already had under the same name is used instead of a
  second one). Event folders are copied file by file (`FileCopier`, never moved): into the calendar's
  folder for the same occurrence when there is one (found by its marker, wherever it was renamed), else
  under their own name, or " 2" when that name is another event's. A folder Ithil never marked (one the
  user made in Finder) belongs to the one occurrence whose folder it is, so a second run finds it.
  Markers are read and written anew. Every other file comes along under its own name, hidden ones
  included (a project's `.git`, an `.env`), and is counted; left behind are only the system's
  `.DS_Store`, AppleDouble and custom-icon files and copies that never finished. A file that is already
  there is never overwritten. Nothing is written outside the calendar's folder, even through a link
  planted in it. A file that can't be copied is listed and the rest go on. Afterwards every file is
  looked for and the counts are compared.
- **Merged when the copy ends.** The app merges `result.source` into the calendar as it is then
  (`merge(_:into:)`), as one undo step: something deleted while the files were copied stays deleted.
- **Ithil's alerts:** Ithil scheduled its own notifications. The app tells the user how to stop them (quit
  Ithil and turn off its notifications in System Settings, or delete Ithil), since Elenath can't reach
  another app's alerts.
- **The demo** (`DemoLibrary`) has Ithil's sample week with each subject homed (a sealed Red Cross subject
  among them), event files, a note for one lecture, and `DemoLibrary.writeIthilFolder(to:now:timeZone:)`
  writes a separate Ithil folder to try bringing in.

### In the app (`Elenath/Calendar`)

Ithil's app layer came across the same way, fitted into Elenath's window:

- **`CalendarModel`** (Ithil's `AppModel`): the open calendar and its state (`closed`, `loading`, `ready`,
  `nameTakenBySpace`, `unreadable`), the span, the selected day and event, the calendar's search, and every
  change: events, subjects, Bring In. It saves through `CalendarSaveQueue` (an actor, one save at a time, the
  newest wins) into `CalendarStore`, and tells its observers (`FilesController`, `NotificationsController`)
  what changed. `AppModel+Calendar` opens it with the library and gives it the spaces, the calendar settings
  from library.json and the window's undo manager.
- **Where it shows:** the `calendar` route (`CalendarDetailView`: Ithil's week and day grid, month, details,
  editor, files and search), the mini month and subjects in the sidebar under Calendar, `CalendarToolbar`
  while it's open, Up next on Today, the menu bar extra and Quick Capture's event line.
- **The workplace** is `CalendarModel.workplace`: everywhere, or one space ("Open in Red Cross"). Its `reach`
  is the `CalendarReach` for it, and every view that shows notes, file names or linked notes asks it.
- **`FilesController`** (Ithil's): event folders, files dropped on an event (copied in the background with
  progress), Quick Look, Show in Finder, the folder watcher, and carrying folders along when an event's
  title, date or time changes. A folder an event no longer needs goes to the Trash; Undo puts it back where
  the sandbox allows.
- **`NotificationsController`** (Ithil's, with `AlertSynchronizer`): alerts are scheduled with
  `UNUserNotificationCenter`, so they arrive while Elenath is closed, under identifiers that start
  `elenath.alert.`.
- **Undo:** each change registers a step that puts the whole calendar back as it was (`restore`), and Redo
  the same way. Edits of one subject within two seconds share a step, as in Ithil.

## Meaning (`ElenathCore/Meaning`, `ElenathCore/Index`): phase 5

Search by meaning, related notes, and the text inside PDFs, pictures and event files (0.3). Everything stays in
the index, a cache rebuilt at will, and every question still goes through `Retrieval` and `Reach`.

### Chunks

```swift
/// A stretch of a note, a PDF page or a picture's text: what one vector stands for.
public struct Chunk: Hashable, Sendable {
    public var headings: [String]       // the heading path above it ("Lecture 7 › Torque"), for notes
    public var text: String             // plain text, Markdown markers left as they are
    public var range: NSRange           // UTF-16 range in the note's body, or in the page's text
    public var page: Int?               // 1-based PDF page; nil for notes and pictures
}
public enum Chunker {
    /// A note by its Markdown structure: each heading starts a chunk, paragraphs gather until about
    /// `targetCharacters` (≈ 250 tokens at 4 characters each), and a paragraph longer than
    /// `maximumCharacters` is cut at sentence ends. Code blocks and tables stay whole up to the maximum.
    public static func chunks(ofNote text: String) -> [Chunk]
    /// Text by pages (PDFs): a chunk never spans pages; long pages are cut as above.
    public static func chunks(ofPages pages: [String]) -> [Chunk]
    public static let targetCharacters: Int      // 1,000
    public static let maximumCharacters: Int     // 1,600, under the embedder's sequence length
}
```

- Linear in the text (`HostileInputTests.expectLinear`), and at most `NoteLimits` of a note is read.
- A chunk's text is what the embedder sees, with its heading path in front ("Torque — …") so a paragraph
  keeps its topic.

### The embedder

```swift
public struct EmbedderStamp: Hashable, Codable, Sendable {
    public var identifier: String       // the model, e.g. NLContextualEmbedding's modelIdentifier
    public var revision: Int
}
public protocol Embedder: Sendable {
    /// The models this embedder has on this Mac right now, by the script they read. Asked at run time,
    /// never assumed: a script without a model (or whose assets aren't on the Mac yet) is left to keyword
    /// search.
    func models() async -> [EmbeddingModel]
    /// One normalized vector per text (mean of its token vectors), or nil for a text the model can't read.
    func vectors(for texts: [String], with model: EmbeddingModel) async throws -> [[Float]?]
}
public struct EmbeddingModel: Hashable, Codable, Sendable {
    public var stamp: EmbedderStamp
    public var script: String           // ISO 15924 ("Latn", "Cyrl", "Hani"…)
    public var dimension: Int
}
```

- **The real one** (`ContextualEmbedder`, behind `#if canImport(NaturalLanguage)`) uses
  `NLContextualEmbedding(script:)`: `hasAvailableAssets` and `requestAssets()` (the system downloads models
  over the air; whether it does without a network entitlement is on the diagnostics report), `load()`,
  `embeddingResult(for:language:)`, then the mean of `enumerateTokenVectors` over the text, normalized. A
  chunk longer than the model's `maximumSequenceLength` tokens is truncated by the model; chunks are cut
  short enough that this is rare.
- **Which model reads a text** is decided by its script (`NLLanguageRecognizer`'s dominant language, then its
  script). Vectors of different models are never compared: a chunk stores the stamp of its model, and a
  question is embedded with each model its own text needs.
- **Tests** use `HashingEmbedder` (in the tests): words hashed into a small vector, so related texts share
  words and score close, deterministic on every machine.

### Vectors in the index

- Schema 4 adds `chunks(id, owner_kind, owner, page, location, length, headings, text, model, vector)` and
  `chunk_text` (FTS5 over the chunks, for "open at the matching spot"), and `meta(key, value)` holding each
  model's stamp. A vector is a BLOB of `dimension` little-endian Float32s.
- **Incremental:** a note's chunks are made again only when its content hash changed; a file's when its size
  or date did. Vectors are made afterwards, in the background, a batch at a time; keyword search works from
  the first moment, and meaning search uses what is there.
- **Stamped:** when a model's stamp in `meta` differs from the model's now (a macOS update), that model's
  vectors are dropped and made again. Settings › Files › Rebuild Index drops everything.
- **Pausable:** `Indexer.setPaused(_:)`; it also waits while the Mac is in Low Power Mode.
- Cosine similarity is a dot product of normalized vectors, with Accelerate (`vDSP_dotpr`) behind
  `#if canImport(Accelerate)` and a plain loop elsewhere.

### Hybrid search

- `Retrieval.search` keeps its keyword ranking (FTS5 words, then trigrams, then file names) and adds a
  meaning ranking: the question's vector against every chunk the workplace may read (through `Reach`), best
  chunk per note or file. The two lists are fused by **reciprocal rank fusion** (score = Σ 1 / (60 + rank)),
  and the snippet is the best chunk's text with the matching words marked.
- **Keyword first:** questions of one or two characters, and questions no model can read, are keyword only,
  and keyword results never wait for vectors. The app shows keyword results at once and fuses the meaning
  results in when they arrive.
- **Measured, not assumed:** `RetrievalBenchmark` holds demo questions with the notes they should find
  (from `DemoLibrary`); its score (the share of questions whose note is in the top 5) is in the diagnostics
  report on the real embedder, and decides between embedder options.

### Related notes

```swift
// Retrieval
/// Notes about the same things as `note`, best first: chunk vectors close to the note's own, ignoring notes
/// it already links to or that link to it. Only from containers the workplace may read.
public func related(to note: NoteRef, from workplace: Workplace, limit: Int) async throws -> [NoteHit]
```

- Shown under the note, after the backlinks ("Related"), and later used by Nano bot's Link job.
- The leak tests ask `related(to:from:limit:)` from every workplace: a sealed space's marker never appears from
  outside, and nothing from outside appears inside it.

### PDFs, pictures and event files

```swift
public protocol TextExtractor: Sendable {
    func pages(ofPDF url: URL) async -> [String]?          // PDFKit; nil when it isn't a PDF it can read
    func text(ofImage url: URL) async -> String?           // Vision text recognition
}
```

- Behind `#if canImport(PDFKit)` and `#if canImport(Vision)`; tests use a fake. Limits as for notes: at most 200
  pages and 4 MB of text per PDF, pictures up to 100 megapixels.
- **Files in spaces** (attachments and other files) get chunks of their text, found by search and related
  notes like notes are, opened in their app or Quick Look.
- **Event files** are indexed into their subject's home space (`CalendarReach.home`), so that space's seal
  applies to them; files of events without a home, or whose home can't be used, are indexed nowhere. The app
  hands the indexer each homed occurrence's folder (`EventFolders`); a search hit opens the event's folder.

## Later phases

Their contracts are written before each phase starts.

| Phase | Adds |
|---|---|
| 6. Nano bot | `BotModel`, the job pipelines, proposals, the activity log, learning, the self-test, the calendar tools |
| 7. Boards and charts | the board package, canvas geometry, chart blocks |
| 8. Goals and the Sky | goal pages, the cached layout |
| 9. Frames and polish | frames, the accessibility pass |
