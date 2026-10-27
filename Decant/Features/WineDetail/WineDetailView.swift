import SwiftUI

struct WineDetailView: View {
    enum Origin { case browse, scan }

    var wine: Wine
    var origin: Origin = .browse
    @Environment(AppEnvironment.self) private var env
    @State private var model: WineDetailViewModel?

    var body: some View {
        Group {
            if let model {
                WineDetailContent(model: model, origin: origin)
            } else {
                Color.clear
            }
        }
        .screenBackground()
        .task(id: wine.id) {
            if model?.wine.id != wine.id { model = WineDetailViewModel(wine: wine, env: env) }
            await model?.load()
        }
        .onChange(of: env.diaryRevision) { Task { await model?.load() } }
        .onChange(of: env.cellarRevision) { Task { await model?.load() } }
        .onChange(of: env.moderationRevision) { Task { await model?.load() } }
    }
}

private struct WineDetailContent: View {
    @Bindable var model: WineDetailViewModel
    var origin: WineDetailView.Origin
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var showRate = false
    @State private var showAddToCellar = false
    @State private var showShare = false
    @State private var showLabel = false
    @State private var showWinery = false
    @State private var showDetails = false

    private var wine: Wine { model.wine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                identity
                actions
                if origin == .scan, model.cellarQuantity > 0 { openCellarBanner }
                if !model.myEntries.isEmpty { myTastings }
                if let c = wine.characteristics { profile(c) }
                if !wine.pairings.isEmpty { pairings }
                details
                if wine.winery.story != nil || !wine.winery.highlights.isEmpty { winery }
                if !model.friendRatings.isEmpty { friends }
                reviews
                if !model.similar.isEmpty { similar }
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(wine.vintageLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share wine")
            }
        }
        .sheet(isPresented: $showRate) { RateWineView(wine: wine) }
        .sheet(isPresented: $showAddToCellar) { AddToCellarSheet(wine: wine) }
        .sheet(isPresented: $showShare) {
            ShareWineSheet(wine: wine, rating: model.myLatestRating, review: model.myEntries.first?.entry.review)
        }
        .fullScreenCover(isPresented: $showLabel) { LabelPhotoViewer(path: wine.labelImagePath) }
    }

    // MARK: Hero

    private var hero: some View {
        BottleStage(tint: Palette.wineColor(wine.type)) {
            BottleArtView(wine: wine, height: 280)
                .onTapGesture { if wine.labelImagePath != nil { showLabel = true } }
                .accessibilityAddTraits(wine.labelImagePath != nil ? .isButton : [])
                .accessibilityHint(wine.labelImagePath != nil ? "Shows your label photo" : "")
        }
        .frame(height: 330)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Palette.wineColor(wine.type).opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TypeDot(type: wine.type)
                if wine.factsSource != .editorial { SourceBadge(source: wine.factsSource) }
            }
            Text(wine.name).font(Typo.hero).fixedSize(horizontal: false, vertical: true)
            Text([wine.producer, wine.locationLine].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.headline.weight(.regular))
                .foregroundStyle(Palette.secondaryText)

            if model.vintages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.vintages) { v in
                            NavigationLink(value: Route.wine(v)) {
                                Chip(title: v.vintageLabel, isSelected: v.id == wine.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(v.id == wine.id)
                        }
                    }
                }
                .accessibilityLabel("Other vintages")
            }

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(wine.communityRating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
                            .font(.system(size: 40, weight: .semibold, design: .serif))
                        StarRatingView(rating: wine.communityRating ?? 0, size: 15)
                    }
                    Text(wine.ratingsCount == 0 ? "No ratings yet" : "\(wine.ratingsCount) rating\(wine.ratingsCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                if let price = wine.price {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(price.formatted).font(.system(.title2, design: .serif).weight(.semibold))
                        Text("Est. retail").font(.caption).foregroundStyle(Palette.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { showRate = true } label: {
                Label(model.myEntries.isEmpty ? "Rate" : "Log again", systemImage: "star.fill")
            }
            .buttonStyle(.primary)
            actionButton(model.cellarQuantity > 0 ? "\(model.cellarQuantity) in cellar" : "Cellar",
                         symbol: model.cellarQuantity > 0 ? "square.stack.3d.up.fill" : "square.stack.3d.up") { showAddToCellar = true }
            actionButton("Wishlist", symbol: model.isWishlisted ? "bookmark.fill" : "bookmark") { Task { await model.toggleWishlist() } }
            actionButton("Share", symbol: "paperplane") { showShare = true }
        }
        .padding(.horizontal, Metrics.gutter)
        .sensoryFeedback(.selection, trigger: model.isWishlisted)
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.headline)
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Palette.burgundy)
            .frame(width: 70, height: 52)
            .background(Palette.burgundy.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(title)
    }

    private var openCellarBanner: some View {
        Button {
            env.cellarFocusWineID = wine.id
            env.selectedTab = .cellar
            env.isScannerPresented = false
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "cube.transparent").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("See it in your 3D cellar").font(.headline)
                    Text("Your bottle is on the shelf with its label").font(.caption).opacity(0.8)
                }
                Spacer()
                Image(systemName: "arrow.right")
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(LinearGradient(colors: [Palette.burgundy, Palette.burgundyDeep], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        .padding(.horizontal, Metrics.gutter)
    }

    // MARK: Sections

    private var myTastings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your tastings", subtitle: "\(model.myEntries.count) entr\(model.myEntries.count == 1 ? "y" : "ies") in your diary")
            ForEach(model.myEntries) { item in
                NavigationLink(value: Route.entry(item.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if let rating = item.entry.rating { StarRatingView(rating: rating, size: 12) }
                            Text(item.entry.consumedOn.formatted(date: .abbreviated, time: .omitted))
                                .font(.subheadline.weight(.medium))
                            if let notes = item.entry.personalNotes {
                                Label(notes, systemImage: "lock.fill").font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: item.entry.visibility.systemImage).foregroundStyle(Palette.secondaryText)
                    }
                    .foregroundStyle(Palette.charcoal)
                }
            }
        }
        .cardSurface()
        .padding(.horizontal, Metrics.gutter)
    }

    private func profile(_ c: WineCharacteristics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Taste profile").font(Typo.title3)
                Spacer()
                SourceBadge(source: c.source)
            }
            FlavorProfileView(characteristics: c)
            if !c.flavors.isEmpty {
                FlowLayout { ForEach(c.flavors, id: \.self) { Chip(title: $0) } }
            }
            if let notes = c.tastingNotes {
                Text(notes).font(.system(.body, design: .serif)).italic()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                if let t = c.servingTempC {
                    GridRow { factLabel("thermometer.medium", "Serve"); Text("\(t.lowerBound)–\(t.upperBound) °C") }
                }
                if let d = c.decantMinutes {
                    GridRow { factLabel("drop", "Decant"); Text(d == 0 ? "Not needed" : "\(d) min") }
                }
                if let a = c.agingPotentialYears {
                    GridRow { factLabel("hourglass", "Aging potential"); Text("Up to \(a) years") }
                }
                if let window = wine.drinkingWindow {
                    GridRow { factLabel("calendar", "Drinking window"); Text(window) }
                }
            }
            .font(.subheadline)
            if c.source == .aiSuggested {
                Text("AI-generated typical-style guidance, not verified facts.").font(.caption).foregroundStyle(Palette.secondaryText)
            } else if c.source == .editorial {
                Text("Curated description of this wine's typical style; individual bottles vary.").font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
        .cardSurface()
        .padding(.horizontal, Metrics.gutter)
    }

    private func factLabel(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(Palette.secondaryText)
    }

    private var pairings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Food pairings").padding(.horizontal, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(wine.pairings, id: \.self) { pairing in
                        VStack(spacing: 8) {
                            Image(systemName: PairingIcon.symbol(for: pairing))
                                .font(.title2)
                                .foregroundStyle(Palette.burgundy)
                                .frame(width: 58, height: 58)
                                .background(Palette.burgundy.opacity(0.08), in: Circle())
                            Text(pairing).font(.caption.weight(.medium)).multilineTextAlignment(.center).lineLimit(2)
                        }
                        .frame(width: 90)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
            }
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                if !wine.grapes.isEmpty { GridRow { factLabel("leaf", "Grapes"); Text(wine.grapeLine) } }
                if let a = wine.appellation { GridRow { factLabel("seal", "Appellation"); Text(a) } }
                if let r = wine.region { GridRow { factLabel("map", "Region"); Text(r) } }
                if let c = wine.country { GridRow { factLabel("globe", "Country"); Text(c) } }
                GridRow { factLabel("calendar", "Vintage"); Text(wine.vintage.map(String.init) ?? "Non-vintage") }
                if let abv = wine.abv { GridRow { factLabel("percent", "Alcohol"); Text("\(abv.formatted())% ABV") } }
                GridRow { factLabel("waterbottle", "Bottle"); Text("\(wine.bottleSizeML) ml") }
                if let p = wine.price { GridRow { factLabel("tag", "Est. price"); Text("\(p.formatted) \(p.currency)") } }
            }
            .font(.subheadline)
            .padding(.top, 10)
            HStack {
                Text("Source").font(.caption).foregroundStyle(Palette.secondaryText)
                SourceBadge(source: wine.factsSource)
            }
            .padding(.top, 8)
        } label: {
            Text("Wine details").font(Typo.title3).foregroundStyle(Palette.charcoal)
        }
        .cardSurface()
        .padding(.horizontal, Metrics.gutter)
    }

    private var winery: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The winery").eyebrow()
                    Text(wine.winery.name).font(Typo.title3)
                }
                Spacer()
                SourceBadge(source: wine.winery.source)
            }
            if let story = wine.winery.story {
                Text(story).font(.callout).lineLimit(showWinery ? nil : 3)
            }
            if showWinery {
                if let founded = wine.winery.foundedYear {
                    Label("Founded \(String(founded))", systemImage: "building.columns").font(.subheadline)
                }
                ForEach(wine.winery.practices, id: \.self) { Label($0, systemImage: "leaf").font(.subheadline) }
                ForEach(wine.winery.highlights, id: \.self) { Label($0, systemImage: "rosette").font(.subheadline) }
            }
            Button(showWinery ? "Show less" : "Read more") { withAnimation(.smooth) { showWinery.toggle() } }
                .font(.subheadline.weight(.semibold))
        }
        .cardSurface()
        .padding(.horizontal, Metrics.gutter)
    }

    private var friends: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Friends who've tried it")
            ForEach(model.friendRatings) { rating in
                NavigationLink(value: Route.entry(rating.entryID)) {
                    HStack(spacing: 12) {
                        AvatarView(profile: rating.friend, size: 36)
                        Text(rating.friend.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.charcoal)
                        Spacer()
                        if let r = rating.rating { StarRatingView(rating: r, size: 12) }
                    }
                }
            }
        }
        .cardSurface()
        .padding(.horizontal, Metrics.gutter)
    }

    @ViewBuilder private var reviews: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Community reviews")
                .padding(.horizontal, Metrics.gutter)
            switch model.reviews {
            case .loading, .idle:
                VStack(spacing: 10) { SkeletonBlock(height: 90); SkeletonBlock(height: 90) }.padding(.horizontal, Metrics.gutter)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await model.load() } }
            case .loaded(let list) where list.isEmpty:
                Text("No reviews yet. Be the first to share your thoughts.")
                    .font(.callout).foregroundStyle(Palette.secondaryText).padding(.horizontal, Metrics.gutter)
            case .loaded(let list):
                ForEach(list) { item in
                    ReviewCard(item: item, showsWine: false, onLike: { Task { await model.toggleLike(item) } })
                        .padding(.horizontal, Metrics.gutter)
                }
            }
        }
    }

    private var similar: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Similar wines").padding(.horizontal, Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(model.similar) { wine in
                        NavigationLink(value: Route.wine(wine)) { WineCard(wine: wine) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 4)
            }
        }
    }
}

struct FlavorProfileView: View {
    var characteristics: WineCharacteristics

    private var rows: [(String, String, String, Double?)] {
        [("Sweetness", "Dry", "Sweet", characteristics.sweetness),
         ("Acidity", "Soft", "Crisp", characteristics.acidity),
         ("Body", "Light", "Bold", characteristics.body),
         ("Tannin", "Smooth", "Grippy", characteristics.tannin),
         ("Fruit", "Savory", "Fruity", characteristics.fruitiness)]
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows, id: \.0) { name, low, high, value in
                if let value {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(low).font(.caption).foregroundStyle(Palette.secondaryText)
                            Spacer()
                            Text(name).font(.caption.weight(.semibold))
                            Spacer()
                            Text(high).font(.caption).foregroundStyle(Palette.secondaryText)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.hairline)
                                Capsule()
                                    .fill(LinearGradient(colors: [Palette.burgundy.opacity(0.6), Palette.burgundy], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(12, proxy.size.width * value))
                            }
                        }
                        .frame(height: 8)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(name)
                    .accessibilityValue("\(Int(value * 100)) percent toward \(high.lowercased())")
                }
            }
        }
    }
}

enum PairingIcon {
    static func symbol(for pairing: String) -> String {
        let p = pairing.lowercased()
        if ["fish", "salmon", "trout", "oyster", "sushi", "seafood", "shrimp", "lobster", "scallop", "crab", "caviar", "ceviche"].contains(where: p.contains) { return "fish" }
        if ["cheese", "parmesan", "pecorino", "comté", "manchego", "roquefort", "gouda", "cheddar"].contains(where: p.contains) { return "circle.grid.cross" }
        if ["chicken", "turkey", "duck", "foie"].contains(where: p.contains) { return "bird" }
        if ["chocolate", "dessert", "pie", "tart", "brûlée", "brulee"].contains(where: p.contains) { return "birthday.cake" }
        if ["salad", "mushroom", "truffle", "risotto", "vegetable", "bruschetta", "portobello"].contains(where: p.contains) { return "leaf" }
        if ["pasta", "pizza", "pappardelle", "tajarin", "noodle", "paella"].contains(where: p.contains) { return "fork.knife" }
        if ["spicy", "curry", "thai", "asian"].contains(where: p.contains) { return "flame" }
        return "fork.knife.circle"
    }
}

struct LabelPhotoViewer: View {
    var path: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            StoredImage(path: path, maxPixel: 2000) { ProgressView().tint(.white) }
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Label photo")
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white).padding(12).background(.white.opacity(0.15), in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}
