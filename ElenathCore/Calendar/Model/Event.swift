import Foundation

/// One calendar entry. A repeating event is a single `Event` with a `recurrence`; its individual
/// dates are produced as `Occurrence`s.
public struct Event: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var timing: EventTiming
    /// nil means "no subject".
    public var subjectID: UUID?
    public var location: String
    public var notes: String
    /// nil means "no alert".
    public var alert: AlertOffset?
    /// nil means the event never repeats.
    public var recurrence: RecurrenceRule?
    /// Dates of a repeating series that were deleted, or detached into their own event
    /// ("edit this event only"). Dates are the occurrence's original day in the event's own time zone.
    public var excludedDates: Set<CalendarDate>
    /// Set when this event replaces one occurrence of another, repeating event.
    public var detachedFrom: SeriesOccurrence?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        timing: EventTiming,
        subjectID: UUID? = nil,
        location: String = "",
        notes: String = "",
        alert: AlertOffset? = nil,
        recurrence: RecurrenceRule? = nil,
        excludedDates: Set<CalendarDate> = [],
        detachedFrom: SeriesOccurrence? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.timing = timing.roundedToSeconds
        self.subjectID = subjectID
        self.location = location
        self.notes = notes
        self.alert = alert
        self.recurrence = recurrence
        self.excludedDates = excludedDates
        self.detachedFrom = detachedFrom
        self.createdAt = createdAt.roundedToSecond
        self.modifiedAt = (modifiedAt ?? createdAt).roundedToSecond
    }

    public var isAllDay: Bool {
        if case .allDay = timing { return true }
        return false
    }

    public var repeats: Bool { recurrence != nil }
}

extension Event {
    private enum CodingKeys: String, CodingKey {
        case id, title, timing, subjectID, location, notes, alert, recurrence, excludedDates, detachedFrom
        case createdAt, modifiedAt
    }

    /// Fields other than `id`, `title` and `timing` are optional in the file, so older or hand-edited
    /// files still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            timing: try container.decode(EventTiming.self, forKey: .timing),
            subjectID: try container.decodeIfPresent(UUID.self, forKey: .subjectID),
            location: try container.decodeIfPresent(String.self, forKey: .location) ?? "",
            notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? "",
            alert: try container.decodeIfPresent(AlertOffset.self, forKey: .alert),
            recurrence: try container.decodeIfPresent(RecurrenceRule.self, forKey: .recurrence),
            excludedDates: try container.decodeIfPresent(Set<CalendarDate>.self, forKey: .excludedDates) ?? [],
            detachedFrom: try container.decodeIfPresent(SeriesOccurrence.self, forKey: .detachedFrom),
            createdAt: createdAt,
            modifiedAt: try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt)
    }

    /// Writes optional fields only when set, and excluded dates in order, so the file diffs cleanly.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(timing, forKey: .timing)
        try container.encodeIfPresent(subjectID, forKey: .subjectID)
        if !location.isEmpty { try container.encode(location, forKey: .location) }
        if !notes.isEmpty { try container.encode(notes, forKey: .notes) }
        try container.encodeIfPresent(alert, forKey: .alert)
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
        if !excludedDates.isEmpty { try container.encode(excludedDates.sorted(), forKey: .excludedDates) }
        try container.encodeIfPresent(detachedFrom, forKey: .detachedFrom)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}

/// When an event happens.
public enum EventTiming: Hashable, Sendable {
    /// An absolute start and end, plus the time zone the event belongs to. Recurrence and the
    /// `HH.mm` folder name use that zone, so a weekly 14:00 lecture stays at 14:00 across DST changes.
    case timed(start: Date, end: Date, timeZone: TimeZone)
    /// Whole days, `end` inclusive (a one-day event has `start == end`). Plain dates, so they never
    /// shift when traveling.
    case allDay(start: CalendarDate, end: CalendarDate)

    /// The event's own time zone, or nil for all-day events (which have none).
    public var timeZone: TimeZone? {
        switch self {
        case .timed(_, _, let timeZone): return timeZone
        case .allDay: return nil
        }
    }

    /// The same timing with its instants rounded to whole seconds, the precision events.json keeps.
    public var roundedToSeconds: EventTiming {
        switch self {
        case .timed(let start, let end, let timeZone):
            return .timed(start: start.roundedToSecond, end: end.roundedToSecond, timeZone: timeZone)
        case .allDay:
            return self
        }
    }

    /// The first day of the event: in its own time zone for timed events.
    public var startDate: CalendarDate {
        switch self {
        case .timed(let start, _, let timeZone): return CalendarDate(start, in: timeZone)
        case .allDay(let start, _): return start
        }
    }
}

extension EventTiming: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, start, end, timeZone, startDate, endDate
    }

    private enum Kind: String, Codable {
        case timed, allDay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .timed:
            let identifier = try container.decode(String.self, forKey: .timeZone)
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timeZone, in: container, debugDescription: "Unknown time zone \"\(identifier)\"")
            }
            self = .timed(
                start: try container.decode(Date.self, forKey: .start),
                end: try container.decode(Date.self, forKey: .end),
                timeZone: timeZone)
        case .allDay:
            self = .allDay(
                start: try container.decode(CalendarDate.self, forKey: .startDate),
                end: try container.decode(CalendarDate.self, forKey: .endDate))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timed(let start, let end, let timeZone):
            try container.encode(Kind.timed, forKey: .kind)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(timeZone.identifier, forKey: .timeZone)
        case .allDay(let start, let end):
            try container.encode(Kind.allDay, forKey: .kind)
            try container.encode(start, forKey: .startDate)
            try container.encode(end, forKey: .endDate)
        }
    }
}

/// How long before an event its notification fires. Stored in events.json as a number of minutes.
public struct AlertOffset: Hashable, Comparable, Sendable {
    /// 0 means "at time of event".
    public var minutesBefore: Int

    public init(minutesBefore: Int) {
        self.minutesBefore = max(0, minutesBefore)
    }

    public static let atStart = AlertOffset(minutesBefore: 0)
    public static let tenMinutes = AlertOffset(minutesBefore: 10)
    public static let oneHour = AlertOffset(minutesBefore: 60)
    public static let oneDay = AlertOffset(minutesBefore: 24 * 60)

    /// The choices in the design's Alert menu, in order (plus "None", which is `nil`).
    public static let presets: [AlertOffset] = [.atStart, .tenMinutes, .oneHour, .oneDay]

    public static func < (lhs: AlertOffset, rhs: AlertOffset) -> Bool {
        lhs.minutesBefore < rhs.minutesBefore
    }
}

extension AlertOffset: Codable {
    public init(from decoder: Decoder) throws {
        self.init(minutesBefore: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(minutesBefore)
    }
}

/// How an event repeats.
///
/// Monthly events repeat on the same day number and skip months that don't have it (an event on the
/// 31st happens only in 31-day months), like Calendar.app and RFC 5545.
public struct RecurrenceRule: Hashable, Codable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily
        case weekly
        case monthly
    }

    public var frequency: Frequency
    /// The last day (in the event's own time zone) an occurrence may start on. nil repeats forever.
    public var until: CalendarDate?

    public init(frequency: Frequency, until: CalendarDate? = nil) {
        self.frequency = frequency
        self.until = until
    }
}

/// Identifies one occurrence of a repeating event by its original day.
public struct SeriesOccurrence: Hashable, Codable, Sendable {
    public var seriesID: UUID
    public var date: CalendarDate

    public init(seriesID: UUID, date: CalendarDate) {
        self.seriesID = seriesID
        self.date = date
    }
}
