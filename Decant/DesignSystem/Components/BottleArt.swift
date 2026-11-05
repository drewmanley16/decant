import SwiftUI

/// Loads an image path through `ImageLoader` with a placeholder.
struct StoredImage<Placeholder: View>: View {
    var path: String?
    var maxPixel: CGFloat = 900
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(path: String?, maxPixel: CGFloat = 900, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.path = path
        self.maxPixel = maxPixel
        self.placeholder = placeholder
        // Synchronous cache hit avoids a placeholder flash (and lets ImageRenderer see it).
        _image = State(initialValue: path.flatMap { ImageLoader.shared.cachedImage(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            guard let path else { image = nil; return }
            if let cached = ImageLoader.shared.cachedImage(for: path) { image = cached; return }
            let loaded = await ImageLoader.shared.image(for: path, maxPixel: maxPixel)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Classic Bordeaux bottle silhouette in a unit rect (width:height ≈ 1:3.6).
struct BottleShape: Shape {
    var style: BottleStyle = .bordeaux

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let neckW = w * 0.3
        let shoulderTop = h * (style == .burgundy ? 0.42 : 0.30)
        let shoulderBottom = h * (style == .burgundy ? 0.55 : 0.40)
        let neckTop = h * 0.03
        var p = Path()
        p.move(to: CGPoint(x: (w - neckW) / 2, y: neckTop))
        p.addLine(to: CGPoint(x: (w + neckW) / 2, y: neckTop))
        p.addLine(to: CGPoint(x: (w + neckW) / 2, y: shoulderTop))
        p.addCurve(to: CGPoint(x: w, y: shoulderBottom),
                   control1: CGPoint(x: (w + neckW) / 2, y: shoulderTop + (shoulderBottom - shoulderTop) * 0.5),
                   control2: CGPoint(x: w, y: shoulderTop + (shoulderBottom - shoulderTop) * 0.4))
        p.addLine(to: CGPoint(x: w, y: h - w * 0.08))
        p.addQuadCurve(to: CGPoint(x: w - w * 0.08, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w * 0.08, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - w * 0.08), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: shoulderBottom))
        p.addCurve(to: CGPoint(x: (w - neckW) / 2, y: shoulderTop),
                   control1: CGPoint(x: 0, y: shoulderTop + (shoulderBottom - shoulderTop) * 0.4),
                   control2: CGPoint(x: (w - neckW) / 2, y: shoulderTop + (shoulderBottom - shoulderTop) * 0.5))
        p.closeSubpath()
        return p
    }
}

enum BottleStyle {
    case bordeaux, burgundy, champagne

    init(type: WineType, grapes: [GrapeShare]) {
        let names = Set(grapes.map(\.name))
        if type == .sparkling {
            self = .champagne
        } else if names.contains("Pinot Noir") || names.contains("Chardonnay") || names.contains("Nebbiolo") {
            self = .burgundy
        } else {
            self = .bordeaux
        }
    }
}

/// A studio-lit bottle with the wine's label (scanned photo or generated art).
/// Layers, back to front: glass body, cylindrical shading, transmitted light,
/// label (with wrap shading), foil capsule, specular streaks and a rim light.
struct BottleArtView: View {
    var wine: Wine
    var height: CGFloat = 160

    private var style: BottleStyle { BottleStyle(type: wine.type, grapes: wine.grapes) }
    private var width: CGFloat { height / (style == .champagne ? 3.3 : 3.6) }
    private var glass: Color { Palette.wineColor(wine.type) }
    /// Pale glass (white, rosé) reads lighter, so it gets less edge darkening.
    private var isPaleGlass: Bool { [.white, .rose, .dessert, .orange].contains(wine.type) }
    private var shoulderY: CGFloat { height * (style == .burgundy ? 0.42 : 0.30) }
    private var bodyTopY: CGFloat { height * (style == .burgundy ? 0.55 : 0.40) }

    var body: some View {
        let shape = BottleShape(style: style)
        ZStack(alignment: .top) {
            shape.fill(glass)
            // Cylindrical falloff: dark edges, lit left-of-centre.
            shape.fill(LinearGradient(stops: [
                .init(color: .black.opacity(isPaleGlass ? 0.38 : 0.6), location: 0),
                .init(color: .black.opacity(0.12), location: 0.14),
                .init(color: .clear, location: 0.3),
                .init(color: .clear, location: 0.55),
                .init(color: .black.opacity(isPaleGlass ? 0.18 : 0.32), location: 0.82),
                .init(color: .black.opacity(isPaleGlass ? 0.42 : 0.65), location: 1),
            ], startPoint: .leading, endPoint: .trailing))
            // Light passing through the far wall of the glass.
            shape.fill(LinearGradient(stops: [
                .init(color: .clear, location: 0.5),
                .init(color: .white.opacity(isPaleGlass ? 0.16 : 0.09), location: 0.68),
                .init(color: .clear, location: 0.84),
            ], startPoint: .leading, endPoint: .trailing))
            // Heavier glass at the base.
            shape.fill(LinearGradient(stops: [
                .init(color: .clear, location: 0.9),
                .init(color: .black.opacity(0.3), location: 0.97),
                .init(color: .white.opacity(0.12), location: 1),
            ], startPoint: .top, endPoint: .bottom))

            label
            capsule
            highlights.mask(shape)
            // Rim light along the silhouette.
            shape.stroke(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04), .white.opacity(0.18)],
                                        startPoint: .leading, endPoint: .trailing),
                         lineWidth: max(0.5, width * 0.02))
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .background(alignment: .bottom) { contactShadow }
        .shadow(color: .black.opacity(0.18), radius: height * 0.035, x: 0, y: height * 0.025)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bottle of \(wine.displayName)")
    }

    // MARK: Layers

    private var label: some View {
        StoredImage(path: wine.labelImagePath, maxPixel: 600) {
            Image(uiImage: LabelArtRenderer.image(for: wine)).resizable()
        }
        .aspectRatio(contentMode: .fill)
        // Generated labels are landscape; size the paper to match so the name isn't cropped.
        .frame(width: width * 0.94, height: min(height * 0.3, width * 0.94 * LabelArtRenderer.size.height / LabelArtRenderer.size.width))
        .clipped()
        .overlay {
            // Wrap shading so the paper reads as curved around the glass.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.42), location: 0),
                .init(color: .black.opacity(0.08), location: 0.2),
                .init(color: .white.opacity(0.14), location: 0.36),
                .init(color: .clear, location: 0.55),
                .init(color: .black.opacity(0.18), location: 0.82),
                .init(color: .black.opacity(0.48), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.black.opacity(0.18)).frame(height: max(0.5, height * 0.004))
        }
        .clipShape(RoundedRectangle(cornerRadius: max(1, width * 0.03)))
        .offset(y: height * 0.58)
    }

    private var capsule: some View {
        let w = width * 0.33, h = height * 0.17
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: w * 0.14)
                .fill(capsuleColor)
            RoundedRectangle(cornerRadius: w * 0.14)
                .fill(LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .white.opacity(0.35), location: 0.28),
                    .init(color: .white.opacity(0.05), location: 0.45),
                    .init(color: .black.opacity(0.15), location: 0.7),
                    .init(color: .black.opacity(0.5), location: 1),
                ], startPoint: .leading, endPoint: .trailing))
            // Crimped rings at the foot of the foil.
            VStack(spacing: h * 0.05) {
                Rectangle().fill(.black.opacity(0.25)).frame(height: max(0.5, h * 0.025))
                Rectangle().fill(.black.opacity(0.2)).frame(height: max(0.5, h * 0.025))
            }
            .padding(.bottom, h * 0.1)
        }
        .frame(width: w, height: h)
        .overlay(alignment: .top) {
            // Top disc of the capsule.
            Capsule().fill(.white.opacity(0.22)).frame(width: w * 0.8, height: max(1, h * 0.05)).padding(.top, h * 0.02)
        }
        .offset(y: height * 0.02)
    }

    private var highlights: some View {
        ZStack(alignment: .topLeading) {
            // Main vertical streak down the body.
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.75), .white.opacity(0.55), .white.opacity(0.0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.085, height: height - bodyTopY)
                .blur(radius: width * 0.02)
                .offset(x: width * 0.2, y: bodyTopY)
            // Crisp core of the reflection.
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.8), .white.opacity(0.6), .white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: max(0.6, width * 0.025), height: (height - bodyTopY) * 0.92)
                .offset(x: width * 0.23, y: bodyTopY + height * 0.01)
            // Fainter secondary streak on the shadow side.
            Capsule()
                .fill(.white.opacity(0.16))
                .frame(width: width * 0.035, height: (height - bodyTopY) * 0.8)
                .blur(radius: width * 0.02)
                .offset(x: width * 0.8, y: bodyTopY + height * 0.03)
            // Glint on the curve of the shoulder.
            Ellipse()
                .fill(.white.opacity(0.5))
                .frame(width: width * 0.22, height: height * 0.05)
                .rotationEffect(.degrees(-35))
                .blur(radius: width * 0.03)
                .offset(x: width * 0.12, y: (shoulderY + bodyTopY) / 2 - height * 0.02)
            // Streak on the neck.
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: width * 0.03, height: shoulderY - height * 0.19)
                .blur(radius: width * 0.012)
                .offset(x: width * 0.41, y: height * 0.19)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var contactShadow: some View {
        Ellipse()
            .fill(.black.opacity(0.28))
            .frame(width: width * 1.5, height: max(3, width * 0.2))
            .blur(radius: max(1.5, width * 0.08))
            .offset(y: width * 0.06)
            .allowsHitTesting(false)
    }

    private var capsuleColor: Color {
        switch wine.type {
        case .sparkling: Palette.gold
        case .white, .rose, .orange: Color(white: 0.82)
        default: Palette.burgundyDeep
        }
    }
}

/// Soft vignette background used behind hero bottles. The bottle carries its
/// own contact shadow, so the stage only provides the glow.
struct BottleStage<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            RadialGradient(colors: [tint.opacity(0.22), tint.opacity(0.04), .clear], center: .center, startRadius: 10, endRadius: 260)
            content()
        }
    }
}
