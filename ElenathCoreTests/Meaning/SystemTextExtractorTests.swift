#if canImport(PDFKit) && canImport(Vision) && canImport(CoreText) && canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import Testing

    @testable import ElenathCore

    /// The real extractor on the Mac that runs the tests: PDFKit for PDFs, Vision for pictures and scans. The
    /// files are made here, so nothing depends on fixtures from elsewhere.
    @Suite("Reading PDFs and pictures with PDFKit and Vision")
    struct SystemTextExtractorTests {
        private let extractor = SystemTextExtractor()

        @Test("A PDF's text comes back page by page")
        func pdfPages() async throws {
            let folder = try TempFolder()
            defer { folder.remove() }
            let url = folder.child("Torque.pdf")
            try DemoFiles.pdf(pages: [["Levers and pulleys"], ["The moment of inertia of a hoop"]]).write(to: url)
            let text = try #require(try await extractor.text(of: url, kind: .pdf))
            #expect(text.isPaged)
            #expect(text.pages.count == 2)
            #expect(text.pages[0].contains("pulleys"))
            #expect(text.pages[1].contains("inertia of a hoop"))
        }

        @Test("A file that isn't a PDF gives nothing, and isn't read as a picture either")
        func notAPDF() async throws {
            let folder = try TempFolder()
            defer { folder.remove() }
            let url = folder.child("Broken.pdf")
            try Data("not a pdf at all".utf8).write(to: url)
            #expect(try await extractor.text(of: url, kind: .pdf) == nil)
            #expect(try await extractor.text(of: url, kind: .picture) == nil)
            #expect(try await extractor.text(of: url, kind: .plainText) == nil)
        }

        @Test("Text in a picture is recognized")
        func picture() async throws {
            let folder = try TempFolder()
            defer { folder.remove() }
            let url = folder.child("Whiteboard.png")
            try #require(DemoFiles.picture(lines: ["Free body diagram", "of a ladder"])).write(to: url)
            let text = try #require(try await extractor.text(of: url, kind: .picture))
            #expect(!text.isPaged)
            let words = text.pages.joined(separator: " ").lowercased()
            #expect(words.contains("ladder"), "recognized: \(words)")
            #expect(words.contains("diagram"), "recognized: \(words)")
        }

        @Test("A picture over the pixel limit is refused from its header, before it is decoded")
        func pixelLimit() throws {
            let folder = try TempFolder()
            defer { folder.remove() }
            let url = folder.child("Whiteboard.png")
            try #require(DemoFiles.picture(lines: ["Free body diagram"])).write(to: url)
            // The picture is 1,600 × 400: within a limit of a megapixel, over one of half that.
            #expect(SystemTextExtractor.decodedPicture(url, maximumPixels: 1_000_000) != nil)
            #expect(SystemTextExtractor.decodedPicture(url, maximumPixels: 500_000) == nil)
        }

        @Test("A page without text, as a scan is, is recognized")
        func scannedPage() async throws {
            let folder = try TempFolder()
            defer { folder.remove() }
            let png = try #require(DemoFiles.picture(lines: ["Scanned handout", "angular momentum"]))
            let url = folder.child("Scan.pdf")
            try Self.pdf(showing: png).write(to: url)
            let text = try #require(try await extractor.text(of: url, kind: .pdf))
            #expect(text.pages.count == 1)
            let words = text.pages[0].lowercased()
            #expect(words.contains("angular"), "recognized: \(words)")
        }

        /// A one-page PDF whose page is a picture and nothing else.
        private static func pdf(showing png: Data) throws -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            context.beginPDFPage(nil)
            let width = 540.0
            let height = width * Double(image.height) / Double(image.width)
            context.draw(image, in: CGRect(x: 36, y: 792 - 72 - height, width: width, height: height))
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
    }
#endif
