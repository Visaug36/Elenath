import AppKit

/// Sets up a `-demo` screenshot scene (see `DemoScene`): the appearance and the window size. Only ever
/// created in demo mode.
@MainActor
final class DemoSceneDirector {
    private let scene: DemoScene
    private let settings: AppSettings

    init(scene: DemoScene, settings: AppSettings) {
        self.scene = scene
        self.settings = settings
        // NSApp may not exist yet while the App is being initialized.
        Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        if let appearance = scene.appearance {
            settings.appearance = appearance
        }
        await resizeMainWindow()
    }

    /// Waits up to 20 seconds for the main window (on a CI runner it can open late), then sizes and centers it.
    private func resizeMainWindow() async {
        guard let size = scene.windowSize else { return }
        for _ in 0..<80 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) {
                window.setContentSize(size)
                window.center()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
