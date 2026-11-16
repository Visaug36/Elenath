import Foundation

/// A day on the Gregorian calendar with no time of day and no time zone.
///
/// All-day events and folder names (`yyyy-MM-dd`) use it, so they never shift when the Mac's
/// time zone changes. Convert to and from `Date` only through an explicit time zone.
public struct CalendarDate: Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day that `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        let parts = Self.gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The first instant of this day in `timeZone`. Usually midnight, but on days where a DST change
    /// skips midnight it is the first moment that exists.
    public func start(in timeZone: TimeZone) -> Date {
        let calendar = Self.gregorian(timeZone)
        let noonParts = DateComponents(year: year, month: month, day: day, hour: 12)
        let noon = calendar.date(from: noonParts) ?? Date(timeIntervalSince1970: 0)
        return calendar.startOfDay(for: noon)
    }

    /// The first instant of the following day in `timeZone`, the exclusive end of this day.
    public func end(in timeZone: TimeZone) -> Date {
        adding(days: 1).start(in: timeZone)
    }

    /// This date moved by a whole number of days (negative moves back). Leap years and month
    /// lengths are handled by the Gregorian calendar.
    public func adding(days: Int) -> CalendarDate {
        let calendar = Self.gregorian(Self.utc)
        guard let date = calendar.date(byAdding: .day, value: days, to: start(in: Self.utc)) else { return self }
        return CalendarDate(date, in: Self.utc)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(to other: CalendarDate) -> Int {
        let calendar = Self.gregorian(Self.utc)
        return calendar.dateComponents([.day], from: start(in: Self.utc), to: other.start(in: Self.utc)).day ?? 0
    }

    /// Gregorian weekday: 1 = Sunday … 7 = Saturday, matching `Calendar.firstWeekday`.
    public var weekday: Int {
        Self.gregorian(Self.utc).component(.weekday, from: start(in: Self.utc))
    }

    /// Whether this names a real day (e.g. 2027-02-29 does not).
    public var isValid: Bool {
        let calendar = Self.gregorian(Self.utc)
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return false }
        return CalendarDate(date, in: Self.utc) == self
    }

    /// `yyyy-MM-dd`, the format used in folder names and in events.json.
    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Parses `yyyy-MM-dd`. Returns nil for anything else, including impossible days.
    public init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
        guard isValid else { return nil }
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

extension CalendarDate: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = CalendarDate(isoString: string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a yyyy-MM-dd date, got \"\(string)\"")
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}

extension CalendarDate: CustomStringConvertible {
    public var description: String { isoString }
}
