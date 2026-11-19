import ElenathCore
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
/// `quickCaptureHotKey` and re-registers the global shortcut. `CalendarModel` observes `firstWeekday` and
/// rebuilds its calendar math when it changes. The calendar's settings (default alert, first weekday, menu
/// bar extra) are Ithil's, under Ithil's keys.
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
    private var storedDefaultAlert: AlertOffset?
    private var storedFirstWeekday: Int?
    private var storedShowsMenuBarExtra: Bool

    /// `skipsOnboarding` is for `-demo`, which goes straight to its sample library.
    init(defaults: UserDefaults = .standard, skipsOnboarding: Bool = false) {
        self.defaults = defaults
        self.skipsOnboarding = skipsOnboarding
        storedAppearance = AppSettings.readAppearance(from: defaults)
        storedQuickCaptureHotKey = AppSettings.readQuickCaptureHotKey(from: defaults)
        storedHasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        storedDefaultAlert = AppSettings.readDefaultAlert(from: defaults)
        storedFirstWeekday = AppSettings.readFirstWeekday(from: defaults)
        storedShowsMenuBarExtra = defaults.object(forKey: Key.showsMenuBarExtra) as? Bool ?? true
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

    /// The global shortcut that opens Quick Capture from any app. Default ⌥Space (from 0.2; it was ⌥⇧Space
    /// while Ithil had ⌥Space); nil means off. A shortcut the user recorded is kept.
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

    /// The alert new events get. Default 10 minutes; nil means "None".
    var defaultAlert: AlertOffset? {
        get { storedDefaultAlert }
        set {
            guard newValue != storedDefaultAlert else { return }
            storedDefaultAlert = newValue
            defaults.set(newValue?.minutesBefore ?? Self.noAlert, forKey: Key.defaultAlert)
        }
    }

    /// nil follows the locale; 1 = Sunday … 7 = Saturday. Other values are treated as nil.
    var firstWeekday: Int? {
        get { storedFirstWeekday }
        set {
            let weekday = newValue.flatMap { (1...7).contains($0) ? $0 : nil }
            guard weekday != storedFirstWeekday else { return }
            storedFirstWeekday = weekday
            if let weekday {
                defaults.set(weekday, forKey: Key.firstWeekday)
            } else {
                defaults.removeObject(forKey: Key.firstWeekday)
            }
        }
    }

    /// `firstWeekday`, or the locale's when it is nil.
    var effectiveFirstWeekday: Int {
        firstWeekday ?? Calendar.autoupdatingCurrent.firstWeekday
    }

    /// Whether the menu bar extra is shown. Default true.
    var showsMenuBarExtra: Bool {
        get { storedShowsMenuBarExtra }
        set {
            guard newValue != storedShowsMenuBarExtra else { return }
            storedShowsMenuBarExtra = newValue
            defaults.set(newValue, forKey: Key.showsMenuBarExtra)
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
        static let defaultAlert = "defaultAlertMinutes"
        static let firstWeekday = "firstWeekday"
        static let showsMenuBarExtra = "showsMenuBarExtra"
    }

    /// Stored for "None" as the default alert, so a missing key can still mean 10 minutes.
    private static let noAlert = -1

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
        else { return .optionSpace }
        return combo
    }

    private static func readDefaultAlert(from defaults: UserDefaults) -> AlertOffset? {
        guard let minutes = defaults.object(forKey: Key.defaultAlert) as? Int else { return .tenMinutes }
        return minutes == noAlert ? nil : AlertOffset(minutesBefore: minutes)
    }

    private static func readFirstWeekday(from defaults: UserDefaults) -> Int? {
        guard let weekday = defaults.object(forKey: Key.firstWeekday) as? Int else { return nil }
        return (1...7).contains(weekday) ? weekday : nil
    }
}
