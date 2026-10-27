import Foundation
import Testing
@testable import Decant

@Suite("Label parsing")
struct LabelTextParserTests {
    private func lines(_ texts: [(String, Double)]) -> [OCRLine] {
        texts.map { OCRLine(text: $0.0, height: $0.1) }
    }

    @Test func parsesClassicBordeauxLabel() {
        let result = LabelTextParser.parse(lines([
            ("GRAND VIN", 0.03),
            ("CHÂTEAU MARGAUX", 0.08),
            ("PREMIER GRAND CRU CLASSÉ", 0.02),
            ("2015", 0.05),
            ("APPELLATION MARGAUX CONTRÔLÉE", 0.015),
            ("MIS EN BOUTEILLE AU CHÂTEAU", 0.012),
            ("13,5% vol", 0.012),
            ("750 ml", 0.012),
        ]), currentYear: 2026)

        #expect(result.vintage == 2015)
        #expect(result.abv == 13.5)
        #expect(result.volumeML == 750)
        #expect(result.appellation == "Margaux")
        #expect(result.region == "Bordeaux")
        #expect(result.country == "France")
        #expect(result.type == .red)
        #expect(result.producer == "Château Margaux")
    }

    @Test func ignoresFoundingYearsAndFutureYears() {
        let result = LabelTextParser.parse(lines([
            ("Since 1858", 0.02), ("Marqués de Riscal", 0.06), ("Reserva", 0.04), ("2019", 0.04), ("2031", 0.01),
        ]), currentYear: 2026)
        #expect(result.vintage == 2019)
    }

    @Test func detectsSparklingAndNonVintage() {
        let result = LabelTextParser.parse(lines([
            ("MOËT & CHANDON", 0.07), ("CHAMPAGNE", 0.04), ("IMPÉRIAL", 0.05), ("BRUT", 0.03), ("12% vol", 0.01), ("75 cl", 0.01),
        ]), currentYear: 2026)
        #expect(result.type == .sparkling)
        #expect(result.vintage == nil)
        #expect(result.volumeML == 750)
        #expect(result.region == "Champagne")
    }

    @Test func infersTypeFromSingleColorGrapes() {
        let result = LabelTextParser.parse(lines([("Kim Crawford", 0.06), ("Sauvignon Blanc", 0.04), ("Marlborough", 0.02), ("2023", 0.03)]),
                                           currentYear: 2026)
        #expect(result.grapes == ["Sauvignon Blanc"])
        #expect(result.type == .white)
        #expect(result.country == "New Zealand")
    }

    @Test func emptyInputProducesNoFacts() {
        let result = LabelTextParser.parse([], currentYear: 2026)
        #expect(result.producer == nil && result.vintage == nil && result.type == nil && result.grapes.isEmpty)
    }

    @Test func phraseMatchingRespectsWordBoundaries() {
        #expect(TextNormalizer.containsPhrase("imported by acme", "port") == false)
        #expect(TextNormalizer.containsPhrase("tawny port wine", "port"))
        #expect(TextNormalizer.levenshtein("margaux", "margeaux") == 1)
    }
}

@Suite("Wine matching")
struct WineMatcherTests {
    let catalog = SeedCatalog.load()

    @Test func catalogIsBundled() {
        #expect(catalog.count >= 25)
        #expect(Set(catalog.map(\.id)).count == catalog.count)
    }

    @Test func matchesExactVintageWithHighConfidence() throws {
        var extraction = LabelExtraction()
        extraction.producer = "Château Margaux"
        extraction.wineName = "Château Margaux"
        extraction.vintage = 2015
        extraction.type = .red
        extraction.rawText = ["CHATEAU MARGAUX", "2015"]
        let best = try #require(WineMatcher.rank(extraction, against: catalog).first)
        #expect(best.wine.name == "Château Margaux")
        #expect(best.wine.vintage == 2015)
        #expect(best.vintageMismatch == false)
        #expect(best.confidence == .high)
    }

    @Test func distinguishesVintagesOfTheSameWine() throws {
        var extraction = LabelExtraction()
        extraction.rawText = ["CHATEAU MARGAUX", "2010"]
        extraction.vintage = 2010
        let ranked = WineMatcher.rank(extraction, against: catalog)
        let best = try #require(ranked.first)
        #expect(best.wine.vintage == 2010)
        let other = try #require(ranked.first { $0.wine.vintage == 2015 })
        #expect(other.vintageMismatch)
        #expect(other.score < best.score)
    }

    @Test func flagsUnknownVintageOfKnownWine() throws {
        var extraction = LabelExtraction()
        extraction.rawText = ["TIGNANELLO", "ANTINORI", "2016"]
        extraction.vintage = 2016
        let best = try #require(WineMatcher.rank(extraction, against: catalog).first)
        #expect(best.wine.name == "Tignanello")
        #expect(best.vintageMismatch)
    }

    @Test func toleratesOCRTypos() throws {
        var extraction = LabelExtraction()
        extraction.rawText = ["SASSICAIA", "TENUTA SAN GUlDO", "2019"]
        extraction.vintage = 2019
        let best = try #require(WineMatcher.rank(extraction, against: catalog).first)
        #expect(best.wine.name == "Sassicaia")
    }

    @Test func unrelatedTextYieldsNoConfidentMatch() {
        var extraction = LabelExtraction()
        extraction.rawText = ["Bodega Imaginaria", "Vino Tinto Joven", "2021"]
        let best = WineMatcher.rank(extraction, against: catalog).first
        #expect(best == nil || best!.confidence == .low)
    }

    @Test func confidenceThresholds() {
        #expect(MatchConfidence(score: 0.9) == .high)
        #expect(MatchConfidence(score: 0.6) == .medium)
        #expect(MatchConfidence(score: 0.2) == .low)
    }
}

@Suite("Label parsing — layout quirks")
struct LabelLayoutTests {
    @Test func joinsProducerSplitAcrossLines() {
        let result = LabelTextParser.parse([
            OCRLine(text: "CHÂTEAU", height: 0.07), OCRLine(text: "MARGAUX", height: 0.07), OCRLine(text: "2015", height: 0.06),
        ], currentYear: 2026)
        #expect(result.producer == "Château Margaux")
    }
}

@Suite("Label parsing — classifications")
struct ClassificationTests {
    @Test func classificationLinesAreNeverNames() {
        let result = LabelTextParser.parse([
            OCRLine(text: "GRAND VIN", height: 0.03), OCRLine(text: "CHÂTEAU", height: 0.08),
            OCRLine(text: "PREMIER GRAND CRU CLASSÉ", height: 0.04), OCRLine(text: "2015", height: 0.06),
        ], currentYear: 2026)
        #expect(result.producer == "Château")
        #expect(result.wineName != "Premier Grand Cru Classé")
        #expect(LabelTextParser.isClassification("premier grand cru classe"))
        #expect(!LabelTextParser.isClassification("chateau margaux"))
    }
}
