import ElenathCore
import SwiftUI

/// Everything that was dumped and isn't filed yet. Each item can be opened, filed into a space or
/// folder, or moved to the Trash.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var listing: FolderListing?
    @State private var details: [ItemPath: NoteHit] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Inbox")
                        .font(Typography.windowTitle)
                        .foregroundStyle(Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let listing, count(listing) > 0 {
                        Text("\(count(listing)) items")
                            .font(Typography.secondary)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                if let listing {
                    if count(listing) == 0 {
                        emptyState
                    } else {
                        items(listing)
                    }
                }
            }
            .frame(maxWidth: Metrics.editorColumnWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .libraryDropTarget(.inbox, cornerRadius: Metrics.Radius.dropZone)
        .task(id: model.contentRevision) {
            await load()
        }
    }

    private func count(_ listing: FolderListing) -> Int {
        listing.folders.count + listing.notes.count + listing.files.count
    }

    @ViewBuilder private func items(_ listing: FolderListing) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(listing.notes.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }, id: \.path)
            {
                entry in
                let note = NoteRef(container: .inbox, path: entry.path)
                let hit = details[entry.path]
                HStack(spacing: 4) {
                    OpenableRow(dragURL: model.url(for: entry.path, in: .inbox)) {
                        model.open(note)
                    } content: {
                        NoteRowView(
                            note: note, title: entry.title, kind: hit?.kind ?? .note, preview: hit?.preview ?? "",
                            modified: entry.modified)
                    }
                    FileToMenu { container, folder in
                        model.move(note, to: folder, in: container)
                    }
                }
                .contextMenu {
                    NoteMenu(note: note)
                }
            }
            ForEach(listing.folders, id: \.self) { path in
                HStack(spacing: 4) {
                    OpenableRow(dragURL: model.url(for: path, in: .inbox, isDirectory: true)) {
                        model.go(to: .folder(.inbox, path))
                    } content: {
                        FileRowLabel(name: path.name, symbol: "folder", detail: "")
                    }
                    FileToMenu { container, folder in
                        model.moveItem(path, in: .inbox, to: folder, in: container)
                    }
                }
                .contextMenu {
                    FileMenu(container: .inbox, path: path)
                }
            }
            ForEach(listing.files, id: \.path) { entry in
                HStack(spacing: 4) {
                    OpenableRow(dragURL: model.url(for: entry.path, in: .inbox)) {
                        model.openFile(entry.path, in: .inbox)
                    } content: {
                        FileRowLabel(
                            name: entry.name, symbol: "doc",
                            detail: ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
                    }
                    FileToMenu { container, folder in
                        model.moveItem(entry.path, in: .inbox, to: folder, in: container)
                    }
                }
                .contextMenu {
                    FileMenu(container: .inbox, path: entry.path)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(.emptyInbox)
                .accessibilityHidden(true)
                .padding(.bottom, 10)
            Text("Inbox is empty.")
                .font(Typography.emptyHeadline)
                .foregroundStyle(Color.textPrimary)
            if let shortcut = settings.quickCaptureHotKey?.displayString {
                Text("Press \(shortcut) anywhere to capture something.")
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("Capture something with File › Quick Capture.")
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let services = model.services else { return }
        if let listing = try? await services.catalog.listing(of: .root, in: .inbox) {
            self.listing = listing
        }
        if let hits = try? await services.retrieval.notes(in: .root, of: .inbox) {
            var byPath: [ItemPath: NoteHit] = [:]
            for hit in hits {
                byPath[hit.note.path] = hit
            }
            details = byPath
        }
    }
}

/// The small "File to…" button at the end of an Inbox row.
struct FileToMenu: View {
    let choose: (Container, ItemPath) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        MoveMenu(title: Text("File to…"), choose: choose)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(Typography.footnote)
            .disabled(!model.canEdit)
            .padding(.trailing, 6)
    }
}
