import PhotosUI
import SwiftUI

/// Edit photo, name, username, bio and favourite styles in one place. Nothing is
/// written until Save; a newly picked photo is uploaded as part of saving.
struct EditProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private let original: Profile
    @State private var draft: Profile
    @State private var pickedPhoto: UIImage?
    @State private var removesPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showsPicker = false
    @State private var showsPhotoOptions = false
    @State private var confirmsDiscard = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case name, username, bio }

    static let nameLimit = 60
    static let bioLimit = 280

    init(profile: Profile) {
        original = profile
        _draft = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    photoEditor
                    VStack(spacing: 0) {
                        nameField
                        Divider().padding(.leading, 16)
                        usernameField
                        Divider().padding(.leading, 16)
                        bioField
                    }
                    .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))

                    stylesSection

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Palette.burgundy)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(Metrics.gutter)
                .animation(.smooth(duration: 0.3), value: error)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isDirty ? (confirmsDiscard = true) : dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(isDirty || saving)
            .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog("Profile photo", isPresented: $showsPhotoOptions) {
                Button("Choose new photo") { showsPicker = true }
                Button("Remove photo", role: .destructive) {
                    withAnimation(.smooth) { pickedPhoto = nil; removesPhoto = true }
                }
            }
            .photosPicker(isPresented: $showsPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        withAnimation(.smooth) {
                            pickedPhoto = image.squareCropped(maxDimension: 800)
                            removesPhoto = false
                        }
                    } else {
                        error = "That photo couldn't be loaded. Try another one."
                    }
                    photoItem = nil
                }
            }
        }
    }

    // MARK: Photo

    private var hasPhoto: Bool { pickedPhoto != nil || (!removesPhoto && draft.avatarURL != nil) }

    private var photoEditor: some View {
        VStack(spacing: 12) {
            Button {
                if hasPhoto { showsPhotoOptions = true } else { showsPicker = true }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let pickedPhoto {
                            Image(uiImage: pickedPhoto).resizable().scaledToFill()
                                .frame(width: 112, height: 112).clipShape(Circle())
                        } else {
                            AvatarView(profile: previewProfile, size: 112)
                        }
                    }
                    .id(photoIdentity)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))

                    Image(systemName: "camera.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Palette.burgundy, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.cream, lineWidth: 3))
                        .offset(x: 2, y: 2)
                }
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityLabel(hasPhoto ? "Change or remove profile photo" : "Add profile photo")

            Button(hasPhoto ? "Change photo" : "Add photo") {
                if hasPhoto { showsPhotoOptions = true } else { showsPicker = true }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.burgundy)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var photoIdentity: String {
        if let pickedPhoto { return "picked-\(ObjectIdentifier(pickedPhoto).hashValue)" }
        return removesPhoto ? "none" : "current"
    }

    /// The draft as it will look, for the initials fallback.
    private var previewProfile: Profile {
        var p = draft
        if removesPhoto { p.avatarURL = nil }
        if p.displayName.trimmingCharacters(in: .whitespaces).isEmpty { p.displayName = p.username }
        return p
    }

    // MARK: Fields

    private var nameField: some View {
        fieldRow("Name", counter: draft.displayName.count, limit: Self.nameLimit, message: nameError) {
            TextField("Your name", text: $draft.displayName)
                .textContentType(.name)
                .submitLabel(.next)
                .focused($focus, equals: .name)
                .onSubmit { focus = .username }
                .onChange(of: draft.displayName) { _, new in
                    if new.count > Self.nameLimit { draft.displayName = String(new.prefix(Self.nameLimit)) }
                }
        }
    }

    private var usernameField: some View {
        fieldRow("Username", counter: nil, limit: nil, message: usernameError,
                 hint: usernameError == nil && draft.username != original.username ? "Your old username will be free for others to take." : nil) {
            HStack(spacing: 2) {
                Text("@").foregroundStyle(Palette.secondaryText)
                TextField("username", text: $draft.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .bio }
                    .onChange(of: draft.username) { _, new in
                        let cleaned = String(new.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }.prefix(30))
                        if cleaned != new { draft.username = cleaned }
                    }
            }
        }
    }

    private var bioField: some View {
        fieldRow("Bio", counter: (draft.bio ?? "").count, limit: Self.bioLimit, message: nil) {
            TextField("Tell people what you like to drink", text: Binding(
                get: { draft.bio ?? "" },
                set: { draft.bio = $0.isEmpty ? nil : String($0.prefix(Self.bioLimit)) }
            ), axis: .vertical)
            .lineLimit(2...6)
            .focused($focus, equals: .bio)
        }
    }

    private func fieldRow<Content: View>(_ title: String, counter: Int?, limit: Int?, message: String?, hint: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondaryText)
                Spacer()
                if let counter, let limit, counter > limit * 3 / 4 {
                    Text("\(counter)/\(limit)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(counter >= limit ? Palette.burgundy : Palette.secondaryText)
                        .contentTransition(.numericText())
                }
            }
            content().font(.body)
            if let message {
                Text(message).font(.caption).foregroundStyle(Palette.burgundy)
                    .transition(.opacity)
            } else if let hint {
                Text(hint).font(.caption).foregroundStyle(Palette.secondaryText)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.2), value: message)
    }

    private var stylesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorite styles").font(Typo.title3)
            FlowLayout {
                ForEach(WineType.allCases) { type in
                    let isOn = draft.favoriteTypes.contains(type)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if let i = draft.favoriteTypes.firstIndex(of: type) {
                                draft.favoriteTypes.remove(at: i)
                            } else {
                                draft.favoriteTypes.append(type)
                            }
                        }
                    } label: { Chip(title: type.displayName, isSelected: isOn) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: draft.favoriteTypes)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Validation & save

    private var trimmedName: String { draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameError: String? {
        trimmedName.isEmpty ? "Add a name so friends can find you." : nil
    }

    private var usernameError: String? {
        if draft.username.count < 3 { return "At least 3 characters." }
        if draft.username.first == "." || draft.username.last == "." { return "Can't start or end with a dot." }
        return nil
    }

    private var isDirty: Bool { draft != original || pickedPhoto != nil || removesPhoto }

    private var canSave: Bool { isDirty && nameError == nil && usernameError == nil && !saving }

    private func save() async {
        focus = nil
        saving = true
        error = nil
        defer { saving = false }
        var profile = draft
        profile.displayName = trimmedName
        profile.bio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        do {
            if let pickedPhoto {
                guard let jpeg = pickedPhoto.jpegForUpload(maxDimension: 600) else {
                    throw AppError.validation("That photo couldn't be prepared for upload.")
                }
                profile.avatarURL = try await env.auth.uploadAvatar(jpeg)
            } else if removesPhoto {
                profile.avatarURL = nil
            }
            let updated = try await env.auth.updateProfile(profile)
            env.currentUser = updated
            env.show("Profile updated")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension UIImage {
    /// Centre square crop, so the uploaded avatar matches what the circle shows.
    func squareCropped(maxDimension: CGFloat) -> UIImage {
        let side = min(size.width, size.height)
        let target = min(side, maxDimension)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let scale = target / side
            let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
            draw(in: CGRect(x: (target - drawSize.width) / 2, y: (target - drawSize.height) / 2,
                            width: drawSize.width, height: drawSize.height))
        }
    }
}
