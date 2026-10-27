import Foundation

/// A titled shelf of recommended wines for the Discover tab.
struct DiscoverSection: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case friends, similar, trending, value, unexplored, pairing, wineries
    }

    var kind: Kind
    var title: String
    var subtitle: String
    var wines: [Wine]
    var id: String { kind.rawValue }
}

/// Attribute-based recommendations. Pure and deterministic so it can be unit
/// tested and later swapped for embeddings / collaborative filtering behind the
/// same `sections(...)` interface.
struct RecommendationEngine: Sendable {
    var catalog: [Wine]
    var myHistory: [ReviewItem]
    var friendActivity: [ReviewItem]
    var wishlistIDs: Set<UUID> = []

    private var tastedProducts: Set<UUID> { Set(myHistory.map(\.wine.productID)) }

    func sections(pairingFood: String? = nil) -> [DiscoverSection] {
        var result: [DiscoverSection] = []
        let friends = popularWithFriends()
        if !friends.isEmpty {
            result.append(.init(kind: .friends, title: "Popular with friends", subtitle: "What your circle is pouring", wines: friends))
        }
        let similar = similarToLoved()
        if !similar.isEmpty {
            result.append(.init(kind: .similar, title: "Because you loved…", subtitle: "Matched on grape, region and style", wines: similar))
        }
        result.append(.init(kind: .trending, title: "Trending", subtitle: "Most rated by the community", wines: trending()))
        let value = highlyRated(under: 25)
        if !value.isEmpty {
            result.append(.init(kind: .value, title: "Highly rated under $25", subtitle: "Great bottles, gentle prices", wines: value))
        }
        let unexplored = unexploredRegions()
        if !unexplored.isEmpty {
            result.append(.init(kind: .unexplored, title: "Regions to explore", subtitle: "Places you haven't tasted yet", wines: unexplored))
        }
        if let food = pairingFood ?? featuredPairing() {
            let pairs = pairings(for: food)
            if !pairs.isEmpty {
                result.append(.init(kind: .pairing, title: "Pairs with \(food.lowercased())", subtitle: "Recommended pairings", wines: pairs))
            }
        }
        let wineries = newWineries()
        if !wineries.isEmpty {
            result.append(.init(kind: .wineries, title: "New wineries to discover", subtitle: "Producers new to you", wines: wineries))
        }
        return result
    }

    func popularWithFriends(limit: Int = 10) -> [Wine] {
        let grouped = Dictionary(grouping: friendActivity, by: \.wine.id)
        return grouped.values
            .map { items -> (Wine, Double) in
                let ratings = items.compactMap(\.entry.rating)
                let avg = ratings.isEmpty ? 3 : ratings.reduce(0, +) / Double(ratings.count)
                return (items[0].wine, Double(Set(items.map(\.author.id)).count) * 2 + avg)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func similarToLoved(limit: Int = 10) -> [Wine] {
        let loved = myHistory.filter { ($0.entry.rating ?? 0) >= 4 || $0.entry.isFavorite }.map(\.wine)
        guard !loved.isEmpty else { return [] }
        let tasted = tastedProducts
        var scored: [(wine: Wine, score: Double)] = []
        for candidate in catalog where !tasted.contains(candidate.productID) {
            let best = loved.map { Self.similarity(candidate, $0) }.max() ?? 0
            if best > 0.35 { scored.append((candidate, best)) }
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map(\.wine)
    }

    func trending(limit: Int = 10) -> [Wine] {
        catalog
            .sorted { lhs, rhs in
                let l = Double(lhs.ratingsCount) * (lhs.communityRating ?? 0)
                let r = Double(rhs.ratingsCount) * (rhs.communityRating ?? 0)
                return l == r ? lhs.name < rhs.name : l > r
            }
            .prefix(limit)
            .map { $0 }
    }

    func highlyRated(under maxPrice: Double, limit: Int = 10) -> [Wine] {
        catalog
            .filter { ($0.price?.doubleValue ?? .infinity) <= maxPrice }
            .sorted { ($0.communityRating ?? 0, $0.ratingsCount) > ($1.communityRating ?? 0, $1.ratingsCount) }
            .prefix(limit)
            .map { $0 }
    }

    func unexploredRegions(limit: Int = 8) -> [Wine] {
        let explored = Set(myHistory.compactMap(\.wine.region))
        var seen = Set<String>()
        return catalog
            .sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
            .filter { wine in
                guard let region = wine.region, !explored.contains(region), !seen.contains(region) else { return false }
                seen.insert(region)
                return true
            }
            .prefix(limit)
            .map { $0 }
    }

    func newWineries(limit: Int = 8) -> [Wine] {
        let known = Set(myHistory.map(\.wine.winery.id))
        var seen = Set<UUID>()
        return catalog.filter { wine in
            guard !known.contains(wine.winery.id), !seen.contains(wine.winery.id), wine.winery.story != nil else { return false }
            seen.insert(wine.winery.id)
            return true
        }
        .prefix(limit)
        .map { $0 }
    }

    func pairings(for food: String, limit: Int = 8) -> [Wine] {
        let needle = TextNormalizer.fold(food)
        return catalog.filter { wine in wine.pairings.contains { TextNormalizer.fold($0).contains(needle) } }
            .prefix(limit).map { $0 }
    }

    /// Picks a pairing that recurs across the catalog so the section is never sparse.
    func featuredPairing() -> String? {
        let keywords = ["lamb", "steak", "salmon", "cheese", "chicken", "oysters"]
        return keywords.max { pairings(for: $0).count < pairings(for: $1).count }.map { $0.capitalized }
    }

    /// 0...1 similarity on type, grapes, place and structure.
    static func similarity(_ a: Wine, _ b: Wine) -> Double {
        guard a.productID != b.productID else { return 0 }
        var score = a.type == b.type ? 0.3 : 0
        let ga = Set(a.grapes.map { TextNormalizer.fold($0.name) })
        let gb = Set(b.grapes.map { TextNormalizer.fold($0.name) })
        if !ga.isEmpty, !gb.isEmpty {
            score += 0.25 * Double(ga.intersection(gb).count) / Double(ga.union(gb).count)
        }
        if a.region != nil, a.region == b.region {
            score += 0.15
        } else if a.country != nil, a.country == b.country {
            score += 0.05
        }
        if let ca = a.characteristics, let cb = b.characteristics {
            let distance = zip(ca.vector, cb.vector).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
            score += 0.3 * max(0, 1 - distance / 2.236) // sqrt(5) is the max distance
        }
        return min(1, score)
    }
}
