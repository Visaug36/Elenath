import Observation

/// Keeps the global Quick Capture shortcut registered as `AppSettings.quickCaptureHotKey` says.
///
/// The app calls `start` once at launch with what a press does (toggle the Quick Capture panel). From then on
/// every change to the setting re-registers the shortcut, and `status` says whether that worked, for
/// Settings → General. While the shortcut recorder listens it calls `suspend()`, so the current shortcut
/// can be typed again instead of opening Quick Capture, and `resume()` when it is done.
@Observable @MainActor
final class QuickCaptureHotKeyController {
    static let shared = QuickCaptureHotKeyController()

    /// What the last registration did. `.off` before `start`, without a shortcut, and while suspended.
    private(set) var status: GlobalHotKey.RegistrationResult = .off

    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private var isSuspended = false

    private init() {}

    /// Registers the shortcut from `settings` and follows its changes. Later calls do nothing.
    func start(settings: AppSettings, onPress: @escaping @MainActor () -> Void) {
        guard hotKey == nil else { return }
        self.settings = settings
        hotKey = GlobalHotKey(onPress: onPress)
        apply()
        observeSetting()
    }

    /// Unregisters the shortcut until `resume()`.
    func suspend() {
        isSuspended = true
        hotKey?.unregister()
        status = .off
    }

    /// Registers the shortcut the setting has now.
    func resume() {
        isSuspended = false
        apply()
    }

    private func apply() {
        guard let hotKey, let settings, !isSuspended else { return }
        status = hotKey.register(settings.quickCaptureHotKey)
    }

    private func observeSetting() {
        guard let settings else { return }
        withObservationTracking {
            _ = settings.quickCaptureHotKey
        } onChange: { [weak self] in
            // Called before the change lands, on whichever thread made it; re-read it on the main actor.
            Task { @MainActor in
                self?.settingDidChange()
            }
        }
    }

    private func settingDidChange() {
        apply()
        observeSetting()
    }
}
