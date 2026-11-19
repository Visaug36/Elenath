import ElenathCore
import SwiftUI

/// The calendar's alerts on the main window (from Ithil's `MainView`): a recovered or restarted calendar, a
/// save that failed, and a file operation that failed.
struct CalendarAlerts: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(CalendarRecoveryAlert())
            .modifier(CalendarLostFileAlert())
            .modifier(CalendarSaveErrorAlert())
            .modifier(FilesErrorAlert())
    }
}

private struct CalendarRecoveryAlert: ViewModifier {
    @Environment(CalendarModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var alerts = model
        let report = model.recoveryNotice
        let isPresented = $alerts.showsRecoveryNotice
        content.alert("Elenath restored your calendar", isPresented: isPresented, presenting: report) { _ in
            Button("OK") {}
        } message: { report in
            Text(verbatim: CalendarMessages.recovery(report))
        }
    }
}

private struct CalendarLostFileAlert: ViewModifier {
    @Environment(CalendarModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var alerts = model
        content.alert("Elenath started an empty calendar", isPresented: $alerts.startedOverLostFile) {
            Button("OK") {}
        } message: {
            Text(verbatim: CalendarMessages.startedOverLostFile)
        }
    }
}

private struct CalendarSaveErrorAlert: ViewModifier {
    @Environment(CalendarModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var alerts = model
        let message = model.saveError
        let isPresented = $alerts.showsSaveError
        content.alert("Elenath couldn't save your calendar", isPresented: isPresented, presenting: message) { _ in
            Button("Try Again") { model.retrySave() }
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
    }
}

private struct FilesErrorAlert: ViewModifier {
    @Environment(FilesController.self) private var files

    func body(content: Content) -> some View {
        @Bindable var alerts = files
        let message = files.lastError
        let isPresented = $alerts.showsLastError
        content.alert("There was a problem with your files", isPresented: isPresented, presenting: message) { _ in
            Button("OK") {}
        } message: { message in
            Text(verbatim: message)
        }
    }
}
