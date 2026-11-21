import ElenathCore
import Foundation
import Testing

/// The calendar inside the library: `Calendar/.ithil/events.json`, with Ithil's backups and Elenath's
/// safety copy and recovery.
struct CalendarStoreTests {
    @Test func theFirstLoadMakesAnEmptyCalendarInTheLibrary() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let load = try await fixture.calendarStore().load()
        #expect(load.isNew)
        #expect(!load.startedOverLostFile)
        #expect(!load.isReadOnly)
        #expect(load.recovery == nil)
        #expect(load.document.events.isEmpty && load.document.subjects.isEmpty)

        let data = try Data(contentsOf: fixture.url("Calendar/.ithil/events.json"))
        #expect(try DocumentCodec.decode(CalendarDocument.self, from: data).document == load.document)
        // The calendar's folder is never a space.
        let snapshot = try await fixture.catalog.open()
        #expect(!snapshot.spaces.contains { $0.name == "Calendar" })
        #expect(snapshot.spaceNamedCalendar == nil)
    }

    @Test func savesAndLoadsWithIthilsBackups() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.calendarStore()
        _ = try await store.load()
        var calendar = CalendarFixtures.sampleCalendar()
        try await store.save(calendar)
        fixture.clock.advance(by: 2 * 60 * 60)
        calendar.events.removeLast()
        try await store.save(calendar)

        let backups = fixture.names(in: "Calendar/.ithil/backups")
        #expect(backups.count == 2)
        #expect(backups.allSatisfy { $0.hasPrefix("events-") && $0.hasSuffix(".json") })
        let again = try await fixture.calendarStore().load()
        #expect(again.document == calendar)
        #expect(!again.isNew)
    }

    @Test func theSafetyCopyLivesBesideTheSpaces() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let libraryID = LibraryID()
        let store = fixture.calendarStore(libraryID: libraryID)
        _ = try await store.load()
        let calendar = CalendarFixtures.sampleCalendar()
        try await store.save(calendar)
        let copy = fixture.safety.appending(path: "\(libraryID.rawValue.uuidString)/\(calendar.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func aDamagedFileComesBackFromABackupAndIsSetAside() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.calendarStore()
        _ = try await store.load()
        let calendar = CalendarFixtures.sampleCalendar()
        try await store.save(calendar)
        fixture.clock.advance(by: 2 * 60 * 60)
        try await store.save(CalendarDocument(id: calendar.id))  // The current file is backed up first.
        try fixture.write("{ damaged", to: "Calendar/.ithil/events.json")

        // Another library id: no safety copy to find, so the newest backup is used.
        let load = try await fixture.calendarStore(libraryID: LibraryID()).load()
        guard case .backup = load.recovery?.source else {
            Issue.record("Expected a recovery from a backup")
            return
        }
        #expect(load.document == calendar)
        #expect(fixture.names(in: "Calendar/.ithil").contains { $0.hasPrefix("events.corrupt-") })
    }

    @Test func theSafetyCopyBringsBackALostCalendarFolder() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let libraryID = LibraryID()
        let store = fixture.calendarStore(libraryID: libraryID)
        _ = try await store.load()
        let calendar = CalendarFixtures.sampleCalendar()
        try await store.save(calendar)
        try FileManager.default.removeItem(at: fixture.url("Calendar"))

        let load = try await fixture.calendarStore(knownCalendarID: calendar.id, libraryID: libraryID).load()
        guard case .safetyCopy = load.recovery?.source else {
            Issue.record("Expected a recovery from the safety copy")
            return
        }
        #expect(load.document == calendar)
        #expect(fixture.exists("Calendar/.ithil/events.json"))
    }

    /// With nothing to bring events.json back from, an empty calendar starts, the app is told, and the
    /// event folders stay as they are.
    @Test func aLostFileWithNothingToRecoverStartsEmptyAndSaysSo() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.calendarStore().load()
        try fixture.write("Notes for the lab", to: "Calendar/2026-11-16/14.00 Lab/Handout.txt")
        try FileManager.default.removeItem(at: fixture.url("Calendar/.ithil"))

        let load = try await fixture.calendarStore(libraryID: LibraryID()).load()
        #expect(load.isNew)
        #expect(load.startedOverLostFile)
        #expect(try fixture.read("Calendar/2026-11-16/14.00 Lab/Handout.txt") == "Notes for the lab")
    }

    @Test func aCalendarFromANewerVersionIsShownAndNeverWritten() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let calendar = CalendarFixtures.sampleCalendar()
        var object = try #require(
            try JSONSerialization.jsonObject(with: DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start))
                as? [String: Any])
        object["schemaVersion"] = 2
        object["somethingNew"] = ["kept": true]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: fixture.url("Calendar/.ithil"), withIntermediateDirectories: true, attributes: nil)
        try bytes.write(to: fixture.url("Calendar/.ithil/events.json"))

        let store = fixture.calendarStore()
        let load = try await store.load()
        #expect(load.isReadOnly)
        #expect(load.document == calendar)
        await #expect(throws: DocumentStoreError.readOnly) {
            try await store.save(CalendarDocument())
        }
        #expect(try Data(contentsOf: fixture.url("Calendar/.ithil/events.json")) == bytes)
    }

    @Test func aReadOnlyLibraryGetsNoCalendarFolder() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.calendarStore()
        let load = try await store.load(readOnly: true)
        #expect(load.isReadOnly)
        #expect(load.document.events.isEmpty)
        #expect(!fixture.exists("Calendar"))
        await #expect(throws: DocumentStoreError.readOnly) {
            try await store.save(CalendarDocument())
        }
    }

    @Test func aReadOnlyLibraryReadsItsCalendarWithoutWriting() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.calendarStore()
        _ = try await store.load()
        let calendar = CalendarFixtures.sampleCalendar()
        try await store.save(calendar)
        let before = fixture.names(in: "Calendar/.ithil")
        let bytes = try Data(contentsOf: fixture.url("Calendar/.ithil/events.json"))

        let load = try await fixture.calendarStore().load(readOnly: true)
        #expect(load.isReadOnly)
        #expect(load.document == calendar)
        #expect(fixture.names(in: "Calendar/.ithil") == before)
        #expect(try Data(contentsOf: fixture.url("Calendar/.ithil/events.json")) == bytes)
    }

    /// Read-only, too, `.ithil` is never read through a link: it would show another folder's calendar.
    @Test func aReadOnlyLibraryNeverReadsThroughALinkedMetadataFolder() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let elsewhere = try fixture.folder.makeDirectory("Elsewhere")
        try DocumentCodec.encode(CalendarFixtures.sampleCalendar(), savedAt: CalendarFixtures.start).write(
            to: elsewhere.appending(component: "events.json"))
        try FileManager.default.createDirectory(
            at: fixture.url("Calendar"), withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createSymbolicLink(at: fixture.url("Calendar/.ithil"), withDestinationURL: elsewhere)
        await #expect(throws: CalendarStoreError.notAFolder) {
            _ = try await fixture.calendarStore().load(readOnly: true)
        }
    }

    /// Elenath 0.1 let a space be called "Calendar". It stays a space, untouched, until it is renamed.
    @Test func aSpaceCalledCalendarFromAnOlderVersionStaysASpace() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let old = SpaceDocument(sealed: false, description: "My timetable notes")
        try fixture.write(
            String(decoding: try DocumentCodec.encode(old, savedAt: LibraryFixture.start), as: UTF8.self),
            to: "Calendar/.space/space.json")
        try fixture.write("Week 1: Physics\n", to: "Calendar/Timetable.md")

        let snapshot = try await fixture.catalog.open()
        let space = try #require(snapshot.spaces.first { $0.name == "Calendar" })
        #expect(space.id == old.id)
        #expect(snapshot.spaceNamedCalendar == old.id)

        await #expect(throws: CalendarStoreError.nameTakenBySpace) {
            _ = try await fixture.calendarStore().load()
        }
        #expect(!fixture.exists("Calendar/.ithil"))

        // Renamed, the space keeps its notes and the calendar gets its folder.
        let renamed = try await fixture.catalog.renameSpace(old.id, to: "Timetable")
        #expect(renamed.name == "Timetable")
        let load = try await fixture.calendarStore().load()
        #expect(load.isNew)
        #expect(try fixture.read("Timetable/Timetable.md") == "Week 1: Physics\n")
        let reopened = try await fixture.catalog.open()
        #expect(reopened.spaceNamedCalendar == nil)
        #expect(reopened.spaces.map(\.name).sorted() == ["Timetable"])
    }

    @Test func aLinkOrAFileCalledCalendarIsNeverUsed() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        let elsewhere = try fixture.folder.makeDirectory("Elsewhere")
        try FileManager.default.createSymbolicLink(at: fixture.url("Calendar"), withDestinationURL: elsewhere)
        await #expect(throws: CalendarStoreError.notAFolder) {
            _ = try await fixture.calendarStore().load()
        }
        #expect(TestFiles.names(in: elsewhere).isEmpty)

        try FileManager.default.removeItem(at: fixture.url("Calendar"))
        try fixture.write("not a folder", to: "Calendar")
        await #expect(throws: CalendarStoreError.notAFolder) {
            _ = try await fixture.calendarStore().load()
        }
        #expect(try fixture.read("Calendar") == "not a folder")
    }

    @Test func aMissingLibraryIsNeverRecreated() async throws {
        let fixture = try await LibraryFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root)
        await #expect(throws: DocumentStoreError.missing) {
            _ = try await fixture.calendarStore().load()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }
}
