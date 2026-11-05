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
            .contentMargins(.bottom, 28, for: .scrollContent)
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
        .sheet(item: $env.pendingLink) { link in
            DeepLinkSheet(link: link)
        }
    }
}

/// Shows whatever a shared link or notification points at, over the current tab.
private struct DeepLinkSheet: View {
    var link: DeepLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch link.route {
                case .entry(let id): ReviewThreadView(entryID: id)
                case .user(let id): UserProfileView(userID: id)
                case .wineID(let id): WineDetailLoader(id: id)
                default: EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .appDestinations()
        }
    }
}

/// The raised, prominent Scan button centred over the tab bar.
private struct ScanTabButton: View {
    var action: () -> Void
    @State private var tapCount = 0

    var body: some View {
        Button { tapCount += 1; action() } label: {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Palette.burgundy, Palette.burgundyDeep], startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 56)
                    .shadow(color: Palette.burgundy.opacity(0.35), radius: 8, y: 3)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                    .frame(width: 56, height: 56)
                Circle().strokeBorder(Palette.gold.opacity(0.6), lineWidth: 1.5).frame(width: 56, height: 56)
                Image(systemName: "viewfinder")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .offset(y: -6)
        .sensoryFeedback(.impact(weight: .medium), trigger: tapCount)
        .accessibilityLabel("Scan a wine label")
        .accessibilityHint("Opens the camera to identify a bottle")
    }
}
