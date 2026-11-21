import AppKit

/// The "Add Files…" open panel: any number of files and folders, to be copied into an event's folder.
@MainActor
enum AddFilesPanel {
    /// Asks which files and folders to copy into the event's folder `folderName`. Empty when cancelled.
    static func chooseFiles(for folderName: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Files")
        panel.message = String(
            localized: "Choose files or folders to copy into “\(folderName)”. The originals stay where they are.")
        panel.prompt = String(localized: "Add")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
