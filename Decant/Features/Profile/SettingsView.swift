import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isPrivate = false
    @State private var defaultVisibility: Visibility = .everyone
    @State private var loaded = false
    @State private var editingProfile = false
    @State private var confirmDelete = false
    @State private var deleteText = ""
    @State private var error: String?
    @State private var notificationsStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            if let me = env.currentUser {
                Section {
                    Button { editingProfile = true } label: {
                        HStack(spacing: 14) {
                            AvatarView(profile: me, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(me.displayName).font(.headline).foregroundStyle(Palette.charcoal)
                                Text("@\(me.username)").font(.subheadline).foregroundStyle(Palette.secondaryText)
                            }
                            Spacer()
                            Text("Edit").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.burgundy)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit photo, name, username and bio")
                }

                Section {
                    Toggle("Private profile", isOn: $isPrivate)
                    Picker("Default review visibility", selection: $defaultVisibility) {
                        ForEach(Visibility.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Private profiles approve followers. Your cellar is always private; private notes are only visible to you.")
                        if let error { Text(error).foregroundStyle(Palette.burgundy) }
                    }
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

            Section {
                // Required by CC BY 4.0: credit, licence link, and a note that the data was adapted.
                Link(destination: URL(string: "https://www.liv-ex.com/lwin/")!) {
                    Label("Wine identities: LWIN by Liv-ex", systemImage: "books.vertical")
                }
                Link(destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!) {
                    Label("Licensed under CC BY 4.0", systemImage: "c.circle")
                }
            } header: {
                Text("Data sources")
            } footer: {
                Text("Producer, wine, region and colour data comes from the LWIN database, adapted to Decant's catalog. Ratings come only from Decant members.")
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
        .sheet(isPresented: $editingProfile) {
            if let me = env.currentUser { EditProfileView(profile: me) }
        }
        .task {
            if let me = env.currentUser {
                isPrivate = me.isPrivate
                defaultVisibility = me.defaultVisibility
            }
            loaded = true
            await refreshNotificationStatus()
        }
        .onChange(of: isPrivate) { savePrivacy() }
        .onChange(of: defaultVisibility) { savePrivacy() }
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

    /// Privacy settings save as soon as they change; on failure they snap back.
    private func savePrivacy() {
        guard loaded, var profile = env.currentUser,
              profile.isPrivate != isPrivate || profile.defaultVisibility != defaultVisibility else { return }
        profile.isPrivate = isPrivate
        profile.defaultVisibility = defaultVisibility
        Task {
            do {
                env.currentUser = try await env.auth.updateProfile(profile)
                error = nil
            } catch {
                self.error = error.localizedDescription
                if let me = env.currentUser {
                    isPrivate = me.isPrivate
                    defaultVisibility = me.defaultVisibility
                }
            }
        }
    }
}
