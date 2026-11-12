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

// MARK: - Taste profile & year in review

/// A few plain-language observations about how someone drinks.
struct TasteTrait: Sendable, Hashable, Identifiable {
    var symbol: String
    var title: String
    var detail: String
    var id: String { title }
}

/// One calendar year of tastings, for the shareable Year in Review.
struct YearReview: Sendable, Equatable {
    var year: Int
    var tastings = 0
    var uniqueWines = 0
    var fiveStars = 0
    var countries = 0
    var topWine: Wine?
    var topWineCount = 0
    var bestRated: (wine: Wine, rating: Double)?
    var topGrape: String?
    var topCountry: String?
    var topStyle: String?
    var topOccasion: String?
    var busiestMonth: Date?
    var friendsTagged = 0

    static func == (a: YearReview, b: YearReview) -> Bool {
        a.year == b.year && a.tastings == b.tastings && a.topWine?.id == b.topWine?.id && a.bestRated?.wine.id == b.bestRated?.wine.id
    }
}

extension StatsCalculator {
    static func tasteTraits(_ items: [ReviewItem]) -> [TasteTrait] {
        guard items.count >= 3 else { return [] }
        var traits: [TasteTrait] = []
        let stats = compute(items)

        if let style = stats.types.first {
            let share = Double(style.value) / Double(max(1, items.count))
            traits.append(TasteTrait(symbol: "wineglass.fill", title: share >= 0.6 ? "\(style.label) devotee" : "Leans \(style.label.lowercased())",
                                     detail: "\(Int((share * 100).rounded()))% of your tastings are \(style.label.lowercased())."))
        }

        // The style you rate highest, when you've rated it at least twice.
        let byType = Dictionary(grouping: items.filter { $0.entry.rating != nil }, by: \.wine.type)
            .filter { $0.value.count >= 2 }
            .mapValues { group in group.compactMap(\.entry.rating).reduce(0, +) / Double(group.count) }
        if byType.count >= 2, let best = byType.max(by: { $0.value < $1.value }) {
            traits.append(TasteTrait(symbol: "star.fill", title: "Happiest with \(best.key.displayName.lowercased())",
                                     detail: "You rate it \(best.value.formatted(.number.precision(.fractionLength(1))))★ on average."))
        }

        if let grape = stats.grapes.first, grape.value >= 2 {
            traits.append(TasteTrait(symbol: "leaf.fill", title: "Go-to grape: \(grape.label)", detail: "In \(grape.value) of the wines you’ve tried."))
        }
        if let country = stats.countries.first {
            let others = stats.countries.count - 1
            traits.append(TasteTrait(symbol: "globe.europe.africa.fill", title: "Home base: \(country.label)",
                                     detail: others > 0 ? "Plus \(others) other countr\(others == 1 ? "y" : "ies") explored." : "Time to explore another country?"))
        }
        if let average = stats.averageRating {
            let (title, detail) = switch average {
            case 4.3...: ("Generous rater", "Your average is \(average.formatted(.number.precision(.fractionLength(1))))★. You know how to pick them.")
            case ..<3.2: ("Tough critic", "Your average is \(average.formatted(.number.precision(.fractionLength(1))))★. A five from you means something.")
            default: ("Balanced palate", "Your average is \(average.formatted(.number.precision(.fractionLength(1))))★.")
            }
            traits.append(TasteTrait(symbol: "scalemass.fill", title: title, detail: detail))
        }
        let answered = items.compactMap(\.entry.drinkAgain)
        if answered.count >= 3 {
            let yes = answered.filter { $0 }.count
            traits.append(TasteTrait(symbol: "arrow.triangle.2.circlepath", title: "Would drink again: \(Int((Double(yes) / Double(answered.count) * 100).rounded()))%",
                                     detail: "Of the \(answered.count) wines you gave a verdict on."))
        }
        return traits
    }

    static func yearReview(_ items: [ReviewItem], year: Int, calendar: Calendar = .current) -> YearReview {
        let yearItems = items.filter { calendar.component(.year, from: $0.entry.consumedOn) == year }
        var review = YearReview(year: year)
        review.tastings = yearItems.count
        guard !yearItems.isEmpty else { return review }
        let stats = compute(yearItems)
        review.uniqueWines = stats.uniqueWines
        review.countries = stats.countries.count
        review.fiveStars = yearItems.filter { ($0.entry.rating ?? 0) >= 5 }.count
        review.topGrape = stats.grapes.first?.label
        review.topCountry = stats.countries.first?.label
        review.topStyle = stats.types.first?.label
        if let best = stats.topRated.first { review.bestRated = (best.wine, best.rating) }

        let byWine = Dictionary(grouping: yearItems, by: \.wine.id)
        if let most = byWine.max(by: { $0.value.count < $1.value.count }), let wine = most.value.first?.wine {
            review.topWine = wine
            review.topWineCount = most.value.count
        }
        let occasions = yearItems.compactMap { $0.entry.occasion?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        review.topOccasion = Dictionary(grouping: occasions, by: { $0.lowercased() })
            .max { $0.value.count < $1.value.count }.flatMap { $0.value.count >= 2 ? $0.value.first : nil }
        let months = Dictionary(grouping: yearItems) { calendar.dateInterval(of: .month, for: $0.entry.consumedOn)?.start ?? $0.entry.consumedOn }
        review.busiestMonth = months.max { $0.value.count < $1.value.count }?.key
        review.friendsTagged = Set(yearItems.flatMap(\.entry.taggedUserIDs)).count
        return review
    }
}
