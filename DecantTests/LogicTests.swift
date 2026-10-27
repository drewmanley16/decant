import Foundation
import Testing
@testable import Decant

enum Fixtures {
    static let catalog = SeedCatalog.load()

    static func wine(_ name: String) -> Wine {
        catalog.first { $0.name == name } ?? catalog[0]
    }

    static let me = Profile(id: UUID(), username: "me", displayName: "Me", avatarURL: nil, bio: nil, isPrivate: false,
                            favoriteTypes: [], defaultVisibility: .everyone, createdAt: .now)

    static func item(_ wine: Wine, rating: Double?, daysAgo: Int = 0, favorite: Bool = false, author: Profile = me) -> ReviewItem {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let entry = TastingEntry(id: UUID(), userID: author.id, wineID: wine.id, rating: rating, review: nil, personalNotes: nil,
                                 photoPaths: [], consumedOn: date, location: nil, occasion: nil, taggedUserIDs: [], drinkAgain: nil,
                                 isFavorite: favorite, visibility: .everyone, createdAt: date, likeCount: 0, commentCount: 0, likedByMe: false)
        return ReviewItem(entry: entry, author: author, wine: wine)
    }

    static func bottle(_ wine: Wine, quantity: Int = 1, addedSecondsAgo: Double = 0) -> CellarBottle {
        CellarBottle(id: UUID(), wine: wine, quantity: quantity, purchasePrice: nil, purchaseDate: nil, storageLocation: nil,
                     collectionID: nil, addedAt: .now.addingTimeInterval(-addedSecondsAgo), consumedCount: 0)
    }
}

@Suite("Ratings")
struct RatingTests {
    @Test(arguments: [(0.2, 0.5), (0.74, 0.5), (0.76, 1.0), (3.24, 3.0), (3.26, 3.5), (4.9, 5.0), (7.0, 5.0)])
    func normalizesToHalfStars(input: Double, expected: Double) {
        #expect(TastingEntry.normalizedRating(input) == expected)
    }
}

@Suite("Statistics")
struct StatsTests {
    @Test func computesTotalsAndPreferences() {
        let items = [
            Fixtures.item(Fixtures.wine("Château Margaux"), rating: 5, daysAgo: 1),
            Fixtures.item(Fixtures.wine("Château Margaux"), rating: 4, daysAgo: 40),
            Fixtures.item(Fixtures.wine("Cloudy Bay Sauvignon Blanc"), rating: 3, daysAgo: 2),
            Fixtures.item(Fixtures.wine("Opus One"), rating: nil, daysAgo: 3),
        ]
        let stats = StatsCalculator.compute(items)
        #expect(stats.totalTastings == 4)
        #expect(stats.uniqueWines == 3)
        #expect(stats.averageRating == 4)
        #expect(stats.countries.first?.label == "France" || stats.countries.contains { $0.label == "USA" })
        #expect(stats.types.first?.label == "Red")
        #expect(stats.topRated.first?.wine.name == "Château Margaux")
        #expect(stats.mostExpensive?.name == "Château Margaux")
        #expect(stats.monthly.count == 12)
        #expect(stats.monthly.map(\.count).reduce(0, +) <= 4)
    }

    @Test func historyAccumulatesUniqueWines() {
        let margaux = Fixtures.wine("Château Margaux")
        let history = StatsCalculator.history([
            Fixtures.item(margaux, rating: 3, daysAgo: 10),
            Fixtures.item(margaux, rating: 5, daysAgo: 1, favorite: true),
            Fixtures.item(Fixtures.wine("Opus One"), rating: 4, daysAgo: 5),
        ])
        #expect(history.count == 2)
        let entry = try? #require(history.first { $0.wine.id == margaux.id })
        #expect(entry?.timesTasted == 2)
        #expect(entry?.bestRating == 5)
        #expect(entry?.latestRating == 5)
        #expect(entry?.isFavorite == true)
        #expect(history.first?.wine.id == margaux.id) // most recent first
    }
}

@Suite("Recommendations")
struct RecommendationTests {
    @Test func similarityPrefersSameStyle() {
        let margaux = Fixtures.wine("Château Margaux")
        let opus = Fixtures.wine("Opus One")
        let kim = Fixtures.wine("Kim Crawford Sauvignon Blanc")
        #expect(RecommendationEngine.similarity(margaux, opus) > RecommendationEngine.similarity(margaux, kim))
        #expect(RecommendationEngine.similarity(margaux, margaux) == 0)
    }

    @Test func similarToLovedExcludesTastedProducts() {
        let loved = Fixtures.item(Fixtures.wine("Château Margaux"), rating: 5)
        let engine = RecommendationEngine(catalog: Fixtures.catalog, myHistory: [loved], friendActivity: [])
        let similar = engine.similarToLoved()
        #expect(!similar.isEmpty)
        #expect(!similar.contains { $0.productID == loved.wine.productID })
    }

    @Test func valueSectionRespectsPrice() {
        let engine = RecommendationEngine(catalog: Fixtures.catalog, myHistory: [], friendActivity: [])
        #expect(engine.highlyRated(under: 25).allSatisfy { ($0.price?.doubleValue ?? 999) <= 25 })
    }

    @Test func friendsSectionRanksSharedWines() {
        let friendA = Profile(id: UUID(), username: "a", displayName: "A", avatarURL: nil, bio: nil, isPrivate: false, favoriteTypes: [], defaultVisibility: .everyone, createdAt: .now)
        let friendB = Profile(id: UUID(), username: "b", displayName: "B", avatarURL: nil, bio: nil, isPrivate: false, favoriteTypes: [], defaultVisibility: .everyone, createdAt: .now)
        let popular = Fixtures.wine("Tignanello")
        let engine = RecommendationEngine(catalog: Fixtures.catalog, myHistory: [], friendActivity: [
            Fixtures.item(popular, rating: 4, author: friendA),
            Fixtures.item(popular, rating: 5, author: friendB),
            Fixtures.item(Fixtures.wine("Opus One"), rating: 5, author: friendA),
        ])
        #expect(engine.popularWithFriends().first?.id == popular.id)
    }

    @Test func unexploredRegionsSkipsTastedRegions() {
        let tasted = Fixtures.item(Fixtures.wine("Château Margaux"), rating: 4)
        let engine = RecommendationEngine(catalog: Fixtures.catalog, myHistory: [tasted], friendActivity: [])
        let regions = engine.unexploredRegions().compactMap(\.region)
        #expect(!regions.contains("Bordeaux"))
        #expect(Set(regions).count == regions.count)
    }
}

@Suite("Cellar layout")
struct CellarLayoutTests {
    @Test func fillsSlotsAndHidesEmptyBottles() {
        let bottles = (0..<10).map { Fixtures.bottle(Fixtures.catalog[$0], addedSecondsAgo: Double(100 - $0)) }
            + [Fixtures.bottle(Fixtures.catalog[10], quantity: 0)]
        let layout = CellarLayout(bottles: bottles, saved: [], sort: .manual)
        #expect(layout.slots.count == 10)
        #expect(Set(layout.slots.values).count == 10)
        #expect(layout.shelfCount == CellarLayout.shelvesPerBay)
        #expect(layout.slots[bottles[0].id] == CellarLayout.Slot(shelf: 0, slot: 0)) // oldest first
    }

    @Test func honorsSavedPlacementsAndIgnoresConflicts() {
        let a = Fixtures.bottle(Fixtures.catalog[0]), b = Fixtures.bottle(Fixtures.catalog[1])
        let saved = [CellarPlacement(bottleID: a.id, shelf: 3, slot: 5), CellarPlacement(bottleID: b.id, shelf: 3, slot: 5)]
        let layout = CellarLayout(bottles: [a, b], saved: saved, sort: .manual)
        #expect(layout.slots[a.id] == CellarLayout.Slot(shelf: 3, slot: 5))
        #expect(layout.slots[b.id] != CellarLayout.Slot(shelf: 3, slot: 5))
    }

    @Test func moveSwapsOccupants() {
        let a = Fixtures.bottle(Fixtures.catalog[0], addedSecondsAgo: 2), b = Fixtures.bottle(Fixtures.catalog[1], addedSecondsAgo: 1)
        var layout = CellarLayout(bottles: [a, b], saved: [], sort: .manual)
        let slotA = layout.slots[a.id]!, slotB = layout.slots[b.id]!
        layout.move(a.id, to: slotB)
        #expect(layout.slots[a.id] == slotB)
        #expect(layout.slots[b.id] == slotA)
    }

    @Test func growsIntoAdditionalBays() {
        let bottles = (0..<45).map { Fixtures.bottle(Fixtures.catalog[$0 % Fixtures.catalog.count]) }
        let layout = CellarLayout(bottles: bottles, saved: [], sort: .type)
        #expect(layout.bayCount == 2)
    }

    @Test func sortsByType() {
        let white = Fixtures.bottle(Fixtures.wine("Cloudy Bay Sauvignon Blanc"))
        let red = Fixtures.bottle(Fixtures.wine("Opus One"))
        let layout = CellarLayout(bottles: [white, red], saved: [], sort: .type)
        #expect(layout.slots[red.id] == CellarLayout.Slot(shelf: 0, slot: 0))
    }

    @Test func filterMatchesAttributes() {
        let bottle = Fixtures.bottle(Fixtures.wine("Château Margaux"))
        #expect(CellarFilter(types: [.red]).matches(bottle, rating: nil))
        #expect(!CellarFilter(types: [.white]).matches(bottle, rating: nil))
        #expect(CellarFilter(region: "Bordeaux").matches(bottle, rating: nil))
        #expect(!CellarFilter(minRating: 4).matches(bottle, rating: 3.5))
    }
}
