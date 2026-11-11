import Foundation
import Observation

/// The Night / Dawn / Match System appearance choice.
enum AppearanceChoice: String, CaseIterable {
    case night, dawn, system
}

/// Preferences that belong to this Mac rather than to a library folder, stored in `UserDefaults`.
///
/// Every property is read once at launch and written through on change. Changing `appearance` applies it
/// to the whole app at once (see `Appearance`).
///
/// In `-demo` mode the store is a throwaway suite (`LaunchOptions.makeDemoDefaults()`), so the user's own
/// settings are never read or changed.
@Observable @MainActor
final class AppSettings {
    private let defaults: UserDefaults
    private var storedAppearance: AppearanceChoice

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedAppearance = AppSettings.readAppearance(from: defaults)
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

    /// Settings in their own throwaway store, for SwiftUI previews.
    static var preview: AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "io.github.visaug36.Elenath.preview") ?? .standard)
    }

    // MARK: - Storage

    private enum Key {
        static let appearance = "appearance"
    }

    private static func readAppearance(from defaults: UserDefaults) -> AppearanceChoice {
        defaults.string(forKey: Key.appearance).flatMap { AppearanceChoice(rawValue: $0) } ?? .night
    }
}
