import AppKit
import SwiftUI

/// The folder exists but holds no library, and there is no backup to restore one from.
struct NoLibraryView: View {
    let path: String
    @Environment(AppModel.self) private var model

    var body: some View {
        FolderSetupScreen(title: title, message: message, path: path) {
            Button("Start a New Library Here") {
                model.startFresh()
            }
            .buttonStyle(FolderSetupButtonStyle(isProminent: true))
            .keyboardShortcut(.defaultAction)
            Button("Choose Another Folder…") {
                chooseAnotherFolder(model: model)
            }
            .buttonStyle(FolderSetupButtonStyle(isProminent: false))
        }
    }

    private var title: Text {
        Text("There's no library in this folder")
    }

    private var message: Text {
        Text("Elenath found no library file here, and no backup to restore one from.")
    }
}

/// The library file is damaged and couldn't be restored. The file is left untouched, and so are the
/// notes.
struct UnreadableLibraryView: View {
    let path: String
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        FolderSetupScreen(title: title, message: Text(verbatim: message), path: path.isEmpty ? nil : path) {
            Button("Try Again") {
                model.retryLoad()
            }
            .buttonStyle(FolderSetupButtonStyle(isProminent: true))
            .keyboardShortcut(.defaultAction)
            Button("Choose Another Folder…") {
                chooseAnotherFolder(model: model)
            }
            .buttonStyle(FolderSetupButtonStyle(isProminent: false))
            if !path.isEmpty {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path, directoryHint: .isDirectory)])
                }
                .buttonStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(Color.accentText)
                .padding(.top, 4)
            }
        }
    }

    private var title: Text {
        Text("Elenath can't open this library")
    }
}

@MainActor
private func chooseAnotherFolder(model: AppModel) {
    guard let url = FolderAccess.chooseExistingFolder() else { return }
    model.useFolder(url)
}
