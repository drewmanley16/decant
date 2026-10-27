import SwiftUI

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        ZStack(alignment: .bottom) {
            TabView(selection: $env.selectedTab) {
                DiscoverView()
                    .tabItem { Label("Discover", systemImage: "sparkles") }
                    .tag(AppTab.discover)
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
                Color.clear
                    .tabItem { Label("Scan", systemImage: "") }
                    .tag(AppTab.scan)
                CellarView()
                    .tabItem { Label("Cellar", systemImage: "square.stack.3d.up.fill") }
                    .tag(AppTab.cellar)
                ProfileView()
                    .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                    .tag(AppTab.profile)
            }
            .onChange(of: env.selectedTab) { old, new in
                // The Scan tab is an action, not a destination.
                if new == .scan {
                    env.selectedTab = old
                    env.isScannerPresented = true
                }
            }

            ScanTabButton { env.isScannerPresented = true }
                .padding(.bottom, 2)
        }
        .fullScreenCover(isPresented: $env.isScannerPresented) {
            ScanFlowView()
        }
    }
}

/// The raised, prominent Scan button centred over the tab bar.
private struct ScanTabButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Palette.burgundy, Palette.burgundyDeep], startPoint: .top, endPoint: .bottom))
                    .frame(width: 62, height: 62)
                    .shadow(color: Palette.burgundy.opacity(0.4), radius: 10, y: 4)
                Circle().strokeBorder(Palette.gold.opacity(0.6), lineWidth: 1.5).frame(width: 62, height: 62)
                Image(systemName: "viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .offset(y: -18)
        .accessibilityLabel("Scan a wine label")
        .accessibilityHint("Opens the camera to identify a bottle")
    }
}
