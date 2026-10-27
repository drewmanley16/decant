import Observation
import UIKit

@MainActor
@Observable
final class ScanViewModel {
    enum Phase {
        case camera
        case processing(UIImage)
        case result(ScanOutcome)
        case noText(UIImage)
        case failed(String)
    }

    struct ScanOutcome {
        var scanID: UUID
        var labelImage: UIImage
        var capture: LabelCapture
        var result: IdentificationResult
        var scanKey: String?
    }

    var phase: Phase = .camera
    var processingStep = 0
    var isConfirming = false

    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    static let steps = ["Reading the label", "Identifying the wine", "Matching the vintage"]

    func process(_ image: UIImage) async {
        phase = .processing(image)
        processingStep = 0
        do {
            let (processed, lines) = try await LabelImageProcessor.process(image)
            guard !lines.isEmpty else {
                phase = .noText(processed)
                return
            }
            processingStep = 1
            guard let jpeg = processed.jpegForUpload(maxDimension: 1400, quality: 0.8) else {
                throw AppError.validation("Couldn't prepare the photo.")
            }
            let capture = LabelCapture(imageJPEG: jpeg, lines: lines)
            let (result, scanKey) = try await env.identification.identify(capture)
            processingStep = 2
            try? await Task.sleep(for: .milliseconds(350)) // let the final step register visually
            phase = .result(ScanOutcome(scanID: UUID(), labelImage: processed, capture: capture, result: result, scanKey: scanKey))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// User confirmed a catalog match (possibly a different vintage).
    func confirm(_ candidate: WineCandidate, in outcome: ScanOutcome, useScannedVintage: Bool) async -> Wine? {
        var wine = candidate.wine
        if useScannedVintage, candidate.vintageMismatch {
            var draft = WineDraft()
            draft.name = candidate.wine.name
            draft.producer = candidate.wine.producer
            draft.vintage = outcome.result.extraction.vintage
            draft.type = candidate.wine.type
            draft.grapes = candidate.wine.grapes.map(\.name)
            draft.country = candidate.wine.country ?? ""
            draft.region = candidate.wine.region ?? ""
            draft.appellation = candidate.wine.appellation ?? ""
            draft.abv = outcome.result.extraction.abv
            draft.bottleSizeML = outcome.result.extraction.volumeML ?? candidate.wine.bottleSizeML
            draft.source = .label
            guard let created = await create(draft, outcome: outcome) else { return nil }
            wine = created
        }
        return await finalize(wine, outcome: outcome, confidence: candidate.score)
    }

    /// User entered or corrected the details manually.
    func confirmManual(_ draft: WineDraft, outcome: ScanOutcome?) async -> Wine? {
        guard let created = await create(draft, outcome: outcome) else { return nil }
        guard let outcome else {
            env.show("Wine added")
            return created
        }
        return await finalize(created, outcome: outcome, confidence: nil)
    }

    private func create(_ draft: WineDraft, outcome: ScanOutcome?) async -> Wine? {
        isConfirming = true
        defer { isConfirming = false }
        do {
            return try await env.catalog.createWine(from: draft, scanKey: outcome?.scanKey, suggestion: outcome?.result.suggestion)
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            return nil
        }
    }

    /// Saves the label photo, records scan history and caches the match.
    private func finalize(_ wine: Wine, outcome: ScanOutcome, confidence: Double?) async -> Wine {
        isConfirming = true
        defer { isConfirming = false }
        var result = wine
        if let path = try? await env.media.storeLabel(outcome.capture.imageJPEG, id: outcome.scanID) {
            try? await env.catalog.setLabelImage(path: path, for: wine.id)
            if result.labelImagePath == nil { result.labelImagePath = path }
            try? await env.scans.record(ScanRecord(id: outcome.scanID, wineID: wine.id, wineName: wine.displayName,
                                                   labelImagePath: path, confidence: confidence, createdAt: .now))
        }
        if let suggestion = outcome.result.suggestion, wine.characteristics == nil {
            try? await env.catalog.attachSuggestion(suggestion, scanKey: outcome.scanKey, to: wine.id)
        }
        await env.scans.cacheMatch(textKey: outcome.capture.normalizedTextKey, wineID: wine.id)
        return (try? await env.catalog.wine(id: wine.id)).map { refreshed in
            var r = refreshed
            if r.labelImagePath == nil { r.labelImagePath = result.labelImagePath }
            return r
        } ?? result
    }
}
