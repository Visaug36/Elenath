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

    // MARK: - Found in the review for 0.2.0

    /// `calendar` or its `homes` that isn't an object at all may have named a sealed space for any subject:
    /// every subject's home is unreadable, and the value is written back as it was found until the app
    /// settles it.
    @Test func damagedSettingsFailClosedAndAreKeptAsFound() {
        let values: [JSONValue] = [.array([.string("x")]), .string("Red Cross"), .number(1), .null]
        var stored: [[String: JSONValue]] = values.map { ["calendar": .object(["homes": $0])] }
        stored += values.dropLast().map { ["calendar": $0] }
        for damaged in stored {
            let settings = CalendarSettings(from: damaged)
            #expect(settings.isDamaged, "\(damaged)")
            #expect(settings.entry(forSubject: physics) == .unreadable, "\(damaged)")
            #expect(settings.entry(forSubject: nil) == SubjectHomeEntry.none)
            var written: [String: JSONValue] = [:]
            settings.written(into: &written)
            #expect(written == damaged, "\(damaged)")
        }
    }

    /// Settling damage gives each of the calendar's subjects an entry that can't be read (its events stay
    /// sealed until it gets a home) and keeps what was found; a subject made later has no home, as usual.
    @Test func settledDamageKeepsEachSubjectSealedUntilItHasAHome() {
        let found: JSONValue = .array([.string("x")])
        var settings = CalendarSettings(from: [
            "calendar": .object(["id": .string(physics.uuidString), "homes": found])
        ])
        let settled = settings.settleDamage(subjects: [physics, shifts])
        #expect(settled && !settings.isDamaged)
        let settledAgain = settings.settleDamage(subjects: [physics])
        #expect(!settledAgain)
        #expect(settings.calendarID == physics)
        #expect(settings.entry(forSubject: physics) == .unreadable)
        #expect(settings.entry(forSubject: shifts) == .unreadable)
        #expect(settings.entry(forSubject: UUID()) == SubjectHomeEntry.none)

        var written: [String: JSONValue] = [:]
        settings.written(into: &written)
        let reread = CalendarSettings(from: written)
        #expect(reread.entry(forSubject: physics) == .unreadable)
        #expect(reread.entry(forSubject: shifts) == .unreadable)
        guard case .object(let calendar) = written["calendar"] else {
            Issue.record("No calendar settings were written")
            return
        }
        #expect(calendar["foundUnreadable"] == found)

        settings.setHome(SubjectHome(space: uni), forSubject: physics)
        #expect(settings.entry(forSubject: physics) == .home(SubjectHome(space: uni)))
    }

    /// Two entries for one subject (keys that differ only in letter case): which counts would depend on the
    /// order they are read in, so neither does.
    @Test func twoEntriesForOneSubjectAreUnreadable() {
        let sealed = SpaceID(UUID(uuidString: "5B1D0000-0000-4000-8000-000000000002")!)
        let stored: [String: JSONValue] = [
            "calendar": .object([
                "homes": .object([
                    shifts.uuidString: .object(["space": .string(sealed.rawValue.uuidString)]),
                    shifts.uuidString.lowercased(): .object(["space": .string(uni.rawValue.uuidString)]),
                ])
            ])
        ]
        let settings = CalendarSettings(from: stored)
        #expect(settings.entry(forSubject: shifts) == .unreadable)
        var written: [String: JSONValue] = [:]
        settings.written(into: &written)
        #expect(written == stored)
    }

    /// A subject's new home is backed up at once, as a space's seal is: a library recovered from a backup
    /// (on another Mac, without the safety copy) still keeps a sealed subject's events sealed.
    @Test func aNewHomeSurvivesRecoveryFromABackup() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let redCross = try await fixture.space("Red Cross", sealed: true)
        fixture.clock.advance(by: 20 * 60)
        var settings = await fixture.catalog.calendarSettings()
        settings.setHome(SubjectHome(space: redCross.id), forSubject: shifts)
        try await fixture.catalog.saveCalendarSettings(settings)

        try FileManager.default.removeItem(at: fixture.url(".elenath/library.json"))
        try? FileManager.default.removeItem(at: fixture.safety)
        let catalog = LibraryCatalog(
            root: fixture.root, safetyDirectory: fixture.safety, fileSystem: fixture.fileSystem,
            timeSource: fixture.clock)
        let snapshot = try await catalog.open()
        #expect(snapshot.calendarSettings.entry(forSubject: shifts) == .home(SubjectHome(space: redCross.id)))
    }
}
