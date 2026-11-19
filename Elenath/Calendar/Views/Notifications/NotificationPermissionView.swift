import SwiftUI

/// Explains Elenath's notifications before asking for permission, or, once they are off, how to turn them
/// back on. Used at the bottom of the sidebar, and reusable in Settings and onboarding.
///
/// - Not asked yet: a bell, "Get a nudge before class" and why, then "Turn On Notifications" (shows
///   macOS's prompt) and "Not Now" (hides the sidebar card from then on, then calls `onNotNow`).
/// - Turned off: "Notifications are off for Elenath", where to turn them on, and "Open System Settings".
/// - Turned on: a short confirmation (for onboarding). Not read yet: nothing.
///
/// A `BackgroundRaised` card with radius 10 and 12–13 pt text. Buttons follow the surrounding control size.
struct NotificationPermissionView: View {
    @Environment(NotificationsController.self) private var notifications
    /// Called after "Not Now", e.g. to move on in onboarding.
    var onNotNow: (() -> Void)? = nil
    @State private var isRequesting = false

    var body: some View {
        switch notifications.authorization {
        case .notDetermined:
            NotificationPermissionCard(symbol: "bell", title: Wording.askTitle, message: Self.explanation) {
                askButtons
            }
        case .denied:
            NotificationPermissionCard(symbol: "bell.slash", title: Wording.offTitle, message: Wording.offMessage) {
                Button("Open System Settings") {
                    notifications.openSystemSettings()
                }
            }
        case .authorized:
            NotificationPermissionCard(symbol: "bell.badge", title: Wording.onTitle, message: Wording.onMessage) {
                EmptyView()
            }
        case .unknown:
            EmptyView()
        }
    }

    /// Why Elenath asks: shown before the permission prompt, here and in Settings.
    static var explanation: LocalizedStringKey {
        "Elenath can remind you before events, even when it's closed. You pick the alert for each event."
    }

    /// Side by side when they fit, else stacked (the sidebar is narrow).
    private var askButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                turnOnButton
                notNowButton
            }
            VStack(alignment: .leading, spacing: 6) {
                turnOnButton
                notNowButton
            }
        }
    }

    private var turnOnButton: some View {
        Button {
            requestPermission()
        } label: {
            Text("Turn On Notifications")
                .foregroundStyle(Color.textOnAccent)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .disabled(isRequesting)
        .accessibilityHint(Text("Asks macOS to let Elenath show alerts"))
    }

    private var notNowButton: some View {
        Button("Not Now") {
            notifications.isPromptDismissed = true
            onNotNow?()
        }
        .accessibilityHint(Text("Hides this suggestion"))
    }

    private func requestPermission() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            await notifications.requestAuthorization()
            isRequesting = false
        }
    }
}

/// The card's words. (Shared with Settings: `NotificationPermissionView.explanation`.)
private enum Wording {
    static var askTitle: LocalizedStringKey { "Get a nudge before class" }
    static var offTitle: LocalizedStringKey { "Notifications are off for Elenath" }
    static var offMessage: LocalizedStringKey { "Turn them on in System Settings → Notifications → Elenath." }
    static var onTitle: LocalizedStringKey { "Notifications are on" }
    static var onMessage: LocalizedStringKey {
        "Elenath reminds you before events that have an alert, even when it's closed."
    }
}

/// The card itself: an amber symbol beside a 13 pt semibold title and a 12 pt explanation, with the
/// actions below.
private struct NotificationPermissionCard<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actions: Actions

    init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.Radius.formGroup, style: .continuous)
                .fill(Color.backgroundRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.formGroup, style: .continuous)
                .strokeBorder(Color.separatorLine, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
