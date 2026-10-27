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

    // Camera rig state (targets are smoothed toward each frame).
    private var yaw: Float = 0, pitch: Float = 0.08, distance: Float = 2.6
    private var target = SIMD3<Float>(0, 1.0, 0)
    private var currentYaw: Float = 0, currentPitch: Float = 0.08, currentDistance: Float = 3.4
    private var currentTarget = SIMD3<Float>(0, 1.0, 0)
    private var lastInteraction = Date()
    private var startTime = Date()

    // Inspection / move state
    private(set) var inspectedID: UUID?
    private var inspectedHome: (position: SCNVector3, orientation: SCNQuaternion)?
    private(set) var movingID: UUID?
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
        scene.lightingEnvironment.intensity = 0.55
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
        camera.vignettingIntensity = 0.6
        camera.vignettingPower = 0.8
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
        key.intensity = 950
        key.temperature = 3200
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
        wallMaterial.diffuse.contents = CellarTextures.brick()
        wallMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(7, 2.5, 1)
        wallMaterial.diffuse.wrapS = .repeat
        wallMaterial.diffuse.wrapT = .repeat
        wallMaterial.roughness.contents = 0.95
        wallMaterial.diffuse.intensity = 0.45
        wall.materials = [wallMaterial]
        let wallNode = SCNNode(geometry: wall)
        wallNode.position = SCNVector3(0, 2.5, -Float(CellarAssets.Dim.shelfDepth) / 2 - 0.08)
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
            node.removeFromParentNode()
            bottleNodes[id] = nil
            bottleSignature[id] = nil
            labelTasks[id]?.cancel()
        }
        for (id, slot) in layout.slots {
            guard let bottle = byID[id] else { continue }
            let signature = "\(bottle.wine.id)|\(bottle.wine.labelImagePath ?? "")"
            let node: SCNNode
            if let existing = bottleNodes[id], bottleSignature[id] == signature {
                node = existing
            } else {
                bottleNodes[id]?.removeFromParentNode()
                node = makeBottleNode(bottle)
                bottleNodes[id] = node
                bottleSignature[id] = signature
                bottleRoot.addChildNode(node)
            }
            if id != inspectedID {
                let destination = position(for: slot)
                if node.position.distance(to: destination) > 0.001 {
                    if node.parent != nil, !reduceMotion, node.opacity > 0 {
                        let move = SCNAction.move(to: destination, duration: 0.45)
                        move.timingMode = .easeInEaseOut
                        node.runAction(move)
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
        updateSlotMarkers()
        if !hasFramedContent, !layout.slots.isEmpty {
            hasFramedContent = true
            frameOccupiedShelves(layout)
        }
        view.setNeedsDisplay()
    }

    /// Points the camera at the shelves that actually hold bottles.
    private func frameOccupiedShelves(_ layout: CellarLayout) {
        let ys = layout.slots.values.map { shelfY(shelfInBay: $0.shelfInBay) }
        guard let minY = ys.min(), let maxY = ys.max() else { return }
        target = SIMD3<Float>(0, (minY + maxY) / 2 - 0.05, 0)
        distance = max(2.4, (maxY - minY) * 1.6 + 1.8)
        clampTarget()
        wake()
    }

    private func buildRacks(bays: Int, finish: ShelfFinish) {
        rackRoot.childNodes.forEach { $0.removeFromParentNode() }
        let wood = assets.wood(finish)
        let D = CellarAssets.Dim.self
        let totalWidth = Float(bays) * D.bayStride
        for bay in 0..<bays {
            let bayNode = SCNNode()
            func box(_ w: Float, _ h: Float, _ d: Float, _ x: Float, _ y: Float, _ z: Float) {
                let b = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: 0.003)
                b.materials = [wood]
                let n = SCNNode(geometry: b)
                n.position = SCNVector3(x, y, z)
                bayNode.addChildNode(n)
            }
            let h = D.bayHeight
            // Side panels, plinth, crown and back.
            box(D.panelThickness, h, D.shelfDepth, -D.bayWidth / 2 - D.panelThickness / 2, h / 2, 0)
            box(D.panelThickness, h, D.shelfDepth, D.bayWidth / 2 + D.panelThickness / 2, h / 2, 0)
            box(D.bayWidth + D.panelThickness * 2 + 0.02, D.baseHeight, D.shelfDepth + 0.02, 0, D.baseHeight / 2, 0.005)
            box(D.bayWidth + D.panelThickness * 2 + 0.04, 0.05, D.shelfDepth + 0.04, 0, h + 0.025, 0.01)
            box(D.bayWidth, h - D.baseHeight, 0.012, 0, D.baseHeight + (h - D.baseHeight) / 2, -D.shelfDepth / 2 + 0.006)
            for shelf in 0..<CellarLayout.shelvesPerBay {
                let y = shelfY(shelfInBay: shelf)
                box(D.bayWidth, D.boardThickness, D.shelfDepth, 0, y - D.boardThickness / 2, 0)
                // Front lip
                box(D.bayWidth, 0.03, 0.015, 0, y + 0.004, D.shelfDepth / 2 - 0.0075)
            }
            let flattened = bayNode.flattenedClone()
            flattened.position = SCNVector3(Float(bay) * D.bayStride - totalWidth / 2 + D.bayStride / 2, 0, 0)

            // Warm LED strips under each shelf (emissive, not real lights, for performance).
            for shelf in 0..<CellarLayout.shelvesPerBay {
                let strip = SCNBox(width: CGFloat(D.bayWidth - 0.04), height: 0.004, length: 0.01, chamferRadius: 0)
                let glow = SCNMaterial()
                glow.lightingModel = .constant
                glow.diffuse.contents = UIColor(hex: 0xFFC67A)
                glow.emission.contents = UIColor(hex: 0xFFC67A)
                glow.emission.intensity = 2.2
                strip.materials = [glow]
                let stripNode = SCNNode(geometry: strip)
                stripNode.position = SCNVector3(0, shelfY(shelfInBay: shelf) + D.shelfSpacing - D.boardThickness - 0.006, D.shelfDepth / 2 - 0.03)
                if shelf > 0 { flattened.addChildNode(stripNode) }
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
        // Slight per-bottle rotation so labels don't look cloned.
        node.eulerAngles.y = Float(Int(bottle.id.stableSeed % 9) - 4) * 0.02
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
        node.position = SCNVector3(0, -0.018, 0.06)
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

    private func clampTarget() {
        let halfWidth = Float(max(1, builtBays)) * CellarAssets.Dim.bayStride / 2
        target.x = min(max(target.x, -halfWidth + 0.2), halfWidth - 0.2)
        target.y = min(max(target.y, 0.35), CellarAssets.Dim.bayHeight - 0.2)
        distance = min(max(distance, 0.55), 4.8)
        yaw = min(max(yaw, -0.75), 0.75)
        pitch = min(max(pitch, -0.3), 0.45)
    }

    func resetCamera() {
        yaw = 0; pitch = 0.08; distance = builtBays > 1 ? 3.4 : 2.6
        target = SIMD3<Float>(0, 1.0, 0)
        wake()
    }

    @objc private func tick() {
        step()
    }

    /// Per-frame smoothing toward targets + a gentle idle drift.
    private func step() {
        let k: Float = 0.14
        let idleFor = Date().timeIntervalSince(lastInteraction)
        // Gentle drift for a minute after the last touch, then settle so rendering can pause.
        let idle = idleFor > 4 && idleFor < 60 && inspectedID == nil && movingID == nil && !reduceMotion
        let drift: Float = idle ? Float(sin(Date().timeIntervalSince(startTime) * 0.25)) * 0.05 : 0
        currentYaw += (yaw + drift - currentYaw) * k
        currentPitch += (pitch - currentPitch) * k
        currentDistance += (distance - currentDistance) * k
        currentTarget += (target - currentTarget) * k
        applyCamera()
        let settled = abs(yaw + drift - currentYaw) < 0.0005 && abs(distance - currentDistance) < 0.0005
            && simd_length(target - currentTarget) < 0.0005 && abs(pitch - currentPitch) < 0.0005
        if settled && !idle && inspectedID == nil && movingID == nil {
            view.rendersContinuously = false
            displayLink?.isPaused = true
        }
    }

    private func wake() {
        lastInteraction = Date()
        view.rendersContinuously = true
        displayLink?.isPaused = false
    }

    // MARK: - Gestures

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        for g in [pan, twoFinger, pinch, tap, doubleTap, longPress] as [UIGestureRecognizer] {
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
            // Rotate the inspected bottle.
            node.eulerAngles.y += Float(t.x) * 0.012
            node.eulerAngles.x = min(max(node.eulerAngles.x + Float(t.y) * 0.006, -0.5), 0.5)
            return
        }
        yaw -= Float(t.x) * 0.004
        pitch += Float(t.y) * 0.003
        clampTarget()
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        guard inspectedID == nil else { return }
        wake()
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        let scale = distance * 0.0016
        target.x -= Float(t.x) * scale * cos(yaw)
        target.z += Float(t.x) * scale * sin(yaw)
        target.y += Float(t.y) * scale
        clampTarget()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        wake()
        if let id = inspectedID, let node = bottleNodes[id] {
            let s = min(max(Float(node.scale.x) * Float(g.scale), 0.8), 1.8)
            node.scale = SCNVector3(s, s, s)
        } else {
            distance /= Float(g.scale)
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
        node.runAction(.group([fly, turn]))
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
