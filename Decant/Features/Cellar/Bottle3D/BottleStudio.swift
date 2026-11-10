import Metal
import RealityKit
import UIKit

/// Builds 3D bottles and renders them to images. The same entity powers both the
/// shelf thumbnails (rendered once, then cached) and the live inspect view, so a
/// bottle looks identical on the shelf and in your hand.
@MainActor
final class BottleStudio {
    static let shared = BottleStudio()

    /// Bump when the look changes so cached renders are redrawn.
    nonisolated static let renderVersion = 11
    /// Every thumbnail shares one canvas so bottles keep their real relative heights.
    nonisolated static let canvasHeightMetres: Float = 0.37
    nonisolated static let canvasAspect: CGFloat = 0.34

    private var meshes: [String: MeshResource] = [:]
    private var environment: EnvironmentResource?
    private var renderer: RealityRenderer?
    private var camera: Entity?
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let memory = NSCache<NSString, UIImage>()
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()

    private init() {
        memory.countLimit = 300
    }

    // MARK: - Entities

    /// A complete bottle (glass, capsule, label) standing at the origin with its label facing +Z.
    func makeBottle(for wine: Wine, label: UIImage?) -> Entity {
        let form = BottleForm(wine: wine)
        let root = Entity()
        root.name = "bottle"
        // Glass, foil and label turn together; the softbox highlights stay with the camera.
        let spinner = Entity()
        spinner.name = "spinner"
        root.addChild(spinner)

        if let body = mesh("body-\(form)", { try MeshResource.generate(from: [BottleMeshBuilder.lathe(BottleMeshBuilder.smooth(form.profile))]) }) {
            spinner.addChild(ModelEntity(mesh: body, materials: [glassMaterial(for: wine.type)]))
        }
        if let cap = mesh("capsule-\(form)", { try MeshResource.generate(from: [BottleMeshBuilder.capsule(form: form)]) }) {
            spinner.addChild(ModelEntity(mesh: cap, materials: [capsuleMaterial(for: wine)]))
        }
        let labelImage = label ?? LabelArtRenderer.image(for: wine)
        let aspect = Float(labelImage.size.width / max(labelImage.size.height, 1))
        let aspectKey = Int((aspect * 10).rounded())
        if let labelMesh = mesh("label-\(form)-\(aspectKey)", { try MeshResource.generate(from: [BottleMeshBuilder.label(form: form, aspect: Float(aspectKey) / 10)]) }),
           let material = labelMaterial(labelImage) {
            spinner.addChild(ModelEntity(mesh: labelMesh, materials: [material]))
        }
        root.addChild(makeHighlights(form: form, strength: wine.type.isPaleGlass ? 0.55 : 0.8))
        return root
    }

    /// Softbox reflections, kept outside the spinner so they don't turn with the bottle.
    func makeHighlights(form: BottleForm, strength: Float) -> Entity {
        let group = Entity()
        group.name = "highlights"
        let strips: [(Float, Float, Float)] = [(-0.62, -0.42, 1.0), (0.66, 0.74, 0.55), (-1.2, -1.12, 0.35)]
        for (index, (a0, a1, power)) in strips.enumerated() {
            guard let material = highlightMaterial(opacity: power * strength) else { continue }
            for (part, descriptor) in BottleMeshBuilder.highlight(form: form, from: a0, to: a1).enumerated() {
                if let mesh = mesh("hl-\(form)-\(index)-\(part)", { try MeshResource.generate(from: [descriptor]) }) {
                    group.addChild(ModelEntity(mesh: mesh, materials: [material]))
                }
            }
        }
        return group
    }

    private var highlightTexture: TextureResource?

    /// Soft-edged white strip: bright core across the width, fading at both ends.
    private func highlightMaterial(opacity: Float) -> UnlitMaterial? {
        if highlightTexture == nil {
            let size = CGSize(width: 64, height: 256)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                for x in 0..<64 {
                    let u = (CGFloat(x) + 0.5) / 64
                    let across = pow(sin(u * .pi), 1.6)
                    for y in 0..<256 {
                        let v = (CGFloat(y) + 0.5) / 256
                        let along = min(1, min(v, 1 - v) * 6)
                        // Opacity is read from the colour channels, so the fade is stored as grey.
                        UIColor(white: across * along, alpha: 1).setFill()
                        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            if let cg = image.cgImage {
                do {
                    highlightTexture = try TextureResource(image: cg, options: .init(semantic: .raw))
                } catch {
                    print("BottleStudio: highlight texture failed: \(error)")
                }
            }
        }
        guard let highlightTexture else { return nil }
        var m = UnlitMaterial(color: UIColor(white: 1, alpha: 1))
        m.color = .init(tint: UIColor(red: 1, green: 0.97, blue: 0.92, alpha: 1))
        m.blending = .transparent(opacity: .init(scale: opacity, texture: .init(highlightTexture)))
        return m
    }

    /// Scanned label photo when there is one, otherwise the generated label art.
    func labelImage(for wine: Wine) async -> UIImage {
        if let path = wine.labelImagePath, let photo = await ImageLoader.shared.image(for: path, maxPixel: 1024) {
            return photo
        }
        return await Task.detached(priority: .utility) { LabelArtRenderer.image(for: wine) }.value
    }

    /// Soft studio light: two tall strip boxes either side of the camera, a dim top
    /// light and a warm floor bounce. Strip boxes give glass its vertical highlights.
    func studioEnvironment() -> EnvironmentResource? {
        if let environment { return environment }
        guard let image = Self.studioImage() else { return nil }
        environment = try? EnvironmentResource(equirectangular: image)
        return environment
    }

    private func mesh(_ key: String, _ make: () throws -> MeshResource) -> MeshResource? {
        if let hit = meshes[key] { return hit }
        let made = try? make()
        meshes[key] = made
        return made
    }

    private func glassMaterial(for type: WineType) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let color: UIColor = switch type {
        case .red: UIColor(hex: 0x1C0A0D)
        case .fortified: UIColor(hex: 0x1E0D07)
        case .white: UIColor(hex: 0x3E4B1E)
        case .rose: UIColor(hex: 0xE3A1A4)
        case .orange: UIColor(hex: 0x8F4C1C)
        case .sparkling: UIColor(hex: 0x1B2416)
        case .dessert: UIColor(hex: 0x8E5A14)
        }
        m.baseColor = .init(tint: color)
        m.metallic = 0.0
        m.roughness = 0.08
        m.specular = 0.9
        m.clearcoat = .init(floatLiteral: 1)
        m.clearcoatRoughness = .init(floatLiteral: 0.02)
        return m
    }

    private func capsuleMaterial(for wine: Wine) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let palette: [UInt32] = switch wine.type {
        case .sparkling: [0xC8A04E, 0x1B1B1B, 0xD8B25A]
        case .white, .rose, .orange: [0xD9D6CF, 0xC6A253, 0xE8E2D0]
        case .dessert, .fortified: [0xB8954F, 0x4A1C10, 0x2A2A2A]
        case .red: [0x5A1220, 0x1C1414, 0xB9975B, 0x2C2C33]
        }
        let hex = palette[Int(wine.productID.stableSeed % UInt64(palette.count))]
        m.baseColor = .init(tint: UIColor(hex: hex))
        m.metallic = 0.85
        m.roughness = 0.32
        return m
    }

    private func labelMaterial(_ image: UIImage) -> PhysicallyBasedMaterial? {
        guard let cg = image.cgImage,
              let texture = try? TextureResource(image: cg, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        else { return nil }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(texture: .init(texture))
        m.roughness = 0.85
        m.metallic = 0.0
        m.specular = 0.2
        return m
    }

    // MARK: - Thumbnails

    nonisolated static func cacheKey(for wine: Wine) -> String {
        // `labelImagePath.stableSeed` rather than `hashValue`, which changes every launch.
        "v\(renderVersion)-\(wine.id.uuidString)-\(wine.labelImagePath.map { String($0.stableSeed, radix: 36) } ?? "art")"
    }

    func cachedThumbnail(for wine: Wine) -> UIImage? {
        let key = Self.cacheKey(for: wine)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let data = try? Data(contentsOf: Self.diskURL(key)), let image = UIImage(data: data, scale: 3) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        return nil
    }

    /// A studio render of the bottle on a transparent background, cached in memory and on disk.
    func thumbnail(for wine: Wine, pixelHeight: Int = 720) async -> UIImage? {
        if let hit = cachedThumbnail(for: wine) { return hit }
        let key = Self.cacheKey(for: wine)
        if let running = inFlight[key] { return await running.value }
        let task = Task<UIImage?, Never> { @MainActor in
            let label = await labelImage(for: wine)
            let image = await render(makeBottle(for: wine, label: label), pixelHeight: pixelHeight)
            if let image {
                memory.setObject(image, forKey: key as NSString)
                if let data = image.pngData() {
                    try? FileManager.default.createDirectory(at: Self.diskURL(key).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: Self.diskURL(key), options: .atomic)
                }
            }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    private static func diskURL(_ key: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bottles", isDirectory: true)
            .appendingPathComponent(key + ".png")
    }

    /// Vertical field of view shared by thumbnails and the live view, so they match exactly.
    nonisolated static let fieldOfView: Float = 13
    /// Camera position that frames the thumbnail canvas.
    nonisolated static var cameraPosition: SIMD3<Float> {
        let half = canvasHeightMetres / 2
        return [0, half - 0.004, half / tan(fieldOfView * .pi / 360)]
    }

    private func setUpRenderer() -> (RealityRenderer, Entity)? {
        if let renderer, let camera { return (renderer, camera) }
        guard let renderer = try? RealityRenderer() else { return nil }
        renderer.cameraSettings.colorBackground = .color(UIColor.clear.cgColor)
        renderer.cameraSettings.antialiasing = .multisample4X
        if let env = studioEnvironment() {
            renderer.lighting.resource = env
            renderer.lighting.intensityExponent = 0
        }
        let camera = Entity()
        var lens = PerspectiveCameraComponent()
        lens.fieldOfViewInDegrees = Self.fieldOfView
        camera.components.set(lens)
        camera.position = Self.cameraPosition
        renderer.activeCamera = camera
        renderer.entities.append(camera)

        for light in Self.studioLights() { renderer.entities.append(light) }

        self.renderer = renderer
        self.camera = camera
        return (renderer, camera)
    }

    private var renderQueue: Task<Void, Never>?

    /// Renders one bottle at a time: the renderer is shared, so overlapping renders
    /// would draw each other's bottles.
    private func render(_ bottle: Entity, pixelHeight: Int) async -> UIImage? {
        let previous = renderQueue
        let job = Task { @MainActor in
            await previous?.value
            return await renderNow(bottle, pixelHeight: pixelHeight)
        }
        renderQueue = Task { _ = await job.value }
        return await job.value
    }

    private func renderNow(_ bottle: Entity, pixelHeight: Int) async -> UIImage? {
        guard let device, let queue, let (renderer, _) = setUpRenderer() else { return nil }
        let width = Int((CGFloat(pixelHeight) * Self.canvasAspect).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: pixelHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let output = try? RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture)) else { return nil }

        renderer.entities.append(bottle)
        defer { renderer.entities.remove(bottle) }
        let rendered: Bool = await withCheckedContinuation { continuation in
            do {
                try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in
                    continuation.resume(returning: true)
                })
            } catch {
                continuation.resume(returning: false)
            }
        }
        guard rendered else { return nil }
        return await Self.readBack(texture, queue: queue)
    }

    /// Copies a private GPU texture into a CGImage (premultiplied BGRA).
    nonisolated private static func readBack(_ texture: MTLTexture, queue: MTLCommandQueue) async -> UIImage? {
        let width = texture.width, height = texture.height, rowBytes = width * 4
        guard let buffer = queue.device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        let data = Data(bytes: buffer.contents(), count: rowBytes * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                               space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg, scale: 3, orientation: .up)
    }

    // MARK: - Studio lighting

    /// Key light from front-left for the label, a cool rim from behind-right so dark
    /// glass separates from a dark wall, and a soft fill.
    static func studioLights() -> [Entity] {
        [(intensity: Float(5200), color: UIColor(hex: 0xFFF0DC), from: SIMD3<Float>(-0.7, 0.8, 1.1)),
         (intensity: Float(4200), color: UIColor(hex: 0xFFE2C0), from: SIMD3<Float>(0.9, 0.6, -0.8)),
         (intensity: Float(1400), color: UIColor(hex: 0xFFF6EA), from: SIMD3<Float>(0.9, 0.2, 1.0))]
            .map { spec in
                let entity = Entity()
                var light = DirectionalLightComponent()
                light.intensity = spec.intensity
                light.color = spec.color
                entity.components.set(light)
                entity.look(at: [0, 0.15, 0], from: spec.from, relativeTo: nil)
                return entity
            }
    }

    /// HDR equirectangular studio: softboxes ~40× brighter than the room so glass
    /// shows crisp highlights, like product photography.
    private static func studioImage() -> CGImage? {
        let width = 1024, height = 512
        var pixels = [Float](repeating: 0, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ rgb: SIMD3<Float>) {
            let i = (y * width + x) * 4
            pixels[i] = rgb.x; pixels[i + 1] = rgb.y; pixels[i + 2] = rgb.z; pixels[i + 3] = 1
        }
        for y in 0..<height {
            let v = Float(y) / Float(height)
            // Warm dim room, brighter ceiling, warm floor bounce.
            var base = SIMD3<Float>(0.02, 0.016, 0.014)
            if v < 0.3 { base += SIMD3<Float>(0.5, 0.48, 0.45) * pow(1 - v / 0.3, 2) }
            if v > 0.6 { base += SIMD3<Float>(0.12, 0.07, 0.04) * ((v - 0.6) / 0.4) }
            for x in 0..<width { set(x, y, base) }
        }
        for strip in studioStrips {
            let cx = Int(strip.u * Float(width)), half = strip.halfWidth
            for y in Int(0.16 * Float(height))..<Int(0.68 * Float(height)) {
                for x in (cx - half)...(cx + half) {
                    let edge = 1 - abs(Float(x - cx)) / Float(half + 1)
                    set((x + width) % width, y, SIMD3<Float>(1, 0.95, 0.88) * strip.power * min(1, edge * 3))
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let studioStrips: [(u: Float, halfWidth: Int, power: Float)] = [
        (0.0625, 5, 30), (0.5625, 16, 30),
    ]
}
