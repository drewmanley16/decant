import Foundation

/// The cellar as a wall of shelves: one shelf per wine style, ordered by the
/// user's chosen sort. Pure and deterministic so it can be unit tested.
struct CellarWall: Sendable, Equatable {
    struct Shelf: Identifiable, Sendable, Equatable {
        var id: String
        var title: String
        var bottles: [CellarBottle]
        var bottleCount: Int { bottles.map(\.quantity).reduce(0, +) }
    }

    /// Shelf groupings, in display order.
    static let groups: [(id: String, title: String, types: Set<WineType>)] = [
        ("red", "Red", [.red]),
        ("white", "White", [.white]),
        ("rose", "Rosé & Orange", [.rose, .orange]),
        ("sparkling", "Sparkling", [.sparkling]),
        ("sweet", "Dessert & Fortified", [.dessert, .fortified]),
    ]

    var shelves: [Shelf]

    init(bottles: [CellarBottle], sort: CellarSort, ratings: [UUID: Double] = [:]) {
        let inStock = Self.sorted(bottles.filter(\.isInStock), by: sort, ratings: ratings)
        shelves = Self.groups.compactMap { group in
            let matching = inStock.filter { group.types.contains($0.wine.type) }
            return matching.isEmpty ? nil : Shelf(id: group.id, title: group.title, bottles: matching)
        }
    }

    /// Every bottle in reading order (shelf by shelf), used for swiping in the inspector.
    var orderedBottles: [CellarBottle] { shelves.flatMap(\.bottles) }

    static func sorted(_ bottles: [CellarBottle], by sort: CellarSort, ratings: [UUID: Double]) -> [CellarBottle] {
        bottles.sorted { a, b in
            switch sort {
            case .manual, .recent, .type: return (a.addedAt, a.wine.name) > (b.addedAt, b.wine.name)
            case .vintage: return (a.wine.vintage ?? 0, a.wine.name) < (b.wine.vintage ?? 0, b.wine.name)
            case .region: return (a.wine.region ?? "~", a.wine.name) < (b.wine.region ?? "~", b.wine.name)
            case .rating:
                let ra = ratings[a.wine.id] ?? a.wine.communityRating ?? 0
                let rb = ratings[b.wine.id] ?? b.wine.communityRating ?? 0
                return ra == rb ? a.wine.name < b.wine.name : ra > rb
            }
        }
    }
}

extension CellarSort {
    /// Orders offered in the UI. `.manual` and `.type` remain only so saved settings decode:
    /// shelves are always grouped by style now.
    static var selectable: [CellarSort] { [.recent, .vintage, .region, .rating] }
}

/// Filters applied to the cellar (non-matching bottles are dimmed on the shelves).
struct CellarFilter: Hashable, Sendable {
    var types: Set<WineType> = []
    var vintage: Int?
    var grape: String?
    var region: String?
    var minRating: Double?
    var collectionID: UUID?

    var isActive: Bool {
        !types.isEmpty || vintage != nil || grape != nil || region != nil || minRating != nil || collectionID != nil
    }

    func matches(_ bottle: CellarBottle, rating: Double?) -> Bool {
        if !types.isEmpty, !types.contains(bottle.wine.type) { return false }
        if let vintage, bottle.wine.vintage != vintage { return false }
        if let grape, !bottle.wine.grapes.contains(where: { $0.name == grape }) { return false }
        if let region, bottle.wine.region != region { return false }
        if let minRating, (rating ?? bottle.wine.communityRating ?? 0) < minRating { return false }
        if let collectionID, bottle.collectionID != collectionID { return false }
        return true
    }
}
