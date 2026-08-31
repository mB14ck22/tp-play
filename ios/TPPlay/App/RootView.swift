import SwiftUI

struct RootView: View {
    @AppStorage("appAppearance") private var appearanceValue = AppAppearance.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceValue) ?? .system
    }

    var body: some View {
        TabView {
            ConsoleLibraryView()
                .tabItem {
                    Label("串流", systemImage: "play.rectangle.fill")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .tint(TPPlayTheme.accent)
        .preferredColorScheme(appearance.colorScheme)
    }
}

#Preview {
    RootView()
}
