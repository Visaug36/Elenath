import ElenathCore
import SwiftUI

/// The now marker, while today is on screen: an amber pill with the time in the gutter, a 1 pt amber line
/// with a dot across today's column, and a faint amber line across the other days. It moves when
/// `CalendarModel.now` ticks, without animating, and never takes clicks.
struct TimeGridNowIndicator: View {
    @Environment(CalendarModel.self) private var model
    let days: [CalendarDate]
    let columnWidth: CGFloat

    var body: some View {
        if let todayColumn = days.firstIndex(of: model.today) {
            let y = TimeGridGeometry.y(forMinute: model.math.minutesOfDay(model.now))
            let gutter = TimeGridGeometry.gutterWidth
            let todayX = gutter + columnWidth * CGFloat(todayColumn)
            let daysWidth = columnWidth * CGFloat(days.count)
            let pillWidth = gutter - 4
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: daysWidth, height: 1)
                    .position(x: gutter + daysWidth / 2, y: y)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: columnWidth, height: 1)
                    .position(x: todayX + columnWidth / 2, y: y)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
                    .position(x: todayX, y: y)
                TimeGridNowPill(text: EventFormatting.time(model.now, timeZone: model.timeZone))
                    .frame(width: pillWidth, alignment: .trailing)
                    .position(x: pillWidth / 2, y: y)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// "13:50" in `TextOnAccent` on an amber capsule, with tabular digits. A time too wide for the gutter
/// ("12:50 PM" in a large text size) shrinks a little rather than being cut off.
private struct TimeGridNowPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.textOnAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule()
                    .fill(Color.accentColor)
            }
    }
}
