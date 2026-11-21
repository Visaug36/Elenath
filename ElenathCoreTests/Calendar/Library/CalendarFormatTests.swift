import ElenathCore
import Foundation
import Testing

/// The calendar's events.json is Ithil 1.0.0's format, unchanged (Ithil's `LibraryCodecTests`, ported).
struct CalendarFormatTests {
    @Test func currentSchemaIsVersionOne() {
        #expect(CalendarDocument.currentSchemaVersion == 1)
        #expect(CalendarDocument.migrator.currentVersion == 1)
    }

    @Test func roundTripKeepsEveryField() throws {
        let calendar = CalendarFixtures.sampleCalendar()
        let data = try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start)
        let decoded = try DocumentCodec.decode(CalendarDocument.self, from: data)
        #expect(decoded.document == calendar)
        #expect(decoded.savedAt == CalendarFixtures.start)
        #expect(decoded.schemaVersion == 1)
    }

    @Test func emptyCalendarRoundTrips() throws {
        let calendar = CalendarDocument()
        let data = try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start)
        #expect(try DocumentCodec.decode(CalendarDocument.self, from: data).document == calendar)
    }

    @Test func fiveThousandEventsRoundTrip() throws {
        let zone = CalendarFixtures.timeZone("America/New_York")
        var events: [Event] = []
        for index in 0..<5000 {
            let start = CalendarFixtures.start.addingTimeInterval(Double(index) * 60 * 60)
            let timing = EventTiming.timed(start: start, end: start.addingTimeInterval(45 * 60), timeZone: zone)
            events.append(Event(title: "Event \(index)", timing: timing, createdAt: CalendarFixtures.start))
        }
        let calendar = CalendarDocument(events: events)
        let data = try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start)
        #expect(try DocumentCodec.decode(CalendarDocument.self, from: data).document == calendar)
    }

    /// Larger than a settings file may be, and still read: a calendar grows with the years.
    @Test func aCalendarLargerThanASettingsFileIsRead() throws {
        let zone = CalendarFixtures.timeZone("Europe/Amsterdam")
        let notes = String(repeating: "Bring the lab book and the safety glasses. ", count: 10)
        var events: [Event] = []
        for index in 0..<20_000 {
            let start = CalendarFixtures.start.addingTimeInterval(Double(index) * 60 * 60)
            let timing = EventTiming.timed(start: start, end: start.addingTimeInterval(45 * 60), timeZone: zone)
            events.append(
                Event(title: "Event \(index)", timing: timing, notes: notes, createdAt: CalendarFixtures.start))
        }
        let calendar = CalendarDocument(events: events)
        let data = try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start)
        #expect(data.count > DocumentCodec.maximumByteCount)
        #expect(try DocumentCodec.decode(CalendarDocument.self, from: data).document.events.count == 20_000)
    }

    @Test func savedAtIsRoundedToWholeSeconds() throws {
        let data = try DocumentCodec.encode(CalendarDocument(), savedAt: CalendarFixtures.start.addingTimeInterval(0.6))
        let decoded = try DocumentCodec.decode(CalendarDocument.self, from: data)
        #expect(decoded.savedAt == CalendarFixtures.start.addingTimeInterval(1))
    }

    @Test func fileIsPrettyJSONWithSchemaVersionOne() throws {
        let calendar = CalendarFixtures.sampleCalendar()
        let data = try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let object = try #require(parsed as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["savedAt"] as? String == "2026-10-06T11:50:00Z")
        #expect(object["id"] as? String == calendar.id.uuidString)
        #expect((object["events"] as? [Any])?.count == 3)
        #expect((object["subjects"] as? [Any])?.count == 2)
        #expect(Set(object.keys) == ["events", "id", "savedAt", "schemaVersion", "subjects"])

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \""))
        #expect(text.contains("https://example.com/physics/week-6"))
        #expect(text.contains("Room B/204"))
        #expect(!text.contains("\\/"))
    }

    @Test func topLevelKeysAreSorted() throws {
        let calendar = CalendarDocument(subjects: [Subject(name: "Physics", color: .palette(.teal))])
        let text = String(decoding: try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start), as: UTF8.self)
        let keys = ["\"events\"", "\"id\"", "\"savedAt\"", "\"schemaVersion\"", "\"subjects\""]
        let positions = keys.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
    }

    /// A small calendar written byte for byte as Ithil 1.0.0 writes it (the same keys, order and layout).
    /// If this test fails, the `Calendar` folder would stop being a valid Ithil folder.
    @Test func bytesAreIthils() throws {
        let subjectID = UUID(uuidString: "4954484C-0000-4000-8000-000000000001")!
        let eventID = UUID(uuidString: "4954484C-0000-4000-8000-000000000002")!
        let calendarID = UUID(uuidString: "4954484C-0000-4000-8000-000000000003")!
        let created = CalendarFixtures.instant(year: 2026, month: 9, day: 1, hour: 8, minute: 0, zone: "UTC")
        let calendar = CalendarDocument(
            id: calendarID,
            subjects: [Subject(id: subjectID, name: "Physics", color: .palette(.teal), keywords: ["phys"])],
            events: [
                Event(
                    id: eventID, title: "Physics Lecture",
                    timing: .timed(
                        start: CalendarFixtures.lectureStart, end: CalendarFixtures.lectureEnd,
                        timeZone: CalendarFixtures.timeZone("Europe/Amsterdam")),
                    subjectID: subjectID, location: "Room B/204", alert: .tenMinutes,
                    recurrence: RecurrenceRule(frequency: .weekly), createdAt: created)
            ])
        let expected = """
            {
              "events" : [
                {
                  "alert" : 10,
                  "createdAt" : "2026-09-01T08:00:00Z",
                  "id" : "4954484C-0000-4000-8000-000000000002",
                  "location" : "Room B/204",
                  "modifiedAt" : "2026-09-01T08:00:00Z",
                  "recurrence" : {
                    "frequency" : "weekly"
                  },
                  "subjectID" : "4954484C-0000-4000-8000-000000000001",
                  "timing" : {
                    "end" : "2026-10-06T13:30:00Z",
                    "kind" : "timed",
                    "start" : "2026-10-06T12:00:00Z",
                    "timeZone" : "Europe/Amsterdam"
                  },
                  "title" : "Physics Lecture"
                }
              ],
              "id" : "4954484C-0000-4000-8000-000000000003",
              "savedAt" : "2026-10-06T11:50:00Z",
              "schemaVersion" : 1,
              "subjects" : [
                {
                  "color" : "teal",
                  "id" : "4954484C-0000-4000-8000-000000000001",
                  "keywords" : [
                    "phys"
                  ],
                  "name" : "Physics"
                }
              ]
            }
            """
        let text = String(decoding: try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start), as: UTF8.self)
        #expect(text == expected)
    }

    @Test func timedEventsKeepTheirTimeZoneAndAllDayEventsTheirDates() throws {
        let calendar = CalendarFixtures.sampleCalendar()
        let data = try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start)
        let decoded = try DocumentCodec.decode(CalendarDocument.self, from: data).document
        let lecture = try #require(decoded.events.first)
        #expect(lecture.timing.timeZone?.identifier == "Europe/Amsterdam")
        let trip = try #require(decoded.events.dropFirst().first)
        let tripDays = EventTiming.allDay(
            start: CalendarDate(year: 2026, month: 10, day: 9), end: CalendarDate(year: 2026, month: 10, day: 11))
        #expect(trip.timing == tripDays)
    }

    @Test func newerSchemaIsRefused() {
        let data = Data(#"{"schemaVersion": 2, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"}"#.utf8)
        #expect(throws: DocumentStoreError.newerSchema(found: 2, supported: 1)) {
            _ = try DocumentCodec.decode(CalendarDocument.self, from: data)
        }
    }

    @Test func damagedFilesAreUnreadable() {
        let samples = [
            "",
            "not json",
            "[]",
            "{\"schemaVersion\": 1, \"events\": [",
            #"{"id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"}"#,
            #"{"schemaVersion": "1", "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"}"#,
            #"{"schemaVersion": 0, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"}"#,
            #"{"schemaVersion": 1}"#,
            #"{"schemaVersion": 1, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11", "events": [{"id": 5}]}"#,
            #"{"schemaVersion": 1, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11", "events": "#
                + String(repeating: "[", count: 100) + String(repeating: "]", count: 100) + "}",
        ]
        for sample in samples {
            var caught: (any Error)?
            do {
                _ = try DocumentCodec.decode(CalendarDocument.self, from: Data(sample.utf8))
            } catch {
                caught = error
            }
            #expect(calendarErrorIsUnreadable(caught), "\(sample.prefix(80))")
        }
    }

    @Test func missingOptionalFieldsUseDefaults() throws {
        let timing = #"{"kind": "allDay", "startDate": "2026-10-09", "endDate": "2026-10-09"}"#
        let essay = #"{"id": "1B8B7C4E-3F2A-4D5E-8A9B-0C1D2E3F4A5B", "title": "Essay due", "timing": \#(timing)}"#
        let json = #"{"schemaVersion": 1, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11", "events": [\#(essay)]}"#
        let decoded = try DocumentCodec.decode(CalendarDocument.self, from: Data(json.utf8))
        #expect(decoded.savedAt == nil)
        #expect(decoded.document.subjects.isEmpty)
        let event = try #require(decoded.document.events.first)
        #expect(event.title == "Essay due")
        #expect(event.notes.isEmpty)
        #expect(event.alert == nil)
    }

    @Test func injectedMigrationsRunInOrderBeforeDecoding() throws {
        let calendar = CalendarFixtures.sampleCalendar()
        let current = try DocumentCodec.encode(calendar, savedAt: CalendarFixtures.start)
        var object = try #require(try JSONSerialization.jsonObject(with: current, options: []) as? [String: Any])
        // An imaginary version 1 called the events "items"; version 2 called them "entries".
        object["items"] = object.removeValue(forKey: "events")
        object["schemaVersion"] = 1
        let old = try JSONSerialization.data(withJSONObject: object, options: [])

        let toVersion2: SchemaMigrator.Step = { json in
            json["entries"] = json.removeValue(forKey: "items")
        }
        let toVersion3: SchemaMigrator.Step = { json in
            json["events"] = json.removeValue(forKey: "entries")
        }
        let migrator = SchemaMigrator(currentVersion: 3, steps: [1: toVersion2, 2: toVersion3])
        let decoded = try DocumentCodec.decode(CalendarDocument.self, from: old, migrator: migrator)
        #expect(decoded.document == calendar)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.savedAt == CalendarFixtures.start)
    }

    @Test func injectedMigratorRefusesNewerFiles() {
        let data = Data(#"{"schemaVersion": 4, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"}"#.utf8)
        let migrator = SchemaMigrator(currentVersion: 3, steps: [:])
        #expect(throws: DocumentStoreError.newerSchema(found: 4, supported: 3)) {
            _ = try DocumentCodec.decode(CalendarDocument.self, from: data, migrator: migrator)
        }
    }

    @Test func failingMigrationIsUnreadable() {
        let data = Data(#"{"schemaVersion": 1, "id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"}"#.utf8)
        let failing: SchemaMigrator.Step = { _ in
            throw CocoaError(.featureUnsupported)
        }
        let migrator = SchemaMigrator(currentVersion: 2, steps: [1: failing])
        var caught: (any Error)?
        do {
            _ = try DocumentCodec.decode(CalendarDocument.self, from: data, migrator: migrator)
        } catch {
            caught = error
        }
        #expect(calendarErrorIsUnreadable(caught))
    }

    /// Ithil's event folder marker, read and written the same way.
    @Test func markersAreIthils() throws {
        let occurrence = CalendarFixtures.firstOccurrence(of: CalendarFixtures.sampleCalendar().events[0])
        let marker = try JSONDecoder().decode(
            EventFolderMarker.self, from: Data(CalendarFixtures.markerJSON(for: occurrence).utf8))
        #expect(marker.eventID == occurrence.event.id)
        #expect(marker.date == occurrence.date)
        #expect(marker.version == 1)
    }
}

/// `SchemaMigrator`, which brings events.json and Elenath's own files up to date (Ithil's tests, ported).
struct SchemaMigratorTests {
    private let migrator = SchemaMigrator(
        currentVersion: 3, steps: [1: SchemaMigratorTests.log("1to2"), 2: SchemaMigratorTests.log("2to3")])

    /// A step that appends `entry` to the object's "log" array, to record which steps ran in which order.
    private static func log(_ entry: String) -> SchemaMigrator.Step {
        return { json in
            var entries = json["log"] as? [String] ?? []
            entries.append(entry)
            json["log"] = entries
        }
    }

    @Test func stepsRunInOrderFromTheObjectsVersion() throws {
        var object: [String: Any] = ["schemaVersion": 1]
        let started = try migrator.migrate(&object)
        #expect(started == 1)
        #expect(object["schemaVersion"] as? Int == 3)
        #expect(object["log"] as? [String] == ["1to2", "2to3"])
    }

    @Test func onlyTheMissingStepsRun() throws {
        var object: [String: Any] = ["schemaVersion": 2]
        let started = try migrator.migrate(&object)
        #expect(started == 2)
        #expect(object["log"] as? [String] == ["2to3"])
    }

    @Test func currentObjectsAreLeftAlone() throws {
        var object: [String: Any] = ["schemaVersion": 3, "keep": "me"]
        let started = try migrator.migrate(&object)
        #expect(started == 3)
        #expect(!object.keys.contains("log"))
        #expect(object["keep"] as? String == "me")
    }

    @Test func newerObjectsAreRefused() {
        var object: [String: Any] = ["schemaVersion": 4]
        #expect(throws: DocumentStoreError.newerSchema(found: 4, supported: 3)) {
            try migrator.migrate(&object)
        }
    }

    @Test func missingStepIsUnreadable() {
        let gappy = SchemaMigrator(currentVersion: 3, steps: [2: SchemaMigratorTests.log("2to3")])
        var object: [String: Any] = ["schemaVersion": 1]
        var caught: (any Error)?
        do {
            try gappy.migrate(&object)
        } catch {
            caught = error
        }
        #expect(calendarErrorIsUnreadable(caught))
    }

    @Test func missingVersionIsUnreadable() {
        var object: [String: Any] = ["id": "8C0F3E0A-7B6B-4F43-9C5E-2D2B9D1C7A11"]
        var caught: (any Error)?
        do {
            try migrator.migrate(&object)
        } catch {
            caught = error
        }
        #expect(calendarErrorIsUnreadable(caught))
    }
}
