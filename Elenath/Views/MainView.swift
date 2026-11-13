import ElenathCore
import SwiftUI

/// The main window's content: one screen per `LibraryState`, plus the alerts for a restored settings
/// file, a folder that can't be used and something that couldn't be done.
///
/// Until onboarding is done (`AppSettings.hasCompletedOnboarding`), `.needsFolder` shows onboarding's
/// welcome and folder pages, and `.ready` its first-spaces page; afterwards they show `ChooseFolderView`
/// and the library. The window's undo manager becomes `AppModel.undoManager`, so Edit › Undo and Redo
/// reach what was done to notes, folders and spaces.
struct MainView: View {
    /// The main window's scene ID, for `openWindow(id:)`.
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        content
            .frame(minWidth: Metrics.windowMinimumWidth, minHeight: Metrics.windowMinimumHeight)
            .modifier(RecoveryAlert())
            .modifier(FolderErrorAlert())
            .modifier(OperationErrorAlert())
            .onAppear {
                model.undoManager = undoManager
            }
            .onChange(of: undoManager) { _, newValue in
                model.undoManager = newValue
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .needsFolder:
            if settings.hasCompletedOnboarding {
                ChooseFolderView()
            } else {
                OnboardingView(startAt: .welcome)
            }
        case .loading:
            LoadingView(isStarry: !settings.hasCompletedOnboarding)
        case .ready:
            if settings.hasCompletedOnboarding {
                LibraryWindow()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if model.isReadOnly {
                            ReadOnlyBanner()
                        }
                    }
            } else {
                OnboardingView(startAt: .spaces)
            }
        case .folderMissing(let path):
            FolderMissingView(path: path)
        case .noLibrary(let path):
            NoLibraryView(path: path)
        case .unreadable(let path, let message):
            UnreadableLibraryView(path: path, message: message)
        }
    }
}

/// A quiet spinner while the library opens. It only appears after a moment, so a fast launch doesn't
/// flash it. During onboarding it keeps the star field, so the stars don't blink out between pages.
private struct LoadingView: View {
    /// Whether to lay the star field over the background (during onboarding).
    var isStarry = false
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Opening your library"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color.backgroundWindow
                if isStarry {
                    StarField()
                }
            }
            .ignoresSafeArea()
        }
        .task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                showsSpinner = true
            } catch {}
        }
    }
}

/// A slim strip along the bottom of the window while the library is read-only.
private struct ReadOnlyBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.accentText)
                .accessibilityHidden(true)
            Text("Read-only: this library was saved by a newer version of Elenath. Update Elenath to make changes.")
                .font(Typography.secondary)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.backgroundSidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecoveryAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var alerts = model
        let message = model.recoveryNotice
        let isPresented = $alerts.showsRecoveryNotice
        content.alert("Elenath looked after your library", isPresented: isPresented, presenting: message) { _ in
            Button("OK") {}
        } message: { message in
            Text(verbatim: message)
        }
    }
}

private struct FolderErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var alerts = model
        let message = model.folderError
        let isPresented = $alerts.showsFolderError
        content.alert("Elenath can't use that folder", isPresented: isPresented, presenting: message) { _ in
            Button("OK") {}
        } message: { message in
            Text(verbatim: message)
        }
    }
}

private struct OperationErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var alerts = model
        let message = model.operationError
        let isPresented = $alerts.showsOperationError
        content.alert("That didn't work", isPresented: isPresented, presenting: message) { _ in
            Button("OK") {}
        } message: { message in
            Text(verbatim: message)
        }
    }
}
