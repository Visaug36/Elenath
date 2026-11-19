import SwiftUI

/// Sizes, spacing and corner radii from docs/DESIGN.md. Colors and images live in Assets.xcassets.
enum Metrics {
    /// Everything snaps to a 4 pt grid.
    static let grid: CGFloat = 4

    static let sidebarWidth: CGFloat = 244
    static let sidebarMinimumWidth: CGFloat = 200
    static let sidebarMaximumWidth: CGFloat = 320
    static let toolbarHeight: CGFloat = 52
    static let toolbarHeightLargeTitle: CGFloat = 64
    /// The calendar's grids (Ithil's): the week header, an hour of the time grid, the time gutter.
    static let weekHeaderHeight: CGFloat = 56
    static let hourRowHeight: CGFloat = 48
    static let timeGutterWidth: CGFloat = 56
    /// The widest a note's text column gets, so lines stay readable in a wide window.
    static let editorColumnWidth: CGFloat = 720
    /// The smallest size of the main window's content.
    static let windowMinimumWidth: CGFloat = 720
    static let windowMinimumHeight: CGFloat = 480

    enum Padding {
        static let popover: CGFloat = 18
        static var formRow: EdgeInsets { EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14) }
        static var sidebarRow: EdgeInsets { EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8) }
    }

    enum Radius {
        static let eventBlock: CGFloat = 6
        static let control: CGFloat = 6
        static let listRow: CGFloat = 7
        static let formGroup: CGFloat = 10
        static let card: CGFloat = 10
        static let dropZone: CGFloat = 10
        static let popover: CGFloat = 12
        static let panel: CGFloat = 14
    }

    /// Event blocks are filled with their subject color at this opacity.
    enum EventFill {
        static let night: Double = 0.20
        static let dawn: Double = 0.15
    }

    /// Glows appear only on a selection and on a drop target.
    enum Glow {
        static let selectionRing: CGFloat = 1.5
        static let selectionShadowRadius: CGFloat = 14
        static let dropRing: CGFloat = 1.5
        static let dropShadowRadius: CGFloat = 32
        static let dropShadowOpacity: Double = 0.32
    }
}
