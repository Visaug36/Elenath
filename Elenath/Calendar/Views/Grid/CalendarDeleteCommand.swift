import ElenathCore
import SwiftUI

extension View {
    /// Delete (⌫ or ⌦, or Edit › Delete) deletes the selected event while the calendar has keyboard focus,
    /// after the same question the details and the editor ask: "This Event Only" / "All Future Events" for
    /// a repeating event, and that its folder goes to the Trash when it has files. Edit › Delete is
    /// unavailable while nothing is selected or the calendar can't be changed.
    func calendarDeleteCommand() -> some View {
        modifier(CalendarDeleteCommandModifier())
    }
}

private struct CalendarDeleteCommandModifier: ViewModifier {
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    /// The occurrence the question is about; kept after the question closes, so its buttons still find it.
    @State private var target: Occurrence? = nil
    @State private var isAsking = false

    func body(content: Content) -> some View {
        let canDelete = model.canEdit && model.selectedOccurrenceID != nil
        let delete: (() -> Void)? = canDelete ? { requestDelete() } : nil
        content
            .onDeleteCommand(perform: delete)
            .confirmsEventChange(.delete, isPresented: $isAsking, context: context) { scope in
                guard let target else { return }
                model.delete(target, scope: scope)
            }
    }

    /// What the question says about the target: its title, day and time, and how many files it has.
    private var context: EventChangeContext {
        guard let target else {
            return EventChangeContext(title: "", repeats: false, dayAndTime: "")
        }
        let fileCount = files.fileCount(for: target) ?? 0
        return EventChangeContext(occurrence: target, timeZone: model.timeZone, fileCount: fileCount)
    }

    private func requestDelete() {
        guard model.canEdit, let id = model.selectedOccurrenceID, let occurrence = model.occurrence(id: id) else {
            return
        }
        files.requestCounts(for: [occurrence])
        target = occurrence
        isAsking = true
    }
}
