import PhotosUI
import SwiftUI

/// Log a tasting: rating, review, private notes, photos, date, place, friends.
struct RateWineView: View {
    var wine: Wine
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TastingDraft()
    @State private var friends: [Profile] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [UIImage] = []
    @State private var saving = false
    @State private var error: String?
    @State private var savedEntry: TastingEntry?
    @FocusState private var reviewFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
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
                            .foregroundStyle(Palette.secondaryText)
                            .animation(.none, value: draft.rating)
                    }
                    .padding(.vertical, 6)
                }

                Section("Review") {
                    TextField("What did you think?", text: $draft.review, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($reviewFocused)
                    Picker("Visible to", selection: $draft.visibility) {
                        ForEach(Visibility.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                    }
                }

                Section {
                    TextField("Tasting notes just for you", text: $draft.personalNotes, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Private notes")
                } footer: {
                    Label("Only you can see these.", systemImage: "lock.fill")
                }

                Section("The moment") {
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
                    let photoTitle = photos.isEmpty ? "Add photos" : "\(photos.count) photo\(photos.count == 1 ? "" : "s") added"
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                        Label(photoTitle, systemImage: "camera")
                    }
                    if !photos.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(Array(photos.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }

                Section {
                    Picker("Would drink again", selection: $draft.drinkAgain) {
                        Text("–").tag(Bool?.none)
                        Text("Yes").tag(Bool?.some(true))
                        Text("No").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    Toggle(isOn: $draft.isFavorite) { Label("Favorite", systemImage: "heart") }
                    Toggle(isOn: $draft.addToCellar) { Label("Also add a bottle to my cellar", systemImage: "square.stack.3d.up") }
                } header: {
                    Text("Would you drink it again?")
                }

                if let error {
                    Section { Text(error).foregroundStyle(Palette.burgundy) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .brandedForm()
            .navigationTitle("Log a tasting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || (draft.rating == nil && draft.review.isEmpty && draft.personalNotes.isEmpty))
                }
            }
            .onChange(of: photoItems) { _, items in
                Task {
                    var loaded: [UIImage] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { loaded.append(image) }
                    }
                    photos = loaded
                }
            }
            .task {
                draft.visibility = env.currentUser?.defaultVisibility ?? .everyone
                if let me = env.currentUser { friends = (try? await env.social.following(of: me.id)) ?? [] }
            }
            .sheet(item: $savedEntry, onDismiss: { dismiss() }) { entry in
                ShareWineSheet(wine: wine, rating: entry.rating, review: entry.review)
            }
            .sensoryFeedback(.success, trigger: savedEntry != nil)
        }
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
        saving = true
        defer { saving = false }
        do {
            var final = draft
            for image in photos {
                if let jpeg = image.jpegForUpload(maxDimension: 1600) {
                    final.photoPaths.append(try await env.media.storePhoto(jpeg, id: UUID()))
                }
            }
            let entry = try await env.tastings.addEntry(for: wine.id, draft: final)
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
