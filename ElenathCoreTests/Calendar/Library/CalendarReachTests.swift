import ElenathCore
import Foundation
import Testing

/// The calendar's sealing exception: who may read an event's content, and what the calendar's own search
/// looks at.
struct CalendarReachTests {
    private struct World {
        let uni = Space(id: SpaceID(), name: "Uni")
        let ideas = Space(id: SpaceID(), name: "Ideas")
        let redCross = Space(id: SpaceID(), name: "Red Cross", isSealed: true)

        let physics = Subject(name: "Physics", color: .palette(.teal))
        let shifts = Subject(name: "Shifts", color: .palette(.rose))
        let homeless = Subject(name: "Gym", color: .palette(.fern))
        let gone = Subject(name: "Old course", color: .palette(.iris))
        let damaged = Subject(name: "Mystery", color: .palette(.clay))

        var spaces: [Space] { [uni, ideas, redCross] }

        var settings: CalendarSettings {
            var stored: [String: JSONValue] = [:]
            var settings = CalendarSettings()
            settings.setHome(SubjectHome(space: uni.id, folder: ItemPath("Physics")!), forSubject: physics.id)
            settings.setHome(SubjectHome(space: redCross.id), forSubject: shifts.id)
            settings.setHome(SubjectHome(space: SpaceID()), forSubject: gone.id)
            settings.written(into: &stored)
            guard case .object(var calendar) = stored["calendar"], case .object(var homes) = calendar["homes"] else {
                return settings
            }
            homes[damaged.id.uuidString] = .string("unreadable")
            calendar["homes"] = .object(homes)
            stored["calendar"] = .object(calendar)
            return CalendarSettings(from: stored)
        }

        func event(_ title: String, subject: Subject?, notes: String = "", location: String = "") -> Event {
            let start = CalendarFixtures.lectureStart
            return Event(
                title: title, timing: .timed(start: start, end: start.addingTimeInterval(3600), timeZone: .gmt),
                subjectID: subject?.id, location: location, notes: notes)
        }

        func reach(_ workplace: Workplace) -> CalendarReach {
            CalendarReach(workplace: workplace, spaces: spaces, settings: settings)
        }
    }

    @Test func contentIsReadWhereItsHomeIs() {
        let world = World()
        let lecture = world.event("Lecture", subject: world.physics)
        let shift = world.event("Shift", subject: world.shifts)
        let loose = world.event("Dentist", subject: nil)
        let homeless = world.event("Gym", subject: world.homeless)
        let gone = world.event("Old", subject: world.gone)
        let damaged = world.event("Mystery", subject: world.damaged)

        let table: [(Workplace, [Bool])] = [
            (.everywhere, [true, false, true, true, false, false]),
            (.space(world.uni.id), [true, false, true, true, false, false]),
            (.space(world.ideas.id), [true, false, true, true, false, false]),
            (.space(world.redCross.id), [false, true, false, false, false, false]),
            (.inbox, [false, false, false, false, false, false]),
            (.space(SpaceID()), [false, false, false, false, false, false]),
        ]
        for (workplace, expected) in table {
            let reach = world.reach(workplace)
            let found = [lecture, shift, loose, homeless, gone, damaged].map(reach.mayReadContent(of:))
            #expect(found == expected, "\(workplace)")
            for (event, readable) in zip([lecture, shift, loose, homeless, gone, damaged], expected) {
                #expect((reach.notes(of: event) != nil) == readable, "\(workplace) \(event.title)")
            }
        }
    }

    @Test func homesAreKnownOnlyWhenTheirSpaceIs() {
        let world = World()
        let reach = world.reach(.everywhere)
        #expect(reach.home(of: world.event("Lecture", subject: world.physics))?.folder == ItemPath("Physics"))
        #expect(reach.home(of: world.event("Shift", subject: world.shifts))?.space == world.redCross.id)
        #expect(reach.home(of: world.event("Dentist", subject: nil)) == nil)
        #expect(reach.home(of: world.event("Old", subject: world.gone)) == nil)
        #expect(reach.hasMissingHome(world.event("Old", subject: world.gone)))
        #expect(reach.hasMissingHome(world.event("Mystery", subject: world.damaged)))
        #expect(!reach.hasMissingHome(world.event("Dentist", subject: nil)))
        #expect(!reach.hasMissingHome(world.event("Gym", subject: world.homeless)))
    }

    /// The calendar's own search finds every event by title and location, and a sealed one never by its
    /// notes from outside.
    @Test func searchCrossesTheSealOnlyForTitleAndLocation() {
        let world = World()
        let shift = world.event(
            "Shift at the station", subject: world.shifts, notes: "Patient zebrafish bandages", location: "Harbour post"
        )
        let lecture = world.event("Lecture", subject: world.physics, notes: "Bring zebrafish slides")
        let calendar = CalendarDocument(subjects: [world.physics, world.shifts], events: [shift, lecture])
        let expander = OccurrenceExpander(displayTimeZone: .gmt)
        let now = CalendarFixtures.start

        let outside = world.reach(.everywhere)
        #expect(outside.search(calendar, query: "station", now: now, expander: expander).map(\.event.id) == [shift.id])
        #expect(outside.search(calendar, query: "harbour", now: now, expander: expander).map(\.event.id) == [shift.id])
        #expect(
            outside.search(calendar, query: "zebrafish", now: now, expander: expander).map(\.event.id) == [lecture.id])
        #expect(outside.search(calendar, query: "bandages", now: now, expander: expander).isEmpty)
        #expect(!outside.matches(shift, query: "bandages"))
        #expect(outside.matches(shift, query: "station"))

        let inside = world.reach(.space(world.redCross.id))
        #expect(inside.search(calendar, query: "bandages", now: now, expander: expander).map(\.event.id) == [shift.id])
        // From inside the sealed space, the Uni lecture shows by title, never by its notes.
        #expect(inside.search(calendar, query: "zebrafish", now: now, expander: expander).map(\.event.id) == [shift.id])
        #expect(inside.search(calendar, query: "lecture", now: now, expander: expander).map(\.event.id) == [lecture.id])
    }

    @Test func fileNamesAreReadOnlyWhereTheContentIs() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let world = World()
        let shift = world.event("Shift", subject: world.shifts)
        let occurrence = CalendarFixtures.firstOccurrence(of: shift)
        let folders = EventFolders(root: try folder.makeDirectory("Calendar"), fileSystem: LocalFileSystem())
        let eventFolder = try await folders.ensureFolder(for: occurrence)
        try Data("roster".utf8).write(to: eventFolder.appending(component: "Rota.pdf"))

        #expect(await world.reach(.everywhere).files(for: occurrence, in: folders) == nil)
        #expect(await folders.fileCount(for: occurrence) == 1)  // The count crosses the seal.
        let inside = await world.reach(.space(world.redCross.id)).files(for: occurrence, in: folders)
        #expect(inside?.map(\.name) == ["Rota.pdf"])
    }
}
