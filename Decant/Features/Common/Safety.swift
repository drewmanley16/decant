import SwiftUI

/// Public pages required by the App Store (privacy policy, terms, support).
enum LegalLinks {
    static let base = URL(string: "https://drewmanley16.github.io/decant-legal")!
    static let privacy = base.appendingPathComponent("privacy.html")
    static let terms = base.appendingPathComponent("terms.html")
    static let guidelines = URL(string: "https://drewmanley16.github.io/decant-legal/terms.html#community-guidelines")!
    static let support = base.appendingPathComponent("support.html")
}

/// Pick a reason and file a report. The reported item disappears for the reporter right away.
struct ReportSheet: View {
    var target: ReportTarget
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var alsoBlock = false
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ReportReason.allCases) { option in
                        Button {
                            reason = option
                        } label: {
                            HStack {
                                Text(option.label).foregroundStyle(Palette.charcoal)
                                Spacer()
                                if reason == option { Image(systemName: "checkmark").foregroundStyle(Palette.burgundy) }
                            }
                        }
                        .accessibilityAddTraits(reason == option ? .isSelected : [])
                    }
                } header: {
                    Text("Why are you reporting this \(target.noun)?")
                }
                Section("Anything else? (optional)") {
                    TextField("Add details for our moderators", text: $details, axis: .vertical).lineLimit(2...5)
                }
                if target.authorID != env.currentUser?.id {
                    Section {
                        Toggle("Also block this account", isOn: $alsoBlock)
                    } footer: {
                        Text("Reports are anonymous. We review every report within 24 hours and remove content that breaks our Community Guidelines.")
                    }
                }
            }
            .brandedForm()
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit() } }.disabled(reason == nil || sending)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func submit() async {
        guard let reason else { return }
        sending = true
        defer { sending = false }
        do {
            try await env.social.report(target, reason: reason, details: details)
            if alsoBlock { try await env.social.block(target.authorID) }
            env.moderationRevision += 1
            env.show("Thanks — we'll review this", symbol: "flag.fill")
            dismiss()
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }
}

/// "…" menu for content written by someone else.
struct SafetyMenu: View {
    var target: ReportTarget
    var authorName: String
    @Environment(AppEnvironment.self) private var env
    @State private var reporting = false
    @State private var confirmBlock = false

    var body: some View {
        if target.authorID != env.currentUser?.id {
            Menu {
                Button { reporting = true } label: { Label("Report \(target.noun)", systemImage: "flag") }
                Button(role: .destructive) { confirmBlock = true } label: { Label("Block \(authorName)", systemImage: "hand.raised") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options")
            .sheet(isPresented: $reporting) { ReportSheet(target: target) }
            .confirmationDialog("Block \(authorName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { Task { await BlockAction.block(target.authorID, name: authorName, env: env) } }
            } message: {
                Text("They won't be able to see your profile or content, and you won't see theirs. They aren't notified.")
            }
        }
    }
}

@MainActor
enum BlockAction {
    static func block(_ userID: UUID, name: String, env: AppEnvironment) async {
        do {
            try await env.social.block(userID)
            env.moderationRevision += 1
            env.show("Blocked \(name)", symbol: "hand.raised.fill")
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }
}

struct BlockedUsersView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var people: Loadable<[Profile]> = .idle

    var body: some View {
        Group {
            switch people {
            case .loaded(let list) where list.isEmpty:
                EmptyStateView(symbol: "hand.raised", title: "No blocked accounts",
                               message: "People you block can't see your content, and you won't see theirs.")
            case .loaded(let list):
                List(list) { person in
                    HStack(spacing: 12) {
                        AvatarView(profile: person, size: 40)
                        VStack(alignment: .leading) {
                            Text(person.displayName).font(.headline)
                            Text("@\(person.username)").font(.caption).foregroundStyle(Palette.secondaryText)
                        }
                        Spacer()
                        Button("Unblock") {
                            Task {
                                try? await env.social.unblock(person.id)
                                env.moderationRevision += 1
                                await load()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .brandedForm()
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            default:
                ProgressView()
            }
        }
        .screenBackground()
        .navigationTitle("Blocked accounts")
        .task { await load() }
    }

    private func load() async {
        do { people = .loaded(try await env.social.blockedUsers()) } catch { people = .failed(error.localizedDescription) }
    }
}
