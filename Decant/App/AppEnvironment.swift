import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Build-time configuration read from Info.plist (populated from Config/*.xcconfig).
struct AppConfig: Sendable {
    var supabaseURL: URL?
    var supabaseAnonKey: String?

    static let current: AppConfig = {
        let info = Bundle.main.infoDictionary ?? [:]
        let rawURL = (info["SupabaseURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info["SupabaseAnonKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let url = URL(string: rawURL).flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        return AppConfig(supabaseURL: url, supabaseAnonKey: key.isEmpty || key.hasPrefix("YOUR-") ? nil : key)
    }()

    var isSupabaseConfigured: Bool { supabaseURL != nil && supabaseAnonKey != nil }
}

enum BackendMode: Sendable {
    case local
    case supabase

    var label: String {
        switch self {
        case .local: "Local Mode — data stays on this device; friends are a simulated sample community."
        case .supabase: "Synced with your Decant account."
        }
    }
}

enum AppTab: Hashable {
    case discover, search, scan, cellar, profile
}

/// Dependency container + session state, injected through the SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    enum Phase: Equatable {
        case launching
        case onboarding
        case ready
    }

    let mode: BackendMode
    let auth: AuthService
    let catalog: WineCatalogService
    let tastings: TastingService
    let social: SocialService
    let cellar: CellarService
    let scans: ScanHistoryService
    let media: MediaService
    let identification: WineIdentificationService

    var phase: Phase = .launching
    var currentUser: Profile?
    var selectedTab: AppTab = .discover
    var isScannerPresented = false
    /// When set, the Cellar tab flies to and inspects this wine's bottle.
    var cellarFocusWineID: UUID?
    /// Bumped whenever cellar / diary data changes so screens can reload.
    var cellarRevision = 0
    var diaryRevision = 0
    /// Bumped after a block/report so feeds and threads drop hidden content.
    var moderationRevision = 0
    var toast: Toast?
    /// A link opened from outside (share link or notification), shown over the tabs.
    var pendingLink: DeepLink?
    /// An invite code from a link, pre-filled on the invite step.
    var pendingInviteCode: String?
    @ObservationIgnored private var pushToken: String?

    @ObservationIgnored
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    init(mode: BackendMode, auth: AuthService, catalog: WineCatalogService, tastings: TastingService,
         social: SocialService, cellar: CellarService, scans: ScanHistoryService, media: MediaService,
         remoteReader: RemoteLabelReader?) {
        self.mode = mode
        self.auth = auth
        self.catalog = catalog
        self.tastings = tastings
        self.social = social
        self.cellar = cellar
        self.scans = scans
        self.media = media
        self.identification = WineIdentificationService(catalog: catalog, scans: scans, remote: remoteReader)
    }

    static func live(config: AppConfig = .current) -> AppEnvironment {
        if let url = config.supabaseURL, let key = config.supabaseAnonKey {
            let backend = SupabaseBackend(url: url, anonKey: key)
            Task { await ImageLoader.shared.setResolver { await backend.resolveImageURL($0) } }
            return AppEnvironment(mode: .supabase, auth: backend, catalog: backend, tastings: backend, social: backend,
                                  cellar: backend, scans: backend, media: backend, remoteReader: backend)
        }
        let backend = LocalBackend()
        return AppEnvironment(mode: .local, auth: backend, catalog: backend, tastings: backend, social: backend,
                              cellar: backend, scans: backend, media: backend, remoteReader: nil)
    }

    /// In-memory environment for SwiftUI previews and tests.
    static func preview() -> AppEnvironment {
        let store = LocalStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID()).json"))
        let backend = LocalBackend(store: store)
        return AppEnvironment(mode: .local, auth: backend, catalog: backend, tastings: backend, social: backend,
                              cellar: backend, scans: backend, media: backend, remoteReader: nil)
    }

    /// Signed in to the cloud but hasn't redeemed an invite code yet.
    var needsInvite: Bool {
        mode == .supabase && currentUser != nil && currentUser?.memberSince == nil
    }

    func bootstrap() async {
        currentUser = await auth.restoreSession()
        phase = currentUser != nil && onboardingComplete && !needsInvite ? .ready : .onboarding
        if phase == .ready { await registerForPushIfAllowed() }
    }

    // MARK: Links

    func open(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        if case .invite(let code) = link {
            if phase == .ready {
                show(needsInvite ? "Invite code ready" : "You're already a member", symbol: "envelope.open.fill")
            }
            pendingInviteCode = code
            return
        }
        guard phase == .ready else { return }
        pendingLink = link
    }

    // MARK: Push notifications

    /// Asks for permission (once), then registers with APNs.
    func requestPushPermission() async {
        guard mode == .supabase else { return }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func registerForPushIfAllowed() async {
        guard mode == .supabase, currentUser != nil else { return }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: UIApplication.shared.registerForRemoteNotifications()
        default: break
        }
    }

    func didReceivePushToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        pushToken = hex
        guard currentUser != nil else { return }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        Task { try? await social.registerDevice(token: hex, sandbox: sandbox) }
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    func didSignIn(_ profile: Profile) {
        currentUser = profile
    }

    func finishOnboarding() {
        onboardingComplete = true
        withAnimation(.smooth) { phase = .ready }
        Task { await requestPushPermission() }
    }

    func signOut() async {
        if let pushToken { try? await social.unregisterDevice(token: pushToken) }
        setBadge(0)
        try? await auth.signOut()
        currentUser = nil
        onboardingComplete = false
        phase = .onboarding
        selectedTab = .discover
    }

    func deleteAccount() async throws {
        try await auth.deleteAccount()
        currentUser = nil
        onboardingComplete = false
        phase = .onboarding
    }

    func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        toast = Toast(message: message, symbol: symbol)
    }
}

struct Toast: Equatable, Identifiable {
    var id = UUID()
    var message: String
    var symbol: String
}
