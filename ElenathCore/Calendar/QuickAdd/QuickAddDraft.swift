import Foundation

/// What Quick Add understood from one line of text: the live preview while the user types, and the
/// event it adds.
public struct QuickAddDraft: Hashable, Sendable {
    /// The text without the recognized date and time. May be empty: the app shows a localized
    /// placeholder.
    public var title: String
    public var timing: EventTiming
    /// The subject whose name or keyword appears in the text, or nil.
    public var subjectID: UUID?
    /// The subject's name or keyword as typed, for "Subject matched from “physics”".
    public var matchedKeyword: String?
    /// UTF-16 ranges in the input recognized as the date and time, for highlighting.
    public var highlightedRanges: [NSRange]
    public var alert: AlertOffset?
    /// Whether the text names a date. Without one the draft is an all-day event today.
    public var hasDate: Bool
    /// Whether the text names a time of day. Without one the draft is an all-day event.
    public var hasTime: Bool

    public init(
        title: String,
        timing: EventTiming,
        subjectID: UUID? = nil,
        matchedKeyword: String? = nil,
        highlightedRanges: [NSRange] = [],
        alert: AlertOffset? = nil,
        hasDate: Bool = false,
        hasTime: Bool = false
    ) {
        self.title = title
        self.timing = timing
        self.subjectID = subjectID
        self.matchedKeyword = matchedKeyword
        self.highlightedRanges = highlightedRanges
        self.alert = alert
        self.hasDate = hasDate
        self.hasTime = hasTime
    }
}
