import PhotosUI
import SwiftUI

/// Log a tasting, or edit one you already logged. New tastings use the
/// one-question-per-screen flow; edits use the full form.
struct RateWineView: View {
    var wine: Wine
    /// When set, the sheet edits this entry instead of creating a new one.
    var editing: TastingEntry?

    init(wine: Wine, editing: TastingEntry? = nil) {
        self.wine = wine
        self.editing = editing
    }

    var body: some View {
        if let editing {
            TastingForm(wine: wine, editing: editing)
        } else {
            QuickLogFlow(wine: wine)
        }
    }
}

// MARK: - Quick log (new tastings)

/// Swipe through: rating → drink again → a few words → photo → details.
/// Only the rating matters; every later screen can be skipped, and Save is always one tap away.
private struct QuickLogFlow: View {
    enum Step: Int, CaseIterable {
        case rating, verdict, words, photos, details
    }

    var wine: Wine
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .rating
    @State private var draft = TastingDraft()
    @State private var original = TastingDraft()
    @State private var friends: [Profile] = []
    @State private var newPhotos: [UIImage] = []
    @State private var saving = false
    @State private var didSave = false
    @State private var error: String?
    @State private var savedEntry: TastingEntry?
    @State private var confirmsDiscard = false
    @State private var autoAdvance: Task<Void, Never>?
    @FocusState private var typing: Bool

    private static let notes = ["Fruity", "Dry", "Smooth", "Bold", "Crisp", "Oaky", "Earthy", "Sweet", "Light", "Spicy", "Tannic", "Buttery"]
    private static let occasions = ["Dinner", "Date night", "With friends", "Celebration", "Tasting", "Just because"]

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .onChange(of: step) { typing = false }
        .interactiveDismissDisabled(isDirty || saving)
        .confirmationDialog("Discard this tasting?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep going", role: .cancel) {}
        }
        .task {
            draft.visibility = env.currentUser?.defaultVisibility ?? .everyone
            original = draft
            if let me = env.currentUser { friends = (try? await env.social.following(of: me.id)) ?? [] }
        }
        .sheet(item: $savedEntry, onDismiss: { dismiss() }) { entry in
            ShareWineSheet(wine: wine, rating: entry.rating, review: entry.review)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: step)
        .sensoryFeedback(.success, trigger: savedEntry != nil)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            Button { isDirty ? (confirmsDiscard = true) : dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(Palette.burgundy.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Cancel")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.burgundy.opacity(0.12))
                    Capsule().fill(Palette.burgundy)
                        .frame(width: max(8, geo.size.width * progress))
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            Button("Save") { Task { await save() } }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 38, minHeight: 38)
                .opacity(canSave && step != .details ? 1 : 0)
                .disabled(!canSave || step == .details)
        }
        .foregroundStyle(Palette.burgundy)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var progress: CGFloat {
        CGFloat(step.rawValue + 1) / CGFloat(Step.allCases.count)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error).font(.footnote).foregroundStyle(Palette.burgundy).multilineTextAlignment(.center)
            }
            if step == .details {
                Button { Task { await save() } } label: {
                    ZStack {
                        Text("Save to diary").opacity(saving ? 0 : 1)
                        if saving { ProgressView().tint(.white) }
                    }
                }
                .buttonStyle(.primary)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
                if !canSave, !didSave {
                    Text("Add a rating or a few words to save.")
                        .font(.footnote).foregroundStyle(Palette.secondaryText)
                }
            } else {
                Button(stepHasAnswer ? "Next" : "Skip", action: next)
                    .buttonStyle(stepHasAnswer ? AnyButtonStyle(.primary) : AnyButtonStyle(.secondary))
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.smooth(duration: 0.2), value: stepHasAnswer)
    }

    // MARK: Pages

    @ViewBuilder
    private func content(for page: Step) -> some View {
        switch page {
        case .rating: ratingPage
        case .verdict: verdictPage
        case .words: wordsPage
        case .photos: photosPage
        case .details: detailsPage
        }
    }

    private func title(_ eyebrow: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Text(eyebrow).eyebrow()
            Text(text)
                .font(.system(.title, design: .serif).weight(.semibold))
                .foregroundStyle(Palette.charcoal)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var ratingPage: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            BottleArtView(wine: wine, height: 150)
            VStack(spacing: 4) {
                Text(wine.name)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Palette.charcoal)
                Text("\(wine.producer) · \(wine.vintageLabel)")
                    .font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
            .multilineTextAlignment(.center)
            Text("How was it?")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Palette.charcoal)
            StarRatingPicker(rating: $draft.rating, size: 46)
            Text(draft.rating.map(ratingWord) ?? "Tap or slide across the stars")
                .font(.headline)
                .foregroundStyle(draft.rating == nil ? Palette.secondaryText : Palette.burgundy)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.2), value: draft.rating)
            Spacer(minLength: 0)
        }
        .onChange(of: draft.rating) { _, rating in
            // Advance once they stop sliding, so a half-star adjustment doesn't jump ahead.
            guard rating != nil else { return }
            scheduleAdvance(from: .rating, after: 0.9)
        }
    }

    private var verdictPage: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            title("Verdict", "Would you drink it again?")
            HStack(spacing: 12) {
                verdictCard("Yes", symbol: "hand.thumbsup", isOn: draft.drinkAgain == true) {
                    draft.drinkAgain = draft.drinkAgain == true ? nil : true
                }
                verdictCard("No", symbol: "hand.thumbsdown", isOn: draft.drinkAgain == false) {
                    draft.drinkAgain = draft.drinkAgain == false ? nil : false
                }
            }
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { draft.isFavorite.toggle() }
            } label: {
                Chip(title: draft.isFavorite ? "One of my favorites" : "Mark as a favorite",
                     isSelected: draft.isFavorite, systemImage: draft.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: draft.isFavorite)
            Spacer(minLength: 0)
        }
    }

    private func verdictCard(_ label: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { action() }
            if draft.drinkAgain != nil { scheduleAdvance(from: .verdict, after: 0.45) }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: isOn ? symbol + ".fill" : symbol).font(.system(size: 34))
                Text(label).font(.headline)
            }
            .foregroundStyle(isOn ? .white : Palette.burgundy)
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(isOn ? Palette.burgundy : Palette.creamElevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isOn ? .clear : Palette.hairline, lineWidth: 1))
            .scaleEffect(isOn ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }

    private var wordsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Notes", "Any thoughts?")
            Text("Tap a few words, or write your own.")
                .font(.subheadline).foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity)
            FlowLayout(spacing: 8) {
                ForEach(Self.notes, id: \.self) { word in
                    Button { toggleNote(word) } label: { Chip(title: word, isSelected: hasNote(word)) }
                        .buttonStyle(.plain)
                }
            }
            TextField("What did you think?", text: $draft.review, axis: .vertical)
                .lineLimit(3...8)
                .focused($typing)
                .padding(14)
                .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            Picker("Visible to", selection: $draft.visibility) {
                ForEach(Visibility.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(visibilityHint).font(.caption).foregroundStyle(Palette.secondaryText)
        }
    }

    private var photosPage: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            title("Photos", "Snap the moment")
            Text("The bottle, the glass, the table. Up to \(TastingPhotoStrip.maxPhotos).")
                .font(.subheadline).foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
            TastingPhotoStrip(paths: $draft.photoPaths, newPhotos: $newPhotos, size: 96)
            Spacer(minLength: 0)
        }
    }

    private var detailsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Details", "When & where")
            DatePicker("When", selection: $draft.consumedOn, in: ...Date.now, displayedComponents: .date)
                .font(.headline)
                .tint(Palette.burgundy)
            TextField("Where (restaurant, winery, home…)", text: $draft.location)
                .focused($typing)
                .padding(14)
                .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))

            Text("Occasion").font(.headline).foregroundStyle(Palette.charcoal)
            FlowLayout(spacing: 8) {
                ForEach(Self.occasions, id: \.self) { occasion in
                    Button { draft.occasion = draft.occasion == occasion ? "" : occasion } label: {
                        Chip(title: occasion, isSelected: draft.occasion == occasion)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !friends.isEmpty {
                Text("Who were you with?").font(.headline).foregroundStyle(Palette.charcoal)
                FlowLayout(spacing: 8) {
                    ForEach(friends) { friend in
                        let isOn = draft.taggedUserIDs.contains(friend.id)
                        Button {
                            if isOn { draft.taggedUserIDs.removeAll { $0 == friend.id } } else { draft.taggedUserIDs.append(friend.id) }
                        } label: {
                            HStack(spacing: 6) {
                                AvatarView(profile: friend, size: 24)
                                Text(friend.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                            }
                            .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
                            .foregroundStyle(isOn ? .white : Palette.charcoal)
                            .background(isOn ? Palette.burgundy : Palette.creamElevated, in: Capsule())
                            .overlay(Capsule().strokeBorder(isOn ? .clear : Palette.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }

            Toggle(isOn: $draft.addToCellar) {
                Label("Also add a bottle to my cellar", systemImage: "square.stack.3d.up")
            }
            .tint(Palette.burgundy)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Private notes, just for you", text: $draft.personalNotes, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($typing)
                    .padding(14)
                    .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                Label("Only you can see these.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
    }

    // MARK: Logic

    private var stepHasAnswer: Bool {
        switch step {
        case .rating: draft.rating != nil
        case .verdict: draft.drinkAgain != nil || draft.isFavorite
        case .words: draft.review.nilIfBlank != nil
        case .photos: !draft.photoPaths.isEmpty || !newPhotos.isEmpty
        case .details: true
        }
    }

    private var visibilityHint: String {
        switch draft.visibility {
        case .everyone: "Anyone on Decant can see your rating and notes."
        case .friends: "Only people who follow you can see this."
        case .onlyMe: "Just for your diary."
        }
    }

    private func next() {
        autoAdvance?.cancel()
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    private func scheduleAdvance(from page: Step, after seconds: Double) {
        autoAdvance?.cancel()
        autoAdvance = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, step == page else { return }
            next()
        }
    }

    private var noteParts: [String] {
        draft.review.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func hasNote(_ word: String) -> Bool {
        noteParts.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    private func toggleNote(_ word: String) {
        var parts = noteParts
        if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            parts.remove(at: i)
            if let first = parts.first { parts[0] = first.prefix(1).uppercased() + first.dropFirst() }
        } else {
            parts.append(parts.isEmpty ? word : word.lowercased())
        }
        withAnimation(.snappy(duration: 0.2)) { draft.review = parts.joined(separator: ", ") }
    }

    private var isDirty: Bool { draft != original || !newPhotos.isEmpty }

    private var canSave: Bool {
        guard !saving, !didSave else { return false }
        return draft.rating != nil || draft.review.nilIfBlank != nil || draft.personalNotes.nilIfBlank != nil
    }

    private func save() async {
        guard canSave else { return }
        autoAdvance?.cancel()
        typing = false
        saving = true
        error = nil
        defer { saving = false }
        do {
            var final = draft
            for image in newPhotos {
                if let jpeg = image.jpegForUpload(maxDimension: 1600) {
                    final.photoPaths.append(try await env.media.storePhoto(jpeg, id: UUID()))
                }
            }
            let entry = try await env.tastings.addEntry(for: wine.id, draft: final)
            didSave = true
            if final.addToCellar {
                _ = try await env.cellar.addBottle(wineID: wine.id, draft: CellarBottleDraft())
                env.cellarRevision += 1
            }
            env.diaryRevision += 1
            env.show(final.addToCellar ? "Saved to your diary and cellar" : "Saved to your diary", symbol: "book.closed.fill")
            if entry.rating != nil {
                savedEntry = entry // offer to share
            } else {
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Lets the footer swap between primary and secondary styles.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private func ratingWord(_ rating: Double) -> String {
    switch rating {
    case ..<1.5: "Not for me"
    case ..<2.5: "Disappointing"
    case ..<3.5: "Good"
    case ..<4.5: "Excellent"
    default: "Unforgettable"
    }
}

// MARK: - Photos

/// Existing photo paths plus newly picked images, with an Add tile until the limit.
struct TastingPhotoStrip: View {
    @Binding var paths: [String]
    @Binding var newPhotos: [UIImage]
    var size: CGFloat = 72
    @State private var items: [PhotosPickerItem] = []

    static let maxPhotos = 4

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(paths, id: \.self) { path in
                    thumbnail {
                        StoredImage(path: path, maxPixel: 240) { Rectangle().fill(Palette.hairline) }.scaledToFill()
                    } remove: {
                        withAnimation(.smooth) { paths.removeAll { $0 == path } }
                    }
                }
                ForEach(Array(newPhotos.enumerated()), id: \.offset) { index, image in
                    thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } remove: {
                        withAnimation(.smooth) { _ = newPhotos.remove(at: index) }
                    }
                }
                let remaining = Self.maxPhotos - paths.count - newPhotos.count
                if remaining > 0 {
                    PhotosPicker(selection: $items, maxSelectionCount: remaining, matching: .images) {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.fill").font(.title3)
                            Text("Add").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Palette.burgundy)
                        .frame(width: size, height: size)
                        .background(Palette.burgundy.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.burgundy.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .accessibilityLabel("Add photos")
                }
            }
            .padding(.vertical, 4)
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       paths.count + newPhotos.count < Self.maxPhotos {
                        withAnimation(.smooth) { newPhotos.append(image) }
                    }
                }
                items = []
            }
        }
    }

    private func thumbnail<Content: View>(@ViewBuilder _ content: () -> Content, remove: @escaping () -> Void) -> some View {
        content()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Remove photo")
            }
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Full form (editing)

/// Every field on one screen; used to edit a tasting you already logged.
private struct TastingForm: View {
    var wine: Wine
    var editing: TastingEntry
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TastingDraft()
    @State private var original = TastingDraft()
    @State private var friends: [Profile] = []
    @State private var newPhotos: [UIImage] = []
    @State private var showsDetails = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmsDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        HStack(spacing: 14) {
                            BottleArtView(wine: wine, height: 86)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(wine.name).font(.system(.headline, design: .serif))
                                Text("\(wine.producer) · \(wine.vintageLabel)").font(.subheadline).foregroundStyle(Palette.secondaryText)
                            }
                            Spacer()
                        }
                        StarRatingPicker(rating: $draft.rating)
                        Text(draft.rating.map(ratingWord) ?? "Tap or slide to rate")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(draft.rating == nil ? Palette.secondaryText : Palette.burgundy)
                            .contentTransition(.opacity)
                            .animation(.smooth(duration: 0.2), value: draft.rating)
                        quickChoices
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    TextField("What did you think?", text: $draft.review, axis: .vertical)
                        .lineLimit(3...8)
                    Picker("Visible to", selection: $draft.visibility) {
                        ForEach(Visibility.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                    }
                } header: {
                    Text("Review")
                }

                Section("Photos") { TastingPhotoStrip(paths: $draft.photoPaths, newPhotos: $newPhotos) }

                Section {
                    DisclosureGroup(isExpanded: $showsDetails.animation(.smooth)) {
                        DatePicker("Date", selection: $draft.consumedOn, in: ...Date.now, displayedComponents: .date)
                        TextField("Where (restaurant, winery, home…)", text: $draft.location)
                        TextField("Occasion", text: $draft.occasion)
                        if !friends.isEmpty {
                            NavigationLink {
                                FriendTagPicker(friends: friends, selection: $draft.taggedUserIDs)
                            } label: {
                                LabeledContent("Tag friends", value: draft.taggedUserIDs.isEmpty ? "None" : "\(draft.taggedUserIDs.count) tagged")
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Private notes, just for you", text: $draft.personalNotes, axis: .vertical)
                                .lineLimit(2...6)
                            Label("Only you can see these.", systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(Palette.secondaryText)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("More details").foregroundStyle(Palette.charcoal)
                            if !showsDetails, let summary = detailsSummary {
                                Text(summary).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                            }
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(Palette.burgundy) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .brandedForm()
            .navigationTitle("Edit tasting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isDirty ? (confirmsDiscard = true) : dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.fontWeight(.semibold).disabled(!canSave)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { Task { await save() } } label: {
                    ZStack {
                        Text("Save changes").opacity(saving ? 0 : 1)
                        if saving { ProgressView().tint(.white) }
                    }
                }
                .buttonStyle(.primary)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 10)
                .background(.bar)
                .animation(.smooth(duration: 0.2), value: canSave)
            }
            .interactiveDismissDisabled(isDirty || saving)
            .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .task {
                draft = TastingDraft(entry: editing)
                showsDetails = editing.location != nil || editing.occasion != nil || editing.personalNotes != nil
                    || !editing.taggedUserIDs.isEmpty
                original = draft
                if let me = env.currentUser { friends = (try? await env.social.following(of: me.id)) ?? [] }
            }
            .sensoryFeedback(.selection, trigger: draft.rating)
        }
    }

    private var quickChoices: some View {
        HStack(spacing: 8) {
            choice("Again", symbol: "hand.thumbsup", isOn: draft.drinkAgain == true) {
                draft.drinkAgain = draft.drinkAgain == true ? nil : true
            }
            choice("Not again", symbol: "hand.thumbsdown", isOn: draft.drinkAgain == false) {
                draft.drinkAgain = draft.drinkAgain == false ? nil : false
            }
            choice("Favorite", symbol: "heart", isOn: draft.isFavorite) { draft.isFavorite.toggle() }
        }
        .sensoryFeedback(.selection, trigger: draft.drinkAgain)
        .sensoryFeedback(.impact(weight: .light), trigger: draft.isFavorite)
    }

    private func choice(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { action() }
        } label: {
            Label(title, systemImage: isOn ? symbol + ".fill" : symbol)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(isOn ? .white : Palette.burgundy)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(isOn ? Palette.burgundy : Palette.burgundy.opacity(0.08), in: Capsule())
                .scaleEffect(isOn ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var detailsSummary: String? {
        var parts: [String] = []
        if !Calendar.current.isDateInToday(draft.consumedOn) {
            parts.append(draft.consumedOn.formatted(date: .abbreviated, time: .omitted))
        }
        if let place = draft.location.nilIfBlank { parts.append(place) }
        if let occasion = draft.occasion.nilIfBlank { parts.append(occasion) }
        if !draft.taggedUserIDs.isEmpty { parts.append("\(draft.taggedUserIDs.count) tagged") }
        if draft.personalNotes.nilIfBlank != nil { parts.append("Private note") }
        return parts.isEmpty ? "Date, place, friends, private notes" : parts.joined(separator: " · ")
    }

    private var isDirty: Bool { draft != original || !newPhotos.isEmpty }

    private var canSave: Bool {
        guard !saving else { return false }
        let hasContent = draft.rating != nil || draft.review.nilIfBlank != nil || draft.personalNotes.nilIfBlank != nil
        return hasContent && isDirty
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        do {
            var final = draft
            for image in newPhotos {
                if let jpeg = image.jpegForUpload(maxDimension: 1600) {
                    final.photoPaths.append(try await env.media.storePhoto(jpeg, id: UUID()))
                }
            }
            var entry = editing
            entry.apply(final)
            try await env.tastings.updateEntry(entry)
            env.diaryRevision += 1
            env.show("Tasting updated", symbol: "book.closed.fill")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension TastingDraft {
    init(entry: TastingEntry) {
        self.init(rating: entry.rating, review: entry.review ?? "", personalNotes: entry.personalNotes ?? "",
                  photoPaths: entry.photoPaths, consumedOn: entry.consumedOn, location: entry.location ?? "",
                  occasion: entry.occasion ?? "", taggedUserIDs: entry.taggedUserIDs, drinkAgain: entry.drinkAgain,
                  isFavorite: entry.isFavorite, visibility: entry.visibility)
    }
}

extension TastingEntry {
    mutating func apply(_ draft: TastingDraft) {
        rating = draft.rating.map(TastingEntry.normalizedRating)
        review = draft.review.nilIfBlank
        personalNotes = draft.personalNotes.nilIfBlank
        photoPaths = draft.photoPaths
        consumedOn = draft.consumedOn
        location = draft.location.nilIfBlank
        occasion = draft.occasion.nilIfBlank
        taggedUserIDs = draft.taggedUserIDs
        drinkAgain = draft.drinkAgain
        isFavorite = draft.isFavorite
        visibility = draft.visibility
    }
}

private struct FriendTagPicker: View {
    var friends: [Profile]
    @Binding var selection: [UUID]

    var body: some View {
        List(friends) { friend in
            Button {
                if let i = selection.firstIndex(of: friend.id) { selection.remove(at: i) } else { selection.append(friend.id) }
            } label: {
                HStack {
                    AvatarView(profile: friend, size: 34)
                    VStack(alignment: .leading) {
                        Text(friend.displayName).foregroundStyle(Palette.charcoal)
                        Text("@\(friend.username)").font(.caption).foregroundStyle(Palette.secondaryText)
                    }
                    Spacer()
                    if selection.contains(friend.id) { Image(systemName: "checkmark").foregroundStyle(Palette.burgundy) }
                }
            }
            .accessibilityAddTraits(selection.contains(friend.id) ? .isSelected : [])
        }
        .navigationTitle("Tag friends")
    }
}
