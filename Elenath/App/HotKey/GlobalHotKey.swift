import Carbon.HIToolbox
import Foundation
import os

private let logger = Logger(subsystem: "io.github.visaug36.Elenath", category: "GlobalHotKey")

/// "ELNT": the signature on every hotkey Elenath registers, so the handler ignores anyone else's.
private let hotKeySignature: OSType = "ELNT".utf8.reduce(0) { $0 << 8 | OSType($1) }

/// `kEventHotKeyExclusive`: registration fails with `eventHotKeyExistsErr` when another app already has
/// the shortcut, instead of both apps quietly sharing it.
private let exclusiveRegistration: OptionBits = 1 << 0

/// A system-wide keyboard shortcut, through Carbon's `RegisterEventHotKey`.
///
/// This works in the App Sandbox and needs no Accessibility or Input Monitoring permission, because macOS
/// only tells Elenath about its own shortcut, never about other key presses. Presses arrive on the main
/// thread, also while Elenath is in the background. One Carbon event handler serves every instance; it is
/// installed the first time one registers and stays for the life of the app.
@MainActor
final class GlobalHotKey {
    enum RegistrationResult {
        /// The shortcut now works from any app.
        case registered
        /// There was no shortcut to register.
        case off
        /// Another app or macOS itself uses the shortcut, or Carbon refused it.
        case unavailable
    }

    private let onPress: @MainActor () -> Void
    private let id: UInt32
    /// The registered shortcut. `nonisolated(unsafe)` only so `deinit` can unregister it.
    private nonisolated(unsafe) var reference: EventHotKeyRef?

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        id = HotKeyDispatcher.shared.makeID()
    }

    deinit {
        if let reference {
            _ = UnregisterEventHotKey(reference)
        }
    }

    /// Registers `combo` in place of the current shortcut. Nil only unregisters.
    @discardableResult
    func register(_ combo: HotKeyCombo?) -> RegistrationResult {
        unregister()
        guard let combo else { return .off }
        guard combo.hasRequiredModifier else {
            // Without ⌘, ⌥ or ⌃ the key would stop typing in every app.
            logger.error("Refusing a hotkey without ⌘, ⌥ or ⌃ (key code \(combo.keyCode, privacy: .public))")
            return .unavailable
        }
        if SystemShortcuts.contains(combo) {
            logger.notice("\(combo.displayString, privacy: .public) is a macOS keyboard shortcut")
            return .unavailable
        }
        guard HotKeyDispatcher.shared.installIfNeeded() else { return .unavailable }
        var status = registerWithCarbon(combo, options: exclusiveRegistration)
        if status != OSStatus(noErr), status != OSStatus(eventHotKeyExistsErr) {
            // Should this macOS refuse the exclusive option itself, a shared registration still works.
            status = registerWithCarbon(combo, options: 0)
        }
        guard status == OSStatus(noErr) else {
            if status == OSStatus(eventHotKeyExistsErr) {
                logger.notice("\(combo.displayString, privacy: .public) is taken by another app")
            } else {
                logger.error("RegisterEventHotKey failed: \(status, privacy: .public)")
            }
            return .unavailable
        }
        HotKeyDispatcher.shared.add(self, id: id)
        return .registered
    }

    /// Gives the shortcut back to the system. Does nothing when none is registered.
    func unregister() {
        guard let reference else { return }
        let status = UnregisterEventHotKey(reference)
        if status != OSStatus(noErr) {
            logger.error("UnregisterEventHotKey failed: \(status, privacy: .public)")
        }
        self.reference = nil
        HotKeyDispatcher.shared.remove(id: id)
    }

    fileprivate func handlePress() {
        onPress()
    }

    /// One `RegisterEventHotKey` call; keeps the reference when it worked.
    private func registerWithCarbon(_ combo: HotKeyCombo, options: OptionBits) -> OSStatus {
        var newReference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers & HotKeyCombo.modifierMask,
            EventHotKeyID(signature: hotKeySignature, id: id),
            GetApplicationEventTarget(),
            options,
            &newReference)
        guard status == OSStatus(noErr), let newReference else {
            return status == OSStatus(noErr) ? OSStatus(paramErr) : status
        }
        reference = newReference
        return status
    }
}

/// The one Carbon event handler for every `GlobalHotKey`, and the table that routes a press to its owner.
@MainActor
private final class HotKeyDispatcher {
    static let shared = HotKeyDispatcher()

    private var isInstalled = false
    private var nextID: UInt32 = 1
    private var hotKeys: [UInt32: WeakHotKey] = [:]

    private init() {}

    func makeID() -> UInt32 {
        defer { nextID += 1 }
        return nextID
    }

    func add(_ hotKey: GlobalHotKey, id: UInt32) {
        hotKeys[id] = WeakHotKey(hotKey: hotKey)
    }

    func remove(id: UInt32) {
        hotKeys[id] = nil
    }

    /// Installs the handler on the application's event target, once. False if Carbon refused.
    func installIfNeeded() -> Bool {
        guard !isInstalled else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The dispatcher is a singleton that is never released, so an unretained pointer stays valid.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &eventType, context, nil)
        guard status == OSStatus(noErr) else {
            logger.error("InstallEventHandler failed: \(status, privacy: .public)")
            return false
        }
        isInstalled = true
        return true
    }

    /// True when one of Elenath's hotkeys had this ID.
    func handlePress(id: UInt32) -> Bool {
        guard let hotKey = hotKeys[id]?.hotKey else { return false }
        hotKey.handlePress()
        return true
    }
}

private struct WeakHotKey {
    weak var hotKey: GlobalHotKey?
}

/// The Carbon callback for `kEventHotKeyPressed`. Carbon calls it on the main thread, from the main run
/// loop, with the dispatcher as its context.
private func hotKeyPressed(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID)
    guard status == OSStatus(noErr), hotKeyID.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let id = hotKeyID.id
    let dispatcher = Unmanaged<HotKeyDispatcher>.fromOpaque(context).takeUnretainedValue()
    let handled = MainActor.assumeIsolated {
        dispatcher.handlePress(id: id)
    }
    return handled ? OSStatus(noErr) : OSStatus(eventNotHandledErr)
}

/// Shortcuts macOS itself uses (Spotlight, input sources, Mission Control, screenshots…), as set in
/// System Settings → Keyboard → Keyboard Shortcuts. Carbon would register one of them anyway, but it would
/// never fire.
private enum SystemShortcuts {
    static func contains(_ combo: HotKeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == OSStatus(noErr),
            let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        let modifiers = combo.carbonModifiers & HotKeyCombo.modifierMask
        return entries.contains { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                let keyCode = entry["kHISymbolicHotKeyCode"] as? Int,
                let entryModifiers = entry["kHISymbolicHotKeyModifiers"] as? Int
            else { return false }
            return UInt32(truncatingIfNeeded: keyCode) == combo.keyCode
                && UInt32(truncatingIfNeeded: entryModifiers) & HotKeyCombo.modifierMask == modifiers
        }
    }
}
