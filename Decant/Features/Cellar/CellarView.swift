import SwiftUI

struct CellarView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: CellarViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    CellarContent(model: model)
                } else {
                    Color.clear
                }
            }
            .appDestinations()
        }
        .task {
            if model == nil { model = CellarViewModel(env: env) }
            await model?.load()
        }
        .onChange(of: env.cellarRevision) { Task { await model?.load() } }
        .onChange(of: env.diaryRevision) { Task { await model?.loadHistory() } }
    }
}

private struct CellarContent: View {
    @Bindable var model: CellarViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controller: CellarSceneController?
    @State private var showFilters = false
    @State private var showCustomize = false
    @State private var managedBottle: CellarBottle?
    @State private var ratingWine: Wine?
    @State private var shareItem: ShareImage?
    @State private var path: [Route] = []
    @State private var detailWine: Wine?

    private var uses2D: Bool { model.settings.prefers2D || ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.mode {
            case .physical: physical
            case .history: CellarHistoryGrid(history: model.history)
            }
        }
        .screenBackground()
        .navigationTitle("Cellar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showFilters) { CellarFilterSheet(model: model) }
        .sheet(isPresented: $showCustomize) { CellarCustomizeSheet(model: model) }
        .sheet(item: $managedBottle) { bottle in BottleManageSheet(bottle: bottle, model: model) }
        .sheet(item: $ratingWine) { wine in RateWineView(wine: wine) }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.image]) }
        .navigationDestination(item: $detailWine) { WineDetailView(wine: $0) }
        .task(id: "\(env.cellarFocusWineID?.uuidString ?? "-")|\(model.inStock.count)|\(controller != nil)") {
            await focusRequestedBottle()
        }
    }

    /// Flies to and inspects a bottle requested from elsewhere (e.g. right after scanning).
    private func focusRequestedBottle() async {
        guard let wineID = env.cellarFocusWineID,
              let bottle = model.inStock.first(where: { $0.wine.id == wineID }) else { return }
        model.mode = .physical
        if uses2D {
            env.cellarFocusWineID = nil
            managedBottle = bottle
            return
        }
        // The scene may still be loading; this task re-runs once the controller exists.
        guard let controller else { return }
        env.cellarFocusWineID = nil
        try? await Task.sleep(for: .milliseconds(400))
        controller.focus(on: bottle.id)
        try? await Task.sleep(for: .milliseconds(900))
        controller.inspect(bottle.id)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            Picker("Collection", selection: $model.mode) {
                ForEach(CellarViewModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 0) {
                stat("\(model.totalBottles)", "Bottles")
                Divider().frame(height: 28)
                if model.purchasedValue > 0 {
                    stat(Price(amount: Decimal(model.purchasedValue), currency: "USD").formatted, "Paid")
                    Divider().frame(height: 28)
                }
                stat("\(model.history.count)", "Wines tasted")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .serif).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Physical cellar

    @ViewBuilder private var physical: some View {
        switch model.bottles {
        case .failed(let message):
            ErrorStateView(message: message) { Task { await model.load() } }
            Spacer()
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if uses2D {
                Cellar2DGrid(model: model, onSelect: { managedBottle = $0 })
            } else {
                scene3D
            }
        }
    }

    private var scene3D: some View {
        ZStack {
            CellarSceneView(
                bottles: model.displayedBottles,
                layout: model.layout,
                finish: model.settings.finish,
                dimmed: model.dimmedIDs,
                controllerRef: { c in Task { @MainActor in controller = c } },
                onInspect: { id in withAnimation(.smooth) { model.inspectedID = id } },
                onMove: { id, slot in Task { await model.move(id, to: slot) } },
                onBeginMove: { id in withAnimation(.smooth) { model.movingID = id } }
            )
            .ignoresSafeArea(edges: .bottom)
            .accessibilityHidden(true)
            .sensoryFeedback(.impact(weight: .light), trigger: model.inspectedID) { _, new in new != nil }
            .sensoryFeedback(.impact(weight: .medium), trigger: model.movingID) { _, new in new != nil }

            VStack {
                if model.movingID != nil {
                    moveBanner
                } else if model.filter.isActive {
                    filterBanner
                }
                Spacer()
                if let bottle = model.bottle(model.inspectedID) {
                    BottleInspectorCard(
                        bottle: bottle,
                        myRating: model.myRatings[bottle.wine.id],
                        onDetails: { detailWine = bottle.wine },
                        onRate: { ratingWine = bottle.wine },
                        onManage: { managedBottle = bottle },
                        onShare: {
                            Task {
                                let image = await ShareCardRenderer.render(wine: bottle.wine, rating: model.myRatings[bottle.wine.id], author: env.currentUser)
                                shareItem = ShareImage(image: image)
                            }
                        },
                        onClose: { controller?.endInspection() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if model.isEmpty {
                    emptyCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 64)

            accessibleBottleList
        }
        .background(Color(red: 0.055, green: 0.043, blue: 0.039))
    }

    private var moveBanner: some View {
        HStack {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            Text("Tap a glowing slot or another bottle to move it")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Done") {
                controller?.endMove()
                withAnimation { model.movingID = nil }
            }
            .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Palette.burgundy.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 8)
        .onChange(of: model.layout) { _, _ in withAnimation { model.movingID = nil } }
    }

    private var filterBanner: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
            Text("\(model.displayedBottles.count - model.dimmedIDs.count) bottles match your filters")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Clear") { model.filter = CellarFilter() }.font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .padding(.top, 8)
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Text("Your cellar awaits")
                .font(Typo.title3)
            Text("Scan your first bottle and it will appear here with its real label, ready to inspect in 3D.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
            Button {
                env.isScannerPresented = true
            } label: {
                Label("Scan your first bottle", systemImage: "viewfinder")
            }
            .buttonStyle(.primary)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// VoiceOver users get a plain list of bottles in place of the 3D scene.
    private var accessibleBottleList: some View {
        VStack {}
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Cellar bottles")
            .accessibilityChildren {
                ForEach(model.displayedBottles) { bottle in
                    Button("\(bottle.wine.displayName), \(bottle.quantity) bottle\(bottle.quantity == 1 ? "" : "s")") {
                        managedBottle = bottle
                    }
                }
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.mode == .physical {
                Button { showFilters = true } label: {
                    Image(systemName: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter bottles")
                Menu {
                    Button { showCustomize = true } label: { Label("Customize cellar", systemImage: "paintbrush") }
                    NavigationLink(value: Route.milestones) { Label("Collections & milestones", systemImage: "rosette") }
                    Button {
                        Task { await model.set2D(!model.settings.prefers2D) }
                    } label: {
                        Label(model.settings.prefers2D ? "Show 3D cellar" : "Show 2D shelves", systemImage: model.settings.prefers2D ? "cube" : "square.grid.3x3")
                    }
                    if !uses2D {
                        Button { controller?.resetCamera() } label: { Label("Reset view", systemImage: "camera.metering.center.weighted") }
                        Button {
                            if let image = controller?.snapshot() { shareItem = ShareImage(image: image) }
                        } label: { Label("Share my cellar", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Cellar options")
            }
        }
    }
}

// MARK: - Inspector card

private struct BottleInspectorCard: View {
    var bottle: CellarBottle
    var myRating: Double?
    var onDetails: () -> Void
    var onRate: () -> Void
    var onManage: () -> Void
    var onShare: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bottle.wine.vintageLabel).eyebrow()
                    Text(bottle.wine.name).font(Typo.title3).lineLimit(2)
                    Text(bottle.wine.producer).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.headline).padding(8).background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Return bottle to shelf")
            }
            HStack(spacing: 16) {
                if let myRating {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your rating").font(.caption2).foregroundStyle(.white.opacity(0.6))
                        StarRatingView(rating: myRating, size: 13)
                    }
                } else if let community = bottle.wine.communityRating {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Community").font(.caption2).foregroundStyle(.white.opacity(0.6))
                        StarRatingView(rating: community, size: 13)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("In cellar").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    Text("\(bottle.quantity) bottle\(bottle.quantity == 1 ? "" : "s")").font(.subheadline.weight(.semibold))
                }
                if let window = bottle.wine.drinkingWindow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drink").font(.caption2).foregroundStyle(.white.opacity(0.6))
                        Text(window).font(.subheadline.weight(.semibold))
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Details", action: onDetails).buttonStyle(.primary)
                actionIcon("star", "Rate", onRate)
                actionIcon("slider.horizontal.3", "Manage bottle", onManage)
                actionIcon("square.and.arrow.up", "Share", onShare)
            }
            Text("Drag to rotate · Pinch to zoom")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func actionIcon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.12), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - 2D fallback

struct Cellar2DGrid: View {
    @Bindable var model: CellarViewModel
    var onSelect: (CellarBottle) -> Void
    @Environment(AppEnvironment.self) private var env

    private var shelves: [[CellarBottle]] {
        let ordered = model.displayedBottles.sorted {
            let a = model.layout.slots[$0.id], b = model.layout.slots[$1.id]
            return (a?.shelf ?? 0, a?.slot ?? 0) < (b?.shelf ?? 0, b?.slot ?? 0)
        }
        return stride(from: 0, to: ordered.count, by: 4).map { Array(ordered[$0..<min($0 + 4, ordered.count)]) }
    }

    var body: some View {
        ScrollView {
            if model.isEmpty {
                EmptyStateView(symbol: "square.stack.3d.up", title: "Your cellar awaits",
                               message: "Scan a bottle to add it to your cellar.", actionTitle: "Scan a bottle") {
                    env.isScannerPresented = true
                }
            }
            LazyVStack(spacing: 18) {
                ForEach(Array(shelves.enumerated()), id: \.offset) { _, shelf in
                    // Bottles stand directly on the shelf; names sit below it so a
                    // count badge or a long name never lifts one bottle off the wood.
                    VStack(spacing: 0) {
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(shelf) { bottle in
                                Button { onSelect(bottle) } label: {
                                    BottleArtView(wine: bottle.wine, height: 120)
                                        .opacity(model.dimmedIDs.contains(bottle.id) ? 0.2 : 1)
                                        .overlay(alignment: .topTrailing) {
                                            if bottle.quantity > 1 {
                                                Text("×\(bottle.quantity)")
                                                    .font(.caption2.weight(.bold).monospacedDigit())
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Palette.burgundy, in: Capsule())
                                                    .offset(x: 10, y: 14)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(bottle.wine.displayName), \(bottle.quantity) in cellar")
                            }
                            ForEach(0..<(4 - shelf.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                        }
                        .padding(.horizontal, 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(uiColor: CellarTextures.woodColor(model.settings.finish)))
                            .frame(height: 10)
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(shelf) { bottle in
                                Text(bottle.wine.name)
                                    .font(.caption2.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .foregroundStyle(Palette.charcoal)
                                    .padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityHidden(true)
                            }
                            ForEach(0..<(4 - shelf.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    }
                }
            }
            .padding(Metrics.gutter)
        }
    }
}

// MARK: - Wine history library

private struct CellarHistoryGrid: View {
    var history: [HistoryWine]
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            if history.isEmpty {
                EmptyStateView(symbol: "books.vertical", title: "Your wine library",
                               message: "Every wine you rate is collected here — a museum of every bottle you've tried.",
                               actionTitle: "Scan a wine") { env.isScannerPresented = true }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], spacing: 18) {
                    ForEach(history) { item in
                        NavigationLink(value: Route.wine(item.wine)) {
                            VStack(spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    BottleArtView(wine: item.wine, height: 120)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    if item.isFavorite {
                                        Image(systemName: "heart.fill").font(.caption).foregroundStyle(Palette.burgundy).padding(8)
                                    }
                                }
                                Text(item.wine.name).font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(Palette.charcoal)
                                if let rating = item.bestRating { StarRatingView(rating: rating, size: 9) }
                                Text(item.timesTasted > 1 ? "Tasted \(item.timesTasted)×" : item.lastTasted.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2).foregroundStyle(Palette.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Metrics.gutter)
            }
        }
    }
}
