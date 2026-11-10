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

/// Identifies the bottle the inspector opens on.
private struct InspectTarget: Identifiable, Hashable {
    var id: UUID
}

private struct CellarContent: View {
    @Bindable var model: CellarViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var showFilters = false
    @State private var showCustomize = false
    @State private var inspecting: InspectTarget?
    @State private var detailWine: Wine?

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
        .fullScreenCover(item: $inspecting) { target in
            BottleInspectorView(model: model, startID: target.id) { wine in
                inspecting = nil
                Task { @MainActor in
                    // Let the cover finish dismissing before pushing.
                    try? await Task.sleep(for: .milliseconds(350))
                    detailWine = wine
                }
            }
            .environment(env)
        }
        .navigationDestination(item: $detailWine) { WineDetailView(wine: $0) }
        .task(id: "\(env.cellarFocusWineID?.uuidString ?? "-")|\(model.inStock.count)") {
            focusRequestedBottle()
        }
    }

    /// Opens a bottle requested from elsewhere (e.g. "See it in your cellar" on a wine page).
    private func focusRequestedBottle() {
        guard let wineID = env.cellarFocusWineID,
              let bottle = model.inStock.first(where: { $0.wine.id == wineID }) else { return }
        env.cellarFocusWineID = nil
        model.mode = .physical
        inspecting = InspectTarget(id: bottle.id)
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

    // MARK: Shelves

    @ViewBuilder private var physical: some View {
        switch model.bottles {
        case .failed(let message):
            ErrorStateView(message: message) { Task { await model.load() } }
            Spacer()
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.isEmpty {
                emptyState
            } else {
                CellarWallView(model: model) { inspecting = InspectTarget(id: $0.id) }
                    .overlay(alignment: .top) {
                        if model.filter.isActive { filterBanner }
                    }
            }
        }
    }

    private var filterBanner: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
            Text("\(model.inStock.count - model.dimmedIDs.count) bottles match your filters")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Clear") { model.filter = CellarFilter() }.font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Your cellar awaits")
                .font(Typo.title3)
            Text("Scan your first bottle and it will appear on the shelf with its real label, ready to inspect in 3D.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(CellarWallStyle.secondaryText)
            Button {
                env.isScannerPresented = true
            } label: {
                Label("Scan your first bottle", systemImage: "viewfinder")
            }
            .buttonStyle(.primary)
            Spacer()
            Spacer()
        }
        .foregroundStyle(CellarWallStyle.text)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CellarWallStyle.wall.ignoresSafeArea())
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Cellar options")
            }
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
