import ElenathCore
import Foundation
import Testing

/// Elenath's calendar settings in library.json: each subject's home, kept out of events.json.
struct CalendarSettingsTests {
    private let physics = UUID(uuidString: "8E2F0000-0000-4000-8000-000000000001")!
    private let shifts = UUID(uuidString: "8E2F0000-0000-4000-8000-000000000002")!
    private let uni = SpaceID(UUID(uuidString: "5B1D0000-0000-4000-8000-000000000001")!)

    @Test func homesRoundTripThroughLibrarySettings() {
        var settings = CalendarSettings(calendarID: physics)
        settings.setHome(SubjectHome(space: uni, folder: ItemPath("Physics/Lectures")!), forSubject: physics)
        settings.setHome(SubjectHome(space: uni), forSubject: shifts)
        var stored: [String: JSONValue] = ["appearance": .string("night")]
        settings.written(into: &stored)

        let read = CalendarSettings(from: stored)
        #expect(read == settings)
        #expect(read.calendarID == physics)
        #expect(
            read.entry(forSubject: physics) == .home(SubjectHome(space: uni, folder: ItemPath("Physics/Lectures")!)))
        #expect(read.entry(forSubject: shifts) == .home(SubjectHome(space: uni, folder: .root)))
        #expect(stored["appearance"] == .string("night"))
    }

    @Test func theStoredShapeIsTheDocumentedOne() {
        var settings = CalendarSettings()
        settings.setHome(SubjectHome(space: uni, folder: ItemPath("Physics")!), forSubject: physics)
        var stored: [String: JSONValue] = [:]
        settings.written(into: &stored)
        let expected: JSONValue = .object([
            "homes": .object([
                physics.uuidString: .object([
                    "space": .string(uni.rawValue.uuidString), "folder": .string("Physics"),
                ])
            ])
        ])
        #expect(stored["calendar"] == expected)
    }

    @Test func noSettingsWriteNothing() {
        var stored: [String: JSONValue] = ["appearance": .string("dawn")]
        CalendarSettings().written(into: &stored)
        #expect(stored == ["appearance": .string("dawn")])
    }

    @Test func anEventWithoutASubjectOrASubjectWithoutAnEntryHasNoHome() {
        let settings = CalendarSettings()
        #expect(settings.entry(forSubject: nil) == SubjectHomeEntry.none)
        #expect(settings.entry(forSubject: physics) == SubjectHomeEntry.none)
    }

    @Test func keysThisVersionDoesntKnowAreKept() {
        let stored: [String: JSONValue] = [
            "calendar": .object([
                "homes": .object([
                    physics.uuidString: .object([
                        "space": .string(uni.rawValue.uuidString), "folder": .string(""), "colorHint": .string("x"),
                    ]),
                    "not-a-subject": .string("kept"),
                ]),
                "weekStartsOn": .number(2),
            ])
        ]
        var settings = CalendarSettings(from: stored)
        settings.setHome(SubjectHome(space: uni), forSubject: shifts)
        var written = stored
        settings.written(into: &written)
        guard case .object(let calendar) = written["calendar"], case .object(let homes) = calendar["homes"] else {
            Issue.record("No calendar settings were written")
            return
        }
        #expect(calendar["weekStartsOn"] == .number(2))
        #expect(homes["not-a-subject"] == .string("kept"))
        #expect(homes.count == 3)
    }

    /// A damaged entry fails closed: it may have named a sealed space.
    @Test func anEntryThatCantBeReadIsUnreadableAndKept() {
        let damaged: [String: JSONValue] = [
            "calendar": .object([
                "homes": .object([
                    physics.uuidString: .object(["space": .string("not an id")]),
                    shifts.uuidString: .string("Red Cross"),
                ])
            ])
        ]
        var settings = CalendarSettings(from: damaged)
        #expect(settings.entry(forSubject: physics) == .unreadable)
        #expect(settings.entry(forSubject: shifts) == .unreadable)
        var written: [String: JSONValue] = [:]
        settings.written(into: &written)
        #expect(written == damaged)

        // Giving the subject a home replaces the damaged entry.
        settings.setHome(SubjectHome(space: uni), forSubject: physics)
        #expect(settings.entry(forSubject: physics) == .home(SubjectHome(space: uni)))
        settings.setHome(nil, forSubject: shifts)
        #expect(settings.entry(forSubject: shifts) == SubjectHomeEntry.none)
        written = [:]
        settings.written(into: &written)
        guard case .object(let calendar) = written["calendar"], case .object(let homes) = calendar["homes"] else {
            Issue.record("No calendar settings were written")
            return
        }
        #expect(homes.count == 1)
    }

    /// A folder that isn't a folder of notes reads as the top of the space; the space still counts.
    @Test func aHomeFolderOutsideTheNotesIsTheTopOfTheSpace() {
        for folder in ["../Elsewhere", "/Users", ".space", "Physics/Attachments", "Sketches.board", "a//b"] {
            let stored: [String: JSONValue] = [
                "calendar": .object([
                    "homes": .object([
                        physics.uuidString: .object([
                            "space": .string(uni.rawValue.uuidString), "folder": .string(folder),
                        ])
                    ])
                ])
            ]
            #expect(
                CalendarSettings(from: stored).entry(forSubject: physics) == .home(SubjectHome(space: uni)),
                "\(folder)")
        }
    }

    @Test func theCatalogKeepsTheLibrarysOtherSettings() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let library = LibraryDocument(id: LibraryID(), settings: ["appearance": .string("night")])
        try fixture.write(
            String(decoding: try DocumentCodec.encode(library, savedAt: LibraryFixture.start), as: UTF8.self),
            to: ".elenath/library.json")
        let snapshot = try await fixture.catalog.open()
        #expect(snapshot.calendarSettings == CalendarSettings())

        var settings = snapshot.calendarSettings
        settings.calendarID = physics
        settings.setHome(SubjectHome(space: uni), forSubject: physics)
        try await fixture.catalog.saveCalendarSettings(settings)

        let reopened = try await fixture.catalog.open()
        #expect(reopened.calendarSettings == settings)
        let data = try Data(contentsOf: fixture.url(".elenath/library.json"))
        let stored = try DocumentCodec.decode(LibraryDocument.self, from: data).document
        #expect(stored.settings["appearance"] == .string("night"))
    }
}
