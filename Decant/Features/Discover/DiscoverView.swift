import SwiftUI

@MainActor
@Observable
final class DiscoverViewModel {
    var sections: Loadable<[DiscoverSection]> = .idle
    var feed: Loadable<[FeedItem]> = .idle
    var recentlyViewed: [Wine] = []
    var unreadNotifications = 0
    var isLoadingMore = false
    private var reachedEnd = false
    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    func load() async {
        if sections.value == nil { sections = .loading }
        if feed.value == nil { feed = .loading }
        reachedEnd = false
        do {
            async let catalogTask = env.catalog.catalogSample(limit: 300)
            async let feedTask = env.social.feed(before: nil, limit: 30)
            async let recentTask = try? env.catalog.recentlyViewed(limit: 10)
            async let notificationsTask = try? env.social.notifications()
            let (catalog, feedItems) = try await (catalogTask, feedTask)
            let me = env.currentUser?.id
            let mine: [ReviewItem] = me != nil ? ((try? await env.tastings.entries(forUser: me!)) ?? []) : []
            let friendActivity = feedItems.compactMap { item -> ReviewItem? in
                guard item.actor.id != me, let wine = item.wine, let entry = item.entry else { return nil }
                return ReviewItem(entry: entry, author: item.actor, wine: wine)
            }
            let engine = RecommendationEngine(catalog: catalog, myHistory: mine, friendActivity: friendActivity)
            sections = .loaded(engine.sections())
            feed = .loaded(feedItems)
            recentlyViewed = await recentTask ?? []
            unreadNotifications = (await notificationsTask ?? []).filter { !$0.isRead }.count
        } catch {
            if sections.value == nil { sections = .failed(error.localizedDescription) }
            if feed.value == nil { feed = .failed(error.localizedDescription) }
        }
    }

    func loadMore() async {
        guard !isLoadingMore, !reachedEnd, case .loaded(let items) = feed, let last = items.last else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let more = (try? await env.social.feed(before: last.createdAt, limit: 20)) ?? []
        reachedEnd = more.isEmpty
        feed = .loaded(items + more.filter { m in !items.contains { $0.id == m.id } })
    }

    func toggleLike(_ item: FeedItem) async {
        guard case .loaded(var items) = feed, let index = items.firstIndex(where: { $0.id == item.id }),
              var entry = items[index].entry else { return }
        entry.likedByMe.toggle()
        entry.likeCount += entry.likedByMe ? 1 : -1
        items[index].entry = entry
        feed = .loaded(items)
        try? await env.social.setLike(entry.likedByMe, entryID: entry.id)
    }
}

struct DiscoverView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: DiscoverViewModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model { DiscoverContent(model: model) }
            }
            .screenBackground()
            .refreshable { await model?.load() }
            .navigationTitle("Discover")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.notifications) {
                        Image(systemName: (model?.unreadNotifications ?? 0) > 0 ? "bell.badge.fill" : "bell")
                            .symbolRenderingMode(.multicolor)
                    }
                    .accessibilityLabel("Notifications\((model?.unreadNotifications ?? 0) > 0 ? ", \(model?.unreadNotifications ?? 0) unread" : "")")
                }
            }
            .appDestinations()
        }
        .task {
            if model == nil { model = DiscoverViewModel(env: env) }
            await model?.load()
        }
        .onChange(of: env.diaryRevision) { Task { await model?.load() } }
        .onChange(of: env.moderationRevision) { Task { await model?.load() } }
    }
}

private struct DiscoverContent: View {
    var model: DiscoverViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            greeting
            scanPrompt
            switch model.sections {
            case .loaded(let sections):
                ForEach(sections) { section in
                    WineCarousel(title: section.title, subtitle: section.subtitle, wines: section.wines)
                }
            case .failed(let message):
                ErrorStateView(message: message) { Task { await model.load() } }
            default:
                ForEach(0..<2, id: \.self) { _ in skeletonCarousel }
            }
            if !model.recentlyViewed.isEmpty {
                WineCarousel(title: "Recently viewed", subtitle: nil, wines: model.recentlyViewed)
            }
            feed
        }
        .padding(.vertical, 12)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month().day())).eyebrow()
            Text("Good \(partOfDay), \(env.currentUser?.displayName.split(separator: " ").first.map(String.init) ?? "friend")")
                .font(Typo.title)
        }
        .padding(.horizontal, Metrics.gutter)
        .accessibilityElement(children: .combine)
    }

    private var partOfDay: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        default: "evening"
        }
    }

    private var scanPrompt: some View {
        Button { env.isScannerPresented = true } label: {
            HStack(spacing: 16) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("What's in your glass?").font(.system(.headline, design: .serif))
                    Text("Scan a label to identify, rate and cellar it").font(.subheadline).opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(.white)
            .padding(18)
            .background {
                ZStack {
                    // Fixed deep burgundy in both appearances; the adaptive tint is too light for white text in dark mode.
                    LinearGradient(colors: [Color(red: 0.48, green: 0.10, blue: 0.18), Color(red: 0.31, green: 0.06, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Palette.gold.opacity(0.18)).frame(width: 160).offset(x: 130, y: -40).blur(radius: 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
    }

    private var skeletonCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(width: 180, height: 20).padding(.horizontal, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) { ForEach(0..<3, id: \.self) { _ in WineCardSkeleton() } }.padding(.horizontal, Metrics.gutter)
            }
            .disabled(true)
        }
    }

    @ViewBuilder private var feed: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Friend activity", subtitle: "What your circle has been drinking")
            switch model.feed {
            case .loaded(let items) where items.isEmpty:
                EmptyStateView(symbol: "person.2", title: "Your feed is quiet",
                               message: "Follow friends to see what they're tasting.", actionTitle: "Find friends") {
                    env.selectedTab = .search
                }
            case .loaded(let items):
                ForEach(items) { item in
                    FeedCard(item: item, onLike: { Task { await model.toggleLike(item) } })
                        .onAppear { if item.id == items.last?.id { Task { await model.loadMore() } } }
                }
                if model.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
            case .failed(let message):
                ErrorStateView(message: message) { Task { await model.load() } }
            default:
                SkeletonBlock(height: 220, radius: Metrics.cardRadius)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

struct WineCarousel: View {
    var title: String
    var subtitle: String?
    var wines: [Wine]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle).padding(.horizontal, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(wines) { wine in
                        NavigationLink(value: Route.wine(wine)) { WineCard(wine: wine) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 4)
            }
        }
    }
}

/// "Alex rated Château Margaux 2015 ★★★★★"
struct FeedCard: View {
    var item: FeedItem
    var onLike: () -> Void

    var body: some View {
        if let wine = item.wine, let entry = item.entry, item.kind == .rated {
            ReviewCard(item: ReviewItem(entry: entry, author: item.actor, wine: wine), onLike: onLike)
                .accessibilityLabel("\(item.actor.displayName) rated \(wine.displayName)")
        } else if let wine = item.wine {
            NavigationLink(value: Route.wine(wine)) {
                HStack(spacing: 12) {
                    AvatarView(profile: item.actor, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(item.actor.displayName).bold() + Text(item.kind == .cellared ? " cellared " : " wishlisted ") + Text(wine.displayName).bold())
                            .font(.subheadline)
                            .foregroundStyle(Palette.charcoal)
                            .multilineTextAlignment(.leading)
                        Text(item.createdAt.relativeShort).font(.caption).foregroundStyle(Palette.secondaryText)
                    }
                    Spacer()
                    BottleArtView(wine: wine, height: 56).frame(width: 24)
                }
                .cardSurface(padding: 14)
            }
            .buttonStyle(.plain)
        }
    }
}
