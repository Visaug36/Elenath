import AppKit
import ElenathCore
import SwiftUI

/// Files: where the library is, with Show in Finder and Change…; the index, with Rebuild Index; and the
/// diagnostics report.
struct FilesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var choice: LibraryFolderChoice?
    @State private var isWorking = false
    @State private var moveError: String?
    @State private var report = ""
    @State private var isRunningDiagnostics = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Library folder") {
                    Text(verbatim: model.rootURL.map { FolderAccess.displayPath($0.path) } ?? "—")
                        .font(Typography.secondary)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if model.isMovingLibrary {
                        ProgressView()
                            .controlSize(.small)
                        Text("Moving your library…")
                            .font(Typography.secondary)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        if let root = model.rootURL {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                    .disabled(model.rootURL == nil)
                    Button("Change…") {
                        chooseFolder()
                    }
                    .disabled(!model.canEdit || model.isDemo || isWorking)
                    .accessibilityHint(Text("Moves your library to another folder, or opens another Elenath folder"))
                }
            } footer: {
                Text(footer)
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Index") {
                LabeledContent("Search index") {
                    Text(model.isIndexing ? "Updating…" : "Up to date")
                        .font(Typography.secondary)
                        .foregroundStyle(Color.textSecondary)
                }
                HStack {
                    Text(
                        "The index is rebuilt from your notes whenever it is missing. It never holds anything that isn't in the folder."
                    )
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Rebuild Index") {
                        Task {
                            await model.rebuildIndex()
                        }
                    }
                    .disabled(model.state != .ready || model.isIndexing)
                }
            }
            Section("Diagnostics") {
                HStack {
                    Text(
                        "Checks what only this Mac can tell: Apple Intelligence, the language models, and the folder access. Nothing leaves your Mac."
                    )
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if isRunningDiagnostics {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Run Diagnostics") {
                        runDiagnostics()
                    }
                    .disabled(isRunningDiagnostics)
                }
                if !report.isEmpty {
                    ScrollView {
                        Text(verbatim: report)
                            .font(Typography.code)
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    HStack {
                        Spacer()
                        Button("Copy Report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundWindow)
        .frame(height: 520)
        .alert("What should Elenath do with this folder?", isPresented: choiceIsShown, presenting: choice) { choice in
            switch choice {
            case .move(let chosen, _):
                Button("Move Library") {
                    move(to: chosen)
                }
                Button("Cancel", role: .cancel) {}
            case .otherLibrary(let folder):
                Button("Open That Library") {
                    model.openOtherLibrary(at: folder)
                }
                Button("Cancel", role: .cancel) {}
            default:
                Button("OK", role: .cancel) {}
            }
        } message: { choice in
            Text(verbatim: message(for: choice))
        }
        .alert("Couldn't Move Your Library", isPresented: moveErrorIsShown, presenting: moveError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
    }

    private var footer: String {
        if model.isDemo {
            return String(
                localized: "Demo mode uses a temporary folder with invented notes. Your own library isn't touched.")
        }
        return String(localized: "Copy this folder to back up everything. Moving it here keeps Elenath pointed at it.")
    }

    private var choiceIsShown: Binding<Bool> {
        Binding(get: { choice != nil }, set: { if !$0 { choice = nil } })
    }

    private var moveErrorIsShown: Binding<Bool> {
        Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })
    }

    private func message(for choice: LibraryFolderChoice) -> String {
        switch choice {
        case .move(_, let newRoot):
            String(
                localized:
                    "Your spaces, the Inbox and Elenath's own files move to \(FolderAccess.displayPath(newRoot.path)). Loose files in the old folder stay where they are."
            )
        case .otherLibrary(let folder):
            String(
                localized:
                    "\(FolderAccess.displayPath(folder.path)) is another Elenath library. Open it instead? This one stays as it is."
            )
        case .currentLibrary:
            String(localized: "That is the folder your library is in already.")
        case .insideCurrentLibrary:
            String(localized: "A library can't move into a folder inside itself.")
        case .unavailable:
            String(localized: "Elenath can't use that folder.")
        }
    }

    private func chooseFolder() {
        guard let current = model.rootURL else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Move Your Library")
        panel.message = String(localized: "Choose where your library should be, or another Elenath folder to open.")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        isWorking = true
        Task {
            let evaluated = await Task.detached(priority: .userInitiated) {
                LibraryFolderChoice.evaluate(chosen, currentRoot: current)
            }.value
            isWorking = false
            choice = evaluated
        }
    }

    private func move(to chosen: URL) {
        Task {
            do {
                try await model.moveLibrary(toChosen: chosen)
            } catch {
                moveError = LibraryMessages.operationFailed(error)
            }
        }
    }

    private func runDiagnostics() {
        isRunningDiagnostics = true
        Task {
            report = await Diagnostics.run(model: model)
            isRunningDiagnostics = false
        }
    }
}
