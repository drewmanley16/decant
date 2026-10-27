import Foundation
import Observation

@MainActor
@Observable
final class CellarViewModel {
    enum Mode: String, CaseIterable, Identifiable {
        case physical = "My Cellar"
        case history = "Wine History"
        var id: String { rawValue }
    }

    var mode: Mode = .physical
    var bottles: Loadable<[CellarBottle]> = .idle
    var history: [HistoryWine] = []
    var collections: [CellarCollection] = []
    var settings = CellarSettings()
    var layout = CellarLayout(bottles: [], saved: [], sort: .manual)
    var filter = CellarFilter()
    var myRatings: [UUID: Double] = [:]
    var inspectedID: UUID?
    var movingID: UUID?
    var showsSamplePreview = false
    var sampleBottles: [CellarBottle] = []

    private let env: AppEnvironment
    private var savedPlacements: [CellarPlacement] = []

    init(env: AppEnvironment) {
        self.env = env
    }

    var inStock: [CellarBottle] { (bottles.value ?? []).filter(\.isInStock) }
    var isEmpty: Bool { bottles.value != nil && inStock.isEmpty }
    var totalBottles: Int { inStock.map(\.quantity).reduce(0, +) }
    var estimatedValue: Double {
        inStock.reduce(0) { $0 + Double($1.quantity) * ($1.purchasePrice?.doubleValue ?? $1.wine.price?.doubleValue ?? 0) }
    }

    /// Bottles actually rendered (real bottles, or the sample preview for empty cellars).
    var displayedBottles: [CellarBottle] { showsSamplePreview && isEmpty ? sampleBottles : inStock }

    var dimmedIDs: Set<UUID> {
        guard filter.isActive else { return [] }
        return Set(displayedBottles.filter { !filter.matches($0, rating: myRatings[$0.wine.id]) }.map(\.id))
    }

    func bottle(_ id: UUID?) -> CellarBottle? {
        guard let id else { return nil }
        return displayedBottles.first { $0.id == id }
    }

    var availableRegions: [String] { Array(Set(inStock.compactMap(\.wine.region))).sorted() }
    var availableGrapes: [String] { Array(Set(inStock.flatMap { $0.wine.grapes.map(\.name) })).sorted() }
    var availableVintages: [Int] { Array(Set(inStock.compactMap(\.wine.vintage))).sorted(by: >) }

    func load() async {
        if bottles.value == nil { bottles = .loading }
        do {
            async let bottlesTask = env.cellar.bottles()
            async let placementsTask = env.cellar.placements()
            async let settingsTask = env.cellar.settings()
            async let collectionsTask = env.cellar.collections()
            let (loaded, placements, settings, collections) = try await (bottlesTask, placementsTask, settingsTask, collectionsTask)
            self.settings = settings
            self.collections = collections
            self.savedPlacements = placements
            bottles = .loaded(loaded)
            await loadHistory()
            relayout()
            if loaded.allSatisfy({ !$0.isInStock }) && sampleBottles.isEmpty {
                await loadSamples()
            }
        } catch {
            bottles = .failed(error.localizedDescription)
        }
    }

    func loadHistory() async {
        guard let me = env.currentUser else { return }
        let items = (try? await env.tastings.entries(forUser: me.id)) ?? []
        history = StatsCalculator.history(items)
        myRatings = Dictionary(history.compactMap { h in h.bestRating.map { (h.wine.id, $0) } }, uniquingKeysWith: max)
    }

    private func loadSamples() async {
        let wines = (try? await env.catalog.catalogSample(limit: 14)) ?? []
        sampleBottles = wines.enumerated().map { index, wine in
            CellarBottle(id: UUID(), wine: wine, quantity: index % 4 == 0 ? 2 : 1, purchasePrice: nil, purchaseDate: nil,
                         storageLocation: nil, collectionID: nil, addedAt: .now.addingTimeInterval(Double(-index) * 60), consumedCount: 0)
        }
        if showsSamplePreview { relayout() }
    }

    func relayout() {
        if showsSamplePreview && isEmpty {
            layout = CellarLayout(bottles: sampleBottles, saved: [], sort: .type)
        } else {
            layout = CellarLayout(bottles: inStock, saved: savedPlacements, sort: settings.sort, ratings: myRatings)
        }
    }

    func setSort(_ sort: CellarSort) async {
        if sort == .manual {
            // Freeze the current arrangement as the manual layout.
            savedPlacements = layout.placements
            try? await env.cellar.savePlacements(savedPlacements)
        }
        settings.sort = sort
        relayout()
        try? await env.cellar.saveSettings(settings)
    }

    func setFinish(_ finish: ShelfFinish) async {
        settings.finish = finish
        try? await env.cellar.saveSettings(settings)
    }

    func set2D(_ prefers2D: Bool) async {
        settings.prefers2D = prefers2D
        try? await env.cellar.saveSettings(settings)
    }

    func move(_ bottleID: UUID, to slot: CellarLayout.Slot) async {
        guard !(showsSamplePreview && isEmpty) else {
            layout.move(bottleID, to: slot)
            return
        }
        layout.move(bottleID, to: slot)
        savedPlacements = layout.placements
        if settings.sort != .manual {
            settings.sort = .manual
            try? await env.cellar.saveSettings(settings)
        }
        do {
            try await env.cellar.savePlacements(savedPlacements)
        } catch {
            env.show("Couldn't save arrangement", symbol: "exclamationmark.triangle.fill")
        }
    }

    func consume(_ bottle: CellarBottle) async {
        do {
            let updated = try await env.cellar.consumeBottle(id: bottle.id)
            replace(updated)
            env.cellarRevision += 1
            env.show(updated.quantity == 0 ? "Last bottle opened — kept in your history" : "Opened one · \(updated.quantity) left",
                     symbol: "wineglass.fill")
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    func updateQuantity(_ bottle: CellarBottle, quantity: Int) async {
        var updated = bottle
        updated.quantity = max(0, quantity)
        do {
            try await env.cellar.updateBottle(updated)
            replace(updated)
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    func assign(_ bottle: CellarBottle, to collection: CellarCollection?) async {
        var updated = bottle
        updated.collectionID = collection?.id
        try? await env.cellar.updateBottle(updated)
        replace(updated)
    }

    func remove(_ bottle: CellarBottle) async {
        try? await env.cellar.removeBottle(id: bottle.id)
        if case .loaded(var list) = bottles {
            list.removeAll { $0.id == bottle.id }
            bottles = .loaded(list)
        }
        relayout()
    }

    func createCollection(name: String, symbol: String) async {
        do {
            let collection = try await env.cellar.createCollection(name: name, symbol: symbol)
            collections.append(collection)
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    private func replace(_ bottle: CellarBottle) {
        guard case .loaded(var list) = bottles, let index = list.firstIndex(where: { $0.id == bottle.id }) else { return }
        list[index] = bottle
        bottles = .loaded(list)
        relayout()
    }
}
