import SwiftUI

/// Where Elenath should keep the notes, when there is no folder yet.
///
/// Onboarding shows the same words and the same `ChooseFolderActions` as its second page; this screen is
/// for when onboarding is already done (for example after the saved folder was forgotten).
struct ChooseFolderView: View {
    var body: some View {
        FolderSetupScreen(title: Self.title, message: Self.message, footnote: Self.footnote) {
            ChooseFolderActions()
        }
    }

    /// The headline, shared with onboarding.
    static var title: Text {
        Text("Choose where Elenath keeps your notes")
    }

    /// The explanation under the headline, shared with onboarding.
    static var message: Text {
        Text("Notes are Markdown files in real folders, so you can also open them in Finder.")
    }

    /// The backup hint under the buttons, shared with onboarding.
    static var footnote: Text {
        Text("Copy the folder to back up everything, or open it on another Mac to pick up where you left off.")
    }
}

/// "Create Elenath Folder…" (suggesting ~/Documents/Elenath) and "Use Existing Folder…". Both hand the
/// chosen folder to `AppModel.useFolder`, which applies `LibraryFolderPolicy` and opens or creates the
/// library.
///
/// Shared by `ChooseFolderView` and onboarding, so choosing a folder works the same way in both. Lay it
/// out in a `VStack(spacing: 10)`.
struct ChooseFolderActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Create Elenath Folder…") {
            createFolder()
        }
        .buttonStyle(FolderSetupButtonStyle(isProminent: true))
        .keyboardShortcut(.defaultAction)
        Text("Suggested: \(FolderAccess.suggestedFolderDisplayPath)")
            .font(Typography.footnote)
            .foregroundStyle(Color.textTertiary)
            .padding(.bottom, 6)
        Button("Use Existing Folder…") {
            chooseFolder()
        }
        .buttonStyle(FolderSetupButtonStyle(isProminent: false))
        .accessibilityHint(
            Text("Opens an Elenath folder you already have, or creates one inside the folder you pick"))
    }

    private func createFolder() {
        guard let url = FolderAccess.createFolder() else { return }
        model.useFolder(url)
    }

    private func chooseFolder() {
        guard let url = FolderAccess.chooseExistingFolder() else { return }
        model.useFolder(url)
    }
}
