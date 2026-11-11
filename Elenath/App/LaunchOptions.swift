import Foundation

/// What the launch arguments ask for.
///
/// `-demo` runs Elenath with throwaway settings, for screenshots and testing. The user's own settings are
/// never read or written. The screenshot flags (see `DemoScene`) only take effect together with `-demo`.
struct LaunchOptions: Sendable {
    var isDemo: Bool
    /// The screenshot scene from `-demoAppearance` and `-demoWindowSize`.
    var demoScene = DemoScene()

    /// The options of this process.
    static var current: LaunchOptions {
        parse(ProcessInfo.processInfo.arguments)
    }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        let isDemo = arguments.contains("-demo")
        var options = LaunchOptions(isDemo: isDemo)
        if isDemo {
            options.demoScene = DemoScene.parse(arguments)
        }
        return options
    }

    /// The settings store for `-demo`: its own suite, emptied at every launch, so demo runs never see
    /// or change the user's settings.
    static func makeDemoDefaults() -> UserDefaults {
        let suiteName = "io.github.visaug36.Elenath.demo"
        // UserDefaults refuses only NSGlobalDomain and the app's own bundle ID as suite names.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("The demo settings suite could not be created")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
