import ElenathCore
import Foundation
import SwiftUI

/// The colors a subject gives its events: the dot, the block fill and border, and a title color that
/// stays readable.
///
/// Event titles sit on the subject fill (20 % Night / 15 % Dawn over `BackgroundWindow`). `text` returns
/// the subject color itself when it reaches WCAG AA (4.5:1) there, which every palette color does in
/// Night. Otherwise it mixes the color toward `TextPrimary`, in 5 % steps, until it does: in Dawn the
/// palette needs about 20–30 % (Iris about 20, the others about 30), and custom colors get whatever
/// they need in either theme. Colors are resolved for the given scheme with `Color.resolve(in:)` and mixed in
/// sRGB; the palette results are worked out once.
///
/// Main-actor isolated, like the views that use it, so resolving colors in an `EnvironmentValues` is safe
/// whatever isolation the SDK gives those APIs; only `resource(for:)` is used elsewhere (menu swatches).
@MainActor
enum SubjectStyle {
    /// The subject's color: a palette asset (Night and Dawn variants) or its custom sRGB color.
    /// Events without a subject use `TextSecondary`.
    static func color(for subject: Subject?) -> Color {
        baseColor(subject?.color)
    }

    /// The asset-catalog color for a palette slot.
    nonisolated static func resource(for palette: PaletteColor) -> ColorResource {
        switch palette {
        case .clay: return .spaceClay
        case .teal: return .spaceTeal
        case .iris: return .spaceIris
        case .fern: return .spaceFern
        case .rose: return .spaceRose
        }
    }

    /// Event block fill: the subject color at 20 % (Night) or 15 % (Dawn).
    static func fill(for subject: Subject?, scheme: ColorScheme) -> Color {
        color(for: subject).opacity(fillOpacity(scheme))
    }

    /// Event block border: the subject color at about 35 %.
    static func border(for subject: Subject?, scheme: ColorScheme) -> Color {
        color(for: subject).opacity(borderOpacity)
    }

    /// A title color in the subject's hue with at least 4.5:1 contrast on the subject fill.
    static func text(for subject: Subject?, scheme: ColorScheme) -> Color {
        let choice = subject?.color
        if let precomputed = paletteText[TextKey(color: choice, scheme: scheme)] {
            return precomputed
        }
        return readableText(base: baseColor(choice), scheme: scheme)
    }

    // MARK: - Private

    private static let borderOpacity = 0.35
    /// WCAG AA for normal text is 4.5:1; the small margin absorbs rounding in the resolved colors.
    private static let minimumContrast = 4.55
    private static let mixSteps = 20

    private struct TextKey: Hashable, Sendable {
        var color: SubjectColor?
        var scheme: ColorScheme
    }

    /// Title colors for every palette slot (and for no subject) in both themes.
    private static let paletteText: [TextKey: Color] = {
        var colors: [TextKey: Color] = [:]
        var choices: [SubjectColor?] = [nil]
        for palette in PaletteColor.allCases {
            choices.append(.palette(palette))
        }
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            for choice in choices {
                let key = TextKey(color: choice, scheme: scheme)
                colors[key] = readableText(base: baseColor(choice), scheme: scheme)
            }
        }
        return colors
    }()

    private static func baseColor(_ choice: SubjectColor?) -> Color {
        switch choice {
        case .palette(let palette)?:
            return Color(resource(for: palette))
        case .custom(let red, let green, let blue)?:
            return Color(.sRGB, red: red, green: green, blue: blue)
        case nil:
            return Color.textSecondary
        }
    }

    private static func fillOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? Metrics.EventFill.night : Metrics.EventFill.dawn
    }

    private static func readableText(base: Color, scheme: ColorScheme) -> Color {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let subject = ContrastRGB(base.resolve(in: environment))
        let ink = ContrastRGB(Color.textPrimary.resolve(in: environment))
        let window = ContrastRGB(Color.backgroundWindow.resolve(in: environment))
        let background = window.mixed(with: subject, by: fillOpacity(scheme))
        for step in 0...mixSteps {
            let candidate = subject.mixed(with: ink, by: Double(step) / Double(mixSteps))
            if candidate.contrastRatio(with: background) >= minimumContrast {
                return step == 0 ? base : candidate.color
            }
        }
        return Color.textPrimary
    }
}

/// A gamma-encoded sRGB color, for contrast math.
private struct ContrastRGB {
    var red: Double
    var green: Double
    var blue: Double
}

extension ContrastRGB {
    init(_ resolved: Color.Resolved) {
        self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// This color moved `amount` (0…1) of the way toward `other`.
    func mixed(with other: ContrastRGB, by amount: Double) -> ContrastRGB {
        ContrastRGB(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    /// WCAG 2 relative luminance.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            let value = min(max(channel, 0), 1)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, 1…21.
    func contrastRatio(with other: ContrastRGB) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
