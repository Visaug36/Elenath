import SwiftUI

/// The Settings window: General, Spaces, Calendar, Subjects and Files.
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
            CalendarSettingsView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
            SubjectsSettingsView()
                .tabItem {
                    Label("Subjects", systemImage: "circle.hexagongrid")
                }
            FilesSettingsView()
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
        }
        .frame(width: 560)
    }
}
