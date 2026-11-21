import ElenathCore
import Foundation
import Testing

/// Quick Capture's event (⌥↩): sent where the text says, never unsealed by accident, and read from one short
/// line. Quick Add itself is stood in for, so these run where it can't find dates (Linux).
struct CaptureEventTests {
    private let redCross = Space(name: "Red Cross", isSealed: true)
    private let uni = Space(name: "Uni")
    private let shifts = Subject(name: "Shifts", color: .palette(.rose))
    private let firstAid = Subject(name: "First aid", color: .palette(.clay))
    private let physics = Subject(name: "Physics", color: .palette(.teal))

    private var spaces: [Space] { [uni, redCross] }

    private func settings(_ homes: [UUID: SpaceID]) -> CalendarSettings {
        var settings = CalendarSettings()
        for (subject, space) in homes {
            settings.setHome(SubjectHome(space: space), forSubject: subject)
        }
        return settings
    }

    /// Quick Add, stood in for: every line names a time, and "physics" picks Physics. Records what it read.
    private final class Reader: @unchecked Sendable {
        var lines: [String] = []
        let physics: UUID

        init(physics: UUID) {
            self.physics = physics
        }

        func parse(_ line: String) -> QuickAddDraft? {
            lines.append(line)
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            return QuickAddDraft(
                title: line, timing: .timed(start: start, end: start.addingTimeInterval(3600), timeZone: .gmt),
                subjectID: line.contains("physics") ? physics : nil, hasDate: true, hasTime: true)
        }
    }

    private func read(_ text: String, homes: [UUID: SpaceID], reader: Reader) -> CaptureEvent.Reading? {
        CaptureEvent.read(
            text, spaces: spaces, subjects: [physics, shifts, firstAid], settings: settings(homes),
            parse: reader.parse)
    }

    private func subject(of reading: CaptureEvent.Reading?) -> UUID? {
        guard case .event(let draft) = reading else { return nil }
        return draft.subjectID
    }

    @Test func aSpacesNameIsntPartOfTheEventAndItsSubjectLivesThere() throws {
        let reader = Reader(physics: physics.id)
        let reading = read("red cross: debrief sat 9pm", homes: [shifts.id: redCross.id], reader: reader)
        #expect(reader.lines == ["debrief sat 9pm"])
        guard case .event(let draft) = reading else {
            Issue.record("No event: \(String(describing: reading))")
            return
        }
        #expect(draft.subjectID == shifts.id)
    }

    @Test func quickAddsSubjectStaysWhenItLivesInThatSpace() throws {
        let reader = Reader(physics: physics.id)
        let reading = read(
            "uni: physics quiz thursday 10am", homes: [physics.id: uni.id, firstAid.id: uni.id], reader: reader)
        #expect(subject(of: reading) == physics.id)
    }

    /// A subject homed elsewhere isn't taken: the text named the sealed space.
    @Test func aSubjectFromAnotherSpaceGivesWayToOneThatLivesThere() throws {
        let reader = Reader(physics: physics.id)
        let reading = read(
            "red cross: physics refresher sat 9pm", homes: [physics.id: uni.id, firstAid.id: redCross.id],
            reader: reader)
        #expect(subject(of: reading) == firstAid.id)
    }

    /// Text for a sealed space where no subject lives gives no event: it would have no home and show
    /// everywhere, with any files dropped on it.
    @Test func aSealedSpaceWithoutASubjectGivesNoEvent() {
        let reader = Reader(physics: physics.id)
        #expect(
            read("red cross: debrief sat 9pm", homes: [physics.id: uni.id], reader: reader) == .noSubjectIn(redCross.id)
        )
        #expect(
            read("red cross: physics sat 9pm", homes: [physics.id: uni.id], reader: reader) == .noSubjectIn(redCross.id)
        )
    }

    /// A space that mixes keeps what Quick Add found, and so does the Inbox.
    @Test func otherwiseQuickAddsReadingStands() {
        let reader = Reader(physics: physics.id)
        let open = read("uni: physics quiz thursday", homes: [physics.id: redCross.id], reader: reader)
        #expect(subject(of: open) == physics.id)
        let inbox = read("physics quiz thursday", homes: [:], reader: reader)
        #expect(subject(of: inbox) == physics.id)
        #expect(reader.lines.last == "physics quiz thursday")
    }

    /// Only the first line is read, and only its first characters: a pasted page is never read at every
    /// keystroke.
    @Test func onlyAShortFirstLineIsRead() {
        let reader = Reader(physics: physics.id)
        _ = read(
            "quiz thursday 10am\n" + String(repeating: "chat log line\n", count: 80_000), homes: [:], reader: reader)
        #expect(reader.lines == ["quiz thursday 10am"])
        _ = read(String(repeating: "x", count: 1_000_000), homes: [:], reader: reader)
        #expect(reader.lines.last?.count == CaptureEvent.maximumLength)
        #expect(read("   \n\n", homes: [:], reader: reader) == nil)
    }
}
