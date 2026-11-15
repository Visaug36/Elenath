import AppKit
import ElenathCore

/// The text view of the editor: TextKit 1, one centered column, with the note's header above the text
/// and its "Linked from" footer below it, all in one scrolling page.
///
/// - The text container is at most 720 pt wide and centered (`textContainerOrigin`). The header and the
///   footer are subviews placed above and below it, and the view's height makes room for them.
/// - Code block backgrounds, quote bars, task boxes and embedded pictures are drawn behind the text
///   (`drawBackground(in:)`), from attributes `MarkdownStyler` sets. Styling never changes a character.
/// - Clicking a task's box ticks it; ⌘-click or ⌘↩ follows a link.
/// - Typing "[[" offers the titles of notes (the system's completion list).
/// - Pasting a picture or dropping files from elsewhere attaches them to the note.
final class NoteTextView: NSTextView {
    static let maximumColumnWidth: CGFloat = 720
    static let topInset: CGFloat = 28
    static let bottomInset: CGFloat = 40
    static let footerGap: CGFloat = 32

    /// What happens on ⌘-click or ⌘↩ in a link, with where it was clicked (for a menu of choices).
    var onFollowLink: (@MainActor (LinkSpan.Target, NSPoint) -> Void)?
    /// Pictures pasted, or files dropped from outside the library: the editor attaches them and returns
    /// the text that refers to them.
    var onAttach:
        (
            @MainActor (_ files: [URL], _ images: [(Data, String)], _ completion: @escaping @MainActor (String) -> Void)
                -> Void
        )?
    /// A note or file of the library dropped on the text: the link to write for it, if any.
    var linkForLibraryItem: (@MainActor (URL) -> String?)?
    /// The picture to draw under an embed's line.
    var embedImage: (@MainActor (EmbedKey) -> NSImage?)?

    /// The header (title and details), above the text.
    var header: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let header {
                addSubview(header)
            }
            layoutAccessories()
        }
    }

    /// The footer ("Linked from"), below the text.
    var footer: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let footer {
                addSubview(footer)
            }
            layoutAccessories()
        }
    }

    var headerHeight: CGFloat = 0 {
        didSet {
            guard headerHeight != oldValue else { return }
            invalidateTextContainerOrigin()
            updateHeight()
        }
    }

    var footerHeight: CGFloat = 0 {
        didSet {
            guard footerHeight != oldValue else { return }
            updateHeight()
        }
    }

    // MARK: - Geometry

    override var textContainerOrigin: NSPoint {
        let width = textContainer?.size.width ?? 0
        return NSPoint(x: max(0, ((bounds.width - width) / 2).rounded()), y: Self.topInset + headerHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        size.height = max(size.height, neededHeight(forWidth: newSize.width))
        super.setFrameSize(size)
        updateColumn()
        layoutAccessories()
    }

    /// The height the header, the text and the footer take together.
    private func neededHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        let used = layoutManager.usedRect(for: textContainer).height
        return Self.topInset + headerHeight + used + Self.footerGap + footerHeight + Self.bottomInset
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        if let clip = superview {
            minSize = NSSize(width: 0, height: clip.bounds.height)
            updateHeight()
        }
    }

    /// Makes the view as tall as its content, or as the visible area, whichever is more.
    func updateHeight() {
        let height = max(minSize.height, neededHeight(forWidth: frame.width))
        if abs(frame.height - height) > 0.5 {
            super.setFrameSize(NSSize(width: frame.width, height: height))
        }
        layoutAccessories()
        needsDisplay = true
    }

    /// The column is at most 720 pt wide, with at least 40 pt (24 pt in a narrow window) at each side.
    private func updateColumn() {
        guard let textContainer else { return }
        let side: CGFloat = bounds.width < 600 ? 24 : 40
        let width = max(160, min(Self.maximumColumnWidth, bounds.width - 2 * side))
        if abs(textContainer.size.width - width) > 0.5 {
            textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            invalidateTextContainerOrigin()
        }
    }

    /// Places the header above the text and the footer at the bottom.
    func layoutAccessories() {
        let width = textContainer?.size.width ?? 0
        let x = textContainerOrigin.x
        header?.frame = NSRect(x: x, y: Self.topInset, width: width, height: headerHeight)
        let footerY = frame.height - Self.bottomInset - footerHeight
        footer?.frame = NSRect(x: x, y: max(footerY, textContainerOrigin.y), width: width, height: footerHeight)
    }

    // MARK: - Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        // Pictures hang below their line, so look a little above the area being drawn too.
        let area = rect.insetBy(dx: 0, dy: -600).offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: area, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0 else { return }
        drawCodeBlocks(in: characters, layoutManager: layoutManager, storage: storage, origin: origin)
        drawQuoteBars(in: characters, layoutManager: layoutManager, storage: storage, origin: origin)
        drawTaskBoxes(in: characters, layoutManager: layoutManager, storage: storage, origin: origin)
        drawEmbeds(in: characters, layoutManager: layoutManager, storage: storage, origin: origin)
    }

    /// The union of the line fragments of a range, in view coordinates.
    private func lineFragments(of range: NSRange, layoutManager: NSLayoutManager, origin: NSPoint) -> NSRect {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var box = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            box = box.union(used)
        }
        guard !box.isNull else { return box }
        return box.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func drawCodeBlocks(
        in range: NSRange, layoutManager: NSLayoutManager, storage: NSTextStorage, origin: NSPoint
    ) {
        let width = textContainer?.size.width ?? 0
        storage.enumerateAttribute(.elenathCodeBlock, in: range) { value, run, _ in
            guard value != nil else { return }
            var box = lineFragments(of: run, layoutManager: layoutManager, origin: origin)
            guard !box.isNull else { return }
            box.origin.x = origin.x - 10
            box.size.width = width + 20
            box = box.insetBy(dx: 0, dy: -5)
            NSColor(resource: .controlFill).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        }
    }

    private func drawQuoteBars(
        in range: NSRange, layoutManager: NSLayoutManager, storage: NSTextStorage, origin: NSPoint
    ) {
        storage.enumerateAttribute(.elenathQuote, in: range) { value, run, _ in
            guard value != nil else { return }
            let box = lineFragments(of: run, layoutManager: layoutManager, origin: origin)
            guard !box.isNull else { return }
            let bar = NSRect(x: origin.x - 12, y: box.minY + 2, width: 2, height: max(0, box.height - 4))
            NSColor(resource: .textTertiary).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawTaskBoxes(
        in range: NSRange, layoutManager: NSLayoutManager, storage: NSTextStorage, origin: NSPoint
    ) {
        storage.enumerateAttribute(.elenathTaskBox, in: range) { value, run, _ in
            guard let isDone = value as? Bool,
                let box = taskBoxRect(for: run, layoutManager: layoutManager, origin: origin)
            else { return }
            let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
            if isDone {
                NSColor(resource: .textTertiary).setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
                check.line(to: NSPoint(x: box.minX + 6, y: box.maxY - 3.5))
                check.line(to: NSPoint(x: box.maxX - 3, y: box.minY + 3.5))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor(resource: .backgroundWindow).setStroke()
                check.stroke()
            } else {
                path.lineWidth = 1.2
                NSColor(resource: .textSecondary).setStroke()
                path.stroke()
            }
        }
    }

    /// The 14 pt box drawn over a task's "[ ]", centered on the characters it replaces.
    private func taskBoxRect(for range: NSRange, layoutManager: NSLayoutManager, origin: NSPoint) -> NSRect? {
        guard let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = line.minY + layoutManager.location(forGlyphAt: glyphs.location).y
        let font =
            (textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            ?? NSFont.systemFont(ofSize: 15)
        let side: CGFloat = 14
        let centerY = baseline - font.capHeight / 2
        return NSRect(
            x: origin.x + bounds.midX - side / 2, y: origin.y + centerY - side / 2, width: side, height: side)
    }

    private func drawEmbeds(in range: NSRange, layoutManager: NSLayoutManager, storage: NSTextStorage, origin: NSPoint)
    {
        storage.enumerateAttribute(.elenathEmbed, in: range) { value, run, _ in
            guard let key = value as? EmbedKey, let image = embedImage?(key) else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let lastGlyph = NSMaxRange(glyphs) - 1
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let size = Self.drawnSize(of: image, key: key, columnWidth: textContainer?.size.width ?? 0)
            let frame = NSRect(x: origin.x, y: origin.y + used.maxY + 8, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The size a picture is drawn at: its own size, or the width the embed asks for, never wider than
    /// the column and never taller than 480 pt.
    static func drawnSize(of image: NSImage, key: EmbedKey, columnWidth: CGFloat) -> NSSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return .zero }
        var width = min(key.width ?? natural.width, columnWidth)
        var height = width * natural.height / natural.width
        if height > 480 {
            height = 480
            width = height * natural.width / natural.height
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    // MARK: - Clicks

    /// The character drawn at a point in the view, if one is.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: -2).contains(inContainer) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point), let storage = textStorage {
            var boxRange = NSRange()
            if isEditable,
                let isDone = storage.attribute(.elenathTaskBox, at: index, effectiveRange: &boxRange) as? Bool
            {
                toggleTask(boxRange: boxRange, isDone: isDone)
                return
            }
            if event.modifierFlags.contains(.command),
                let target = storage.attribute(.elenathLink, at: index, effectiveRange: nil) as? LinkSpan.Target
            {
                onFollowLink?(target, point)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Ticks or unticks a task by changing the one character between its brackets, as an edit that can
    /// be undone.
    private func toggleTask(boxRange: NSRange, isDone: Bool) {
        let mark = NSRange(location: boxRange.location + 1, length: 1)
        let selection = selectedRanges
        insertText(isDone ? " " : "x", replacementRange: mark)
        selectedRanges = selection
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if window?.firstResponder === self, modifiers == .command, isReturn {
            let caret = selectedRange().location
            let index = caret > 0 && caret == textStorage?.length ? caret - 1 : caret
            if let storage = textStorage, index < storage.length,
                let target = storage.attribute(.elenathLink, at: index, effectiveRange: nil) as? LinkSpan.Target
            {
                let point = firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
                onFollowLink?(target, convert(window?.convertFromScreen(point).origin ?? .zero, from: nil))
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Completing links

    /// The text typed after an unclosed "[[" before the caret, on the same line.
    func openLinkRange() -> NSRange? {
        let caret = selectedRange()
        guard caret.length == 0 else { return nil }
        let text = string as NSString
        var index = caret.location
        var steps = 0
        while index >= 2, steps < 200 {
            let unit = text.character(at: index - 1)
            if unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x5D || unit == 0x7C || unit == 0x23 {
                return nil  // a line break, "]", "|" or "#": not a title being typed
            }
            if unit == 0x5B, text.character(at: index - 2) == 0x5B {
                return NSRange(location: index, length: caret.location - index)
            }
            index -= 1
            steps += 1
        }
        return nil
    }

    override var rangeForUserCompletion: NSRange {
        openLinkRange() ?? NSRange(location: NSNotFound, length: 0)
    }

    override func insertCompletion(
        _ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool
    ) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard flag, movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue else {
            return
        }
        // Close the link the title was chosen for.
        let text = string as NSString
        let end = charRange.location + (word as NSString).length
        let closed = end + 2 <= text.length && text.substring(with: NSRange(location: end, length: 2)) == "]]"
        if closed {
            setSelectedRange(NSRange(location: end + 2, length: 0))
        } else {
            insertText("]]", replacementRange: NSRange(location: end, length: 0))
        }
    }

    // MARK: - Pasting and dropping

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let hasText = pasteboard.availableType(from: [.string]) != nil
        if !hasText, isEditable, let onAttach {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL],
                !urls.isEmpty
            {
                attach(files: urls, images: [], using: onAttach)
                return
            }
            if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
                let png =
                    type == .png
                    ? data : (NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data)
                let name =
                    String(localized: "Pasted image", comment: "The name of an image pasted into a note") + ".png"
                attach(files: [], images: [(png, name)], using: onAttach)
                return
            }
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard isEditable,
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL],
            !urls.isEmpty
        else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: min(index, textStorage?.length ?? 0), length: 0))
        var outside: [URL] = []
        var links: [String] = []
        for url in urls {
            if let link = linkForLibraryItem?(url) {
                links.append(link)
            } else {
                outside.append(url)
            }
        }
        if !links.isEmpty {
            insertText(links.joined(separator: " "), replacementRange: selectedRange())
        }
        if !outside.isEmpty, let onAttach {
            attach(files: outside, images: [], using: onAttach)
        }
        return true
    }

    private func attach(
        files: [URL], images: [(Data, String)],
        using onAttach: @MainActor ([URL], [(Data, String)], @escaping @MainActor (String) -> Void) -> Void
    ) {
        let insertion = selectedRange()
        onAttach(files, images) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let length = textStorage?.length ?? 0
            let range = NSRange(location: min(insertion.location, length), length: 0)
            insertText(text, replacementRange: range)
        }
    }
}
