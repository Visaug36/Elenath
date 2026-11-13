import ElenathCore
import SwiftUI

/// What is in a space or a folder: its folders, its notes and its other files.
///
/// The names and dates come from the folder itself, so something made a moment ago is there at once; the
/// first lines of the notes come from the index and follow when it has caught up.
struct FolderContentsView: View {
    let container: Container
    let folder: ItemPath
    @Environment(AppModel.self) private var model
    @State private var listing: FolderListing?
    @State private var details: [ItemPath: NoteHit] = [:]
    @State private var openTasks: [TaskHit] = []
    @State private var showsAllTasks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let listing {
                    if listing.folders.isEmpty && listing.notes.isEmpty && listing.files.isEmpty {
                        emptyState
                    } else {
                        contents(listing)
                    }
                }
            }
            .frame(maxWidth: Metrics.editorColumnWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .libraryDropTarget(container, folder, cornerRadius: Metrics.Radius.dropZone)
        .task(id: RefreshKey(revision: model.contentRevision, isIndexing: model.isIndexing)) {
            await load()
        }
        .contextMenu {
            Button("New Note") {
                model.newNote(in: container, folder: folder)
            }
            Button("New Folder") {
                model.newFolder(in: container, folder: folder)
            }
            Button("Show in Finder") {
                model.revealInFinder(folder, in: container)
            }
        }
    }

    private struct RefreshKey: Hashable {
        var revision: Int
        var isIndexing: Bool
    }

    @ViewBuilder private var header: some View {
        let space = model.space(of: container)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if folder.isRoot, let space {
                    Image(systemName: SpaceStyle.symbol(for: space))
                        .font(.system(size: 20))
                        .foregroundStyle(SpaceStyle.color(for: space))
                        .accessibilityHidden(true)
                }
                Text(verbatim: folder.isRoot ? model.placeName(container) : folder.name)
                    .font(Typography.windowTitle)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if folder.isRoot, space?.isSealed == true {
                    Label("Sealed", systemImage: "lock.fill")
                        .font(Typography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.controlFill, in: Capsule())
                        .help(
                            "This space is kept apart: its notes stay out of search, links and suggestions everywhere else."
                        )
                }
                Spacer()
                Button {
                    model.newFolder(in: container, folder: folder)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Folder")
                .disabled(!model.canEdit(container))
            }
            if folder.isRoot, let description = space?.description, !description.isEmpty {
                Text(verbatim: description)
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    @ViewBuilder private func contents(_ listing: FolderListing) -> some View {
        if folder.isRoot, !openTasks.isEmpty {
            SectionCard(title: Text("Open tasks")) {
                if openTasks.count > 6 {
                    Button(showsAllTasks ? "Show Fewer" : "Show All") {
                        showsAllTasks.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(Typography.footnote)
                    .foregroundStyle(Color.accentText)
                    .padding(.trailing, 10)
                }
            } content: {
                ForEach(Array(openTasks.prefix(showsAllTasks ? 200 : 6).enumerated()), id: \.offset) { _, task in
                    TaskRowView(task: task, showsPlace: false)
                }
            }
        }
        VStack(alignment: .leading, spacing: 1) {
            ForEach(listing.folders, id: \.self) { path in
                OpenableRow(dragURL: model.url(for: path, in: container, isDirectory: true)) {
                    model.go(to: .folder(container, path))
                } content: {
                    FileRowLabel(name: path.name, symbol: "folder", detail: "")
                }
                .libraryDropTarget(container, path)
                .contextMenu {
                    FolderMenu(container: container, folder: path)
                }
            }
            ForEach(listing.notes, id: \.path) { entry in
                let note = NoteRef(container: container, path: entry.path)
                let hit = details[entry.path]
                OpenableRow(dragURL: model.url(for: entry.path, in: container)) {
                    model.open(note)
                } content: {
                    NoteRowView(
                        note: note, title: entry.title, kind: hit?.kind ?? .note, preview: hit?.preview ?? "",
                        modified: entry.modified)
                }
                .contextMenu {
                    NoteMenu(note: note)
                }
            }
            ForEach(listing.files, id: \.path) { entry in
                OpenableRow(dragURL: model.url(for: entry.path, in: container)) {
                    model.openFile(entry.path, in: container)
                } content: {
                    FileRowLabel(
                        name: entry.name, symbol: "doc",
                        detail: ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
                }
                .contextMenu {
                    FileMenu(container: container, path: entry.path)
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            illustration: .emptySky, title: "Nothing here yet.",
            message: "Press ⌘N to write the first note, or drop files here to import them."
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func load() async {
        guard let services = model.services else { return }
        if let listing = try? await services.catalog.listing(of: folder, in: container) {
            self.listing = listing
        }
        if let hits = try? await services.retrieval.notes(in: folder, of: container) {
            var byPath: [ItemPath: NoteHit] = [:]
            for hit in hits {
                byPath[hit.note.path] = hit
            }
            details = byPath
        }
        if folder.isRoot {
            let tasks =
                (try? await services.retrieval.openTasks(from: Reach.workplace(of: container), limit: 200)) ?? []
            openTasks = tasks.filter { $0.note.note.container == container }
        }
    }
}

/// A folder or a file in a list.
struct FileRowLabel: View {
    let name: String
    let symbol: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: detail)
                .font(Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// What can be done to a file that isn't a note.
struct FileMenu: View {
    let container: Container
    let path: ItemPath
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open") {
            model.openFile(path, in: container)
        }
        MoveMenu(title: container == .inbox ? Text("File to") : Text("Move to")) { destination, folder in
            model.moveItem(path, in: container, to: folder, in: destination)
        }
        Button("Show in Finder") {
            model.revealInFinder(path, in: container)
        }
        Divider()
        Button("Move to Trash") {
            model.trashItem(path, in: container)
        }
        .disabled(!model.canEdit(container))
    }
}

/// The notes with a tag, as seen from the place the tag was chosen in.
struct TagNotesView: View {
    let tag: String
    let workplace: Workplace
    @Environment(AppModel.self) private var model
    @State private var notes: [NoteHit]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "#\(tag)")
                        .font(Typography.windowTitle)
                        .foregroundStyle(Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let notes {
                        Text("^[\(notes.count) note](inflect: true)")
                            .font(Typography.secondary)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(notes ?? [], id: \.note) { hit in
                        OpenableRow(dragURL: model.url(for: hit.note.path, in: hit.note.container)) {
                            model.open(hit.note)
                        } content: {
                            NoteRowView(hit: hit, showsPlace: true)
                        }
                        .contextMenu {
                            NoteMenu(note: hit.note)
                        }
                    }
                }
            }
            .frame(maxWidth: Metrics.editorColumnWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .task(id: model.contentRevision) {
            guard let services = model.services else { return }
            notes = (try? await services.retrieval.notes(tagged: tag, from: workplace)) ?? []
        }
    }
}
