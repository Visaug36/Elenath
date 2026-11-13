import AppKit

/// Puts keyboard focus in the main window's toolbar search field, for Edit › Find… (⌘F).
///
/// SwiftUI's `.searchable(placement: .toolbar)` is an `NSSearchToolbarItem` on the Mac; asking it to
/// begin a search interaction also expands it when the toolbar collapsed it into a button (macOS 26) or
/// put it in the overflow menu. If the toolbar has no such item, the first search field in the window's
/// view hierarchy is focused instead.
@MainActor
enum SearchFocus {
    /// Focuses the search field of the key window, or else of the frontmost window that has one (bringing
    /// it forward). Does nothing when no window has one, e.g. while no calendar is open.
    static func focus() {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in candidates where window.isVisible {
            if focusSearch(in: window) {
                return
            }
        }
    }

    /// Focuses the window's search field; false when it has none.
    private static func focusSearch(in window: NSWindow) -> Bool {
        if let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            bringForward(window)
            item.beginSearchInteraction()
            return true
        }
        let toolbarViews = window.toolbar?.items.compactMap { $0.view } ?? []
        let roots = toolbarViews + [window.contentView?.superview ?? window.contentView].compactMap { $0 }
        for root in roots {
            if let field = searchField(in: root) {
                bringForward(window)
                return window.makeFirstResponder(field)
            }
        }
        return false
    }

    private static func bringForward(_ window: NSWindow) {
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The first visible search field in `view` or below it.
    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField, !field.isHiddenOrHasHiddenAncestor, field.isEnabled {
            return field
        }
        for subview in view.subviews {
            if let found = searchField(in: subview) {
                return found
            }
        }
        return nil
    }
}
