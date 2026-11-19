import AppKit
import ElenathCore
import SwiftUI

/// The menu bar extra's window (`MenuBarExtra` with `.menuBarExtraStyle(.window)`), as in docs/DESIGN.md
/// screen 8, and Elenath's DESIGN.md screen 12): today's weekday and date, a card for the next event with
/// "Open Files", what's on today and tomorrow, then menu-style rows for Capture, the Inbox, opening Elenath,
/// Settings and Quit. Events from every space show here, sealed ones too (title, time, location and file
/// count: the calendar exception).
///
/// Clicking an event shows it in the main window, selected. Every action moves the keyboard to another
/// window or app, and the menu bar extra's window closes when it stops being key, so nothing has to close
/// it by hand. Until a library is open, a sentence says what Elenath is waiting for instead of the agenda.
struct MenuBarContent: View {
    /// The window's width.
    static let width: CGFloat = 300

    @Environment(CalendarModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                MenuBarHeader()
                content
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
                .padding(.horizontal, 14)
                .accessibilityHidden(true)
            MenuBarActions()
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
        .frame(width: Self.width)
        .background {
            // Opaque on every macOS version, so the tokens keep the contrast docs/DESIGN.md measures. The
            // window around it (shape, edge, shadow) is drawn by the system, as Liquid Glass on macOS 26.
            Color.backgroundRaised
                .ignoresSafeArea()
        }
    }

    @ViewBuilder private var content: some View {
        switch app.state {
        case .ready:
            switch model.state {
            case .ready:
                MenuBarAgenda()
            case .closed, .loading:
                MenuBarStatusMessage(text: "Opening your calendar…")
            case .nameTakenBySpace, .unreadable:
                MenuBarStatusMessage(text: "Elenath can't open your calendar. Open Elenath to see why.")
            }
        case .loading:
            MenuBarStatusMessage(text: "Opening your library…")
        case .needsFolder:
            MenuBarStatusMessage(text: "Open Elenath and choose a folder for your notes and calendar to get started.")
        case .folderMissing:
            MenuBarStatusMessage(text: "Elenath can't find its folder. Open Elenath to locate it.")
        case .noLibrary, .unreadable:
            MenuBarStatusMessage(text: "Elenath can't open your library. Open Elenath to see why.")
        }
    }
}

/// "Tuesday 6 October": the weekday in New York, the date in `TextSecondary`.
private struct MenuBarHeader: View {
    @Environment(CalendarModel.self) private var model

    var body: some View {
        let today = model.today
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: MenuBarFormatting.weekday(today))
                .font(Typography.dayHeader)
                .foregroundStyle(Color.textPrimary)
            Text(verbatim: MenuBarFormatting.dayAndMonth(today))
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What Elenath is waiting for while no library is open.
private struct MenuBarStatusMessage: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(Typography.secondary)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }
}

/// The menu-style rows at the bottom: "Capture… ⌥Space", "Inbox" with its count, "Open Elenath ⌘O",
/// "Settings… ⌘," and "Quit Elenath ⌘Q". The shortcuts work while this window is key; Capture's is the global
/// one from Settings (none when it is off).
private struct MenuBarActions: View {
    @Environment(AppModel.self) private var app
    @Environment(CalendarModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            MenuBarActionRow(title: "Capture…", shortcut: settings.quickCaptureHotKey?.displayString) {
                QuickCapturePanelController.shared.show(model: app)
            }
            .disabled(!app.canEdit)
            MenuBarActionRow(title: "Inbox", shortcut: app.inboxCount > 0 ? "\(app.inboxCount)" : nil) {
                app.go(to: .inbox)
                MenuBarNavigation.openElenath(openWindow: openWindow)
            }
            .disabled(app.state != .ready)
            MenuBarActionRow(title: "Open Elenath", shortcut: "⌘O") {
                MenuBarNavigation.openElenath(openWindow: openWindow)
            }
            .keyboardShortcut("o", modifiers: .command)
            MenuBarActionRow(title: "Settings…", shortcut: "⌘,") {
                NSApplication.shared.activate()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            MenuBarActionRow(title: "Quit Elenath", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// One menu-style row: the title on the left, its shortcut in `TextTertiary` on the right.
private struct MenuBarActionRow: View {
    let title: LocalizedStringKey
    /// Key symbols, not localized: "⌘O".
    let shortcut: String?
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            MenuBarActionLabel(title: title, shortcut: shortcut)
        }
        .buttonStyle(MenuBarRowButtonStyle())
    }
}

private struct MenuBarActionLabel: View {
    @Environment(\.isMenuBarRowHighlighted) private var isHighlighted
    let title: LocalizedStringKey
    let shortcut: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: 8)
            if let shortcut {
                Text(verbatim: shortcut)
                    .font(Typography.body)
                    .foregroundStyle(isHighlighted ? Color.textSecondary : Color.textTertiary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The menu bar icon: `star.fill` as a template image, so it takes the menu bar's own colors. VoiceOver
/// calls it "Elenath".
struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "star.fill")
            .renderingMode(.template)
            .accessibilityLabel(Text("Elenath", comment: "The app's name"))
    }
}
