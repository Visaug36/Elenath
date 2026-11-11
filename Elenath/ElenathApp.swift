import SwiftUI

/// Elenath's scenes: the main window and Settings, sharing one `AppSettings`.
///
/// The settings are created once, here, from the launch arguments (`-demo` gives them a throwaway store),
/// and injected with `.environment`.
@main
struct ElenathApp: App {
    @State private var settings: AppSettings
    /// Only for `-demo` screenshot scenes.
    @State private var demoDirector: DemoSceneDirector?

    init() {
        let options = LaunchOptions.current
        let defaults = options.isDemo ? LaunchOptions.makeDemoDefaults() : UserDefaults.standard
        let settings = AppSettings(defaults: defaults)
        var demoDirector: DemoSceneDirector?
        if options.isDemo, !options.demoScene.isEmpty {
            demoDirector = DemoSceneDirector(scene: options.demoScene, settings: settings)
        }
        _settings = State(initialValue: settings)
        _demoDirector = State(initialValue: demoDirector)
        // Before the first window draws, where possible; `connect()` makes sure of it.
        Task { @MainActor in
            Appearance.apply(settings.appearance)
        }
    }

    var body: some Scene {
        WindowGroup(id: MainView.windowID) {
            MainView()
                .environment(settings)
                .onAppear { connect() }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            ElenathCommands()
        }

        Settings {
            SettingsView()
                .environment(settings)
                .onAppear { connect() }
        }
    }

    /// Applies the appearance setting once the app object exists.
    private func connect() {
        Appearance.apply(settings.appearance)
    }
}
