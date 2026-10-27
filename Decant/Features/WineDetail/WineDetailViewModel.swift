import Foundation
import Observation

@MainActor
@Observable
final class WineDetailViewModel {
    var wine: Wine
    var vintages: [Wine] = []
    var reviews: Loadable<[ReviewItem]> = .idle
    var friendRatings: [FriendRating] = []
    var myEntries: [ReviewItem] = []
    var similar: [Wine] = []
    var isWishlisted = false
    var cellarQuantity = 0

    private let env: AppEnvironment

    init(wine: Wine, env: AppEnvironment) {
        self.wine = wine
        self.env = env
    }

    var myLatestRating: Double? { myEntries.first?.entry.rating }

    func load() async {
        await env.catalog.recordView(of: wine.id)
        if reviews.value == nil { reviews = .loading }
        async let fresh = try? env.catalog.wine(id: wine.id)
        async let vintagesTask = try? env.catalog.vintages(ofProduct: wine.productID)
        async let reviewsTask = Result { try await env.tastings.reviews(forWine: wine.id, limit: 20) }
        async let friendsTask = try? env.tastings.friendRatings(forWine: wine.id)
        async let wishlistTask = try? env.cellar.wishlist()
        async let bottlesTask = try? env.cellar.bottles()

        if let updated = await fresh {
            // Keep a label photo we already have locally if the server hasn't caught up.
            let label = updated.labelImagePath ?? wine.labelImagePath
            wine = updated
            wine.labelImagePath = label
        }
        vintages = (await vintagesTask ?? []).filter { $0.bottleSizeML == wine.bottleSizeML }
        switch await reviewsTask {
        case .success(let list): reviews = .loaded(list)
        case .failure(let error): reviews = .failed(error.localizedDescription)
        }
        friendRatings = await friendsTask ?? []
        isWishlisted = (await wishlistTask ?? []).contains { $0.wine.id == wine.id }
        cellarQuantity = (await bottlesTask ?? []).filter { $0.wine.id == wine.id }.map(\.quantity).reduce(0, +)
        await loadMine()
        await loadSimilar()
    }

    func loadMine() async {
        guard let me = env.currentUser else { return }
        myEntries = ((try? await env.tastings.entries(forUser: me.id)) ?? []).filter { $0.wine.id == wine.id }
    }

    private func loadSimilar() async {
        let pool = (try? await env.catalog.catalogSample(limit: 300)) ?? []
        similar = pool
            .filter { $0.productID != wine.productID }
            .map { ($0, RecommendationEngine.similarity($0, wine)) }
            .filter { $0.1 > 0.3 }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map(\.0)
    }

    func toggleWishlist() async {
        let target = !isWishlisted
        isWishlisted = target
        do {
            try await env.cellar.setWishlisted(target, wineID: wine.id)
            env.show(target ? "Added to wishlist" : "Removed from wishlist", symbol: target ? "bookmark.fill" : "bookmark")
        } catch {
            isWishlisted = !target
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    func toggleLike(_ item: ReviewItem) async {
        guard case .loaded(var list) = reviews, let index = list.firstIndex(where: { $0.id == item.id }) else { return }
        let liked = !list[index].entry.likedByMe
        list[index].entry.likedByMe = liked
        list[index].entry.likeCount += liked ? 1 : -1
        reviews = .loaded(list)
        try? await env.social.setLike(liked, entryID: item.id)
    }
}
