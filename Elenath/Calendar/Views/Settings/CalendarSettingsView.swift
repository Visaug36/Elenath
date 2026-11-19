import AppKit
import ElenathCore
import SwiftUI

/// Settings › Calendar (Ithil's General settings for the calendar): the default alert for new events, the
/// first day of the week, notifications, the menu bar extra, and bringing in an Ithil calendar. The subjects
/// and their homes are in Settings › Subjects.
struct CalendarSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(CalendarModel.self) private var model
    @State private var showsBringIn = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                DefaultAlertPicker(alert: $settings.defaultAlert)
                FirstWeekdayPicker(weekday: $settings.firstWeekday)
            } footer: {
                Text("New events start with this alert. Quick Capture gives it only to events with a time.")
                    .font(Typography.eventTime)
                    .foregroundStyle(Color.textTertiary)
            }
            NotificationSettingsSection()
            Section {
                Toggle("Show in menu bar", isOn: $settings.showsMenuBarExtra)
                    .tint(Color.accentColor)
            } footer: {
                Text("Today and the next event, with Open Files, Capture and the Inbox, from the menu bar.")
                    .font(Typography.eventTime)
                    .foregroundStyle(Color.textTertiary)
            }
            Section {
                LabeledContent("Ithil") {
                    Button("Bring In Ithil Calendar…") {
                        showsBringIn = true
                    }
                    .disabled(!model.canEdit)
                }
            } footer: {
                Text(
                    "Copies the events, subjects and files of an Ithil calendar into Elenath. The Ithil folder stays as it is."
                )
                .font(Typography.eventTime)
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundWindow)
        .frame(height: 520)
        .sheet(isPresented: $showsBringIn) {
            BringInIthilSheet()
        }
    }
}

/// "Notifications": what macOS allows, with the button that fits, and a footnote that explains (before
/// asking) or says where to change it.
private struct NotificationSettingsSection: View {
    @Environment(CalendarModel.self) private var model
    @Environment(NotificationsController.self) private var notifications
    @State private var isRequesting = false

    var body: some View {
        Section {
            LabeledContent("Notifications") {
                HStack(spacing: 10) {
                    status
                        .foregroundStyle(Color.textSecondary)
                    action
                }
            }
            .task {
                // The user may have changed it in System Settings since.
                await notifications.refreshAuthorization()
            }
        } footer: {
            footer
                .font(Typography.eventTime)
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: Text {
        if model.isDemo { return Text("Off in demo mode") }
        switch notifications.authorization {
        case .unknown: return Text("Checking…")
        case .notDetermined: return Text("Not turned on")
        case .denied: return Text("Off")
        case .authorized: return Text("On")
        }
    }

    @ViewBuilder private var action: some View {
        if !model.isDemo {
            switch notifications.authorization {
            case .notDetermined:
                Button("Turn On…") {
                    requestPermission()
                }
                .disabled(isRequesting)
                .accessibilityHint(Text("Asks macOS to let Elenath show alerts"))
            case .denied:
                Button("Open System Settings") {
                    notifications.openSystemSettings()
                }
            case .authorized:
                Button("Notification Settings…") {
                    notifications.openSystemSettings()
                }
                .accessibilityHint(Text("Opens Elenath in System Settings → Notifications"))
            case .unknown:
                EmptyView()
            }
        }
    }

    private var footer: Text {
        if model.isDemo {
            return Text("Demo mode never schedules notifications, so your real alerts stay as they are.")
        }
        switch notifications.authorization {
        case .notDetermined, .unknown:
            return Text(NotificationPermissionView.explanation)
        case .denied:
            return Text("Turn them on in System Settings → Notifications → Elenath.")
        case .authorized:
            return Text("Alerts arrive even when Elenath is closed. Their style and sound are set in System Settings.")
        }
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

/// The alert new events get: the presets, then None.
private struct DefaultAlertPicker: View {
    @Binding var alert: AlertOffset?

    var body: some View {
        Picker("Default alert", selection: $alert) {
            ForEach(AlertChoices.offered(including: alert), id: \.self) { offset in
                Text(EventFormatting.alert(offset))
                    .tag(AlertOffset?.some(offset))
            }
            Divider()
            Text(EventFormatting.alert(nil))
                .tag(AlertOffset?.none)
        }
    }
}

/// "System Default (Monday)", then the seven weekdays from the locale's first one.
private struct FirstWeekdayPicker: View {
    @Binding var weekday: Int?

    var body: some View {
        let systemDefault = Self.weekdayName(Calendar.autoupdatingCurrent.firstWeekday)
        Picker("First day of week", selection: $weekday) {
            Text("System Default (\(systemDefault))")
                .tag(Int?.none)
            Divider()
            ForEach(Self.weekdaysInLocaleOrder, id: \.self) { day in
                Text(Self.weekdayName(day))
                    .tag(Int?.some(day))
            }
        }
    }

    /// The seven Gregorian weekdays (1 = Sunday … 7 = Saturday), starting from the locale's first day.
    private static var weekdaysInLocaleOrder: [Int] {
        let first = Calendar.autoupdatingCurrent.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// "Monday", in the user's language.
    private static func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        let symbols = calendar.standaloneWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }
}
