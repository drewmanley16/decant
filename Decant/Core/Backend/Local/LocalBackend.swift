import Foundation

/// Local Mode implementation of every service, backed by `LocalStore`.
/// Mirrors the server's visibility rules (friends = mutual follows).
final class LocalBackend: AuthService, WineCatalogService, TastingService, SocialService, CellarService,
    ScanHistoryService, MediaService, Sendable {
    let store: LocalStore

    init(store: LocalStore = LocalStore()) {
        self.store = store
    }

    private func me() async throws -> UUID {
        guard let id = await store.read({ $0.currentUserID }) else { throw AppError.notSignedIn }
        return id
    }

    // MARK: - Visibility & hydration (pure, on a snapshot)

    private static func follows(_ s: LocalSnapshot, _ a: UUID, _ b: UUID) -> Bool {
        s.follows.contains { $0.follower == a && $0.followee == b && !$0.pending }
    }

    private static func isBlocked(_ s: LocalSnapshot, _ a: UUID, _ b: UUID) -> Bool {
        (s.blocks ?? []).contains { ($0.blocker == a && $0.blocked == b) || ($0.blocker == b && $0.blocked == a) }
    }

    /// Visibility rules plus safety: blocks hide content both ways; reported items vanish for the reporter.
    private static func canSee(_ s: LocalSnapshot, _ e: TastingEntry, viewer: UUID?) -> Bool {
        guard canView(s, owner: e.userID, visibility: e.visibility, viewer: viewer) else { return false }
        guard let viewer, e.userID != viewer else { return true }
        return !(s.reports ?? []).contains { $0.reporter == viewer && $0.entryID == e.id }
    }

    private static func canView(_ s: LocalSnapshot, owner: UUID, visibility: Visibility, viewer: UUID?) -> Bool {
        guard let viewer else { return visibility == .everyone }
        if owner == viewer { return true }
        if isBlocked(s, viewer, owner) { return false }
        let profileOpen = !(s.profiles[owner]?.isPrivate ?? false) || follows(s, viewer, owner)
        switch visibility {
        case .everyone: return profileOpen
        case .friends: return follows(s, viewer, owner) && follows(s, owner, viewer)
        case .onlyMe: return false
        }
    }

    private static func hydrate(_ s: LocalSnapshot, wine id: UUID) -> Wine? {
        guard var wine = s.wines[id] else { return nil }
        let ratings = s.entries.filter { $0.wineID == id && $0.visibility == .everyone }.compactMap(\.rating)
        wine.ratingsCount = ratings.count
        wine.communityRating = ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)
        return wine
    }

    private static func hydrate(_ s: LocalSnapshot, entry: TastingEntry, viewer: UUID?) -> TastingEntry {
        var e = entry
        e.likeCount = s.likes.filter { $0.entryID == entry.id }.count
        e.commentCount = s.comments.filter { $0.entryID == entry.id }.count
        e.likedByMe = viewer.map { v in s.likes.contains { $0.entryID == entry.id && $0.userID == v } } ?? false
        if entry.userID != viewer { e.personalNotes = nil }
        return e
    }

    private static func reviewItem(_ s: LocalSnapshot, _ entry: TastingEntry, viewer: UUID?) -> ReviewItem? {
        guard let author = s.profiles[entry.userID], let wine = hydrate(s, wine: entry.wineID) else { return nil }
        return ReviewItem(entry: hydrate(s, entry: entry, viewer: viewer), author: author, wine: wine)
    }

    private static func bottle(_ s: LocalSnapshot, _ b: LocalSnapshot.Bottle) -> CellarBottle? {
        guard let wine = hydrate(s, wine: b.wineID) else { return nil }
        return CellarBottle(id: b.id, wine: wine, quantity: b.quantity, purchasePrice: b.purchasePrice,
                            purchaseDate: b.purchaseDate, storageLocation: b.storageLocation,
                            collectionID: b.collectionID, addedAt: b.addedAt, consumedCount: b.consumedCount)
    }

    // MARK: - AuthService

    var supportsAppleSignIn: Bool { false }
    var supportsEmailSignIn: Bool { false }

    func restoreSession() async -> Profile? {
        await store.read { s in s.currentUserID.flatMap { s.profiles[$0] } }
    }

    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws -> Profile {
        throw AppError.unavailable("Sign in with Apple needs a Supabase project. See README → Backend setup.")
    }

    func signIn(email: String, password: String) async throws -> Profile {
        throw AppError.unavailable("Email sign-in needs a Supabase project.")
    }

    func signUp(email: String, password: String, username: String) async throws -> Profile {
        throw AppError.unavailable("Email sign-up needs a Supabase project.")
    }

    func startLocalSession(username: String, displayName: String) async throws -> Profile {
        let handle = username.trimmingCharacters(in: .whitespaces).lowercased()
        guard handle.range(of: #"^[a-z0-9_.]{3,30}$"#, options: .regularExpression) != nil else {
            throw AppError.validation("Usernames are 3–30 letters, numbers, dots or underscores.")
        }
        return await store.write { s in
            let profile = Profile(id: UUID(), username: handle, displayName: displayName.isEmpty ? handle : displayName,
                                  avatarURL: nil, bio: nil, isPrivate: false, favoriteTypes: [],
                                  defaultVisibility: .everyone, createdAt: .now)
            s.profiles[profile.id] = profile
            s.currentUserID = profile.id
            LocalStore.seedCommunity(into: &s, for: profile.id)
            return profile
        }
    }

    func updateProfile(_ profile: Profile) async throws -> Profile {
        let id = try await me()
        guard profile.id == id else { throw AppError.validation("You can only edit your own profile.") }
        await store.write { $0.profiles[id] = profile }
        return profile
    }

    func uploadAvatar(_ jpeg: Data) async throws -> URL {
        let id = try await me()
        let path = try LocalFiles.write(jpeg, folder: "avatars", name: "\(id)-\(Int(Date().timeIntervalSince1970)).jpg")
        guard let url = LocalFiles.url(forFilePath: path) else { throw AppError.server("Could not save avatar.") }
        return url
    }

    func signOut() async throws {
        await store.write { $0.currentUserID = nil }
    }

    func recordTermsAcceptance() async {}

    func deleteAccount() async throws {
        await store.reset()
        try? FileManager.default.removeItem(at: LocalFiles.root.appendingPathComponent("labels"))
        try? FileManager.default.removeItem(at: LocalFiles.root.appendingPathComponent("photos"))
        try? FileManager.default.removeItem(at: LocalFiles.root.appendingPathComponent("avatars"))
    }

    // MARK: - WineCatalogService

    func search(_ query: WineSearchQuery, limit: Int) async throws -> [Wine] {
        await store.read { s in
            let text = TextNormalizer.fold(query.text.trimmingCharacters(in: .whitespaces))
            return s.wines.keys.compactMap { Self.hydrate(s, wine: $0) }
                .filter { wine in
                    if !text.isEmpty {
                        let haystack = TextNormalizer.fold([wine.name, wine.producer, wine.region ?? "", wine.appellation ?? "",
                                                            wine.country ?? "", wine.grapeLine, wine.vintageLabel].joined(separator: " "))
                        guard text.split(separator: " ").allSatisfy({ haystack.contains($0) }) else { return false }
                    }
                    if !query.types.isEmpty, !query.types.contains(wine.type) { return false }
                    if let c = query.country, wine.country != c { return false }
                    if let r = query.region, wine.region != r { return false }
                    if let g = query.grape, !wine.grapes.contains(where: { $0.name == g }) { return false }
                    if let v = query.vintage, wine.vintage != v { return false }
                    if let p = query.maxPrice, (wine.price?.doubleValue ?? .infinity) > p { return false }
                    if let r = query.minRating, (wine.communityRating ?? 0) < r { return false }
                    return true
                }
                .sorted { ($0.ratingsCount, $1.name) > ($1.ratingsCount, $0.name) }
                .prefix(limit).map { $0 }
        }
    }

    func wine(id: UUID) async throws -> Wine {
        guard let wine = await store.read({ Self.hydrate($0, wine: id) }) else { throw AppError.notFound }
        return wine
    }

    func vintages(ofProduct productID: UUID) async throws -> [Wine] {
        await store.read { s in
            s.wines.values.filter { $0.productID == productID }.compactMap { Self.hydrate(s, wine: $0.id) }
                .sorted { ($0.vintage ?? 0) > ($1.vintage ?? 0) }
        }
    }

    func catalogSample(limit: Int) async throws -> [Wine] {
        await store.read { s in s.wines.keys.prefix(limit).compactMap { Self.hydrate(s, wine: $0) } }
    }

    func createWine(from draft: WineDraft, scanKey: String?, suggestion: AITastingSuggestion?) async throws -> Wine {
        guard draft.isValid else { throw AppError.validation("A wine needs at least a name and a producer.") }
        let created = await store.write { s -> Wine in
            let producerKey = TextNormalizer.fold(draft.producer)
            let nameKey = TextNormalizer.fold(draft.name)
            let existingProduct = s.wines.values.first {
                TextNormalizer.fold($0.producer) == producerKey && TextNormalizer.fold($0.name) == nameKey
            }
            if let existingProduct,
               let vintage = s.wines.values.first(where: {
                   $0.productID == existingProduct.productID && $0.vintage == draft.vintage && $0.bottleSizeML == draft.bottleSizeML
               }) {
                return vintage
            }
            let winery = s.wines.values.first { TextNormalizer.fold($0.producer) == producerKey }?.winery
                ?? Winery(name: draft.producer.trimmingCharacters(in: .whitespaces),
                          country: draft.country.nilIfBlank, region: draft.region.nilIfBlank, source: draft.source)
            var wine = Wine(
                id: UUID(), productID: existingProduct?.productID ?? UUID(),
                name: draft.name.trimmingCharacters(in: .whitespaces), winery: winery, vintage: draft.vintage,
                type: existingProduct?.type ?? draft.type,
                grapes: existingProduct?.grapes ?? draft.grapes.map { GrapeShare(name: $0) },
                country: existingProduct?.country ?? draft.country.nilIfBlank,
                region: existingProduct?.region ?? draft.region.nilIfBlank,
                appellation: existingProduct?.appellation ?? draft.appellation.nilIfBlank,
                abv: draft.abv, bottleSizeML: draft.bottleSizeML,
                price: draft.priceAmount.map { Price(amount: Decimal($0), currency: draft.currency) },
                labelImagePath: draft.labelImagePath, bottleImagePath: nil, drinkFrom: nil, drinkUntil: nil,
                characteristics: existingProduct?.characteristics, pairings: existingProduct?.pairings ?? [],
                factsSource: draft.source, communityRating: nil, ratingsCount: 0
            )
            if wine.characteristics == nil, let suggestion {
                wine.characteristics = suggestion.characteristics
                wine.pairings = suggestion.pairings
            }
            s.wines[wine.id] = wine
            return wine
        }
        return created
    }

    func attachSuggestion(_ suggestion: AITastingSuggestion, scanKey: String?, to wineID: UUID) async throws {
        await store.write { s in
            guard var wine = s.wines[wineID], wine.characteristics == nil else { return }
            wine.characteristics = suggestion.characteristics
            if wine.pairings.isEmpty { wine.pairings = suggestion.pairings }
            s.wines[wineID] = wine
        }
    }

    func setLabelImage(path: String, for wineID: UUID) async throws {
        await store.write { s in
            guard s.wines[wineID]?.labelImagePath == nil else { return }
            s.wines[wineID]?.labelImagePath = path
        }
    }

    func recordView(of wineID: UUID) async {
        await store.write { s in
            s.recentlyViewed.removeAll { $0 == wineID }
            s.recentlyViewed.insert(wineID, at: 0)
            s.recentlyViewed = Array(s.recentlyViewed.prefix(30))
        }
    }

    func recentlyViewed(limit: Int) async throws -> [Wine] {
        await store.read { s in s.recentlyViewed.prefix(limit).compactMap { Self.hydrate(s, wine: $0) } }
    }

    // MARK: - TastingService

    func addEntry(for wineID: UUID, draft: TastingDraft) async throws -> TastingEntry {
        let id = try await me()
        return await store.write { s in
            let entry = TastingEntry(
                id: UUID(), userID: id, wineID: wineID, rating: draft.rating.map(TastingEntry.normalizedRating),
                review: draft.review.nilIfBlank, personalNotes: draft.personalNotes.nilIfBlank,
                photoPaths: draft.photoPaths, consumedOn: draft.consumedOn, location: draft.location.nilIfBlank,
                occasion: draft.occasion.nilIfBlank, taggedUserIDs: draft.taggedUserIDs, drinkAgain: draft.drinkAgain,
                isFavorite: draft.isFavorite, visibility: draft.visibility, createdAt: .now,
                likeCount: 0, commentCount: 0, likedByMe: false
            )
            s.entries.append(entry)
            for tagged in draft.taggedUserIDs where tagged != id {
                s.notifications.append(.init(id: UUID(), recipient: tagged, actor: id, kind: .tag,
                                             entryID: entry.id, createdAt: .now, read: false))
            }
            return entry
        }
    }

    func updateEntry(_ entry: TastingEntry) async throws {
        let id = try await me()
        guard entry.userID == id else { throw AppError.validation("You can only edit your own tastings.") }
        await store.write { s in
            if let index = s.entries.firstIndex(where: { $0.id == entry.id }) { s.entries[index] = entry }
        }
    }

    func deleteEntry(id entryID: UUID) async throws {
        let id = try await me()
        await store.write { s in
            s.entries.removeAll { $0.id == entryID && $0.userID == id }
            s.likes.removeAll { $0.entryID == entryID }
            s.comments.removeAll { $0.entryID == entryID }
        }
    }

    func entries(forUser userID: UUID) async throws -> [ReviewItem] {
        let viewer = try await me()
        return await store.read { s in
            s.entries.filter { $0.userID == userID && Self.canSee(s, $0, viewer: viewer) }
                .sorted { $0.consumedOn > $1.consumedOn }
                .compactMap { Self.reviewItem(s, $0, viewer: viewer) }
        }
    }

    func reviews(forWine wineID: UUID, limit: Int) async throws -> [ReviewItem] {
        let viewer = try await me()
        return await store.read { s in
            s.entries.filter { $0.wineID == wineID && $0.review != nil && Self.canSee(s, $0, viewer: viewer) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
                .compactMap { Self.reviewItem(s, $0, viewer: viewer) }
        }
    }

    func friendRatings(forWine wineID: UUID) async throws -> [FriendRating] {
        let viewer = try await me()
        return await store.read { s in
            s.entries.filter { entry in
                entry.wineID == wineID && entry.userID != viewer && Self.follows(s, viewer, entry.userID)
                    && Self.canSee(s, entry, viewer: viewer)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { e in s.profiles[e.userID].map { FriendRating(friend: $0, rating: e.rating, entryID: e.id) } }
        }
    }

    func entry(id entryID: UUID) async throws -> ReviewItem {
        let viewer = try await me()
        let item = await store.read { s -> ReviewItem? in
            guard let e = s.entries.first(where: { $0.id == entryID }),
                  Self.canSee(s, e, viewer: viewer) else { return nil }
            return Self.reviewItem(s, e, viewer: viewer)
        }
        guard let item else { throw AppError.notFound }
        return item
    }

    // MARK: - SocialService

    func profileSummary(userID: UUID) async throws -> ProfileSummary {
        let viewer = try await me()
        let summary = await store.read { s -> ProfileSummary? in
            guard let profile = s.profiles[userID] else { return nil }
            let canView = userID == viewer || !profile.isPrivate || Self.follows(s, viewer, userID)
            return ProfileSummary(
                profile: profile,
                followers: s.follows.filter { $0.followee == userID && !$0.pending }.count,
                following: s.follows.filter { $0.follower == userID && !$0.pending }.count,
                tastings: canView ? s.entries.filter { $0.userID == userID && Self.canView(s, owner: userID, visibility: $0.visibility, viewer: viewer) }.count : 0,
                isFollowing: s.follows.contains { $0.follower == viewer && $0.followee == userID },
                canViewContent: canView
            )
        }
        guard let summary else { throw AppError.notFound }
        return summary
    }

    func searchUsers(_ text: String) async throws -> [Profile] {
        let viewer = try await me()
        let needle = TextNormalizer.fold(text)
        return await store.read { s in
            s.profiles.values.filter { p in
                p.id != viewer && (needle.isEmpty || TextNormalizer.fold(p.username + " " + p.displayName).contains(needle))
            }
            .sorted { $0.username < $1.username }
        }
    }

    func suggestedUsers(limit: Int) async throws -> [Profile] {
        let viewer = try await me()
        return await store.read { s in
            s.profiles.values.filter { p in p.id != viewer && !s.follows.contains { $0.follower == viewer && $0.followee == p.id } }
                .prefix(limit).map { $0 }
        }
    }

    func follow(_ userID: UUID) async throws {
        let viewer = try await me()
        await store.write { s in
            guard viewer != userID, !Self.isBlocked(s, viewer, userID),
                  !s.follows.contains(where: { $0.follower == viewer && $0.followee == userID }) else { return }
            let pending = s.profiles[userID]?.isPrivate ?? false
            s.follows.append(.init(follower: viewer, followee: userID, pending: pending))
        }
    }

    func unfollow(_ userID: UUID) async throws {
        let viewer = try await me()
        await store.write { s in s.follows.removeAll { $0.follower == viewer && $0.followee == userID } }
    }

    func following(of userID: UUID) async throws -> [Profile] {
        await store.read { s in s.follows.filter { $0.follower == userID && !$0.pending }.compactMap { s.profiles[$0.followee] } }
    }

    func followers(of userID: UUID) async throws -> [Profile] {
        await store.read { s in s.follows.filter { $0.followee == userID && !$0.pending }.compactMap { s.profiles[$0.follower] } }
    }

    func feed(before: Date?, limit: Int) async throws -> [FeedItem] {
        let viewer = try await me()
        return await store.read { s in
            let circle = Set(s.follows.filter { $0.follower == viewer && !$0.pending }.map(\.followee)).union([viewer])
            let rated = s.entries
                .filter { circle.contains($0.userID) && Self.canSee(s, $0, viewer: viewer) && $0.visibility != .onlyMe }
                .compactMap { e -> FeedItem? in
                    guard let item = Self.reviewItem(s, e, viewer: viewer) else { return nil }
                    return FeedItem(id: e.id, kind: .rated, actor: item.author, wine: item.wine, entry: item.entry, createdAt: e.createdAt)
                }
            let cellared = s.bottles.compactMap { b -> FeedItem? in
                guard let actor = s.profiles[viewer], let wine = Self.hydrate(s, wine: b.wineID) else { return nil }
                return FeedItem(id: b.id, kind: .cellared, actor: actor, wine: wine, entry: nil, createdAt: b.addedAt)
            }
            return (rated + cellared)
                .filter { before == nil || $0.createdAt < before! }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func setLike(_ liked: Bool, entryID: UUID) async throws {
        let viewer = try await me()
        await store.write { s in
            s.likes.removeAll { $0.entryID == entryID && $0.userID == viewer }
            if liked { s.likes.append(.init(entryID: entryID, userID: viewer)) }
        }
    }

    func comments(entryID: UUID) async throws -> [ReviewComment] {
        let viewer = try await me()
        return await store.read { s in
            s.comments.filter { c in
                c.entryID == entryID && !Self.isBlocked(s, viewer, c.userID)
                    && !(s.reports ?? []).contains { $0.reporter == viewer && $0.commentID == c.id }
            }.sorted { $0.createdAt < $1.createdAt }.compactMap { c in
                s.profiles[c.userID].map { ReviewComment(id: c.id, entryID: c.entryID, author: $0, body: c.body, createdAt: c.createdAt) }
            }
        }
    }

    func addComment(_ body: String, entryID: UUID) async throws -> ReviewComment {
        let viewer = try await me()
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1000 else { throw AppError.validation("Comments must be 1–1000 characters.") }
        let comment = await store.write { s -> ReviewComment? in
            guard let author = s.profiles[viewer] else { return nil }
            let stored = LocalSnapshot.Comment(id: UUID(), entryID: entryID, userID: viewer, body: text, createdAt: .now)
            s.comments.append(stored)
            if let owner = s.entries.first(where: { $0.id == entryID })?.userID, owner != viewer {
                s.notifications.append(.init(id: UUID(), recipient: owner, actor: viewer, kind: .comment, entryID: entryID, createdAt: .now, read: false))
            }
            return ReviewComment(id: stored.id, entryID: entryID, author: author, body: text, createdAt: stored.createdAt)
        }
        guard let comment else { throw AppError.notSignedIn }
        return comment
    }

    func notifications() async throws -> [AppNotification] {
        let viewer = try await me()
        return await store.read { s in
            s.notifications.filter { $0.recipient == viewer && !Self.isBlocked(s, viewer, $0.actor) }.sorted { $0.createdAt > $1.createdAt }.compactMap { n in
                guard let actor = s.profiles[n.actor] else { return nil }
                let wineName = n.entryID.flatMap { id in s.entries.first { $0.id == id } }.flatMap { s.wines[$0.wineID]?.name }
                return AppNotification(id: n.id, kind: n.kind, actor: actor, entryID: n.entryID, wineName: wineName,
                                       createdAt: n.createdAt, isRead: n.read)
            }
        }
    }

    func markNotificationsRead() async throws {
        let viewer = try await me()
        await store.write { s in
            for i in s.notifications.indices where s.notifications[i].recipient == viewer { s.notifications[i].read = true }
        }
    }

    func block(_ userID: UUID) async throws {
        let viewer = try await me()
        await store.write { s in
            guard viewer != userID, !Self.isBlocked(s, viewer, userID) else { return }
            s.blocks = (s.blocks ?? []) + [.init(blocker: viewer, blocked: userID)]
            s.follows.removeAll { ($0.follower == viewer && $0.followee == userID) || ($0.follower == userID && $0.followee == viewer) }
        }
    }

    func unblock(_ userID: UUID) async throws {
        let viewer = try await me()
        await store.write { s in s.blocks?.removeAll { $0.blocker == viewer && $0.blocked == userID } }
    }

    func blockedUsers() async throws -> [Profile] {
        let viewer = try await me()
        return await store.read { s in (s.blocks ?? []).filter { $0.blocker == viewer }.compactMap { s.profiles[$0.blocked] } }
    }

    func report(_ target: ReportTarget, reason: ReportReason, details: String?) async throws {
        let viewer = try await me()
        await store.write { s in
            var report = LocalSnapshot.Report(id: UUID(), reporter: viewer, entryID: nil, commentID: nil, userID: nil,
                                              reason: reason, details: details?.nilIfBlank, createdAt: .now)
            switch target {
            case .user(let id): report.userID = id
            case .entry(let id, let author): report.entryID = id; report.userID = author
            case .comment(let id, let author): report.commentID = id; report.userID = author
            }
            s.reports = (s.reports ?? []) + [report]
        }
    }

    // MARK: - CellarService

    func bottles() async throws -> [CellarBottle] {
        await store.read { s in s.bottles.compactMap { Self.bottle(s, $0) }.sorted { $0.addedAt > $1.addedAt } }
    }

    func addBottle(wineID: UUID, draft: CellarBottleDraft) async throws -> CellarBottle {
        guard draft.quantity > 0 else { throw AppError.validation("Quantity must be at least 1.") }
        let bottle = await store.write { s -> CellarBottle? in
            // Adding the same wine again increases the stack instead of duplicating it.
            if let index = s.bottles.firstIndex(where: { $0.wineID == wineID && $0.collectionID == draft.collectionID }) {
                s.bottles[index].quantity += draft.quantity
                return Self.bottle(s, s.bottles[index])
            }
            let stored = LocalSnapshot.Bottle(
                id: UUID(), wineID: wineID, quantity: draft.quantity,
                purchasePrice: draft.purchasePrice.map { Price(amount: Decimal($0), currency: draft.currency) },
                purchaseDate: draft.purchaseDate, storageLocation: draft.storageLocation.nilIfBlank,
                collectionID: draft.collectionID, addedAt: .now, consumedCount: 0
            )
            s.bottles.append(stored)
            return Self.bottle(s, stored)
        }
        guard let bottle else { throw AppError.notFound }
        return bottle
    }

    func updateBottle(_ bottle: CellarBottle) async throws {
        await store.write { s in
            guard let i = s.bottles.firstIndex(where: { $0.id == bottle.id }) else { return }
            s.bottles[i].quantity = max(0, bottle.quantity)
            s.bottles[i].purchasePrice = bottle.purchasePrice
            s.bottles[i].purchaseDate = bottle.purchaseDate
            s.bottles[i].storageLocation = bottle.storageLocation
            s.bottles[i].collectionID = bottle.collectionID
        }
    }

    func consumeBottle(id: UUID) async throws -> CellarBottle {
        let bottle = await store.write { s -> CellarBottle? in
            guard let i = s.bottles.firstIndex(where: { $0.id == id }), s.bottles[i].quantity > 0 else { return nil }
            s.bottles[i].quantity -= 1
            s.bottles[i].consumedCount += 1
            if s.bottles[i].quantity == 0 { s.placements.removeAll { $0.bottleID == id } }
            return Self.bottle(s, s.bottles[i])
        }
        guard let bottle else { throw AppError.validation("No bottles left to open.") }
        return bottle
    }

    func removeBottle(id: UUID) async throws {
        await store.write { s in
            s.bottles.removeAll { $0.id == id }
            s.placements.removeAll { $0.bottleID == id }
        }
    }

    func placements() async throws -> [CellarPlacement] {
        await store.read(\.placements)
    }

    func savePlacements(_ placements: [CellarPlacement]) async throws {
        await store.write { $0.placements = placements }
    }

    func collections() async throws -> [CellarCollection] {
        await store.read { $0.collections.sorted { $0.createdAt < $1.createdAt } }
    }

    func createCollection(name: String, symbol: String) async throws -> CellarCollection {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw AppError.validation("Give your collection a name.") }
        return await store.write { s in
            let collection = CellarCollection(id: UUID(), name: trimmed, symbol: symbol, createdAt: .now)
            s.collections.append(collection)
            return collection
        }
    }

    func settings() async throws -> CellarSettings {
        await store.read(\.settings)
    }

    func saveSettings(_ settings: CellarSettings) async throws {
        await store.write { $0.settings = settings }
    }

    func wishlist() async throws -> [WishlistItem] {
        await store.read { s in
            s.wishlist.sorted { $0.addedAt > $1.addedAt }.compactMap { w in
                Self.hydrate(s, wine: w.wineID).map { WishlistItem(id: w.wineID, wine: $0, addedAt: w.addedAt) }
            }
        }
    }

    func setWishlisted(_ wishlisted: Bool, wineID: UUID) async throws {
        await store.write { s in
            s.wishlist.removeAll { $0.wineID == wineID }
            if wishlisted { s.wishlist.append(.init(wineID: wineID, addedAt: .now)) }
        }
    }

    // MARK: - ScanHistoryService

    func record(_ record: ScanRecord) async throws {
        await store.write { s in
            s.scans.insert(record, at: 0)
            s.scans = Array(s.scans.prefix(200))
        }
    }

    func history(limit: Int) async throws -> [ScanRecord] {
        await store.read { Array($0.scans.prefix(limit)) }
    }

    func cachedMatch(forTextKey key: String) async -> UUID? {
        await store.read { $0.textCache[key] }
    }

    func cacheMatch(textKey: String, wineID: UUID) async {
        guard !textKey.isEmpty else { return }
        await store.write { $0.textCache[textKey] = wineID }
    }

    // MARK: - MediaService

    func storeLabel(_ jpeg: Data, id: UUID) async throws -> String {
        try LocalFiles.write(jpeg, folder: "labels", name: "\(id).jpg")
    }

    func storePhoto(_ jpeg: Data, id: UUID) async throws -> String {
        try LocalFiles.write(jpeg, folder: "photos", name: "\(id).jpg")
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
