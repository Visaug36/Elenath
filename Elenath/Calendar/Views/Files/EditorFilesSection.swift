import ElenathCore
import SwiftUI

/// The editor's drop zone (DESIGN.md screen 5), below Notes: a dashed rounded rectangle with a paperclip,
/// "Drop files here" and where the files go ("Copied to Calendar › 2026-10-08 › 10.00 Physics Quiz").
/// Clicking it opens "Add Files…".
///
/// - Editing an event (`existing` is set): files are copied into its folder at once, with the copy's
///   progress below the zone; the zone shows how many files the event already has.
/// - A new event (`existing` is nil): the files wait in `pending` until the event is added, and the zone
///   shows how many there are, with a button that leaves them out again.
///
/// `preview` is the event as the form describes it now, for the folder path.
struct EditorFilesSection: View {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    let preview: Occurrence
    let existing: Occurrence?
    @Binding var pending: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditorFileDropZone(
                destination: files.displayPath(for: preview), summary: summary, isEnabled: model.canEdit,
                showsClearButton: showsClearButton, onChoose: { chooseFiles() }, onDrop: { urls in add(urls) }
            )
            .overlay(alignment: .topTrailing) {
                if showsClearButton {
                    clearPendingButton
                }
            }
            if let existing, let progress = files.imports[existing.id] {
                FileImportProgressRow(progress: progress) {
                    files.cancelImport(for: existing)
                }
            }
        }
        .onAppear {
            if let existing {
                files.requestCounts(for: [existing])
            }
        }
    }

    /// "4 files" an edited event already has, or "2 files to add" for a new one.
    private var summary: String? {
        if let existing {
            guard let count = files.fileCount(for: existing), count > 0 else { return nil }
            return FileLabels.count(count)
        }
        return pending.isEmpty ? nil : FileLabels.pending(pending.count)
    }

    /// A new event's waiting files can be left out again.
    private var showsClearButton: Bool {
        existing == nil && !pending.isEmpty
    }

    private var clearPendingButton: some View {
        Button {
            pending = []
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
        }
        .buttonStyle(.borderless)
        .padding(.top, 10)
        .padding(.trailing, 10)
        .help("Don’t Add These Files")
        .accessibilityLabel(Text("Don’t Add These Files"))
    }

    private func chooseFiles() {
        let chosen = AddFilesPanel.chooseFiles(for: files.folderName(for: preview))
        add(chosen)
    }

    private func add(_ urls: [URL]) {
        guard model.canEdit, !urls.isEmpty else { return }
        if let existing {
            files.addFiles(urls, to: model.occurrence(id: existing.id) ?? existing)
        } else {
            for url in urls where !pending.contains(url) {
                pending.append(url)
            }
        }
    }
}

/// Builds the occurrence a new or edited event will have, so the editor can show where its files go
/// before it is saved.
enum EditorFilesPreview {
    /// The (first) occurrence of `event`, with all-day events placed in `displayTimeZone`.
    static func occurrence(of event: Event, displayTimeZone: TimeZone) -> Occurrence {
        switch event.timing {
        case .timed(let start, let end, _):
            return Occurrence(event: event, date: event.timing.startDate, start: start, end: end)
        case .allDay(let first, let last):
            let start = first.start(in: displayTimeZone)
            let end = last.adding(days: 1).start(in: displayTimeZone)
            return Occurrence(event: event, date: first, start: start, end: end)
        }
    }
}

/// The dashed zone itself: a plain button (click or Space opens "Add Files…") that also takes dropped
/// files, turning amber while they are over it.
private struct EditorFileDropZone: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let destination: String
    let summary: String?
    let isEnabled: Bool
    /// Leaves room after the summary for the button that drops a new event's waiting files.
    let showsClearButton: Bool
    let onChoose: () -> Void
    let onDrop: @MainActor ([URL]) -> Void
    @State private var drag = FileDragState()

    var body: some View {
        Button {
            onChoose()
        } label: {
            zone
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fileDropTarget(isEnabled: isEnabled, state: $drag, perform: onDrop)
        .help("Add Files…")
        .accessibilityLabel(Text("Add Files…"))
        .accessibilityValue(Text(summary ?? ""))
        .accessibilityHint(Text(FileLabels.copiedTo(destination)))
    }

    private var zone: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.dropZone, style: .continuous)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .foregroundStyle(drag.isTargeted ? Color.accentText : Color.textSecondary)
                Text(drag.isTargeted ? FileLabels.dropPrompt(itemCount: drag.itemCount) : dropHere)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 6)
                if let summary {
                    Text(summary)
                        .foregroundStyle(Color.textTertiary)
                        .monospacedDigit()
                        .padding(.trailing, showsClearButton ? 18 : 0)
                }
            }
            .font(Typography.body)
            .lineLimit(1)
            Text(FileLabels.copiedTo(destination))
                .font(.system(size: 11))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(drag.isTargeted ? Color.accentSoft : Color.clear)
        }
        .overlay {
            shape.strokeBorder(border, style: FileDropZoneStyle.dash(lineWidth: borderWidth))
        }
        .contentShape(shape)
    }

    private var dropHere: String {
        String(localized: "Drop files here")
    }

    private var border: Color {
        drag.isTargeted ? Color.accentColor : FileDropZoneStyle.idleBorder(contrast: contrast)
    }

    private var borderWidth: CGFloat {
        drag.isTargeted ? Metrics.Glow.dropRing : 1
    }
}
