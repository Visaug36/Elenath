import ElenathCore
import Foundation

/// Reads the "PDFs" and "pictures" tests write, deterministically on every machine:
///
/// - a PDF is "%PDF" on its first line, then its pages separated by form feeds (U+000C);
/// - a picture is "PNG" on its first line, then its text.
///
/// Anything else can't be read (nil). It remembers which files it was asked about, can hang on some like a
/// PDFKit call that never returns (it doesn't notice cancellation), and can run something while reading.
final class FakeTextExtractor: TextExtractor, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var hanging: Set<String>
    private let whileReading: (@Sendable (URL) -> Void)?

    init(hanging: Set<String> = [], whileReading: (@Sendable (URL) -> Void)? = nil) {
        self.hanging = hanging
        self.whileReading = whileReading
    }

    /// The names of the files it was asked about, in order.
    var askedNames: [String] {
        lock.withLock { asked }
    }

    func stopHanging() {
        lock.withLock { hanging = [] }
    }

    func text(of url: URL, kind: FileTextKind) async throws -> ExtractedText? {
        let name = url.lastPathComponent
        let hangs = lock.withLock { () -> Bool in
            asked.append(name)
            return hanging.contains(name)
        }
        if hangs {
            // Ignores cancellation, as a synchronous framework call would, and gives up after a while.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume() }
            }
            return nil
        }
        whileReading?(url)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        let body = String(text.drop { $0 != "\n" }.dropFirst())
        switch kind {
        case .pdf:
            guard text.hasPrefix("%PDF") else { return nil }
            return ExtractedText(
                pages: body.split(separator: "\u{0C}", omittingEmptySubsequences: false).map(String.init), isPaged: true
            )
        case .picture:
            guard text.hasPrefix("PNG") else { return nil }
            return ExtractedText(pages: [body], isPaged: false)
        case .plainText:
            return nil
        }
    }

    /// A "PDF" of these pages, as the fake reads it.
    static func pdf(_ pages: String...) -> String {
        "%PDF\n" + pages.joined(separator: "\u{0C}")
    }

    /// A "picture" holding this text, as the fake reads it.
    static func picture(_ text: String) -> String {
        "PNG\n" + text
    }
}
