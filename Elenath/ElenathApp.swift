import SwiftUI

/// Elenath's scenes: the main window and Settings, sharing one `AppModel` and one `AppSettings`.
///
/// Both are created once, here, from the launch arguments (`-demo` gives them a temporary folder with an
/// invented library and throwaway settings), and injected with `.environment`. Once the app runs,
/// `QuickCaptureHotKeyController` registers the global Quick Capture shortcut (⌥⇧Space by default) and
/// keeps it registered as the setting changes; a press toggles the Quick Capture panel.
@main
struct ElenathApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var model: AppModel
    /// Only for `-demo` screenshot scenes.
    @State private var demoDirector: DemoSceneDirector?

    init() {
        let options = LaunchOptions.current
        let defaults = options.isDemo ? LaunchOptions.makeDemoDefaults() : UserDefaults.standard
        let showsOnboarding = options.demoScene.screen == .onboarding
        let settings = AppSettings(defaults: defaults, skipsOnboarding: options.isDemo && !showsOnboarding)
        let model = AppModel(options: options, settings: settings, defaults: defaults)
        var demoDirector: DemoSceneDirector?
        if options.isDemo, !options.demoScene.isEmpty {
            demoDirector = DemoSceneDirector(scene: options.demoScene, model: model, settings: settings)
        }
        model.start()
        _settings = State(initialValue: settings)
        _model = State(initialValue: model)
        _demoDirector = State(initialValue: demoDirector)
        // Before the first window draws, where possible; `connect()` makes sure of it. The global shortcut
        // is registered once the app's run loop is going.
        Task { @MainActor in
            Appearance.apply(settings.appearance)
            QuickCaptureHotKeyController.shared.start(settings: settings) {
                QuickCapturePanelController.shared.toggle(model: model)
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: MainView.windowID) {
            MainView()
                .environment(model)
                .environment(settings)
                .onAppear { connect() }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            ElenathCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
                .onAppear { connect() }
        }
    }

    /// Hands the model to the app delegate (for quitting safely) and applies the appearance setting.
    private func connect() {
        appDelegate.model = model
        Appearance.apply(settings.appearance)
    }
}
