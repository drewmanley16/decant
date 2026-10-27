import SwiftUI

struct CellarFilterSheet: View {
    @Bindable var model: CellarViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Wine type") {
                    FlowLayout {
                        ForEach(WineType.allCases) { type in
                            Button {
                                if model.filter.types.contains(type) { model.filter.types.remove(type) } else { model.filter.types.insert(type) }
                            } label: { Chip(title: type.displayName, isSelected: model.filter.types.contains(type)) }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Details") {
                    Picker("Vintage", selection: $model.filter.vintage) {
                        Text("Any").tag(Int?.none)
                        ForEach(model.availableVintages, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                    }
                    Picker("Grape", selection: $model.filter.grape) {
                        Text("Any").tag(String?.none)
                        ForEach(model.availableGrapes, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Picker("Region", selection: $model.filter.region) {
                        Text("Any").tag(String?.none)
                        ForEach(model.availableRegions, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Picker("Minimum rating", selection: $model.filter.minRating) {
                        Text("Any").tag(Double?.none)
                        ForEach([3.0, 3.5, 4.0, 4.5], id: \.self) { Text("\($0.formatted())★ +").tag(Double?.some($0)) }
                    }
                    if !model.collections.isEmpty {
                        Picker("Collection", selection: $model.filter.collectionID) {
                            Text("Any").tag(UUID?.none)
                            ForEach(model.collections) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
            }
            .brandedForm()
            .navigationTitle("Filter cellar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Clear") { model.filter = CellarFilter() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct CellarCustomizeSheet: View {
    @Bindable var model: CellarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newCollection = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Shelving finish") {
                    HStack(spacing: 14) {
                        ForEach(ShelfFinish.allCases) { finish in
                            Button {
                                Task { await model.setFinish(finish) }
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(uiColor: CellarTextures.woodColor(finish)))
                                        .frame(height: 44)
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.settings.finish == finish ? Palette.burgundy : .clear, lineWidth: 2.5))
                                    Text(finish.displayName).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.settings.finish == finish ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Picker("Arrange by", selection: Binding(get: { model.settings.sort }, set: { sort in Task { await model.setSort(sort) } })) {
                        ForEach(CellarSort.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Organization")
                } footer: {
                    Text("Choose Manual to arrange bottles yourself — press and hold a bottle in 3D to move it.")
                }
                Section("Collections") {
                    ForEach(model.collections) { collection in
                        Label(collection.name, systemImage: collection.symbol)
                    }
                    HStack {
                        TextField("New collection (e.g. Special occasions)", text: $newCollection)
                        Button("Add") {
                            let name = newCollection
                            newCollection = ""
                            Task { await model.createCollection(name: name, symbol: "sparkles") }
                        }
                        .disabled(newCollection.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    Toggle("Use 2D shelves", isOn: Binding(get: { model.settings.prefers2D }, set: { v in Task { await model.set2D(v) } }))
                } footer: {
                    Text("A lighter view for accessibility and older devices. Low Power Mode switches to 2D automatically.")
                }
                Section {
                    Label("Cellar rooms, lighting styles and display themes", systemImage: "lightbulb")
                        .foregroundStyle(Palette.secondaryText)
                } header: {
                    Text("Coming later")
                }
            }
            .brandedForm()
            .navigationTitle("Customize cellar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// Inventory management for one cellar bottle.
struct BottleManageSheet: View {
    var bottle: CellarBottle
    var model: CellarViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var quantity: Int
    @State private var confirmRemove = false
    @State private var rateAfterOpening = false

    init(bottle: CellarBottle, model: CellarViewModel) {
        self.bottle = bottle
        self.model = model
        _quantity = State(initialValue: bottle.quantity)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        BottleArtView(wine: bottle.wine, height: 110)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bottle.wine.vintageLabel).eyebrow()
                            Text(bottle.wine.name).font(Typo.title3)
                            Text(bottle.wine.producer).font(.subheadline).foregroundStyle(Palette.secondaryText)
                            NavigationLink("View details", value: Route.wine(bottle.wine)).font(.subheadline.weight(.semibold))
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button {
                        Task {
                            await model.consume(bottle)
                            rateAfterOpening = true
                        }
                    } label: {
                        Label("Open a bottle", systemImage: "wineglass")
                    }
                    .disabled(bottle.quantity == 0)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 0...999)
                        .onChange(of: quantity) { _, new in Task { await model.updateQuantity(bottle, quantity: new) } }
                } footer: {
                    Text("Opening a bottle lowers your inventory. The wine and your reviews stay in your Wine History.")
                }
                Section("Details") {
                    if let price = bottle.purchasePrice { LabeledContent("Purchase price", value: price.formatted) }
                    if let date = bottle.purchaseDate { LabeledContent("Purchased", value: date.formatted(date: .abbreviated, time: .omitted)) }
                    if let location = bottle.storageLocation { LabeledContent("Storage", value: location) }
                    if let window = bottle.wine.drinkingWindow { LabeledContent("Drinking window", value: window) }
                    LabeledContent("Opened so far", value: "\(bottle.consumedCount)")
                    if !model.collections.isEmpty {
                        Picker("Collection", selection: Binding(
                            get: { bottle.collectionID },
                            set: { id in Task { await model.assign(bottle, to: model.collections.first { $0.id == id }) } })) {
                            Text("None").tag(UUID?.none)
                            ForEach(model.collections) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
                Section {
                    Button("Remove from cellar", role: .destructive) { confirmRemove = true }
                }
            }
            .brandedForm()
            .navigationTitle("Manage bottle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove this wine from your cellar?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await model.remove(bottle); dismiss() }
                }
            } message: {
                Text("Your tasting history is not affected.")
            }
            .sheet(isPresented: $rateAfterOpening) { RateWineView(wine: bottle.wine) }
            .appDestinations()
        }
        .presentationDetents([.medium, .large])
    }
}

/// Add a wine to the physical cellar.
struct AddToCellarSheet: View {
    var wine: Wine
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var draft = CellarBottleDraft()
    @State private var collections: [CellarCollection] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        BottleArtView(wine: wine, height: 80)
                        VStack(alignment: .leading) {
                            Text(wine.name).font(.headline)
                            Text("\(wine.producer) · \(wine.vintageLabel)").font(.subheadline).foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
                Section("Inventory") {
                    Stepper("Bottles: \(draft.quantity)", value: $draft.quantity, in: 1...240)
                    HStack {
                        Text("Price per bottle")
                        Spacer()
                        TextField(wine.price?.formatted ?? "Optional", value: $draft.purchasePrice, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Purchased", selection: Binding(get: { draft.purchaseDate ?? .now }, set: { draft.purchaseDate = $0 }), displayedComponents: .date)
                    TextField("Storage location (e.g. Rack B, wine fridge)", text: $draft.storageLocation)
                }
                if !collections.isEmpty {
                    Section("Collection") {
                        Picker("Collection", selection: $draft.collectionID) {
                            Text("None").tag(UUID?.none)
                            ForEach(collections) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
                if let window = wine.drinkingWindow {
                    Section { LabeledContent("Suggested drinking window", value: window) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Palette.burgundy) }
                }
            }
            .brandedForm()
            .navigationTitle("Add to cellar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(saving)
                }
            }
            .task { collections = (try? await env.cellar.collections()) ?? [] }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await env.cellar.addBottle(wineID: wine.id, draft: draft)
            env.cellarRevision += 1
            env.show("Added to your cellar", symbol: "square.stack.3d.up.fill")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MilestonesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var milestones: [CollectionMilestone] = []

    var body: some View {
        List(milestones) { m in
            HStack(spacing: 14) {
                Image(systemName: m.symbol)
                    .font(.title3)
                    .foregroundStyle(m.achieved ? Palette.gold : Palette.secondaryText)
                    .frame(width: 44, height: 44)
                    .background((m.achieved ? Palette.gold : Palette.hairline).opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.title).font(.headline)
                    Text(m.detail).font(.subheadline).foregroundStyle(Palette.secondaryText)
                    ProgressView(value: m.progress).tint(m.achieved ? Palette.gold : Palette.burgundy)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityValue(m.achieved ? "Achieved" : "\(Int(m.progress * 100)) percent")
        }
        .navigationTitle("Milestones")
        .task {
            guard let me = env.currentUser else { return }
            let entries = (try? await env.tastings.entries(forUser: me.id)) ?? []
            let bottles = (try? await env.cellar.bottles()) ?? []
            milestones = StatsCalculator.milestones(history: StatsCalculator.history(entries), bottles: bottles)
        }
    }
}
