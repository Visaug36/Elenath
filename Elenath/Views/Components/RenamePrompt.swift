import AppKit

/// A small window that asks for a new name. Used where a name isn't edited in place: folders, and notes
/// from a list.
@MainActor
enum RenamePrompt {
    /// Asks for a name, starting from `current`, and calls `rename` with it unless the user cancels or
    /// leaves it as it was.
    static func run(title: String, current: String, rename: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel(String(localized: "Name"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current else { return }
        rename(name)
    }
}
