import ElenathCore
import Foundation
import Testing

/// Notes and pages cut into chunks: by their structure, never too long, with ranges that point back at
/// exactly their text, in linear time.
struct ChunkerTests {
    /// Every chunk's range holds exactly its text.
    private func expectRangesMatch(
        _ chunks: [Chunk], in text: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let source = text as NSString
        for chunk in chunks {
            #expect(NSMaxRange(chunk.range) <= source.length, sourceLocation: sourceLocation)
            #expect(source.substring(with: chunk.range) == chunk.text, sourceLocation: sourceLocation)
            #expect(chunk.range.length <= Chunker.maximumCharacters, sourceLocation: sourceLocation)
        }
    }

    @Test func headingsStartChunksAndMakeAPath() {
        let text = """
            # Lecture 7

            Torque is a force that turns things.

            ## Torque

            τ = r × F, measured in newton metres.

            ## Angular momentum

            L = Iω. It stays the same without torque.

            # Problems
            Bring problem set 4.
            """
        let chunks = Chunker.chunks(ofNote: text)
        #expect(
            chunks.map(\.headings) == [
                ["Lecture 7"], ["Lecture 7", "Torque"], ["Lecture 7", "Angular momentum"], ["Problems"],
            ])
        #expect(chunks[1].text == "## Torque\n\nτ = r × F, measured in newton metres.")
        #expect(chunks[1].embeddingText.hasPrefix("Lecture 7 › Torque — ## Torque"))
        expectRangesMatch(chunks, in: text)
    }

    @Test func aSectionThatIsOnlyAHeadingMakesNoChunk() {
        let text = "# Week 3\n## Monday\nNothing yet.\n## Tuesday\n"
        let chunks = Chunker.chunks(ofNote: text)
        #expect(chunks.count == 1)
        #expect(chunks[0].headings == ["Week 3", "Monday"])
        #expect(chunks[0].text == "## Monday\nNothing yet.")
        expectRangesMatch(chunks, in: text)
    }

    @Test func paragraphsGatherUpToTheTarget() {
        let paragraph = String(repeating: "Words about physics. ", count: 15)  // 315 characters
        let text = Array(repeating: paragraph, count: 9).joined(separator: "\n\n")
        let chunks = Chunker.chunks(ofNote: text)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.range.length <= Chunker.targetCharacters + paragraph.utf16.count })
        expectRangesMatch(chunks, in: text)
        // Nothing but whitespace is left out between chunks.
        let letters = { (text: String) in text.filter { !$0.isWhitespace } }
        #expect(letters(chunks.map(\.text).joined()) == letters(text))
    }

    @Test func aLongParagraphIsCutAtSentenceEnds() {
        let sentence = "The quick brown fox jumps over the lazy dog again and again. "
        let text = String(repeating: sentence, count: 100)  // 6,100 characters, no blank lines
        let chunks = Chunker.chunks(ofNote: text)
        #expect(chunks.count >= 4)
        for chunk in chunks.dropLast() {
            #expect(chunk.text.hasSuffix("again."), "\(chunk.text.suffix(20))")
            #expect(chunk.range.length >= Chunker.targetCharacters / 2)
        }
        expectRangesMatch(chunks, in: text)
    }

    @Test func textWithoutSpacesIsCutWithoutSplittingACharacter() {
        let text = String(repeating: "😀", count: 2_000) + String(repeating: "あ", count: 3_000)
        let chunks = Chunker.chunks(ofNote: text)
        expectRangesMatch(chunks, in: text)
        #expect(chunks.map(\.text).joined() == text)
        #expect(!chunks.contains { $0.text.contains("\u{FFFD}") })
    }

    @Test func codeStaysWholeUpToTheMaximumAndIsCutAtLineEnds() {
        let short = "```swift\nlet a = 1\n\nlet b = 2\n```"
        let shortChunks = Chunker.chunks(ofNote: "Intro.\n\n" + short + "\n\nAfter.")
        #expect(shortChunks.count == 1)
        #expect(shortChunks[0].text.contains("let a = 1\n\nlet b = 2"))

        let long = "```\n" + String(repeating: "print(\"a line of code\")\n", count: 200) + "```"
        let longChunks = Chunker.chunks(ofNote: long)
        #expect(longChunks.count >= 3)
        for chunk in longChunks.dropLast() {
            #expect(chunk.text.hasSuffix(")") || chunk.text.hasSuffix("```"))
        }
        expectRangesMatch(longChunks, in: long)
    }

    @Test func aCodeBlockThatNeverClosesRunsToTheEnd() {
        let text = "# Notes\n```\n# not a heading\nsome code"
        let chunks = Chunker.chunks(ofNote: text)
        #expect(chunks.count == 1 && chunks[0].headings == ["Notes"])
        #expect(chunks[0].text.hasSuffix("some code"))
    }

    @Test func rightToLeftAndMixedTextKeepTheirRanges() {
        let text = "# שיעור 7\n\nמומנט כוח הוא כוח שמסובב. Torque in English.\n\n## مقدمة\n\nنص عربي هنا."
        let chunks = Chunker.chunks(ofNote: text)
        #expect(chunks.map(\.headings) == [["שיעור 7"], ["שיעור 7", "مقدمة"]])
        expectRangesMatch(chunks, in: text)
    }

    @Test func blankTextMakesNoChunks() {
        #expect(Chunker.chunks(ofNote: "").isEmpty)
        #expect(Chunker.chunks(ofNote: " \n\n\t \n").isEmpty)
        #expect(Chunker.chunks(ofPages: ["", "  \n"]).isEmpty)
    }

    @Test func pagesNeverShareAChunk() {
        let pages = ["First page text.", "", String(repeating: "A sentence on page three. ", count: 150)]
        let chunks = Chunker.chunks(ofPages: pages)
        #expect(chunks.first?.page == 1 && chunks.first?.text == "First page text.")
        #expect(!chunks.contains { $0.page == 2 })
        #expect(chunks.dropFirst().allSatisfy { $0.page == 3 })
        #expect(chunks.count >= 3)
        for chunk in chunks.dropFirst() {
            #expect((pages[2] as NSString).substring(with: chunk.range) == chunk.text)
        }
    }

    @Test func chunkingTakesLinearTime() {
        HostileInputTests.expectLinear("headings", size: 400_000, make: { String(repeating: "# h\n", count: $0 / 4) }) {
            _ = Chunker.chunks(ofNote: $0)
        }
        HostileInputTests.expectLinear("one long line", size: 2_000_000, make: { String(repeating: "x", count: $0) }) {
            _ = Chunker.chunks(ofNote: $0)
        }
        HostileInputTests.expectLinear("fences", size: 400_000, make: { String(repeating: "```\n", count: $0 / 4) }) {
            _ = Chunker.chunks(ofNote: $0)
        }
        HostileInputTests.expectLinear("sentences", size: 2_000_000, make: { String(repeating: "Ab. ", count: $0 / 4) })
        {
            _ = Chunker.chunks(ofNote: $0)
        }
    }
}
