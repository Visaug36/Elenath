import ElenathCore
import Foundation
import Testing

/// Web pages and web archives are read as text, without WebKit (docs/IMPORT.md). From the independent
/// review before 0.1.1: AppKit read them with WebKit on the main thread.
@Suite("Web pages as text")
struct HTMLTextTests {
    @Test("Headings, paragraphs, lists, breaks and entities become Markdown; scripts and styles don't")
    func basics() {
        let html = """
            <!DOCTYPE html><html><head><title>Ignored</title><style>p { color: red }</style>
            <script>alert("<p>no</p>")</script></head>
            <body><h1>Course   notes</h1><p>First <b>paragraph</b>,
            over two lines.</p><!-- a <p>comment</p> -->
            <ul><li>One</li><li>Two &amp; three</li></ul>
            <p>Line<br>break &lt;tag&gt; &#169; &#x1F600; &nbsp;end</p>
            <img src="https://example.invalid/x.png" alt="remote"><blockquote>Quoted</blockquote>
            <pre>  keep
              spacing</pre><SCRIPT type="x">hidden()</SCRIPT>
            </body></html>
            """
        #expect(
            HTMLText.markdown(fromHTML: html) == """
                # Course notes

                First paragraph, over two lines.

                - One
                - Two & three

                Line
                break <tag> © 😀 end

                > Quoted

                ```
                  keep
                  spacing
                ```

                """)
    }

    @Test("Text that only looks like markup is kept")
    func lookalikes() {
        #expect(HTMLText.markdown(fromHTML: "a < b && c > d &unknown; &#0; &") == "a < b && c > d &unknown; &#0; &\n")
        #expect(HTMLText.markdown(fromHTML: "") == "")
        #expect(HTMLText.markdown(fromHTML: "<p></p><div> </div>") == "")
    }

    @Test("A Safari web archive gives its main page's text")
    func webArchive() throws {
        let page = Data("<html><body><p>Saved page</p></body></html>".utf8)
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": page, "WebResourceMIMEType": "text/html", "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "https://example.invalid/",
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        #expect(HTMLText.markdown(fromWebArchive: data) == "Saved page\n")
        #expect(HTMLText.markdown(fromWebArchive: Data("not a plist".utf8)) == nil)
    }

    @Test("Older encodings named in the page are read")
    func encodings() {
        let latin = Data("<meta charset=\"windows-1252\"><p>Caf".utf8) + Data([0xE9]) + Data("</p>".utf8)
        #expect(HTMLText.markdown(fromHTML: latin) == "Café\n")
        var wide = Data([0xFF, 0xFE])
        wide.append("<p>Grüße</p>".data(using: .utf16LittleEndian)!)
        #expect(HTMLText.markdown(fromHTML: wide) == "Grüße\n")
    }

    @Test("Hostile pages are read in time that grows with their size")
    func hostile() {
        let cases: [(String, (Int) -> String)] = [
            ("open tags", { String(repeating: "<", count: $0) }),
            ("tag starts", { String(repeating: "<a", count: $0 / 2) }),
            ("comments", { String(repeating: "<!--", count: $0 / 4) }),
            ("scripts", { String(repeating: "<script>", count: $0 / 8) }),
            ("closed scripts", { String(repeating: "<script>x</script>", count: $0 / 18) }),
            ("quotes", { "<a title=\"" + String(repeating: "x", count: $0) }),
            ("entities", { String(repeating: "&amp", count: $0 / 4) }),
            ("paragraphs", { String(repeating: "<p>word</p>", count: $0 / 11) }),
            ("nested", { String(repeating: "<div><li><h1>", count: $0 / 13) }),
        ]
        for (name, make) in cases {
            HostileInputTests.expectLinear(name, size: 400_000, make: make) { text in
                _ = HTMLText.markdown(fromHTML: text)
            }
        }
    }
}
