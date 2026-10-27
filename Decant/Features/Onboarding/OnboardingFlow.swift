import AuthenticationServices
import CryptoKit
import SwiftUI

struct OnboardingFlow: View {
    enum Step: Int, CaseIterable {
        case welcome, age, scan, social, cellar, signIn, tastes, friends
    }

    @Environment(AppEnvironment.self) private var env
    @State private var step: Step = .welcome
    @State private var favoriteTypes: Set<WineType> = []
    @AppStorage("ageAndTermsConfirmed") private var ageAndTermsConfirmed = false

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            Group {
                switch step {
                case .welcome: WelcomeStep(next: advance)
                case .age: AgeGateStep(confirm: {
                    ageAndTermsConfirmed = true
                    if env.currentUser != nil { Task { await env.auth.recordTermsAcceptance() } }
                    advance()
                })
                case .scan: IntroStep(eyebrow: "Scan", title: "Point. Scan. Know.",
                                      message: "Aim your camera at any label. Decant reads it, identifies the exact wine and vintage, and tells you what's in the bottle.",
                                      symbol: "viewfinder", next: advance, skip: skipIntro)
                case .social: IntroStep(eyebrow: "Share", title: "A diary for every glass",
                                        message: "Rate in half stars, keep private notes, and see what your friends are pouring — like a Letterboxd for wine.",
                                        symbol: "person.2.wave.2", next: advance, skip: skipIntro)
                case .cellar: CellarPreviewStep(next: advance, skip: skipIntro)
                case .signIn: SignInStep(next: advance)
                case .tastes: TastesStep(selection: $favoriteTypes, next: saveTastes)
                case .friends: FriendsStep(finish: { env.finishOnboarding() })
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .animation(.smooth(duration: 0.35), value: step)
        .onAppear {
            // Already signed in (e.g. reinstalled) — jump past the intro, but never past the age gate.
            if env.currentUser != nil { step = ageAndTermsConfirmed ? .tastes : .age }
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        if next == .signIn, env.currentUser != nil {
            step = .tastes
        } else {
            step = next
        }
    }

    private func skipIntro() {
        step = env.currentUser == nil ? .signIn : .tastes
    }

    private func saveTastes() {
        if var profile = env.currentUser {
            profile.favoriteTypes = WineType.allCases.filter(favoriteTypes.contains)
            Task {
                if let updated = try? await env.auth.updateProfile(profile) { env.currentUser = updated }
            }
        }
        advance()
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var next: () -> Void
    @State private var appear = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.burgundyDeep, Color(red: 0.1, green: 0.03, blue: 0.05)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Circle().fill(Palette.gold.opacity(0.18)).frame(width: 420).blur(radius: 80).offset(y: -160)
            VStack(spacing: 22) {
                Spacer()
                HStack(alignment: .bottom, spacing: -14) {
                    ForEach(Array(previewWines.prefix(3).enumerated()), id: \.offset) { index, wine in
                        BottleArtView(wine: wine, height: index == 1 ? 250 : 200)
                            .offset(y: appear ? 0 : 40)
                            .opacity(appear ? 1 : 0)
                            .animation(.smooth(duration: 0.8).delay(Double(index) * 0.12), value: appear)
                            .zIndex(index == 1 ? 1 : 0)
                    }
                }
                .padding(.bottom, 10)
                Text("DECANT")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(8)
                    .foregroundStyle(Palette.gold)
                Text("Every great bottle,\nremembered.")
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text("Discover, collect and share the wines you love.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button("Begin", action: next)
                    .buttonStyle(PrimaryButtonStyle(fill: Palette.gold))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .onAppear { appear = true }
    }

    private var previewWines: [Wine] {
        let all = SeedCatalog.load()
        let names = ["Tignanello", "Château Margaux", "Dom Pérignon"]
        return names.compactMap { name in all.first { $0.name == name } }
    }
}

/// Alcohol-related app: users must confirm legal drinking age and accept the
/// Terms & Community Guidelines (zero tolerance for objectionable content).
private struct AgeGateStep: View {
    var confirm: () -> Void
    @State private var acceptsTerms = false
    @State private var declined = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: declined ? "hand.raised.fill" : "person.badge.shield.checkmark")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Palette.burgundy)
                .frame(width: 130, height: 130)
                .background(Palette.burgundy.opacity(0.08), in: Circle())
            if declined {
                Text("Come back later").font(Typo.title)
                Text("Decant is only for people of legal drinking age where they live.")
                    .multilineTextAlignment(.center).foregroundStyle(Palette.secondaryText)
                Spacer()
                Button("I made a mistake") { declined = false }.buttonStyle(.secondary)
            } else {
                Text("Before we pour").eyebrow()
                Text("Are you of legal drinking age?").font(Typo.title).multilineTextAlignment(.center)
                Text("Decant is about wine, so it's only for adults of legal drinking age in their country.")
                    .multilineTextAlignment(.center).foregroundStyle(Palette.secondaryText)
                Spacer()
                Toggle(isOn: $acceptsTerms) {
                    Text("I agree to the [Terms of Use](\(LegalLinks.terms.absoluteString)) and [Community Guidelines](\(LegalLinks.guidelines.absoluteString)). There is no tolerance for objectionable content or abusive users.")
                        .font(.footnote)
                        .tint(Palette.burgundy)
                }
                .toggleStyle(CheckboxToggleStyle())
                Button("Yes, I'm of legal drinking age", action: confirm)
                    .buttonStyle(.primary)
                    .disabled(!acceptsTerms)
                Button("No") { declined = true }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(28)
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { configuration.isOn.toggle() } label: {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Palette.burgundy : Palette.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agree to terms")
            .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
            configuration.label
        }
    }
}

private struct IntroStep: View {
    var eyebrow: String
    var title: String
    var message: String
    var symbol: String
    var next: () -> Void
    var skip: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            HStack { Spacer(); Button("Skip", action: skip).font(.subheadline.weight(.semibold)) }
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Palette.burgundy)
                .frame(width: 150, height: 150)
                .background(Palette.burgundy.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(Palette.gold.opacity(0.4), lineWidth: 1))
            Text(eyebrow).eyebrow()
            Text(title).font(Typo.title).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
            Spacer()
            Button("Continue", action: next).buttonStyle(.primary)
        }
        .padding(28)
    }
}

private struct CellarPreviewStep: View {
    var next: () -> Void
    var skip: () -> Void
    @State private var bottles: [CellarBottle] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if !bottles.isEmpty {
                    CellarSceneView(bottles: bottles, layout: CellarLayout(bottles: bottles, saved: [], sort: .type),
                                    finish: .walnut, dimmed: [], onInspect: { _ in }, onMove: { _, _ in }, onBeginMove: { _ in })
                        .accessibilityHidden(true)
                } else {
                    Color(red: 0.055, green: 0.043, blue: 0.039)
                }
                Button("Skip", action: skip)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding()
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: 14) {
                Text("Cellar").eyebrow()
                Text("Your personal wine museum").font(Typo.title2).multilineTextAlignment(.center)
                Text("Every bottle you scan lands on a real 3D shelf with its own label. Spin it, inspect it, rearrange your racks.")
                    .font(.callout).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
                Button("Continue", action: next).buttonStyle(.primary).padding(.top, 6)
            }
            .padding(28)
            .background(Palette.cream)
        }
        .ignoresSafeArea(edges: .top)
        .task {
            bottles = SeedCatalog.load().prefix(16).enumerated().map { index, wine in
                CellarBottle(id: UUID(), wine: wine, quantity: 1, purchasePrice: nil, purchaseDate: nil, storageLocation: nil,
                             collectionID: nil, addedAt: .now.addingTimeInterval(Double(index)), consumedCount: 0)
            }
        }
    }
}

private struct SignInStep: View {
    var next: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var nonce = ""
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var isSignUp = true
    @State private var localName = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "wineglass.fill").font(.system(size: 40)).foregroundStyle(Palette.burgundy).padding(.top, 40)
                Text("Join Decant").font(Typo.title)
                Text("Your diary, cellar and friends — saved to your account.")
                    .font(.callout).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)

                if env.auth.supportsAppleSignIn {
                    SignInWithAppleButton(.continue) { request in
                        nonce = Self.randomNonce()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = Self.sha256(nonce)
                    } onCompletion: { result in
                        Task { await handleApple(result) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 52)
                    .clipShape(Capsule())
                }

                if env.auth.supportsEmailSignIn {
                    divider("or use email")
                    VStack(spacing: 10) {
                        if isSignUp { field("Username", text: $username).textInputAutocapitalization(.never) }
                        field("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                            .textContentType(isSignUp ? .newPassword : .password)
                            .padding(14)
                            .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14))
                        Button(isSignUp ? "Create account" : "Sign in") { Task { await emailAuth() } }
                            .buttonStyle(.primary)
                            .disabled(busy || email.isEmpty || password.count < 6 || (isSignUp && username.count < 3))
                        Button(isSignUp ? "I already have an account" : "Create a new account") { isSignUp.toggle() }
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if env.mode == .local {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Local Mode", systemImage: "iphone").font(.headline)
                        Text("No server is configured, so your data stays on this device and the friends you'll see are a simulated sample community. Add Supabase keys to enable accounts and real friends.")
                            .font(.footnote).foregroundStyle(Palette.secondaryText)
                        field("Choose a username", text: $localName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Start tasting") { Task { await startLocal() } }
                            .buttonStyle(.primary)
                            .disabled(busy || localName.count < 3)
                    }
                    .cardSurface()
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(Palette.burgundy).multilineTextAlignment(.center)
                }
                if busy { ProgressView() }
            }
            .padding(28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            .padding(14)
            .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14))
    }

    private func divider(_ label: String) -> some View {
        HStack {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                error = "Apple didn't return a sign-in token."
                return
            }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
            await run { try await env.auth.signInWithApple(idToken: token, nonce: nonce, fullName: name.nilIfBlank) }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled { error = failure.localizedDescription }
        }
    }

    private func emailAuth() async {
        await run {
            isSignUp
                ? try await env.auth.signUp(email: email, password: password, username: username.lowercased())
                : try await env.auth.signIn(email: email, password: password)
        }
    }

    private func startLocal() async {
        await run { try await env.auth.startLocalSession(username: localName, displayName: localName) }
    }

    private func run(_ body: () async throws -> Profile) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            env.didSignIn(try await body())
            await env.auth.recordTermsAcceptance()
            next()
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator) ?? "a" })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct TastesStep: View {
    @Binding var selection: Set<WineType>
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer().frame(height: 30)
            Text("Your palate").eyebrow()
            Text("What do you love to drink?").font(Typo.title)
            Text("We'll use this to tune your recommendations.").foregroundStyle(Palette.secondaryText)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(WineType.allCases) { type in
                    Button {
                        if selection.contains(type) { selection.remove(type) } else { selection.insert(type) }
                    } label: {
                        HStack {
                            Circle().fill(Palette.wineColor(type)).frame(width: 18, height: 18)
                            Text(type.displayName).font(.headline)
                            Spacer()
                            if selection.contains(type) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.burgundy) }
                        }
                        .foregroundStyle(Palette.charcoal)
                        .padding(16)
                        .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selection.contains(type) ? Palette.burgundy : Palette.hairline, lineWidth: selection.contains(type) ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection.contains(type) ? .isSelected : [])
                }
            }
            Spacer()
            Button(selection.isEmpty ? "Skip" : "Continue", action: next).buttonStyle(.primary)
        }
        .padding(28)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct FriendsStep: View {
    var finish: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var people: [Profile] = []
    @State private var followed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer().frame(height: 30)
            Text("Friends").eyebrow()
            Text("Find your people").font(Typo.title)
            Text("Follow friends to see their ratings in your feed and on every wine page.")
                .foregroundStyle(Palette.secondaryText)
            if people.isEmpty {
                Text("You can find friends any time from Search.").font(.callout).foregroundStyle(Palette.secondaryText)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(people) { person in
                        HStack(spacing: 12) {
                            AvatarView(profile: person, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName).font(.headline)
                                Text(person.bio ?? "@\(person.username)").font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                            }
                            Spacer()
                            FollowButton(isFollowing: followed.contains(person.id)) {
                                Task {
                                    if followed.contains(person.id) {
                                        try? await env.social.unfollow(person.id)
                                        followed.remove(person.id)
                                    } else {
                                        try? await env.social.follow(person.id)
                                        followed.insert(person.id)
                                    }
                                }
                            }
                        }
                        .cardSurface(padding: 12)
                    }
                }
            }
            Button("Enter Decant", action: finish).buttonStyle(.primary)
        }
        .padding(28)
        .task {
            people = (try? await env.social.suggestedUsers(limit: 8)) ?? []
            if let me = env.currentUser {
                followed = Set(((try? await env.social.following(of: me.id)) ?? []).map(\.id))
                // In Local Mode the sample friends are already followed; show them as such.
                if people.isEmpty { people = (try? await env.social.following(of: me.id)) ?? [] }
            }
        }
    }
}
