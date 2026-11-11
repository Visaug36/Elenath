import SwiftUI

/// The menu bar: no File › New Window (Elenath has one main window), the sidebar commands in the View
/// menu, and a Help menu that opens the project's GitHub pages in the browser (Elenath itself never goes
/// online).
struct ElenathCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .help) {
            HelpCommands()
        }
        SidebarCommands()
    }
}

/// The Help menu: the project's pages on GitHub, opened in the browser.
private struct HelpCommands: View {
    var body: some View {
        Button("Elenath on GitHub") {
            AppLinks.open(AppLinks.repository)
        }
        Divider()
        Button("Check for Updates…") {
            AppLinks.open(AppLinks.releases)
        }
        Button("Report an Issue…") {
            AppLinks.open(AppLinks.newIssue)
        }
    }
}
