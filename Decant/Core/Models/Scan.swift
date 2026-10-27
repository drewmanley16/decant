import Foundation

/// Structured information read from a label. Every field is something that was
/// actually printed on the label (or nil). Nothing here is inferred.
struct LabelExtraction: Codable, Hashable, Sendable {
    var producer: String?
    var wineName: String?
    var vintage: Int?
    var type: WineType?
    var grapes: [String] = []
    var country: String?
    var region: String?
    var appellation: String?
    var abv: Double?
    var volumeML: Int?
    var rawText: [String] = []

    var asDraft: WineDraft {
        var draft = WineDraft()
        draft.name = wineName ?? ""
        draft.producer = producer ?? ""
        draft.vintage = vintage
        draft.type = type ?? .red
        draft.grapes = grapes
        draft.country = country ?? ""
        draft.region = region ?? ""
        draft.appellation = appellation ?? ""
        draft.abv = abv
        draft.bottleSizeML = volumeML ?? 750
        draft.source = .label
        return draft
    }
}

enum MatchConfidence: String, Sendable, Codable {
    case high, medium, low

    init(score: Double) {
        switch score {
        case 0.75...: self = .high
        case 0.45..<0.75: self = .medium
        default: self = .low
        }
    }

    var label: String {
        switch self {
        case .high: "Confident match"
        case .medium: "Likely match"
        case .low: "Uncertain"
        }
    }
}

struct WineCandidate: Hashable, Sendable, Identifiable {
    var wine: Wine
    var score: Double
    /// True when the catalog has this product but the scanned vintage differs.
    var vintageMismatch: Bool
    var id: UUID { wine.id }
    var confidence: MatchConfidence { MatchConfidence(score: score) }
}

/// AI tasting suggestions. Always displayed as suggestions, never as facts.
struct AITastingSuggestion: Codable, Hashable, Sendable {
    var characteristics: WineCharacteristics?
    var pairings: [String] = []
    var summary: String?
}

enum IdentificationEngine: String, Sendable, Codable {
    case cache, cloudAI = "cloud_ai", onDevice = "on_device"

    var label: String {
        switch self {
        case .cache: "Recognized from your scan history"
        case .cloudAI: "Identified with AI label reading"
        case .onDevice: "Identified on device"
        }
    }
}

struct IdentificationResult: Sendable {
    var extraction: LabelExtraction
    var candidates: [WineCandidate]
    var suggestion: AITastingSuggestion?
    var engine: IdentificationEngine

    var best: WineCandidate? { candidates.first }
}

/// One recognized line of label text. `height` is the normalized glyph height
/// (0...1 of the image), used as a proxy for typographic prominence.
struct OCRLine: Sendable, Hashable, Codable {
    var text: String
    var height: Double
}

/// The captured label: the processed (cropped / perspective corrected) image and
/// recognized text lines in reading order.
struct LabelCapture: Sendable {
    var imageJPEG: Data
    var lines: [OCRLine]

    var textLines: [String] { lines.map(\.text) }

    var normalizedTextKey: String {
        textLines.joined(separator: " ").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
            .joined(separator: " ")
    }
}

struct ScanRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var wineID: UUID?
    var wineName: String?
    var labelImagePath: String?
    var confidence: Double?
    var createdAt: Date
}
