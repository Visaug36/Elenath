import AppKit
import ElenathCore
import Observation
import SwiftUI

/// "Bring in my Ithil calendar" (DESIGN.md screen 13): choose the Ithil folder, copy, check, then give the
/// new subjects a home and say how to stop Ithil's own alerts.
///
/// The Ithil folder is only read (`CalendarImport`). The merged calendar is taken in as one change, which
/// Undo takes back. Stopping keeps the files already copied; bringing it in again copies the rest.
struct BringInIthilSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(CalendarModel.self) private var model
    @Environment(FilesController.self) private var files
    @State private var phase: Phase = .intro
    /// The copy's progress, reported from the import's background work.
    @State private var progress = BringInProgress()
    @State private var work: Task<Void, Never>? = nil

    enum Phase {
        case intro
        case copying
        case done(CalendarImportReport, newSubjects: [Subject])
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring in your Ithil calendar")
                .font(Typography.detailTitle)
                .foregroundStyle(Color.textPrimary)
            switch phase {
            case .intro:
                intro
            case .copying:
                copying(progress.value)
            case .done(let report, let newSubjects):
                BringInResult(report: report, newSubjects: newSubjects) {
                    dismiss()
                }
            case .failed(let message):
                failed(message)
            }
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
        .background(Color.backgroundRaised)
        .onDisappear {
            work?.cancel()
        }
    }

    // MARK: - Phases

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "Elenath copies your events, subjects and each event's files. Your Ithil folder stays exactly as it is."
            )
            .font(Typography.body)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    chooseFolder()
                } label: {
                    Text("Choose Ithil Folder…")
                        .foregroundStyle(Color.textOnAccent)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canEdit)
            }
        }
    }

    private func copying(_ progress: FileCopyProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progress.fractionCompleted)
                .tint(Color.accentColor)
            Text("Copying \(progress.completedFiles) of \(progress.totalFiles) files")
                .font(Typography.secondary)
                .monospacedDigit()
                .foregroundStyle(Color.textSecondary)
            HStack {
                Spacer()
                Button("Stop") {
                    work?.cancel()
                }
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.accentText)
            }
            .font(Typography.body)
            .foregroundStyle(Color.textPrimary)
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Choose Another Folder…") {
                    chooseFolder()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Bringing in

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Bring In")
        panel.message = String(localized: "Choose your Ithil folder. Elenath only reads it.")
        let suggested = FolderAccess.userHome.appending(components: "Documents", "Ithil", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: suggested.path) {
            panel.directoryURL = suggested
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        start(from: folder)
    }

    private func start(from folder: URL) {
        guard model.canEdit, let calendarFolder = model.rootURL, let libraryRoot = app.rootURL,
            let eventFolders = files.eventFolders
        else {
            phase = .failed(String(localized: "The calendar isn't open for changes right now."))
            return
        }
        let before = model.library
        let relay = progress
        relay.value = FileCopyProgress(totalBytes: 0, totalFiles: 0)
        phase = .copying
        work = Task {
            let isAccessing = folder.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let result = try await CalendarImport.run(
                    from: folder, into: before, calendarFolder: calendarFolder, libraryRoot: libraryRoot,
                    eventFolders: eventFolders, fileSystem: LocalFileSystem()
                ) { update in
                    Task { @MainActor in
                        relay.value = update
                    }
                }
                guard !Task.isCancelled else { return }
                // The calendar may have changed while the files were copied: merge into it as it is now.
                var report = CalendarImportReport()
                let merged = CalendarImport.merge(result.document, into: model.library, report: &report)
                model.bringIn(merged)
                let known = Set(before.subjects.map(\.id))
                let added = merged.subjects.filter { !known.contains($0.id) }
                phase = .done(result.report, newSubjects: added)
            } catch is CancellationError {
                phase = .failed(
                    String(
                        localized:
                            "Stopped. The files already copied stay; bringing the calendar in again copies the rest."))
            } catch {
                phase = .failed(BringInMessages.failure(error))
            }
        }
    }
}

/// What happened, the new subjects' homes, and how to stop Ithil's alerts.
private struct BringInResult: View {
    @Environment(CalendarModel.self) private var model
    let report: CalendarImportReport
    let newSubjects: [Subject]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            if !newSubjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where do these subjects belong?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(
                        "A subject's home is the space its notes go to. Events in a sealed space keep their notes and files there."
                    )
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(newSubjects) { subject in
                        HStack(spacing: 8) {
                            SubjectDot(subject: subject)
                            Text(verbatim: subject.name)
                                .font(Typography.body)
                                .foregroundStyle(Color.textPrimary)
                            Spacer(minLength: 8)
                            SubjectHomePicker(subject: subject)
                        }
                    }
                }
            }
            IthilAlertsCard()
            HStack {
                Spacer()
                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .foregroundStyle(Color.textOnAccent)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let everything = report.countsMatch
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(everything ? "Everything is in Elenath" : BringInMessages.missingTitle(report.missingFiles.count))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
            } icon: {
                Image(systemName: everything ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(everything ? Color(.spaceFern) : Color.accentText)
            }
            Text(verbatim: BringInMessages.summary(report))
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !report.missingFiles.isEmpty {
                ScrollView {
                    Text(verbatim: report.missingFiles.joined(separator: "\n"))
                        .font(Typography.code)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Metrics.Radius.control))
                Button("Copy List") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.missingFiles.joined(separator: "\n"), forType: .string)
                }
                .controlSize(.small)
            }
        }
    }
}

/// Ithil scheduled its own notifications, which keep coming until they are turned off there.
private struct IthilAlertsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Ithil's own alerts are still scheduled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
            } icon: {
                Image(systemName: "bell.slash")
                    .foregroundStyle(Color.accentText)
            }
            Text(
                "To stop them: open System Settings › Notifications › Ithil and turn off Allow Notifications. Then quit Ithil and turn off its Open at Login."
            )
            .font(Typography.secondary)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Notification Settings") {
                BringInMessages.openIthilNotificationSettings()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundWindow, in: RoundedRectangle(cornerRadius: Metrics.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .strokeBorder(Color.separatorLine, lineWidth: 1)
        }
    }
}

/// The sheet's sentences.
enum BringInMessages {
    static func summary(_ report: CalendarImportReport) -> String {
        var sentences = [
            String(
                localized:
                    "Brought in ^[\(report.eventsAdded) event](inflect: true), ^[\(report.subjectsAdded) subject](inflect: true) and ^[\(report.filesCopied) file](inflect: true)."
            )
        ]
        let alreadyThere = report.eventsAlreadyThere + report.subjectsAlreadyThere + report.filesAlreadyThere
        if alreadyThere > 0 {
            sentences.append(
                String(localized: "^[\(alreadyThere) item](inflect: true) already in Elenath were left alone."))
        }
        if report.readFromBackup {
            sentences.append(String(localized: "Ithil's calendar file was damaged, so its newest backup was used."))
        }
        if !report.missingFiles.isEmpty {
            sentences.append(String(localized: "Bringing the calendar in again copies what's missing."))
        }
        return sentences.joined(separator: " ")
    }

    static func missingTitle(_ count: Int) -> String {
        String(localized: "^[\(count) file](inflect: true) couldn't be copied")
    }

    static func failure(_ error: any Error) -> String {
        switch error as? CalendarImportError {
        case .notAnIthilFolder:
            return String(localized: "This isn't an Ithil folder: it has no calendar in it.")
        case .newerSchema:
            return String(
                localized: "This calendar was made by a newer Ithil, and this version of Elenath can't read it.")
        case .unreadable:
            return String(localized: "Ithil's calendar file can't be read, and neither can its backups.")
        case .insideLibrary:
            return String(localized: "That folder is part of your Elenath library. Choose your Ithil folder.")
        case nil:
            return String(localized: "Elenath couldn't bring the calendar in.") + " " + error.localizedDescription
        }
    }

    /// System Settings › Notifications, on Ithil's page where macOS supports it.
    @MainActor
    static func openIthilNotificationSettings() {
        let page = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.visaug36.Ithil"
        if let url = URL(string: page) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Where the import's progress lands: main-actor state that the background copy reports into.
@Observable @MainActor
final class BringInProgress {
    var value = FileCopyProgress(totalBytes: 0, totalFiles: 0)
}
