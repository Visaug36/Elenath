import AppKit
import ElenathCore
import SwiftUI

/// Words the menu bar extra shows beyond `EventFormatting`. Days are formatted on the Gregorian calendar in
/// the user's locale, like the rest of Elenath.
enum MenuBarFormatting {
    /// "Tuesday", today's weekday at the top.
    static func weekday(_ day: CalendarDate) -> String {
        dateStyle(.standalone).weekday(.wide).format(day.start(in: utc))
    }

    /// "6 October" (or "October 6", as the locale has it), next to the weekday.
    static func dayAndMonth(_ day: CalendarDate) -> String {
        dateStyle(.standalone).day().month(.wide).format(day.start(in: utc))
    }

    /// The Next card's first line: "Next, in 10 min" within the hour, otherwise "Next, today",
    /// "Next, tomorrow", "Next, Thursday" or "Next, Mon 12 Oct".
    static func nextLabel(_ occurrence: Occurrence, now: Date, math: CalendarMath) -> String {
        let seconds = occurrence.start.timeIntervalSince(now)
        if !occurrence.isAllDay, seconds > 0, seconds <= 60 * 60 {
            let minutes = max(1, Int((seconds / 60).rounded(.up)))
            return String(localized: "Next, in \(minutes) min", comment: "Menu bar: the next event starts in N minutes")
        }
        let today = math.today(now: now)
        let day = EventFormatting.displayDay(of: occurrence, timeZone: math.timeZone)
        let when: String
        switch math.relativeDay(day, today: today) {
        case .yesterday, .today:
            return String(localized: "Next, today", comment: "Menu bar: the next event is later today")
        case .tomorrow:
            return String(localized: "Next, tomorrow", comment: "Menu bar: the next event is tomorrow")
        case .laterThisWeek:
            when = dateStyle(.middleOfSentence).weekday(.wide).format(day.start(in: utc))
        case .other(let date):
            when = EventFormatting.shortDate(date, includeYear: date.year != today.year)
        }
        return String(localized: "Next, \(when)", comment: "Menu bar: the next event's weekday or date")
    }

    /// "14:00 – 15:30 · Room B204", or "All day · Room B204".
    static func detail(_ occurrence: Occurrence, timeZone: TimeZone) -> String {
        var parts = [EventFormatting.timeRange(occurrence, timeZone: timeZone)]
        let location = occurrence.event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty {
            parts.append(location)
        }
        return EventFormatting.joined(parts)
    }

    /// The time column of the Today and Tomorrow lists: "09:30" (or "9:30 AM"), or "All day".
    static func timeColumn(_ occurrence: Occurrence, timeZone: TimeZone) -> String {
        if occurrence.isAllDay {
            return String(localized: "All day")
        }
        return EventFormatting.time(occurrence.start, timeZone: timeZone)
    }

    /// Wide enough for "10:30 AM" when the Mac's clock shows a day period ("AM", "in the morning"),
    /// otherwise for "09:30" and "All day".
    static func timeColumnWidth() -> CGFloat {
        let hourFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? ""
        return showsDayPeriod(hourFormat) ? 62 : 44
    }

    /// Whether a date format pattern has a day-period field (`a`, `b` or `B`), skipping quoted literal text
    /// such as German "HH 'Uhr'".
    static func showsDayPeriod(_ pattern: String) -> Bool {
        var isQuoted = false
        for character in pattern {
            if character == "'" {
                isQuoted.toggle()
            } else if !isQuoted, character == "a" || character == "b" || character == "B" {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    private static func dateStyle(_ capitalization: FormatStyleCapitalizationContext) -> Date.FormatStyle {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = utc
        return Date.FormatStyle(
            locale: .autoupdatingCurrent, calendar: calendar, timeZone: utc, capitalizationContext: capitalization)
    }
}

/// Showing things in the main window from the menu bar extra.
///
/// Each of these activates Elenath and makes its calendar window key, which also closes the menu bar extra's
/// window (it closes when it stops being key).
@MainActor
enum MenuBarNavigation {
    /// Shows the occurrence's day in the calendar with the occurrence selected.
    static func show(_ occurrence: Occurrence, model: CalendarModel, openWindow: OpenWindowAction) {
        model.searchText = ""
        model.reveal(occurrence)
        openElenath(openWindow: openWindow)
    }

    /// Shows `day` in the calendar.
    static func show(_ day: CalendarDate, model: CalendarModel, openWindow: OpenWindowAction) {
        model.searchText = ""
        model.show(day, span: nil)
        model.showCalendar?()
        openElenath(openWindow: openWindow)
    }

    /// Activates Elenath and brings its calendar window forward (restored if minimized), or opens one when
    /// none is open. Settings, About, panels and the menu bar extra's own (untitled) window are never picked.
    static func openElenath(openWindow: OpenWindowAction) {
        let app = NSApplication.shared
        if app.isHidden {
            app.unhide(nil)
        }
        app.activate()
        let shown = app.windows.filter { isDocumentStyleWindow($0) }
        let main = shown.first { isMainWindow($0) } ?? shown.first { !isAuxiliaryWindow($0) }
        guard let window = main else {
            openWindow(id: MainView.windowID)
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// A shown (or minimized) ordinary titled window that can be main: not a panel, not the menu bar extra's
    /// borderless window, nothing floating.
    private static func isDocumentStyleWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.styleMask.contains(.titled), window.level == .normal else { return false }
        return window.canBecomeMain && (window.isVisible || window.isMiniaturized)
    }

    /// SwiftUI names a scene's windows after its ID ("main-AppWindow-1").
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(MainView.windowID) ?? false
    }

    private static func isAuxiliaryWindow(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier.localizedCaseInsensitiveContains("settings")
            || identifier.localizedCaseInsensitiveContains("about")
    }
}

/// The look of the menu bar extra's rows: full width, a `ControlFill` highlight under the pointer, like a
/// menu item in Elenath's colors. The label can read `isMenuBarRowHighlighted` to brighten its quiet parts
/// while the highlight is behind them.
struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarRowButtonBody(configuration: configuration)
    }
}

private struct MenuBarRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let isHighlighted = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .environment(\.isMenuBarRowHighlighted, isHighlighted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
                    .fill(isHighlighted ? Color.controlFill : Color.clear)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// The amber button of the Next card ("Open Files"), with dark ink, which keeps AA contrast on amber in
/// both themes.
struct MenuBarProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.textOnAccent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(shape.fill(configuration.isPressed ? Color.accentColor.opacity(0.8) : Color.accentColor))
            .contentShape(shape)
    }
}

private struct MenuBarRowHighlightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the menu bar row this view is in has its highlight behind it (under the pointer or pressed).
    var isMenuBarRowHighlighted: Bool {
        get { self[MenuBarRowHighlightKey.self] }
        set { self[MenuBarRowHighlightKey.self] = newValue }
    }
}
