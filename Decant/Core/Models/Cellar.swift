import Foundation

/// A physical bottle (or stack of identical bottles) the user owns.
struct CellarBottle: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var wine: Wine
    var quantity: Int
    var purchasePrice: Price?
    var purchaseDate: Date?
    var storageLocation: String?
    var collectionID: UUID?
    var addedAt: Date
    var consumedCount: Int

    var isInStock: Bool { quantity > 0 }
}

struct CellarBottleDraft: Sendable, Hashable {
    var quantity: Int = 1
    var purchasePrice: Double?
    var currency: String = "USD"
    var purchaseDate: Date? = .now
    var storageLocation: String = ""
    var collectionID: UUID?
}

/// Where a bottle sits in the 3D rack. `shelf` 0 is the top shelf.
struct CellarPlacement: Codable, Hashable, Sendable {
    var bottleID: UUID
    var shelf: Int
    var slot: Int
}

struct CellarCollection: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var symbol: String
    var createdAt: Date
}

enum ShelfFinish: String, Codable, CaseIterable, Sendable, Identifiable {
    case oak, walnut, ebony, whitewash

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum CellarSort: String, Codable, CaseIterable, Sendable, Identifiable {
    case manual, type, vintage, region, rating, recent

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .type: "Wine type"
        case .vintage: "Vintage"
        case .region: "Region"
        case .rating: "Rating"
        case .recent: "Recently added"
        }
    }
}

struct CellarSettings: Codable, Hashable, Sendable {
    var finish: ShelfFinish = .walnut
    var sort: CellarSort = .manual
    var prefers2D: Bool = false
}

/// Every unique wine a user has tasted, accumulated from their diary.
struct HistoryWine: Hashable, Sendable, Identifiable {
    var wine: Wine
    var timesTasted: Int
    var lastTasted: Date
    var bestRating: Double?
    var latestRating: Double?
    var isFavorite: Bool
    var id: UUID { wine.id }
}

struct WishlistItem: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var wine: Wine
    var addedAt: Date
}

struct CollectionMilestone: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var symbol: String
    var achieved: Bool
    var progress: Double
}
