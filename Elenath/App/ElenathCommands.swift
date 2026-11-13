import AppKit
import ElenathCore
import SwiftUI

/// The menu bar: File › New Note ⌘N, New Folder ⇧⌘N, Quick Capture, Import… ⇧⌘I and Jump to Note… ⌘O;
/// Edit › Find… ⌘F (the note's find bar) and Search Everywhere ⇧⌘F; View › Today ⌘1, Inbox ⌘2, Back ⌘[ and
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
        Button("New Note") {
            model.newNote()
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(!model.canEdit(model.currentPlace.container))
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
                model.go(to: .today)
            }
            .keyboardShortcut("1", modifiers: .command)
            Button("Inbox") {
                model.go(to: .inbox)
            }
            .keyboardShortcut("2", modifiers: .command)
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
