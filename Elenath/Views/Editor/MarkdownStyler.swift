import AppKit
import ElenathCore

extension NSAttributedString.Key {
    /// The scanner's state at the end of the line a character is on, as a `BlockState`. The editor reads
    /// it to rescan from any line without starting at the top.
    static let elenathLineEndState = NSAttributedString.Key("io.github.visaug36.Elenath.lineEndState")
    /// A whole link, brackets included, as its `LinkSpan.Target`: what ⌘-click follows.
    static let elenathLink = NSAttributedString.Key("io.github.visaug36.Elenath.link")
    /// The visible part of a link, as its `LinkSpan.Target`: what is colored by where it leads.
    static let elenathLinkText = NSAttributedString.Key("io.github.visaug36.Elenath.linkText")
    /// The "[ ]" of a task, as a `Bool` that says whether it is done. The box is drawn over it.
    static let elenathTaskBox = NSAttributedString.Key("io.github.visaug36.Elenath.taskBox")
    /// A line of a fenced or indented code block. The block's background is drawn behind it.
    static let elenathCodeBlock = NSAttributedString.Key("io.github.visaug36.Elenath.codeBlock")
    /// A line of a quote. A bar is drawn at its left.
    static let elenathQuote = NSAttributedString.Key("io.github.visaug36.Elenath.quote")
    /// An embedded image or PDF, as its `EmbedKey`. The picture is drawn under its line.
    static let elenathEmbed = NSAttributedString.Key("io.github.visaug36.Elenath.embed")
}

/// What an embed points at, and how wide it may be drawn.
struct EmbedKey: Hashable, Sendable {
    /// A wiki embed's target ("photo.png") or a Markdown image's destination ("Attachments/photo.png").
    var target: String
    var isWikiLink: Bool
    /// The width written in the embed (`![[photo.png|300]]`), if any.
    var width: CGFloat?
}

/// How a link looks, from where it leads.
enum LinkLook: Equatable {
    /// A note in this space or another one that mixes: the space's color.
    case note(Space?)
    /// Nothing has that title: dashed and dim.
    case unresolved
    /// A web page or an e-mail address.
    case web
    /// A file that isn't a note.
    case file
}

/// The fonts and colors of the editor (docs/DESIGN.md, "The editor").
@MainActor
struct EditorTheme {
    let body = NSFont.systemFont(ofSize: 15)
    let code = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    let primary = NSColor(resource: .textPrimary)
    let secondary = NSColor(resource: .textSecondary)
    let tertiary = NSColor(resource: .textTertiary)
    let controlFill = NSColor(resource: .controlFill)

    /// New York semibold for headings 1 to 3, SF Pro semibold for 4 to 6.
    func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: EditorTheme.serif(22)
        case 2: EditorTheme.serif(18)
        case 3: EditorTheme.serif(15)
        default: NSFont.systemFont(ofSize: 15, weight: .semibold)
        }
    }

    /// The paragraph style of ordinary lines: 15 pt text about 1.45 lines apart, each paragraph in its
    /// own writing direction.
    func paragraph(headIndent: CGFloat = 0, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore
        style.headIndent = headIndent
        style.baseWritingDirection = .natural
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func serif(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func adding(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

/// Styles a note's text from what `MarkdownScanner` finds in it. Styling only sets attributes: it never
/// changes a character, so markers stay in the text and are only dimmed.
///
/// After an edit, only the lines from the edit on are scanned again, until a line ends in the same
/// scanner state as before: typing in a long note restyles a line or two.
@MainActor
final class MarkdownStyler {
    let theme = EditorTheme()
    /// How a link looks. Set by the editor once it knows where links lead.
    var look: (LinkSpan.Target) -> LinkLook = { _ in .note(nil) }
    /// The height an embed's picture takes under its line, or nil while there is none.
    var embedHeight: (EmbedKey) -> CGFloat? = { _ in nil }

    /// What text has before it is styled: the body font and color.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.body, .foregroundColor: theme.primary, .paragraphStyle: theme.paragraph()]
    }

    // MARK: - Whole notes

    /// Styles the whole text: when a note is opened.
    func restyleAll(_ storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        let scan = MarkdownScanner.scan(storage.string)
        storage.beginEditing()
        apply(scan, to: storage)
        storage.endEditing()
    }

    /// Styles the lines an edit touched, and the lines after them whose meaning it changed (a code fence
    /// that was opened or closed). `editedRange` is in the text as it is now.
    func restyle(_ storage: NSTextStorage, after editedRange: NSRange) {
        let text = storage.string as NSString
        let length = text.length
        guard length > 0 else { return }
        var start = Self.lineStart(at: min(editedRange.location, length), in: text)
        if start >= length, start > 0 {
            start = Self.lineStart(at: start - 1, in: text)
        }
        var state = BlockState.start
        if start > 0,
            let previous = storage.attribute(.elenathLineEndState, at: start - 1, effectiveRange: nil) as? BlockState
        {
            state = previous
        }
        let editedEnd = NSMaxRange(editedRange)
        storage.beginEditing()
        while start < length {
            let end = Self.lineEnd(from: start, in: text)
            let range = NSRange(location: start, length: end - start)
            let oldState = storage.attribute(.elenathLineEndState, at: start, effectiveRange: nil) as? BlockState
            let scan = MarkdownScanner.scanLines(text.substring(with: range), offset: start, from: state)
            apply(scan, to: storage)
            state = scan.endState
            if range.location >= editedEnd, oldState == state {
                break
            }
            start = end
        }
        storage.endEditing()
    }

    /// Colors the links again, after it changed where they lead (a note was added, renamed or deleted).
    func recolorLinks(_ storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        var runs: [(NSRange, LinkSpan.Target)] = []
        storage.enumerateAttribute(.elenathLinkText, in: whole) { value, range, _ in
            if let target = value as? LinkSpan.Target {
                runs.append((range, target))
            }
        }
        guard !runs.isEmpty else { return }
        storage.beginEditing()
        for (range, target) in runs {
            storage.addAttributes(linkAttributes(look(target)), range: range)
        }
        storage.endEditing()
    }

    // MARK: - Applying a scan

    private func apply(_ scan: MarkdownScan, to storage: NSTextStorage) {
        let text = storage.string as NSString
        var embedsByLine: [Int: EmbedKey] = [:]
        for link in scan.links {
            if let key = Self.embedKey(for: link.target) {
                embedsByLine[Self.lineStart(at: link.range.location, in: text)] = key
            }
        }
        for line in scan.lines {
            styleLine(line, in: storage, text: text, embed: embedsByLine[line.range.location])
        }
        for span in scan.spans {
            styleSpan(span, in: storage)
        }
        for link in scan.links {
            storage.addAttribute(.elenathLink, value: link.target, range: link.range)
            storage.addAttribute(.elenathLinkText, value: link.target, range: link.textRange)
            storage.addAttributes(linkAttributes(look(link.target)), range: link.textRange)
        }
        for task in scan.tasks {
            storage.addAttribute(.elenathTaskBox, value: task.isDone, range: task.boxRange)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: task.boxRange)
        }
    }

    private func styleLine(_ line: LineInfo, in storage: NSTextStorage, text: NSString, embed: EmbedKey?) {
        guard line.range.length > 0 else { return }
        var font = theme.body
        var color = theme.primary
        var headIndent: CGFloat = 0
        var spacingBefore: CGFloat = 0
        var spacingAfter: CGFloat = 0
        var extra: [NSAttributedString.Key: Any] = [:]
        switch line.kind {
        case .heading(let level):
            font = theme.heading(level)
            spacingBefore = level <= 2 ? 10 : 6
            spacingAfter = 2
        case .quote:
            color = theme.secondary
            extra[.elenathQuote] = true
        case .listItem:
            let prefixLength = max(0, line.textStart - line.range.location)
            if prefixLength > 0, prefixLength <= line.contentRange.length {
                let prefix = text.substring(with: NSRange(location: line.range.location, length: prefixLength))
                headIndent = (prefix as NSString).size(withAttributes: [.font: theme.body]).width
            }
        case .codeFence:
            font = theme.code
            color = theme.tertiary
            extra[.elenathCodeBlock] = true
        case .codeBlock:
            font = theme.code
            extra[.elenathCodeBlock] = true
        case .table:
            font = theme.code
        case .thematicBreak:
            color = theme.tertiary
        case .paragraph, .blank:
            break
        }
        if let embed {
            extra[.elenathEmbed] = embed
            if let height = embedHeight(embed) {
                spacingAfter = max(spacingAfter, height + 16)
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: theme.paragraph(
                headIndent: headIndent, spacingBefore: spacingBefore, spacingAfter: spacingAfter),
            .elenathLineEndState: line.endState,
        ]
        attributes.merge(extra) { _, new in new }
        storage.setAttributes(attributes, range: line.range)
    }

    private func styleSpan(_ span: InlineSpan, in storage: NSTextStorage) {
        let range = span.range
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        switch span.kind {
        case .marker, .linkDestination:
            storage.addAttribute(.foregroundColor, value: theme.tertiary, range: range)
        case .emphasis:
            changeFonts(in: storage, range: range) { EditorTheme.adding(.italic, to: $0) }
        case .strong:
            changeFonts(in: storage, range: range) { EditorTheme.adding(.bold, to: $0) }
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .highlight:
            storage.addAttribute(.backgroundColor, value: theme.controlFill, range: range)
        case .code:
            storage.addAttribute(.font, value: theme.code, range: range)
            storage.addAttribute(.backgroundColor, value: theme.controlFill, range: range)
        case .tag:
            storage.addAttribute(.foregroundColor, value: theme.secondary, range: range)
            storage.addAttribute(.backgroundColor, value: theme.controlFill, range: range)
        case .doneTask:
            storage.addAttribute(.foregroundColor, value: theme.tertiary, range: range)
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .link, .taskBox:
            break  // Styled from `scan.links` and `scan.tasks`.
        }
    }

    private func changeFonts(in storage: NSTextStorage, range: NSRange, _ change: (NSFont) -> NSFont) {
        var changes: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? theme.body
            changes.append((subrange, change(font)))
        }
        for (subrange, font) in changes {
            storage.addAttribute(.font, value: font, range: subrange)
        }
    }

    private func linkAttributes(_ look: LinkLook) -> [NSAttributedString.Key: Any] {
        switch look {
        case .note(let space):
            let color = space.map(SpaceStyle.nsColor(for:)) ?? theme.secondary
            return [
                .foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color.withAlphaComponent(0.5),
            ]
        case .unresolved:
            return [
                .foregroundColor: theme.tertiary,
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue,
                .underlineColor: theme.tertiary,
            ]
        case .web, .file:
            return [
                .foregroundColor: theme.secondary, .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.secondary.withAlphaComponent(0.6),
            ]
        }
    }

    // MARK: - Embeds

    /// The file endings whose pictures are drawn under their line.
    static let embeddableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "pdf",
    ]

    /// What an embed or a Markdown image shows, if it is a picture or a PDF.
    static func embedKey(for target: LinkSpan.Target) -> EmbedKey? {
        switch target {
        case .wiki(let link):
            guard link.isEmbed, isEmbeddable(link.target) else { return nil }
            let width = link.shownText.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
            return EmbedKey(target: link.target, isWikiLink: true, width: width)
        case .markdown(let destination, let isImage):
            guard isImage, isEmbeddable(destination), !destination.contains("://") else { return nil }
            return EmbedKey(target: destination, isWikiLink: false, width: nil)
        case .url:
            return nil
        }
    }

    private static func isEmbeddable(_ name: String) -> Bool {
        let ending = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return embeddableExtensions.contains(ending)
    }

    // MARK: - Lines

    /// Where the line that holds `index` starts, with the scanner's idea of a line break: LF, CR, CRLF
    /// and the paragraph separator.
    static func lineStart(at index: Int, in text: NSString) -> Int {
        var start = min(index, text.length)
        while start > 0 {
            let unit = text.character(at: start - 1)
            if unit == 0x0A || unit == 0x0D || unit == 0x2029 {
                break
            }
            start -= 1
        }
        // The LF of a CRLF belongs to the line before it.
        if start > 0, start < text.length, text.character(at: start) == 0x0A, text.character(at: start - 1) == 0x0D {
            return lineStart(at: start - 1, in: text)
        }
        return start
    }

    /// Where the next line starts: after this line's break.
    static func lineEnd(from start: Int, in text: NSString) -> Int {
        let length = text.length
        var index = start
        while index < length {
            let unit = text.character(at: index)
            if unit == 0x0A || unit == 0x2029 {
                return index + 1
            }
            if unit == 0x0D {
                return index + 1 < length && text.character(at: index + 1) == 0x0A ? index + 2 : index + 1
            }
            index += 1
        }
        return length
    }
}
