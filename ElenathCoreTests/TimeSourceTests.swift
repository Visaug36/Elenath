import ElenathCore
import Foundation
import Testing

struct TimeSourceTests {
    @Test func fixedTimeSourceNeverMoves() {
        // Tuesday 10 November 2026, 14:30 UTC.
        let instant = Date(timeIntervalSince1970: 1_794_321_000)
        let source = FixedTimeSource(instant)
        #expect(source.now == instant)
        #expect(source.now == source.now)
    }

    @Test func systemTimeSourceFollowsTheClock() {
        let before = Date()
        let now = SystemTimeSource().now
        #expect(now >= before)
        #expect(now.timeIntervalSince(before) < 5)
    }
}
