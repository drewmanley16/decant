import Foundation

/// Scores catalog wines against a label extraction. Vintage-aware: a product
/// match with the wrong vintage is returned but flagged and penalized.
enum WineMatcher {
    private static let stopwords: Set<String> = ["the", "de", "la", "le", "les", "du", "des", "di", "del", "della", "wine", "wines", "and", "et", "vin", "vino"]

    static func rank(_ extraction: LabelExtraction, against catalog: [Wine], limit: Int = 5) -> [WineCandidate] {
        let labelTokens = Set(TextNormalizer.tokens(
            (extraction.rawText + [extraction.producer, extraction.wineName].compactMap { $0 }).joined(separator: " ")
        ))
        guard !labelTokens.isEmpty else { return [] }

        let scored = catalog.compactMap { wine -> WineCandidate? in
            let nameScore = coverage(of: wine.name, in: labelTokens)
            let producerScore = coverage(of: wine.producer, in: labelTokens)
            guard nameScore > 0 || producerScore > 0 else { return nil }

            var score = 0.55 * nameScore + 0.35 * producerScore
            if let type = extraction.type {
                score += type == wine.type ? 0.1 : -0.15
            } else {
                score += 0.05
            }
            if let region = extraction.region, let wineRegion = wine.region,
               TextNormalizer.fold(region) == TextNormalizer.fold(wineRegion) {
                score += 0.05
            }

            var vintageMismatch = false
            switch (extraction.vintage, wine.vintage) {
            case let (scanned?, catalog?) where scanned == catalog: break
            case (_?, _?), (_?, nil):
                score *= 0.8
                vintageMismatch = true
            case (nil, _?): score *= 0.9
            case (nil, nil): break
            }
            return WineCandidate(wine: wine, score: min(1, max(0, score)), vintageMismatch: vintageMismatch)
        }

        // Keep the best-scoring vintage first, but retain sibling vintages as alternatives.
        return scored
            .filter { $0.score >= 0.2 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Fraction of meaningful tokens in `phrase` found (fuzzily) in the label.
    static func coverage(of phrase: String, in labelTokens: Set<String>) -> Double {
        let tokens = TextNormalizer.tokens(phrase).filter { !stopwords.contains($0) }
        guard !tokens.isEmpty else { return 0 }
        let hits = tokens.filter { token in
            if labelTokens.contains(token) { return true }
            guard token.count >= 5 else { return false }
            return labelTokens.contains { abs($0.count - token.count) <= 1 && TextNormalizer.levenshtein($0, token) <= 1 }
        }
        return Double(hits.count) / Double(tokens.count)
    }
}
