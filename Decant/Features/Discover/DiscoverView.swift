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
            let me = env.currentUser?.id
            // Fetched alongside the rest instead of after it.
            async let mineTask: [ReviewItem]? = me != nil ? try? env.tastings.entries(forUser: me!) : nil
            let (catalog, feedItems) = try await (catalogTask, feedTask)
            let mine = await mineTask ?? []
            let friendActivity = feedItems.compactMap { item -> ReviewItem? in
                guard item.actor.id != me, let wine = item.wine, let entry = item.entry else { return nil }
                return ReviewItem(entry: entry, author: item.actor, wine: wine)
            }
            let engine = RecommendationEngine(catalog: catalog, myHistory: mine, friendActivity: friendActivity)
            sections = .loaded(Self.deduplicated(engine.sections()))
            feed = .loaded(feedItems)
            recentlyViewed = await recentTask ?? []
            unreadNotifications = (await notificationsTask ?? []).filter { !$0.isRead }.count
        } catch {
            if sections.value == nil { sections = .failed(error.localizedDescription) }
            if feed.value == nil { feed = .failed(error.localizedDescription) }
        }
    }

    /// Each wine appears in at most one section, so the page doesn't repeat itself.
    /// Sections left with fewer than two wines are dropped.
    static func deduplicated(_ sections: [DiscoverSection]) -> [DiscoverSection] {
        var shown = Set<UUID>()
        return sections.compactMap { section in
            var section = section
            let fresh = section.wines.filter { !shown.contains($0.id) }
            // Region cards lead with the place, so a repeated bottle there still reads as new.
            if fresh.count >= 2 { section.wines = fresh } else if section.kind != .unexplored { return nil }
            section.wines.forEach { shown.insert($0.id) }
            return section
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
            switch model.sections {
            case .loaded(let sections):
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index == 0 {
                        FeaturedWineSection(section: section)
                    } else {
                        switch section.kind {
                        case .trending: RankedWineList(section: section)
                        case .unexplored: RegionCarousel(section: section)
                        default: WineCarousel(title: section.title, subtitle: section.subtitle, wines: section.wines)
                        }
                    }
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
            case .loaded(let all) where friendItems(all).isEmpty:
                EmptyStateView(symbol: "person.2", title: "Your feed is quiet",
                               message: "Follow friends to see what they're tasting.", actionTitle: "Find friends") {
                    env.selectedTab = .search
                }
            case .loaded(let all):
                let items = friendItems(all)
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

    /// Your own activity isn't "friend activity".
    private func friendItems(_ items: [FeedItem]) -> [FeedItem] {
        items.filter { $0.actor.id != env.currentUser?.id }
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
                            .buttonStyle(PressableCardStyle())
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

// MARK: - Section layouts

/// Leads the page: one large hero card, then the rest of the shelf.
private struct FeaturedWineSection: View {
    var section: DiscoverSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: section.title, subtitle: section.subtitle).padding(.horizontal, Metrics.gutter)
            if let hero = section.wines.first {
                NavigationLink(value: Route.wine(hero)) { FeaturedWineCard(wine: hero) }
                    .buttonStyle(PressableCardStyle())
                    .padding(.horizontal, Metrics.gutter)
            }
            let rest = Array(section.wines.dropFirst())
            if !rest.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(rest) { wine in
                            NavigationLink(value: Route.wine(wine)) { WineCard(wine: wine) }
                                .buttonStyle(PressableCardStyle())
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct FeaturedWineCard: View {
    var wine: Wine
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isLarge: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        // At accessibility sizes the bottle sits above the text so the name,
        // producer and region can use the card's full width.
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(spacing: 18))
        layout {
            BottleStage(tint: Palette.wineColor(wine.type)) {
                BottleArtView(wine: wine, height: 190)
            }
            .frame(width: isLarge ? nil : 120, height: 220)
            .frame(maxWidth: isLarge ? .infinity : nil)
            .background(Palette.wineColor(wine.type).opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                TypeDot(type: wine.type)
                Text(wine.name)
                    .font(Typo.title2)
                    .foregroundStyle(Palette.charcoal)
                    .lineLimit(isLarge ? 4 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(wine.producer) · \(wine.vintageLabel)")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(isLarge ? 3 : 1)
                if !wine.locationLine.isEmpty {
                    Label(wine.locationLine, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(isLarge ? 2 : 1)
                }
                Spacer(minLength: 0)
                HStack {
                    if let rating = wine.communityRating {
                        StarRatingView(rating: rating, size: 13)
                    } else {
                        RatingPill(rating: nil, count: nil)
                    }
                    Spacer()
                    if let price = wine.price {
                        Text(price.formatted).font(.system(.headline, design: .serif)).foregroundStyle(Palette.charcoal)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Numbered top-five list for Trending.
private struct RankedWineList: View {
    var section: DiscoverSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: section.title, subtitle: section.subtitle)
            VStack(spacing: 0) {
                let top = Array(section.wines.prefix(5))
                ForEach(Array(top.enumerated()), id: \.element.id) { index, wine in
                    NavigationLink(value: Route.wine(wine)) {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(.title2, design: .serif).weight(.semibold))
                                .foregroundStyle(index == 0 ? Palette.gold : Palette.secondaryText.opacity(0.7))
                                .frame(width: 26)
                            WineRow(wine: wine)
                        }
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                    if index < top.count - 1 {
                        Divider().overlay(Palette.hairline).padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 6)
            .cardSurface(padding: 0)
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

/// Wider cards that lead with the place, not the bottle.
private struct RegionCarousel: View {
    var section: DiscoverSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: section.title, subtitle: section.subtitle).padding(.horizontal, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(section.wines) { wine in
                        NavigationLink(value: Route.wine(wine)) { RegionCard(wine: wine) }
                            .buttonStyle(PressableCardStyle())
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 4)
            }
        }
    }
}

private struct RegionCard: View {
    var wine: Wine

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Palette.wineColor(wine.type).opacity(0.85), Palette.wineColor(wine.type).opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .bottom, endPoint: .center)
            BottleArtView(wine: wine, height: 150)
                .rotationEffect(.degrees(8))
                .offset(x: -14, y: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text((wine.country ?? "").uppercased())
                    .font(.caption2.weight(.semibold)).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.75))
                Text(wine.region ?? wine.locationLine)
                    .font(Typo.title2)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                Text(wine.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: 130, alignment: .leading)
                Text(wine.vintageLabel).font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 230, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}
