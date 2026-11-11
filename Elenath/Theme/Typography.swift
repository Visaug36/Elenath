import SwiftUI

/// Type scale from docs/DESIGN.md: New York (serif) semibold for titles and headings, SF Pro for
/// everything else, SF Mono for code. Times and counts use tabular numerals; apply `.monospacedDigit()`
/// where they're shown.
enum Typography {
    static var windowTitle: Font { .system(size: 26, weight: .semibold, design: .serif) }
    static var noteTitle: Font { .system(size: 28, weight: .semibold, design: .serif) }
    static var detailTitle: Font { .system(size: 22, weight: .semibold, design: .serif) }
    static var emptyHeadline: Font { .system(size: 20, weight: .semibold, design: .serif) }
    static var sidebarTitle: Font { .system(size: 18, weight: .semibold, design: .serif) }

    static var body: Font { .system(size: 13) }
    static var secondary: Font { .system(size: 12.5) }
    static var caption: Font { .system(size: 11, weight: .semibold) }
    static var footnote: Font { .system(size: 11) }
    static var code: Font { .system(size: 12.5, design: .monospaced) }
}
