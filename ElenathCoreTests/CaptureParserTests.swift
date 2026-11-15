import ElenathCore
import Foundation
import Testing

@Suite("Capture")
struct CaptureParserTests {
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let now = Date(timeIntervalSince1970: 1_794_321_000)  // 2026-11-10 14:30 UTC
    let uni = Space(name: "Uni", keywords: ["lecture", "exam"])
    let redCross = Space(name: "Red Cross", isSealed: true, keywords: ["first aid", "rc"])
    let ideas = Space(name: "Ideas", keywords: ["idea", "rc car"])

    private func parse(_ text: String) -> CaptureDraft? {
        CaptureParser(spaces: [uni, redCross, ideas]).parse(text, now: Self.now, timeZone: Self.utc)
    }

    @Test("Plain text goes to the Inbox, titled by its first line")
    func inbox() {
        #expect(
            parse("Ask about the exam date")
                == CaptureDraft(destination: .inbox, title: "Ask about the exam date", body: ""))
        let draft = parse("  Shopping\n- milk\n- bread\n")
        #expect(draft?.destination == .inbox)
        #expect(draft?.title == "Shopping")
        #expect(draft?.body == "Shopping\n- milk\n- bread")
        #expect(parse("   \n ") == nil)
    }

    @Test("A title that had to be changed keeps the full text in the body")
    func changedTitle() {
        let long = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        #expect(parse(long)?.title.count == 59)
        #expect(parse(long)?.body == long)
        #expect(parse("Meet 3/4 at 10:30")?.title == "Meet 3-4 at 10-30")
        #expect(parse("Meet 3/4 at 10:30")?.body == "Meet 3/4 at 10:30")
        #expect(parse("\n\n")?.title == nil)
    }

    @Test("A space's name or keyword and a colon files it there directly")
    func prefixes() {
        #expect(
            parse("uni: ask about the exam")
                == CaptureDraft(destination: .space(uni.id, matched: "Uni"), title: "ask about the exam", body: ""))
        #expect(parse("LECTURE:   Bring the lab coat")?.destination == .space(uni.id, matched: "lecture"))
        #expect(parse("Red Cross: shift swap on Friday")?.destination == .space(redCross.id, matched: "Red Cross"))
        #expect(parse("first aid: recovery position\nsteps")?.body == "recovery position\nsteps")
        // The longest that fits wins: "rc car" is Ideas, "rc" is the Red Cross.
        #expect(parse("rc car: brushless motor")?.destination == .space(ideas.id, matched: "rc car"))
        #expect(parse("rc: bandages")?.destination == .space(redCross.id, matched: "rc"))
    }

    @Test("What only looks like a prefix stays in the Inbox")
    func notPrefixes() {
        for text in [
            "uni:", "uni:no space", "https://example.com/a", "unit: of measurement", "note: uni: nested",
            "exam tomorrow: revise", ": nothing before",
        ] {
            #expect(parse(text)?.destination == .inbox, "\(text)")
        }
        #expect(parse("https://example.com/a")?.body == "https://example.com/a")
    }

    @Test("A capture without a usable first line is named by its time")
    func timeTitle() {
        #expect(parse("...")?.title == "Capture 2026-11-10 14.30")
        #expect(parse("...")?.body == "...")
    }
}
