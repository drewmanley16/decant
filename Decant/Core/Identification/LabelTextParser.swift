import Foundation

/// Deterministic, on-device parser that turns OCR lines into a `LabelExtraction`.
/// It only reports what is literally present in the text; it never fills gaps.
enum LabelTextParser {
    static func parse(_ lines: [OCRLine], currentYear: Int = Calendar.current.component(.year, from: .now)) -> LabelExtraction {
        let cleaned = lines
            .map { OCRLine(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), height: $0.height) }
            .filter { !$0.text.isEmpty }
        let fullText = cleaned.map(\.text).joined(separator: "\n")
        let folded = TextNormalizer.fold(fullText)

        var result = LabelExtraction()
        result.rawText = cleaned.map(\.text)
        result.vintage = vintage(in: cleaned.map(\.text), currentYear: currentYear)
        result.abv = abv(in: fullText)
        result.volumeML = volume(in: fullText)
        result.grapes = WineLexicon.grapes.filter { TextNormalizer.containsPhrase(folded, TextNormalizer.fold($0.name)) }.map(\.name)
        let appellation = appellation(in: cleaned.map(\.text), folded: folded)
        result.appellation = appellation?.name
        result.region = appellation?.region
        result.country = appellation?.country ?? country(in: folded)
        result.type = type(in: folded, grapes: result.grapes, appellation: appellation)
        let (producer, name) = producerAndName(cleaned, excluding: result)
        result.producer = producer
        result.wineName = name
        return result
    }

    // MARK: - Field extractors

    static func vintage(in lines: [String], currentYear: Int) -> Int? {
        let pattern = /(?:^|[^\d.,])(19[5-9]\d|20[0-9]\d)(?![\d%])/
        var candidates: [(year: Int, weight: Int)] = []
        for line in lines {
            let lower = line.lowercased()
            // Founding dates are not vintages.
            let isHistory = ["since", "depuis", "est.", "established", "founded", "fondé", "dal ", "seit"].contains { lower.contains($0) }
            for match in line.matches(of: pattern) {
                guard let year = Int(match.output.1), year <= currentYear else { continue }
                let standalone = line.trimmingCharacters(in: .whitespaces).count <= 6
                candidates.append((year, (isHistory ? -10 : 0) + (standalone ? 3 : 1)))
            }
        }
        return candidates.filter { $0.weight > 0 }.max { $0.weight == $1.weight ? $0.year < $1.year : $0.weight < $1.weight }?.year
    }

    static func abv(in text: String) -> Double? {
        let pattern = /(\d{1,2}(?:[.,]\d{1,2})?)\s*%\s*(?:vol|alc|abv|by\s*vol)?/
        for match in text.lowercased().matches(of: pattern) {
            let value = Double(match.output.1.replacingOccurrences(of: ",", with: ".")) ?? 0
            if (5...23).contains(value) { return value }
        }
        return nil
    }

    static func volume(in text: String) -> Int? {
        let lower = text.lowercased().replacingOccurrences(of: ",", with: ".")
        if let m = lower.firstMatch(of: /(\d{3,4})\s*m\s?l\b/), let v = Int(m.output.1), [187, 375, 500, 750, 1000, 1500, 3000].contains(v) {
            return v
        }
        if let m = lower.firstMatch(of: /(\d{2,3}(?:\.\d)?)\s*c\s?l\b/), let v = Double(m.output.1) {
            let ml = Int((v * 10).rounded())
            if [375, 500, 750, 1000, 1500].contains(ml) { return ml }
        }
        if let m = lower.firstMatch(of: /(\d(?:\.\d{1,2})?)\s*(?:l|litre|liter)\b/), let v = Double(m.output.1) {
            let ml = Int((v * 1000).rounded())
            if [750, 1000, 1500, 3000].contains(ml) { return ml }
        }
        return nil
    }

    static func country(in folded: String) -> String? {
        for (needle, country) in WineLexicon.countryPhrases where TextNormalizer.containsPhrase(folded, needle) {
            return country
        }
        return nil
    }

    static func appellation(in lines: [String], folded: String) -> WineLexicon.Place? {
        // "Appellation Margaux Contrôlée" style statements are the most reliable.
        for line in lines {
            let f = TextNormalizer.fold(line)
            if let m = f.firstMatch(of: /appellation\s+(.+?)\s+(?:controlee|protegee)/) {
                let name = String(m.output.1)
                if let known = WineLexicon.places.first(where: { TextNormalizer.fold($0.name) == name }) { return known }
                if let known = WineLexicon.places.first(where: { name.contains(TextNormalizer.fold($0.name)) }) { return known }
            }
        }
        // Otherwise the most specific (longest) known place mentioned anywhere.
        return WineLexicon.places
            .filter { TextNormalizer.containsPhrase(folded, TextNormalizer.fold($0.name)) }
            .max { $0.name.count < $1.name.count }
    }

    static func type(in folded: String, grapes: [String], appellation: WineLexicon.Place?) -> WineType? {
        let has = { (words: [String]) in words.contains { TextNormalizer.containsPhrase(folded, $0) } }
        if has(["champagne", "sparkling", "brut", "prosecco", "cava", "cremant", "spumante", "sekt", "methode traditionnelle", "metodo classico"]) { return .sparkling }
        if has(["port", "porto", "sherry", "jerez", "madeira", "marsala"]) { return .fortified }
        if has(["sauternes", "late harvest", "ice wine", "icewine", "eiswein", "tokaji", "beerenauslese", "vin santo", "passito"]) { return .dessert }
        if has(["rose", "rosado", "rosato"]) { return .rose }
        if has(["orange wine", "skin contact", "amber wine"]) { return .orange }
        if let style = appellation?.style { return style }
        if has(["rouge", "rosso", "tinto", "red wine"]) { return .red }
        if has(["blanc", "bianco", "blanco", "weisswein", "white wine"]) { return .white }
        let colors = Set(grapes.compactMap { name in WineLexicon.grapes.first { $0.name == name }?.color })
        return colors.count == 1 ? colors.first : nil
    }

    static func producerAndName(_ lines: [OCRLine], excluding info: LabelExtraction) -> (String?, String?) {
        let boilerplate = ["contains sulfites", "product of", "produce of", "alc", "vol", "ml", "bottled", "imported", "government warning", "www", "mis en bouteille", "appellation", "wine of", "estate bottled"]
        let candidates = lines.filter { line in
            let f = TextNormalizer.fold(line.text)
            guard f.count >= 3, f.rangeOfCharacter(from: .letters) != nil else { return false }
            if isClassification(f) { return false }
            if boilerplate.contains(where: { f.contains($0) }) { return false }
            if let v = info.vintage, f == String(v) { return false }
            return true
        }

        let producerMarkers = ["chateau", "domaine", "bodega", "bodegas", "tenuta", "weingut", "maison", "cantina", "quinta", "clos", "estate", "winery", "vineyards", "vineyard", "cellars", "wines", "marchesi", "castello", "fattoria", "dr."]
        var producer = candidates.first { line in
            let f = TextNormalizer.fold(line.text)
            return producerMarkers.contains { f == $0 || f.hasPrefix($0 + " ") || f.hasSuffix(" " + $0) || f.contains(" \($0) ") }
        }?.text

        if let current = producer, producerMarkers.contains(TextNormalizer.fold(current)),
           let index = candidates.firstIndex(where: { $0.text == current }), index + 1 < candidates.count {
            producer = current + " " + candidates[index + 1].text
        }

        if producer == nil {
            for line in lines {
                if let m = line.text.firstMatch(of: /(?i)(?:produced|bottled|made|vinified)\s+(?:and\s+bottled\s+)?by\s+(.+)/) {
                    producer = String(m.output.1).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
                    break
                }
            }
        }

        let ranked = candidates.sorted { $0.height > $1.height }
        let grapeNames = Set(info.grapes.map { TextNormalizer.fold($0) })
        let name = ranked.first { line in
            let f = TextNormalizer.fold(line.text)
            if let producer, TextNormalizer.fold(producer) == f || TextNormalizer.fold(producer).hasPrefix(f + " ") { return false }
            if grapeNames.contains(f) || info.appellation.map({ TextNormalizer.fold($0) == f }) == true { return false }
            return true
        }?.text

        let finalProducer = producer.map(titleCase) ?? ranked.first.map { titleCase($0.text) }
        // Wines named after their estate (e.g. "Château Margaux") repeat the producer.
        let finalName = name.map(titleCase) ?? finalProducer
        return (finalProducer, finalName)
    }

    /// Quality/classification statements ("Premier Grand Cru Classé", "Grand Vin") are never names.
    static func isClassification(_ folded: String) -> Bool {
        let words: Set<String> = ["grand", "grands", "vin", "premier", "premiers", "1er", "cru", "crus", "classe", "classes",
                                  "superieur", "second", "de", "du", "en", "1855", "docg", "doc", "aoc", "aop", "igt"]
        let tokens = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return !tokens.isEmpty && tokens.allSatisfy(words.contains)
    }

    private static func titleCase(_ text: String) -> String {
        let isShouting = text == text.uppercased() && text.count > 3
        return isShouting ? text.lowercased().capitalized : text
    }
}

enum TextNormalizer {
    /// Lowercased, diacritic-free, single-spaced.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    /// Whole-word phrase containment on folded text.
    static func containsPhrase(_ folded: String, _ phrase: String) -> Bool {
        guard let range = folded.range(of: phrase) else { return false }
        let before = range.lowerBound == folded.startIndex ? nil : folded[folded.index(before: range.lowerBound)]
        let after = range.upperBound == folded.endIndex ? nil : folded[range.upperBound]
        let isBoundary: (Character?) -> Bool = { c in c.map { !$0.isLetter && !$0.isNumber } ?? true }
        if isBoundary(before) && isBoundary(after) { return true }
        // Check later occurrences.
        let rest = String(folded[range.upperBound...])
        return rest.count >= phrase.count && containsPhrase(rest, phrase)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
