import PhotosUI
import SwiftUI

/// Log a tasting, or edit one you already logged. The essentials (rating,
/// drink again, favourite, review, photos) are up front; everything else
/// is under "More details".
struct RateWineView: View {
    var wine: Wine
    /// When set, the sheet edits this entry instead of creating a new one.
    var editing: TastingEntry?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TastingDraft()
    @State private var original = TastingDraft()
    @State private var friends: [Profile] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var newPhotos: [UIImage] = []
    @State private var showsDetails = false
    @State private var saving = false
    @State private var error: String?
    @State private var savedEntry: TastingEntry?
    /// Set once a new tasting is created, so extra taps on Save can't post it again.
    @State private var didSave = false
    @State private var confirmsDiscard = false

    private static let maxPhotos = 4

    init(wine: Wine, editing: TastingEntry? = nil) {
        self.wine = wine
        self.editing = editing
    }

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
                        Text(draft.rating.map { ratingWord($0) } ?? "Tap or slide to rate")
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

                Section("Photos") { photoStrip }

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
                    if editing == nil {
                        Toggle(isOn: $draft.addToCellar) { Label("Also add a bottle to my cellar", systemImage: "square.stack.3d.up") }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(Palette.burgundy) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .brandedForm()
            .navigationTitle(editing == nil ? "Log a tasting" : "Edit tasting")
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
                        Text(editing == nil ? "Save to diary" : "Save changes").opacity(saving ? 0 : 1)
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
            .confirmationDialog(editing == nil ? "Discard this tasting?" : "Discard your changes?",
                                isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                           draft.photoPaths.count + newPhotos.count < Self.maxPhotos {
                            withAnimation(.smooth) { newPhotos.append(image) }
                        }
                    }
                    photoItems = []
                }
            }
            .task {
                if let editing {
                    draft = TastingDraft(entry: editing)
                    showsDetails = editing.location != nil || editing.occasion != nil || editing.personalNotes != nil
                        || !editing.taggedUserIDs.isEmpty
                } else {
                    draft.visibility = env.currentUser?.defaultVisibility ?? .everyone
                }
                original = draft
                if let me = env.currentUser { friends = (try? await env.social.following(of: me.id)) ?? [] }
            }
            .sheet(item: $savedEntry, onDismiss: { dismiss() }) { entry in
                ShareWineSheet(wine: wine, rating: entry.rating, review: entry.review)
            }
            .sensoryFeedback(.success, trigger: savedEntry != nil)
            .sensoryFeedback(.selection, trigger: draft.rating)
        }
    }

    // MARK: Quick choices

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

    // MARK: Photos

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(draft.photoPaths, id: \.self) { path in
                    thumbnail {
                        StoredImage(path: path, maxPixel: 240) { Rectangle().fill(Palette.hairline) }.scaledToFill()
                    } remove: {
                        withAnimation(.smooth) { draft.photoPaths.removeAll { $0 == path } }
                    }
                }
                ForEach(Array(newPhotos.enumerated()), id: \.offset) { index, image in
                    thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } remove: {
                        withAnimation(.smooth) { _ = newPhotos.remove(at: index) }
                    }
                }
                let remaining = Self.maxPhotos - draft.photoPaths.count - newPhotos.count
                if remaining > 0 {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: remaining, matching: .images) {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.fill").font(.title3)
                            Text("Add").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Palette.burgundy)
                        .frame(width: 72, height: 72)
                        .background(Palette.burgundy.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.burgundy.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .accessibilityLabel("Add photos")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func thumbnail<Content: View>(@ViewBuilder _ content: () -> Content, remove: @escaping () -> Void) -> some View {
        content()
            .frame(width: 72, height: 72)
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

    // MARK: State

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
        guard !saving, !didSave else { return false }
        let hasContent = draft.rating != nil || draft.review.nilIfBlank != nil || draft.personalNotes.nilIfBlank != nil
        return hasContent && (editing == nil || isDirty)
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
            if var entry = editing {
                entry.apply(final)
                try await env.tastings.updateEntry(entry)
                env.diaryRevision += 1
                env.show("Tasting updated", symbol: "book.closed.fill")
                dismiss()
                return
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
