import Foundation
import Testing
@testable import Decant

/// Exercises the full journey and privacy rules against the on-device backend.
@Suite("Local backend")
struct LocalBackendTests {
    private func makeBackend() async throws -> (LocalBackend, Profile) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).json")
        let backend = LocalBackend(store: LocalStore(fileURL: url))
        let me = try await backend.startLocalSession(username: "tester", displayName: "Tester")
        return (backend, me)
    }

    @Test func rejectsInvalidUsernames() async throws {
        let backend = LocalBackend(store: LocalStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID()).json")))
        await #expect(throws: AppError.self) { try await backend.startLocalSession(username: "a!", displayName: "") }
    }

    @Test func criticalJourney() async throws {
        let (backend, me) = try await makeBackend()

        // Identify → details
        let wine = try #require(try await backend.search(WineSearchQuery(text: "margaux 2015"), limit: 5).first)
        #expect(wine.vintage == 2015)

        // Rate
        var draft = TastingDraft()
        draft.rating = 4.5
        draft.review = "Stunning"
        draft.personalNotes = "Secret"
        let entry = try await backend.addEntry(for: wine.id, draft: draft)
        #expect(entry.rating == 4.5)

        // Add to cellar (twice → stacks)
        _ = try await backend.addBottle(wineID: wine.id, draft: CellarBottleDraft(quantity: 2))
        let stacked = try await backend.addBottle(wineID: wine.id, draft: CellarBottleDraft(quantity: 1))
        #expect(stacked.quantity == 3)
        #expect(try await backend.bottles().count == 1)

        // Community rating reflects the public rating
        let refreshed = try await backend.wine(id: wine.id)
        #expect(refreshed.ratingsCount >= 1)

        // Consume keeps history
        var bottle = try await backend.consumeBottle(id: stacked.id)
        bottle = try await backend.consumeBottle(id: bottle.id)
        bottle = try await backend.consumeBottle(id: bottle.id)
        #expect(bottle.quantity == 0)
        #expect(bottle.consumedCount == 3)
        await #expect(throws: AppError.self) { try await backend.consumeBottle(id: bottle.id) }
        let history = StatsCalculator.history(try await backend.entries(forUser: me.id))
        #expect(history.contains { $0.wine.id == wine.id })
    }

    @Test func multipleEntriesForSameWine() async throws {
        let (backend, me) = try await makeBackend()
        let wine = try #require(try await backend.catalogSample(limit: 1).first)
        var draft = TastingDraft()
        draft.rating = 3
        _ = try await backend.addEntry(for: wine.id, draft: draft)
        draft.rating = 5
        _ = try await backend.addEntry(for: wine.id, draft: draft)
        let mine = try await backend.entries(forUser: me.id).filter { $0.wine.id == wine.id }
        #expect(mine.count == 2)
    }

    @Test func privateNotesAndPrivateEntriesStayPrivate() async throws {
        let (backend, me) = try await makeBackend()
        let wine = try #require(try await backend.catalogSample(limit: 1).first)
        var draft = TastingDraft()
        draft.rating = 4
        draft.review = "Only me"
        draft.personalNotes = "secret"
        draft.visibility = .onlyMe
        let entry = try await backend.addEntry(for: wine.id, draft: draft)

        // The owner sees notes.
        #expect(try await backend.entry(id: entry.id).entry.personalNotes == "secret")

        // Switch to a different user: the private entry is invisible.
        let other = try await backend.startLocalSession(username: "someone", displayName: "Someone")
        #expect(other.id != me.id)
        await #expect(throws: AppError.self) { try await backend.entry(id: entry.id) }
        #expect(try await backend.reviews(forWine: wine.id, limit: 50).allSatisfy { $0.id != entry.id })
    }

    @Test func friendsOnlyRequiresMutualFollow() async throws {
        let (backend, _) = try await makeBackend()
        // The sample community includes a friends-only Dom Pérignon review by a mutual friend.
        let dom = try #require(try await backend.search(WineSearchQuery(text: "Dom Pérignon"), limit: 1).first)
        #expect(try await !backend.reviews(forWine: dom.id, limit: 10).isEmpty)
        #expect(try await !backend.friendRatings(forWine: dom.id).isEmpty)
    }

    @Test func privateProfilesNeedApproval() async throws {
        let (backend, _) = try await makeBackend()
        let privateUser = try #require(LocalSampleCommunity.profiles.first { $0.isPrivate })
        try await backend.follow(privateUser.id)
        let summary = try await backend.profileSummary(userID: privateUser.id)
        #expect(summary.isFollowing)
        #expect(summary.canViewContent == false)
        #expect(try await backend.entries(forUser: privateUser.id).isEmpty)
    }

    @Test func createWineIsVintageAwareAndDeduplicates() async throws {
        let (backend, _) = try await makeBackend()
        var draft = WineDraft()
        draft.name = "Tignanello"
        draft.producer = "Marchesi Antinori"
        draft.vintage = 2016
        let created = try await backend.createWine(from: draft, scanKey: nil, suggestion: nil)
        let existing = try #require(try await backend.search(WineSearchQuery(text: "Tignanello"), limit: 5).first { $0.vintage == 2020 })
        #expect(created.productID == existing.productID) // same wine, new vintage
        #expect(created.id != existing.id)
        #expect(created.characteristics != nil) // inherited product profile
        let again = try await backend.createWine(from: draft, scanKey: nil, suggestion: nil)
        #expect(again.id == created.id)
    }

    @Test func aiSuggestionsAreLabelledAndNeverOverwriteProfiles() async throws {
        let (backend, _) = try await makeBackend()
        var draft = WineDraft()
        draft.name = "Mystery Red"
        draft.producer = "Unknown Estate"
        let suggestion = AITastingSuggestion(characteristics: WineCharacteristics(body: 0.8, source: .aiSuggested), pairings: ["Steak"], summary: nil)
        let created = try await backend.createWine(from: draft, scanKey: nil, suggestion: suggestion)
        #expect(created.characteristics?.source == .aiSuggested)
        #expect(created.factsSource == .user)

        let margaux = try #require(try await backend.search(WineSearchQuery(text: "Margaux"), limit: 1).first)
        try await backend.attachSuggestion(suggestion, scanKey: nil, to: margaux.id)
        #expect(try await backend.wine(id: margaux.id).characteristics?.source == .editorial)
    }

    @Test func scanCacheRoundTrip() async throws {
        let (backend, _) = try await makeBackend()
        let id = UUID()
        await backend.cacheMatch(textKey: "chateau margaux 2015", wineID: id)
        #expect(await backend.cachedMatch(forTextKey: "chateau margaux 2015") == id)
        #expect(await backend.cachedMatch(forTextKey: "other") == nil)
    }

    @Test func identificationUsesCacheThenOnDeviceMatching() async throws {
        let (backend, _) = try await makeBackend()
        let service = WineIdentificationService(catalog: backend, scans: backend, remote: nil)
        let capture = LabelCapture(imageJPEG: Data(), lines: [
            OCRLine(text: "TENUTA SAN GUIDO", height: 0.03), OCRLine(text: "SASSICAIA", height: 0.08), OCRLine(text: "2019", height: 0.04),
        ])
        let (first, _) = try await service.identify(capture)
        #expect(first.engine == .onDevice)
        let best = try #require(first.best)
        #expect(best.wine.name == "Sassicaia")

        await backend.cacheMatch(textKey: capture.normalizedTextKey, wineID: best.wine.id)
        let (second, _) = try await service.identify(capture)
        #expect(second.engine == .cache)
        #expect(second.best?.wine.id == best.wine.id)
    }
}
