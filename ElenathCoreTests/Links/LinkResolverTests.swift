import Foundation
import Testing

@testable import ElenathCore

@Suite("Link resolution")
struct LinkResolverTests {
    static let uni = SpaceID(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
    static let ideas = SpaceID(UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)

    static func note(_ space: SpaceID, _ path: String) -> NoteRef {
        NoteRef(container: .space(space), path: ItemPath(path)!)
    }

    static func inbox(_ path: String) -> NoteRef {
        NoteRef(container: .inbox, path: ItemPath(path)!)
    }

    static let names: [SpaceID: String] = [uni: "Uni", ideas: "Ideas"]

    /// Uni has two "Lecture 7" notes and two "Summary" notes; Ideas has its own "Summary".
    static let notes: [NoteRef] = [
        note(uni, "Reading list.md"),
        note(uni, "Physics/Lecture 7.md"),
        note(uni, "Physics/Summary.md"),
        note(uni, "Maths/Lecture 7.md"),
        note(uni, "Maths/Old/Summary.md"),
        note(uni, "Maths/Proofs.markdown"),
        note(uni, "C# notes.md"),
        note(ideas, "Summary.md"),
        note(ideas, "App idea.md"),
        note(ideas, "Uni/Orientation.md"),
    ]

    static let resolver = LinkResolver(catalog: TitleCatalog(notes: notes), spaceNames: names)

    private func resolve(_ inner: String, from source: NoteRef) -> LinkResolution {
        Self.resolver.resolve(WikiLink(inner: inner, isEmbed: false)!, from: source)
    }

    @Test("A title resolves inside the linking note's space first")
    func titleInOwnSpace() {
        let source = Self.note(Self.uni, "Reading list.md")
        #expect(resolve("Reading list", from: source) == .resolved(source))
        #expect(resolve("reading LIST", from: source) == .resolved(source))
        #expect(resolve("Reading list.md", from: source) == .resolved(source))
        #expect(resolve("Proofs", from: source) == .resolved(Self.note(Self.uni, "Maths/Proofs.markdown")))
        #expect(
            resolve("Summary", from: Self.note(Self.ideas, "App idea.md"))
                == .resolved(Self.note(Self.ideas, "Summary.md")))
    }

    @Test("Among several notes with one title, the one beside the linking note wins, then the shortest path")
    func clashes() {
        let physics = Self.note(Self.uni, "Physics/Summary.md")
        let maths = Self.note(Self.uni, "Maths/Proofs.markdown")
        #expect(resolve("Lecture 7", from: physics) == .resolved(Self.note(Self.uni, "Physics/Lecture 7.md")))
        #expect(resolve("Lecture 7", from: maths) == .resolved(Self.note(Self.uni, "Maths/Lecture 7.md")))
        // From the top of the space neither is beside the note and both are equally deep.
        #expect(
            resolve("Lecture 7", from: Self.note(Self.uni, "Reading list.md"))
                == .ambiguous([Self.note(Self.uni, "Maths/Lecture 7.md"), Self.note(Self.uni, "Physics/Lecture 7.md")]))
        // "Summary": Physics/Summary is nearer the top than Maths/Old/Summary.
        #expect(resolve("Summary", from: Self.note(Self.uni, "Reading list.md")) == .resolved(physics))
    }

    @Test("A title the space doesn't have resolves elsewhere when exactly one note has it")
    func otherSpaces() {
        let source = Self.note(Self.ideas, "App idea.md")
        #expect(resolve("Reading list", from: source) == .resolved(Self.note(Self.uni, "Reading list.md")))
        #expect(
            resolve("Lecture 7", from: source)
                == .ambiguous([Self.note(Self.uni, "Maths/Lecture 7.md"), Self.note(Self.uni, "Physics/Lecture 7.md")]))
        #expect(resolve("No such note", from: source) == .unresolved)
    }

    @Test("Paths: the end of a path in the same space, then a path from the library folder")
    func paths() {
        let source = Self.note(Self.uni, "Reading list.md")
        #expect(resolve("Physics/Lecture 7", from: source) == .resolved(Self.note(Self.uni, "Physics/Lecture 7.md")))
        #expect(resolve("Old/Summary", from: source) == .resolved(Self.note(Self.uni, "Maths/Old/Summary.md")))
        #expect(resolve("Ideas/Summary", from: source) == .resolved(Self.note(Self.ideas, "Summary.md")))
        #expect(resolve("Ideas/App idea", from: source) == .resolved(Self.note(Self.ideas, "App idea.md")))
        #expect(resolve("Nowhere/Summary", from: source) == .unresolved)

        let fromIdeas = Self.note(Self.ideas, "App idea.md")
        #expect(
            resolve("Uni/Physics/Lecture 7", from: fromIdeas) == .resolved(Self.note(Self.uni, "Physics/Lecture 7.md")))
        #expect(resolve("Uni/Reading list", from: fromIdeas) == .resolved(Self.note(Self.uni, "Reading list.md")))
        // Ideas has a folder called Uni: the path inside the own space is tried first.
        #expect(resolve("Uni/Orientation", from: fromIdeas) == .resolved(Self.note(Self.ideas, "Uni/Orientation.md")))
    }

    @Test("Headings, the note itself, and titles with a # in them")
    func headings() {
        let source = Self.note(Self.uni, "Reading list.md")
        #expect(resolve("Proofs#Induction", from: source) == .resolved(Self.note(Self.uni, "Maths/Proofs.markdown")))
        #expect(resolve("#Top", from: source) == .resolved(source))
        #expect(resolve("C# notes", from: source) == .resolved(Self.note(Self.uni, "C# notes.md")))
        #expect(resolve("Missing#Part", from: source) == .unresolved)
    }

    @Test("A resolver finds nothing outside its catalog: that is how sealing holds for links")
    func sealedCatalog() {
        // What a sealed space's resolver is given: its own notes only.
        let sealed = LinkResolver(
            catalog: TitleCatalog(notes: Self.notes.filter { $0.container == .space(Self.ideas) }),
            spaceNames: [Self.ideas: "Ideas"])
        let source = Self.note(Self.ideas, "App idea.md")
        #expect(sealed.resolve(WikiLink(target: "Reading list"), from: source) == .unresolved)
        #expect(sealed.resolve(WikiLink(target: "Uni/Reading list"), from: source) == .unresolved)
        #expect(
            sealed.resolve(WikiLink(target: "Summary"), from: source) == .resolved(Self.note(Self.ideas, "Summary.md")))
    }

    @Test("The shortest target that resolves is written")
    func shortestTarget() {
        let resolver = Self.resolver
        let top = Self.note(Self.uni, "Reading list.md")
        #expect(resolver.shortestTarget(for: Self.note(Self.uni, "Maths/Proofs.markdown"), from: top) == "Proofs")
        #expect(
            resolver.shortestTarget(for: Self.note(Self.uni, "Physics/Lecture 7.md"), from: top) == "Physics/Lecture 7")
        #expect(
            resolver.shortestTarget(
                for: Self.note(Self.uni, "Physics/Lecture 7.md"), from: Self.note(Self.uni, "Physics/Summary.md"))
                == "Lecture 7")
        #expect(resolver.shortestTarget(for: Self.note(Self.uni, "Maths/Old/Summary.md"), from: top) == "Old/Summary")
        let fromIdeas = Self.note(Self.ideas, "App idea.md")
        #expect(resolver.shortestTarget(for: top, from: fromIdeas) == "Reading list")
        #expect(
            resolver.shortestTarget(for: Self.note(Self.uni, "Physics/Summary.md"), from: fromIdeas) == "Uni/Summary")
        #expect(
            resolver.shortestTarget(for: Self.note(Self.uni, "Maths/Lecture 7.md"), from: fromIdeas)
                == "Uni/Maths/Lecture 7")
    }

    @Test("Markdown links are paths from the linking note's folder")
    func markdownLinks() {
        let resolver = Self.resolver
        let source = Self.note(Self.uni, "Physics/Summary.md")
        #expect(
            resolver.resolve(markdownDestination: "Lecture%207.md", from: source)
                == .resolved(Self.note(Self.uni, "Physics/Lecture 7.md")))
        #expect(
            resolver.resolve(markdownDestination: "../Maths/Old/Summary.md#Part", from: source)
                == .resolved(Self.note(Self.uni, "Maths/Old/Summary.md")))
        #expect(
            resolver.resolve(markdownDestination: "../Reading list", from: source)
                == .resolved(Self.note(Self.uni, "Reading list.md")))
        #expect(resolver.resolve(markdownDestination: "https://example.com/a.md", from: source) == .unresolved)
        #expect(resolver.resolve(markdownDestination: "../../Ideas/Summary.md", from: source) == .unresolved)
        #expect(resolver.resolve(markdownDestination: "/Physics/Lecture 7.md", from: source) == .unresolved)
        #expect(
            resolver.markdownDestination(for: Self.note(Self.uni, "Maths/Lecture 7.md"), from: source)
                == "../Maths/Lecture%207.md")
        #expect(resolver.markdownDestination(for: Self.note(Self.ideas, "Summary.md"), from: source) == nil)
    }
}

@Suite("Link rewriting")
struct LinkRewriterTests {
    typealias Fixture = LinkResolverTests

    private func rewrite(
        moving old: NoteRef, to new: NoteRef, in notes: [(note: NoteRef, body: String)]
    ) -> [NoteRef: String] {
        let catalog = TitleCatalog(notes: Fixture.notes)
        let before = LinkResolver(catalog: catalog, spaceNames: Fixture.names)
        let after = LinkResolver(catalog: catalog.replacing(old, with: new), spaceNames: Fixture.names)
        let edits = LinkRewriter.edits(forMoving: old, to: new, notes: notes, before: before, after: after)
        var result: [NoteRef: String] = [:]
        for (note, body) in notes {
            let noteAfter = note == old ? new : note
            result[noteAfter] = LinkRewriter.apply(edits.filter { $0.note == noteAfter }, to: body)
        }
        return result
    }

    @Test("Renaming a note rewrites the links to it and keeps shown text and headings")
    func rename() {
        let old = Fixture.note(Fixture.uni, "Reading list.md")
        let new = Fixture.note(Fixture.uni, "Books to read.md")
        let linker = Fixture.note(Fixture.uni, "Physics/Summary.md")
        let other = Fixture.note(Fixture.ideas, "App idea.md")
        let body =
            "See [[Reading list]], [[reading list|my list]], [[Reading list#Fiction]] and ![[Reading list]].\n`[[Reading list]]` stays. [[Proofs]] stays. [[Nothing here]] stays.\n"
        let result = rewrite(
            moving: old, to: new, in: [(linker, body), (other, "🧭 [[Reading list]] and [x](<../Uni/x.md>)")])
        #expect(
            result[linker]
                == "See [[Books to read]], [[Books to read|my list]], [[Books to read#Fiction]] and ![[Books to read]].\n`[[Reading list]]` stays. [[Proofs]] stays. [[Nothing here]] stays.\n"
        )
        #expect(result[other] == "🧭 [[Books to read]] and [x](<../Uni/x.md>)")
    }

    @Test("Moving a note keeps links to it working and lengthens them only when needed")
    func move() {
        let old = Fixture.note(Fixture.uni, "Physics/Lecture 7.md")
        let new = Fixture.note(Fixture.uni, "Maths/Old/Lecture 7.md")
        let beside = Fixture.note(Fixture.uni, "Physics/Summary.md")
        let result = rewrite(
            moving: old, to: new,
            in: [(beside, "[[Lecture 7]] and [[Physics/Lecture 7]] and [again](Lecture%207.md#Top)")])
        // "Lecture 7" alone would now find Maths/Lecture 7 or be ambiguous: the folder is written out.
        #expect(
            result[beside] == "[[Old/Lecture 7]] and [[Old/Lecture 7]] and [again](../Maths/Old/Lecture%207.md#Top)")
    }

    @Test("The moved note's own links are kept pointing where they pointed")
    func ownLinks() {
        let old = Fixture.note(Fixture.uni, "Physics/Summary.md")
        let new = Fixture.note(Fixture.ideas, "Physics summary.md")
        let result = rewrite(
            moving: old, to: new, in: [(old, "[[Lecture 7]] [[Reading list]] [[Summary]] [[#Top]] [l](Lecture%207.md)")]
        )
        // In Ideas, "Lecture 7" is ambiguous, "Reading list" still unique, and "Summary" would be
        // Ideas' own note instead of this one.
        #expect(
            result[new]
                == "[[Uni/Physics/Lecture 7]] [[Reading list]] [[Physics summary]] [[#Top]] [l](Lecture%207.md)")
    }

    @Test("Links that never resolved are left alone")
    func unresolvedStay() {
        let old = Fixture.note(Fixture.uni, "Physics/Lecture 7.md")
        let new = Fixture.note(Fixture.uni, "Physics/Lecture seven.md")
        let top = Fixture.note(Fixture.uni, "Reading list.md")
        let result = rewrite(moving: old, to: new, in: [(top, "[[Lecture 7]] was ambiguous, [[Lecture 8]] unresolved")])
        #expect(result[top] == "[[Lecture 7]] was ambiguous, [[Lecture 8]] unresolved")
    }
}

@Suite("Link rewriting for folders and spaces")
struct LinkRewriterBatchTests {
    typealias Fixture = LinkResolverTests

    @Test("Renaming a folder keeps the links that name it")
    func folderRename() {
        let catalog = TitleCatalog(notes: Fixture.notes)
        let moves: [NoteRef: NoteRef] = [
            Fixture.note(Fixture.uni, "Maths/Lecture 7.md"): Fixture.note(Fixture.uni, "Algebra/Lecture 7.md"),
            Fixture.note(Fixture.uni, "Maths/Proofs.markdown"): Fixture.note(Fixture.uni, "Algebra/Proofs.markdown"),
            Fixture.note(Fixture.uni, "Maths/Old/Summary.md"): Fixture.note(Fixture.uni, "Algebra/Old/Summary.md"),
        ]
        var afterCatalog = catalog
        for (old, new) in moves {
            afterCatalog = afterCatalog.replacing(old, with: new)
        }
        let top = Fixture.note(Fixture.uni, "Reading list.md")
        let body = "[[Maths/Lecture 7]] [[Proofs]] [[Maths/Old/Summary|old]] [[Physics/Lecture 7]]"
        let edits = LinkRewriter.edits(
            forMoving: moves, notes: [(top, body)], before: LinkResolver(catalog: catalog, spaceNames: Fixture.names),
            after: LinkResolver(catalog: afterCatalog, spaceNames: Fixture.names))
        #expect(
            LinkRewriter.apply(edits, to: body)
                == "[[Algebra/Lecture 7]] [[Proofs]] [[Old/Summary|old]] [[Physics/Lecture 7]]")
    }

    @Test("Renaming a space keeps the links written with its name")
    func spaceRename() {
        let catalog = TitleCatalog(notes: Fixture.notes)
        let before = LinkResolver(catalog: catalog, spaceNames: Fixture.names)
        let after = LinkResolver(catalog: catalog, spaceNames: [Fixture.uni: "University", Fixture.ideas: "Ideas"])
        let source = Fixture.note(Fixture.ideas, "App idea.md")
        let body = "[[Uni/Summary]] [[Uni/Maths/Lecture 7#Part|that]] [[Reading list]]"
        let edits = LinkRewriter.edits(forMoving: [:], notes: [(source, body)], before: before, after: after)
        #expect(
            LinkRewriter.apply(edits, to: body)
                == "[[University/Summary]] [[University/Maths/Lecture 7#Part|that]] [[Reading list]]")
    }
}

@Suite("Link rewriting with titles made outside Elenath")
struct LinkRewriterSpecialTitleTests {
    private static func wikiLinks(in body: String) -> [WikiLink] {
        MarkdownScanner.scan(body).links.compactMap { span in
            if case .wiki(let link) = span.target { return link }
            return nil
        }
    }

    @Test("A new title that can't be written as a wiki link leaves the links as they were")
    func titleThatBreaksLinks() {
        let space = SpaceID()
        func ref(_ path: String) -> NoteRef { NoteRef(container: .space(space), path: ItemPath(path)!) }
        let other = ref("C.md")
        let old = ref("Old.md")
        let linker = ref("Linker.md")
        for newTitle in ["C# notes", "C|D"] {
            let new = ref("\(newTitle).md")
            let catalog = TitleCatalog(notes: [other, old, linker])
            let before = LinkResolver(catalog: catalog, spaceNames: [space: "Uni"])
            let after = LinkResolver(catalog: catalog.replacing(old, with: new), spaceNames: [space: "Uni"])
            let body = "See [[Old]] and [[Old#Intro]].\n"
            let edits = LinkRewriter.edits(
                forMoving: old, to: new, notes: [(note: linker, body: body)], before: before, after: after)
            let rewritten = LinkRewriter.apply(edits, to: body)
            // Never a link that now points at "C".
            for link in Self.wikiLinks(in: rewritten) {
                #expect(after.resolve(link, from: linker) != .resolved(other), "\(link.written)")
            }
        }
    }

    @Test("Renaming a note whose title has # in it drops the heading that was part of the title")
    func renameFromHashTitle() {
        let space = SpaceID()
        func ref(_ path: String) -> NoteRef { NoteRef(container: .space(space), path: ItemPath(path)!) }
        let old = ref("C# notes.md")
        let new = ref("C sharp.md")
        let linker = ref("Linker.md")
        let catalog = TitleCatalog(notes: [old, linker])
        let before = LinkResolver(catalog: catalog, spaceNames: [:])
        let after = LinkResolver(catalog: catalog.replacing(old, with: new), spaceNames: [:])
        let body = "See [[C# notes]] and [[C# notes|the notes]].\n"
        let edits = LinkRewriter.edits(
            forMoving: old, to: new, notes: [(note: linker, body: body)], before: before, after: after)
        #expect(LinkRewriter.apply(edits, to: body) == "See [[C sharp]] and [[C sharp|the notes]].\n")
    }
}
