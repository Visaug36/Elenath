import ElenathCore
import Foundation
import Testing

/// The proof that sealing holds (CLAUDE.md, "Spaces").
///
/// One marker word is planted in a sealed space, another in a space that mixes and a third in the Inbox,
/// each in every place the index reads: a note's title, its text, a tag in the text and in the front
/// matter, a task, a link, a file's name and a folder's name. Then every query of `Retrieval` is asked
/// from every workplace, and everything it returns is searched for the markers.
///
/// - The sealed marker comes out only inside the sealed space.
/// - Nothing else comes out inside the sealed space.
/// - The Inbox's marker comes out only in the Inbox, and nothing else comes out there.
///
/// `scripts/check-rules.sh` fails when `Retrieval` has a public query that this file doesn't call.
@Suite("Sealing: nothing leaks")
struct SealingLeakTests {
    static let sealedMarker = "zebrafish"
    static let openMarker = "quokka"
    static let inboxMarker = "axolotl"

    private struct Library {
        let fixture: LibraryFixture
        let uni: Space
        let ideas: Space
        let redCross: Space
        let indexer: Indexer
        let retrieval: Retrieval

        init() async throws {
            fixture = try await LibraryFixture()
            uni = try await fixture.space("Uni", keywords: ["lecture"])
            ideas = try await fixture.space("Ideas")
            redCross = try await fixture.space("Red Cross", sealed: true, keywords: ["first aid"])
            try Library.plant(SealingLeakTests.openMarker, in: "Uni", fixture)
            try Library.plant(SealingLeakTests.sealedMarker, in: "Red Cross", fixture)
            try Library.plant(SealingLeakTests.inboxMarker, in: "Inbox", fixture)
            // A note in a space that mixes. Every container has a "Shared title", so its link shows which
            // one a link from here can reach. No marker word is written here or in another container's
            // notes: a marker exists only where it was planted.
            try fixture.write("A curious note that links to [[Shared title]].\n", to: "Ideas/Curious.md")
            indexer = fixture.indexer()
            retrieval = fixture.retrieval()
            await indexer.refreshAll()
        }

        /// Puts a marker everywhere the index reads, inside one container's folder.
        static func plant(_ marker: String, in folder: String, _ fixture: LibraryFixture) throws {
            try fixture.write(
                """
                ---
                id: \(UUID().uuidString)
                tags: [\(marker)-front]
                kind: idea
                ---
                # The \(marker) heading

                Text about the \(marker) protocol. #\(marker)-tag
                - [ ] Call the \(marker) team
                A link to [[\(marker) plan]] and to [[Shared title]].
                """, to: "\(folder)/\(marker) drills/\(marker) roster.md")
            try fixture.write("The \(marker) plan itself.\n", to: "\(folder)/\(marker) plan.md")
            try fixture.write("Same title in every container, by \(marker).\n", to: "\(folder)/Shared title.md")
            try fixture.write("%PDF", to: "\(folder)/\(marker) drills/\(marker) scan.pdf")
        }

        var containers: [Container] {
            [.space(uni.id), .space(ideas.id), .space(redCross.id), .inbox]
        }

        func roster(_ marker: String, in container: Container) -> NoteRef {
            NoteRef(container: container, path: ItemPath("\(marker) drills/\(marker) roster.md")!)
        }

        /// Everything a workplace can get out of the queries that take one, as one text.
        func everything(from workplace: Workplace) async throws -> String {
            var found: [String] = []
            func add(_ hits: [NoteHit]) {
                for hit in hits {
                    found += [hit.title, hit.preview, hit.note.path.description]
                }
            }
            let markers = [SealingLeakTests.sealedMarker, SealingLeakTests.openMarker, SealingLeakTests.inboxMarker]
            for text in markers + ["", "roster", "plan", "protocol", "drills", "shared", "scan", "heading", "team"] {
                for query in [
                    SearchQuery(text: text, limit: 200),
                    SearchQuery(text: text, space: redCross.id, limit: 200),
                    SearchQuery(text: text, space: uni.id, limit: 200),
                    SearchQuery(text: text, folder: ItemPath("\(SealingLeakTests.sealedMarker) drills"), limit: 200),
                    SearchQuery(text: text, space: redCross.id, folder: ItemPath("zebrafish drills"), limit: 200),
                    SearchQuery(text: text, tag: "\(SealingLeakTests.sealedMarker)-tag", limit: 200),
                    SearchQuery(text: text, kind: .idea, limit: 200),
                ] {
                    for hit in try await retrieval.search(query, from: workplace) {
                        found += [hit.title, hit.snippet.text]
                        switch hit.item {
                        case .note(let note): found.append(note.path.description)
                        case .file(_, let path): found.append(path.description)
                        }
                    }
                }
                add(try await retrieval.titles(matching: text, from: workplace, limit: 200))
            }
            add(try await retrieval.recentNotes(from: workplace, limit: 200))
            for name in ["Red Cross", "Uni", "Inbox"] + markers.map({ "\($0) drills" }) {
                found += try await retrieval.notesLinking(throughFolderNamed: name, from: workplace).map(
                    \.path.description)
            }
            for tag in try await retrieval.tags(from: workplace) {
                found.append(tag.tag)
                add(try await retrieval.notes(tagged: tag.tag, from: workplace))
            }
            for marker in markers {
                add(try await retrieval.notes(tagged: "\(marker)-tag", from: workplace))
                add(try await retrieval.notes(tagged: "\(marker)-front", from: workplace))
            }
            for task in try await retrieval.openTasks(from: workplace, limit: 200) {
                found += [task.text, task.note.title, task.note.preview]
            }
            for container in containers {
                found += try await retrieval.folders(of: container, from: workplace).map(\.description)
                for marker in markers {
                    for note in [
                        roster(marker, in: container),
                        NoteRef(container: container, path: ItemPath("\(marker) plan.md")!),
                        NoteRef(container: container, path: ItemPath("Shared title.md")!),
                    ] {
                        if let text = try await retrieval.text(of: note, from: workplace) {
                            found.append(text)
                        }
                    }
                }
            }
            return found.joined(separator: "\n").lowercased()
        }

        /// Everything the queries about one note give for the notes of one container.
        func everythingAbout(notesIn container: Container, marker: String) async throws -> String {
            var found: [String] = []
            let notes = [
                roster(marker, in: container),
                NoteRef(container: container, path: ItemPath("\(marker) plan.md")!),
                NoteRef(container: container, path: ItemPath("Shared title.md")!),
            ]
            for note in notes {
                for backlink in try await retrieval.backlinks(to: note) {
                    found += [backlink.source.title, backlink.source.preview, backlink.context]
                    found.append(backlink.source.note.path.description)
                }
                found += try await retrieval.linkingNotes(to: note).map(\.path.description)
                found += try await retrieval.attachmentNamesShared(by: note)
                if let hit = try await retrieval.note(note) {
                    found += [hit.title, hit.preview]
                }
                _ = try await retrieval.hasDuplicatedIdentity(note)
            }
            for folder in [ItemPath.root, ItemPath("\(marker) drills")!] {
                for hit in try await retrieval.notes(in: folder, of: container) {
                    found += [hit.title, hit.preview, hit.note.path.description]
                }
            }
            return found.joined(separator: "\n").lowercased()
        }
    }

    // MARK: - Queries asked from a workplace

    @Test("The sealed marker comes out inside the sealed space and nowhere else")
    func sealedContentStaysInside() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let outside: [Workplace] = [
            .space(library.uni.id), .space(library.ideas.id), .everywhere, .inbox, .space(SpaceID()),
        ]
        for workplace in outside {
            let text = try await library.everything(from: workplace)
            #expect(!text.contains(Self.sealedMarker), "the sealed marker leaked to \(workplace)")
        }
        // The marker really is findable: the test above is not passing by finding nothing at all.
        let inside = try await library.everything(from: .space(library.redCross.id))
        #expect(inside.contains("zebrafish roster"))
        #expect(inside.contains("zebrafish protocol"))
        #expect(inside.contains("zebrafish-tag"))
        #expect(inside.contains("zebrafish-front"))
        #expect(inside.contains("call the zebrafish team"))
        #expect(inside.contains("zebrafish scan.pdf"))
        #expect(inside.contains("zebrafish drills"))
    }

    @Test("Nothing from outside comes out inside the sealed space")
    func nothingEntersTheSealedSpace() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let inside = try await library.everything(from: .space(library.redCross.id))
        #expect(!inside.contains(Self.openMarker))
        #expect(!inside.contains(Self.inboxMarker))
        #expect(!inside.contains("curious"))
    }

    @Test("Spaces that mix see each other, and never the Inbox")
    func mixingSpaces() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        for workplace in [Workplace.space(library.uni.id), .space(library.ideas.id), .everywhere] {
            let text = try await library.everything(from: workplace)
            #expect(text.contains("quokka roster"))
            #expect(text.contains("quokka scan.pdf"))
            #expect(text.contains("curious"))
            #expect(!text.contains(Self.inboxMarker), "the Inbox leaked to \(workplace)")
        }
    }

    @Test("The Inbox sees itself only")
    func inboxIsAlone() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let text = try await library.everything(from: .inbox)
        #expect(text.contains("axolotl roster"))
        #expect(text.contains("axolotl scan.pdf"))
        #expect(!text.contains(Self.openMarker))
        #expect(!text.contains(Self.sealedMarker))
        #expect(!text.contains("curious"))
    }

    @Test("A workplace that doesn't exist gets nothing")
    func unknownWorkplace() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        #expect(try await library.everything(from: .space(SpaceID())).isEmpty)
    }

    // MARK: - Queries about one note

    @Test("Backlinks, linking notes and folder lists stay on their side of the seal")
    func queriesAboutOneNote() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let sealed = try await library.everythingAbout(notesIn: .space(library.redCross.id), marker: Self.sealedMarker)
        #expect(sealed.contains("zebrafish roster"))
        #expect(!sealed.contains(Self.openMarker))
        #expect(!sealed.contains(Self.inboxMarker))
        #expect(!sealed.contains("curious"))

        let open = try await library.everythingAbout(notesIn: .space(library.uni.id), marker: Self.openMarker)
        #expect(open.contains("quokka roster"))
        #expect(!open.contains(Self.sealedMarker))
        #expect(!open.contains(Self.inboxMarker))

        let inbox = try await library.everythingAbout(notesIn: .inbox, marker: Self.inboxMarker)
        #expect(inbox.contains("axolotl roster"))
        #expect(!inbox.contains(Self.sealedMarker))
        #expect(!inbox.contains(Self.openMarker))
    }

    @Test("Links never resolve across a seal, in either direction, however they are written")
    func linksStopAtTheSeal() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let retrieval = library.retrieval
        let fromIdeas = NoteRef(container: .space(library.ideas.id), path: ItemPath("Curious.md")!)
        let fromSealed = library.roster(Self.sealedMarker, in: .space(library.redCross.id))
        let fromInbox = library.roster(Self.inboxMarker, in: .inbox)
        let sealedRoster = library.roster(Self.sealedMarker, in: .space(library.redCross.id))

        for target in [
            "zebrafish roster", "Red Cross/zebrafish roster", "Red Cross/zebrafish drills/zebrafish roster",
            "zebrafish drills/zebrafish roster", "zebrafish plan", "axolotl roster", "Inbox/axolotl roster",
        ] {
            #expect(try await retrieval.resolve(WikiLink(target: target), from: fromIdeas) == .unresolved, "\(target)")
        }
        // "Shared title" exists on both sides. From outside, it is never the sealed one or the Inbox's.
        #expect(
            try await retrieval.resolve(WikiLink(target: "Shared title"), from: fromIdeas)
                == .resolved(NoteRef(container: .space(library.uni.id), path: ItemPath("Shared title.md")!)))

        // From inside the seal: only what is inside.
        #expect(
            try await retrieval.resolve(WikiLink(target: "zebrafish roster"), from: fromSealed)
                == .resolved(sealedRoster))
        #expect(
            try await retrieval.resolve(WikiLink(target: "Shared title"), from: fromSealed)
                == .resolved(NoteRef(container: .space(library.redCross.id), path: ItemPath("Shared title.md")!)))
        for target in ["quokka roster", "Uni/quokka roster", "Curious", "Ideas/Curious", "axolotl roster"] {
            #expect(try await retrieval.resolve(WikiLink(target: target), from: fromSealed) == .unresolved, "\(target)")
        }
        // From the Inbox: only the Inbox.
        #expect(try await retrieval.resolve(WikiLink(target: "quokka roster"), from: fromInbox) == .unresolved)
        #expect(try await retrieval.resolve(WikiLink(target: "zebrafish roster"), from: fromInbox) == .unresolved)

        // What a container's links can resolve to holds no note from the other side.
        for (container, forbidden) in [
            (Container.space(library.uni.id), [Container.space(library.redCross.id), .inbox]),
            (.space(library.redCross.id), [.space(library.uni.id), .space(library.ideas.id), .inbox]),
            (.inbox, [.space(library.uni.id), .space(library.ideas.id), .space(library.redCross.id)]),
        ] {
            let context = try await retrieval.linkContext(for: container)
            for other in forbidden {
                for marker in [Self.sealedMarker, Self.openMarker, Self.inboxMarker] {
                    #expect(!context.catalog.contains(library.roster(marker, in: other)))
                }
            }
        }
        let sealedContext = try await retrieval.linkContext(for: .space(library.redCross.id))
        #expect(Array(sealedContext.spaceNames.values) == ["Red Cross"])
    }

    // MARK: - The one crossing

    @Test("Filing may use a sealed space's name, description and keywords, never its folders or notes")
    func filingCrossesWithNamesOnly() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        let destinations = await library.retrieval.filingDestinations()
        let sealed = try #require(destinations.first { $0.space == library.redCross.id })
        #expect(sealed.name == "Red Cross")
        #expect(sealed.keywords == ["first aid"])
        #expect(sealed.isSealed)
        #expect(sealed.folders.isEmpty)
        let open = try #require(destinations.first { $0.space == library.uni.id })
        #expect(open.folders == [ItemPath("quokka drills")!])
        let everything = destinations.flatMap {
            [$0.name, $0.description] + $0.keywords + $0.folders.map(\.description)
        }
        #expect(!everything.joined(separator: " ").lowercased().contains(Self.sealedMarker))

        // The Inbox's count is a number and nothing more.
        #expect(try await library.retrieval.inboxCount() == 3)
    }

    // MARK: - Sealing and unsealing

    @Test("Sealing takes effect at the next question, and so does unsealing")
    func sealingIsImmediate() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        var redCross = library.redCross
        redCross.isSealed = false
        try await library.fixture.catalog.update(redCross)
        #expect(try await library.everything(from: .space(library.uni.id)).contains(Self.sealedMarker))
        #expect(
            try await library.retrieval.resolve(
                WikiLink(target: "zebrafish roster"),
                from: NoteRef(container: .space(library.ideas.id), path: ItemPath("Curious.md")!)) != .unresolved)

        redCross.isSealed = true
        try await library.fixture.catalog.update(redCross)
        #expect(try await !library.everything(from: .space(library.uni.id)).contains(Self.sealedMarker))
        #expect(try await !library.everything(from: .everywhere).contains(Self.sealedMarker))
        #expect(
            try await library.retrieval.resolve(
                WikiLink(target: "zebrafish roster"),
                from: NoteRef(container: .space(library.ideas.id), path: ItemPath("Curious.md")!)) == .unresolved)

        // A newly sealed space closes both ways.
        var uni = library.uni
        uni.isSealed = true
        try await library.fixture.catalog.update(uni)
        #expect(try await !library.everything(from: .everywhere).contains(Self.openMarker))
        #expect(try await !library.everything(from: .space(library.uni.id)).contains("curious"))
    }

    @Test("A space whose settings can't be read counts as sealed")
    func damagedSettingsFailClosed() async throws {
        let library = try await Library()
        defer { library.fixture.remove() }
        // The space's settings, its backups and its safety copy are all gone, and Elenath knows the folder.
        try FileManager.default.removeItem(at: library.fixture.url("Uni/.space"))
        try FileManager.default.removeItem(at: library.fixture.safety)
        try library.fixture.write("{ not json", to: "Uni/.space/space.json")
        let catalog = LibraryCatalog(
            root: library.fixture.root, safetyDirectory: library.fixture.safety,
            fileSystem: library.fixture.fileSystem, timeSource: library.fixture.clock)
        let snapshot = try await catalog.open()
        let uni = try #require(snapshot.spaces.first { $0.name == "Uni" })
        #expect(uni.isSealed)
        #expect(snapshot.sealedByDefault == [uni.id])

        let indexer = Indexer(
            catalog: catalog, indexDirectory: library.fixture.indexDirectory, fileSystem: library.fixture.fileSystem)
        await indexer.refreshAll()
        let retrieval = Retrieval(indexDirectory: library.fixture.indexDirectory, spaces: { await catalog.spaces() })
        let hits = try await retrieval.search(SearchQuery(text: Self.openMarker), from: .everywhere)
        #expect(hits.isEmpty)
        #expect(
            try await retrieval.recentNotes(from: .everywhere, limit: 50).allSatisfy {
                !$0.title.contains(Self.openMarker)
            })
    }
}
