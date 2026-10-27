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

/// A stylized, lit bottle with the wine's label (scanned photo or generated art).
struct BottleArtView: View {
    var wine: Wine
    var height: CGFloat = 160

    private var style: BottleStyle { BottleStyle(type: wine.type, grapes: wine.grapes) }
    private var width: CGFloat { height / (style == .champagne ? 3.3 : 3.6) }
    private var glass: Color { Palette.wineColor(wine.type) }

    var body: some View {
        ZStack(alignment: .top) {
            BottleShape(style: style)
                .fill(LinearGradient(colors: [glass.opacity(0.95), glass, glass.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
            // Capsule / foil
            RoundedRectangle(cornerRadius: width * 0.06)
                .fill(LinearGradient(colors: [capsuleColor.opacity(0.85), capsuleColor, capsuleColor.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                .frame(width: width * 0.33, height: height * 0.16)
                .offset(y: height * 0.02)
            label
                .frame(width: width * 0.96, height: height * 0.3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .offset(y: height * 0.55)
            // Glass highlight
            BottleShape(style: style)
                .fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0), location: 0.12),
                    .init(color: .white.opacity(0.28), location: 0.2),
                    .init(color: .white.opacity(0), location: 0.3),
                    .init(color: .white.opacity(0), location: 0.85),
                    .init(color: .white.opacity(0.12), location: 0.9),
                    .init(color: .white.opacity(0), location: 0.95),
                ], startPoint: .leading, endPoint: .trailing))
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.25), radius: height * 0.04, x: 0, y: height * 0.03)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bottle of \(wine.displayName)")
    }

    private var capsuleColor: Color {
        switch wine.type {
        case .sparkling: Palette.gold
        case .white, .rose: Color(white: 0.85)
        default: Palette.burgundyDeep
        }
    }

    @ViewBuilder private var label: some View {
        StoredImage(path: wine.labelImagePath, maxPixel: 600) {
            Image(uiImage: LabelArtRenderer.image(for: wine)).resizable()
        }
        .aspectRatio(contentMode: .fill)
    }
}

/// Soft vignette background used behind hero bottles.
struct BottleStage<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            RadialGradient(colors: [tint.opacity(0.22), tint.opacity(0.04), .clear], center: .center, startRadius: 10, endRadius: 260)
            Ellipse()
                .fill(.black.opacity(0.18))
                .frame(width: 110, height: 16)
                .blur(radius: 8)
                .offset(y: 120)
            content()
        }
    }
}
