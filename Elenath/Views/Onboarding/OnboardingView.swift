import ElenathCore
import SwiftUI

/// The first launch (docs/DESIGN.md, "Onboarding"): welcome, choose a folder, make the first spaces.
///
/// Choosing a folder opens or creates the library, which takes `MainView` through `.loading` to
/// `.ready`; it then shows this view again at the spaces page. Finishing that page marks onboarding as
/// done.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, folder, spaces
    }

    @State private var step: Step
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(startAt step: Step) {
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome:
                    WelcomePage { go(to: .folder) }
                        .transition(transition)
                case .folder:
                    FolderPage()
                        .transition(transition)
                case .spaces:
                    FirstSpacesPage()
                        .transition(transition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StepDots(current: step)
                .padding(.bottom, 28)
        }
        .starryBackground(.backgroundWindow)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private var transition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .offset(x: 40).combined(with: .opacity), removal: .offset(x: -40).combined(with: .opacity))
    }

    private func go(to next: Step) {
        withAnimation(.easeOut(duration: 0.25)) {
            step = next
        }
    }
}

/// Three 7 pt dots, the current one amber.
private struct StepDots: View {
    let current: OnboardingView.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingView.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.textTertiary.opacity(0.5))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current.rawValue + 1) of \(OnboardingView.Step.allCases.count)"))
    }
}

/// The layout every page shares: the icon, a headline, one line, the page's content, its buttons.
private struct OnboardingPage<Content: View>: View {
    let title: Text
    let message: Text
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AppIconImage(size: 96)
                VStack(spacing: 8) {
                    title
                        .font(Typography.windowTitle)
                        .foregroundStyle(Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    message
                        .font(Typography.body)
                        .foregroundStyle(Color.textSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                content
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct WelcomePage: View {
    let onContinue: () -> Void
    @Environment(AppSettings.self) private var settings

    var body: some View {
        OnboardingPage(
            title: Text("Welcome to Elenath"), message: Text("One private place for your notes, on your Mac.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                point("lock", Text("Offline and private"), Text("Nothing you write leaves this Mac."))
                point("folder", Text("Plain files in a real folder"), Text("Markdown that any app can open."))
                point("keyboard", Text("Capture from anywhere"), captureLine)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.backgroundRaised, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                    .strokeBorder(Color.separatorLine, lineWidth: 1)
            }
            Button("Continue", action: onContinue)
                .buttonStyle(FolderSetupButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var captureLine: Text {
        if let shortcut = settings.quickCaptureHotKey?.displayString {
            return Text("Press \(shortcut) in any app to jot something down.")
        }
        return Text("Jot something down from any app.")
    }

    private func point(_ symbol: String, _ title: Text, _ detail: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentText)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                detail
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FolderPage: View {
    var body: some View {
        OnboardingPage(title: ChooseFolderView.title, message: ChooseFolderView.message) {
            VStack(spacing: 10) {
                ChooseFolderActions()
            }
            ChooseFolderView.footnote
                .font(Typography.secondary)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The spaces to start with, each switched on or off, renamed, and sealed or not.
private struct FirstSpacesPage: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var rows: [Row] = Row.suggestions
    @State private var isCreating = false

    struct Row: Identifiable {
        let id = UUID()
        var isOn: Bool
        var name: String
        var symbol: String
        var color: PaletteColor
        var isSealed: Bool
        var description: String
        var keywords: [String]

        static var suggestions: [Row] {
            [
                Row(
                    isOn: true, name: String(localized: "Uni"), symbol: "graduationcap", color: .teal, isSealed: false,
                    description: String(localized: "University courses and coursework."),
                    keywords: ["uni", "lecture", "exam"]),
                Row(
                    isOn: true, name: String(localized: "Red Cross"), symbol: "cross.case", color: .rose,
                    isSealed: true,
                    description: String(localized: "Volunteer work, kept apart from everything else."),
                    keywords: ["red cross", "first aid", "shift"]),
                Row(
                    isOn: true, name: String(localized: "Ideas"), symbol: "lightbulb", color: .iris, isSealed: false,
                    description: String(localized: "Things worth thinking about."), keywords: ["idea"]),
                Row(
                    isOn: true, name: String(localized: "Personal"), symbol: "person", color: .fern, isSealed: false,
                    description: String(localized: "Everything else."), keywords: ["personal"]),
            ]
        }
    }

    var body: some View {
        OnboardingPage(
            title: Text("Make your first spaces"),
            message: Text("A space is a folder for one part of your life. You can change these any time.")
        ) {
            if model.spaces.isEmpty {
                VStack(spacing: 0) {
                    ForEach($rows) { $row in
                        SpaceRowEditor(row: $row)
                        if row.id != rows.last?.id {
                            Rectangle()
                                .fill(Color.separatorLine)
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(
                    Color.backgroundRaised, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                        .strokeBorder(Color.separatorLine, lineWidth: 1)
                }
                Button("Add Another…") {
                    rows.append(
                        Row(
                            isOn: true, name: String(localized: "New Space"), symbol: "folder", color: .clay,
                            isSealed: false, description: "", keywords: []))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentText)
                Text(
                    "A sealed space keeps its notes to itself: they never show up in search, links or suggestions anywhere else."
                )
                .font(Typography.secondary)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This library has \(model.spaces.count) spaces already.")
                    .font(Typography.body)
                    .foregroundStyle(Color.textSecondary)
            }
            Button(model.spaces.isEmpty ? "Create Spaces" : "Continue") {
                finish()
            }
            .buttonStyle(FolderSetupButtonStyle(isProminent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(isCreating)
        }
    }

    private func finish() {
        guard model.spaces.isEmpty else {
            settings.hasCompletedOnboarding = true
            return
        }
        isCreating = true
        let chosen = rows.filter { $0.isOn && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { row in
            Space(
                name: row.name, color: .palette(row.color), symbol: row.symbol, isSealed: row.isSealed,
                description: row.description, keywords: row.keywords)
        }
        Task {
            await model.createFirstSpaces(chosen)
            isCreating = false
            settings.hasCompletedOnboarding = true
        }
    }
}

private struct SpaceRowEditor: View {
    @Binding var row: FirstSpacesPage.Row

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $row.isOn) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel(Text("Create \(row.name)"))
            Image(systemName: row.symbol)
                .foregroundStyle(Color(SpaceStyle.resource(for: row.color)))
                .frame(width: 20)
                .accessibilityHidden(true)
            TextField("Name", text: $row.name)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .disabled(!row.isOn)
            Spacer()
            Toggle("Sealed", isOn: $row.isSealed)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.accentColor)
                .font(Typography.secondary)
                .disabled(!row.isOn)
        }
        .padding(.vertical, 10)
        .opacity(row.isOn ? 1 : 0.55)
    }
}
