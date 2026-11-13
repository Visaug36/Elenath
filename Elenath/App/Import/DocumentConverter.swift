import AppKit
import ElenathCore
import Foundation

/// Reads a rich-text or Word document with AppKit and writes its text as Markdown: headings by their
/// size, bold and italic, and list paragraphs as they are. It is a plain reading, not a faithful
/// conversion, which is why the original is kept beside the note.
struct DocumentConverter: DocumentConverting {
    func markdown(from url: URL) throws -> String {
        let fileExtension = url.pathExtension.lowercased()
        if ["html", "htm", "webarchive"].contains(fileExtension) {
            // AppKit reads HTML with WebKit, which only works on the main thread.
            return try DispatchQueue.main.sync {
                try DocumentConverter.convert(url)
            }
        }
        return try DocumentConverter.convert(url)
    }

    private static func convert(_ url: URL) throws -> String {
        let document = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        return markdown(from: document)
    }

    /// The text of an attributed string, paragraph by paragraph.
    static func markdown(from document: NSAttributedString) -> String {
        let whole = document.string as NSString
        guard whole.length > 0 else { return "" }
        let bodySize = commonFontSize(in: document)
        var paragraphs: [String] = []
        whole.enumerateSubstrings(
            in: NSRange(location: 0, length: whole.length), options: [.byParagraphs, .substringNotRequired]
        ) { _, range, _, _ in
            paragraphs.append(paragraph(in: document, range: range, bodySize: bodySize))
        }
        // Blank paragraphs become single blank lines.
        var lines: [String] = []
        for text in paragraphs {
            if text.isEmpty, lines.last?.isEmpty ?? true {
                continue
            }
            lines.append(text)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func paragraph(in document: NSAttributedString, range: NSRange, bodySize: CGFloat) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        var largest: CGFloat = 0
        var allBold = true
        document.enumerateAttribute(.font, in: range) { value, runRange, _ in
            var text = (document.string as NSString).substring(with: runRange)
            let font = value as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            largest = max(largest, font?.pointSize ?? bodySize)
            if !traits.contains(.bold) {
                allBold = false
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, traits.contains(.bold) || traits.contains(.italic) {
                let marker = traits.contains(.bold) ? "**" : "*"
                text = text.replacingOccurrences(of: trimmed, with: marker + trimmed + marker)
            }
            result += text
        }
        let text = result.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        // A paragraph set clearly larger than the body is a heading.
        if largest >= bodySize * 1.6 {
            return "# " + plain(text)
        }
        if largest >= bodySize * 1.25 {
            return "## " + plain(text)
        }
        if largest >= bodySize * 1.1 && allBold {
            return "### " + plain(text)
        }
        // Lists arrive as "\t•\titem" or "\t1.\titem".
        let parts = text.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 2, let marker = parts.first {
            let rest = parts.dropFirst().joined(separator: " ")
            if ["•", "◦", "▪", "-", "–", "*"].contains(marker) {
                return "- " + rest
            }
            if marker.last == "." || marker.last == ")", marker.dropLast().allSatisfy(\.isNumber), marker.count > 1 {
                return String(marker.dropLast()) + ". " + rest
            }
        }
        return text
    }

    /// A heading's text without the bold markers its font would have given it.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }

    /// The font size most of the text is set in.
    private static func commonFontSize(in document: NSAttributedString) -> CGFloat {
        var lengths: [CGFloat: Int] = [:]
        document.enumerateAttribute(.font, in: NSRange(location: 0, length: document.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            lengths[size, default: 0] += range.length
        }
        return lengths.max { $0.value < $1.value }?.key ?? 12
    }
}
