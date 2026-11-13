import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, as Carbon's `RegisterEventHotKey` takes it: a virtual key code and Carbon
/// modifier bits, plus the key's name for display.
///
/// Stored in `AppSettings` as JSON. `keyName` is the canonical name ("Space", "K"); `displayString`
/// localizes the named keys, so a stored shortcut reads right after the language changes.
struct HotKeyCombo: Codable, Hashable, Sendable {
    /// The virtual key code (`kVK_*`), which names a key position, not a character.
    var keyCode: UInt32
    /// `cmdKey | optionKey | controlKey | shiftKey` bits.
    var carbonModifiers: UInt32
    /// For display, e.g. "Space" or "K".
    var keyName: String

    /// ⌥⇧Space, Quick Capture's default. Ithil, Elenath's sibling, has ⌥Space.
    static let optionShiftSpace = HotKeyCombo(
        keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey), keyName: "Space")

    /// The four modifier bits a hotkey can use.
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// The modifiers of which at least one must be held. Shift alone would steal ordinary typing.
    static let requiredModifierMask = UInt32(cmdKey | optionKey | controlKey)

    /// True when ⌘, ⌥ or ⌃ is part of the shortcut.
    var hasRequiredModifier: Bool {
        carbonModifiers & Self.requiredModifierMask != 0
    }

    /// "⌥Space", "⌃⇧K": the modifiers in the system's ⌃⌥⇧⌘ order, then the key.
    var displayString: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 {
            symbols += "⌃"
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            symbols += "⌥"
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            symbols += "⇧"
        }
        if carbonModifiers & UInt32(cmdKey) != 0 {
            symbols += "⌘"
        }
        return symbols + displayKeyName
    }

    /// The key as shown: "Space" in the user's language, a symbol for the other named keys, or the
    /// stored name.
    private var displayKeyName: String {
        if keyCode == UInt32(kVK_Space) {
            return String(localized: "Space", comment: "The space bar, in a keyboard shortcut such as ⌥Space")
        }
        return Self.namedKeys[keyCode] ?? keyName
    }

    /// Keys that type nothing printable (or only a space), with the symbols macOS menus use for them.
    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
    ]
}

extension HotKeyCombo {
    /// The shortcut a key press makes, or nil unless ⌘, ⌥ or ⌃ is held (⇧ alone isn't enough) or the event
    /// isn't a key press.
    @MainActor
    init?(event: NSEvent) {
        // Reading `keyCode` of any other kind of event raises an exception.
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers & Self.requiredModifierMask != 0 else { return nil }
        let keyCode = UInt32(event.keyCode)
        guard let name = Self.namedKeys[keyCode] ?? Self.characterName(of: event) else { return nil }
        self.init(keyCode: keyCode, carbonModifiers: modifiers, keyName: name)
    }

    /// True when an item in Elenath's own menus has this shortcut (⌘Q, ⌘W, ⌘C, ⌘N…). Registered globally it
    /// would be taken from every app, so the recorder refuses it.
    @MainActor
    var isMainMenuShortcut: Bool {
        guard let menu = NSApplication.shared.mainMenu else { return false }
        return Self.menu(menu, contains: self)
    }

    /// Carbon's bits for ⌘, ⌥, ⌃ and ⇧ in `flags`; other flags are ignored.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }

    @MainActor
    private static func menu(_ menu: NSMenu, contains combo: HotKeyCombo) -> Bool {
        for item in menu.items {
            if let submenu = item.submenu, Self.menu(submenu, contains: combo) {
                return true
            }
            if item.hasKeyEquivalent(of: combo) {
                return true
            }
        }
        return false
    }

    /// The character the key types with no modifiers held ("k" for ⌥K, "1" for ⇧⌘1), in capitals.
    @MainActor
    private static func characterName(of event: NSEvent) -> String? {
        let typed = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        // AppKit's function-key characters (U+F700…U+F8FF) have no glyph.
        guard let first = name.unicodeScalars.first, !(0xF700...0xF8FF).contains(first.value) else { return nil }
        return name.uppercased()
    }
}

extension HotKeyCombo {
    /// The `NSMenuItem.keyEquivalent` strings this key can appear as, in lower case: the character for a
    /// character key, AppKit's function-key character for the named keys (arrows, F-keys, ↩…).
    fileprivate var menuKeyEquivalents: Set<String> {
        guard let scalars = Self.menuKeyEquivalentScalars[keyCode] else { return [keyName.lowercased()] }
        return Set(scalars.compactMap { value in Unicode.Scalar(value).map { String(Character($0)) } })
    }

    /// `NSUpArrowFunctionKey` and friends, as AppKit and SwiftUI's `KeyEquivalent` spell the named keys.
    private static let menuKeyEquivalentScalars: [UInt32: [UInt32]] = [
        UInt32(kVK_Space): [0x20],
        UInt32(kVK_Return): [0x0D],
        UInt32(kVK_ANSI_KeypadEnter): [0x03],
        UInt32(kVK_Tab): [0x09],
        UInt32(kVK_Delete): [0x08, 0x7F],
        UInt32(kVK_ForwardDelete): [0xF728],
        UInt32(kVK_Escape): [0x1B],
        UInt32(kVK_UpArrow): [0xF700],
        UInt32(kVK_DownArrow): [0xF701],
        UInt32(kVK_LeftArrow): [0xF702],
        UInt32(kVK_RightArrow): [0xF703],
        UInt32(kVK_Home): [0xF729],
        UInt32(kVK_End): [0xF72B],
        UInt32(kVK_PageUp): [0xF72C],
        UInt32(kVK_PageDown): [0xF72D],
        UInt32(kVK_F1): [0xF704],
        UInt32(kVK_F2): [0xF705],
        UInt32(kVK_F3): [0xF706],
        UInt32(kVK_F4): [0xF707],
        UInt32(kVK_F5): [0xF708],
        UInt32(kVK_F6): [0xF709],
        UInt32(kVK_F7): [0xF70A],
        UInt32(kVK_F8): [0xF70B],
        UInt32(kVK_F9): [0xF70C],
        UInt32(kVK_F10): [0xF70D],
        UInt32(kVK_F11): [0xF70E],
        UInt32(kVK_F12): [0xF70F],
        UInt32(kVK_F13): [0xF710],
        UInt32(kVK_F14): [0xF711],
        UInt32(kVK_F15): [0xF712],
        UInt32(kVK_F16): [0xF713],
        UInt32(kVK_F17): [0xF714],
        UInt32(kVK_F18): [0xF715],
        UInt32(kVK_F19): [0xF716],
        UInt32(kVK_F20): [0xF717],
    ]
}

extension NSMenuItem {
    /// Whether this item's key equivalent is `combo`, for character keys and the named keys alike; an
    /// upper-case key equivalent implies ⇧, as AppKit reads it.
    @MainActor
    fileprivate func hasKeyEquivalent(of combo: HotKeyCombo) -> Bool {
        let equivalent = keyEquivalent
        guard !equivalent.isEmpty, combo.menuKeyEquivalents.contains(equivalent.lowercased()) else { return false }
        var modifiers = HotKeyCombo.carbonModifiers(from: keyEquivalentModifierMask)
        if equivalent != equivalent.lowercased() {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers == combo.carbonModifiers & HotKeyCombo.modifierMask
    }
}
