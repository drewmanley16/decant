import Foundation

/// Errors surfaced to the UI. Backends map their native errors into these.
enum AppError: LocalizedError, Equatable {
    case notSignedIn
    case notFound
    case network(String)
    case validation(String)
    case unavailable(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Please sign in to continue."
        case .notFound: "We couldn't find that."
        case .network(let message): "Connection problem. \(message)"
        case .validation(let message): message
        case .unavailable(let message): message
        case .server(let message): "Something went wrong. \(message)"
        }
    }
}

protocol AuthService: Sendable {
    var supportsAppleSignIn: Bool { get }
    var supportsEmailSignIn: Bool { get }
    func restoreSession() async -> Profile?
    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws -> Profile
    func signIn(email: String, password: String) async throws -> Profile
    func signUp(email: String, password: String, username: String) async throws -> Profile
    func startLocalSession(username: String, displayName: String) async throws -> Profile
    func updateProfile(_ profile: Profile) async throws -> Profile
    func uploadAvatar(_ jpeg: Data) async throws -> URL
    func signOut() async throws
    func deleteAccount() async throws
    /// Records that the signed-in user accepted the Terms & Community Guidelines.
    func recordTermsAcceptance() async
}

protocol WineCatalogService: Sendable {
    func search(_ query: WineSearchQuery, limit: Int) async throws -> [Wine]
    func wine(id: UUID) async throws -> Wine
    func vintages(ofProduct productID: UUID) async throws -> [Wine]
    /// Candidate pool used for on-device matching and recommendations.
    func catalogSample(limit: Int) async throws -> [Wine]
    /// Finds or creates the wine described by `draft`. `scanKey` links an AI
    /// label reading so the server can attach its suggestions (never trusted from the client).
    func createWine(from draft: WineDraft, scanKey: String?, suggestion: AITastingSuggestion?) async throws -> Wine
    /// Attach AI tasting suggestions to a wine that has no profile yet.
    func attachSuggestion(_ suggestion: AITastingSuggestion, scanKey: String?, to wineID: UUID) async throws
    func setLabelImage(path: String, for wineID: UUID) async throws
    func recordView(of wineID: UUID) async
    func recentlyViewed(limit: Int) async throws -> [Wine]
}

protocol TastingService: Sendable {
    func addEntry(for wineID: UUID, draft: TastingDraft) async throws -> TastingEntry
    func updateEntry(_ entry: TastingEntry) async throws
    func deleteEntry(id: UUID) async throws
    func entries(forUser userID: UUID) async throws -> [ReviewItem]
    func reviews(forWine wineID: UUID, limit: Int) async throws -> [ReviewItem]
    func friendRatings(forWine wineID: UUID) async throws -> [FriendRating]
    func entry(id: UUID) async throws -> ReviewItem
}

protocol SocialService: Sendable {
    func profileSummary(userID: UUID) async throws -> ProfileSummary
    func searchUsers(_ text: String) async throws -> [Profile]
    func suggestedUsers(limit: Int) async throws -> [Profile]
    func follow(_ userID: UUID) async throws
    func unfollow(_ userID: UUID) async throws
    func following(of userID: UUID) async throws -> [Profile]
    func followers(of userID: UUID) async throws -> [Profile]
    func feed(before: Date?, limit: Int) async throws -> [FeedItem]
    func setLike(_ liked: Bool, entryID: UUID) async throws
    func comments(entryID: UUID) async throws -> [ReviewComment]
    func addComment(_ body: String, entryID: UUID) async throws -> ReviewComment
    func notifications() async throws -> [AppNotification]
    func markNotificationsRead() async throws
    // Safety (App Store Guideline 1.2)
    func block(_ userID: UUID) async throws
    func unblock(_ userID: UUID) async throws
    func blockedUsers() async throws -> [Profile]
    func report(_ target: ReportTarget, reason: ReportReason, details: String?) async throws
}

protocol CellarService: Sendable {
    func bottles() async throws -> [CellarBottle]
    func addBottle(wineID: UUID, draft: CellarBottleDraft) async throws -> CellarBottle
    func updateBottle(_ bottle: CellarBottle) async throws
    /// Decrements quantity and returns the updated bottle. Tasting history is untouched.
    func consumeBottle(id: UUID) async throws -> CellarBottle
    func removeBottle(id: UUID) async throws
    func placements() async throws -> [CellarPlacement]
    func savePlacements(_ placements: [CellarPlacement]) async throws
    func collections() async throws -> [CellarCollection]
    func createCollection(name: String, symbol: String) async throws -> CellarCollection
    func settings() async throws -> CellarSettings
    func saveSettings(_ settings: CellarSettings) async throws
    func wishlist() async throws -> [WishlistItem]
    func setWishlisted(_ wishlisted: Bool, wineID: UUID) async throws
}

protocol ScanHistoryService: Sendable {
    func record(_ record: ScanRecord) async throws
    func history(limit: Int) async throws -> [ScanRecord]
    /// Previously confirmed match for an identical label text, to avoid repeat AI calls.
    func cachedMatch(forTextKey key: String) async -> UUID?
    func cacheMatch(textKey: String, wineID: UUID) async
}

/// Uploads/stores images. Returns a path usable by `ImageLoader`.
protocol MediaService: Sendable {
    func storeLabel(_ jpeg: Data, id: UUID) async throws -> String
    func storePhoto(_ jpeg: Data, id: UUID) async throws -> String
}

/// Remote AI label reading. Optional: nil when no backend is configured.
protocol RemoteLabelReader: Sendable {
    func read(_ capture: LabelCapture) async throws -> RemoteLabelReading
}

struct RemoteLabelReading: Sendable {
    var scanKey: String
    var extraction: LabelExtraction
    var candidateWineIDs: [(id: UUID, score: Double)]
    var suggestion: AITastingSuggestion?
    var identityConfidence: Double
}
