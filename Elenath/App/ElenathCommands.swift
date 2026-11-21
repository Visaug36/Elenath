import AppKit
import ElenathCore
import SwiftUI

/// The menu bar: File › New Note ⌘N (New Event… ⌘N while the calendar is open), New Folder ⇧⌘N, Quick
/// Capture, Import… ⇧⌘I and Jump to Note… ⌘O; Edit › Find… ⌘F (the note's find bar, or the search field) and
/// Search Everywhere ⇧⌘F; View › Today ⌘T (today in the calendar while it is open), Inbox ⌥⌘I, Calendar,
/// Day ⌘1, Week ⌘2 and Month ⌘3 (from anywhere), Previous and Next ⌘← ⌘→ in the calendar, Back ⌘[ and
/// Forward ⌘]; and a Help menu that opens the project's GitHub pages in the browser (Elenath itself never
/// goes online).
struct ElenathCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            FileCommands(model: model)
        }
        CommandGroup(before: .textEditing) {
            FindCommands(model: model)
        }
        CommandGroup(before: .toolbar) {
            NavigationCommands(model: model)
        }
        CommandGroup(replacing: .help) {
            HelpCommands()
        }
        SidebarCommands()
    }
}

/// Menu items are views, so their enabled state follows the model through Observation.
private struct FileCommands: View {
    let model: AppModel

    var body: some View {
        if model.route == .calendar {
            Button("New Event…") {
                model.calendar.requestsNewEvent = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.calendar.canEdit)
            Button("New Note") {
                model.newNote()
            }
            .disabled(!model.canEdit(model.currentPlace.container))
        } else {
            Button("New Note") {
                model.newNote()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.canEdit(model.currentPlace.container))
        }
        Button("New Folder") {
            let place = model.currentPlace
            model.newFolder(in: place.container, folder: place.folder)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!model.canEdit(model.currentPlace.container))
        Button("Quick Capture") {
            QuickCapturePanelController.shared.show(model: model)
        }
        Divider()
        Button("Import…") {
            model.chooseAndImport()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!model.canEdit(model.currentPlace.container))
        Button("Jump to Note…") {
            model.isJumpPanelShown = true
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(model.state != .ready)
    }
}

/// ⌘F belongs to the text being edited, as in any Mac app: the note's find bar. Elsewhere it focuses the
/// search field, like ⇧⌘F.
private struct FindCommands: View {
    let model: AppModel

    var body: some View {
        Button("Find…") {
            find()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(model.state != .ready)
        Button("Search Everywhere") {
            // The field searches events while the calendar is open: everywhere means the notes.
            if model.route == .calendar {
                model.go(to: .today)
            }
            SearchFocus.focus()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(model.state != .ready)
    }

    private func find() {
        guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else {
            SearchFocus.focus()
            return
        }
        if textView.isFieldEditor, textView.delegate is NSSearchField {
            SearchFocus.focus()
            return
        }
        guard textView.usesFindBar || textView.usesFindPanel else {
            SearchFocus.focus()
            return
        }
        let request = NSMenuItem()
        request.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(request)
    }
}

private struct NavigationCommands: View {
    let model: AppModel

    var body: some View {
        Group {
            Button("Today") {
                if model.route == .calendar {
                    model.calendar.goToToday()
                } else {
                    model.go(to: .today)
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Inbox") {
                model.go(to: .inbox)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Calendar") {
                model.go(to: .calendar)
            }
            Divider()
            CalendarSpanCommands(model: model)
            Divider()
            Button("Back") {
                model.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!model.canGoBack)
            Button("Forward") {
                model.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!model.canGoForward)
            Divider()
        }
        .disabled(model.state != .ready)
    }
}

/// The Help menu: the project's pages on GitHub, opened in the browser.
private struct HelpCommands: View {
    var body: some View {
        Button("Elenath on GitHub") {
            AppLinks.open(AppLinks.repository)
        }
        Divider()
        Button("Check for Updates…") {
            AppLinks.open(AppLinks.releases)
        }
        Button("Report an Issue…") {
            AppLinks.open(AppLinks.newIssue)
        }
    }
}

/// Day ⌘1, Week ⌘2 and Month ⌘3 open the calendar from anywhere; Previous and Next (⌘← ⌘→) step it while it
/// is open (Ithil's `CalendarNavigationCommands`).
private struct CalendarSpanCommands: View {
    let model: AppModel

    var body: some View {
        let calendar = model.calendar
        Button("Day") {
            show(.day)
        }
        .keyboardShortcut("1", modifiers: .command)
        Button("Week") {
            show(.week)
        }
        .keyboardShortcut("2", modifiers: .command)
        Button("Month") {
            show(.month)
        }
        .keyboardShortcut("3", modifiers: .command)
        Button(previousTitle(calendar.span)) {
            goBack()
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(model.route != .calendar)
        Button(nextTitle(calendar.span)) {
            goForward()
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(model.route != .calendar)
    }

    private func show(_ span: CalendarSpan) {
        model.calendar.span = span
        model.go(to: .calendar)
    }

    private func previousTitle(_ span: CalendarSpan) -> LocalizedStringKey {
        switch span {
        case .day: "Previous Day"
        case .week: "Previous Week"
        case .month: "Previous Month"
        }
    }

    private func nextTitle(_ span: CalendarSpan) -> LocalizedStringKey {
        switch span {
        case .day: "Next Day"
        case .week: "Next Week"
        case .month: "Next Month"
        }
    }

    /// ⌘← / ⌘→ belong to the text while typing (the search field, a note, the event editor): there they move
    /// to the start or end of the line as usual, and only elsewhere step the calendar.
    private func goBack() {
        if let textView = editingTextView() {
            textView.moveToLeftEndOfLine(nil)
        } else {
            model.calendar.step(-1)
        }
    }

    private func goForward() {
        if let textView = editingTextView() {
            textView.moveToRightEndOfLine(nil)
        } else {
            model.calendar.step(1)
        }
    }

    private func editingTextView() -> NSTextView? {
        NSApplication.shared.keyWindow?.firstResponder as? NSTextView
    }
}
