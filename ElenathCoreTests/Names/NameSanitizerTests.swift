import ElenathCore
import Foundation
import Testing

struct NameSanitizerTests {
    @Test func slashesAndColonsBecomeHyphens() {
        #expect(NameSanitizer.sanitizedTitle("Mechanics: forces/torque") == "Mechanics- forces-torque")
    }

    @Test func whitespaceAndControlCharactersCollapse() {
        #expect(NameSanitizer.sanitizedTitle("  Lecture\t7\n\nnotes  ") == "Lecture 7 notes")
        #expect(NameSanitizer.sanitizedTitle("a\u{0}b\u{2028}c") == "a b c")
    }

    @Test func nothingElenathNamesIsHidden() {
        #expect(NameSanitizer.sanitizedTitle(".hidden") == "hidden")
        #expect(NameSanitizer.sanitizedTitle(". . .draft") == "draft")
        #expect(NameSanitizer.sanitizedTitle("...") == "Untitled")
        #expect(NameSanitizer.sanitizedTitle("") == "Untitled")
        #expect(NameSanitizer.sanitizedTitle(" \n ") == "Untitled")
    }

    @Test func trailingDotsAndSpacesAreRemoved() {
        #expect(NameSanitizer.sanitizedTitle("To do... ") == "To do")
    }

    @Test func charactersOtherPlatformsForbidAreKept() {
        #expect(NameSanitizer.sanitizedTitle("What is entropy?") == "What is entropy?")
        #expect(NameSanitizer.sanitizedTitle("a*b \"c\" <d>e\\f") == "a*b \"c\" <d>e\\f")
    }

    @Test func charactersThatWouldBreakALinkBecomeHyphens() {
        // "[[C# notes]]" would read as the note "C" and its heading " notes".
        #expect(NameSanitizer.sanitizedTitle("C# notes") == "C- notes")
        #expect(NameSanitizer.sanitizedTitle("a|b [c] ^d") == "a-b -c- -d")
    }

    @Test func conflictTitlesOfLongNamesFitInAFileName() {
        let long = String(repeating: "a", count: 240)
        let title = NameSanitizer.conflictTitle(for: long, now: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        #expect(title.utf8.count <= 200)
        #expect(title.hasSuffix(" (conflict 1970-01-01 00.00)"))
    }

    @Test func longTitlesAreCutOnCharacterBoundaries() {
        let long = String(repeating: "a", count: 300)
        #expect(NameSanitizer.sanitizedTitle(long).count == 120)

        // 120 family emoji are far more than 200 bytes: the cut keeps whole Characters.
        let wide = String(repeating: "👨‍👩‍👧‍👦", count: 120)
        let cut = NameSanitizer.sanitizedTitle(wide)
        #expect(cut.utf8.count <= 200)
        #expect(!cut.isEmpty)
        #expect(wide.hasPrefix(cut))
        #expect(cut.count == cut.utf8.count / "👨‍👩‍👧‍👦".utf8.count)
    }

    @Test func aCutTitleIsTrimmedAgain() {
        let title = String(repeating: "a", count: 119) + " b"
        #expect(NameSanitizer.sanitizedTitle(title) == String(repeating: "a", count: 119))
    }

    @Test func rightToLeftAndCombiningTextSurvives() {
        #expect(NameSanitizer.sanitizedTitle("ملاحظات الفيزياء") == "ملاحظات الفيزياء")
        #expect(NameSanitizer.sanitizedTitle("Cafe\u{301}") == "Cafe\u{301}")
    }

    @Test func captureTitlesComeFromTheFirstLine() {
        let now = Date(timeIntervalSince1970: 1_794_321_000)  // 2026-11-10 14:30 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(
            NameSanitizer.captureTitle(firstLine: "Ask about the exam date", now: now, timeZone: utc)
                == "Ask about the exam date")
        let long = String(repeating: "word ", count: 40)
        #expect(NameSanitizer.captureTitle(firstLine: long, now: now, timeZone: utc).count <= 60)
        #expect(NameSanitizer.captureTitle(firstLine: nil, now: now, timeZone: utc) == "Capture 2026-11-10 14.30")
        #expect(NameSanitizer.captureTitle(firstLine: "  ", now: now, timeZone: utc) == "Capture 2026-11-10 14.30")
    }

    @Test func stampsUseTheGivenTimeZone() {
        let now = Date(timeIntervalSince1970: 1_794_321_000)  // 14:30 UTC is 23:30 in Tokyo
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(NameSanitizer.captureTitle(firstLine: nil, now: now, timeZone: tokyo) == "Capture 2026-11-10 23.30")
        #expect(
            NameSanitizer.conflictTitle(for: "Lecture 7", now: now, timeZone: tokyo)
                == "Lecture 7 (conflict 2026-11-10 23.30)")
    }

    @Test func namesCompareWithoutCaseOrNormalization() {
        #expect(NameSanitizer.key("Physics") == NameSanitizer.key("PHYSICS"))
        #expect(NameSanitizer.key("Caf\u{E9}") == NameSanitizer.key("Cafe\u{301}"))
        #expect(NameSanitizer.key("Physics") != NameSanitizer.key("Physics 2"))
    }

    @Test func reservedNames() {
        #expect(NameSanitizer.isReservedAtLibraryRoot(".elenath"))
        #expect(NameSanitizer.isReservedAtLibraryRoot("Inbox"))
        #expect(NameSanitizer.isReservedAtLibraryRoot("inbox"))
        #expect(NameSanitizer.isReservedAtLibraryRoot(".DS_Store"))
        #expect(!NameSanitizer.isReservedAtLibraryRoot("Uni"))
        #expect(!NameSanitizer.isReservedAtLibraryRoot("Inbox 2"))

        #expect(NameSanitizer.isReservedInSpace(".space"))
        #expect(NameSanitizer.isReservedInSpace("Attachments"))
        #expect(NameSanitizer.isReservedInSpace("attachments"))
        #expect(NameSanitizer.isReservedInSpace("Free body diagrams.board"))
        #expect(!NameSanitizer.isReservedInSpace("Physics"))
        #expect(!NameSanitizer.isReservedInSpace("Board games"))
    }
}
