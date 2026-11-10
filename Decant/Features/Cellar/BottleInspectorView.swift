import RealityKit
import SwiftUI

/// Full-screen bottle inspector. Swipe sideways to move through the cellar in shelf
/// order; tap Turn (or double-tap the bottle) to rotate it and pinch to read the label.
struct BottleInspectorView: View {
    var model: CellarViewModel
    var onOpenDetails: (Wine) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentID: UUID?
    @State private var settledID: UUID?
    @State private var isTurning = false
    @State private var yaw: Float = 0
    @State private var dragStartYaw: Float?
    @State private var zoom: Float = 1
    @State private var pinchStartZoom: Float?
    @State private var ratingWine: Wine?
    @State private var managedBottle: CellarBottle?
    @State private var shareItem: ShareImage?
    @State private var confirmOpen: CellarBottle?

    init(model: CellarViewModel, startID: UUID, onOpenDetails: @escaping (Wine) -> Void) {
        self.model = model
        self.onOpenDetails = onOpenDetails
        _currentID = State(initialValue: startID)
        _settledID = State(initialValue: startID)
    }

    private var bottles: [CellarBottle] { model.wall.orderedBottles }
    private var current: CellarBottle? { bottles.first { $0.id == currentID } ?? bottles.first }
    private var index: Int { bottles.firstIndex { $0.id == current?.id } ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let stageHeight = min(proxy.size.height * 0.56, 520)
            VStack(spacing: 0) {
                topBar
                pager(stageHeight: stageHeight)
                    .frame(height: stageHeight)
                if let current {
                    InspectorDetails(bottle: current, myRating: model.myRatings[current.wine.id],
                                     onOpen: { confirmOpen = current },
                                     onRate: { ratingWine = current.wine },
                                     onDetails: { onOpenDetails(current.wine) },
                                     onManage: { managedBottle = current })
                        .id(current.id)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
        }
        .background { stageBackground.ignoresSafeArea() }
        .foregroundStyle(CellarWallStyle.text)
        .environment(\.colorScheme, .dark)
        .sheet(item: $ratingWine) { RateWineView(wine: $0) }
        .sheet(item: $managedBottle) { BottleManageSheet(bottle: $0, model: model) }
        .sheet(item: $shareItem) { ActivityView(items: [$0.image]) }
        .onChange(of: bottles.map(\.id)) { _, ids in
            // The last bottle of a wine was opened or removed: move to a neighbour, or close.
            guard let currentID, !ids.contains(currentID) else { return }
            if ids.isEmpty { dismiss() } else { self.currentID = ids[min(index, ids.count - 1)]; settledID = self.currentID }
        }
        .sensoryFeedback(.selection, trigger: settledID)
        // Opening a bottle changes inventory, so it takes a second tap.
        .confirmationDialog("Open a bottle of \(confirmOpen?.wine.name ?? "this wine")?",
                            isPresented: Binding(get: { confirmOpen != nil }, set: { if !$0 { confirmOpen = nil } }),
                            titleVisibility: .visible, presenting: confirmOpen) { bottle in
            Button("Open bottle") { Task { await model.consume(bottle) } }
            Button("Cancel", role: .cancel) {}
        } message: { bottle in
            Text(bottle.quantity == 1
                 ? "This is your last bottle. It will move to your Wine History."
                 : "You'll have \(bottle.quantity - 1) left in your cellar.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            circleButton("xmark", "Close") { dismiss() }
            Spacer()
            Text("\(index + 1) of \(bottles.count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(CellarWallStyle.secondaryText)
            Spacer()
            circleButton("square.and.arrow.up", "Share") {
                guard let current else { return }
                Task {
                    let image = await ShareCardRenderer.render(wine: current.wine, rating: model.myRatings[current.wine.id], author: env.currentUser)
                    shareItem = ShareImage(image: image)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func circleButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Pager

    private func pager(stageHeight: CGFloat) -> some View {
        let bottleHeight = stageHeight * 0.9
        return ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(bottles) { bottle in
                        stage(for: bottle, bottleHeight: bottleHeight)
                            .containerRelativeFrame(.horizontal)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(1 - abs(phase.value) * 0.18)
                                    .opacity(1 - abs(phase.value) * 0.55)
                                    .blur(radius: abs(phase.value) * 3)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .scrollDisabled(isTurning)
            .onScrollPhaseChange { _, phase in
                if phase == .idle, settledID != currentID {
                    settledID = currentID
                    resetPose()
                }
            }

            if isTurning {
                // Above the pager so drags turn the bottle instead of being taken by scrolling.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(turnGesture)
                    .onTapGesture(count: 2) { toggleTurning() }
            }

            turnControl
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func stage(for bottle: CellarBottle, bottleHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // Plinth light pool.
            Ellipse()
                .fill(RadialGradient(colors: [CellarWallStyle.glow.opacity(0.28), .clear], center: .center, startRadius: 2, endRadius: 140))
                .frame(width: 280, height: 46)
                .offset(y: 14)
            // The shelf render stays underneath: it shows while the live bottle loads and
            // during swipes, and the live bottle covers it exactly once ready.
            BottleRender(wine: bottle.wine, height: bottleHeight)
            if bottle.id == settledID {
                LiveBottleView(wine: bottle.wine, yaw: yaw, zoom: zoom, introTurn: !reduceMotion)
                    .frame(height: bottleHeight)
                    // Touches go to the pager unless the user is turning the bottle.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if bottle.id == settledID { toggleTurning() } }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 44)
        .accessibilityElement()
        .accessibilityLabel(bottle.wine.displayName)
    }

    private var turnGesture: some Gesture {
        SimultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStartYaw ?? yaw
                    dragStartYaw = start
                    yaw = start + Float(value.translation.width) * 0.012
                }
                .onEnded { _ in dragStartYaw = nil },
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStartZoom ?? zoom
                    pinchStartZoom = start
                    zoom = min(max(start * Float(value.magnification), 1), 2.6)
                }
                .onEnded { _ in pinchStartZoom = nil }
        )
    }

    private var turnControl: some View {
        Button(action: toggleTurning) {
            Label(isTurning ? "Done turning" : "Turn bottle", systemImage: isTurning ? "checkmark" : "rotate.3d")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isTurning ? AnyShapeStyle(Palette.burgundy) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
        }
        .accessibilityHint(isTurning ? "Swipe returns to moving between bottles" : "Drag to rotate the bottle and pinch to zoom")
    }

    private func toggleTurning() {
        withAnimation(.snappy) {
            isTurning.toggle()
            if !isTurning { zoom = 1 }
        }
    }

    private func resetPose() {
        yaw = 0
        zoom = 1
        isTurning = false
    }

    private var stageBackground: some View {
        ZStack {
            CellarWallStyle.wallDeep
            RadialGradient(colors: [Color(red: 0.23, green: 0.16, blue: 0.13), .clear], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 10, endRadius: 420)
        }
    }
}

// MARK: - Details

private struct InspectorDetails: View {
    var bottle: CellarBottle
    var myRating: Double?
    var onOpen: () -> Void
    var onRate: () -> Void
    var onDetails: () -> Void
    var onManage: () -> Void

    private var wine: Wine { bottle.wine }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text([wine.vintageLabel, wine.appellation ?? wine.region].compactMap { $0 }.joined(separator: " · ").uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.gold)
                Text(wine.name)
                    .font(.system(.title, design: .serif).weight(.medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text([wine.producer, wine.locationLine].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(CellarWallStyle.secondaryText)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 22) {
                fact("In cellar", "\(bottle.quantity)")
                if let myRating {
                    fact("Your rating", myRating.formatted(.number.precision(.fractionLength(1))) + "★")
                } else if let community = wine.communityRating, wine.ratingsCount > 0 {
                    fact("Community", community.formatted(.number.precision(.fractionLength(1))) + "★")
                }
                if let window = wine.drinkingWindow { fact("Drink", window) }
            }

            if let from = wine.drinkFrom, let until = wine.drinkUntil, until > from {
                DrinkingWindowBar(from: from, until: until)
            }

            HStack(spacing: 10) {
                Button(action: onOpen) {
                    Label("Open a bottle", systemImage: "wineglass")
                }
                .buttonStyle(.primary)
                iconButton("star", "Rate", onRate)
                iconButton("info.circle", "Details", onDetails)
                iconButton("slider.horizontal.3", "Manage bottle", onManage)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 6)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(CellarWallStyle.secondaryText)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.1), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

/// Where this year falls in the wine's drinking window.
private struct DrinkingWindowBar: View {
    var from: Int
    var until: Int
    private var year: Int { Calendar.current.component(.year, from: .now) }

    var body: some View {
        let start = min(from, year) - 2, end = max(until, year) + 2
        let span = CGFloat(end - start)
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.burgundy, Palette.gold], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * CGFloat(until - from) / span)
                    .offset(x: w * CGFloat(from - start) / span)
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 12)
                    .offset(x: w * CGFloat(year - start) / span - 1)
            }
        }
        .frame(height: 6)
        .padding(.vertical, 3)
        .accessibilityElement()
        .accessibilityLabel(year < from ? "Not ready until \(from)" : year > until ? "Past its window since \(until)" : "In its drinking window until \(until)")
    }
}

// MARK: - Live 3D bottle

/// The same bottle as the shelf render, live. The camera and lights match the
/// thumbnail exactly, so the swap from image to 3D is invisible.
struct LiveBottleView: View {
    var wine: Wine
    var yaw: Float
    var zoom: Float
    var introTurn: Bool

    var body: some View {
        RealityView { content in
            let studio = BottleStudio.shared
            let bottle = studio.makeBottle(for: wine, label: await studio.labelImage(for: wine))
            let scene = Entity()
            scene.name = "scene"
            scene.addChild(bottle)
            if let environment = studio.studioEnvironment() {
                scene.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0))
                Self.receiveLight(from: scene, in: bottle)
            }
            for light in BottleStudio.studioLights() { scene.addChild(light) }
            let camera = Entity()
            camera.name = "camera"
            var lens = PerspectiveCameraComponent()
            lens.fieldOfViewInDegrees = BottleStudio.fieldOfView
            camera.components.set(lens)
            camera.position = BottleStudio.cameraPosition
            scene.addChild(camera)
            content.add(scene)

            if introTurn, let spinner = bottle.findEntity(named: "spinner") {
                spinner.orientation = simd_quatf(angle: -0.9, axis: [0, 1, 0])
                spinner.move(to: Transform(rotation: simd_quatf(angle: 0, axis: [0, 1, 0])), relativeTo: bottle, duration: 0.9, timingFunction: .easeOut)
            }
        } update: { content in
            guard let scene = content.entities.first,
                  let spinner = scene.findEntity(named: "spinner"),
                  let camera = scene.findEntity(named: "camera") else { return }
            if yaw != 0 || zoom != 1 {
                spinner.stopAllAnimations()
                spinner.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            }
            // Zoom toward the label.
            let form = BottleForm(wine: wine)
            let focus = SIMD3<Float>(0, (form.labelSpan.0 + form.labelSpan.1) / 2, 0)
            let base = BottleStudio.cameraPosition
            let anchor = SIMD3<Float>(0, base.y + (focus.y - base.y) * min(1, (zoom - 1) / 1.6), 0)
            camera.position = [0, anchor.y, base.z / zoom]
        }
    }

    @MainActor private static func receiveLight(from source: Entity, in entity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: source))
        for child in entity.children { receiveLight(from: source, in: child) }
    }
}
