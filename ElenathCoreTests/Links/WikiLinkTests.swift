import Foundation
import Testing

@testable import ElenathCore

@Suite("Wiki links")
struct WikiLinkTests {
    @Test(
        "A link is read and written back as it was",
        arguments: [
            "Title", "Folder/Title", "Space/Folder/Title", "Title|shown text", "Title#Heading", "Title#Heading|shown",
            "Title#^block", "#Heading only", "Title\\|in a table", "diagram.png|300", "Title#", "A|b|c",
        ])
    func roundTrip(inner: String) throws {
        let link = try #require(WikiLink(inner: inner, isEmbed: false))
        #expect(link.written == "[[\(inner)]]")
        let embed = try #require(WikiLink(inner: inner, isEmbed: true))
        #expect(embed.written == "![[\(inner)]]")
    }

    @Test("The parts of a link")
    func parts() throws {
        let link = try #require(WikiLink(inner: " Uni/Physics/Lecture 7.md#Summary|the summary", isEmbed: false))
        #expect(link.target == "Uni/Physics/Lecture 7.md")
        #expect(link.targetComponents == ["Uni", "Physics", "Lecture 7"])
        #expect(link.heading == "Summary")
        #expect(link.shownText == "the summary")
        #expect(link.displayText == "the summary")
        #expect(WikiLink(inner: "Title#Part", isEmbed: false)?.displayText == "Title › Part")
        #expect(WikiLink(inner: "#Part", isEmbed: false)?.displayText == "Part")
        #expect(WikiLink(inner: "Table\\|x", isEmbed: false)?.target == "Table")
        #expect(WikiLink(inner: "Table\\|x", isEmbed: false)?.escapesPipe == true)
    }

    @Test("Nothing to point at is not a link")
    func empty() {
        #expect(WikiLink(inner: "", isEmbed: false) == nil)
        #expect(WikiLink(inner: "   ", isEmbed: false) == nil)
        #expect(WikiLink(inner: "|shown", isEmbed: false) == nil)
        #expect(WikiLink(inner: "#", isEmbed: false) == nil)
    }
}
