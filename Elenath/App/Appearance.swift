import AppKit

/// Applies the Night / Dawn / Match System choice to the whole app: windows, Settings, panels and menus.
///
/// Night is the asset catalog's Dark appearance and Dawn its Any (light) one, so every color token
/// follows. `AppSettings` calls this whenever the choice changes; the app calls it once at launch.
enum Appearance {
    @MainActor
    static func apply(_ choice: AppearanceChoice) {
        let appearance: NSAppearance?
        switch choice {
        case .night:
            appearance = NSAppearance(named: .darkAqua)
        case .dawn:
            appearance = NSAppearance(named: .aqua)
        case .system:
            appearance = nil
        }
        NSApplication.shared.appearance = appearance
    }
}
