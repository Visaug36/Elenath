import AppKit
import ElenathCore
import SwiftUI
import UniformTypeIdentifiers

/// The Quick Capture panel's content (docs/DESIGN.md, "Quick Capture"): the text, where it will go, the
/// files that come with it, the event the text describes when it names a date or time (⌥↩ Add to
/// Calendar), and the key hints. A note stays the default.
struct QuickCaptureView: View {
    static let width: CGFloat = 560

    @Bindable var session: QuickCaptureSession
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    /// Adds the event the text describes; true also opens it in the calendar.
    let onAddEvent: @MainActor (Bool) -> Void
    @Environment(AppModel.self) private var model
    @Environment(CalendarModel.self) private var calendar
    @State private var isDropTarget = false

    var body: some View {
        let draft = model.captureDraft(for: session.text)
        let reading = calendar.captureReading(for: session.text)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentText)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                CaptureTextField(
                    session: session, onSubmit: onSubmit, onCancel: onCancel, onAddEvent: { onAddEvent(false) }
                )
                .frame(height: session.textHeight)
                DestinationCapsule(destination: draft?.destination ?? .inbox)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, session.attachments.isEmpty ? 14 : 8)
            if !session.attachments.isEmpty {
                AttachmentChips(session: session)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
            switch reading {
            case .event(let eventDraft)?:
                CaptureEventLine(draft: eventDraft) {
                    onAddEvent(false)
                }
            case .noSubjectIn(let space)?:
                CaptureNoSubjectLine(space: calendar.spaces.first { $0.id == space })
            case nil:
                EmptyView()
            }
            footer(draft: draft)
        }
        .frame(width: Self.width)
        .raisedPanelBackground(cornerRadius: Metrics.Radius.panel)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Metrics.Radius.panel, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.dropRing)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            Task {
                let urls = await DroppedFiles.urls(from: providers)
                session.add(urls.map(CaptureAttachment.file))
            }
            return true
        }
    }

    private func footer(draft: CaptureDraft?) -> some View {
        HStack(spacing: 14) {
            if let message = session.message {
                Text(verbatim: message)
                    .foregroundStyle(Color.accentText)
            } else if case .space(_, let matched) = draft?.destination {
                Text("Space matched from “\(matched)”")
            }
            Spacer(minLength: 8)
            Text("↩ Save")
            Text("⌘↩ Save and open")
            Text("esc Close")
        }
        .font(Typography.footnote)
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
    }
}

/// The event the text describes: "Thu 10:00 · Physics Quiz · Physics", with the "⌥↩ Add to Calendar" hint.
/// The whole line is a button that adds it.
private struct CaptureEventLine: View {
    let draft: QuickAddDraft
    let onAdd: @MainActor () -> Void
    @Environment(CalendarModel.self) private var calendar

    var body: some View {
        let subject = calendar.library.subject(withID: draft.subjectID)
        Button {
            onAdd()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentText)
                    .accessibilityHidden(true)
                Text(verbatim: when)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                Text(verbatim: "·")
                    .foregroundStyle(Color.textTertiary)
                Text(verbatim: title)
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let subject {
                    Text(verbatim: "·")
                        .foregroundStyle(Color.textTertiary)
                    SubjectDot(subject: subject)
                    Text(verbatim: subject.name)
                        .font(Typography.body)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("⌥↩ Add to Calendar")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
        .accessibilityLabel(Text("Add to Calendar: \(when), \(title)\(subject.map { ", \($0.name)" } ?? "")"))
    }

    private var title: String {
        draft.title.isEmpty ? String(localized: "New Event") : draft.title
    }

    /// "Thu 10:00", or "Thu" for an all-day event.
    private var when: String {
        let zone = calendar.timeZone
        switch draft.timing {
        case .timed(let start, _, _):
            let day = CalendarDate(start, in: zone)
            return "\(EventFormatting.weekdayAbbreviation(day)) \(EventFormatting.time(start, timeZone: zone))"
        case .allDay(let start, _):
            return EventFormatting.weekdayAbbreviation(start)
        }
    }
}

/// For text meant for a sealed space where no subject lives: ⌥↩ adds nothing, since the event would have no
/// home and show everywhere.
private struct CaptureNoSubjectLine: View {
    let space: Space?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        guard let space else { return String(localized: "This can't be added to the calendar here.") }
        return String(
            localized:
                "No subject has its home in \(space.name) yet, so this can't be a sealed event there. Give a subject that home in Settings."
        )
    }
}

/// "Inbox", or the space the text starts with.
private struct DestinationCapsule: View {
    let destination: CaptureDestination
    @Environment(AppModel.self) private var model

    var body: some View {
        switch destination {
        case .inbox:
            Label("Inbox", systemImage: "tray")
                .font(Typography.footnote)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.controlFill, in: Capsule())
                .fixedSize()
        case .space(let id, _):
            let space = model.space(id)
            HStack(spacing: 5) {
                SpaceDot(space: space, size: 7)
                Text(verbatim: space?.name ?? "")
                    .lineLimit(1)
                if space?.isSealed == true {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .accessibilityLabel(Text("Sealed"))
                }
            }
            .font(Typography.footnote)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SpaceStyle.fill(for: space), in: Capsule())
            .fixedSize()
        }
    }
}

/// The files and pictures that come with a capture, each with a button to take it off.
private struct AttachmentChips: View {
    let session: QuickCaptureSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.attachments, id: \.self) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .accessibilityHidden(true)
                        Text(verbatim: attachment.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            session.remove(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove \(attachment.name)"))
                    }
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.controlFill, in: Capsule())
                }
            }
            .padding(.leading, 28)
        }
    }
}

/// The capture's text: grows from one line to eight, ↩ saves, ⇧↩ starts a new line, esc closes, and a
/// pasted picture or file becomes an attachment.
struct CaptureTextField: NSViewRepresentable {
    let session: QuickCaptureSession
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    /// ⌥↩: adds the event the text describes (when it describes one).
    var onAddEvent: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = CaptureInputView(usingTextLayoutManager: false)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = NSColor(resource: .textPrimary)
        textView.insertionPointColor = NSColor(resource: .accentText)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.unregisterDraggedTypes()
        textView.string = session.text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(String(localized: "Quick Capture"))
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.onAddEvent = onAddEvent
        textView.onPasteAttachments = { [weak session] attachments in
            session?.add(attachments)
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.onAddEvent = onAddEvent
        if textView.string != session.text {
            textView.string = session.text
            context.coordinator.measure()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: QuickCaptureSession
        weak var textView: CaptureInputView?

        init(session: QuickCaptureSession) {
            self.session = session
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            session.text = textView.string
            measure()
        }

        /// One line at least, eight at most.
        func measure() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let line = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: 15))
            let used = layoutManager.usedRect(for: container).height
            session.textHeight = min(max(used, line), line * 8).rounded(.up)
        }
    }
}

/// The text view behind `CaptureTextField`.
final class CaptureInputView: NSTextView {
    var onSubmit: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?
    var onAddEvent: (@MainActor () -> Void)?
    var onPasteAttachments: (@MainActor ([CaptureAttachment]) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if isReturn, !hasMarkedText() {
            if modifiers.isEmpty {
                onSubmit?()
                return
            }
            if modifiers == .shift {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if modifiers == .option {
                onAddEvent?()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if pasteboard.availableType(from: [.string]) == nil, let onPasteAttachments {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL], !urls.isEmpty
            {
                onPasteAttachments(urls.map(CaptureAttachment.file))
                return
            }
            if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
                let png =
                    type == .png
                    ? data : (NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data)
                let name =
                    String(localized: "Pasted image", comment: "The name of an image pasted into a note") + ".png"
                onPasteAttachments([.image(png, name: name)])
                return
            }
        }
        super.paste(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let placeholder = String(localized: "Capture a thought…")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor(resource: .textTertiary),
        ]
        placeholder.draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attributes)
    }
}
