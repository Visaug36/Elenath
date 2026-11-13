import AppKit
import ElenathCore
import ImageIO
import PDFKit
import SwiftUI

/// The editor's text view, wrapped for SwiftUI.
struct MarkdownEditor: NSViewRepresentable {
    let session: EditorSession
    let model: AppModel
    /// Goes up when the text view must show `session.bodyToShow`.
    let bodyGeneration: Int
    /// Goes up when notes changed somewhere: links and backlinks are looked up again.
    let contentRevision: Int
    let isReadOnly: Bool
    let noteRef: NoteRef

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(session: session, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            bodyGeneration: bodyGeneration, contentRevision: contentRevision, isReadOnly: isReadOnly, noteRef: noteRef)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: EditorCoordinator) {
        coordinator.detach()
    }
}

/// Runs one open note's text view: loads the text, styles it as it is typed, saves through the session,
/// follows links, completes "[[", attaches pasted and dropped files, and draws embedded pictures.
///
/// Typing has an undo history of its own, per note, so undoing can never reach into a note that is no
/// longer open.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let session: EditorSession
    let model: AppModel
    let styler = MarkdownStyler()
    private(set) var textView: NoteTextView?
    private var headerHost: NSHostingView<AnyView>?
    private var footerHost: NSHostingView<AnyView>?
    private var shownGeneration = -1
    private var shownRevision = -1
    private var shownRef: NoteRef?
    /// What changed in the text since the last restyle.
    private var pendingEdit: NSRange?
    private var linkContext: LinkContext?
    private var linkContextTask: Task<Void, Never>?
    private let textUndoManager = UndoManager()
    private var embeds: [EmbedKey: EmbedState] = [:]
    private var isCompleting = false

    private enum EmbedState {
        case loading
        case loaded(NSImage)
        case missing
    }

    init(session: EditorSession, model: AppModel) {
        self.session = session
        self.model = model
        super.init()
        styler.look = { [weak self] target in
            self?.look(of: target) ?? .note(nil)
        }
        styler.embedHeight = { [weak self] key in
            self?.embedHeight(for: key)
        }
    }

    // MARK: - Setting up

    func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(resource: .backgroundWindow)
        scrollView.findBarPosition = .aboveContent

        let textView = NoteTextView(usingTextLayoutManager: false)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(resource: .backgroundWindow)
        textView.insertionPointColor = NSColor(resource: .accentText)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(resource: .accentSoft)]
        textView.typingAttributes = styler.baseAttributes
        textView.setAccessibilityLabel(String(localized: "Note text"))
        textView.delegate = self
        textView.textStorage?.delegate = self

        textView.onFollowLink = { [weak self] target, point in
            self?.follow(target, at: point)
        }
        textView.onAttach = { [weak self] files, images, completion in
            guard let self else { return }
            let note = session.ref
            Task {
                let text = await self.model.attach(files: files, images: images, to: note)
                completion(text)
            }
        }
        textView.linkForLibraryItem = { [weak self] url in
            self?.libraryLink(for: url)
        }
        textView.embedImage = { [weak self] key in
            self?.loadedImage(for: key)
        }

        let header = NSHostingView(rootView: headerView())
        header.sizingOptions = []
        textView.headerHeight = NoteHeaderView.height
        textView.header = header
        headerHost = header

        let footer = NSHostingView(rootView: footerView())
        footer.sizingOptions = []
        textView.footer = footer
        footerHost = footer

        scrollView.documentView = textView
        self.textView = textView
        return scrollView
    }

    func update(bodyGeneration: Int, contentRevision: Int, isReadOnly: Bool, noteRef: NoteRef) {
        guard let textView else { return }
        textView.isEditable = !isReadOnly
        if bodyGeneration != shownGeneration {
            shownGeneration = bodyGeneration
            showBody()
        }
        if contentRevision != shownRevision || noteRef != shownRef {
            shownRevision = contentRevision
            shownRef = noteRef
            footerHost?.rootView = footerView()
            refreshLinkContext()
        }
    }

    func detach() {
        linkContextTask?.cancel()
        textUndoManager.removeAllActions()
        session.currentBody = nil
        textView?.delegate = nil
        textView?.textStorage?.delegate = nil
    }

    private func headerView() -> AnyView {
        AnyView(
            NoteHeaderView(session: session) { [weak self] in
                self?.focusText()
            }
            .environment(model)
            .environment(model.settings))
    }

    private func footerView() -> AnyView {
        let report: @MainActor (CGFloat) -> Void = { [weak self] height in
            self?.textView?.footerHeight = height
        }
        return AnyView(
            BacklinksView(note: session.ref, revision: model.contentRevision, onHeightChange: report)
                .environment(model))
    }

    // MARK: - The text

    /// Puts the session's text into the text view and styles it.
    private func showBody() {
        guard let textView, let storage = textView.textStorage else { return }
        let previousSelection = textView.selectedRange()
        let hadText = storage.length > 0
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: session.bodyToShow, attributes: styler.baseAttributes))
        storage.endEditing()
        pendingEdit = nil
        styler.restyleAll(storage)
        textUndoManager.removeAllActions()
        session.currentBody = { [weak textView] in
            textView?.string ?? ""
        }
        let length = storage.length
        if !model.pendingHighlight.isEmpty {
            highlight(model.pendingHighlight)
            model.pendingHighlight = []
        } else if hadText {
            let location = min(previousSelection.location, length)
            textView.setSelectedRange(
                NSRange(location: location, length: min(previousSelection.length, length - location)))
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.updateHeight()
    }

    /// Selects the first place one of `terms` appears, and shows it.
    private func highlight(_ terms: [String]) {
        guard let textView else { return }
        let text = textView.string as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let found = terms.map { text.range(of: $0, options: options) }.filter { $0.location != NSNotFound }
        guard let first = found.min(by: { $0.location < $1.location }) else { return }
        textView.setSelectedRange(first)
        textView.scrollRangeToVisible(first)
        DispatchQueue.main.async { [weak textView] in
            textView?.showFindIndicator(for: first)
        }
    }

    private func focusText() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Text view delegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        textUndoManager
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            recordEdit(editedRange)
        }
    }

    private func recordEdit(_ range: NSRange) {
        if let pending = pendingEdit {
            pendingEdit = NSUnionRange(pending, range)
        } else {
            pendingEdit = range
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView, let storage = textView.textStorage else { return }
        if let edit = pendingEdit {
            pendingEdit = nil
            let location = min(edit.location, storage.length)
            let length = min(edit.length, storage.length - location)
            styler.restyle(storage, after: NSRange(location: location, length: length))
        }
        session.textDidChange()
        offerLinkCompletion()
    }

    func textView(
        _ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        guard let context = linkContext else { return [] }
        let partial = (textView.string as NSString).substring(with: charRange)
        let targets = LinkCompletion.targets(matching: partial, from: session.ref, context: context, limit: 20)
        if !targets.isEmpty {
            index?.pointee = 0
        }
        return targets
    }

    /// Typing "[[" opens the list of note titles.
    private func offerLinkCompletion() {
        guard !isCompleting, linkContext != nil, let textView, let range = textView.openLinkRange(), range.length == 0
        else { return }
        isCompleting = true
        textView.complete(nil)
        isCompleting = false
    }

    // MARK: - Links

    private func refreshLinkContext() {
        guard let services = model.services else { return }
        let container = session.ref.container
        linkContextTask?.cancel()
        linkContextTask = Task {
            guard let context = try? await services.retrieval.linkContext(for: container), !Task.isCancelled else {
                return
            }
            linkContext = context
            if let storage = textView?.textStorage {
                styler.recolorLinks(storage)
            }
        }
    }

    private func look(of target: LinkSpan.Target) -> LinkLook {
        let source = session.ref
        let here = model.space(of: source.container)
        switch target {
        case .url:
            return .web
        case .wiki(let link):
            if LinkCompletion.isFileName(link.target) {
                return .file
            }
            if link.target.isEmpty {
                return .note(here)
            }
            guard let context = linkContext else { return .note(here) }
            switch context.resolver.resolve(link, from: source) {
            case .resolved(let note): return .note(model.space(of: note.container))
            case .ambiguous: return .note(here)
            case .unresolved: return .unresolved
            }
        case .markdown(let destination, _):
            if LinkCompletion.hasScheme(destination) {
                return .web
            }
            guard let context = linkContext else { return .note(here) }
            if case .resolved(let note) = context.resolver.resolve(markdownDestination: destination, from: source) {
                return .note(model.space(of: note.container))
            }
            return .file
        }
    }

    /// ⌘-click or ⌘↩ on a link.
    private func follow(_ target: LinkSpan.Target, at point: NSPoint) {
        let source = session.ref
        switch target {
        case .url(let address):
            openWeb(address)
        case .wiki(let link):
            if LinkCompletion.isFileName(link.target) {
                openFile(EmbedKey(target: link.target, isWikiLink: true, width: nil))
                return
            }
            if link.target.isEmpty {
                jumpToHeading(link.heading)
                return
            }
            guard let context = linkContext else { return }
            switch context.resolver.resolve(link, from: source) {
            case .resolved(let note):
                if note == source {
                    jumpToHeading(link.heading)
                } else {
                    model.open(note)
                }
            case .ambiguous(let notes):
                showChoices(notes, at: point)
            case .unresolved:
                offerToCreate(link)
            }
        case .markdown(let destination, _):
            if LinkCompletion.hasScheme(destination) {
                openWeb(destination)
                return
            }
            if let context = linkContext,
                case .resolved(let note) = context.resolver.resolve(markdownDestination: destination, from: source)
            {
                model.open(note)
                return
            }
            openFile(EmbedKey(target: destination, isWikiLink: false, width: nil))
        }
    }

    /// Web pages and e-mail open in the apps the Mac uses for them. Elenath itself never goes online.
    private func openWeb(_ address: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
            let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
        else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openFile(_ key: EmbedKey) {
        let note = session.ref
        Task {
            guard let url = await model.embedURL(for: key, from: note) else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    private func jumpToHeading(_ heading: String?) {
        guard let textView, let heading = heading?.trimmingCharacters(in: .whitespaces), !heading.isEmpty else {
            return
        }
        let key = NameSanitizer.key(heading)
        guard
            let match = MarkdownScanner.scan(textView.string).headings.first(where: {
                NameSanitizer.key($0.text) == key
            })
        else {
            NSSound.beep()
            return
        }
        textView.setSelectedRange(NSRange(location: match.range.location, length: 0))
        textView.scrollRangeToVisible(match.range)
        textView.showFindIndicator(for: match.range)
    }

    /// A link that fits several notes: a menu to choose one.
    private func showChoices(_ notes: [NoteRef], at point: NSPoint) {
        guard let textView else { return }
        let menu = NSMenu()
        for note in notes {
            let item = ActionMenuItem(title: "\(note.title) — \(model.placeName(note.container, note.path.folder))") {
                [weak self] in
                self?.model.open(note)
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: textView)
    }

    /// A link to a note that doesn't exist yet: offers to make it, beside this one.
    private func offerToCreate(_ link: WikiLink) {
        guard let title = link.targetComponents.last, model.canEdit(session.ref.container) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "There's no note called “\(title)” yet.")
        alert.informativeText = String(localized: "Create it next to this note?")
        alert.addButton(withTitle: String(localized: "Create Note"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.newNote(titled: title, in: session.ref.container, folder: session.ref.path.folder)
    }

    /// The link to write for a note of the library dropped on the text. Nil for anything else.
    private func libraryLink(for url: URL) -> String? {
        guard let item = model.libraryItem(at: url), ItemPath.isNoteFileName(item.path.name) else { return nil }
        let note = NoteRef(container: item.container, path: item.path)
        guard let context = linkContext, context.catalog.contains(note) else { return nil }
        return "[[\(context.resolver.shortestTarget(for: note, from: session.ref))]]"
    }

    // MARK: - Embedded pictures

    private func loadedImage(for key: EmbedKey) -> NSImage? {
        if case .loaded(let image) = embeds[key] {
            return image
        }
        return nil
    }

    /// The height a picture takes under its line. Starts loading it the first time it is asked for.
    private func embedHeight(for key: EmbedKey) -> CGFloat? {
        switch embeds[key] {
        case .loaded(let image):
            let width = textView?.textContainer?.size.width ?? NoteTextView.maximumColumnWidth
            return NoteTextView.drawnSize(of: image, key: key, columnWidth: width).height
        case .loading, .missing:
            return nil
        case nil:
            embeds[key] = .loading
            let note = session.ref
            Task {
                guard let url = await model.embedURL(for: key, from: note) else {
                    embeds[key] = .missing
                    return
                }
                let thumbnail = await Task.detached(priority: .utility) {
                    EmbedThumbnail.make(from: url, maximumPixelSize: 1600)
                }.value
                guard let thumbnail else {
                    embeds[key] = .missing
                    return
                }
                embeds[key] = .loaded(NSImage(cgImage: thumbnail.image, size: thumbnail.pointSize))
                restyleLines(showing: key)
            }
            return nil
        }
    }

    /// Styles the lines with an embed again, now that its picture has a size.
    private func restyleLines(showing key: EmbedKey) {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.elenathEmbed, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let found = value as? EmbedKey, found == key {
                ranges.append(range)
            }
        }
        for range in ranges.reversed() {
            styler.restyle(storage, after: NSRange(location: range.location, length: 0))
        }
        textView.updateHeight()
    }
}

/// A picture made small enough to draw quickly: images through ImageIO, PDFs by their first page.
struct EmbedThumbnail: @unchecked Sendable {
    let image: CGImage
    /// The size to draw it at, in points (the pixels are for a Retina screen).
    let pointSize: NSSize

    static func make(from url: URL, maximumPixelSize: Int) -> EmbedThumbnail? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = min(2, CGFloat(maximumPixelSize) / max(bounds.width, bounds.height))
            let picture = page.thumbnail(
                of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return EmbedThumbnail(image: image, pointSize: NSSize(width: bounds.width, height: bounds.height))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return EmbedThumbnail(
            image: image, pointSize: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}

/// Titles to offer after "[[": the notes the link could reach, those whose title starts with what was
/// typed first, each written in the shortest form that resolves to it.
enum LinkCompletion {
    static func targets(matching partial: String, from source: NoteRef, context: LinkContext, limit: Int) -> [String] {
        let key = NameSanitizer.key(partial.trimmingCharacters(in: .whitespaces))
        var candidates: [(rank: Int, note: NoteRef)] = []
        for note in context.catalog.notes where note != source {
            let title = NameSanitizer.key(note.title)
            if key.isEmpty {
                candidates.append((1, note))
            } else if title.hasPrefix(key) {
                candidates.append((0, note))
            } else if title.contains(key) {
                candidates.append((1, note))
            }
        }
        candidates.sort { first, second in
            if first.rank != second.rank {
                return first.rank < second.rank
            }
            return first.note.title.localizedStandardCompare(second.note.title) == .orderedAscending
        }
        let resolver = context.resolver
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates.prefix(limit * 2) {
            let target = resolver.shortestTarget(for: candidate.note, from: source)
            if seen.insert(target).inserted {
                result.append(target)
            }
            if result.count == limit {
                break
            }
        }
        return result
    }

    /// Whether a link names a file that isn't a note: it ends in an extension other than a note's.
    static func isFileName(_ target: String) -> Bool {
        guard let last = target.split(separator: "/").last, let dot = last.lastIndex(of: ".") else { return false }
        let ending = last[last.index(after: dot)...].lowercased()
        guard (1...5).contains(ending.count), ending.contains(where: \.isLetter),
            ending.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return false }
        return ending != "md" && ending != "markdown"
    }

    /// Whether a Markdown destination is an address with a scheme ("https:", "mailto:").
    static func hasScheme(_ destination: String) -> Bool {
        guard let colon = destination.firstIndex(of: ":") else { return false }
        let scheme = destination[..<colon]
        return !scheme.isEmpty && !scheme.contains("/")
            && scheme.allSatisfy { $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        MainActor.assumeIsolated {
            handler()
        }
    }
}
