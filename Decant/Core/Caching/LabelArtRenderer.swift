import UIKit

/// Draws a typographic label for wines without a photographed label. Used by
/// both the 2D bottle art and the 3D cellar so every bottle looks distinct.
/// The design is deterministic per wine product.
enum LabelArtRenderer {
    static let size = CGSize(width: 640, height: 448)

    // NSCache is internally thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    private struct Style {
        var paper: UIColor
        var ink: UIColor
        var accent: UIColor
        var band: UIColor?
    }

    static func image(for wine: Wine) -> UIImage {
        let key = "\(wine.productID)-\(wine.vintageLabel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = render(wine)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func style(for wine: Wine) -> Style {
        let variant = Int(wine.productID.stableSeed % 4)
        let gold = UIColor(hex: 0xB08D57)
        switch (wine.type, variant) {
        case (.sparkling, _):
            return Style(paper: UIColor(hex: 0x16181A), ink: UIColor(hex: 0xE9D7AE), accent: gold, band: nil)
        case (.rose, _):
            return Style(paper: UIColor(hex: 0xFBF4F1), ink: UIColor(hex: 0x6B2A35), accent: UIColor(hex: 0xD98C97), band: nil)
        case (.dessert, _), (.fortified, _):
            return Style(paper: UIColor(hex: 0xF3E6C8), ink: UIColor(hex: 0x3B2312), accent: gold, band: UIColor(hex: 0x5B1A12))
        case (_, 0):
            return Style(paper: UIColor(hex: 0xF4ECDD), ink: UIColor(hex: 0x2A2321), accent: gold, band: nil)
        case (_, 1):
            return Style(paper: UIColor(hex: 0x1E1B1A), ink: UIColor(hex: 0xEDE3D1), accent: gold, band: nil)
        case (_, 2):
            return Style(paper: UIColor(hex: 0xFFFFFF), ink: UIColor(hex: 0x1B1B1B), accent: UIColor(hex: 0x7A1A2E), band: nil)
        default:
            return Style(paper: UIColor(hex: 0xF7F1E6), ink: UIColor(hex: 0x2A2321), accent: gold, band: UIColor(hex: 0x7A1A2E))
        }
    }

    private static func render(_ wine: Wine) -> UIImage {
        let style = style(for: wine)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            style.paper.setFill()
            ctx.fill(rect)

            // Subtle paper grain.
            var rng = SeededGenerator(seed: wine.productID.stableSeed)
            for _ in 0..<900 {
                let x = CGFloat.random(in: 0..<size.width, using: &rng)
                let y = CGFloat.random(in: 0..<size.height, using: &rng)
                style.ink.withAlphaComponent(0.035).setFill()
                ctx.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }

            // Double rule border.
            style.accent.setStroke()
            let outer = UIBezierPath(rect: rect.insetBy(dx: 22, dy: 22))
            outer.lineWidth = 3
            outer.stroke()
            let inner = UIBezierPath(rect: rect.insetBy(dx: 32, dy: 32))
            inner.lineWidth = 1
            inner.stroke()

            if let band = style.band {
                band.setFill()
                ctx.fill(CGRect(x: 33, y: size.height - 120, width: size.width - 66, height: 34))
            }

            // Crest with producer initials.
            let crestRect = CGRect(x: size.width / 2 - 34, y: 52, width: 68, height: 68)
            let crest = UIBezierPath(ovalIn: crestRect)
            crest.lineWidth = 2
            crest.stroke()
            let initials = wine.producer.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            draw(initials, in: crestRect.insetBy(dx: 4, dy: 18), size: 26, weight: .semibold, color: style.accent)

            draw(wine.producer.uppercased(), in: CGRect(x: 60, y: 136, width: size.width - 120, height: 30),
                 size: 20, weight: .medium, color: style.ink.withAlphaComponent(0.8), kern: 3)
            draw(wine.name, in: CGRect(x: 56, y: 170, width: size.width - 112, height: 120),
                 size: wine.name.count > 22 ? 40 : 52, weight: .semibold, color: style.ink, lines: 2)

            let locale = [wine.appellation ?? wine.region, wine.country].compactMap { $0 }.joined(separator: " · ")
            draw(locale.uppercased(), in: CGRect(x: 60, y: size.height - 152, width: size.width - 120, height: 26),
                 size: 15, weight: .regular, color: style.ink.withAlphaComponent(0.7), kern: 2)
            draw(wine.vintageLabel, in: CGRect(x: 60, y: size.height - 118, width: size.width - 120, height: 34),
                 size: 26, weight: .semibold, color: style.band == nil ? style.accent : style.paper, kern: 4)
            draw(wine.type.displayName.uppercased() + " WINE", in: CGRect(x: 60, y: size.height - 74, width: size.width - 120, height: 22),
                 size: 12, weight: .regular, color: style.ink.withAlphaComponent(0.55), kern: 3)
        }
    }

    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, weight: UIFont.Weight,
                             color: UIColor, kern: CGFloat = 0, lines: Int = 1) {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        paragraph.lineHeightMultiple = 0.92
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: kern,
        ])
        let bounds = attributed.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], context: nil)
        let y = rect.minY + max(0, (rect.height - bounds.height) / 2)
        attributed.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}


/// Deterministic RNG so generated art is stable between launches.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

extension UUID {
    /// Launch-stable 64-bit value (unlike `hashValue`, which is randomized per process).
    var stableSeed: UInt64 {
        withUnsafeBytes(of: uuid) { $0.loadUnaligned(as: UInt64.self) }
    }
}
