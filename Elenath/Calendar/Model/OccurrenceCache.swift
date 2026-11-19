import ElenathCore
import Foundation

/// A small most-recently-used cache of occurrence queries, so going back and forth between weeks and
/// months doesn't expand thousands of events again.
///
/// Keys carry everything a result depends on (library revision, hidden subjects, display time zone and
/// the day range), so a stale entry can never be returned; `CalendarModel` also empties the cache whenever
/// one of those changes, to free the memory.
struct OccurrenceCache {
    struct Key: Hashable {
        var revision: Int
        var hiddenSubjectIDs: Set<UUID>
        var timeZone: TimeZone
        var first: CalendarDate
        var last: CalendarDate

        /// Whether `other` was computed from the same data, whatever its days.
        func matchesData(of other: Key) -> Bool {
            revision == other.revision && hiddenSubjectIDs == other.hiddenSubjectIDs && timeZone == other.timeZone
        }
    }

    private let capacity = 48
    private var entries: [Key: [Occurrence]] = [:]
    /// Least recently used first.
    private var recency: [Key] = []

    mutating func value(for key: Key) -> [Occurrence]? {
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    /// A cached range computed from the same data as `key` whose days include `day`, newest first.
    mutating func value(covering day: CalendarDate, like key: Key) -> [Occurrence]? {
        for candidate in recency.reversed() where candidate.matchesData(of: key) {
            if candidate.first <= day, day <= candidate.last, let value = entries[candidate] {
                touch(candidate)
                return value
            }
        }
        return nil
    }

    mutating func insert(_ value: [Occurrence], for key: Key) {
        entries[key] = value
        touch(key)
        while recency.count > capacity {
            let oldest = recency.removeFirst()
            entries[oldest] = nil
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        recency.removeAll()
    }

    private mutating func touch(_ key: Key) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}
