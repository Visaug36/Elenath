import AppKit
import ElenathCore
import SwiftUI

/// Shows and hides the Quick Capture panel, from the global shortcut (⌥⇧Space by default), the menu bar
/// and File › Quick Capture (from Ithil's Quick Add panel).
///
/// The panel floats above every app and space without activating Elenath, so capturing doesn't pull the
/// user out of what they were doing. It opens in the upper part of the screen the pointer is on. ↩ saves
/// to the Inbox (or to the space the text starts with), ⌘↩ saves and opens the note, esc closes. Text
/// that wasn't saved is still there the next time.
@MainActor
final class QuickCapturePanelController {
    static let shared = QuickCapturePanelController()

    private var panel: QuickCapturePanel?
    /// Kept between openings, so closing with esc doesn't lose what was typed.
    private var session: QuickCaptureSession?
    private weak var model: AppModel?
    /// Elenath's key window when the panel opened, to give the keyboard back to on close.
    private weak var previousKeyWindow: NSWindow?

    private init() {}

    var isShown: Bool {
        panel?.isVisible ?? false
    }

    func toggle(model: AppModel) {
        if isShown {
            close()
        } else {
            show(model: model)
        }
    }

    /// Shows the panel. `text` fills the field (for `-demo` screenshot scenes).
    func show(model: AppModel, text: String? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let app = NSApplication.shared
        if app.isActive, let keyWindow = app.keyWindow, keyWindow !== panel {
            previousKeyWindow = keyWindow
        }
        if session == nil || self.model !== model {
            session = QuickCaptureSession()
        }
        self.model = model
        guard let session else { return }
        if let text {
            session.text = text
        }
        session.message = nil
        panel.onCommandReturn = { [weak self] in
            self?.submit(openingNote: true)
        }
        let root = QuickCaptureView(
            session: session,
            onSubmit: { [weak self] in self?.submit(openingNote: false) },
            onCancel: { [weak self] in self?.close() }
        )
        .environment(model)
        .environment(model.settings)
        let hostingView = NSHostingView(rootView: root)
        panel.makeFirstResponder(nil)
        panel.contentView = hostingView
        resize(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        session.onSizeChange = { [weak self, weak panel] in
            guard let panel else { return }
            self?.resize(panel)
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        let previous = previousKeyWindow
        previousKeyWindow = nil
        if NSApplication.shared.isActive, let previous, previous.isVisible {
            previous.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Saving

    private func submit(openingNote: Bool) {
        guard let session, let model, !session.isSaving else { return }
        let text = session.text
        let attachments = session.attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        guard model.state == .ready else {
            session.message = String(localized: "Open your library in Elenath first. Your text is kept.")
            NSSound.beep()
            return
        }
        session.isSaving = true
        Task {
            defer { session.isSaving = false }
            do {
                let note = try await model.capture(text, attachments: attachments)
                session.reset()
                close()
                if openingNote {
                    revealMainWindow()
                    model.open(note)
                }
            } catch {
                session.message = LibraryMessages.operationFailed(error)
                NSSound.beep()
            }
        }
    }

    private func revealMainWindow() {
        let app = NSApplication.shared
        app.activate()
        let windows = app.windows.filter { window in
            !(window is NSPanel) && window.canBecomeMain && (window.isVisible || window.isMiniaturized)
        }
        guard let window = windows.first(where: { !Self.isSettingsWindow($0) }) ?? windows.first else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false
    }

    // MARK: - The panel

    /// Fits the panel to its content, keeping its top where it is.
    private func resize(_ panel: NSPanel) {
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        if panel.isVisible {
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
        } else {
            panel.setContentSize(size)
            panel.setFrameOrigin(origin(for: size))
        }
    }

    /// Centered horizontally, a quarter of the way down the visible part of the screen with the pointer.
    private func origin(for size: NSSize) -> NSPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        let x = visible.midX - size.width / 2
        let centerY = visible.maxY - visible.height / 4
        let y = min(visible.maxY - size.height, centerY - size.height / 2)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickCaptureView.width, height: 150),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: true)
        panel.title = String(localized: "Quick Capture")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in
            self?.close()
        }
        panel.onResignKey = { [weak self] in
            self?.close()
        }
        return panel
    }
}

/// The Quick Capture window: a floating panel that takes the keyboard without activating Elenath. It
/// closes on esc and on a click elsewhere, and reports ⌘↩ before the text sees it.
final class QuickCapturePanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?
    var onCommandReturn: (@MainActor () -> Void)?
    var onResignKey: (@MainActor () -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
            event.keyCode == 36 || event.keyCode == 76, let onCommandReturn
        {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One capture being written: its text, the files and pictures that come with it, and what the panel
/// says.
@Observable @MainActor
final class QuickCaptureSession {
    var text = "" {
        didSet {
            if text != oldValue {
                message = nil
            }
        }
    }
    var attachments: [CaptureAttachment] = []
    var isSaving = false
    /// A problem to show in the footer.
    var message: String?
    /// How tall the text is, in points: the panel grows with it.
    var textHeight: CGFloat = 22 {
        didSet {
            if textHeight != oldValue {
                onSizeChange?()
            }
        }
    }
    @ObservationIgnored var onSizeChange: (@MainActor () -> Void)?

    func add(_ new: [CaptureAttachment]) {
        for attachment in new where !attachments.contains(attachment) {
            attachments.append(attachment)
        }
        onSizeChange?()
    }

    func remove(_ attachment: CaptureAttachment) {
        attachments.removeAll { $0 == attachment }
        onSizeChange?()
    }

    func reset() {
        text = ""
        attachments = []
        message = nil
        textHeight = 22
    }
}
