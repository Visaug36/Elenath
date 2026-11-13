import AppKit
import ElenathCore

/// Sets up a `-demo` screenshot scene (see `DemoScene`): the appearance, the window size, and what the
/// window shows. Only ever created in demo mode.
@MainActor
final class DemoSceneDirector {
    private let scene: DemoScene
    private let model: AppModel
    private let settings: AppSettings

    init(scene: DemoScene, model: AppModel, settings: AppSettings) {
        self.scene = scene
        self.model = model
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
        guard let screen = scene.screen, screen != .onboarding else { return }
        guard await waitUntilReady() else { return }
        let uni = model.spaces.first { $0.name == "Uni" }
        let sealed = model.spaces.first { $0.isSealed }
        switch screen {
        case .today, .onboarding:
            model.go(to: .today)
        case .note:
            if let uni, let path = ItemPath("Physics/Lecture 7 notes.md") {
                model.open(NoteRef(container: .space(uni.id), path: path))
            }
        case .inbox:
            model.go(to: .inbox)
        case .space:
            if let uni {
                model.go(to: .folder(.space(uni.id), .root))
            }
        case .search:
            model.searchText = "inertia"
        case .sealed:
            if let sealed {
                model.go(to: .folder(.space(sealed.id), .root))
            }
        case .capture:
            QuickCapturePanelController.shared.show(model: model, text: "uni: ask about the exam date")
        case .settings:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Waits up to 30 seconds for the demo library to open and be indexed.
    private func waitUntilReady() async -> Bool {
        for _ in 0..<120 {
            if model.state == .ready, !model.isIndexing {
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
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
