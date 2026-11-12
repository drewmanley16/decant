import SwiftUI

/// Shows the identification: best match with confidence, what was read from
/// the label, alternatives, AI suggestions (clearly labelled), and correction paths.
struct ScanResultView: View {
    var model: ScanViewModel
    var outcome: ScanViewModel.ScanOutcome
    var onIdentified: (Wine) -> Void
    var onManual: () -> Void

    private var result: IdentificationResult { outcome.result }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let best = result.best, best.confidence != .low {
                    MatchCard(candidate: best, scannedVintage: result.extraction.vintage, isBusy: model.isConfirming,
                              confirm: { useScanned in confirm(best, useScanned) })
                } else {
                    noConfidentMatch
                }
                extractedFacts
                let alternatives = result.best?.confidence == .low ? result.candidates : Array(result.candidates.dropFirst())
                if !alternatives.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Other possibilities")
                        ForEach(alternatives) { candidate in
                            Button { confirm(candidate, false) } label: {
                                HStack {
                                    WineRow(wine: candidate.wine, trailing: "\(Int(candidate.score * 100))% match")
                                    Image(systemName: "chevron.right").foregroundStyle(Palette.secondaryText)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isConfirming)
                        }
                    }
                    .cardSurface()
                }
                if let suggestion = result.suggestion { AISuggestionCard(suggestion: suggestion) }
                VStack(spacing: 12) {
                    Button("None of these — enter details", action: onManual).buttonStyle(.secondary)
                    Button("Scan again") { model.phase = .camera }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(Metrics.gutter)
        }
        .screenBackground()
        .navigationTitle("Scan result")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if model.isConfirming { ProgressView().controlSize(.large) } }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(uiImage: outcome.labelImage)
                .resizable()
                .scaledToFill()
                .frame(width: 92, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline))
                .accessibilityLabel("Your label photo")
            VStack(alignment: .leading, spacing: 8) {
                Text(result.engine.label).eyebrow()
                if let best = result.best {
                    ConfidenceBadge(confidence: best.confidence)
                }
                Text("\(outcome.capture.lines.count) lines of text read")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
    }

    private var noConfidentMatch: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("We couldn't confidently identify this wine", systemImage: "questionmark.circle")
                .font(.headline)
            Text("We won't guess facts about a wine we can't verify. Check the details read from the label below, then add it to the catalog.")
                .font(.callout)
                .foregroundStyle(Palette.secondaryText)
            Button("Review & add this wine", action: onManual).buttonStyle(.primary)
        }
        .cardSurface()
    }

    @ViewBuilder private var extractedFacts: some View {
        let facts = Self.facts(from: result.extraction)
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Read from your label").font(Typo.title3)
                    Spacer()
                    SourceBadge(source: .label)
                }
                ForEach(facts, id: \.0) { label, value in
                    LabeledContent(label, value: value).font(.subheadline)
                }
            }
            .cardSurface()
        }
    }

    private static func facts(from e: LabelExtraction) -> [(String, String)] {
        var rows: [(String, String?)] = []
        rows.append(("Producer", e.producer))
        rows.append(("Wine", e.wineName))
        rows.append(("Vintage", e.vintage.map { String($0) }))
        rows.append(("Style", e.type?.displayName))
        rows.append(("Grapes", e.grapes.isEmpty ? nil : e.grapes.joined(separator: ", ")))
        rows.append(("Appellation", e.appellation))
        rows.append(("Region", e.region))
        rows.append(("Country", e.country))
        rows.append(("ABV", e.abv.map { "\($0.formatted())%" }))
        rows.append(("Volume", e.volumeML.map { "\($0) ml" }))
        return rows.compactMap { label, value in value.map { (label, $0) } }
    }

    private func confirm(_ candidate: WineCandidate, _ useScannedVintage: Bool) {
        Task {
            if let wine = await model.confirm(candidate, in: outcome, useScannedVintage: useScannedVintage) {
                onIdentified(wine)
            }
        }
    }
}

private struct MatchCard: View {
    var candidate: WineCandidate
    var scannedVintage: Int?
    var isBusy: Bool
    var confirm: (_ useScannedVintage: Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            BottleStage(tint: Palette.wineColor(candidate.wine.type)) {
                BottleArtView(wine: candidate.wine, height: 200)
            }
            .frame(height: 230)
            VStack(spacing: 4) {
                Text(candidate.wine.name).font(Typo.title2).multilineTextAlignment(.center)
                Text("\(candidate.wine.producer) · \(candidate.wine.vintageLabel)")
                    .font(.subheadline).foregroundStyle(Palette.secondaryText)
                if !candidate.wine.locationLine.isEmpty {
                    Text(candidate.wine.locationLine).font(.caption).foregroundStyle(Palette.secondaryText)
                }
            }
            if candidate.vintageMismatch, let scannedVintage {
                VStack(spacing: 10) {
                    Label("Your label says \(String(scannedVintage)); our catalog has \(candidate.wine.vintageLabel).", systemImage: "calendar.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(Palette.warning)
                        .multilineTextAlignment(.center)
                    Button("Use the \(String(scannedVintage)) vintage") { confirm(true) }
                        .buttonStyle(.primary)
                        .disabled(isBusy)
                    Button("It's the \(candidate.wine.vintageLabel)") { confirm(false) }
                        .font(.subheadline.weight(.semibold))
                        .disabled(isBusy)
                }
            } else {
                Button(candidate.confidence == .high ? "View this wine" : "Yes, this is my wine") { confirm(false) }
                    .buttonStyle(.primary)
                    .disabled(isBusy)
            }
        }
        .cardSurface(padding: 20)
    }
}

/// AI tasting guidance — always visually distinct from verified facts.
struct AISuggestionCard: View {
    var suggestion: AITastingSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tasting suggestions").font(Typo.title3)
                Spacer()
                SourceBadge(source: .aiSuggested)
            }
            if let summary = suggestion.summary {
                Text(summary).font(.callout)
            }
            if let c = suggestion.characteristics {
                FlavorProfileView(characteristics: c)
            }
            if !suggestion.pairings.isEmpty {
                Text("Try with: " + suggestion.pairings.joined(separator: ", ")).font(.subheadline)
            }
            Text("Generated by AI from the label. Typical-style guidance, not verified facts about this bottle.")
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .cardSurface()
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.purple.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// Add a wine that isn't in the catalog, one question per screen:
/// name & producer → year & style → origin → bottle. Only the first screen is required,
/// and catalog matches show up as you type so people pick an existing wine instead of a duplicate.
struct ManualEntryView: View {
    enum Step: Int, CaseIterable { case name, style, origin, bottle }

    var prefill: WineDraft?
    var onSave: (WineDraft) async -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .name
    @State private var draft = WineDraft()
    @State private var grapesText = ""
    @State private var suggestions: [Wine] = []
    @State private var saving = false
    @State private var didPrefill = false
    @FocusState private var focus: Field?

    private enum Field { case name, producer }
    private static let sizes = [187, 375, 500, 750, 1000, 1500, 3000]
    private static let thisYear = Calendar.current.component(.year, from: .now)

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            TabView(selection: $step) {
                ForEach(Step.allCases, id: \.self) { page in
                    FitScroll {
                        content(for: page)
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.vertical, 16)
                    }
                    .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .background(Palette.cream.ignoresSafeArea())
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: step)
        .sensoryFeedback(.impact(weight: .light), trigger: step)
        .onChange(of: step) { focus = nil }
        .navigationTitle("Add a wine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).fontWeight(.semibold).disabled(!draft.isValid || saving)
            }
        }
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if let prefill {
                draft = prefill
                grapesText = prefill.grapes.joined(separator: ", ")
            }
            if draft.name.isEmpty { focus = .name }
        }
        .task(id: draft.name + draft.producer) {
            let text = [draft.producer, draft.name].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard text.count >= 3 else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            suggestions = (try? await env.catalog.search(WineSearchQuery(text: draft.name.isEmpty ? draft.producer : draft.name), limit: 6)) ?? []
        }
    }

    // MARK: Chrome

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.burgundy.opacity(0.12))
                Capsule().fill(Palette.burgundy)
                    .frame(width: max(8, geo.size.width * CGFloat(step.rawValue + 1) / CGFloat(Step.allCases.count)))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if step == .bottle || !draft.isValid && step != .name {
                Button(action: save) {
                    ZStack {
                        Text("Add wine").opacity(saving ? 0 : 1)
                        if saving { ProgressView().tint(.white) }
                    }
                }
                .buttonStyle(.primary)
                .disabled(!draft.isValid || saving)
                .opacity(draft.isValid ? 1 : 0.5)
                if !draft.isValid {
                    Button("Add a name and producer first") { step = .name }
                        .font(.footnote.weight(.semibold))
                }
            } else {
                Button("Next") { if let next = Step(rawValue: step.rawValue + 1) { step = next } }
                    .buttonStyle(.primary)
                    .disabled(step == .name && !draft.isValid)
                    .opacity(step == .name && !draft.isValid ? 0.5 : 1)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: Pages

    @ViewBuilder
    private func content(for page: Step) -> some View {
        switch page {
        case .name: namePage
        case .style: stylePage
        case .origin: originPage
        case .bottle: bottlePage
        }
    }

    private func title(_ eyebrow: String, _ text: String, _ hint: String? = nil) -> some View {
        VStack(spacing: 6) {
            Text(eyebrow).eyebrow()
            Text(text)
                .font(.system(.title, design: .serif).weight(.semibold))
                .foregroundStyle(Palette.charcoal)
            if let hint {
                Text(hint).font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.words)
            .padding(14)
            .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("The wine", "What are you drinking?")
            if draft.source == .label {
                Label("Filled in from your label. Give it a quick check.", systemImage: "text.viewfinder")
                    .font(.footnote).foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity)
            }
            field("Wine name", text: $draft.name)
                .focused($focus, equals: .name)
                .submitLabel(.next)
                .onSubmit { focus = .producer }
            field("Producer / winery", text: $draft.producer)
                .focused($focus, equals: .producer)
                .submitLabel(.next)
                .onSubmit { if draft.isValid { step = .style } }
            if !suggestions.isEmpty {
                Text("Already in Decant?").font(.headline).foregroundStyle(Palette.charcoal).padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(suggestions.prefix(4)) { wine in
                        NavigationLink(value: Route.wine(wine)) {
                            HStack {
                                WineRow(wine: wine)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondaryText)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if wine.id != suggestions.prefix(4).last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
    }

    private var stylePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Style", "Year & style")
            Text("Style").font(.headline).foregroundStyle(Palette.charcoal)
            FlowLayout(spacing: 8) {
                ForEach(WineType.allCases) { type in
                    Button { draft.type = type } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Palette.wineColor(type)).frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                            Text(type.displayName).font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(draft.type == type ? .white : Palette.charcoal)
                        .background(draft.type == type ? Palette.burgundy : Palette.creamElevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(draft.type == type ? .clear : Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.type == type ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: draft.type)
            Text("Vintage").font(.headline).foregroundStyle(Palette.charcoal).padding(.top, 6)
            Picker("Vintage", selection: $draft.vintage) {
                Text("Non-vintage").tag(Int?.none)
                ForEach((1950...Self.thisYear).reversed(), id: \.self) {
                    Text(String($0)).tag(Int?.some($0))
                }
            }
            .pickerStyle(.wheel)
            .frame(maxHeight: 150)
            .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var originPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Origin", "Where's it from?", "All optional. Skip what you don't know.")
            field("Country", text: $draft.country)
            field("Region", text: $draft.region)
            field("Appellation", text: $draft.appellation)
            field("Grapes (comma separated)", text: $grapesText)
        }
    }

    private var bottlePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Bottle", "The bottle", "Optional too.")
            Text("Size").font(.headline).foregroundStyle(Palette.charcoal)
            FlowLayout(spacing: 8) {
                ForEach(Self.sizes, id: \.self) { size in
                    Button { draft.bottleSizeML = size } label: {
                        Chip(title: size >= 1000 ? "\((Double(size) / 1000).formatted()) L" : "\(size) ml",
                             isSelected: draft.bottleSizeML == size)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                numberField("ABV %", value: $draft.abv)
                numberField("Price", value: $draft.priceAmount)
            }
            .padding(.top, 6)
        }
    }

    private func numberField(_ label: String, value: Binding<Double?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline).foregroundStyle(Palette.charcoal)
            TextField("Optional", value: value, format: .number)
                .keyboardType(.decimalPad)
                .padding(14)
                .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    private func save() {
        guard draft.isValid, !saving else { return }
        saving = true
        focus = nil
        var final = draft
        final.grapes = grapesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { await onSave(final); saving = false }
    }
}

struct ScanHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var records: Loadable<[ScanRecord]> = .idle

    var body: some View {
        Group {
            switch records {
            case .loaded(let list) where list.isEmpty:
                EmptyStateView(symbol: "viewfinder", title: "No scans yet", message: "Labels you scan will appear here.",
                               actionTitle: "Scan a label") { env.isScannerPresented = true }
            case .loaded(let list):
                List(list) { record in
                    NavigationLink(value: record.wineID.map(Route.wineID) ?? Route.scanHistory) {
                        HStack(spacing: 12) {
                            StoredImage(path: record.labelImagePath, maxPixel: 200) {
                                Rectangle().fill(Palette.hairline)
                            }
                            .scaledToFill()
                            .frame(width: 48, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.wineName ?? "Unidentified label").font(.headline)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }
                    .disabled(record.wineID == nil)
                }
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            default:
                ProgressView()
            }
        }
        .navigationTitle("Scan history")
        .task { await load() }
    }

    private func load() async {
        do { records = .loaded(try await env.scans.history(limit: 100)) } catch { records = .failed(error.localizedDescription) }
    }
}
