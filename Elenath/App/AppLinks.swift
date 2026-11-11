import AppKit
import Foundation

/// The project's pages on GitHub, for the Help menu.
///
/// They open in the user's browser with `NSWorkspace`. Elenath itself never makes a network request (it
/// has no network entitlement); handing a link to the browser is the browser's business.
enum AppLinks {
    /// https://github.com/Visaug36/Elenath
    static let repository = URL(string: "https://github.com/Visaug36/Elenath")!
    /// The releases page, where "Check for Updates…" sends the user.
    static let releases = URL(string: "https://github.com/Visaug36/Elenath/releases")!
    /// The issue template chooser (bug report or feature request).
    static let newIssue = URL(string: "https://github.com/Visaug36/Elenath/issues/new/choose")!

    /// Opens `url` in the default browser.
    @MainActor
    static func open(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }
}
