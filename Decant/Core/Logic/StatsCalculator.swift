import Foundation

struct WineStats: Sendable, Equatable {
    struct Count: Sendable, Hashable, Identifiable {
        var label: String
        var value: Int
        var id: String { label }
    }

    struct Month: Sendable, Hashable, Identifiable {
        var start: Date
        var count: Int
        var id: Date { start }
    }

    var totalTastings = 0
    var uniqueWines = 0
    var uniqueWineries = 0
    var countries: [Count] = []
    var grapes: [Count] = []
    var regions: [Count] = []
    var types: [Count] = []
    var averageRating: Double?
    var mostExpensive: Wine?
    var topRated: [(wine: Wine, rating: Double)] = []
    var monthly: [Month] = []

    var redShare: Double {
        let total = types.map(\.value).reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(types.first { $0.label == WineType.red.displayName }?.value ?? 0) / Double(total)
    }

    static func == (lhs: WineStats, rhs: WineStats) -> Bool {
        lhs.totalTastings == rhs.totalTastings && lhs.uniqueWines == rhs.uniqueWines && lhs.monthly == rhs.monthly
    }
}

enum StatsCalculator {
    static func compute(_ items: [ReviewItem], now: Date = .now, calendar: Calendar = .current) -> WineStats {
        var stats = WineStats()
        stats.totalTastings = items.count
        let wines = Dictionary(items.map { ($0.wine.id, $0.wine) }, uniquingKeysWith: { a, _ in a })
        stats.uniqueWines = wines.count
        stats.uniqueWineries = Set(wines.values.map(\.winery.id)).count

        stats.countries = counts(wines.values.compactMap(\.country))
        stats.regions = counts(wines.values.compactMap(\.region))
        stats.grapes = counts(wines.values.flatMap { $0.grapes.map(\.name) })
        stats.types = counts(items.map(\.wine.type.displayName))

        let ratings = items.compactMap(\.entry.rating)
        stats.averageRating = ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)
        stats.mostExpensive = wines.values.filter { $0.price != nil }.max { ($0.price?.doubleValue ?? 0) < ($1.price?.doubleValue ?? 0) }

        var best: [UUID: (Wine, Double)] = [:]
        for item in items {
            guard let rating = item.entry.rating else { continue }
            if rating > best[item.wine.id]?.1 ?? 0 { best[item.wine.id] = (item.wine, rating) }
        }
        stats.topRated = best.values.sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 > $1.1 }.prefix(5).map { ($0.0, $0.1) }

        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        stats.monthly = (0..<12).reversed().compactMap { offset -> WineStats.Month? in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: thisMonth),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            return .init(start: start, count: items.filter { interval.contains($0.entry.consumedOn) }.count)
        }
        return stats
    }

    private static func counts(_ values: [String]) -> [WineStats.Count] {
        Dictionary(grouping: values, by: { $0 })
            .map { WineStats.Count(label: $0.key, value: $0.value.count) }
            .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Distinct wines tasted, newest first, for the "Wine History" library.
    static func history(_ items: [ReviewItem]) -> [HistoryWine] {
        Dictionary(grouping: items, by: \.wine.id).values.compactMap { group in
            let sorted = group.sorted { $0.entry.consumedOn > $1.entry.consumedOn }
            guard let latest = sorted.first else { return nil }
            return HistoryWine(
                wine: latest.wine,
                timesTasted: group.count,
                lastTasted: latest.entry.consumedOn,
                bestRating: group.compactMap(\.entry.rating).max(),
                latestRating: latest.entry.rating,
                isFavorite: group.contains { $0.entry.isFavorite }
            )
        }
        .sorted { $0.lastTasted > $1.lastTasted }
    }

    static func milestones(history: [HistoryWine], bottles: [CellarBottle]) -> [CollectionMilestone] {
        let tasted = history.count
        let countries = Set(history.compactMap(\.wine.country)).count
        let owned = bottles.map(\.quantity).reduce(0, +)
        let types = Set(history.map(\.wine.type)).count
        func milestone(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ value: Int, _ goal: Int) -> CollectionMilestone {
            .init(id: id, title: title, detail: detail, symbol: symbol, achieved: value >= goal, progress: min(1, Double(value) / Double(goal)))
        }
        return [
            milestone("first", "First Pour", "Log your first wine", "drop.fill", tasted, 1),
            milestone("ten", "Curious Palate", "Taste 10 different wines", "sparkles", tasted, 10),
            milestone("fifty", "Connoisseur", "Taste 50 different wines", "crown.fill", tasted, 50),
            milestone("globe", "Globetrotter", "Wines from 5 countries", "globe.europe.africa.fill", countries, 5),
            milestone("spectrum", "Full Spectrum", "Taste 5 styles of wine", "paintpalette.fill", types, 5),
            milestone("cellar", "Cellar Keeper", "Hold 12 bottles in your cellar", "square.stack.3d.up.fill", owned, 12),
        ]
    }
}
