import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// Prepares a photographed label: perspective-corrects to the detected label
/// rectangle (or crops to the text region on curved bottles) and runs OCR.
enum LabelImageProcessor {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func process(_ image: UIImage) async throws -> (image: UIImage, lines: [OCRLine]) {
        try await Task.detached(priority: .userInitiated) {
            guard let upright = image.normalizedOrientation(maxDimension: 2400), let cg = upright.cgImage else {
                throw AppError.validation("That image couldn't be read.")
            }
            let ci = CIImage(cgImage: cg)
            let fullLines = try recognizeText(in: cg)

            var output = upright
            if let rectangle = try detectLabelRectangle(in: cg), let corrected = perspectiveCorrect(ci, rectangle) {
                output = corrected
            } else if let textBox = textBoundingBox(fullLines.observations), let cropped = crop(ci, normalized: textBox) {
                output = cropped
            }
            return (output, fullLines.lines)
        }.value
    }

    // MARK: - OCR

    private static func recognizeText(in cg: CGImage) throws -> (lines: [OCRLine], observations: [VNRecognizedTextObservation]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // proper nouns (producers, places) get "corrected" badly
        request.recognitionLanguages = ["en-US", "fr-FR", "it-IT", "es-ES", "de-DE", "pt-BR"]
        request.minimumTextHeight = 0.012
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let observations = (request.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.3 }
        // Reading order: top to bottom, then left to right.
        let sorted = observations.sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        let lines = sorted.compactMap { obs -> OCRLine? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return OCRLine(text: text, height: Double(obs.boundingBox.height))
        }
        return (lines, sorted)
    }

    // MARK: - Geometry

    private static func detectLabelRectangle(in cg: CGImage) throws -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.25
        request.minimumConfidence = 0.8
        request.quadratureTolerance = 20
        request.maximumObservations = 1
        try VNImageRequestHandler(cgImage: cg).perform([request])
        guard let rect = request.results?.first else { return nil }
        // Ignore rectangles that are basically the whole frame (no useful crop).
        return rect.boundingBox.width * rect.boundingBox.height > 0.92 ? nil : rect
    }

    private static func perspectiveCorrect(_ image: CIImage, _ r: VNRectangleObservation) -> UIImage? {
        let size = image.extent.size
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = point(r.topLeft)
        filter.topRight = point(r.topRight)
        filter.bottomLeft = point(r.bottomLeft)
        filter.bottomRight = point(r.bottomRight)
        guard let out = filter.outputImage, let cg = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func textBoundingBox(_ observations: [VNRecognizedTextObservation]) -> CGRect? {
        guard !observations.isEmpty else { return nil }
        let union = observations.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        let padded = union.insetBy(dx: -union.width * 0.12, dy: -union.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return padded.width * padded.height < 0.05 ? nil : padded
    }

    private static func crop(_ image: CIImage, normalized: CGRect) -> UIImage? {
        let e = image.extent
        let rect = CGRect(x: normalized.minX * e.width, y: normalized.minY * e.height,
                          width: normalized.width * e.width, height: normalized.height * e.height)
        guard let cg = context.createCGImage(image.cropped(to: rect), from: rect) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension UIImage {
    /// Redraws with `.up` orientation (Vision/CoreImage expect pixel-aligned data), downscaling if needed.
    func normalizedOrientation(maxDimension: CGFloat) -> UIImage? {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(pixelSize.width, pixelSize.height)
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        guard target.width > 0, target.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
