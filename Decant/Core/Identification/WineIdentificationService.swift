import Foundation

/// Orchestrates label identification:
///   OCR text → local cache → cloud AI reading (if configured) → catalog matching
///   → on-device parser fallback.
/// Designed so a dedicated wine-recognition provider can be added as another
/// `RemoteLabelReader` without touching the UI.
struct WineIdentificationService: Sendable {
    let catalog: WineCatalogService
    let scans: ScanHistoryService
    let remote: RemoteLabelReader?

    func identify(_ capture: LabelCapture) async throws -> (result: IdentificationResult, scanKey: String?) {
        let localExtraction = LabelTextParser.parse(capture.lines)
        let textKey = capture.normalizedTextKey

        // 1. Previously confirmed match for the same label text: free and instant.
        if !textKey.isEmpty, let cachedID = await scans.cachedMatch(forTextKey: textKey),
           let wine = try? await catalog.wine(id: cachedID) {
            let candidate = WineCandidate(wine: wine, score: 0.95, vintageMismatch: false)
            return (IdentificationResult(extraction: localExtraction, candidates: [candidate], suggestion: nil, engine: .cache), nil)
        }

        // 2. Cloud AI label reading (server-side; API keys never on device).
        if let remote {
            do {
                let reading = try await remote.read(capture)
                var candidates: [WineCandidate] = []
                for (id, score) in reading.candidateWineIDs {
                    guard let wine = try? await catalog.wine(id: id) else { continue }
                    let mismatch = reading.extraction.vintage != nil && wine.vintage != reading.extraction.vintage
                    candidates.append(WineCandidate(wine: wine, score: score, vintageMismatch: mismatch))
                }
                var extraction = reading.extraction
                if extraction.rawText.isEmpty { extraction.rawText = capture.textLines }
                return (IdentificationResult(extraction: extraction, candidates: candidates.sorted { $0.score > $1.score },
                                             suggestion: reading.suggestion, engine: .cloudAI), reading.scanKey)
            } catch {
                // Fall through to on-device identification; the UI shows the engine used.
            }
        }

        // 3. On-device: deterministic parser + catalog matching. No AI suggestions.
        let pool = try await candidatePool(for: localExtraction)
        let candidates = WineMatcher.rank(localExtraction, against: pool)
        return (IdentificationResult(extraction: localExtraction, candidates: candidates, suggestion: nil, engine: .onDevice), nil)
    }

    /// Narrows the catalog to plausible wines using extracted producer/name tokens.
    private func candidatePool(for extraction: LabelExtraction) async throws -> [Wine] {
        var pool: [UUID: Wine] = [:]
        let probes = [extraction.producer, extraction.wineName].compactMap { $0 }
            + extraction.rawText.sorted { $0.count > $1.count }.prefix(3)
        for probe in probes {
            for token in TextNormalizer.tokens(probe) where token.count >= 4 {
                for wine in try await catalog.search(WineSearchQuery(text: token), limit: 25) { pool[wine.id] = wine }
            }
        }
        if pool.isEmpty {
            for wine in try await catalog.catalogSample(limit: 500) { pool[wine.id] = wine }
        }
        return Array(pool.values)
    }
}
