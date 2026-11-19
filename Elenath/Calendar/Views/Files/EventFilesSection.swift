import ElenathCore
import SwiftUI

/// The Files part of the event details popover (DESIGN.md screens 6 and 10): "Files · 4" with Add Files
/// and Show in Finder, the file list (or the "No files yet" drop zone), the copy in progress, and the
/// folder's path.
///
/// The folder is the source of truth: the list is read again whenever `FilesController.changeToken`
/// changes (Finder edits, imports, renames) and whenever the event changes. While files are dragged over
/// the popover (`drag`), the list dims and the amber drop zone appears. `loadedCount` reports how many
/// files the folder has once it has been read, for the delete question.
struct EventFilesSection: View {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    let occurrence: Occurrence
    let drag: FileDragState
    @Binding var isListFocused: Bool
    @Binding var loadedCount: Int?
    @State private var items: [EventFile] = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EventFilesHeader(
                count: hasLoaded ? items.count : nil, canAdd: model.canEdit, onAdd: { chooseFiles() },
                onReveal: { files.revealInFinder(occurrence) })
            content
            if let progress = files.imports[occurrence.id] {
                FileImportProgressRow(progress: progress) {
                    files.cancelImport(for: occurrence)
                }
            }
            EventFolderPathRow(path: files.displayPath(for: occurrence))
        }
        .task(id: EventFilesReloadKey(occurrence: occurrence, changeToken: files.changeToken)) {
            await reload()
        }
    }

    @ViewBuilder private var content: some View {
        if !items.isEmpty {
            EventFileList(items: items, isFocused: $isListFocused)
                .opacity(drag.isTargeted ? 0.4 : 1)
        }
        if drag.isTargeted {
            FileDropPrompt(itemCount: drag.itemCount, folderName: files.folderName(for: occurrence))
        } else if items.isEmpty && hasLoaded {
            EventFilesEmptyState(
                folderName: files.folderName(for: occurrence), canAdd: model.canEdit, onAdd: { chooseFiles() })
        }
    }

    /// Reads the folder off the main thread, then shows what is in it.
    private func reload() async {
        let listed = await files.files(for: occurrence)
        guard !Task.isCancelled else { return }
        items = listed
        hasLoaded = true
        loadedCount = listed.count
    }

    private func chooseFiles() {
        guard model.canEdit else { return }
        let chosen = AddFilesPanel.chooseFiles(for: files.folderName(for: occurrence))
        if !chosen.isEmpty {
            files.addFiles(chosen, to: occurrence)
        }
    }
}

/// What the list depends on: the occurrence as it is now (a rename moves its folder) and the files'
/// change counter.
private struct EventFilesReloadKey: Equatable {
    var occurrence: Occurrence
    var changeToken: Int
}

/// "Files · 4" (section label), then a `plus` Add Files button and "Show in Finder" (`folder`).
private struct EventFilesHeader: View {
    let count: Int?
    let canAdd: Bool
    let onAdd: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(FileLabels.sectionTitle(count: count))
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityLabel(Text(spokenTitle))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if canAdd {
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Add Files…")
                .accessibilityLabel(Text("Add Files…"))
            }
            Button {
                onReveal()
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            .help("Show the event’s folder in Finder")
        }
    }

    /// "4 files" for VoiceOver; just "Files" before the folder has been read.
    private var spokenTitle: String {
        guard let count else { return String(localized: "Files") }
        return FileLabels.count(count)
    }
}

/// `folder` "Calendar › 2026-10-06 › 14.00 Physics Lecture" in `TextTertiary`.
private struct EventFolderPathRow: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .accessibilityHidden(true)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.textTertiary)
        .help(path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Folder"))
        .accessibilityValue(Text(path))
    }
}

/// The "No files" empty state (DESIGN.md screen 10): a large dashed drop zone holding the `EmptyFiles`
/// illustration, "No files yet. Drop some here." and where they go, plus "Add Files…".
private struct EventFilesEmptyState: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let folderName: String
    let canAdd: Bool
    let onAdd: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.dropZone, style: .continuous)
        let border = FileDropZoneStyle.idleBorder(contrast: contrast)
        VStack(spacing: 6) {
            Image(.emptyFiles)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text("No files yet. Drop some here.")
                .font(Typography.emptyHeadline)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("They’re copied to \(folderName) and show up in Finder too.")
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if canAdd {
                Button("Add Files…", action: onAdd)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .overlay {
            shape.strokeBorder(border, style: FileDropZoneStyle.dash(lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
    }
}
