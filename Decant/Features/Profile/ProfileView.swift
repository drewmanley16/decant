import SwiftUI

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            Group {
                if let me = env.currentUser {
                    ProfileContent(userID: me.id, isMe: true)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .appDestinations()
        }
    }
}

struct UserProfileView: View {
    var userID: UUID
    @Environment(AppEnvironment.self) private var env

    @State private var reporting = false
    @State private var confirmBlock = false

    var body: some View {
        ProfileContent(userID: userID, isMe: userID == env.currentUser?.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if userID != env.currentUser?.id {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { reporting = true } label: { Label("Report account", systemImage: "flag") }
                            Button(role: .destructive) { confirmBlock = true } label: { Label("Block", systemImage: "hand.raised") }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More options")
                    }
                }
            }
            .sheet(isPresented: $reporting) { ReportSheet(target: .user(userID)) }
            .confirmationDialog("Block this account?", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { Task { await BlockAction.block(userID, name: "this account", env: env) } }
            } message: {
                Text("They won't be able to see your profile or content, and you won't see theirs.")
            }
    }
}

private struct ProfileContent: View {
    var userID: UUID
    var isMe: Bool
    @Environment(AppEnvironment.self) private var env
    @State private var summary: Loadable<ProfileSummary> = .idle
    @State private var diary: [ReviewItem] = []
    @State private var stats = WineStats()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch summary {
                case .loaded(let s):
                    header(s)
                    if s.canViewContent {
                        if isMe { shortcuts }
                        statsTeaser
                        diarySection
                    } else {
                        EmptyStateView(symbol: "lock.fill", title: "This profile is private",
                                       message: s.isFollowing ? "Your follow request is pending." : "Follow to see their tastings.")
                    }
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                default:
                    VStack(spacing: 16) {
                        SkeletonBlock(width: 84, height: 84, radius: 42)
                        SkeletonBlock(width: 160, height: 22)
                        SkeletonBlock(height: 120, radius: Metrics.cardRadius)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(Metrics.gutter)
        }
        .screenBackground()
        .refreshable { await load() }
        .task(id: userID) { await load() }
        .onChange(of: env.diaryRevision) { Task { await load() } }
        .onChange(of: env.moderationRevision) { Task { await load() } }
    }

    private func load() async {
        do {
            let s = try await env.social.profileSummary(userID: userID)
            summary = .loaded(s)
            if s.canViewContent {
                diary = try await env.tastings.entries(forUser: userID)
                stats = StatsCalculator.compute(diary)
            }
        } catch {
            summary = .failed(error.localizedDescription)
        }
    }

    private func header(_ s: ProfileSummary) -> some View {
        VStack(spacing: 14) {
            AvatarView(profile: s.profile, size: 88)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.profile.displayName).font(Typo.title2)
                    if s.profile.isPrivate { Image(systemName: "lock.fill").font(.caption).foregroundStyle(Palette.secondaryText) }
                }
                Text("@\(s.profile.username)").font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
            if let bio = s.profile.bio { Text(bio).font(.callout).multilineTextAlignment(.center) }
            HStack(spacing: 0) {
                counter(s.tastings, "Tastings", route: nil)
                counter(s.followers, "Followers", route: s.canViewContent ? .followers(userID) : nil)
                counter(s.following, "Following", route: s.canViewContent ? .following(userID) : nil)
            }
            if !isMe {
                FollowButton(isFollowing: s.isFollowing) {
                    Task {
                        if s.isFollowing { try? await env.social.unfollow(userID) } else { try? await env.social.follow(userID) }
                        await load()
                    }
                }
            }
            if isMe && env.mode == .local {
                Label("Local Mode · sample community", systemImage: "iphone")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func counter(_ value: Int, _ label: String, route: Route?) -> some View {
        let content = VStack(spacing: 2) {
            Text("\(value)").font(.system(.title3, design: .serif).weight(.semibold))
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        if let route {
            NavigationLink(value: route) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 10) {
            shortcut("Wishlist", "bookmark", .wishlist)
            shortcut("Scans", "viewfinder", .scanHistory)
            shortcut("Milestones", "rosette", .milestones)
        }
    }

    private func shortcut(_ title: String, _ symbol: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Palette.burgundy)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.charcoal)
            }
            .frame(maxWidth: .infinity)
            .cardSurface(padding: 14)
        }
        .buttonStyle(.plain)
    }

    private var statsTeaser: some View {
        NavigationLink(value: Route.stats) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(isMe ? "Your wine year" : "Statistics").font(Typo.title3)
                    Spacer()
                    if isMe { Image(systemName: "chevron.right").foregroundStyle(Palette.secondaryText) }
                }
                HStack(spacing: 0) {
                    statCell("\(stats.uniqueWines)", "Wines")
                    statCell("\(stats.uniqueWineries)", "Wineries")
                    statCell("\(stats.countries.count)", "Countries")
                    statCell(stats.averageRating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–", "Avg ★")
                }
            }
            .foregroundStyle(Palette.charcoal)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .disabled(!isMe)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title2, design: .serif).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var diarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Diary", subtitle: diary.isEmpty ? nil : "\(diary.count) tasting\(diary.count == 1 ? "" : "s")")
            if diary.isEmpty {
                EmptyStateView(symbol: "book.closed", title: "No tastings yet",
                               message: isMe ? "Scan or search for a wine and rate it to start your diary." : "Nothing logged yet.",
                               actionTitle: isMe ? "Scan a wine" : nil, action: isMe ? { env.isScannerPresented = true } : nil)
            } else {
                ForEach(diary) { item in
                    NavigationLink(value: Route.entry(item.id)) {
                        HStack(spacing: 14) {
                            VStack(spacing: 0) {
                                Text(item.entry.consumedOn.formatted(.dateTime.month(.abbreviated))).font(.caption2.weight(.semibold)).textCase(.uppercase)
                                Text(item.entry.consumedOn.formatted(.dateTime.day())).font(.system(.title3, design: .serif).weight(.semibold))
                            }
                            .foregroundStyle(Palette.burgundy)
                            .frame(width: 40)
                            BottleArtView(wine: item.wine, height: 60).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.wine.displayName).font(.system(.subheadline, design: .serif).weight(.semibold)).lineLimit(1)
                                Text(item.wine.producer).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let r = item.entry.rating { StarRatingView(rating: r, size: 10) }
                                    if item.entry.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Palette.burgundy) }
                                    if item.entry.review != nil { Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(Palette.secondaryText) }
                                }
                            }
                            Spacer()
                        }
                        .foregroundStyle(Palette.charcoal)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

struct PeopleListView: View {
    enum Kind { case followers, following }
    var userID: UUID
    var kind: Kind
    @Environment(AppEnvironment.self) private var env
    @State private var people: [Profile] = []

    var body: some View {
        List(people) { profile in
            NavigationLink(value: Route.user(profile.id)) {
                HStack(spacing: 12) {
                    AvatarView(profile: profile, size: 40)
                    VStack(alignment: .leading) {
                        Text(profile.displayName).font(.headline)
                        Text("@\(profile.username)").font(.caption).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
        }
        .overlay { if people.isEmpty { Text("No one yet").foregroundStyle(Palette.secondaryText) } }
        .navigationTitle(kind == .followers ? "Followers" : "Following")
        .task {
            people = (try? await (kind == .followers ? env.social.followers(of: userID) : env.social.following(of: userID))) ?? []
        }
    }
}

struct WishlistView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: Loadable<[WishlistItem]> = .idle

    var body: some View {
        Group {
            switch items {
            case .loaded(let list) where list.isEmpty:
                EmptyStateView(symbol: "bookmark", title: "Your wishlist is empty",
                               message: "Tap the bookmark on any wine to save it for later.")
            case .loaded(let list):
                List {
                    ForEach(list) { item in
                        NavigationLink(value: Route.wine(item.wine)) { WineRow(wine: item.wine) }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let id = list[index].wine.id
                            Task { try? await env.cellar.setWishlisted(false, wineID: id); await load() }
                        }
                    }
                }
                .listStyle(.plain)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            default:
                ProgressView()
            }
        }
        .screenBackground()
        .navigationTitle("Wishlist")
        .task { await load() }
    }

    private func load() async {
        do { items = .loaded(try await env.cellar.wishlist()) } catch { items = .failed(error.localizedDescription) }
    }
}

struct NotificationsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: Loadable<[AppNotification]> = .idle

    var body: some View {
        Group {
            switch items {
            case .loaded(let list) where list.isEmpty:
                EmptyStateView(symbol: "bell", title: "No notifications", message: "Follows, likes and comments will show up here.")
            case .loaded(let list):
                List(list) { n in
                    NavigationLink(value: n.entryID.map(Route.entry) ?? Route.user(n.actor.id)) {
                        HStack(spacing: 12) {
                            AvatarView(profile: n.actor, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                (Text(n.actor.displayName).bold() + Text(" \(n.message)")).font(.subheadline)
                                Text(n.createdAt.relativeShort).font(.caption).foregroundStyle(Palette.secondaryText)
                            }
                            Spacer()
                            if !n.isRead { Circle().fill(Palette.burgundy).frame(width: 8, height: 8).accessibilityLabel("Unread") }
                        }
                    }
                }
                .listStyle(.plain)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            default:
                ProgressView()
            }
        }
        .screenBackground()
        .navigationTitle("Notifications")
        .task {
            await load()
            try? await env.social.markNotificationsRead()
        }
    }

    private func load() async {
        do { items = .loaded(try await env.social.notifications()) } catch { items = .failed(error.localizedDescription) }
    }
}
