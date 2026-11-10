@preconcurrency import SceneKit
import UIKit

/// Owns the SceneKit cellar: environment, racks, bottles, camera rig and all
/// gesture handling. SwiftUI talks to it through `CellarSceneView`.
@MainActor
final class CellarSceneController: NSObject, UIGestureRecognizerDelegate {
    struct Callbacks {
        var onInspect: (UUID?) -> Void = { _ in }
        var onMove: (UUID, CellarLayout.Slot) -> Void = { _, _ in }
        var onBeginMove: (UUID) -> Void = { _ in }
    }

    let view: SCNView
    let scene = SCNScene()
    var callbacks = Callbacks()

    private let assets = CellarAssets.shared
    private let rackRoot = SCNNode()
    private let bottleRoot = SCNNode()
    private let slotMarkerRoot = SCNNode()
    private let cameraNode = SCNNode()
    private let focusVeil = SCNNode()
    private var bottleNodes: [UUID: SCNNode] = [:]
    private var bottleSignature: [UUID: String] = [:]
    private var labelTasks: [UUID: Task<Void, Never>] = [:]
    private var displayLink: CADisplayLink?

    private var layout: CellarLayout?
    private var finish: ShelfFinish?
    private var builtBays = 0
    private var hasFramedContent = false
    /// False until the first set of bottles has been placed (they cascade in).
    private var hasPopulated = false
    /// Until this time the camera eases more slowly, for the opening glide.
    private var introUntil = Date.distantPast

    // Camera rig state (targets are smoothed toward each frame).
    private var yaw: Float = 0, pitch: Float = 0.06, distance: Float = 2.6
    private var target = SIMD3<Float>(0, 1.0, 0)
    private var currentYaw: Float = 0, currentPitch: Float = 0.08, currentDistance: Float = 3.4
    private var currentTarget = SIMD3<Float>(0, 1.0, 0)
    // Drag-to-browse: one finger slides the camera across the wall, then coasts.
    private var isDragging = false
    /// World-space metres/second of the finger while dragging, or of the coast after release.
    private var velocity = SIMD2<Float>(0, 0)
    private var snapAfterCoast = false
    private var lastStep = CACurrentMediaTime()
    private static let restingPitch: Float = 0.06

    // Inspection / move state
    private(set) var inspectedID: UUID?
    private var inspectedHome: (position: SCNVector3, orientation: SCNQuaternion)?
    private(set) var movingID: UUID?
    private var userTurnedInspected = false
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    override init() {
        view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        super.init()
        configureView()
        buildEnvironment()
        installGestures()
    }

    // MARK: - Setup

    private func configureView() {
        view.scene = scene
        view.backgroundColor = UIColor(hex: 0x0E0B0A)
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.isPlaying = true
        // Camera smoothing runs on the main thread (SceneKit's renderer delegate runs on its render thread).
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        view.accessibilityLabel = "3D wine cellar"
        view.isAccessibilityElement = false
    }

    private func buildEnvironment() {
        scene.lightingEnvironment.contents = CellarTextures.environment()
        scene.lightingEnvironment.intensity = 1.1
        scene.background.contents = UIColor(hex: 0x0E0B0A)
        scene.fogStartDistance = 5
        scene.fogEndDistance = 12
        scene.fogColor = UIColor(hex: 0x0E0B0A)

        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.zNear = 0.05
        camera.zFar = 30
        camera.wantsHDR = true
        camera.bloomIntensity = 0.2
        camera.bloomThreshold = 1.2
        camera.vignettingIntensity = 0.9
        camera.vignettingPower = 1.1
        camera.contrast = 0.12
        camera.saturation = 1.05
        camera.screenSpaceAmbientOcclusionIntensity = 0.7
        camera.screenSpaceAmbientOcclusionRadius = 0.12
        camera.exposureOffset = -0.35
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        // Dim veil that sits behind an inspected bottle for focus.
        let veil = SCNPlane(width: 6, height: 6)
        let veilMaterial = SCNMaterial()
        veilMaterial.diffuse.contents = UIColor.black
        veilMaterial.lightingModel = .constant
        veilMaterial.writesToDepthBuffer = false
        veil.materials = [veilMaterial]
        focusVeil.geometry = veil
        focusVeil.position = SCNVector3(0, 0, -0.9)
        focusVeil.opacity = 0
        focusVeil.renderingOrder = 10
        cameraNode.addChildNode(focusVeil)

        // Warm key light with soft shadows.
        let key = SCNLight()
        key.type = .spot
        key.intensity = 820
        key.temperature = 3800
        key.spotInnerAngle = 30
        key.spotOuterAngle = 75
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowSampleCount = 8
        key.shadowRadius = 6
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowColor = UIColor.black.withAlphaComponent(0.6)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(0.6, 3.2, 2.6)
        keyNode.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(keyNode)

        // Cool rim light from behind and above: separates the bottles from the rack.
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 420
        rim.temperature = 5200
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(-1.5, 3, -1.5)
        rimNode.look(at: SCNVector3(0, 0.8, 0.3))
        scene.rootNode.addChildNode(rimNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 60
        fill.temperature = 3000
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        // Floor and back wall.
        let floor = SCNFloor()
        floor.reflectivity = 0.08
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .physicallyBased
        floorMaterial.diffuse.contents = CellarTextures.floor()
        floorMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(4, 4, 1)
        floorMaterial.diffuse.wrapS = .repeat
        floorMaterial.diffuse.wrapT = .repeat
        floorMaterial.roughness.contents = 0.8
        floor.materials = [floorMaterial]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        let wall = SCNPlane(width: 14, height: 5)
        let wallMaterial = SCNMaterial()
        wallMaterial.lightingModel = .physicallyBased
        wallMaterial.diffuse.contents = CellarTextures.plaster()
        wallMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(5, 2, 1)
        wallMaterial.diffuse.wrapS = .repeat
        wallMaterial.diffuse.wrapT = .repeat
        wallMaterial.roughness.contents = 0.95
        wallMaterial.diffuse.intensity = 0.9
        wall.materials = [wallMaterial]
        let wallNode = SCNNode(geometry: wall)
        // Shelves are wall-mounted, so the wall sits right behind their back edge.
        wallNode.position = SCNVector3(0, 2.5, -Float(CellarAssets.Dim.shelfDepth) / 2 - 0.004)
        scene.rootNode.addChildNode(wallNode)

        scene.rootNode.addChildNode(rackRoot)
        scene.rootNode.addChildNode(bottleRoot)
        scene.rootNode.addChildNode(slotMarkerRoot)
        applyCamera(immediate: true)
    }

    // MARK: - Content updates

    /// Applies the latest bottles + layout. Only changed bottles are rebuilt.
    func update(bottles: [CellarBottle], layout: CellarLayout, finish: ShelfFinish, dimmed: Set<UUID>) {
        let rackChanged = layout.bayCount != builtBays || finish != self.finish
        self.layout = layout
        if rackChanged {
            self.finish = finish
            buildRacks(bays: layout.bayCount, finish: finish)
        }

        let byID = Dictionary(uniqueKeysWithValues: bottles.map { ($0.id, $0) })
        for (id, node) in bottleNodes where layout.slots[id] == nil || byID[id] == nil {
            bottleNodes[id] = nil
            bottleSignature[id] = nil
            labelTasks[id]?.cancel()
            animateRemoval(node)
        }
        // Top shelf first, left to right, so the opening cascade reads naturally.
        let ordered = layout.slots.sorted { a, b in
            (a.value.shelfInBay, a.value.bay, a.value.slot) < (b.value.shelfInBay, b.value.bay, b.value.slot)
        }
        let cascading = !hasPopulated && !ordered.isEmpty
        for (index, (id, slot)) in ordered.enumerated() {
            guard let bottle = byID[id] else { continue }
            let signature = "\(bottle.wine.id)|\(bottle.wine.labelImagePath ?? "")"
            let destination = position(for: slot)
            let node: SCNNode
            if let existing = bottleNodes[id], bottleSignature[id] == signature {
                node = existing
            } else {
                let replaced = bottleNodes[id]
                node = makeBottleNode(bottle)
                bottleNodes[id] = node
                bottleSignature[id] = signature
                bottleRoot.addChildNode(node)
                if let replaced {
                    // Same bottle, new look (e.g. label photo arrived): swap in place.
                    node.position = replaced.position
                    node.orientation = replaced.orientation
                    replaced.removeFromParentNode()
                } else {
                    node.position = destination
                    if !reduceMotion {
                        animateEntrance(node, delay: cascading ? min(Double(index) * 0.035, 1.1) + 0.15 : 0,
                                        dramatic: !cascading)
                    }
                }
            }
            if id != inspectedID, id != movingID, node.action(forKey: "enter") == nil {
                if node.position.distance(to: destination) > 0.001 {
                    if !reduceMotion, node.opacity > 0 {
                        animateArc(node, to: destination)
                    } else {
                        node.position = destination
                    }
                }
            }
            let targetOpacity: CGFloat = dimmed.contains(id) ? 0.12 : 1
            if node.opacity != targetOpacity {
                node.runAction(.fadeOpacity(to: targetOpacity, duration: 0.25))
            }
        }
        if !ordered.isEmpty { hasPopulated = true }
        updateSlotMarkers()
        if !hasFramedContent, !layout.slots.isEmpty {
            hasFramedContent = true
            frameOccupiedShelves(layout)
            if !reduceMotion {
                // Open slightly wide and high, then glide in.
                currentDistance = distance + 1.1
                currentPitch = pitch + 0.18
                currentYaw = yaw - 0.22
                introUntil = Date().addingTimeInterval(1.6)
            }
        }
        view.setNeedsDisplay()
    }

    // MARK: - Bottle motion

    /// Drops a bottle onto its shelf: falls in, lands with a small bounce and wobble.
    private func animateEntrance(_ node: SCNNode, delay: TimeInterval, dramatic: Bool) {
        let home = node.position
        let lift: Float = dramatic ? 0.42 : 0.22
        node.position = SCNVector3(home.x, home.y + lift, home.z + 0.06)
        node.opacity = 0
        let fall = SCNAction.move(to: SCNVector3(home.x, home.y, home.z), duration: dramatic ? 0.5 : 0.42)
        fall.timingMode = .easeIn
        let land = SCNAction.sequence([
            .moveBy(x: 0, y: 0.014, z: 0, duration: 0.09),
            .moveBy(x: 0, y: -0.014, z: 0, duration: 0.1),
        ])
        land.timingMode = .easeOut
        let tilt = CGFloat(Int.random(in: 0...1) == 0 ? 1 : -1) * 0.07
        let wobble = SCNAction.sequence([
            .rotateBy(x: 0, y: 0, z: tilt, duration: 0.08),
            .rotateBy(x: 0, y: 0, z: -tilt * 1.6, duration: 0.12),
            .rotateBy(x: 0, y: 0, z: tilt * 0.6, duration: 0.1),
        ])
        var steps: [SCNAction] = [
            .wait(duration: delay),
            .group([fall, .fadeIn(duration: 0.22)]),
            .group([land, wobble]),
        ]
        if dramatic {
            // A newly added bottle gets a little "here I am" pop.
            let pop = SCNAction.sequence([.scale(to: 1.08, duration: 0.14), .scale(to: 1, duration: 0.2)])
            pop.timingMode = .easeInEaseOut
            steps.append(pop)
            steps.append(.run { _ in
                Task { @MainActor in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            })
        }
        node.runAction(.sequence(steps), forKey: "enter")
        wake()
    }

    /// Moves a bottle to a new slot along a lifted arc, leaning into the move.
    private func animateArc(_ node: SCNNode, to destination: SCNVector3) {
        node.removeAction(forKey: "arc")
        let start = node.simdPosition
        let end = SIMD3<Float>(destination.x, destination.y, destination.z)
        let travel = simd_length(end - start)
        let duration = TimeInterval(min(0.75, 0.35 + travel * 0.25))
        let height = min(0.12, 0.04 + travel * 0.06)
        let lean = (end.x - start.x) > 0 ? -0.12 : 0.12
        let baseZ = node.eulerAngles.z
        let arc = SCNAction.customAction(duration: duration) { n, elapsed in
            let t = Float(min(1, elapsed / CGFloat(duration)))
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            var p = start + (end - start) * e
            p.y += sin(t * .pi) * height
            p.z += sin(t * .pi) * 0.05
            n.simdPosition = p
            n.eulerAngles.z = baseZ + Float(lean) * sin(t * .pi)
        }
        node.runAction(arc, forKey: "arc")
        wake()
    }

    /// Lifts a removed bottle off the shelf and fades it away.
    private func animateRemoval(_ node: SCNNode) {
        guard !reduceMotion else {
            node.removeFromParentNode()
            return
        }
        node.removeAllActions()
        let out = SCNAction.group([
            .moveBy(x: 0, y: 0.12, z: 0.08, duration: 0.3),
            .fadeOut(duration: 0.3),
            .scale(to: 0.85, duration: 0.3),
        ])
        out.timingMode = .easeIn
        node.runAction(.sequence([out, .removeFromParentNode()]))
        wake()
    }

    /// Points the camera at the shelves that actually hold bottles.
    /// Opens close enough to read labels: frames the bottles you own (at least
    /// `minimumFramedSlots` wide), not the whole wall. Dragging reaches the rest.
    private func frameOccupiedShelves(_ layout: CellarLayout) {
        let points = layout.slots.values.map { position(for: $0) }
        guard let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max() else { return }
        let D = CellarAssets.Dim.self
        let halfWidth = max(maxX - minX + D.slotSpacing, D.slotSpacing * Self.minimumFramedSlots) / 2 + 0.06
        let halfHeight = (maxY - minY) / 2 + 0.3
        let fit = max(fitDistance(halfWidth: halfWidth), halfHeight / tan(verticalHalfFOV))
        distance = min(fit, widthFitDistance())
        target = SIMD3<Float>((minX + maxX) / 2, (minY + maxY) / 2 + 0.14, 0)
        clampTarget()
        wake()
    }

    private static let minimumFramedSlots: Float = 4.2
    private var verticalHalfFOV: Float { Float(cameraNode.camera?.fieldOfView ?? 42) * .pi / 360 }

    /// Camera distance at which `halfWidth` metres either side of centre fill the view.
    private func fitDistance(halfWidth: Float) -> Float {
        let size = view.bounds.size
        let aspect = size.width > 0 && size.height > 0 ? Float(size.width / size.height) : 0.46
        return halfWidth / (tan(verticalHalfFOV) * aspect)
    }

    /// Distance at which one whole bay, side panels included, fits the view's width.
    /// `fieldOfView` is vertical, so a tall phone viewport crops the sides unless we back off.
    private func widthFitDistance() -> Float {
        let D = CellarAssets.Dim.self
        return max(2.4, fitDistance(halfWidth: D.bayWidth / 2 + 0.06))
    }

    /// Floating, wall-mounted shelves: a slim slab per shelf, no cabinet. Each shelf
    /// has an LED strip along its back edge that washes warm light up the wall
    /// behind the bottles, so they read as silhouettes against a glow.
    private func buildRacks(bays: Int, finish: ShelfFinish) {
        rackRoot.childNodes.forEach { $0.removeFromParentNode() }
        let wood = assets.wood(finish)
        let D = CellarAssets.Dim.self
        let totalWidth = Float(bays) * D.bayStride
        let slab: Float = 0.032

        let strip = SCNBox(width: CGFloat(D.bayWidth - 0.03), height: 0.004, length: 0.006, chamferRadius: 0)
        let stripMaterial = SCNMaterial()
        stripMaterial.lightingModel = .constant
        stripMaterial.diffuse.contents = UIColor(hex: 0xFFC67A)
        stripMaterial.emission.contents = UIColor(hex: 0xFFC67A)
        stripMaterial.emission.intensity = 1.6
        strip.materials = [stripMaterial]

        let washHeight: Float = 0.30
        let wash = SCNPlane(width: CGFloat(D.bayWidth), height: CGFloat(washHeight))
        let washMaterial = SCNMaterial()
        washMaterial.lightingModel = .constant
        washMaterial.diffuse.contents = CellarTextures.wallWash()
        washMaterial.blendMode = .add
        washMaterial.writesToDepthBuffer = false
        wash.materials = [washMaterial]

        for bay in 0..<bays {
            let bayNode = SCNNode()
            for shelf in 0..<CellarLayout.shelvesPerBay {
                let y = shelfY(shelfInBay: shelf)
                let board = SCNBox(width: CGFloat(D.bayWidth), height: CGFloat(slab), length: CGFloat(D.shelfDepth), chamferRadius: 0.006)
                board.materials = [wood]
                let boardNode = SCNNode(geometry: board)
                boardNode.position = SCNVector3(0, y - slab / 2, 0)
                bayNode.addChildNode(boardNode)
            }
            let flattened = bayNode.flattenedClone()
            flattened.position = SCNVector3(Float(bay) * D.bayStride - totalWidth / 2 + D.bayStride / 2, 0, 0)
            for shelf in 0..<CellarLayout.shelvesPerBay {
                let y = shelfY(shelfInBay: shelf)
                let stripNode = SCNNode(geometry: strip)
                stripNode.position = SCNVector3(0, y + 0.002, -D.shelfDepth / 2 + 0.008)
                flattened.addChildNode(stripNode)
                let washNode = SCNNode(geometry: wash)
                washNode.position = SCNVector3(0, y + washHeight / 2, -D.shelfDepth / 2 - 0.002)
                washNode.castsShadow = false
                flattened.addChildNode(washNode)
            }
            rackRoot.addChildNode(flattened)
        }
        builtBays = bays
        clampTarget()
    }

    private func shelfY(shelfInBay: Int) -> Float {
        let D = CellarAssets.Dim.self
        return D.baseHeight + Float(CellarLayout.shelvesPerBay - 1 - shelfInBay) * D.shelfSpacing + D.boardThickness
    }

    private func position(for slot: CellarLayout.Slot) -> SCNVector3 {
        let D = CellarAssets.Dim.self
        let totalWidth = Float(builtBays) * D.bayStride
        let bayX = Float(slot.bay) * D.bayStride - totalWidth / 2 + D.bayStride / 2
        let x = bayX - D.bayWidth / 2 + 0.025 + D.slotSpacing * (Float(slot.slot) + 0.5)
        return SCNVector3(x, shelfY(shelfInBay: slot.shelfInBay), 0.02)
    }

    private func makeBottleNode(_ bottle: CellarBottle) -> SCNNode {
        let wine = bottle.wine
        let style = BottleStyle(type: wine.type, grapes: wine.grapes)
        let node = SCNNode()
        node.name = "bottle:\(bottle.id.uuidString)"

        let body = SCNNode(geometry: shallowCopy(assets.bodyGeometry(style), materials: [assets.glass(for: wine.type)]))
        body.castsShadow = true
        node.addChildNode(body)

        let labelMaterial = assets.labelMaterial(image: nil)
        let label = SCNNode(geometry: shallowCopy(assets.labelGeometry(style), materials: [labelMaterial]))
        node.addChildNode(label)

        let (capsuleGeometry, capsuleMaterial) = assets.capsule(for: wine.type)
        let capsule = SCNNode(geometry: shallowCopy(capsuleGeometry, materials: [capsuleMaterial]))
        let capsuleHeight = Float((capsuleGeometry as? SCNCylinder)?.height ?? 0.07)
        capsule.position = SCNVector3(0, 0.302 - capsuleHeight / 2, 0)
        node.addChildNode(capsule)

        if bottle.quantity > 1 {
            node.addChildNode(quantityTag(bottle.quantity))
        }
        loadLabel(for: bottle, into: labelMaterial)
        return node
    }

    private func shallowCopy(_ geometry: SCNGeometry, materials: [SCNMaterial]) -> SCNGeometry {
        // `copy()` shares vertex/index buffers; only the materials array differs.
        let copy = (geometry.copy() as? SCNGeometry) ?? geometry
        copy.materials = materials
        return copy
    }

    private func quantityTag(_ quantity: Int) -> SCNNode {
        let text = SCNText(string: "×\(quantity)", extrusionDepth: 0.5)
        text.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        text.flatness = 0.2
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(hex: 0xE8C98E)
        text.materials = [m]
        let node = SCNNode(geometry: text)
        node.scale = SCNVector3(0.0022, 0.0022, 0.0022)
        let (minB, maxB) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x) / 2 + minB.x, 0, 0)
        // Stands on the shelf just in front of the bottle (below 0 it sinks into the board).
        node.position = SCNVector3(0, 0.004, 0.07)
        return node
    }

    /// Label textures load asynchronously: generated art off the main thread,
    /// or the scanned photo via the shared image cache.
    private func loadLabel(for bottle: CellarBottle, into material: SCNMaterial) {
        labelTasks[bottle.id]?.cancel()
        let wine = bottle.wine
        labelTasks[bottle.id] = Task { [weak self] in
            var image: UIImage?
            if let path = wine.labelImagePath {
                image = await ImageLoader.shared.image(for: path, maxPixel: 512)
            }
            if image == nil {
                image = await Task.detached(priority: .utility) { LabelArtRenderer.image(for: wine) }.value
            }
            guard !Task.isCancelled else { return }
            material.diffuse.contents = image
            material.emission.contents = image
            self?.view.setNeedsDisplay()
        }
    }

    // MARK: - Camera

    private func applyCamera(immediate: Bool = false) {
        if immediate {
            currentYaw = yaw; currentPitch = pitch; currentDistance = distance; currentTarget = target
        }
        let offset = SIMD3<Float>(
            sin(currentYaw) * cos(currentPitch),
            sin(currentPitch),
            cos(currentYaw) * cos(currentPitch)
        ) * currentDistance
        let eye = currentTarget + offset
        cameraNode.simdPosition = eye
        cameraNode.simdLook(at: currentTarget)
    }

    /// Half the visible wall at the current zoom, in metres.
    private func visibleHalfExtents() -> SIMD2<Float> {
        let size = view.bounds.size
        let aspect = size.width > 0 && size.height > 0 ? Float(size.width / size.height) : 0.46
        let halfH = distance * tan(Float(cameraNode.camera?.fieldOfView ?? 42) * .pi / 360)
        return SIMD2(halfH * aspect, halfH)
    }

    /// Where the camera may look so the view stays on the shelves. When the whole
    /// wall fits on an axis, that axis is pinned to the centre.
    private func panBounds() -> (x: ClosedRange<Float>, y: ClosedRange<Float>) {
        let D = CellarAssets.Dim.self
        let half = visibleHalfExtents()
        let halfWall = Float(max(1, builtBays)) * D.bayStride / 2
        let xr = max(0, halfWall - half.x + 0.06)
        let bottom: Float = 0.05, top = D.bayHeight + 0.05
        var lo = bottom + half.y * 0.85, hi = top - half.y * 0.85
        if lo > hi { let mid = (bottom + top) / 2; lo = mid; hi = mid }
        return (-xr...xr, lo...hi)
    }

    private func clampTarget() {
        distance = min(max(distance, 0.55), max(4.8, widthFitDistance() * 1.2))
        let b = panBounds()
        target.x = min(max(target.x, b.x.lowerBound), b.x.upperBound)
        target.y = min(max(target.y, b.y.lowerBound), b.y.upperBound)
        yaw = min(max(yaw, -0.75), 0.75)
        pitch = min(max(pitch, -0.3), 0.45)
    }

    func resetCamera() {
        velocity = .zero
        yaw = 0; pitch = Self.restingPitch
        if let layout, !layout.slots.isEmpty {
            frameOccupiedShelves(layout)
        } else {
            distance = widthFitDistance()
            target = SIMD3<Float>(0, 1.0, 0)
            clampTarget()
            wake()
        }
    }

    @objc private func tick() {
        step()
    }

    /// Per-frame: coast with momentum, ease back inside the wall's edges, and lean
    /// the camera slightly into the direction of travel for a sense of depth.
    private func step() {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastStep, 1.0 / 30))
        lastStep = now
        let k: Float = Date() < introUntil ? 0.045 : 0.14

        if !isDragging, inspectedID == nil {
            let b = panBounds()
            let outside = !b.x.contains(target.x) || !b.y.contains(target.y)
            if simd_length(velocity) > 0.01 {
                target.x += velocity.x * dt
                target.y += velocity.y * dt
                // Friction; much stronger past an edge so it stops and springs back.
                velocity *= pow(outside ? 0.72 : 0.935, dt * 60)
            } else {
                velocity = .zero
                if snapAfterCoast { snapAfterCoast = false; snapToBay() }
                if outside { clampTarget() }
            }
        }

        let motion = inspectedID == nil ? velocity : .zero
        let leanYaw = min(max(-motion.x * 0.05, -0.12), 0.12)
        let leanPitch = min(max(-motion.y * 0.035, -0.07), 0.07)
        // While a finger is down the view tracks it 1:1; easing would feel like lag.
        let kt: Float = isDragging ? 1 : k
        currentYaw += (yaw + leanYaw - currentYaw) * k
        currentPitch += (pitch + leanPitch - currentPitch) * k
        currentDistance += (distance - currentDistance) * k
        currentTarget += (target - currentTarget) * kt
        applyCamera()
        let settled = !isDragging && velocity == .zero
            && abs(yaw - currentYaw) < 0.0005 && abs(distance - currentDistance) < 0.0005
            && simd_length(target - currentTarget) < 0.0005 && abs(pitch - currentPitch) < 0.0005
        if settled && inspectedID == nil && movingID == nil {
            view.rendersContinuously = false
            displayLink?.isPaused = true
        }
    }

    /// With several bays and the camera zoomed out to about one bay, come to rest
    /// centred on a bay instead of straddling two.
    private func snapToBay() {
        guard builtBays > 1, distance < widthFitDistance() * 1.25 else { return }
        let stride = CellarAssets.Dim.bayStride
        let first = -Float(builtBays) * stride / 2 + stride / 2
        let index = min(max(((target.x - first) / stride).rounded(), 0), Float(builtBays - 1))
        target.x = first + index * stride
        clampTarget()
    }

    private func wake() {
        lastStep = CACurrentMediaTime()
        view.rendersContinuously = true
        displayLink?.isPaused = false
    }

    // MARK: - Gestures

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        for g in [pan, pinch, tap, doubleTap, longPress] as [UIGestureRecognizer] {
            g.delegate = self
            view.addGestureRecognizer(g)
        }
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (other is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        wake()
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        if let id = inspectedID, let node = bottleNodes[id] {
            userTurnedInspected = true
            node.removeAction(forKey: "spin")
            // Rotate the inspected bottle.
            node.eulerAngles.y += Float(t.x) * 0.012
            node.eulerAngles.x = min(max(node.eulerAngles.x + Float(t.y) * 0.006, -0.5), 0.5)
            return
        }
        // Metres of wall per screen point at the current zoom, so the shelf under
        // the finger stays under the finger.
        let perPoint = visibleHalfExtents().y * 2 / Float(max(view.bounds.height, 1))
        let v = g.velocity(in: view)
        let fingerVelocity = SIMD2(-Float(v.x), Float(v.y)) * perPoint
        switch g.state {
        case .began:
            isDragging = true
            snapAfterCoast = false
            velocity = .zero
        case .changed:
            var dx = -Float(t.x) * perPoint, dy = Float(t.y) * perPoint
            let b = panBounds()
            // Rubber band past the edges.
            if (target.x <= b.x.lowerBound && dx < 0) || (target.x >= b.x.upperBound && dx > 0) { dx *= 0.3 }
            if (target.y <= b.y.lowerBound && dy < 0) || (target.y >= b.y.upperBound && dy > 0) { dy *= 0.3 }
            target.x += dx
            target.y += dy
            velocity = fingerVelocity
        default:
            isDragging = false
            let speed = simd_length(fingerVelocity)
            velocity = speed > 6 ? fingerVelocity / speed * 6 : fingerVelocity
            snapAfterCoast = true
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        wake()
        if let id = inspectedID, let node = bottleNodes[id] {
            let s = min(max(Float(node.scale.x) * Float(g.scale), 0.8), 1.8)
            node.scale = SCNVector3(s, s, s)
        } else {
            distance /= Float(g.scale)
            velocity = .zero
            clampTarget()
        }
        g.scale = 1
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard inspectedID == nil else { return }
        wake()
        resetCamera()
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        wake()
        let point = g.location(in: view)
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])

        if let moving = movingID {
            if let marker = hits.first(where: { $0.node.name?.hasPrefix("slot:") == true })?.node.name,
               let slot = Self.parseSlot(marker) {
                callbacks.onMove(moving, slot)
            } else if let other = hits.lazy.compactMap({ self.bottleID(for: $0.node) }).first(where: { $0 != moving }),
                      let slot = layout?.slots[other] {
                callbacks.onMove(moving, slot)
            }
            endMove()
            return
        }

        if inspectedID != nil {
            if let hit = hits.lazy.compactMap({ self.bottleID(for: $0.node) }).first, hit == inspectedID { return }
            endInspection()
            return
        }

        if let id = hits.lazy.compactMap({ self.bottleID(for: $0.node) }).first,
           let node = bottleNodes[id], node.opacity > 0.5 {
            inspect(id)
        }
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, inspectedID == nil else { return }
        let hits = view.hitTest(g.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        guard let id = hits.lazy.compactMap({ self.bottleID(for: $0.node) }).first else { return }
        beginMove(id)
        callbacks.onBeginMove(id)
    }

    private func bottleID(for node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, name.hasPrefix("bottle:") { return UUID(uuidString: String(name.dropFirst(7))) }
            current = n.parent
        }
        return nil
    }

    // MARK: - Inspection

    /// Where an inspected bottle sits, in camera space (base of the bottle).
    private static let inspectionPoint = SIMD3<Float>(0, 0.08, -1.15)
    private static let minimumInspectionDistance: Float = 1.75

    func inspect(_ id: UUID) {
        guard let node = bottleNodes[id], inspectedID == nil else { return }
        wake()
        inspectedID = id
        userTurnedInspected = false
        if node.action(forKey: "enter") != nil || node.action(forKey: "arc") != nil {
            // Tapped mid-animation: settle it first so it returns to the right spot.
            node.removeAllActions()
            node.opacity = 1
            node.scale = SCNVector3(1, 1, 1)
            node.eulerAngles.z = 0
            if let slot = layout?.slots[id] { node.position = position(for: slot) }
        }
        inspectedHome = (node.position, node.orientation)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // The bottle floats ~1.15 m in front of the camera; keep the camera far enough
        // back that this point is in front of the rack, not inside it.
        distance = max(distance, Self.minimumInspectionDistance)
        if let slot = layout?.slots[id] {
            target.y = position(for: slot).y + 0.1
            target.x = position(for: slot).x
        }

        // Slide forward off the shelf, then hand the bottle to the camera so it
        // stays framed even while the camera rig is still easing into place.
        let pullOut = SCNAction.move(by: SCNVector3(0, 0.03, 0.2), duration: reduceMotion ? 0.01 : 0.25)
        pullOut.timingMode = .easeOut
        node.renderingOrder = 20
        // Completion handlers run on SceneKit's thread: hop to main and look the node up by id.
        node.runAction(pullOut) { [weak self] in
            Task { @MainActor in
                guard let self, let node = self.bottleNodes[id] else { return }
                self.attachToCamera(node)
            }
        }
        focusVeil.runAction(.fadeOpacity(to: 0.6, duration: 0.4))
        callbacks.onInspect(id)
    }

    private func attachToCamera(_ node: SCNNode) {
        guard inspectedID != nil else { return }
        let world = node.simdWorldTransform
        node.removeFromParentNode()
        cameraNode.addChildNode(node)
        node.simdWorldTransform = world
        let duration: TimeInterval = reduceMotion ? 0.01 : 0.55
        let fly = SCNAction.move(to: SCNVector3(Self.inspectionPoint), duration: duration)
        fly.timingMode = .easeInEaseOut
        // Identity orientation in camera space = label facing the viewer.
        let turn = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: duration, usesShortestUnitArc: true)
        // Once it arrives, turn slowly on its own until you touch it.
        let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16))
        node.runAction(.sequence([.group([fly, turn]), .wait(duration: reduceMotion ? 0 : 1.2)])) { [weak self] in
            Task { @MainActor in
                guard let self, !self.reduceMotion, let id = self.inspectedID, let node = self.bottleNodes[id],
                      node.action(forKey: "spin") == nil, !self.userTurnedInspected else { return }
                node.runAction(spin, forKey: "spin")
            }
        }
    }

    func endInspection() {
        guard let id = inspectedID, let node = bottleNodes[id], let home = inspectedHome else {
            inspectedID = nil
            return
        }
        wake()
        node.removeAllActions()
        // Return the bottle to rack space, preserving where it currently appears.
        let world = node.simdWorldTransform
        node.removeFromParentNode()
        bottleRoot.addChildNode(node)
        node.simdWorldTransform = world

        let homeOrientation = simd_quatf(ix: home.orientation.x, iy: home.orientation.y, iz: home.orientation.z, r: home.orientation.w)
        let startOrientation = node.simdOrientation
        let startScale = node.simdScale
        let duration: TimeInterval = reduceMotion ? 0.01 : 0.5
        let back = SCNAction.group([
            SCNAction.move(to: home.position, duration: duration),
            SCNAction.customAction(duration: duration) { n, elapsed in
                let t = min(1, Float(elapsed / CGFloat(duration)))
                n.simdOrientation = simd_slerp(startOrientation, homeOrientation, t)
                n.simdScale = startScale + (SIMD3<Float>(repeating: 1) - startScale) * t
            },
        ])
        back.timingMode = .easeInEaseOut
        node.runAction(back) { [weak self] in
            Task { @MainActor in
                guard let node = self?.bottleNodes[id], self?.inspectedID != id else { return }
                node.orientation = home.orientation
                node.scale = SCNVector3(1, 1, 1)
                node.renderingOrder = 0
            }
        }
        focusVeil.runAction(.fadeOpacity(to: 0, duration: 0.35))
        inspectedID = nil
        inspectedHome = nil
        callbacks.onInspect(nil)
    }

    // MARK: - Reorganising

    func beginMove(_ id: UUID) {
        guard let node = bottleNodes[id] else { return }
        wake()
        movingID = id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        node.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.03, z: 0, duration: 0.4), .moveBy(x: 0, y: -0.03, z: 0, duration: 0.4)])), forKey: "hover")
        updateSlotMarkers()
    }

    func endMove() {
        if let id = movingID, let node = bottleNodes[id] {
            node.removeAction(forKey: "hover")
            if let slot = layout?.slots[id] { node.runAction(.move(to: position(for: slot), duration: 0.2)) }
        }
        movingID = nil
        updateSlotMarkers()
    }

    private func updateSlotMarkers() {
        slotMarkerRoot.childNodes.forEach { $0.removeFromParentNode() }
        guard movingID != nil, let layout else { return }
        let occupied = Set(layout.slots.values)
        let marker = SCNCylinder(radius: 0.03, height: 0.004)
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = UIColor(hex: 0xE8C98E).withAlphaComponent(0.7)
        glow.emission.contents = UIColor(hex: 0xE8C98E)
        marker.materials = [glow]
        for shelf in 0..<layout.shelfCount {
            for slotIndex in 0..<CellarLayout.slotsPerShelf {
                let slot = CellarLayout.Slot(shelf: shelf, slot: slotIndex)
                guard !occupied.contains(slot) else { continue }
                let node = SCNNode(geometry: marker)
                node.name = "slot:\(shelf):\(slotIndex)"
                var p = position(for: slot)
                p.y += 0.004
                node.position = p
                node.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.35, duration: 0.6), .fadeOpacity(to: 1, duration: 0.6)])))
                slotMarkerRoot.addChildNode(node)
            }
        }
    }

    private static func parseSlot(_ name: String) -> CellarLayout.Slot? {
        let parts = name.split(separator: ":")
        guard parts.count == 3, let shelf = Int(parts[1]), let slot = Int(parts[2]) else { return nil }
        return CellarLayout.Slot(shelf: shelf, slot: slot)
    }

    // MARK: - Utilities

    func focus(on id: UUID) {
        guard let node = bottleNodes[id] else { return }
        target = SIMD3<Float>(node.simdPosition.x, node.simdPosition.y + 0.15, 0)
        distance = Self.minimumInspectionDistance + 0.1
        yaw = 0
        pitch = 0.05
        clampTarget()
        wake()
    }

    func snapshot() -> UIImage {
        view.snapshot()
    }

    func teardown() {
        labelTasks.values.forEach { $0.cancel() }
        displayLink?.invalidate()
        displayLink = nil
        view.isPlaying = false
    }
}

private extension SCNVector3 {
    func distance(to other: SCNVector3) -> Float {
        simd_distance(SIMD3<Float>(x, y, z), SIMD3<Float>(other.x, other.y, other.z))
    }
}
