import ElenathCore
import Testing

struct UniqueNameTests {
    private func available(_ name: String, taken: Set<String>) -> String {
        UniqueName.available(name) { taken.contains($0) }
    }

    @Test func aFreeNameIsKept() {
        #expect(available("Notes.md", taken: []) == "Notes.md")
    }

    @Test func clashesGetNumbersBeforeTheExtension() {
        #expect(available("Notes.md", taken: ["Notes.md"]) == "Notes 2.md")
        #expect(available("Notes.md", taken: ["Notes.md", "Notes 2.md"]) == "Notes 3.md")
        #expect(available("Physics", taken: ["Physics"]) == "Physics 2")
    }

    @Test func aNumberedCopyContinuesFromItsNumber() {
        #expect(available("Notes 2.md", taken: ["Notes.md", "Notes 2.md"]) == "Notes 3.md")
        #expect(available("Notes 9.md", taken: ["Notes.md", "Notes 9.md", "Notes 10.md"]) == "Notes 11.md")
    }

    @Test func aTitleThatEndsInANumberIsNotACopy() {
        // A second "Lecture 7" must never be called "Lecture 8".
        #expect(available("Lecture 7.md", taken: ["Lecture 7.md"]) == "Lecture 7 2.md")
        #expect(available("Lecture 7.md", taken: ["Lecture 7.md", "Lecture 7 2.md"]) == "Lecture 7 3.md")
        #expect(available("Lecture 7.md", taken: ["Lecture 7.md", "Lecture 8.md"]) == "Lecture 7 2.md")
        #expect(available("Week 12", taken: ["Week 12"]) == "Week 12 2")
    }

    @Test func yearsAndLeadingZerosAreNotFinderNumbers() {
        #expect(available("Report 2026.pdf", taken: ["Report 2026.pdf"]) == "Report 2026 2.pdf")
        #expect(available("Track 01.md", taken: ["Track 01.md"]) == "Track 01 2.md")
    }

    @Test func dotsThatAreNotExtensions() {
        #expect(available("Chapter 1.2", taken: ["Chapter 1.2"]) == "Chapter 1.2 2")
        #expect(available("Dr. Smith", taken: ["Dr. Smith"]) == "Dr. Smith 2")
        #expect(available(".gitignore", taken: [".gitignore"]) == ".gitignore 2")
    }

    @Test func longNamesAreShortenedToFit() {
        let base = String(repeating: "a", count: 252)
        let name = base + ".md"
        let result = available(name, taken: [name])
        #expect(result.utf8.count <= 255)
        #expect(result.hasSuffix(" 2.md"))
    }
}
