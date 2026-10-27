import PhotosUI
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var profile: Profile?
    @State private var avatarItem: PhotosPickerItem?
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var deleteText = ""
    @State private var error: String?
    @State private var notificationsStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            if let binding = Binding($profile) {
                Section("Profile") {
                    HStack {
                        AvatarView(profile: binding.wrappedValue, size: 56)
                        PhotosPicker("Change photo", selection: $avatarItem, matching: .images)
                    }
                    TextField("Display name", text: binding.displayName)
                    TextField("Username", text: binding.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Bio", text: Binding(get: { binding.wrappedValue.bio ?? "" }, set: { binding.wrappedValue.bio = $0.nilIfBlank }), axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Toggle("Private profile", isOn: binding.isPrivate)
                    Picker("Default review visibility", selection: binding.defaultVisibility) {
                        ForEach(Visibility.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Private profiles approve followers. Your cellar is always private; private notes are only visible to you.")
                }
                Section("Favorite styles") {
                    FlowLayout {
                        ForEach(WineType.allCases) { type in
                            Button {
                                if let i = binding.wrappedValue.favoriteTypes.firstIndex(of: type) {
                                    binding.wrappedValue.favoriteTypes.remove(at: i)
                                } else {
                                    binding.wrappedValue.favoriteTypes.append(type)
                                }
                            } label: { Chip(title: type.displayName, isSelected: binding.wrappedValue.favoriteTypes.contains(type)) }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Button(saving ? "Saving…" : "Save changes") { Task { await save() } }
                        .disabled(saving || binding.wrappedValue == env.currentUser)
                    if let error { Text(error).font(.footnote).foregroundStyle(Palette.burgundy) }
                }
            }

            Section("Notifications") {
                switch notificationsStatus {
                case .authorized, .provisional, .ephemeral:
                    Label("Enabled", systemImage: "bell.badge")
                case .denied:
                    Button("Enable in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                default:
                    Button("Turn on notifications") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                            await refreshNotificationStatus()
                        }
                    }
                }
            }

            Section("Safety") {
                NavigationLink("Blocked accounts") { BlockedUsersView() }
                Link(destination: LegalLinks.guidelines) { Label("Community Guidelines", systemImage: "person.2.badge.gearshape") }
            }

            Section("Help & legal") {
                Link(destination: LegalLinks.support) { Label("Support", systemImage: "questionmark.circle") }
                Link(destination: LegalLinks.privacy) { Label("Privacy Policy", systemImage: "hand.raised") }
                Link(destination: LegalLinks.terms) { Label("Terms of Use", systemImage: "doc.text") }
            }

            Section("Your data") {
                NavigationLink("Scan history", value: Route.scanHistory)
                NavigationLink("Wishlist", value: Route.wishlist)
                LabeledContent("Storage", value: env.mode == .local ? "This device" : "Decant cloud")
            }

            Section {
                Text(env.mode.label).font(.footnote).foregroundStyle(Palette.secondaryText)
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            } header: {
                Text("About")
            }

            Section {
                Button("Sign out") { Task { await env.signOut() } }
                Button("Delete account…", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Deleting your account permanently removes your profile, diary, reviews, cellar, photos and scan history.")
            }
        }
        .brandedForm()
        .navigationTitle("Settings")
        .task {
            profile = env.currentUser
            await refreshNotificationStatus()
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                      let jpeg = image.jpegForUpload(maxDimension: 600) else { return }
                do {
                    let url = try await env.auth.uploadAvatar(jpeg)
                    profile?.avatarURL = url
                    await save()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            TextField("Type DELETE to confirm", text: $deleteText)
            Button("Delete forever", role: .destructive) {
                guard deleteText == "DELETE" else { return }
                Task {
                    do { try await env.deleteAccount() } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { deleteText = "" }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func refreshNotificationStatus() async {
        notificationsStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func save() async {
        guard let profile else { return }
        saving = true
        defer { saving = false }
        do {
            let updated = try await env.auth.updateProfile(profile)
            env.currentUser = updated
            self.profile = updated
            error = nil
            env.show("Profile updated")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
