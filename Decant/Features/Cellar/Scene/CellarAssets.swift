import SceneKit
import UIKit

/// Shared, reusable SceneKit geometry and materials for the cellar.
/// Geometry is built once per bottle style; each bottle node gets a shallow
/// geometry copy (sharing vertex buffers) only for its unique label material.
@MainActor
final class CellarAssets {
    static let shared = CellarAssets()

    enum Dim {
        static let slotSpacing: Float = 0.105
        static let shelfSpacing: Float = 0.40
        static let shelfDepth: Float = 0.30
        static let boardThickness: Float = 0.022
        static let panelThickness: Float = 0.026
        static let baseHeight: Float = 0.12
        static var bayWidth: Float { Float(CellarLayout.slotsPerShelf) * slotSpacing + 0.05 }
        static var bayStride: Float { bayWidth + panelThickness + 0.02 }
        static var bayHeight: Float { baseHeight + Float(CellarLayout.shelvesPerBay) * shelfSpacing + 0.04 }
    }

    private var bodyGeometries: [BottleStyle: SCNGeometry] = [:]
    private var labelGeometries: [BottleStyle: SCNGeometry] = [:]
    private var glassMaterials: [WineType: SCNMaterial] = [:]
    private var capsuleMaterials: [String: SCNMaterial] = [:]
    private var woodMaterials: [ShelfFinish: SCNMaterial] = [:]
    private lazy var capsuleGeometry: SCNGeometry = SCNCylinder(radius: 0.0162, height: 0.07)
    private lazy var champagneCapsuleGeometry: SCNGeometry = SCNCylinder(radius: 0.0175, height: 0.11)

    // MARK: - Bottle profiles (radius, height) from base to lip, in metres

    private static func profile(_ style: BottleStyle) -> [SIMD2<Float>] {
        switch style {
        case .bordeaux:
            return [[0, 0], [0.033, 0], [0.0365, 0.004], [0.0365, 0.19], [0.034, 0.212], [0.024, 0.232],
                    [0.0155, 0.248], [0.0142, 0.262], [0.0142, 0.288], [0.0158, 0.291], [0.0158, 0.30], [0, 0.30]]
        case .burgundy:
            return [[0, 0], [0.036, 0], [0.0395, 0.005], [0.0395, 0.13], [0.037, 0.165], [0.029, 0.205],
                    [0.019, 0.238], [0.0145, 0.258], [0.0142, 0.288], [0.0158, 0.291], [0.0158, 0.30], [0, 0.30]]
        case .champagne:
            return [[0, 0], [0.039, 0], [0.0435, 0.006], [0.0435, 0.14], [0.041, 0.17], [0.032, 0.205],
                    [0.021, 0.238], [0.0162, 0.262], [0.0158, 0.292], [0.0175, 0.296], [0.0175, 0.305], [0, 0.305]]
        }
    }

    static func labelRadius(_ style: BottleStyle) -> Float {
        (profile(style).map(\.x).max() ?? 0.037) + 0.0006
    }

    static func labelRange(_ style: BottleStyle) -> (Float, Float) {
        switch style {
        case .bordeaux: (0.045, 0.16)
        case .burgundy: (0.035, 0.125)
        case .champagne: (0.035, 0.13)
        }
    }

    func bodyGeometry(_ style: BottleStyle) -> SCNGeometry {
        if let g = bodyGeometries[style] { return g }
        let g = Self.lathe(profile: Self.profile(style), segments: 36)
        bodyGeometries[style] = g
        return g
    }

    /// A label wrapped 210° around the front of the bottle (+Z faces the viewer).
    func labelGeometry(_ style: BottleStyle) -> SCNGeometry {
        if let g = labelGeometries[style] { return g }
        let (y0, y1) = Self.labelRange(style)
        let g = Self.cylinderPatch(radius: Self.labelRadius(style), y0: y0, y1: y1, arc: .pi * 210 / 180, segments: 28)
        labelGeometries[style] = g
        return g
    }

    func capsule(for type: WineType) -> (SCNGeometry, SCNMaterial) {
        let key: String
        let color: UIColor
        switch type {
        case .sparkling: key = "gold"; color = UIColor(hex: 0xC8A45C)
        case .white, .rose, .orange: key = "silver"; color = UIColor(hex: 0xD8D4CE)
        default: key = "burgundy"; color = UIColor(hex: 0x5A1220)
        }
        let material = capsuleMaterials[key] ?? {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = 0.85
            m.roughness.contents = 0.32
            capsuleMaterials[key] = m
            return m
        }()
        return (type == .sparkling ? champagneCapsuleGeometry : capsuleGeometry, material)
    }

    func glass(for type: WineType) -> SCNMaterial {
        if let m = glassMaterials[type] { return m }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        // Real bottle glass is much darker than the wine's brand tint.
        let tint = Palette.wineUIColor(type)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
        tint.getRed(&r, green: &g, blue: &bl, alpha: &al)
        let darken: CGFloat = type == .red || type == .fortified ? 0.55 : 0.8
        m.diffuse.contents = UIColor(red: r * darken, green: g * darken, blue: bl * darken, alpha: 1)
        m.metalness.contents = 0.15
        m.roughness.contents = 0.07
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.03
        glassMaterials[type] = m
        return m
    }

    func labelMaterial(image: UIImage?) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image ?? UIColor(hex: 0xF1E9DA)
        m.diffuse.mipFilter = .linear
        m.diffuse.wrapS = .clamp
        m.diffuse.intensity = 0.8
        m.roughness.contents = 0.7
        m.metalness.contents = 0.0
        m.isDoubleSided = false
        return m
    }

    func wood(_ finish: ShelfFinish) -> SCNMaterial {
        if let m = woodMaterials[finish] { return m }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = CellarTextures.wood(finish)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.roughness.contents = finish == .ebony ? 0.35 : 0.55
        m.metalness.contents = 0.0
        woodMaterials[finish] = m
        return m
    }

    // MARK: - Mesh builders

    /// Revolves a 2D profile around the Y axis into a smooth-shaded mesh with UVs.
    static func lathe(profile: [SIMD2<Float>], segments: Int) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [UInt32] = []
        let rings = profile.count
        let totalLength = zip(profile, profile.dropFirst()).map { simd_distance($0, $1) }.reduce(0, +)

        var accumulated: Float = 0
        for (i, point) in profile.enumerated() {
            if i > 0 { accumulated += simd_distance(profile[i - 1], point) }
            // Profile tangent → outward normal in the (r, y) plane.
            let prev = profile[max(0, i - 1)], next = profile[min(rings - 1, i + 1)]
            let tangent = simd_normalize(next - prev + SIMD2<Float>(0, 1e-6))
            let n2 = SIMD2<Float>(tangent.y, -tangent.x)
            for s in 0...segments {
                let theta = Float(s) / Float(segments) * 2 * .pi
                let c = cos(theta), sn = sin(theta)
                positions.append(SCNVector3(point.x * sn, point.y, point.x * c))
                normals.append(SCNVector3(n2.x * sn, n2.y, n2.x * c))
                uvs.append(CGPoint(x: CGFloat(s) / CGFloat(segments), y: CGFloat(1 - accumulated / totalLength)))
            }
        }
        let stride = UInt32(segments + 1)
        for ring in 0..<UInt32(rings - 1) {
            for s in 0..<UInt32(segments) {
                let a = ring * stride + s, b = a + stride
                indices += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        return geometry(positions: positions, normals: normals, uvs: uvs, indices: indices)
    }

    /// Partial cylinder (label) centred on +Z; UVs span the full label image.
    static func cylinderPatch(radius: Float, y0: Float, y1: Float, arc: Float, segments: Int) -> SCNGeometry {
        var positions: [SCNVector3] = [], normals: [SCNVector3] = [], uvs: [CGPoint] = [], indices: [UInt32] = []
        for row in 0...1 {
            let y = row == 0 ? y0 : y1
            for s in 0...segments {
                let t = Float(s) / Float(segments)
                let theta = -arc / 2 + t * arc
                positions.append(SCNVector3(radius * sin(theta), y, radius * cos(theta)))
                normals.append(SCNVector3(sin(theta), 0, cos(theta)))
                uvs.append(CGPoint(x: CGFloat(t), y: row == 0 ? 1 : 0))
            }
        }
        let stride = UInt32(segments + 1)
        for s in 0..<UInt32(segments) {
            indices += [s, s + 1, s + stride, s + 1, s + 1 + stride, s + stride]
        }
        return geometry(positions: positions, normals: normals, uvs: uvs, indices: indices)
    }

    private static func geometry(positions: [SCNVector3], normals: [SCNVector3], uvs: [CGPoint], indices: [UInt32]) -> SCNGeometry {
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [
            SCNGeometrySource(vertices: positions),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: uvs),
        ], elements: [element])
    }
}

extension BottleStyle: Hashable {}

/// Procedural textures so the cellar ships without large image assets.
enum CellarTextures {
    static func woodColor(_ finish: ShelfFinish) -> UIColor {
        switch finish {
        case .oak: UIColor(hex: 0x8E6440)
        case .walnut: UIColor(hex: 0x3E2615)
        case .ebony: UIColor(hex: 0x231B17)
        case .whitewash: UIColor(hex: 0xD8CDBE)
        }
    }

    static func wood(_ finish: ShelfFinish) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let base = woodColor(finish)
        var rng = SeededGenerator(seed: 42)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            base.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // Long grain lines with gentle waviness.
            for _ in 0..<140 {
                let y = CGFloat.random(in: 0..<size.height, using: &rng)
                let alpha = CGFloat.random(in: 0.04...0.16, using: &rng)
                let dark = Bool.random(using: &rng)
                (dark ? UIColor.black : UIColor.white).withAlphaComponent(dark ? alpha : alpha * 0.5).setStroke()
                let path = UIBezierPath()
                path.lineWidth = CGFloat.random(in: 0.6...2.4, using: &rng)
                path.move(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                var yy = y
                while x < size.width {
                    x += 32
                    yy += CGFloat.random(in: -2.5...2.5, using: &rng)
                    path.addLine(to: CGPoint(x: x, y: yy))
                }
                path.stroke()
            }
            // A few knots.
            for _ in 0..<3 {
                let c = CGPoint(x: .random(in: 40...470, using: &rng), y: .random(in: 40...470, using: &rng))
                for r in stride(from: 14.0, to: 2, by: -3) {
                    UIColor.black.withAlphaComponent(0.06).setStroke()
                    UIBezierPath(ovalIn: CGRect(x: c.x - r * 2, y: c.y - r / 2, width: r * 4, height: r)).stroke()
                }
            }
        }
    }

    static func brick() -> UIImage {
        let size = CGSize(width: 512, height: 512)
        var rng = SeededGenerator(seed: 7)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(hex: 0x2B2220).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let brickH: CGFloat = 32, brickW: CGFloat = 96
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : -brickW / 2
                while x < size.width {
                    let shade = CGFloat.random(in: 0.75...1.1, using: &rng)
                    UIColor(red: 0.36 * shade, green: 0.22 * shade, blue: 0.18 * shade, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x + 2, y: y + 2, width: brickW - 4, height: brickH - 4))
                    x += brickW
                }
                y += brickH
                row += 1
            }
        }
    }

    static func floor() -> UIImage {
        let size = CGSize(width: 512, height: 512)
        var rng = SeededGenerator(seed: 99)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(hex: 0x3A2E28).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for i in 0..<4 {
                for j in 0..<4 {
                    let shade = CGFloat.random(in: 0.85...1.1, using: &rng)
                    UIColor(red: 0.29 * shade, green: 0.24 * shade, blue: 0.21 * shade, alpha: 1).setFill()
                    ctx.fill(CGRect(x: CGFloat(i) * 128 + 1.5, y: CGFloat(j) * 128 + 1.5, width: 125, height: 125))
                }
            }
        }
    }

    /// Warm gradient used as image-based lighting for glass reflections.
    static func environment() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(hex: 0x14100E).cgColor, UIColor(hex: 0x6B4A30).cgColor,
                          UIColor(hex: 0xFFD9A0).cgColor, UIColor(hex: 0x3A2A20).cgColor, UIColor(hex: 0x0E0B0A).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 0.35, 0.5, 0.65, 1])
            if let gradient {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }
}
