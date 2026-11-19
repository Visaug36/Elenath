import ElenathCore
import SwiftUI

/// The new / edit event popover: title, date and time, subject, location, alert, repeat and notes.
///
/// - An edited event's notes show only where they may be read (`CalendarReach`); elsewhere the Notes field
///   says where they are kept, and they stay as they were.
/// - New events are added with `CalendarModel.add`; a timed one gets the calendar's time zone.
/// - Edits go through `CalendarModel.update`. A repeating occurrence first asks "This Event Only" / "All
///   Future Events"; an edit that changes nothing just closes. Edited timed events keep their own zone.
/// - In edit mode "Delete Event" asks first (and which occurrences, for a repeating event, and what
///   happens to its files).
/// - Below the form, a drop zone takes files (DESIGN.md screen 5). An edited event gets them at once; a
///   new event keeps them until Add Event, then they are copied into its folder.
///
/// The caller presents it (usually as a popover) and dismisses it in `onClose`, which runs after Cancel,
/// Add Event, Done and Delete.
struct EventEditorView: View {
    enum Mode {
        /// A new event, not yet in the library (from `CalendarModel.newEvent` or Quick Add).
        case new(Event)
        /// One occurrence of an event already in the library.
        case edit(Occurrence)
    }

    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    private let mode: Mode
    private let onClose: () -> Void
    @State private var draft: EventEditorDraft
    /// The fields as they were when the editor opened, to tell whether anything changed.
    @State private var original: EventEditorDraft
    /// Files dropped on a new event, copied into its folder once it is added.
    @State private var pendingFiles: [URL] = []
    @State private var hasPrepared = false
    @State private var showsSaveConfirmation = false
    @State private var showsDeleteConfirmation = false
    @FocusState private var titleFocused: Bool

    init(mode: Mode, onClose: @escaping () -> Void) {
        self.mode = mode
        self.onClose = onClose
        let draft = Self.makeDraft(for: mode, displayTimeZone: .current)
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EventEditorHeader(draft: $draft, titleFocused: $titleFocused)
            EventEditorFields(draft: $draft, notesKeptIn: notesKeptIn)
            EditorFilesSection(preview: filesPreview, existing: libraryOccurrence, pending: $pendingFiles)
            footer
        }
        .padding(Metrics.Padding.popover)
        .frame(width: 380)
        .background(Color.backgroundRaised)
        .environment(\.timeZone, draft.displayTimeZone)
        .onAppear {
            prepare()
        }
        .confirmsEventChange(.save, isPresented: $showsSaveConfirmation, context: changeContext) { scope in
            commitEdit(scope)
        }
    }

    /// Where an edited event's notes are kept, when they may not be read here (the calendar exception): the
    /// Notes field then says so instead of showing them. The draft keeps them, so saving leaves them as they
    /// were.
    private var notesKeptIn: String? {
        guard case .edit(let occurrence) = mode else { return nil }
        let reach = model.reach
        guard !reach.mayReadContent(of: occurrence.event) else { return nil }
        if let home = reach.home(of: occurrence.event), let space = model.spaces.first(where: { $0.id == home.space }) {
            return space.name
        }
        return ""
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isEditing {
                Button("Delete Event", role: .destructive) {
                    showsDeleteConfirmation = true
                }
                .disabled(!model.canEdit)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button {
                save()
            } label: {
                primaryTitle
                    .foregroundStyle(Color.textOnAccent)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canEdit)
        }
        .confirmsEventChange(.delete, isPresented: $showsDeleteConfirmation, context: changeContext) { scope in
            delete(scope)
        }
    }

    private var primaryTitle: Text {
        isEditing ? Text("Done") : Text("Add Event")
    }

    // MARK: - State

    private var isEditing: Bool {
        editedOccurrence != nil
    }

    /// The occurrence being edited; nil for a new event.
    private var editedOccurrence: Occurrence? {
        switch mode {
        case .new: return nil
        case .edit(let occurrence): return occurrence
        }
    }

    /// The edited occurrence as it is in the library now; nil for a new event.
    private var libraryOccurrence: Occurrence? {
        guard let occurrence = editedOccurrence else { return nil }
        return model.occurrence(id: occurrence.id) ?? occurrence
    }

    /// What the save and delete questions say: the event as it is in the library, and its files.
    private var changeContext: EventChangeContext {
        guard let occurrence = editedOccurrence else {
            return EventChangeContext(title: fallbackTitle, repeats: false, dayAndTime: "")
        }
        let fileCount = files.fileCount(for: libraryOccurrence ?? occurrence) ?? 0
        return EventChangeContext(occurrence: occurrence, timeZone: model.timeZone, fileCount: fileCount)
    }

    /// The occurrence as the form describes it now, to show where its files go.
    private var filesPreview: Occurrence {
        let base: Event
        let eventTimeZone: TimeZone
        switch mode {
        case .new(let event):
            base = event
            eventTimeZone = model.timeZone
        case .edit(let occurrence):
            base = occurrence.event
            eventTimeZone = occurrence.event.timing.timeZone ?? model.timeZone
        }
        let event = draft.event(updating: base, eventTimeZone: eventTimeZone, fallbackTitle: fallbackTitle)
        return EditorFilesPreview.occurrence(of: event, displayTimeZone: model.timeZone)
    }

    private var fallbackTitle: String {
        String(localized: "New Event")
    }

    /// Runs once: shows the fields in the calendar's time zone, drops a subject that no longer exists and
    /// focuses the title of a new event.
    private func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true
        if draft.displayTimeZone != model.timeZone {
            let rebuilt = Self.makeDraft(for: mode, displayTimeZone: model.timeZone)
            draft = rebuilt
            original = rebuilt
        }
        if let subjectID = draft.subjectID, model.library.subject(withID: subjectID) == nil {
            draft.subjectID = nil
            original.subjectID = nil
        }
        if !isEditing {
            titleFocused = true
        }
    }

    // MARK: - Actions

    private func save() {
        switch mode {
        case .new(let event):
            let added = draft.event(updating: event, eventTimeZone: model.timeZone, fallbackTitle: fallbackTitle)
            model.add(added)
            copyPendingFiles(into: added)
            onClose()
        case .edit(let occurrence):
            if draft == original {
                onClose()
            } else if occurrence.event.repeats {
                showsSaveConfirmation = true
            } else {
                commitEdit(.thisEvent)
            }
        }
    }

    private func commitEdit(_ scope: SeriesEditing.Scope) {
        guard let occurrence = editedOccurrence else { return }
        let zone = occurrence.event.timing.timeZone ?? model.timeZone
        let edited = draft.event(updating: occurrence.event, eventTimeZone: zone, fallbackTitle: fallbackTitle)
        model.update(occurrence, with: edited, scope: scope)
        onClose()
    }

    private func delete(_ scope: SeriesEditing.Scope) {
        guard let occurrence = editedOccurrence else { return }
        model.delete(occurrence, scope: scope)
        onClose()
    }

    /// Copies the files dropped on a new event into the folder of its first occurrence, now that it is in
    /// the library.
    private func copyPendingFiles(into event: Event) {
        guard !pendingFiles.isEmpty else { return }
        let id = Occurrence.ID(eventID: event.id, date: event.timing.startDate)
        guard let occurrence = model.occurrence(id: id) else { return }
        files.addFiles(pendingFiles, to: occurrence)
        pendingFiles = []
    }

    /// The form's fields for `mode`, with days and times shown in `displayTimeZone`.
    private static func makeDraft(for mode: Mode, displayTimeZone: TimeZone) -> EventEditorDraft {
        switch mode {
        case .new(let event):
            return EventEditorDraft(event: event, timing: event.timing, displayTimeZone: displayTimeZone)
        case .edit(let occurrence):
            return EventEditorDraft(
                event: occurrence.event, timing: timing(of: occurrence), displayTimeZone: displayTimeZone)
        }
    }

    /// The timing of one occurrence: its own start and end for timed events, its own days for all-day
    /// ones. This is what the editor shows and what `SeriesEditing` expects back.
    private static func timing(of occurrence: Occurrence) -> EventTiming {
        switch occurrence.event.timing {
        case .timed(_, _, let timeZone):
            return .timed(start: occurrence.start, end: max(occurrence.start, occurrence.end), timeZone: timeZone)
        case .allDay(let start, let end):
            let span = max(0, start.days(to: end))
            return .allDay(start: occurrence.date, end: occurrence.date.adding(days: span))
        }
    }
}

/// The subject dot and the editable title (15 pt semibold, "New Event" when empty).
private struct EventEditorHeader: View {
    @Environment(CalendarModel.self) private var model
    @Binding var draft: EventEditorDraft
    var titleFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            SubjectDot(subject: model.library.subject(withID: draft.subjectID), size: 10)
            TextField("Title", text: $draft.title, prompt: Text("New Event"))
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .focused(titleFocused)
        }
    }
}
