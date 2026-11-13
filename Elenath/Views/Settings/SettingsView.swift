import SwiftUI

/// The Settings window: General, Spaces and Files.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            SpacesSettingsView()
                .tabItem {
                    Label("Spaces", systemImage: "circle.grid.2x2")
                }
            FilesSettingsView()
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
        }
        .frame(width: 560)
    }
}
