import SwiftUI

/// Typed navigation destinations shared by every tab's NavigationStack.
enum Route: Hashable {
    case wine(Wine)
    case wineID(UUID)
    case user(UUID)
    case entry(UUID)
    case stats
    case wishlist
    case scanHistory
    case notifications
    case settings
    case followers(UUID)
    case following(UUID)
    case milestones
}

extension View {
    func appDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .wine(let wine): WineDetailView(wine: wine)
            case .wineID(let id): WineDetailLoader(id: id)
            case .user(let id): UserProfileView(userID: id)
            case .entry(let id): ReviewThreadView(entryID: id)
            case .stats: StatsView()
            case .wishlist: WishlistView()
            case .scanHistory: ScanHistoryView()
            case .notifications: NotificationsView()
            case .settings: SettingsView()
            case .followers(let id): PeopleListView(userID: id, kind: .followers)
            case .following(let id): PeopleListView(userID: id, kind: .following)
            case .milestones: MilestonesView()
            }
        }
    }
}

/// Resolves a wine by id before showing its details.
struct WineDetailLoader: View {
    var id: UUID
    @Environment(AppEnvironment.self) private var env
    @State private var state: Loadable<Wine> = .idle

    var body: some View {
        Group {
            switch state {
            case .loaded(let wine): WineDetailView(wine: wine)
            case .failed(let message): ErrorStateView(message: message) { Task { await load() } }
            default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .screenBackground()
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do { state = .loaded(try await env.catalog.wine(id: id)) } catch { state = .failed(error.localizedDescription) }
    }
}
