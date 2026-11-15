import AppKit
import SwiftUI

/// The layout every folder screen shares, in the style of the empty states: the app icon, a New York
/// headline, an explanation, optionally the folder's path, then the buttons, all centered on the starry
/// window background (from Ithil).
struct FolderSetupScreen<Actions: View>: View {
    private let title: Text
    private let message: Text
    private let path: String?
    private let footnote: Text?
    private let actions: Actions

    init(
        title: Text,
        message: Text,
        path: String? = nil,
        footnote: Text? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.path = path
        self.footnote = footnote
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                column
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .starryBackground(.backgroundWindow)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private var column: some View {
        VStack(spacing: 22) {
            AppIconImage()
            VStack(spacing: 10) {
                title
                    .font(Typography.windowTitle)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                message
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
                if let path {
                    FolderPathLabel(path: path)
                        .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                actions
            }
            if let footnote {
                footnote
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
    }
}

/// The two button looks of the folder screens and onboarding: amber for the main action (with dark ink,
/// which keeps AA contrast on amber in both themes) and a quiet filled one for the rest.
struct FolderSetupButtonStyle: ButtonStyle {
    var isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        FolderSetupButtonLabel(configuration: configuration, isProminent: isProminent)
    }
}

private struct FolderSetupButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.control + 1, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isProminent ? Color.textOnAccent : Color.textPrimary)
            .frame(minWidth: 220)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
    }

    private var fill: Color {
        let base = isProminent ? Color.accentColor : Color.controlFill
        return configuration.isPressed ? base.opacity(0.8) : base
    }

    private var border: Color {
        if isProminent {
            return .clear
        }
        return contrast == .increased ? Color.textSecondary : Color.separatorLine
    }
}

/// `folder` + the path with the home folder shown as "~", on a control-fill capsule. Selectable, so it
/// can be copied.
struct FolderPathLabel: View {
    let path: String

    var body: some View {
        let displayPath = FolderAccess.displayPath(path)
        Label {
            Text(verbatim: displayPath)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "folder")
                .accessibilityHidden(true)
        }
        .font(Typography.secondary)
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.controlFill))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Folder: \(displayPath)"))
    }
}

/// The app icon, as Finder shows it. Decorative, so VoiceOver skips it. Also used by onboarding.
struct AppIconImage: View {
    var size: CGFloat = 112

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
