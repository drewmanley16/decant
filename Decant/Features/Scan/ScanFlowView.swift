import PhotosUI
import SwiftUI

/// Full-screen scan experience: camera → processing → identification → details.
struct ScanFlowView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScanViewModel?
    @State private var path: [ScanRoute] = []

    enum ScanRoute: Hashable {
        case wine(Wine)
        case manual
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    ScanPhaseView(model: model, onIdentified: { path.append(.wine($0)) }, onManual: { path.append(.manual) })
                }
            }
            .navigationDestination(for: ScanRoute.self) { route in
                switch route {
                case .wine(let wine):
                    WineDetailView(wine: wine, origin: .scan)
                case .manual:
                    ManualEntryView(prefill: model?.currentOutcome?.result.extraction.asDraft) { draft in
                        guard let wine = await model?.confirmManual(draft, outcome: model?.currentOutcome) else { return }
                        path = [.wine(wine)]
                    }
                }
            }
            .appDestinations()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close scanner")
                }
            }
        }
        .task { if model == nil { model = ScanViewModel(env: env) } }
    }
}

extension ScanViewModel {
    var currentOutcome: ScanOutcome? {
        if case .result(let outcome) = phase { return outcome }
        return nil
    }
}

private struct ScanPhaseView: View {
    @Bindable var model: ScanViewModel
    var onIdentified: (Wine) -> Void
    var onManual: () -> Void

    var body: some View {
        switch model.phase {
        case .camera:
            CameraStage(model: model, onManual: onManual)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        case .processing(let image):
            ProcessingStage(image: image, step: model.processingStep)
                .toolbarColorScheme(.dark, for: .navigationBar)
        case .result(let outcome):
            ScanResultView(model: model, outcome: outcome, onIdentified: onIdentified, onManual: onManual)
        case .noText(let image):
            ScanProblemView(image: image, title: "We couldn't read this label",
                            message: "Try again with the label filling the frame, in good light, or enter the wine manually.",
                            retake: { model.phase = .camera }, manual: onManual)
        case .failed(let message):
            ScanProblemView(image: nil, title: "Scanning didn't work", message: message,
                            retake: { model.phase = .camera }, manual: onManual)
        }
    }
}

// MARK: - Camera

private struct CameraStage: View {
    var model: ScanViewModel
    var onManual: () -> Void
    @State private var detected = 0
    @State private var captureRequest = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var cameraError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if LiveLabelScanner.isAvailable && cameraError == nil {
                LiveLabelScanner(detectedTextCount: $detected, captureRequest: captureRequest,
                                 onCapture: { image in Task { await model.process(image) } },
                                 onError: { cameraError = $0 })
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.metering.unknown").font(.system(size: 38)).foregroundStyle(.white.opacity(0.6))
                    Text(cameraError ?? "Live scanning isn't available on this device.")
                        .font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    Text("Choose a photo of a label instead.").font(.footnote).foregroundStyle(.white.opacity(0.6))
                }
                .padding(40)
            }
            LabelFrameOverlay(isLocked: detected >= 3)
            VStack {
                Text(detected >= 3 ? "Label detected — hold steady" : "Fit the front label inside the frame")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.top, 8)
                    .animation(.smooth, value: detected >= 3)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer()
                controls
            }
        }
        .sensoryFeedback(.success, trigger: detected >= 3)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await model.process(image)
                }
                photoItem = nil
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ControlIcon(symbol: "photo.on.rectangle", label: "Photos")
            }
            Spacer()
            Button {
                captureRequest += 1
            } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                    Circle().fill(detected >= 3 ? Palette.gold : .white).frame(width: 64, height: 64)
                }
            }
            .disabled(!LiveLabelScanner.isAvailable || cameraError != nil)
            .opacity(LiveLabelScanner.isAvailable && cameraError == nil ? 1 : 0.35)
            .accessibilityLabel("Capture label")
            Spacer()
            Button(action: onManual) { ControlIcon(symbol: "square.and.pencil", label: "Manual") }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 30)
    }

}

private struct ControlIcon: View {
    var symbol: String
    var label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3).frame(width: 52, height: 52).background(.white.opacity(0.15), in: Circle())
            Text(label).font(.caption2.weight(.medium))
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// Elegant label-shaped viewfinder with corner brackets and a sweeping scan line.
private struct LabelFrameOverlay: View {
    var isLocked: Bool
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 0.74
            let height = width * 1.25
            let rect = CGRect(x: (proxy.size.width - width) / 2, y: (proxy.size.height - height) / 2 - 30, width: width, height: height)
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .mask {
                        Rectangle().overlay {
                            RoundedRectangle(cornerRadius: 22).frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                CornerBrackets()
                    .stroke(isLocked ? Palette.gold : .white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.smooth, value: isLocked)
                if !reduceMotion {
                    LinearGradient(colors: [.clear, Palette.gold.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: rect.width - 30, height: 2)
                        .shadow(color: Palette.gold, radius: 6)
                        .position(x: rect.midX, y: sweep ? rect.maxY - 20 : rect.minY + 20)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: sweep)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { sweep = true }
        .accessibilityHidden(true)
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let l: CGFloat = 34, r: CGFloat = 22
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

// MARK: - Processing

private struct ProcessingStage: View {
    var image: UIImage
    var step: Int
    @State private var pulse = false

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .blur(radius: 18)
                .overlay(Color.black.opacity(0.55).ignoresSafeArea())
            VStack(spacing: 30) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.gold.opacity(pulse ? 0.9 : 0.3), lineWidth: 2))
                    .shadow(color: Palette.gold.opacity(pulse ? 0.45 : 0.1), radius: 24)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(ScanViewModel.steps.enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 12) {
                            ZStack {
                                if index < step {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.gold)
                                } else if index == step {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.white.opacity(0.3))
                                }
                            }
                            .frame(width: 22)
                            Text(title).foregroundStyle(index <= step ? .white : .white.opacity(0.45))
                        }
                        .font(.body.weight(.medium))
                    }
                }
                .animation(.smooth, value: step)
            }
            .padding(30)
        }
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Identifying wine. \(ScanViewModel.steps[min(step, 2)])")
    }
}

private struct ScanProblemView: View {
    var image: UIImage?
    var title: String
    var message: String
    var retake: () -> Void
    var manual: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16)).opacity(0.85)
            }
            EmptyStateView(symbol: "text.viewfinder", title: title, message: message)
            Button("Try again", action: retake).buttonStyle(.primary)
            Button("Enter wine manually", action: manual).buttonStyle(.secondary)
            Spacer()
        }
        .padding(Metrics.gutter)
        .screenBackground()
    }
}
