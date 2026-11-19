import ElenathCore
import SwiftUI

/// The main window once a library is open: the sidebar, the toolbar, and whatever was opened. While the
/// calendar is open, the toolbar is the calendar's and the search field searches events.
struct LibraryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(CalendarModel.self) private var calendar

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: Metrics.sidebarMinimumWidth, ideal: Metrics.sidebarWidth, max: Metrics.sidebarMaximumWidth)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.backgroundWindow)
                .navigationTitle(Text(verbatim: windowTitle))
                .toolbar {
                    LibraryToolbar(showsCalendar: model.route == .calendar)
                }
        }
        .searchable(text: searchText, placement: .toolbar, prompt: Text("Search"))
        .onSubmit(of: .search) {
            if model.route == .calendar {
                calendar.isSearchDismissed = false
            }
        }
        .overlay {
            if model.isJumpPanelShown {
                JumpPanel()
            }
        }
        .sheet(item: $model.spaceSheet) { request in
            SpaceSheet(request: request)
        }
    }

    /// The search field: the calendar's own search while the calendar is open, the notes' everywhere else.
    private var searchText: Binding<String> {
        if model.route == .calendar {
            return Binding(get: { calendar.searchText }, set: { calendar.searchText = $0 })
        }
        return Binding(get: { model.searchText }, set: { model.searchText = $0 })
    }

    @ViewBuilder private var detail: some View {
        switch model.route {
        case .today:
            TodayView()
        case .inbox:
            InboxView()
        case .calendar:
            CalendarDetailView()
        case .folder(let container, let folder):
            FolderContentsView(container: container, folder: folder)
                .id(FolderIdentity(container: container, folder: folder))
        case .tag(let tag, let workplace):
            TagNotesView(tag: tag, workplace: workplace)
                .id(tag)
        case .note:
            if let session = model.session {
                NoteEditorView(session: session)
                    .id(ObjectIdentifier(session))
            } else {
                Color.backgroundWindow
            }
        case .search:
            SearchResultsView()
        }
    }

    /// What the window is called in Mission Control and the Window menu.
    private var windowTitle: String {
        switch model.route {
        case .today: String(localized: "Today")
        case .inbox: String(localized: "Inbox")
        case .calendar: String(localized: "Calendar")
        case .folder(let container, let folder): model.placeName(container, folder)
        case .tag(let tag, _): "#\(tag)"
        case .note(let note): note.title
        case .search: String(localized: "Search")
        }
    }
}

private struct FolderIdentity: Hashable {
    var container: Container
    var folder: ItemPath
}

/// The toolbar: back and forward, where the user is, and the amber New Note button; or, while the calendar
/// is open, the calendar's (`CalendarToolbar`). The search field comes from `.searchable` on `LibraryWindow`.
private struct LibraryToolbar: ToolbarContent {
    let showsCalendar: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ToolbarHistoryButtons()
        }
        if showsCalendar {
            CalendarToolbar()
        } else {
            ToolbarItem(placement: .navigation) {
                ToolbarBreadcrumb()
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarNewNoteButton()
            }
        }
    }
}

private struct ToolbarHistoryButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ControlGroup {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .help("Back")
            .disabled(!model.canGoBack)
            Button {
                model.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .help("Forward")
            .disabled(!model.canGoForward)
        }
        .labelStyle(.iconOnly)
    }
}

/// "Uni › Physics" with the space's dot: the place of what is open.
private struct ToolbarBreadcrumb: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let place {
            HStack(spacing: 6) {
                if let space = model.space(of: place.container) {
                    SpaceDot(space: space)
                    if space.isSealed {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.textTertiary)
                            .accessibilityLabel(Text("Sealed"))
                    }
                }
                Text(verbatim: model.placeName(place.container, place.folder))
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var place: (container: Container, folder: ItemPath)? {
        switch model.route {
        case .folder(let container, let folder):
            return (container, folder)
        case .note(let note):
            return (note.container, note.path.folder)
        case .inbox:
            return (.inbox, .root)
        case .today, .calendar, .tag, .search:
            return nil
        }
    }
}

/// The square amber button: a new note where the user is.
private struct ToolbarNewNoteButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.newNote()
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.textOnAccent)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .help("New Note")
        .accessibilityLabel(Text("New Note"))
        .disabled(!model.canEdit(model.currentPlace.container))
    }
}
