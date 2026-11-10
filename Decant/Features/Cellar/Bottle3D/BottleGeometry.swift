import RealityKit
import simd

/// The four bottle silhouettes the cellar draws, chosen from the wine's style.
enum BottleForm: String, CaseIterable, Sendable {
    case bordeaux, burgundy, champagne, flute

    init(wine: Wine) {
        let grapes = Set(wine.grapes.map(\.name))
        let region = (wine.region ?? "").lowercased()
        if wine.type == .sparkling {
            self = .champagne
        } else if !grapes.isDisjoint(with: ["Riesling", "Gewürztraminer", "Gewurztraminer", "Grüner Veltliner"])
                    || region.contains("mosel") || region.contains("alsace") || region.contains("provence") {
            self = .flute
        } else if !grapes.isDisjoint(with: ["Pinot Noir", "Chardonnay", "Nebbiolo", "Syrah", "Viognier", "Gamay"])
                    || region.contains("burgundy") || region.contains("piedmont") || region.contains("rhône") || region.contains("rhone") {
            self = .burgundy
        } else {
            self = .bordeaux
        }
    }

    /// Outline from the base centre to the lip centre as (radius, height) in metres,
    /// taken from real 750 ml bottles. Smoothed before lathing.
    var profile: [SIMD2<Float>] {
        switch self {
        case .bordeaux:
            return [[0, 0.004], [0.026, 0.0], [0.0352, 0.002], [0.0365, 0.008], [0.0365, 0.19], [0.0352, 0.207],
                    [0.029, 0.224], [0.0195, 0.238], [0.0152, 0.25], [0.0143, 0.265], [0.0143, 0.287], [0.0158, 0.29],
                    [0.0158, 0.299], [0.012, 0.30], [0, 0.30]]
        case .burgundy:
            return [[0, 0.004], [0.028, 0.0], [0.0385, 0.002], [0.0396, 0.009], [0.0396, 0.125], [0.0383, 0.15],
                    [0.0345, 0.178], [0.0275, 0.207], [0.0198, 0.233], [0.0152, 0.252], [0.0143, 0.268], [0.0143, 0.287],
                    [0.0158, 0.29], [0.0158, 0.299], [0.012, 0.30], [0, 0.30]]
        case .champagne:
            return [[0, 0.006], [0.03, 0.0], [0.0425, 0.002], [0.0438, 0.01], [0.0438, 0.135], [0.0425, 0.158],
                    [0.038, 0.184], [0.03, 0.211], [0.0215, 0.237], [0.0168, 0.258], [0.0158, 0.275], [0.0158, 0.292],
                    [0.0185, 0.295], [0.0185, 0.304], [0.013, 0.305], [0, 0.305]]
        case .flute:
            return [[0, 0.004], [0.025, 0.0], [0.0335, 0.002], [0.0345, 0.008], [0.0345, 0.13], [0.0335, 0.165],
                    [0.029, 0.205], [0.0225, 0.245], [0.0165, 0.278], [0.0135, 0.3], [0.0132, 0.336], [0.0148, 0.339],
                    [0.0148, 0.348], [0.011, 0.349], [0, 0.349]]
        }
    }

    var height: Float { profile.last?.y ?? 0.3 }
    var bodyRadius: Float { profile.map(\.x).max() ?? 0.037 }

    /// Vertical span of the front label, in metres from the base.
    var labelSpan: (Float, Float) {
        switch self {
        case .bordeaux: (0.045, 0.16)
        case .burgundy: (0.035, 0.118)
        case .champagne: (0.038, 0.125)
        case .flute: (0.04, 0.118)
        }
    }

    /// Where the foil capsule starts; it runs from here to the lip.
    var capsuleBottom: Float {
        switch self {
        case .bordeaux: 0.247
        case .burgundy: 0.248
        case .champagne: 0.2
        case .flute: 0.292
        }
    }
}

/// Builds lathed bottle meshes. Pure geometry, no materials.
enum BottleMeshBuilder {
    /// Catmull-Rom smoothing so shoulders read as curves rather than facets.
    static func smooth(_ points: [SIMD2<Float>], steps: Int = 5) -> [SIMD2<Float>] {
        guard points.count > 2 else { return points }
        var out: [SIMD2<Float>] = []
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                let t2 = t * t, t3 = t2 * t
                let a = 2 * p1
                let b = (p2 - p0) * t
                let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                let d = (3 * p1 - p0 - 3 * p2 + p3) * t3
                out.append(0.5 * (a + b + c + d))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    /// Revolves a (radius, height) profile around the Y axis. U runs around, V up the profile.
    static func lathe(_ profile: [SIMD2<Float>], segments: Int = 72, radiusOffset: Float = 0) -> MeshDescriptor {
        let pts = profile.map { SIMD2<Float>($0.x > 0 ? $0.x + radiusOffset : 0, $0.y) }
        // Per-point profile normals, averaged from neighbouring segments.
        var normals2D: [SIMD2<Float>] = []
        for i in pts.indices {
            let prev = pts[max(i - 1, 0)], next = pts[min(i + 1, pts.count - 1)]
            let tangent = next - prev
            var n = SIMD2<Float>(tangent.y, -tangent.x)
            if simd_length(n) < 1e-6 { n = [0, i == 0 ? -1 : 1] }
            normals2D.append(simd_normalize(n))
        }
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        let totalLength = zip(pts, pts.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
        var run: Float = 0
        for (i, p) in pts.enumerated() {
            if i > 0 { run += simd_distance(pts[i - 1], p) }
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * .pi
                let (sinA, cosA) = (sin(a), cos(a))
                positions.append([p.x * sinA, p.y, p.x * cosA])
                normals.append(simd_normalize([normals2D[i].x * sinA, normals2D[i].y, normals2D[i].x * cosA]))
                uvs.append([Float(s) / Float(segments), run / max(totalLength, 1e-4)])
            }
        }
        var indices: [UInt32] = []
        let ring = UInt32(segments + 1)
        for i in 0..<UInt32(pts.count - 1) {
            for s in 0..<UInt32(segments) {
                let a = i * ring + s, b = a + 1, c = a + ring, d = c + 1
                // Counter-clockwise seen from outside, so faces point away from the axis.
                indices += [a, b, c, b, d, c]
            }
        }
        var descriptor = MeshDescriptor(name: "lathe")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    /// A cylindrical label patch centred on +Z (facing the camera). The arc follows the
    /// label image's aspect ratio so artwork isn't stretched.
    static func label(form: BottleForm, aspect: Float, segments: Int = 40) -> MeshDescriptor {
        let (y0, y1) = form.labelSpan
        let radius = radius(of: form, at: (y0 + y1) / 2) + 0.0007
        let arc = min(max(aspect * (y1 - y0) / radius, 2.0), 4.5)
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        for s in 0...segments {
            let u = Float(s) / Float(segments)
            let a = (u - 0.5) * arc
            let n = SIMD3<Float>(sin(a), 0, cos(a))
            for (y, v) in [(y0, Float(0)), (y1, Float(1))] {
                positions.append([n.x * radius, y, n.z * radius])
                normals.append(n)
                uvs.append([u, v])
            }
        }
        var indices: [UInt32] = []
        for s in 0..<UInt32(segments) {
            let a = s * 2, b = a + 1, c = a + 2, d = a + 3
            indices += [a, c, b, b, c, d]
        }
        var descriptor = MeshDescriptor(name: "label")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    /// The foil capsule: the top of the profile, lathed slightly proud of the glass.
    static func capsule(form: BottleForm) -> MeshDescriptor {
        let smoothProfile = smooth(form.profile)
        var top = smoothProfile.filter { $0.y >= form.capsuleBottom }
        top.insert([radius(of: form, at: form.capsuleBottom), form.capsuleBottom], at: 0)
        return lathe(top, segments: 56, radiusOffset: 0.0009)
    }

    /// Body radius at a given height, interpolated from the smoothed profile.
    static func radius(of form: BottleForm, at y: Float) -> Float {
        let pts = smooth(form.profile).filter { $0.x > 0 }
        for (a, b) in zip(pts, pts.dropFirst()) where (a.y...max(a.y, b.y)).contains(y) && b.y != a.y {
            return a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)
        }
        return form.bodyRadius
    }
}

extension BottleMeshBuilder {
    /// A narrow strip of the bottle surface between two angles (radians, 0 = facing the
    /// camera), lifted just off the glass. Used for softbox reflections that stay fixed
    /// relative to the camera while the bottle turns. Skips the label, which is matte.
    static func highlight(form: BottleForm, from a0: Float, to a1: Float, segments: Int = 10) -> [MeshDescriptor] {
        let profile = smooth(form.profile).filter { $0.x > 0.004 }
        let (l0, l1) = form.labelSpan
        let pieces = [profile.filter { $0.y > 0.012 && $0.y < l0 - 0.003 },
                      profile.filter { $0.y > l1 + 0.003 && $0.y < form.capsuleBottom - 0.004 }]
        return pieces.filter { $0.count > 1 }.map { pts in
            var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
            let yMin = pts.first!.y, yMax = pts.last!.y
            for p in pts {
                for s in 0...segments {
                    let u = Float(s) / Float(segments)
                    let a = a0 + (a1 - a0) * u
                    let r = p.x + 0.0012
                    positions.append([r * sin(a), p.y, r * cos(a)])
                    normals.append([sin(a), 0, cos(a)])
                    uvs.append([u, (p.y - yMin) / max(yMax - yMin, 1e-4)])
                }
            }
            var indices: [UInt32] = []
            let ring = UInt32(segments + 1)
            for i in 0..<UInt32(pts.count - 1) {
                for s in 0..<UInt32(segments) {
                    let a = i * ring + s, b = a + 1, c = a + ring, d = c + 1
                    indices += [a, b, c, b, d, c]
                }
            }
            var descriptor = MeshDescriptor(name: "highlight")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
            descriptor.primitives = .triangles(indices)
            return descriptor
        }
    }
}

extension WineType {
    /// Clear or light-tinted glass, which shows highlights less strongly.
    var isPaleGlass: Bool { [.rose, .white, .dessert, .orange].contains(self) }
}

extension String {
    /// FNV-1a hash that is stable across launches (unlike `hashValue`). Used for cache keys.
    var stableSeed: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
