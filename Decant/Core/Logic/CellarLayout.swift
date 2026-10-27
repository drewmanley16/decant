import Foundation

/// Assigns in-stock bottles to rack slots. Racks are made of bays; each bay
/// has `shelvesPerBay` shelves of `slotsPerShelf` slots. Shelf indices are global.
struct CellarLayout: Sendable, Equatable {
    static let slotsPerShelf = 8
    static let shelvesPerBay = 5

    struct Slot: Hashable, Sendable {
        var shelf: Int
        var slot: Int

        var bay: Int { shelf / CellarLayout.shelvesPerBay }
        var shelfInBay: Int { shelf % CellarLayout.shelvesPerBay }
    }

    private(set) var slots: [UUID: Slot]
    private(set) var shelfCount: Int

    var bayCount: Int { max(1, Int((Double(shelfCount) / Double(Self.shelvesPerBay)).rounded(.up))) }

    var placements: [CellarPlacement] {
        slots.map { CellarPlacement(bottleID: $0.key, shelf: $0.value.shelf, slot: $0.value.slot) }
            .sorted { ($0.shelf, $0.slot) < ($1.shelf, $1.slot) }
    }

    func bottle(at slot: Slot) -> UUID? {
        slots.first { $0.value == slot }?.key
    }

    /// Builds a layout. In `.manual` mode saved placements are honoured and new
    /// bottles fill the first free slots; other modes re-flow by the sort key.
    init(bottles: [CellarBottle], saved: [CellarPlacement], sort: CellarSort, ratings: [UUID: Double] = [:]) {
        let inStock = bottles.filter(\.isInStock)
        var assigned: [UUID: Slot] = [:]

        if sort == .manual {
            let valid = Set(inStock.map(\.id))
            var taken = Set<Slot>()
            for placement in saved where valid.contains(placement.bottleID) && placement.slot < Self.slotsPerShelf {
                let slot = Slot(shelf: placement.shelf, slot: placement.slot)
                guard !taken.contains(slot), assigned[placement.bottleID] == nil else { continue }
                taken.insert(slot)
                assigned[placement.bottleID] = slot
            }
            var cursor = 0
            for bottle in inStock.sorted(by: { $0.addedAt < $1.addedAt }) where assigned[bottle.id] == nil {
                while taken.contains(Self.slot(forIndex: cursor)) { cursor += 1 }
                let slot = Self.slot(forIndex: cursor)
                taken.insert(slot)
                assigned[bottle.id] = slot
            }
        } else {
            let ordered = Self.sorted(inStock, by: sort, ratings: ratings)
            for (index, bottle) in ordered.enumerated() {
                assigned[bottle.id] = Self.slot(forIndex: index)
            }
        }

        let maxShelf = assigned.values.map(\.shelf).max() ?? -1
        // Always show at least one full bay, and leave a free shelf for growth.
        let needed = max(Self.shelvesPerBay, maxShelf + 2)
        self.shelfCount = Int((Double(needed) / Double(Self.shelvesPerBay)).rounded(.up)) * Self.shelvesPerBay
        self.slots = assigned
    }

    /// Moves a bottle to a slot, swapping with any occupant.
    mutating func move(_ bottleID: UUID, to target: Slot) {
        guard let origin = slots[bottleID], origin != target else { return }
        if let occupant = bottle(at: target) {
            slots[occupant] = origin
        }
        slots[bottleID] = target
        shelfCount = max(shelfCount, Int((Double(target.shelf + 2) / Double(Self.shelvesPerBay)).rounded(.up)) * Self.shelvesPerBay)
    }

    static func slot(forIndex index: Int) -> Slot {
        Slot(shelf: index / slotsPerShelf, slot: index % slotsPerShelf)
    }

    static func sorted(_ bottles: [CellarBottle], by sort: CellarSort, ratings: [UUID: Double]) -> [CellarBottle] {
        let typeOrder = Dictionary(uniqueKeysWithValues: WineType.allCases.enumerated().map { ($1, $0) })
        return bottles.sorted { a, b in
            switch sort {
            case .manual, .recent: return a.addedAt > b.addedAt
            case .type:
                let ta = typeOrder[a.wine.type] ?? 0, tb = typeOrder[b.wine.type] ?? 0
                return ta == tb ? a.wine.name < b.wine.name : ta < tb
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

/// Filters applied to the cellar (dims non-matching bottles in 3D).
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
