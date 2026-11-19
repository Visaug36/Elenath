import SwiftUI

extension View {
    /// ← and → step the calendar back or forward by its span (a day, week or month) while this view or
    /// something in it has keyboard focus. Arrows held with ⌘, ⌥, ⌃ or ⇧ are left to the menus, and text
    /// fields keep their arrows because they handle them before they get here.
    func calendarArrowKeys() -> some View {
        modifier(CalendarArrowKeysModifier())
    }
}

private struct CalendarArrowKeysModifier: ViewModifier {
    @Environment(CalendarModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                let blocking: EventModifiers = [.command, .option, .control, .shift]
                guard press.modifiers.isDisjoint(with: blocking) else { return .ignored }
                model.step(press.key == .leftArrow ? -1 : 1)
                return .handled
            }
    }
}
