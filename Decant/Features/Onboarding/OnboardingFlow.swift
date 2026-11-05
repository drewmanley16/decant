import AuthenticationServices
import CryptoKit
import SwiftUI

struct OnboardingFlow: View {
    enum Step: Int, CaseIterable {
        case welcome, age, scan, social, cellar, signIn, invite, tastes, friends
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var favoriteTypes: Set<WineType> = []
    @AppStorage("ageAndTermsConfirmed") private var ageAndTermsConfirmed = false

    var body: some View {
        ZStack {
            (step == .welcome ? Palette.burgundyDeep : Palette.cream).ignoresSafeArea()
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
                                      symbol: "viewfinder", next: advance)
                case .social: IntroStep(eyebrow: "Share", title: "A diary for every glass",
                                        message: "Rate in half stars, keep private notes, and see what your friends are pouring — like a Letterboxd for wine.",
                                        symbol: "person.2.wave.2", next: advance)
                case .cellar: CellarPreviewStep(next: advance)
                case .signIn: SignInStep(next: advance)
                case .invite: InviteStep(next: advance)
                case .tastes: TastesStep(selection: $favoriteTypes, next: saveTastes)
                case .friends: FriendsStep(finish: { env.finishOnboarding() })
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading))
        }
        .overlay(alignment: .top) {
            if step != .welcome {
                header.transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.55, extraBounce: 0.02), value: step)
        .sensoryFeedback(.impact(weight: .light), trigger: step)
        .onChange(of: env.currentUser?.id) { _, id in
            // Signed out from a later step (e.g. "Use a different account").
            if id == nil, step.rawValue > Step.signIn.rawValue { go(to: .signIn, forward: false) }
        }
        .onAppear {
            // Already signed in (e.g. reinstalled) — jump past the intro, but never past the age gate.
            if env.currentUser != nil { step = !ageAndTermsConfirmed ? .age : env.needsInvite ? .invite : .tastes }
        }
    }

    // MARK: Header (back · progress · skip)

    private var header: some View {
        let onDark = step == .cellar
        return HStack(spacing: 14) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(onDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Palette.burgundy.opacity(0.08)), in: Circle())
            }
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityLabel("Back")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(onDark ? Color.white.opacity(0.22) : Palette.burgundy.opacity(0.12))
                    Capsule().fill(onDark ? Color.white : Palette.burgundy)
                        .frame(width: max(8, geo.size.width * progress))
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue) of \(Step.allCases.count - 1)")

            Button("Skip", action: skipIntro)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 38, minHeight: 38)
                .opacity(canSkip ? 1 : 0)
                .disabled(!canSkip)
        }
        .foregroundStyle(onDark ? Color.white : Palette.burgundy)
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private var progress: CGFloat {
        CGFloat(step.rawValue) / CGFloat(Step.allCases.count - 1)
    }

    private var canGoBack: Bool {
        env.currentUser == nil && (Step.age.rawValue...Step.signIn.rawValue).contains(step.rawValue)
    }

    private var canSkip: Bool { [.scan, .social, .cellar].contains(step) }

    // MARK: Navigation

    private func go(to next: Step, forward isForward: Bool) {
        forward = isForward
        step = next
    }

    private func advance() {
        guard var next = Step(rawValue: step.rawValue + 1) else { return }
        if next == .signIn, env.currentUser != nil { next = .invite }
        if next == .invite, !env.needsInvite { next = .tastes }
        go(to: next, forward: true)
    }

    private func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous, forward: false)
    }

    private func skipIntro() {
        go(to: env.currentUser == nil ? .signIn : env.needsInvite ? .invite : .tastes, forward: true)
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

// MARK: - Motion

/// Fades and lifts a view into place after the page transition, staggered by `order`.
private struct Entrance: ViewModifier {
    var order: Int
    var base: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 22)
            .blur(radius: shown || reduceMotion ? 0 : 4)
            .onAppear {
                withAnimation(.smooth(duration: 0.6).delay(base + Double(order) * 0.07)) { shown = true }
            }
    }
}

private extension View {
    func entrance(_ order: Int, base: Double = 0.18) -> some View {
        modifier(Entrance(order: order, base: base))
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var next: () -> Void
    @State private var appear = false
    @State private var float = false
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.burgundyDeep, Color(red: 0.1, green: 0.03, blue: 0.05)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Circle()
                .fill(Palette.gold.opacity(glow ? 0.24 : 0.14))
                .frame(width: 420)
                .scaleEffect(glow ? 1.08 : 0.94)
                .blur(radius: 80)
                .offset(y: -160)
                .animation(reduceMotion ? nil : .easeInOut(duration: 4).repeatForever(autoreverses: true), value: glow)
            VStack(spacing: 22) {
                Spacer()
                HStack(alignment: .bottom, spacing: -14) {
                    ForEach(Array(previewWines.prefix(3).enumerated()), id: \.offset) { index, wine in
                        BottleArtView(wine: wine, height: index == 1 ? 250 : 200)
                            .rotationEffect(.degrees(appear ? Double(index - 1) * 5 : 0), anchor: .bottom)
                            .offset(y: appear ? 0 : 70)
                            .opacity(appear ? 1 : 0)
                            .animation(.spring(response: 0.9, dampingFraction: 0.78).delay(0.1 + Double(index) * 0.12), value: appear)
                            .offset(y: float ? (index == 1 ? -9 : -5) : 0)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 2.8 + Double(index) * 0.45).repeatForever(autoreverses: true), value: float)
                            .zIndex(index == 1 ? 1 : 0)
                    }
                }
                .padding(.bottom, 10)
                Text("DECANT")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(appear ? 8 : 2)
                    .foregroundStyle(Palette.gold)
                    .animation(.smooth(duration: 1.2).delay(0.45), value: appear)
                    .entrance(0, base: 0.45)
                Text("Every great bottle,\nremembered.")
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .entrance(1, base: 0.45)
                Text("Discover, collect and share the wines you love.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .entrance(2, base: 0.45)
                Spacer()
                Button("Begin", action: next)
                    .buttonStyle(PrimaryButtonStyle(fill: Palette.gold))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .entrance(3, base: 0.45)
            }
        }
        .onAppear {
            appear = true
            Task {
                try? await Task.sleep(for: .seconds(1.1))
                float = true
                glow = true
            }
        }
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
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 130, height: 130)
                .background(Palette.burgundy.opacity(0.08), in: Circle())
                .entrance(0)
            Group {
                if declined {
                    VStack(spacing: 22) {
                        Text("Come back later").font(Typo.title)
                        Text("Decant is only for people of legal drinking age where they live.")
                            .multilineTextAlignment(.center).foregroundStyle(Palette.secondaryText)
                        Spacer()
                        Button("I made a mistake") { declined = false }.buttonStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    VStack(spacing: 22) {
                        Text("Before we pour").eyebrow().entrance(1)
                        Text("Are you of legal drinking age?").font(Typo.title).multilineTextAlignment(.center).entrance(2)
                        Text("Decant is about wine, so it's only for adults of legal drinking age in their country.")
                            .multilineTextAlignment(.center).foregroundStyle(Palette.secondaryText).entrance(3)
                        Spacer()
                        Toggle(isOn: $acceptsTerms) {
                            Text("I agree to the [Terms of Use](\(LegalLinks.terms.absoluteString)) and [Community Guidelines](\(LegalLinks.guidelines.absoluteString)). There is no tolerance for objectionable content or abusive users.")
                                .font(.footnote)
                                .tint(Palette.burgundy)
                        }
                        .toggleStyle(CheckboxToggleStyle())
                        .entrance(4)
                        VStack(spacing: 14) {
                            Button("Yes, I'm of legal drinking age", action: confirm)
                                .buttonStyle(.primary)
                                .disabled(!acceptsTerms)
                                .opacity(acceptsTerms ? 1 : 0.5)
                            Button("No") { declined = true }
                                .font(.subheadline.weight(.semibold))
                        }
                        .entrance(5)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
        .padding(28)
        .padding(.top, 30)
        .animation(.smooth(duration: 0.35), value: declined)
        .animation(.snappy(duration: 0.25), value: acceptsTerms)
        .sensoryFeedback(.selection, trigger: acceptsTerms)
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { configuration.isOn.toggle() } label: {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
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
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .strokeBorder(Palette.gold.opacity(0.35), lineWidth: 1)
                    .frame(width: 150, height: 150)
                    .scaleEffect(animate && !reduceMotion ? 1.35 : 1)
                    .opacity(animate && !reduceMotion ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 2.4).repeatForever(autoreverses: false), value: animate)
                Circle()
                    .trim(from: 0, to: 0.68)
                    .stroke(Palette.gold.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 176, height: 176)
                    .rotationEffect(.degrees(animate && !reduceMotion ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 14).repeatForever(autoreverses: false), value: animate)
                Image(systemName: symbol)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Palette.burgundy)
                    .symbolEffect(.bounce, value: animate)
                    .frame(width: 150, height: 150)
                    .background(Palette.burgundy.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(Palette.gold.opacity(0.4), lineWidth: 1))
            }
            .entrance(0)
            Text(eyebrow).eyebrow().entrance(1)
            Text(title).font(Typo.title).multilineTextAlignment(.center).entrance(2)
            Text(message).font(.body).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center).entrance(3)
            Spacer()
            Button("Continue", action: next).buttonStyle(.primary).entrance(4)
        }
        .padding(28)
        .task {
            try? await Task.sleep(for: .seconds(0.45))
            animate = true
        }
    }
}

private struct CellarPreviewStep: View {
    var next: () -> Void
    @State private var bottles: [CellarBottle] = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(red: 0.055, green: 0.043, blue: 0.039)
                if !bottles.isEmpty {
                    CellarSceneView(bottles: bottles, layout: CellarLayout(bottles: bottles, saved: [], sort: .type),
                                    finish: .walnut, dimmed: [], onInspect: { _ in }, onMove: { _, _ in }, onBeginMove: { _ in })
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.8), value: bottles.isEmpty)
            VStack(spacing: 14) {
                Text("Cellar").eyebrow().entrance(0)
                Text("Your personal wine museum").font(Typo.title2).multilineTextAlignment(.center).entrance(1)
                Text("Every bottle you scan lands on a real 3D shelf with its own label. Spin it, inspect it, rearrange your racks.")
                    .font(.callout).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center).entrance(2)
                Button("Continue", action: next).buttonStyle(.primary).padding(.top, 6).entrance(3)
            }
            .padding(28)
            .background(Palette.cream)
        }
        .ignoresSafeArea(edges: .top)
        .task {
            // Illustration only: a handful of well-known bottles to show what a shelf looks like.
            try? await Task.sleep(for: .seconds(0.35))
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
                Image(systemName: "wineglass.fill").font(.system(size: 40)).foregroundStyle(Palette.burgundy)
                    .padding(.top, 56)
                    .entrance(0)
                Text(isSignUp ? "Join Decant" : "Welcome back").font(Typo.title)
                    .contentTransition(.opacity)
                    .entrance(1)
                Text("Your diary, cellar and friends — saved to your account.")
                    .font(.callout).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
                    .entrance(2)

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
                    .entrance(3)
                }

                if env.auth.supportsEmailSignIn {
                    divider("or use email").entrance(4)
                    VStack(spacing: 10) {
                        if isSignUp {
                            field("Username", text: $username).textInputAutocapitalization(.never)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        field("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                            .textContentType(isSignUp ? .newPassword : .password)
                            .padding(14)
                            .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 14))
                        Button { Task { await emailAuth() } } label: {
                            ZStack {
                                Text(isSignUp ? "Create account" : "Sign in").opacity(busy ? 0 : 1)
                                if busy { ProgressView().tint(.white) }
                            }
                        }
                        .buttonStyle(.primary)
                        .disabled(busy || email.isEmpty || password.count < 6 || (isSignUp && username.count < 3))
                        Button(isSignUp ? "I already have an account" : "Create a new account") {
                            withAnimation(.smooth(duration: 0.35)) { isSignUp.toggle(); error = nil }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .entrance(5)
                }

                if env.mode == .local {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Local Mode", systemImage: "iphone").font(.headline)
                        Text("No server is configured, so everything stays on this device. Add Supabase keys to enable accounts and friends.")
                            .font(.footnote).foregroundStyle(Palette.secondaryText)
                        field("Choose a username", text: $localName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Start tasting") { Task { await startLocal() } }
                            .buttonStyle(.primary)
                            .disabled(busy || localName.count < 3)
                    }
                    .cardSurface()
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote).foregroundStyle(Palette.burgundy).multilineTextAlignment(.center)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if busy && !env.auth.supportsEmailSignIn { ProgressView() }
            }
            .padding(28)
            .animation(.smooth(duration: 0.3), value: error)
        }
        .scrollDismissesKeyboard(.interactively)
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
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

/// Decant is invite-only: a new account needs a member's code before it can post.
private struct InviteStep: View {
    var next: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var attempts = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 40)
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Palette.burgundy)
                .symbolEffect(.bounce, value: attempts)
                .frame(width: 120, height: 120)
                .background(Palette.burgundy.opacity(0.08), in: Circle())
                .entrance(0)
            Text("By invitation").eyebrow().entrance(1)
            Text("Enter your invite code").font(Typo.title).multilineTextAlignment(.center).entrance(2)
            Text("Decant is invite-only for now. Ask a friend who's already on Decant for their code — you'll find it on their profile.")
                .multilineTextAlignment(.center).foregroundStyle(Palette.secondaryText).entrance(3)

            CodeBoxes(code: code, focused: focused)
                .overlay {
                    TextField("", text: $code)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($focused)
                        .opacity(0.02)
                        .accessibilityLabel("Invite code")
                }
                .onTapGesture { focused = true }
                .modifier(Shake(animatableData: CGFloat(attempts)))
                .entrance(4)
                .onChange(of: code) { _, new in
                    let cleaned = String(new.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(6))
                    if cleaned != new { code = cleaned }
                    error = nil
                    if cleaned.count == 6 { Task { await redeem() } }
                }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(Palette.burgundy)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            Button { Task { await redeem() } } label: {
                ZStack {
                    Text("Join Decant").opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(.white) }
                }
            }
            .buttonStyle(.primary)
            .disabled(code.count < 6 || busy)
            .entrance(5)
            Button("Use a different account") { Task { await env.signOut() } }
                .font(.subheadline.weight(.semibold))
                .entrance(6)
        }
        .padding(28)
        .animation(.smooth(duration: 0.3), value: error)
        .sensoryFeedback(.error, trigger: attempts)
        .task {
            try? await Task.sleep(for: .seconds(0.6))
            if let link = env.pendingInviteCode, code.isEmpty {
                env.pendingInviteCode = nil
                code = link // redeems automatically once six characters are in
            } else {
                focused = true
            }
        }
        .onChange(of: env.pendingInviteCode) { _, link in
            guard let link else { return }
            env.pendingInviteCode = nil
            code = link
        }
    }

    private func redeem() async {
        guard code.count == 6, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            env.currentUser = try await env.auth.redeemInvite(code)
            focused = false
            env.show("Welcome to Decant", symbol: "party.popper.fill")
            next()
        } catch {
            self.error = error.localizedDescription
            withAnimation(.default) { attempts += 1 }
        }
    }
}

private struct CodeBoxes: View {
    var code: String
    var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { i in
                let chars = Array(code)
                let filled = i < chars.count
                let active = focused && i == min(chars.count, 5)
                Text(filled ? String(chars[i]) : "")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.charcoal)
                    .frame(width: 46, height: 58)
                    .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(active ? Palette.burgundy : filled ? Palette.burgundy.opacity(0.35) : Palette.hairline,
                                      lineWidth: active ? 2 : 1))
                    .scaleEffect(filled ? 1 : 0.96)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: filled)
                    .animation(.smooth(duration: 0.2), value: active)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(animatableData * .pi * 4), y: 0))
    }
}

private struct TastesStep: View {
    @Binding var selection: Set<WineType>
    var next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer().frame(height: 56)
            Text("Your palate").eyebrow().entrance(0)
            Text("What do you love to drink?").font(Typo.title).entrance(1)
            Text("We'll use this to tune your recommendations.").foregroundStyle(Palette.secondaryText).entrance(2)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(WineType.allCases.enumerated()), id: \.element) { index, type in
                    let isOn = selection.contains(type)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            if isOn { selection.remove(type) } else { selection.insert(type) }
                        }
                    } label: {
                        HStack {
                            Circle().fill(Palette.wineColor(type)).frame(width: 18, height: 18)
                                .scaleEffect(isOn ? 1.15 : 1)
                            Text(type.displayName).font(.headline)
                            Spacer()
                            if isOn {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.burgundy)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .foregroundStyle(Palette.charcoal)
                        .padding(16)
                        .background(isOn ? Palette.burgundy.opacity(0.06) : Palette.creamElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(isOn ? Palette.burgundy : Palette.hairline, lineWidth: isOn ? 2 : 1))
                        .scaleEffect(isOn ? 1.02 : 1)
                    }
                    .buttonStyle(PressableCardStyle())
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .entrance(3 + index / 2)
                }
            }
            Spacer()
            Button(selection.isEmpty ? "Skip" : "Continue", action: next)
                .buttonStyle(.primary)
                .contentTransition(.opacity)
                .animation(.smooth, value: selection.isEmpty)
                .entrance(7)
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
            Spacer().frame(height: 56)
            Text("Friends").eyebrow().entrance(0)
            Text("Find your people").font(Typo.title).entrance(1)
            Text("Follow friends to see their ratings in your feed and on every wine page.")
                .foregroundStyle(Palette.secondaryText)
                .entrance(2)
            if people.isEmpty {
                Text("You can find friends any time from Search.").font(.callout).foregroundStyle(Palette.secondaryText)
                    .entrance(3)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
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
                        .entrance(index, base: 0.05)
                    }
                }
            }
            Button("Enter Decant", action: finish).buttonStyle(.primary).entrance(4)
        }
        .padding(28)
        .task {
            people = (try? await env.social.suggestedUsers(limit: 8)) ?? []
            if let me = env.currentUser {
                followed = Set(((try? await env.social.following(of: me.id)) ?? []).map(\.id))
            }
        }
    }
}
