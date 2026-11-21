import Foundation

/// One alert Ithil wants macOS to deliver.
public struct PlannedAlert: Hashable, Sendable {
    /// Stable across launches; changes when anything shown in the alert changes (see
    /// `AlertPlanner.identifier(for:minutesBefore:)`).
    public var identifier: String
    /// The occurrence the alert is for.
    public var occurrence: Occurrence
    /// When the notification fires.
    public var fireDate: Date
    /// The event's `AlertOffset.minutesBefore`.
    public var minutesBefore: Int

    public init(identifier: String, occurrence: Occurrence, fireDate: Date, minutesBefore: Int) {
        self.identifier = identifier
        self.occurrence = occurrence
        self.fireDate = fireDate
        self.minutesBefore = minutesBefore
    }
}

/// Decides which notifications should be pending: the nearest upcoming alerts of every event that has
/// one, so they fire even while Ithil is quit.
///
/// - Timed events: the alert fires `minutesBefore` minutes (elapsed time) before the occurrence starts.
/// - All-day events: the alert is relative to `allDayAlertHour`:00 on the occurrence's first day in
///   `displayTimeZone`, counted in wall-clock time, so "1 day before" fires at 09:00 the day before and
///   "at time of event" at 09:00 that day, also when the clocks change in between.
/// - Only alerts that fire after `now` and within `horizonDays` days of it are planned, earliest first,
///   at most `maximumCount` (macOS keeps at most 64 pending notifications per app). Repeating events,
///   excluded dates and detached events behave exactly as in the calendar (`OccurrenceExpander`).
///
/// Identifiers are deterministic, so the app can compare what is pending with what should be and only
/// touch the difference (`AlertSynchronizer`).
public struct AlertPlanner: Sendable {
    /// Every notification identifier Ithil makes starts with this.
    public static let identifierPrefix = "elenath.alert."

    /// Where all-day events are placed, as in `OccurrenceExpander`.
    public let displayTimeZone: TimeZone
    /// The hour (0…23) all-day alerts are relative to.
    public let allDayAlertHour: Int
    /// The most alerts `plan(_:now:)` returns.
    public let maximumCount: Int
    /// How many days ahead of `now` alerts are planned.
    public let horizonDays: Int

    private let expander: OccurrenceExpander
    private let displayCalendar: Calendar

    /// Out-of-range values are clamped: `allDayAlertHour` to 0…23, the others to zero or more.
    public init(displayTimeZone: TimeZone, allDayAlertHour: Int = 9, maximumCount: Int = 48, horizonDays: Int = 14) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = displayTimeZone
        self.displayTimeZone = displayTimeZone
        self.allDayAlertHour = min(max(allDayAlertHour, 0), 23)
        self.maximumCount = max(0, maximumCount)
        self.horizonDays = max(0, horizonDays)
        self.expander = OccurrenceExpander(displayTimeZone: displayTimeZone)
        self.displayCalendar = calendar
    }

    /// The nearest upcoming alerts (fireDate > now), earliest fireDate first, at most maximumCount.
    ///
    /// Alerts that fire at the same moment are ordered by occurrence start, then by identifier.
    public func plan(_ library: CalendarDocument, now: Date) -> [PlannedAlert] {
        guard maximumCount > 0, horizonDays > 0 else { return [] }
        var alerting: [Event] = []
        var largestOffset = 0
        for event in library.events {
            guard let alert = event.alert else { continue }
            alerting.append(event)
            largestOffset = max(largestOffset, alert.minutesBefore)
        }
        // Occurrences up to the horizon plus the largest offset in use, so a "1 day before" alert for an
        // event just past the horizon is still found. The spare day covers all-day alerts, which are
        // counted in wall-clock time. A hand-edited offset of months doesn't make the search that long.
        guard !alerting.isEmpty,
            let horizon = displayCalendar.date(byAdding: .day, value: horizonDays, to: now),
            let searchDays = displayCalendar.date(byAdding: .day, value: horizonDays + 1, to: now)
        else { return [] }
        let searchOffset = min(largestOffset, Self.longestSearchedOffset)
        let searchEnd = searchDays.addingTimeInterval(TimeInterval(searchOffset) * 60)
        // Overlapping rather than starting in the window: an all-day event that began at midnight can
        // still have its 09:00 alert ahead.
        let candidates = expander.occurrences(of: alerting, in: DateInterval(start: now, end: searchEnd))
        var alerts: [PlannedAlert] = []
        var seen: Set<String> = []
        for occurrence in candidates {
            guard let offset = occurrence.event.alert?.minutesBefore else { continue }
            let minutes = max(0, offset)
            guard let fireDate = scheduledFireDate(for: occurrence, minutesBefore: minutes),
                fireDate > now, fireDate <= horizon
            else { continue }
            let alertIdentifier = self.identifier(for: occurrence, minutesBefore: minutes)
            guard seen.insert(alertIdentifier).inserted else { continue }
            let alert = PlannedAlert(
                identifier: alertIdentifier, occurrence: occurrence, fireDate: fireDate, minutesBefore: minutes)
            alerts.append(alert)
        }
        alerts.sort(by: Self.firingOrder)
        return Array(alerts.prefix(maximumCount))
    }

    /// The identifier for an occurrence's alert (exposed for tests and for matching delivered notifications).
    ///
    /// `elenath.alert.<event UUID>.<yyyy-MM-dd occurrence date>.<minutesBefore>.<16 hex digits>`, where the
    /// last part is a 64-bit FNV-1a hash of the title, location, start and end (whole seconds), the
    /// all-day flag and `minutesBefore`. It is the same in every process and on every Mac, and changes
    /// whenever one of those changes. A negative `minutesBefore` counts as 0, as in `AlertOffset`.
    public func identifier(for occurrence: Occurrence, minutesBefore: Int) -> String {
        let minutes = max(0, minutesBefore)
        var hasher = AlertContentHasher()
        hasher.combine(occurrence.event.title)
        hasher.combine(occurrence.event.location)
        hasher.combine(Self.wholeSeconds(occurrence.start))
        hasher.combine(Self.wholeSeconds(occurrence.end))
        hasher.combine(occurrence.isAllDay)
        hasher.combine(Int64(minutes))
        let parts = [occurrence.event.id.uuidString, occurrence.date.isoString, String(minutes), hasher.hexDigest]
        return Self.identifierPrefix + parts.joined(separator: ".")
    }

    /// Parses an identifier back into (event ID, occurrence date); nil for anything not made by Ithil.
    public static func parse(identifier: String) -> (eventID: UUID, date: CalendarDate)? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let body = identifier.dropFirst(identifierPrefix.count)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
            let eventID = UUID(uuidString: String(parts[0])),
            let date = CalendarDate(isoString: String(parts[1])),
            isMinutesField(parts[2]),
            isHashField(parts[3])
        else { return nil }
        return (eventID: eventID, date: date)
    }

    // MARK: - Fire dates

    private static let minutesPerDay = 24 * 60

    /// The most minutes past the horizon `plan(_:now:)` looks for events whose alert fires before it.
    private static let longestSearchedOffset = 31 * minutesPerDay

    /// When the alert `minutesBefore` minutes before `occurrence` fires, or nil if the calendar can't
    /// name that moment.
    private func scheduledFireDate(for occurrence: Occurrence, minutesBefore: Int) -> Date? {
        guard occurrence.isAllDay else {
            return occurrence.start.addingTimeInterval(-TimeInterval(minutesBefore) * 60)
        }
        // Wall-clock arithmetic on the alert hour of the first day: whole days move by calendar days.
        let minuteOfDay = allDayAlertHour * 60 - minutesBefore
        let dayOffset = OccurrenceDayMath.floorDivide(minuteOfDay, Self.minutesPerDay)
        let wallClockMinute = OccurrenceDayMath.floorModulo(minuteOfDay, Self.minutesPerDay)
        let day = OccurrenceDayMath.date(fromNumber: OccurrenceDayMath.number(of: occurrence.date) + dayOffset)
        let parts = DateComponents(
            year: day.year, month: day.month, day: day.day, hour: wallClockMinute / 60, minute: wallClockMinute % 60)
        // A time inside a DST gap moves forward, as `Calendar` resolves it.
        return displayCalendar.date(from: parts)
    }

    /// Earliest fire date first; then earliest occurrence start; then by identifier, so the order
    /// never depends on the order of the events in the library.
    private static func firingOrder(_ lhs: PlannedAlert, _ rhs: PlannedAlert) -> Bool {
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        if lhs.occurrence.start != rhs.occurrence.start { return lhs.occurrence.start < rhs.occurrence.start }
        return lhs.identifier < rhs.identifier
    }

    // MARK: - Identifiers

    private static func wholeSeconds(_ instant: Date) -> Int64 {
        Int64(instant.timeIntervalSince1970.rounded())
    }

    private static let decimalDigits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let lowercaseHexLetters = UInt8(ascii: "a")...UInt8(ascii: "f")

    /// ASCII digits that make a valid `Int` (the `minutesBefore` part), so every identifier
    /// `identifier(for:minutesBefore:)` makes parses, whatever the offset.
    private static func isMinutesField(_ field: Substring) -> Bool {
        guard !field.isEmpty, Int(field) != nil else { return false }
        return field.utf8.allSatisfy { decimalDigits.contains($0) }
    }

    /// Exactly 16 lowercase hex digits (the hash part), as `AlertContentHasher.hexDigest` writes them.
    private static func isHashField(_ field: Substring) -> Bool {
        guard field.utf8.count == AlertContentHasher.hexDigestLength else { return false }
        return field.utf8.allSatisfy { decimalDigits.contains($0) || lowercaseHexLetters.contains($0) }
    }
}

/// 64-bit FNV-1a over a sequence of fields, for alert identifiers.
///
/// Swift's `Hasher` is seeded randomly in every process, so it can't make identifiers that must match
/// across launches. This one is fixed: the same fields give the same value in every process and on
/// every Mac. Strings are prefixed with their UTF-8 length, so ("ab", "c") and ("a", "bc") differ.
struct AlertContentHasher {
    static let hexDigestLength = 16

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x100_0000_01b3

    private(set) var value: UInt64 = AlertContentHasher.offsetBasis

    mutating func combine(byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* Self.prime
    }

    /// Eight bytes, little-endian (two's complement for negative numbers).
    mutating func combine(_ number: Int64) {
        var remaining = UInt64(bitPattern: number)
        for _ in 0..<8 {
            combine(byte: UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }

    /// The UTF-8 byte count (as an `Int64`), then the bytes.
    mutating func combine(_ text: String) {
        let bytes = text.utf8
        combine(Int64(bytes.count))
        for byte in bytes {
            combine(byte: byte)
        }
    }

    /// One byte: 1 for true, 0 for false.
    mutating func combine(_ flag: Bool) {
        combine(byte: flag ? 1 : 0)
    }

    /// `value` as 16 lowercase hex digits, zero-padded.
    var hexDigest: String {
        let digits = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, Self.hexDigestLength - digits.count)) + digits
    }
}
