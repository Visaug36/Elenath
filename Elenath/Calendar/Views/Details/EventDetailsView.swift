import ElenathCore
import SwiftUI

/// The event details popover: subject, title in New York 22 pt, day and time, then location, alert and
/// repeat rows (only those that apply), the home, the notes, the notes for this occurrence, the event's
/// files, and Delete / Edit.
///
/// It shows the occurrence as it is in the library now, so edits made elsewhere appear at once. Delete
/// asks first (and which occurrences, for a repeating event, and what happens to its files), then calls
/// `onClose`; Edit calls `onEdit`.
///
/// **Sealing** (the calendar exception): the event's notes, its files' names and the notes linked to it
/// show only where `CalendarReach` says they may be read. Otherwise the popover shows the file count with
/// Open Files, and a card that says where they are kept, with a way to work in that space.
///
/// Files dragged anywhere over the popover are copied into the event's folder; while they are over it, the
/// popover gets the amber drop ring and glow (DESIGN.md screen 6).
struct EventDetailsView: View {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    let occurrence: Occurrence
    let onEdit: () -> Void
    let onClose: () -> Void
    @State private var showsDeleteConfirmation = false
    @State private var drag = FileDragState()
    /// How many files the folder had when the Files section last read it.
    @State private var loadedFileCount: Int? = nil
    /// The file list has keyboard focus, so Return opens a file instead of pressing Edit.
    @State private var isFileListFocused = false

    var body: some View {
        let current = model.occurrence(id: occurrence.id) ?? occurrence
        let context = EventChangeContext(
            occurrence: current, timeZone: model.timeZone, fileCount: fileCount(of: current))
        let reach = model.reach
        let mayRead = reach.mayReadContent(of: current.event)
        VStack(alignment: .leading, spacing: 14) {
            EventDetailsHeader(occurrence: current)
            EventDetailsInfo(event: current.event)
            if mayRead {
                EventHomeRow(home: reach.home(of: current.event))
            }
            if let notes = reach.notes(of: current.event), !notes.isEmpty {
                Text(notes)
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Notes"))
                    .accessibilityValue(Text(notes))
            }
            EventDetailsSeparator()
            if mayRead {
                EventLinkedNotesSection(occurrence: current, home: reach.home(of: current.event), onOpen: onClose)
                EventDetailsSeparator()
                EventFilesSection(
                    occurrence: current, drag: drag, isListFocused: $isFileListFocused, loadedCount: $loadedFileCount)
            } else {
                EventSealedFilesRow(occurrence: current)
                EventSealedCard(event: current.event)
            }
            EventDetailsSeparator()
            footer
        }
        .padding(Metrics.Padding.popover)
        .frame(width: 320, alignment: .leading)
        .background(Color.backgroundRaised)
        .overlay {
            if drag.isTargeted {
                FileDropGlow()
                    .padding(1)
            }
        }
        .fileDropTarget(isEnabled: model.canEdit, state: $drag) { urls in
            files.addFiles(urls, to: current)
        }
        .onAppear {
            files.requestCounts(for: [current])
        }
        .onDeleteCommand {
            requestDelete()
        }
        .confirmsEventChange(.delete, isPresented: $showsDeleteConfirmation, context: context) { scope in
            model.delete(current, scope: scope)
            onClose()
        }
    }

    private var footer: some View {
        let editShortcut: KeyboardShortcut? = isFileListFocused ? nil : .defaultAction
        return HStack(spacing: 8) {
            Button(role: .destructive) {
                requestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .help("Delete Event")
            Spacer(minLength: 8)
            Button("Edit", action: onEdit)
                .keyboardShortcut(editShortcut)
                .help("Edit Event")
        }
        .disabled(!model.canEdit)
    }

    private func requestDelete() {
        guard model.canEdit else { return }
        showsDeleteConfirmation = true
    }

    /// The files in the occurrence's folder: as last listed here, else as the files controller knows.
    private func fileCount(of occurrence: Occurrence) -> Int {
        loadedFileCount ?? files.fileCount(for: occurrence) ?? 0
    }
}

/// A 1 pt `SeparatorLine` between the popover's parts.
private struct EventDetailsSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.separatorLine)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The subject label (dot + name in the subject's color, 11 pt), the title and "Tuesday, 6 October ·
/// 14:00 – 15:30".
private struct EventDetailsHeader: View {
    @Environment(CalendarModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let occurrence: Occurrence

    var body: some View {
        let subject = model.subject(for: occurrence.event)
        VStack(alignment: .leading, spacing: 4) {
            if let subject {
                HStack(spacing: 6) {
                    SubjectDot(subject: subject, size: 7)
                    Text(subject.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SubjectStyle.text(for: subject, scheme: colorScheme))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Subject: \(subject.name)"))
            }
            Text(EventFormatting.displayTitle(occurrence.event))
                .font(Typography.detailTitle)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Text(EventFormatting.dayAndTime(occurrence, timeZone: model.timeZone))
                .font(Typography.secondary)
                .monospacedDigit()
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `mappin` location, `bell` alert and `repeat` rule rows, each only when the event has one.
private struct EventDetailsInfo: View {
    @Environment(CalendarModel.self) private var model
    let event: Event

    var body: some View {
        let location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let recurrence = EventFormatting.recurrence(event, timeZone: model.timeZone)
        if !location.isEmpty || event.alert != nil || recurrence != nil {
            VStack(alignment: .leading, spacing: 7) {
                if !location.isEmpty {
                    EventDetailsRow(systemImage: "mappin", label: "Location", value: location)
                }
                if let alert = event.alert {
                    EventDetailsRow(systemImage: "bell", label: "Alert", value: EventFormatting.alert(alert))
                }
                if let recurrence {
                    EventDetailsRow(systemImage: "repeat", label: "Repeats", value: recurrence)
                }
            }
        }
    }
}

private struct EventDetailsRow: View {
    let systemImage: String
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(value)
                .font(Typography.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}
