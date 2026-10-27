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

/// Manual wine entry / correction, with catalog suggestions so users can
/// pick an existing wine instead of creating a duplicate.
struct ManualEntryView: View {
    var prefill: WineDraft?
    var onSave: (WineDraft) async -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var draft = WineDraft()
    @State private var grapesText = ""
    @State private var suggestions: [Wine] = []
    @State private var saving = false
    @State private var didPrefill = false

    var body: some View {
        Form {
            if !suggestions.isEmpty {
                Section("Already in the catalog?") {
                    ForEach(suggestions.prefix(4)) { wine in
                        NavigationLink(value: Route.wine(wine)) { WineRow(wine: wine) }
                    }
                }
            }
            Section("Wine") {
                TextField("Wine name", text: $draft.name).textInputAutocapitalization(.words)
                TextField("Producer / winery", text: $draft.producer).textInputAutocapitalization(.words)
                Picker("Vintage", selection: $draft.vintage) {
                    Text("Non-vintage").tag(Int?.none)
                    ForEach((1950...Calendar.current.component(.year, from: .now)).reversed(), id: \.self) {
                        Text(String($0)).tag(Int?.some($0))
                    }
                }
                Picker("Style", selection: $draft.type) {
                    ForEach(WineType.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Grapes (comma separated)", text: $grapesText)
            }
            Section("Origin") {
                TextField("Country", text: $draft.country)
                TextField("Region", text: $draft.region)
                TextField("Appellation", text: $draft.appellation)
            }
            Section("Bottle") {
                HStack {
                    Text("ABV %")
                    Spacer()
                    TextField("Optional", value: $draft.abv, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Picker("Size", selection: $draft.bottleSizeML) {
                    ForEach([187, 375, 500, 750, 1000, 1500, 3000], id: \.self) { Text("\($0) ml").tag($0) }
                }
                HStack {
                    Text("Price")
                    Spacer()
                    TextField("Optional", value: $draft.priceAmount, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
            }
            if draft.source == .label {
                Section {
                    Label("Fields were pre-filled from your label. Please check them.", systemImage: "text.viewfinder")
                        .font(.footnote).foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .brandedForm()
        .navigationTitle("Add a wine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    var final = draft
                    final.grapes = grapesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    Task { await onSave(final); saving = false }
                }
                .disabled(!draft.isValid || saving)
            }
        }
        .onAppear {
            guard !didPrefill, let prefill else { return }
            didPrefill = true
            draft = prefill
            grapesText = prefill.grapes.joined(separator: ", ")
        }
        .task(id: draft.name + draft.producer) {
            let text = [draft.producer, draft.name].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard text.count >= 3 else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            suggestions = (try? await env.catalog.search(WineSearchQuery(text: draft.name.isEmpty ? draft.producer : draft.name), limit: 6)) ?? []
        }
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
