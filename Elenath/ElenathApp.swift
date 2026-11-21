import SwiftUI

/// Elenath's scenes: the main window, Settings and the menu bar extra, sharing one `AppModel` (with its
/// `CalendarModel`), one `AppSettings`, and the calendar's `FilesController` and `NotificationsController`.
///
/// All are created once, here, from the launch arguments (`-demo` gives them a temporary folder with an
/// invented library and throwaway settings), and injected with `.environment`. The calendar's controllers
/// are created before `model.start()`, so they follow the calendar from the first time it opens. Once the
/// app runs, `QuickCaptureHotKeyController` registers the global Quick Capture shortcut (⌥Space by default)
/// and keeps it registered as the setting changes; a press toggles the Quick Capture panel. The menu bar
/// extra is inserted while `settings.showsMenuBarExtra` is on.
@main
struct ElenathApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var model: AppModel
    @State private var files: FilesController
    @State private var notifications: NotificationsController
    /// Only for `-demo` screenshot scenes.
    @State private var demoDirector: DemoSceneDirector?
    /// Only for `-demo -demoSelfCheck`, CI's crash check.
    @State private var selfCheck: DemoSelfCheck?

    init() {
        let options = LaunchOptions.current
        let defaults = options.isDemo ? LaunchOptions.makeDemoDefaults() : UserDefaults.standard
        let showsOnboarding = options.demoScene.screen == .onboarding
        let settings = AppSettings(defaults: defaults, skipsOnboarding: options.isDemo && !showsOnboarding)
        let model = AppModel(options: options, settings: settings, defaults: defaults)
        let files = FilesController(model: model.calendar)
        let notifications = NotificationsController(model: model.calendar, files: files)
        model.calendar.isCopyingFiles = { [weak files] in
            files?.isCopyingFiles ?? false
        }
        model.calendar.finishFileWork = { [weak files] timeout in
            await files?.finishDiskWork(timeout: timeout) ?? true
        }
        model.calendar.filesForNewEvent = { [weak files] urls, occurrence in
            files?.addFiles(urls, to: occurrence)
        }
        var demoDirector: DemoSceneDirector?
        if options.isDemo, !options.demoScene.isEmpty {
            demoDirector = DemoSceneDirector(scene: options.demoScene, model: model, settings: settings)
        }
        var selfCheck: DemoSelfCheck?
        if options.isDemo, options.runsSelfCheck {
            selfCheck = DemoSelfCheck(model: model, settings: settings, files: files)
        }
        model.start()
        _settings = State(initialValue: settings)
        _model = State(initialValue: model)
        _files = State(initialValue: files)
        _notifications = State(initialValue: notifications)
        _demoDirector = State(initialValue: demoDirector)
        _selfCheck = State(initialValue: selfCheck)
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
                .environment(model.calendar)
                .environment(settings)
                .environment(files)
                .environment(notifications)
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
                .environment(model.calendar)
                .environment(settings)
                .environment(files)
                .environment(notifications)
                .onAppear { connect() }
        }

        MenuBarExtra(isInserted: $settings.showsMenuBarExtra) {
            MenuBarContent()
                .environment(model)
                .environment(model.calendar)
                .environment(settings)
                .environment(files)
                .environment(notifications)
                .onAppear { connect() }
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }

    /// Hands the model to the app delegate (for quitting safely) and applies the appearance setting.
    private func connect() {
        appDelegate.model = model
        Appearance.apply(settings.appearance)
    }
}
