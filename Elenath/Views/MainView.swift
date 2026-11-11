import SwiftUI

/// The main window's content. For now it is the themed shell only: the starry sidebar and an empty state.
/// The library, the sidebar's sections and the editor arrive with version 0.1 (see docs/DESIGN.md).
struct MainView: View {
    /// The main window's scene ID, for `openWindow(id:)`.
    static let windowID = "main"

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: Metrics.sidebarMinimumWidth, ideal: Metrics.sidebarWidth, max: Metrics.sidebarMaximumWidth)
        } detail: {
            EmptyStateView(
                illustration: .emptySky,
                title: "Nothing here yet.",
                message: "This early build only shows Elenath’s window. Notes arrive in version 0.1."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .starryBackground(.backgroundWindow)
            .navigationTitle(Text(verbatim: "Elenath"))
        }
        .frame(minWidth: Metrics.windowMinimumWidth, minHeight: Metrics.windowMinimumHeight)
    }
}

/// The sidebar before there is a library: the app's name and what it means, on the starry sidebar
/// background.
private struct SidebarView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Elenath")
                    .font(Typography.sidebarTitle)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("All the stars together.")
                    .font(Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .starryBackground(.backgroundSidebar)
    }
}

#Preview {
    MainView()
        .environment(AppSettings.preview)
        .frame(width: 900, height: 620)
}
