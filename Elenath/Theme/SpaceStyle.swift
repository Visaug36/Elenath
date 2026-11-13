import AppKit
import ElenathCore
import SwiftUI

/// The colors a space gives the things that belong to it: its symbol and dot in the sidebar, and the
/// links that point into it.
@MainActor
enum SpaceStyle {
    /// The space's color: a palette asset (Night and Dawn variants) or its custom sRGB color. Things that
    /// belong to no space (the Inbox) use `TextSecondary`.
    static func color(for space: Space?) -> Color {
        guard let space else { return Color.textSecondary }
        switch space.color {
        case .palette(let palette):
            return Color(resource(for: palette))
        case .custom(let red, let green, let blue):
            return Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }
    }

    /// The same color for AppKit: the text view draws links with it.
    static func nsColor(for space: Space?) -> NSColor {
        guard let space else { return NSColor(resource: .textSecondary) }
        switch space.color {
        case .palette(let palette):
            return NSColor(resource: resource(for: palette))
        case .custom(let red, let green, let blue):
            return NSColor(
                srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    /// The asset-catalog color for a palette slot.
    nonisolated static func resource(for palette: PaletteColor) -> ColorResource {
        switch palette {
        case .clay: .spaceClay
        case .teal: .spaceTeal
        case .iris: .spaceIris
        case .fern: .spaceFern
        case .rose: .spaceRose
        }
    }

    /// A soft fill in the space's color, for a capsule that names the space.
    static func fill(for space: Space?) -> Color {
        color(for: space).opacity(0.18)
    }

    /// The space's symbol, or the folder if the name isn't an SF Symbol this Mac has.
    static func symbol(for space: Space) -> String {
        NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil) == nil
            ? Space.fallbackSymbol : space.symbol
    }
}

/// A small filled circle in a space's color. Decorative: what it sits next to carries the VoiceOver label.
struct SpaceDot: View {
    let space: Space?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(SpaceStyle.color(for: space))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The symbol of a kind of note.
enum KindStyle {
    static func symbol(for kind: NoteKind) -> String {
        switch kind {
        case .note: "doc.text"
        case .idea: "lightbulb"
        case .goal: "star"
        }
    }

    static func name(for kind: NoteKind) -> String {
        switch kind {
        case .note: String(localized: "Note", comment: "A kind of note")
        case .idea: String(localized: "Idea", comment: "A kind of note")
        case .goal: String(localized: "Goal", comment: "A kind of note")
        }
    }
}

/// Dates as lists show them.
enum DateText {
    /// "14:30" for today, "Mon" within the last week, "10 Nov" this year, "10 Nov 2025" before that.
    static func short(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, (0..<6).contains(days) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "2 hours ago", counted from `now`.
    static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
