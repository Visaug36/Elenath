import SwiftUI

/// General: appearance (Night, Dawn, Match System).
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                AppearanceChooser(selection: $settings.appearance)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundWindow)
        .frame(height: 190)
    }
}

private struct AppearanceChooser: View {
    @Binding var selection: AppearanceChoice

    var body: some View {
        HStack(spacing: 18) {
            ForEach(AppearanceChoice.allCases, id: \.self) { choice in
                AppearanceCard(choice: choice, isSelected: selection == choice) {
                    selection = choice
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct AppearanceCard: View {
    let choice: AppearanceChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AppearanceThumbnailCard(choice: choice)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: Metrics.Glow.selectionRing)
                                .padding(-3)
                                .shadow(color: Color.accentColor.opacity(0.35), radius: 6)
                        }
                    }
                title
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(traits)
    }

    private var title: Text {
        switch choice {
        case .night: return Text("Night")
        case .dawn: return Text("Dawn")
        case .system: return Text("Match System")
        }
    }

    private var traits: AccessibilityTraits {
        isSelected ? [.isSelected] : []
    }
}

/// A miniature Elenath window in Night, Dawn, or both split along the diagonal.
private struct AppearanceThumbnailCard: View {
    let choice: AppearanceChoice

    var body: some View {
        ZStack {
            switch choice {
            case .night:
                AppearanceThumbnail()
                    .environment(\.colorScheme, .dark)
            case .dawn:
                AppearanceThumbnail()
                    .environment(\.colorScheme, .light)
            case .system:
                AppearanceThumbnail()
                    .environment(\.colorScheme, .dark)
                AppearanceThumbnail()
                    .environment(\.colorScheme, .light)
                    .clipShape(LowerTrailingTriangle())
            }
        }
        .frame(width: 112, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.separatorLine, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// The window drawn with the theme's own tokens, so the environment's color scheme picks Night or Dawn:
/// a sidebar with space dots, and a note with a title, a few lines and one amber selection.
private struct AppearanceThumbnail: View {
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            note
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule()
                .fill(Color.textPrimary.opacity(0.55))
                .frame(width: 16, height: 3)
                .padding(.bottom, 2)
            dot(.spaceTeal)
            dot(.spaceRose)
            dot(.spaceIris)
            dot(.spaceFern)
        }
        .padding(7)
        .frame(width: 32)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.backgroundSidebar)
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule()
                .fill(Color.textPrimary.opacity(0.8))
                .frame(width: 38, height: 4)
                .padding(.bottom, 2)
            line(width: 62)
            line(width: 54)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentSoft)
                .frame(width: 44, height: 7)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentText)
                        .frame(width: 30, height: 2)
                        .padding(.leading, 3)
                }
            line(width: 58)
            line(width: 36)
        }
        .padding(.horizontal, 9)
        .padding(.top, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.backgroundWindow)
    }

    private func dot(_ color: ColorResource) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color(color))
                .frame(width: 4, height: 4)
            Capsule()
                .fill(Color.textSecondary.opacity(0.5))
                .frame(width: 10, height: 2)
        }
    }

    private func line(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.textSecondary.opacity(0.5))
            .frame(width: width, height: 2)
    }
}

/// The lower-right half of a rectangle, cut along the diagonal from top right to bottom left.
private struct LowerTrailingTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppSettings.preview)
        .frame(width: 520)
}
