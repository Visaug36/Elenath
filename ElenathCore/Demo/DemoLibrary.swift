import Foundation

/// An invented library for screenshots and for trying Elenath out: Uni, a sealed Red Cross space, Ideas,
/// and an Inbox with a few captures. Nothing in it comes from a real library.
///
/// Every id is fixed and every date is counted back from `now`, so equal arguments give equal libraries.
public enum DemoLibrary {
    /// Writes the library into `root`, which must be an empty folder, and returns it as opened.
    @discardableResult
    public static func write(
        to root: URL, safetyDirectory: URL, now: Date, timeZone: TimeZone, fileSystem: any FileSystem
    ) async throws -> LibrarySnapshot {
        let clock = FixedTimeSource(now)
        let catalog = LibraryCatalog(
            root: root, safetyDirectory: safetyDirectory, fileSystem: fileSystem, timeSource: clock)
        _ = try await catalog.create(id: LibraryID(uuid("E1E7A7E0-0000-4000-8000-000000000001")))
        let ids = Counter()
        let store = NoteStore(
            catalog: catalog, fileSystem: fileSystem, timeSource: clock, timeZone: { timeZone },
            makeID: { NoteID(uuid(String(format: "D0000000-0000-4000-8000-%012d", ids.next()))) })

        var containers: [String: Container] = ["Inbox": .inbox]
        for (index, space) in spaces.enumerated() {
            let created = try await catalog.createSpace(
                named: space.name, color: .palette(space.color), symbol: space.symbol, sealed: space.sealed,
                description: space.description, keywords: space.keywords,
                id: SpaceID(uuid(String(format: "5ACE0000-0000-4000-8000-%012d", index + 1))))
            containers[space.name] = .space(created.id)
        }
        for note in notes {
            guard let container = containers[note.place], let folder = ItemPath(note.folder) else { continue }
            let written = now.addingTimeInterval(-note.hoursAgo * 3600)
            let created = try await store.create(
                title: note.title, in: folder, container: container, kind: note.kind, body: note.body,
                created: written.addingTimeInterval(-note.hoursAgo * 1800))
            let url = try await catalog.url(for: created.ref.path, in: container, isDirectory: false)
            try? FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        }
        return try await catalog.open()
    }

    // MARK: - Content

    struct DemoSpace {
        var name: String
        var color: PaletteColor
        var symbol: String
        var sealed: Bool
        var description: String
        var keywords: [String]
    }

    struct DemoNote {
        /// A space's name, or "Inbox".
        var place: String
        var folder: String
        var title: String
        var kind: NoteKind = .note
        /// How long before `now` the note was last changed.
        var hoursAgo: Double
        var body: String
    }

    static let spaces: [DemoSpace] = [
        DemoSpace(
            name: "Uni", color: .teal, symbol: "graduationcap", sealed: false,
            description: "University courses and coursework.", keywords: ["uni", "lecture", "exam"]),
        DemoSpace(
            name: "Red Cross", color: .rose, symbol: "cross.case", sealed: true,
            description: "Volunteer work. Kept apart from everything else.",
            keywords: ["red cross", "first aid", "shift"]),
        DemoSpace(
            name: "Ideas", color: .iris, symbol: "lightbulb", sealed: false,
            description: "Things worth thinking about.", keywords: ["idea"]),
    ]

    static let notes: [DemoNote] = [
        DemoNote(
            place: "Uni", folder: "", title: "Pass Physics 1", kind: .goal, hoursAgo: 20,
            body: """
                The exam is on 12 February. What gets me there:

                - [ ] Finish problem sets 4 to 6
                - [ ] Two past papers under exam conditions
                - [x] Sort the formula sheet

                Notes that count toward this: [[Lecture 7 notes]], [[Lecture 8 notes]] and [[Problem set 4]].
                """),
        DemoNote(
            place: "Uni", folder: "Physics", title: "Lecture 7 notes", hoursAgo: 3,
            body: """
                # Rotational motion

                Torque is the rotational version of force: **τ = r × F**. The moment of inertia *I* plays the role of mass.

                - A rigid body: every point shares the same angular velocity ω
                - Kinetic energy of rotation: `½ I ω²`
                - Parallel axis theorem: `I = I_cm + m d²`

                > Ask in the tutorial why the hoop loses to the disc down the ramp.

                - [ ] Redo the worked example with the pulley
                - [x] Copy the table of moments of inertia

                Continues in [[Lecture 8 notes]]. For the exam: [[Pass Physics 1]]. #physics #exam
                """),
        DemoNote(
            place: "Uni", folder: "Physics", title: "Lecture 8 notes", hoursAgo: 1,
            body: """
                # Angular momentum

                **L = I ω**, and it is conserved when no outside torque acts. The skater pulls her arms in, *I* drops, ω rises.

                - Gyroscope precession: torque changes the direction of **L**, not its size
                - Compare with linear momentum in [[Lecture 7 notes]]

                - [ ] Look up the derivation of the precession rate

                #physics
                """),
        DemoNote(
            place: "Uni", folder: "Physics", title: "Problem set 4", hoursAgo: 26,
            body: """
                Due Friday. From the chapter on rotation.

                - [x] 4.1 Flywheel spin-up
                - [x] 4.2 Rolling without slipping
                - [ ] 4.3 The yo-yo
                - [ ] 4.4 Door and bullet

                Stuck on 4.3: is the tension constant? See [[Lecture 7 notes]].
                """),
        DemoNote(
            place: "Uni", folder: "Linear Algebra", title: "Eigenvalues", hoursAgo: 50,
            body: """
                # Eigenvalues and eigenvectors

                A vector **v** is an eigenvector of *A* when `A v = λ v`.

                | Matrix | Eigenvalues |
                |---|---|
                | diagonal | its diagonal entries |
                | rotation by 90° | none that are real |

                - [ ] Prove that a symmetric matrix has real eigenvalues

                #linear-algebra #exam
                """),
        DemoNote(
            place: "Uni", folder: "", title: "Reading list", hoursAgo: 72,
            body: """
                - [x] *Six Easy Pieces*, chapters 1 to 3
                - [ ] *Linear Algebra Done Right*, chapter 5
                - [ ] The lab manual, before week 9

                #reading
                """),
        DemoNote(
            place: "Red Cross", folder: "First aid course", title: "Session 3 - Bleeding and shock", hoursAgo: 30,
            body: """
                # Bleeding and shock

                1. Gloves on, then direct pressure on the wound
                2. Raise the limb if nothing is broken
                3. Pressure bandage; a second one on top if it soaks through

                Signs of shock: pale and cold skin, fast and weak pulse, restlessness. Lay the person down, legs raised, keep them warm, call for help.

                - [ ] Practise the pressure bandage until it takes under a minute

                #first-aid
                """),
        DemoNote(
            place: "Red Cross", folder: "", title: "Shift plan November", hoursAgo: 8,
            body: """
                | Date | Shift | With |
                |---|---|---|
                | Sat 14 | Football, north stand | team B |
                | Fri 20 | Blood drive, sports hall | team A |
                | Sun 29 | Christmas market | team B |

                - [ ] Swap the 20th, there is a lab that afternoon
                """),
        DemoNote(
            place: "Red Cross", folder: "", title: "Equipment checklist", hoursAgo: 100,
            body: """
                Before every shift:

                - [ ] Gloves, two sizes
                - [ ] Triangular bandages
                - [ ] Rescue blanket
                - [ ] Torch with fresh batteries
                """),
        DemoNote(
            place: "Ideas", folder: "", title: "Notes that file themselves", kind: .idea, hoursAgo: 5,
            body: """
                What if the place I dump things could sort them, and only ask when it isn't sure?

                - It should say *why* it wants to put something somewhere
                - It should never move anything without showing me first
                - It could learn from what I correct

                Related: [[Study group app]]. #idea
                """),
        DemoNote(
            place: "Ideas", folder: "", title: "Study group app", kind: .idea, hoursAgo: 44,
            body: """
                A shared board for a study group: who explains which topic, and when.

                Start with the topics in [[Reading list]] and the open problems in [[Problem set 4]].

                - [ ] Ask the group whether anyone would use it

                #idea
                """),
        DemoNote(
            place: "Ideas", folder: "", title: "Night sky photos", hoursAgo: 120,
            body: """
                The Plough is easy to find even from the balcony. Follow the two end stars of the bowl to the Pole Star.

                Try a 15 second exposure next clear night. #photography
                """),
        DemoNote(place: "Inbox", folder: "", title: "Ask about the exam date", hoursAgo: 0.5, body: ""),
        DemoNote(
            place: "Inbox", folder: "", title: "Book - Six Easy Pieces", hoursAgo: 2,
            body: "Recommended in the tutorial. Check the library before buying it.\n"),
        DemoNote(
            place: "Inbox", folder: "", title: "Bandage sizes", hoursAgo: 6,
            body: "Triangular bandage: 96 × 96 × 136 cm. Ask at the next course evening how many to carry.\n"),
        DemoNote(
            place: "Inbox", folder: "", title: "Table of moments of inertia", hoursAgo: 28,
            body: "https://example.org/moments-of-inertia\n\nThe hoop and the disc are both on it.\n"),
    ]

    // MARK: - Private

    private static func uuid(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }

    /// Counts up from 1, from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
