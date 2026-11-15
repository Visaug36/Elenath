import ElenathCore
import Foundation
import Testing

@Suite("Chat export")
struct ChatExportTests {
    static let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static let iPhone = """
        \u{FEFF}[10/11/2026, 14:30:05] Messages and calls are end-to-end encrypted. Only people in this chat can read them.
        [10/11/2026, 14:30:05] Sam: Idea: a note app that files things for me
        [10/11/2026, 14:31:40] Sam: It should work offline
        and keep plain files
        [10/11/2026, 14:33:00] Sam: \u{200E}<attached: 00000012-PHOTO-2026-11-10-14-33-00.jpg>
        [13/11/2026, 09:05:10] Sam: Buy bandages for the course
        [13/11/2026, 09:05:30] Sam: \u{200E}image omitted
        [13/11/2026, 21:00:00] Sam: https://example.com/article
        """

    @Test("An iPhone export: brackets, seconds, continuation lines and attachments")
    func iPhone() {
        #expect(ChatExport.isChatExport(Self.iPhone))
        let messages = ChatExport.messages(from: Self.iPhone, timeZone: Self.utc)
        #expect(
            messages.map(\.text) == [
                "Idea: a note app that files things for me", "It should work offline\nand keep plain files", "",
                "Buy bandages for the course", "https://example.com/article",
            ])
        #expect(messages.map(\.sender).allSatisfy { $0 == "Sam" })
        #expect(messages[0].sent == date(2026, 11, 10, 14, 30, 5))
        #expect(messages[2].attachmentNames == ["00000012-PHOTO-2026-11-10-14-33-00.jpg"])
        #expect(messages[3].sent == date(2026, 11, 13, 9, 5, 10))
    }

    @Test("An Android export: a dash, twelve-hour times, the month first")
    func android() {
        let text = """
            11/10/26, 2:30 PM - Messages and calls are end-to-end encrypted. Tap to learn more.
            11/10/26, 2:30 PM - Sam: First thought
            11/10/26, 2:31 PM - Sam: IMG-20261110-WA0001.jpg (file attached)
            with a caption
            11/13/26, 12:05 AM - Sam: Just after midnight
            11/13/26, 12:10 PM - Sam: <Media omitted>
            """
        #expect(ChatExport.isChatExport(text))
        let messages = ChatExport.messages(from: text, timeZone: Self.utc)
        #expect(messages.map(\.text) == ["First thought", "with a caption", "Just after midnight"])
        // The 13 can only be a day, so the month comes first throughout.
        #expect(messages[0].sent == date(2026, 11, 10, 14, 30))
        #expect(messages[1].attachmentNames == ["IMG-20261110-WA0001.jpg"])
        #expect(messages[2].sent == date(2026, 11, 13, 0, 5))
    }

    @Test(
        "Dates as different regions write them",
        arguments: [
            ("[10.11.26, 14:30:05] Sam: a\n[11.11.26, 08:00:00] Sam: b", 10, 11),
            ("10/11/2026, 14:30 - Sam: a\n11/11/2026, 08:00 - Sam: b", 10, 11),
            ("[2026-11-10, 14:30:05] Sam: a\n[2026-11-11, 08:00:00] Sam: b", 10, 11),
            ("[10/11/2026, 2:30:05\u{202F}PM] Sam: a\n[11/11/2026, 8:00:00\u{202F}AM] Sam: b", 10, 11),
            ("11/10/26, 2:30 p.m. - Sam: a\n11/25/26, 8:00 a.m. - Sam: b", 10, 11),
            ("10-11-2026 14:30 - Sam: a\n25-11-2026 08:00 - Sam: b", 10, 11),
        ])
    func dateForms(text: String, day: Int, month: Int) {
        let messages = ChatExport.messages(from: text, timeZone: Self.utc)
        #expect(messages.count == 2)
        #expect(messages.first?.sent == date(2026, month, day, 14, 30, text.contains(":05") ? 5 : 0))
    }

    @Test("Ordinary text is not a chat")
    func notAChat() {
        #expect(!ChatExport.isChatExport("# Notes\n\nSome text\n"))
        #expect(!ChatExport.isChatExport("10/11/2026 was a good day\n[1] a footnote\n"))
        #expect(!ChatExport.isChatExport("[10/11/2026, 14:30:05] Sam: only one line\n"))
        #expect(!ChatExport.isChatExport(""))
        #expect(ChatExport.messages(from: "No messages here", timeZone: Self.utc).isEmpty)
    }

    @Test("Messages sent close together are one note")
    func grouping() {
        let messages = ChatExport.messages(from: Self.iPhone, timeZone: Self.utc)
        let notes = ChatExport.notes(from: messages, gap: 5 * 60)
        #expect(notes.map(\.count) == [3, 1, 1])
        #expect(notes[0].map(\.text).first == "Idea: a note app that files things for me")
        // A smaller gap splits the first thought.
        #expect(ChatExport.notes(from: messages, gap: 90).map(\.count) == [1, 2, 1, 1])
        #expect(ChatExport.notes(from: messages, gap: 60).map(\.count) == [1, 1, 1, 1, 1])
        #expect(ChatExport.notes(from: [], gap: 60).isEmpty)
    }
}
