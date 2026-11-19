import Foundation

extension UndoManager {
    /// Registers what `body` registers as an undo group of its own, so one Undo takes back this change and
    /// nothing else. Inside an open group (an undo or redo running, or a change made while another group is
    /// open) `body` simply joins it.
    ///
    /// AppKit groups by event: the first registration opens a group, and the application closes it only after
    /// it has dispatched the next event. An explicit `beginUndoGrouping()` at level 0 opens that event group
    /// too, so a change made without an event (after Bring In's copy finishes, in the crash check, later Nano
    /// bot) used to leave it open, and every change after it joined the same group until the user's next key
    /// press or click. So the group is opened with automatic grouping off and closed before it is turned back
    /// on: no event group is left behind.
    @MainActor
    func registerAsOwnGroup(_ body: () -> Void) {
        guard !isUndoing, !isRedoing, groupingLevel == 0 else {
            body()
            return
        }
        let groupedByEvent = groupsByEvent
        groupsByEvent = false
        beginUndoGrouping()
        body()
        endUndoGrouping()
        groupsByEvent = groupedByEvent
    }
}
