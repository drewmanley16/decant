import Foundation
import Supabase

/// Supabase implementation of every service. All access control is enforced by
/// Postgres RLS (see supabase/migrations); this client never assumes privilege.
final class SupabaseBackend: AuthService, WineCatalogService, TastingService, SocialService, CellarService,
    ScanHistoryService, MediaService, RemoteLabelReader, Sendable {
    let client: SupabaseClient
    let baseURL: URL
    /// Local-only state (recently viewed, label text cache, offline snapshots).
    private let local: LocalStore

    init(url: URL, anonKey: String, local: LocalStore = LocalStore(fileURL: LocalFiles.root.appendingPathComponent("supabase-cache.json"))) {
        self.baseURL = url
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
        self.local = local
    }

    /// Resolves stored image paths ("bucket/uid/file.jpg") to URLs.
    func resolveImageURL(_ path: String) async -> URL? {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "tasting-photos" {
            return try? await client.storage.from(parts[0]).createSignedURL(path: parts[1], expiresIn: 3600)
        }
        return try? client.storage.from(parts[0]).getPublicURL(path: parts[1])
    }

    private func me() async throws -> UUID {
        guard let id = try? await client.auth.session.user.id else { throw AppError.notSignedIn }
        return id
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try SupabaseCoding.decoder.decode(T.self, from: data)
        } catch {
            throw AppError.server("Unexpected response (\(T.self)).")
        }
    }

    private func mapError(_ error: Error) -> Error {
        if error is AppError { return error }
        if let urlError = error as? URLError { return AppError.network(urlError.localizedDescription) }
        return AppError.server(error.localizedDescription)
    }

    @discardableResult
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw mapError(error) }
    }

    // MARK: - AuthService

    var supportsAppleSignIn: Bool { true }
    var supportsEmailSignIn: Bool { true }

    private func loadProfile(_ id: UUID) async throws -> Profile {
        let data = try await client.from("profiles").select().eq("id", value: id.uuidString).single().execute().data
        return try decode(ProfileRow.self, data).profile
    }

    func restoreSession() async -> Profile? {
        guard let session = try? await client.auth.session else { return nil }
        return try? await loadProfile(session.user.id)
    }

    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws -> Profile {
        try await run {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
            var profile = try await loadProfile(session.user.id)
            // Apple only shares the name on first sign-in; persist it.
            if let fullName, !fullName.isEmpty, profile.displayName == profile.username {
                profile.displayName = fullName
                profile = try await updateProfile(profile)
            }
            return profile
        }
    }

    func signIn(email: String, password: String) async throws -> Profile {
        try await run {
            let session = try await client.auth.signIn(email: email, password: password)
            return try await loadProfile(session.user.id)
        }
    }

    func signUp(email: String, password: String, username: String) async throws -> Profile {
        try await run {
            let response = try await client.auth.signUp(email: email, password: password, data: ["username": .string(username)])
            guard response.session != nil else {
                throw AppError.validation("Check your email to confirm your account, then sign in.")
            }
            return try await loadProfile(response.user.id)
        }
    }

    func startLocalSession(username: String, displayName: String) async throws -> Profile {
        throw AppError.unavailable("Local Mode is disabled when a server is configured.")
    }

    func updateProfile(_ profile: Profile) async throws -> Profile {
        try await run {
            let update = ProfileUpdate(username: profile.username, displayName: profile.displayName, bio: profile.bio,
                                       isPrivate: profile.isPrivate, favoriteTypes: profile.favoriteTypes,
                                       defaultVisibility: profile.defaultVisibility, avatarUrl: profile.avatarURL?.absoluteString)
            let data = try await client.from("profiles").update(update).eq("id", value: profile.id.uuidString)
                .select().single().execute().data
            return try decode(ProfileRow.self, data).profile
        }
    }

    func uploadAvatar(_ jpeg: Data) async throws -> URL {
        let id = try await me()
        return try await run {
            let path = "\(id.uuidString.lowercased())/avatar-\(Int(Date().timeIntervalSince1970)).jpg"
            try await client.storage.from("avatars").upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
            return try client.storage.from("avatars").getPublicURL(path: path)
        }
    }

    func signOut() async throws {
        try await run { try await client.auth.signOut() }
    }

    func recordTermsAcceptance() async {
        guard let id = try? await me() else { return }
        _ = try? await client.from("profiles").update(["terms_accepted_at": ISO8601DateFormatter().string(from: .now)])
            .eq("id", value: id.uuidString).execute()
    }

    func deleteAccount() async throws {
        try await run {
            try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(method: .post))
            try? await client.auth.signOut()
            await local.reset()
        }
    }

    // MARK: - WineCatalogService

    private struct SearchParams: Encodable {
        var q: String
        var types: [WineType]?
        var country_filter, region_filter, grape_filter: String?
        var vintage_filter: Int?
        var max_price, min_rating: Double?
        var lim: Int
    }

    func search(_ query: WineSearchQuery, limit: Int) async throws -> [Wine] {
        try await run {
            let params = SearchParams(q: query.text.trimmingCharacters(in: .whitespaces),
                                      types: query.types.isEmpty ? nil : Array(query.types),
                                      country_filter: query.country, region_filter: query.region, grape_filter: query.grape,
                                      vintage_filter: query.vintage, max_price: query.maxPrice, min_rating: query.minRating, lim: limit)
            let data = try await client.rpc("search_wines", params: params).execute().data
            return try decode([WineCatalogRow].self, data).map(\.wine)
        }
    }

    private func wines(ids: [UUID]) async throws -> [UUID: Wine] {
        guard !ids.isEmpty else { return [:] }
        let unique = Array(Set(ids)).map(\.uuidString)
        let data = try await client.from("wine_catalog").select().in("id", values: unique).execute().data
        return Dictionary(try decode([WineCatalogRow].self, data).map { ($0.id, $0.wine) }, uniquingKeysWith: { a, _ in a })
    }

    func wine(id: UUID) async throws -> Wine {
        try await run {
            guard let wine = try await wines(ids: [id])[id] else { throw AppError.notFound }
            return wine
        }
    }

    func vintages(ofProduct productID: UUID) async throws -> [Wine] {
        try await run {
            let data = try await client.from("wine_catalog").select().eq("product_id", value: productID.uuidString)
                .order("year", ascending: false).execute().data
            return try decode([WineCatalogRow].self, data).map(\.wine)
        }
    }

    func catalogSample(limit: Int) async throws -> [Wine] {
        try await run {
            let data = try await client.from("wine_catalog").select()
                .order("ratings_count", ascending: false).limit(limit).execute().data
            return try decode([WineCatalogRow].self, data).map(\.wine)
        }
    }

    private struct CreateWineParams: Encodable {
        var p_producer, p_name: String
        var p_type: WineType
        var p_vintage: Int?
        var p_grapes: [String]
        var p_country, p_region, p_appellation: String?
        var p_abv: Double?
        var p_bottle_size_ml: Int
        var p_price: Double?
        var p_currency: String
        var p_source: InfoSource
        var p_scan_text_hash: String?
    }

    func createWine(from draft: WineDraft, scanKey: String?, suggestion: AITastingSuggestion?) async throws -> Wine {
        guard draft.isValid else { throw AppError.validation("A wine needs at least a name and a producer.") }
        return try await run {
            let params = CreateWineParams(
                p_producer: draft.producer, p_name: draft.name, p_type: draft.type, p_vintage: draft.vintage,
                p_grapes: draft.grapes, p_country: draft.country.nilIfBlank, p_region: draft.region.nilIfBlank,
                p_appellation: draft.appellation.nilIfBlank, p_abv: draft.abv, p_bottle_size_ml: draft.bottleSizeML,
                p_price: draft.priceAmount, p_currency: draft.currency, p_source: draft.source, p_scan_text_hash: scanKey)
            let data = try await client.rpc("create_wine_from_scan", params: params).execute().data
            let id = try decode(UUID.self, data)
            return try await wine(id: id)
        }
    }

    private struct AttachParams: Encodable {
        var target_vintage: UUID
        var scan_text_hash: String
    }

    func attachSuggestion(_ suggestion: AITastingSuggestion, scanKey: String?, to wineID: UUID) async throws {
        // The server copies suggestions from its own cache; client-supplied content is never trusted.
        guard let scanKey else { return }
        try await run {
            try await client.rpc("attach_cached_suggestion", params: AttachParams(target_vintage: wineID, scan_text_hash: scanKey)).execute()
        }
    }

    private struct LabelParams: Encodable {
        var target_vintage: UUID
        var path: String
    }

    func setLabelImage(path: String, for wineID: UUID) async throws {
        // `path` is "labels/<uid>/<file>"; the RPC validates the uid prefix of the object name.
        let objectPath = path.hasPrefix("labels/") ? String(path.dropFirst("labels/".count)) : path
        try await run {
            try await client.rpc("set_vintage_label", params: LabelParams(target_vintage: wineID, path: objectPath)).execute()
        }
    }

    func recordView(of wineID: UUID) async {
        await local.write { s in
            s.recentlyViewed.removeAll { $0 == wineID }
            s.recentlyViewed.insert(wineID, at: 0)
            s.recentlyViewed = Array(s.recentlyViewed.prefix(30))
        }
    }

    func recentlyViewed(limit: Int) async throws -> [Wine] {
        let ids = await local.read { Array($0.recentlyViewed.prefix(limit)) }
        let map = try await run { try await wines(ids: ids) }
        return ids.compactMap { map[$0] }
    }

    // MARK: - TastingService

    /// Joins entry rows with authors, wines, review text, private notes and counts.
    private func hydrate(_ rows: [TastingRow]) async throws -> [ReviewItem] {
        guard !rows.isEmpty else { return [] }
        let viewer = try? await me()
        let entryIDs = rows.map(\.id.uuidString)
        async let winesTask = wines(ids: rows.map(\.vintageId))
        async let profilesTask = profiles(ids: rows.map(\.userId))
        async let reviewsData = client.from("wine_reviews").select("entry_id,user_id,body").in("entry_id", values: entryIDs).execute().data
        async let notesData = client.from("tasting_private_notes").select("entry_id,user_id,notes").in("entry_id", values: entryIDs).execute().data
        async let statsData = client.rpc("entry_stats", params: ["entry_ids": rows.map(\.id)]).execute().data

        let wines = try await winesTask
        let profiles = try await profilesTask
        let reviews = Dictionary(try decode([ReviewRead].self, try await reviewsData).map { ($0.entryId, $0.body) }, uniquingKeysWith: { a, _ in a })
        let notes = Dictionary(try decode([PrivateNoteRead].self, try await notesData).map { ($0.entryId, $0.notes) }, uniquingKeysWith: { a, _ in a })
        let stats = Dictionary(try decode([EntryStatsRow].self, try await statsData).map { ($0.entryId, $0) }, uniquingKeysWith: { a, _ in a })

        return rows.compactMap { row in
            guard let wine = wines[row.vintageId], let author = profiles[row.userId] else { return nil }
            let s = stats[row.id]
            let entry = TastingEntry(
                id: row.id, userID: row.userId, wineID: row.vintageId, rating: row.rating, review: reviews[row.id],
                personalNotes: row.userId == viewer ? notes[row.id] : nil, photoPaths: row.photoPaths,
                consumedOn: row.consumedOn, location: row.location, occasion: row.occasion,
                taggedUserIDs: row.taggedUserIds, drinkAgain: row.drinkAgain, isFavorite: row.isFavorite,
                visibility: row.visibility, createdAt: row.createdAt, likeCount: s?.likeCount ?? 0,
                commentCount: s?.commentCount ?? 0, likedByMe: s?.likedByMe ?? false)
            return ReviewItem(entry: entry, author: author, wine: wine)
        }
    }

    private func profiles(ids: [UUID]) async throws -> [UUID: Profile] {
        guard !ids.isEmpty else { return [:] }
        let data = try await client.from("profiles").select().in("id", values: Array(Set(ids)).map(\.uuidString)).execute().data
        return Dictionary(try decode([ProfileRow].self, data).map { ($0.id, $0.profile) }, uniquingKeysWith: { a, _ in a })
    }

    private static let entryColumns = "id,user_id,vintage_id,rating,consumed_on,location,occasion,drink_again,is_favorite,visibility,tagged_user_ids,photo_paths,created_at"

    func addEntry(for wineID: UUID, draft: TastingDraft) async throws -> TastingEntry {
        let userID = try await me()
        return try await run {
            let insert = TastingInsert(
                userId: userID, vintageId: wineID, rating: draft.rating.map(TastingEntry.normalizedRating),
                consumedOn: SupabaseCoding.dayString(draft.consumedOn), location: draft.location.nilIfBlank,
                occasion: draft.occasion.nilIfBlank, drinkAgain: draft.drinkAgain, isFavorite: draft.isFavorite,
                visibility: draft.visibility, taggedUserIds: draft.taggedUserIDs, photoPaths: draft.photoPaths)
            let data = try await client.from("tasting_entries").insert(insert).select(Self.entryColumns).single().execute().data
            let row = try decode(TastingRow.self, data)
            if let review = draft.review.nilIfBlank {
                try await client.from("wine_reviews").insert(ReviewRow(entryId: row.id, userId: userID, body: review)).execute()
            }
            if let notes = draft.personalNotes.nilIfBlank {
                try await client.from("tasting_private_notes").insert(PrivateNoteRow(entryId: row.id, userId: userID, notes: notes)).execute()
            }
            guard let item = try await hydrate([row]).first else { throw AppError.notFound }
            return item.entry
        }
    }

    private struct EntryUpdate: Encodable {
        var rating: Double?
        var location, occasion: String?
        var drink_again: Bool?
        var is_favorite: Bool
        var visibility: Visibility
    }

    func updateEntry(_ entry: TastingEntry) async throws {
        try await run {
            let update = EntryUpdate(rating: entry.rating, location: entry.location, occasion: entry.occasion,
                                     drink_again: entry.drinkAgain, is_favorite: entry.isFavorite, visibility: entry.visibility)
            try await client.from("tasting_entries").update(update).eq("id", value: entry.id.uuidString).execute()
            if let review = entry.review?.nilIfBlank {
                try await client.from("wine_reviews").upsert(ReviewRow(entryId: entry.id, userId: entry.userID, body: review)).execute()
            } else {
                try await client.from("wine_reviews").delete().eq("entry_id", value: entry.id.uuidString).execute()
            }
        }
    }

    func deleteEntry(id: UUID) async throws {
        try await run { try await client.from("tasting_entries").delete().eq("id", value: id.uuidString).execute() }
    }

    func entries(forUser userID: UUID) async throws -> [ReviewItem] {
        try await run {
            let data = try await client.from("tasting_entries").select(Self.entryColumns)
                .eq("user_id", value: userID.uuidString).order("consumed_on", ascending: false).limit(500).execute().data
            let items = try await hydrate(try decode([TastingRow].self, data))
            if userID == (try? await me()) { await cacheHistory(items) }
            return items
        }
    }

    func reviews(forWine wineID: UUID, limit: Int) async throws -> [ReviewItem] {
        try await run {
            let reviewed = try await client.from("wine_reviews").select("entry_id,user_id,body")
                .order("created_at", ascending: false).limit(200).execute().data
            let reviewIDs = Set(try decode([ReviewRead].self, reviewed).map(\.entryId))
            let data = try await client.from("tasting_entries").select(Self.entryColumns)
                .eq("vintage_id", value: wineID.uuidString).order("created_at", ascending: false).limit(limit * 3).execute().data
            let rows = try decode([TastingRow].self, data).filter { reviewIDs.contains($0.id) }
            return Array(try await hydrate(Array(rows.prefix(limit))))
        }
    }

    private func followingIDs(of userID: UUID) async throws -> [UUID] {
        let data = try await client.from("user_follows").select("follower_id,followee_id,status")
            .eq("follower_id", value: userID.uuidString).eq("status", value: "accepted").execute().data
        return try decode([FollowRow].self, data).map(\.followeeId)
    }

    func friendRatings(forWine wineID: UUID) async throws -> [FriendRating] {
        let viewer = try await me()
        return try await run {
            let following = try await followingIDs(of: viewer)
            guard !following.isEmpty else { return [] }
            let data = try await client.from("tasting_entries").select(Self.entryColumns)
                .eq("vintage_id", value: wineID.uuidString).in("user_id", values: following.map(\.uuidString))
                .order("created_at", ascending: false).execute().data
            let rows = try decode([TastingRow].self, data)
            let people = try await profiles(ids: rows.map(\.userId))
            return rows.compactMap { row in people[row.userId].map { FriendRating(friend: $0, rating: row.rating, entryID: row.id) } }
        }
    }

    func entry(id: UUID) async throws -> ReviewItem {
        try await run {
            let data = try await client.from("tasting_entries").select(Self.entryColumns).eq("id", value: id.uuidString).execute().data
            guard let item = try await hydrate(try decode([TastingRow].self, data)).first else { throw AppError.notFound }
            return item
        }
    }

    // MARK: - SocialService

    func profileSummary(userID: UUID) async throws -> ProfileSummary {
        let viewer = try await me()
        return try await run {
            let profile = try await loadProfile(userID)
            let followers = try await client.from("user_follows").select("follower_id", head: true, count: .exact)
                .eq("followee_id", value: userID.uuidString).eq("status", value: "accepted").execute().count ?? 0
            let following = try await client.from("user_follows").select("followee_id", head: true, count: .exact)
                .eq("follower_id", value: userID.uuidString).eq("status", value: "accepted").execute().count ?? 0
            let tastings = try await client.from("tasting_entries").select("id", head: true, count: .exact)
                .eq("user_id", value: userID.uuidString).execute().count ?? 0
            let mine = try await client.from("user_follows").select("follower_id,followee_id,status")
                .eq("follower_id", value: viewer.uuidString).eq("followee_id", value: userID.uuidString).execute().data
            let relation = try decode([FollowRow].self, mine).first
            let canView = userID == viewer || !profile.isPrivate || relation?.status == "accepted"
            return ProfileSummary(profile: profile, followers: followers, following: following, tastings: tastings,
                                  isFollowing: relation != nil, canViewContent: canView)
        }
    }

    func searchUsers(_ text: String) async throws -> [Profile] {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ")
        guard !trimmed.isEmpty else { return try await suggestedUsers(limit: 20) }
        return try await run {
            let data = try await client.from("profiles").select()
                .or("username.ilike.%\(trimmed)%,display_name.ilike.%\(trimmed)%").limit(30).execute().data
            let viewer = try? await me()
            return try decode([ProfileRow].self, data).map(\.profile).filter { $0.id != viewer }
        }
    }

    func suggestedUsers(limit: Int) async throws -> [Profile] {
        let viewer = try await me()
        return try await run {
            let following = Set(try await followingIDs(of: viewer))
            let data = try await client.from("profiles").select().eq("is_private", value: false)
                .order("created_at", ascending: false).limit(limit + following.count + 1).execute().data
            return try decode([ProfileRow].self, data).map(\.profile)
                .filter { $0.id != viewer && !following.contains($0.id) }.prefix(limit).map { $0 }
        }
    }

    private struct FollowInsert: Encodable {
        var follower_id: UUID
        var followee_id: UUID
    }

    func follow(_ userID: UUID) async throws {
        let viewer = try await me()
        try await run {
            try await client.from("user_follows").upsert(FollowInsert(follower_id: viewer, followee_id: userID),
                                                         onConflict: "follower_id,followee_id", ignoreDuplicates: true).execute()
        }
    }

    func unfollow(_ userID: UUID) async throws {
        let viewer = try await me()
        try await run {
            try await client.from("user_follows").delete()
                .eq("follower_id", value: viewer.uuidString).eq("followee_id", value: userID.uuidString).execute()
        }
    }

    func following(of userID: UUID) async throws -> [Profile] {
        try await run {
            let ids = try await followingIDs(of: userID)
            return Array(try await profiles(ids: ids).values).sorted { $0.username < $1.username }
        }
    }

    func followers(of userID: UUID) async throws -> [Profile] {
        try await run {
            let data = try await client.from("user_follows").select("follower_id,followee_id,status")
                .eq("followee_id", value: userID.uuidString).eq("status", value: "accepted").execute().data
            let ids = try decode([FollowRow].self, data).map(\.followerId)
            return Array(try await profiles(ids: ids).values).sorted { $0.username < $1.username }
        }
    }

    func feed(before: Date?, limit: Int) async throws -> [FeedItem] {
        let viewer = try await me()
        return try await run {
            let circle = (try await followingIDs(of: viewer) + [viewer]).map(\.uuidString)
            var query = client.from("activities").select("id,actor_id,kind,vintage_id,entry_id,created_at")
                .in("actor_id", values: circle)
            if let before {
                query = query.lt("created_at", value: ISO8601DateFormatter().string(from: before))
            }
            let data = try await query.order("created_at", ascending: false).limit(limit).execute().data
            let activities = try decode([ActivityRow].self, data)

            let entryIDs = activities.compactMap(\.entryId).map(\.uuidString)
            var entries: [UUID: ReviewItem] = [:]
            if !entryIDs.isEmpty {
                let rows = try await client.from("tasting_entries").select(Self.entryColumns).in("id", values: entryIDs).execute().data
                entries = Dictionary(try await hydrate(try decode([TastingRow].self, rows)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            let wines = try await wines(ids: activities.compactMap(\.vintageId))
            let actors = try await profiles(ids: activities.map(\.actorId))
            return activities.compactMap { a in
                guard let actor = actors[a.actorId] else { return nil }
                let item = a.entryId.flatMap { entries[$0] }
                if a.kind == .rated && item == nil { return nil }
                return FeedItem(id: a.id, kind: a.kind, actor: actor, wine: item?.wine ?? a.vintageId.flatMap { wines[$0] },
                                entry: item?.entry, createdAt: a.createdAt)
            }
        }
    }

    private struct LikeRow: Encodable {
        var entry_id: UUID
        var user_id: UUID
    }

    func setLike(_ liked: Bool, entryID: UUID) async throws {
        let viewer = try await me()
        try await run {
            if liked {
                try await client.from("review_likes").upsert(LikeRow(entry_id: entryID, user_id: viewer),
                                                            onConflict: "entry_id,user_id", ignoreDuplicates: true).execute()
            } else {
                try await client.from("review_likes").delete()
                    .eq("entry_id", value: entryID.uuidString).eq("user_id", value: viewer.uuidString).execute()
            }
        }
    }

    func comments(entryID: UUID) async throws -> [ReviewComment] {
        try await run {
            let data = try await client.from("review_comments").select()
                .eq("entry_id", value: entryID.uuidString).order("created_at", ascending: true).execute().data
            let rows = try decode([CommentRow].self, data)
            let people = try await profiles(ids: rows.map(\.userId))
            return rows.compactMap { r in
                people[r.userId].map { ReviewComment(id: r.id, entryID: r.entryId, author: $0, body: r.body, createdAt: r.createdAt) }
            }
        }
    }

    private struct CommentInsert: Encodable {
        var entry_id: UUID
        var user_id: UUID
        var body: String
    }

    func addComment(_ body: String, entryID: UUID) async throws -> ReviewComment {
        let viewer = try await me()
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1000 else { throw AppError.validation("Comments must be 1–1000 characters.") }
        return try await run {
            let data = try await client.from("review_comments").insert(CommentInsert(entry_id: entryID, user_id: viewer, body: text))
                .select().single().execute().data
            let row = try decode(CommentRow.self, data)
            let author = try await loadProfile(viewer)
            return ReviewComment(id: row.id, entryID: row.entryId, author: author, body: row.body, createdAt: row.createdAt)
        }
    }

    func notifications() async throws -> [AppNotification] {
        try await run {
            let data = try await client.from("notifications").select("id,actor_id,kind,entry_id,created_at,read_at")
                .order("created_at", ascending: false).limit(100).execute().data
            let rows = try decode([NotificationRow].self, data)
            let actors = try await profiles(ids: rows.map(\.actorId))
            return rows.compactMap { r in
                guard let actor = actors[r.actorId] else { return nil }
                let kind: NotificationKind = switch r.kind {
                case "like": .like
                case "comment": .comment
                case "tag": .tag
                default: .follow
                }
                return AppNotification(id: r.id, kind: kind, actor: actor, entryID: r.entryId, wineName: nil,
                                       createdAt: r.createdAt, isRead: r.readAt != nil)
            }
        }
    }

    func markNotificationsRead() async throws {
        try await run {
            try await client.from("notifications").update(["read_at": ISO8601DateFormatter().string(from: .now)])
                .is("read_at", value: nil).execute()
        }
    }

    private struct BlockRow: Codable {
        var blocker_id: UUID
        var blocked_id: UUID
    }

    func block(_ userID: UUID) async throws {
        let viewer = try await me()
        try await run {
            // A trigger removes follows in both directions.
            try await client.from("user_blocks").upsert(BlockRow(blocker_id: viewer, blocked_id: userID),
                                                       onConflict: "blocker_id,blocked_id", ignoreDuplicates: true).execute()
        }
    }

    func unblock(_ userID: UUID) async throws {
        let viewer = try await me()
        try await run {
            try await client.from("user_blocks").delete()
                .eq("blocker_id", value: viewer.uuidString).eq("blocked_id", value: userID.uuidString).execute()
        }
    }

    func blockedUsers() async throws -> [Profile] {
        try await run {
            let data = try await client.from("user_blocks").select("blocker_id,blocked_id").execute().data
            let rows = try JSONDecoder().decode([BlockRow].self, from: data)
            return Array(try await profiles(ids: rows.map(\.blocked_id)).values).sorted { $0.username < $1.username }
        }
    }

    private struct ReportInsert: Encodable {
        var reporter_id: UUID
        var reported_user_id: UUID?
        var entry_id: UUID?
        var comment_id: UUID?
        var reason: ReportReason
        var details: String?
    }

    func report(_ target: ReportTarget, reason: ReportReason, details: String?) async throws {
        let viewer = try await me()
        var insert = ReportInsert(reporter_id: viewer, reason: reason, details: details?.nilIfBlank)
        switch target {
        case .user(let id): insert.reported_user_id = id
        case .entry(let id, let author): insert.entry_id = id; insert.reported_user_id = author
        case .comment(let id, let author): insert.comment_id = id; insert.reported_user_id = author
        }
        try await run {
            // Reporting the same thing twice is a no-op (unique index), not an error for the user.
            do {
                try await client.from("content_reports").insert(insert).execute()
            } catch let error as PostgrestError where error.code == "23505" {
                return
            }
        }
    }

    // MARK: - CellarService

    private static let bottleColumns = "id,vintage_id,quantity,consumed_count,purchase_price,currency,purchase_date,storage_location,collection_id,added_at"

    private func hydrateBottles(_ rows: [BottleRow]) async throws -> [CellarBottle] {
        let wines = try await wines(ids: rows.map(\.vintageId))
        return rows.compactMap { r in
            wines[r.vintageId].map { wine in
                CellarBottle(id: r.id, wine: wine, quantity: r.quantity,
                             purchasePrice: r.purchasePrice.map { Price(amount: Decimal($0), currency: r.currency) },
                             purchaseDate: r.purchaseDate, storageLocation: r.storageLocation, collectionID: r.collectionId,
                             addedAt: r.addedAt, consumedCount: r.consumedCount)
            }
        }
    }

    func bottles() async throws -> [CellarBottle] {
        do {
            let data = try await client.from("cellar_bottles").select(Self.bottleColumns).order("added_at", ascending: false).execute().data
            let bottles = try await hydrateBottles(try decode([BottleRow].self, data))
            await cacheBottles(bottles)
            return bottles
        } catch {
            // Offline: fall back to the last synced cellar.
            let cached = await cachedBottles()
            if !cached.isEmpty { return cached }
            throw mapError(error)
        }
    }

    func addBottle(wineID: UUID, draft: CellarBottleDraft) async throws -> CellarBottle {
        let userID = try await me()
        guard draft.quantity > 0 else { throw AppError.validation("Quantity must be at least 1.") }
        return try await run {
            let existing = try await client.from("cellar_bottles").select(Self.bottleColumns)
                .eq("vintage_id", value: wineID.uuidString).execute().data
            if let match = try decode([BottleRow].self, existing).first(where: { $0.collectionId == draft.collectionID }) {
                let data = try await client.from("cellar_bottles").update(["quantity": match.quantity + draft.quantity])
                    .eq("id", value: match.id.uuidString).select(Self.bottleColumns).single().execute().data
                guard let bottle = try await hydrateBottles([try decode(BottleRow.self, data)]).first else { throw AppError.notFound }
                return bottle
            }
            let write = BottleWrite(userId: userID, vintageId: wineID, quantity: draft.quantity, consumedCount: 0,
                                    purchasePrice: draft.purchasePrice, currency: draft.currency,
                                    purchaseDate: draft.purchaseDate.map(SupabaseCoding.dayString),
                                    storageLocation: draft.storageLocation.nilIfBlank, collectionId: draft.collectionID)
            let data = try await client.from("cellar_bottles").insert(write).select(Self.bottleColumns).single().execute().data
            guard let bottle = try await hydrateBottles([try decode(BottleRow.self, data)]).first else { throw AppError.notFound }
            return bottle
        }
    }

    func updateBottle(_ bottle: CellarBottle) async throws {
        let userID = try await me()
        try await run {
            let write = BottleWrite(userId: userID, vintageId: bottle.wine.id, quantity: max(0, bottle.quantity),
                                    consumedCount: bottle.consumedCount, purchasePrice: bottle.purchasePrice?.doubleValue,
                                    currency: bottle.purchasePrice?.currency ?? "USD",
                                    purchaseDate: bottle.purchaseDate.map(SupabaseCoding.dayString),
                                    storageLocation: bottle.storageLocation, collectionId: bottle.collectionID)
            try await client.from("cellar_bottles").update(write).eq("id", value: bottle.id.uuidString).execute()
        }
    }

    func consumeBottle(id: UUID) async throws -> CellarBottle {
        try await run {
            let data = try await client.from("cellar_bottles").select(Self.bottleColumns).eq("id", value: id.uuidString).single().execute().data
            let row = try decode(BottleRow.self, data)
            guard row.quantity > 0 else { throw AppError.validation("No bottles left to open.") }
            let updated = try await client.from("cellar_bottles")
                .update(["quantity": row.quantity - 1, "consumed_count": row.consumedCount + 1])
                .eq("id", value: id.uuidString).eq("quantity", value: row.quantity) // optimistic concurrency
                .select(Self.bottleColumns).single().execute().data
            if row.quantity - 1 == 0 {
                try await client.from("cellar_placements").delete().eq("bottle_id", value: id.uuidString).execute()
            }
            guard let bottle = try await hydrateBottles([try decode(BottleRow.self, updated)]).first else { throw AppError.notFound }
            return bottle
        }
    }

    func removeBottle(id: UUID) async throws {
        try await run { try await client.from("cellar_bottles").delete().eq("id", value: id.uuidString).execute() }
    }

    func placements() async throws -> [CellarPlacement] {
        try await run {
            let data = try await client.from("cellar_placements").select("bottle_id,shelf_index,slot_index").execute().data
            return try decode([PlacementRow].self, data).map { CellarPlacement(bottleID: $0.bottleId, shelf: $0.shelfIndex, slot: $0.slotIndex) }
        }
    }

    private struct PlacementParam: Encodable {
        var bottle_id: UUID
        var shelf_index: Int
        var slot_index: Int
    }

    func savePlacements(_ placements: [CellarPlacement]) async throws {
        try await run {
            let payload = placements.map { PlacementParam(bottle_id: $0.bottleID, shelf_index: $0.shelf, slot_index: $0.slot) }
            try await client.rpc("save_cellar_placements", params: ["placements": payload]).execute()
        }
    }

    func collections() async throws -> [CellarCollection] {
        try await run {
            let data = try await client.from("cellar_collections").select("id,name,symbol,created_at").order("created_at").execute().data
            return try decode([CollectionRow].self, data).map { CellarCollection(id: $0.id, name: $0.name, symbol: $0.symbol, createdAt: $0.createdAt) }
        }
    }

    private struct CollectionInsert: Encodable {
        var user_id: UUID
        var name: String
        var symbol: String
    }

    func createCollection(name: String, symbol: String) async throws -> CellarCollection {
        let userID = try await me()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw AppError.validation("Give your collection a name.") }
        return try await run {
            let data = try await client.from("cellar_collections").insert(CollectionInsert(user_id: userID, name: trimmed, symbol: symbol))
                .select("id,name,symbol,created_at").single().execute().data
            let row = try decode(CollectionRow.self, data)
            return CellarCollection(id: row.id, name: row.name, symbol: row.symbol, createdAt: row.createdAt)
        }
    }

    func settings() async throws -> CellarSettings {
        let userID = try await me()
        let prefers2D = await local.read(\.settings.prefers2D)
        return try await run {
            let data = try await client.from("profiles").select().eq("id", value: userID.uuidString).single().execute().data
            let row = try decode(ProfileRow.self, data)
            return CellarSettings(finish: row.cellarFinish.flatMap(ShelfFinish.init(rawValue:)) ?? .walnut,
                                  sort: row.cellarSort.flatMap(CellarSort.init(rawValue:)) ?? .manual,
                                  prefers2D: prefers2D)
        }
    }

    func saveSettings(_ settings: CellarSettings) async throws {
        let userID = try await me()
        await local.write { $0.settings.prefers2D = settings.prefers2D }
        try await run {
            try await client.from("profiles").update(["cellar_finish": settings.finish.rawValue, "cellar_sort": settings.sort.rawValue])
                .eq("id", value: userID.uuidString).execute()
        }
    }

    func wishlist() async throws -> [WishlistItem] {
        try await run {
            let data = try await client.from("wishlists").select("vintage_id,created_at").order("created_at", ascending: false).execute().data
            let rows = try decode([WishlistRow].self, data)
            let wines = try await wines(ids: rows.map(\.vintageId))
            return rows.compactMap { r in wines[r.vintageId].map { WishlistItem(id: r.vintageId, wine: $0, addedAt: r.createdAt) } }
        }
    }

    private struct WishInsert: Encodable {
        var user_id: UUID
        var vintage_id: UUID
    }

    func setWishlisted(_ wishlisted: Bool, wineID: UUID) async throws {
        let userID = try await me()
        try await run {
            if wishlisted {
                try await client.from("wishlists").upsert(WishInsert(user_id: userID, vintage_id: wineID),
                                                         onConflict: "user_id,vintage_id", ignoreDuplicates: true).execute()
            } else {
                try await client.from("wishlists").delete().eq("vintage_id", value: wineID.uuidString).execute()
            }
        }
    }

    // MARK: - ScanHistoryService

    private struct ScanInsert: Encodable {
        var id: UUID
        var user_id: UUID
        var vintage_id: UUID?
        var label_image_path: String?
        var confidence: Double?
    }

    func record(_ record: ScanRecord) async throws {
        let userID = try await me()
        try await run {
            try await client.from("scan_history").insert(ScanInsert(id: record.id, user_id: userID, vintage_id: record.wineID,
                                                                     label_image_path: record.labelImagePath,
                                                                     confidence: record.confidence)).execute()
        }
    }

    func history(limit: Int) async throws -> [ScanRecord] {
        try await run {
            let data = try await client.from("scan_history").select("id,vintage_id,label_image_path,confidence,created_at")
                .order("created_at", ascending: false).limit(limit).execute().data
            let rows = try decode([ScanRow].self, data)
            let wines = try await wines(ids: rows.compactMap(\.vintageId))
            return rows.map { r in
                ScanRecord(id: r.id, wineID: r.vintageId, wineName: r.vintageId.flatMap { wines[$0]?.displayName },
                           labelImagePath: r.labelImagePath, confidence: r.confidence, createdAt: r.createdAt)
            }
        }
    }

    func cachedMatch(forTextKey key: String) async -> UUID? {
        await local.read { $0.textCache[key] }
    }

    func cacheMatch(textKey: String, wineID: UUID) async {
        guard !textKey.isEmpty else { return }
        await local.write { $0.textCache[textKey] = wineID }
    }

    // MARK: - MediaService

    func storeLabel(_ jpeg: Data, id: UUID) async throws -> String {
        try await upload(jpeg, bucket: "labels", id: id)
    }

    func storePhoto(_ jpeg: Data, id: UUID) async throws -> String {
        try await upload(jpeg, bucket: "tasting-photos", id: id)
    }

    private func upload(_ jpeg: Data, bucket: String, id: UUID) async throws -> String {
        let userID = try await me()
        let object = "\(userID.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg"
        return try await run {
            try await client.storage.from(bucket).upload(object, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
            // Keep a local copy so the label renders instantly and offline.
            _ = try? LocalFiles.write(jpeg, folder: "uploads/\(bucket)", name: "\(id).jpg")
            return "\(bucket)/\(object)"
        }
    }

    // MARK: - RemoteLabelReader

    private struct IdentifyRequest: Encodable {
        var image_base64: String
        var ocr_text: [String]
        var text_key: String
    }

    func read(_ capture: LabelCapture) async throws -> RemoteLabelReading {
        try await run {
            let request = IdentifyRequest(image_base64: capture.imageJPEG.base64EncodedString(),
                                          ocr_text: capture.textLines, text_key: capture.normalizedTextKey)
            let response: IdentifyResponse = try await client.functions.invoke(
                "identify-wine", options: FunctionInvokeOptions(body: request), decoder: SupabaseCoding.decoder)
            let l = response.extraction
            let extraction = LabelExtraction(
                producer: l.producer, wineName: l.wineName, vintage: l.vintage, type: l.type, grapes: l.grapes ?? [],
                country: l.country, region: l.region, appellation: l.appellation, abv: l.abv, volumeML: l.volumeMl,
                rawText: capture.textLines)
            let suggestion = response.suggestion.map { s in
                AITastingSuggestion(
                    characteristics: s.characteristics.map { c in
                        WineCharacteristics(
                            sweetness: c.sweetness, acidity: c.acidity, body: c.body, tannin: c.tannin, fruitiness: c.fruitiness,
                            flavors: c.flavors ?? [], tastingNotes: s.summary,
                            servingTempC: c.serveMinC.flatMap { min in c.serveMaxC.map { min...max($0, min) } },
                            decantMinutes: c.decantMinutes, agingPotentialYears: c.agingYears, source: .aiSuggested)
                    },
                    pairings: s.pairings ?? [], summary: s.summary)
            }
            return RemoteLabelReading(scanKey: response.textHash, extraction: extraction,
                                      candidateWineIDs: response.candidates.map { ($0.vintageId, $0.score) },
                                      suggestion: suggestion, identityConfidence: response.identityConfidence)
        }
    }

    // MARK: - Offline snapshots

    private func cacheBottles(_ bottles: [CellarBottle]) async {
        guard let data = try? JSONEncoder().encode(bottles) else { return }
        try? data.write(to: LocalFiles.root.appendingPathComponent("offline-cellar.json"), options: .atomic)
    }

    private func cachedBottles() async -> [CellarBottle] {
        guard let data = try? Data(contentsOf: LocalFiles.root.appendingPathComponent("offline-cellar.json")) else { return [] }
        return (try? JSONDecoder().decode([CellarBottle].self, from: data)) ?? []
    }

    private func cacheHistory(_ items: [ReviewItem]) async {
        // Wines in the tasting history are cached for offline Wine History browsing.
        await local.write { s in
            for item in items { s.wines[item.wine.id] = item.wine }
        }
    }
}
