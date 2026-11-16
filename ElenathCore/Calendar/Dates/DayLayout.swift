import Foundation

/// Places timed occurrences in one day column of the Day and Week views.
///
/// Positions are wall-clock minutes in the given time zone (0 = midnight, 1440 = the next midnight),
/// matching the hour rows of the grid even on DST days. Occurrences that overlap share the column
/// width side by side.
public struct DayLayout: Sendable {
    public struct Item: Hashable, Sendable {
        public var occurrence: Occurrence
        /// Which side-by-side column the occurrence is drawn in, from 0.
        public var column: Int
        /// How many columns its group of overlapping occurrences needs.
        public var columnCount: Int
        /// Top of the block in minutes since midnight, 0…1440, clipped to the day.
        public var startMinute: Int
        /// Bottom of the block in minutes since midnight, 0…1440, clipped to the day and at least the
        /// layout's minimum height below `startMinute` (unless that would pass midnight).
        public var endMinute: Int
        /// The occurrence started on an earlier day.
        public var continuesBefore: Bool
        /// The occurrence ends on a later day.
        public var continuesAfter: Bool

        public init(
            occurrence: Occurrence,
            column: Int,
            columnCount: Int,
            startMinute: Int,
            endMinute: Int,
            continuesBefore: Bool,
            continuesAfter: Bool
        ) {
            self.occurrence = occurrence
            self.column = column
            self.columnCount = columnCount
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.continuesBefore = continuesBefore
            self.continuesAfter = continuesAfter
        }
    }

    private static let minutesPerDay = 24 * 60

    /// Lays out the timed occurrences that fall on `day` in `timeZone`, sorted top to bottom.
    ///
    /// All-day occurrences and occurrences on other days are left out (all-day events belong in the
    /// all-day row). Blocks shorter than `minimumMinutes` are drawn `minimumMinutes` tall, and overlap
    /// is judged on the drawn blocks. Occurrences that overlap, directly or through others, form a
    /// group; each gets the lowest free column, and every member of the group gets the group's
    /// `columnCount`, the most columns it needs at any moment.
    public static func layout(
        _ occurrences: [Occurrence],
        on day: CalendarDate,
        timeZone: TimeZone,
        minimumMinutes: Int
    ) -> [Item] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = day.start(in: timeZone)
        let dayEnd = max(dayStart, day.end(in: timeZone))
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        let minimum = min(max(minimumMinutes, 0), minutesPerDay)
        var items: [Item] = []
        for occurrence in occurrences where !occurrence.isAllDay {
            let start = occurrence.start
            let end = max(occurrence.start, occurrence.end)
            guard OccurrenceExpander.overlaps(start: start, end: end, dayInterval) else { continue }
            let continuesBefore = start < dayStart
            let continuesAfter = end > dayEnd
            var startMinute = continuesBefore ? 0 : wallClockMinutes(of: start, calendar: calendar)
            var endMinute = end >= dayEnd ? minutesPerDay : wallClockMinutes(of: end, calendar: calendar)
            // On the night clocks go back, wall-clock time can run backwards inside one occurrence.
            endMinute = max(endMinute, startMinute)
            if endMinute - startMinute < minimum {
                endMinute = startMinute + minimum
                if endMinute > minutesPerDay {
                    endMinute = minutesPerDay
                    startMinute = minutesPerDay - minimum
                }
            }
            let item = Item(
                occurrence: occurrence, column: 0, columnCount: 1, startMinute: startMinute,
                endMinute: endMinute, continuesBefore: continuesBefore, continuesAfter: continuesAfter)
            items.append(item)
        }
        items.sort { lhs, rhs in
            if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
            if lhs.endMinute != rhs.endMinute { return lhs.endMinute > rhs.endMinute }
            return OccurrenceExpander.chronologicalOrder(lhs.occurrence, rhs.occurrence)
        }
        assignColumns(&items)
        return items
    }

    /// Gives each item the lowest column that is free at its start, group by group. `items` must be
    /// sorted by `startMinute`. Greedy assignment in start order needs exactly as many columns as the
    /// most items that overlap at one moment.
    private static func assignColumns(_ items: inout [Item]) {
        var groupStart = 0
        while groupStart < items.count {
            // Bottom of each column so far; a zero-height block still occupies its minute.
            var columnEnds: [Int] = []
            var groupEnd = groupStart
            var groupBottom = drawnEnd(of: items[groupStart])
            while groupEnd < items.count && items[groupEnd].startMinute < groupBottom {
                let top = items[groupEnd].startMinute
                let bottom = drawnEnd(of: items[groupEnd])
                if let free = columnEnds.firstIndex(where: { $0 <= top }) {
                    items[groupEnd].column = free
                    columnEnds[free] = bottom
                } else {
                    items[groupEnd].column = columnEnds.count
                    columnEnds.append(bottom)
                }
                groupBottom = max(groupBottom, bottom)
                groupEnd += 1
            }
            for member in groupStart..<groupEnd {
                items[member].columnCount = columnEnds.count
            }
            groupStart = groupEnd
        }
    }

    private static func drawnEnd(of item: Item) -> Int {
        max(item.endMinute, item.startMinute + 1)
    }

    private static func wallClockMinutes(of instant: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
