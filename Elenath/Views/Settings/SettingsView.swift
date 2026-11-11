import SwiftUI

/// The Settings window. General is its only tab for now; Spaces and Files arrive with version 0.1.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
        }
        .frame(width: 520)
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings.preview)
}
