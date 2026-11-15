import Foundation
import Observation

/// The Night / Dawn / Match System appearance choice.
enum AppearanceChoice: String, CaseIterable {
    case night, dawn, system
}

/// Preferences that belong to this Mac rather than to a library folder, stored in `UserDefaults`.
///
/// Every property is read once at launch and written through on change. Changing `appearance` applies it
/// to the whole app at once (see `Appearance`). `QuickCaptureHotKeyController` observes
/// `quickCaptureHotKey` and re-registers the global shortcut.
///
/// In `-demo` mode the store is a throwaway suite (`LaunchOptions.makeDemoDefaults()`), so the user's own
/// settings are never read or changed, and onboarding counts as done unless a screenshot asks for it.
@Observable @MainActor
final class AppSettings {
    private let defaults: UserDefaults
    private let skipsOnboarding: Bool
    private var storedAppearance: AppearanceChoice
    private var storedQuickCaptureHotKey: HotKeyCombo?
    private var storedHasCompletedOnboarding: Bool

    /// `skipsOnboarding` is for `-demo`, which goes straight to its sample library.
    init(defaults: UserDefaults = .standard, skipsOnboarding: Bool = false) {
        self.defaults = defaults
        self.skipsOnboarding = skipsOnboarding
        storedAppearance = AppSettings.readAppearance(from: defaults)
        storedQuickCaptureHotKey = AppSettings.readQuickCaptureHotKey(from: defaults)
        storedHasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    /// Default `.night`.
    var appearance: AppearanceChoice {
        get { storedAppearance }
        set {
            guard newValue != storedAppearance else { return }
            storedAppearance = newValue
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            Appearance.apply(newValue)
        }
    }

    /// The global shortcut that opens Quick Capture from any app. Default ⌥⇧Space (Ithil has ⌥Space);
    /// nil means off.
    ///
    /// A stored shortcut without ⌘, ⌥ or ⌃ (which would stop that key from typing everywhere) or one that
    /// can't be read counts as the default.
    var quickCaptureHotKey: HotKeyCombo? {
        get { storedQuickCaptureHotKey }
        set {
            guard newValue != storedQuickCaptureHotKey else { return }
            storedQuickCaptureHotKey = newValue
            guard let newValue else {
                defaults.set(Self.hotKeyOff, forKey: Key.quickCaptureHotKey)
                return
            }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.quickCaptureHotKey)
            }
        }
    }

    /// Whether the first-launch onboarding has been finished. Default false.
    var hasCompletedOnboarding: Bool {
        get { skipsOnboarding || storedHasCompletedOnboarding }
        set {
            guard newValue != storedHasCompletedOnboarding else { return }
            storedHasCompletedOnboarding = newValue
            defaults.set(newValue, forKey: Key.hasCompletedOnboarding)
        }
    }

    /// Settings in their own throwaway store, for SwiftUI previews.
    static var preview: AppSettings {
        AppSettings(
            defaults: UserDefaults(suiteName: "io.github.visaug36.Elenath.preview") ?? .standard, skipsOnboarding: true)
    }

    // MARK: - Storage

    private enum Key {
        static let appearance = "appearance"
        static let quickCaptureHotKey = "quickCaptureHotKey"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    /// Stored for a shortcut that was turned off, so a missing key can still mean the default.
    private static let hotKeyOff = "off"

    private static func readAppearance(from defaults: UserDefaults) -> AppearanceChoice {
        defaults.string(forKey: Key.appearance).flatMap { AppearanceChoice(rawValue: $0) } ?? .night
    }

    private static func readQuickCaptureHotKey(from defaults: UserDefaults) -> HotKeyCombo? {
        let stored = defaults.object(forKey: Key.quickCaptureHotKey)
        if let text = stored as? String, text == hotKeyOff {
            return nil
        }
        guard let data = stored as? Data,
            let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data),
            combo.hasRequiredModifier
        else { return .optionShiftSpace }
        return combo
    }
}
