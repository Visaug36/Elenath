import AppKit
import Observation
import SwiftUI

/// A shortcut field: shows the shortcut ("⌥Space", or "Off"). Click it, then press the new keys.
///
/// While it records, Elenath's own key presses go to the recorder (an `NSEvent` local monitor, so nothing
/// typed in other apps is ever seen): a press with ⌘, ⌥ or ⌃ becomes the shortcut, unless one of Elenath's
/// menu items has it (⌘Q, ⌘W…, which it would take from every app). Esc cancels, ⌫ turns the shortcut off,
/// Tab cancels and moves on, anything else beeps. Clicking the field again, closing the window or switching
/// to another window or app cancels too. `onRecordingChange` says when recording starts and ends, so the
/// global hotkey can step aside meanwhile and the current shortcut can be typed again.
struct HotKeyRecorder: View {
    @Binding private var combo: HotKeyCombo?
    private let title: Text
    private let onRecordingChange: @MainActor (Bool) -> Void
    @State private var recording = KeyRecording()

    /// `title` is what VoiceOver calls the field, e.g. "Quick Capture shortcut".
    init(
        _ title: Text,
        combo: Binding<HotKeyCombo?>,
        onRecordingChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.title = title
        _combo = combo
        self.onRecordingChange = onRecordingChange
    }

    var body: some View {
        Button(action: toggleRecording) {
            HotKeyRecorderField(combo: combo, isRecording: recording.isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .onDisappear {
            finishRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            finishRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            finishRecording()
        }
    }

    private var accessibilityValue: Text {
        if recording.isActive {
            return Text("Recording")
        }
        guard let combo else { return Text("Off") }
        return Text(verbatim: combo.displayString)
    }

    private var accessibilityHint: Text {
        if recording.isActive {
            return Text("Press the new shortcut. Escape cancels, Delete turns the shortcut off.")
        }
        return Text("Records a new shortcut")
    }

    private func toggleRecording() {
        if recording.isActive {
            finishRecording()
        } else {
            recording.start { event in
                handle(event)
            }
            onRecordingChange(true)
        }
    }

    private func finishRecording() {
        guard recording.isActive else { return }
        recording.stop()
        onRecordingChange(false)
    }

    /// Returns false for a key press that should go on to the window (Tab).
    private func handle(_ event: NSEvent) -> Bool {
        guard !event.isARepeat else { return true }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty {
            switch event.keyCode {
            case VirtualKey.escape:
                finishRecording()
                return true
            case VirtualKey.delete, VirtualKey.forwardDelete:
                combo = nil
                finishRecording()
                return true
            case VirtualKey.tab:
                finishRecording()
                return false
            default:
                break
            }
        }
        guard let newCombo = HotKeyCombo(event: event), !newCombo.isMainMenuShortcut else {
            NSSound.beep()
            return true
        }
        combo = newCombo
        finishRecording()
        return true
    }
}

/// The field itself: the shortcut in a control-fill capsule, or "Type Shortcut" in amber inside the
/// selection ring while recording.
private struct HotKeyRecorderField: View {
    let combo: HotKeyCombo?
    let isRecording: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control, style: .continuous)
        label
            .font(Typography.body)
            .lineLimit(1)
            .frame(minWidth: 112)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.controlFill, in: shape)
            .overlay {
                if isRecording {
                    shape.strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.selectionRing)
                }
            }
            .contentShape(shape)
    }

    @ViewBuilder private var label: some View {
        if isRecording {
            Text("Type Shortcut")
                .foregroundStyle(Color.accentText)
        } else if let combo {
            Text(verbatim: combo.displayString)
                .foregroundStyle(Color.textPrimary)
        } else {
            Text("Off")
                .foregroundStyle(Color.textTertiary)
        }
    }
}

/// The local key monitor, installed only while the recorder records.
@Observable @MainActor
private final class KeyRecording {
    private(set) var isActive = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onKeyDown: (@MainActor (NSEvent) -> Bool)?

    /// `onKeyDown` gets every key press in Elenath until `stop()`; it returns false to let one through.
    func start(onKeyDown: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        self.onKeyDown = onKeyDown
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, before the event is dispatched.
            let consumed = MainActor.assumeIsolated {
                self?.receive(event) ?? false
            }
            return consumed ? nil : event
        }
        isActive = true
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onKeyDown = nil
        isActive = false
    }

    private func receive(_ event: NSEvent) -> Bool {
        guard isActive, let onKeyDown else { return false }
        return onKeyDown(event)
    }
}
