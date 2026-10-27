import SwiftUI
import VisionKit

/// Live camera with on-device text detection (VisionKit DataScanner).
struct LiveLabelScanner: UIViewControllerRepresentable {
    @Binding var detectedTextCount: Int
    var captureRequest: Int
    var onCapture: (UIImage) -> Void
    var onError: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        guard captureRequest != context.coordinator.lastCaptureRequest else { return }
        context.coordinator.lastCaptureRequest = captureRequest
        Task { @MainActor in
            do {
                let photo = try await scanner.capturePhoto()
                scanner.stopScanning()
                onCapture(photo)
            } catch {
                onError("Couldn't capture the photo. \(error.localizedDescription)")
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: LiveLabelScanner
        var lastCaptureRequest = 0

        init(parent: LiveLabelScanner) {
            self.parent = parent
            self.lastCaptureRequest = parent.captureRequest
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            parent.detectedTextCount = allItems.count
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            parent.detectedTextCount = allItems.count
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            parent.onError("The camera is unavailable. You can choose a photo instead.")
        }
    }
}
