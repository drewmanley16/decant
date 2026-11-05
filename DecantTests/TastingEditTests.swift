import Foundation
import Testing
@testable import Decant

@Suite("Editing tastings")
struct TastingEditTests {
    private func makeBackend() async throws -> (LocalBackend, Profile) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID()).json")
        let backend = LocalBackend(store: LocalStore(fileURL: url))
        let me = try await backend.startSessionWithSampleCommunity(username: "editor", displayName: "Editor")
        return (backend, me)
    }

    @Test func draftRoundTripsEveryField() {
        var draft = TastingDraft()
        draft.rating = 4.5
        draft.review = "Bright and long"
        draft.personalNotes = "Bought at the cellar door"
        draft.location = "Home"
        draft.occasion = "Birthday"
        draft.drinkAgain = true
        draft.isFavorite = true
        draft.visibility = .friends
        draft.photoPaths = ["a.jpg"]
        var entry = TastingEntry(id: UUID(), userID: UUID(), wineID: UUID(), rating: nil, review: nil, personalNotes: nil,
                                 photoPaths: [], consumedOn: .now, location: nil, occasion: nil, taggedUserIDs: [],
                                 drinkAgain: nil, isFavorite: false, visibility: .everyone, createdAt: .now,
                                 likeCount: 0, commentCount: 0, likedByMe: false)
        entry.apply(draft)
        #expect(TastingDraft(entry: entry) == draft)
    }

    @Test func clearingFieldsStoresNil() {
        var entry = TastingEntry(id: UUID(), userID: UUID(), wineID: UUID(), rating: 3, review: "Old", personalNotes: "Secret",
                                 photoPaths: ["p.jpg"], consumedOn: .now, location: "Bar", occasion: nil, taggedUserIDs: [],
                                 drinkAgain: false, isFavorite: true, visibility: .everyone, createdAt: .now,
                                 likeCount: 0, commentCount: 0, likedByMe: false)
        var draft = TastingDraft(entry: entry)
        draft.rating = nil
        draft.review = "  "
        draft.personalNotes = ""
        draft.location = ""
        draft.photoPaths = []
        draft.drinkAgain = nil
        entry.apply(draft)
        #expect(entry.rating == nil && entry.review == nil && entry.personalNotes == nil)
        #expect(entry.location == nil && entry.photoPaths.isEmpty && entry.drinkAgain == nil)
    }

    @Test func editedEntryIsSaved() async throws {
        let (backend, me) = try await makeBackend()
        let wine = try #require(try await backend.catalogSample(limit: 1).first)
        var draft = TastingDraft()
        draft.rating = 3
        var entry = try await backend.addEntry(for: wine.id, draft: draft)
        draft.rating = 4.5
        draft.review = "Better the second night"
        entry.apply(draft)
        try await backend.updateEntry(entry)
        let saved = try await backend.entries(forUser: me.id).first { $0.id == entry.id }
        #expect(saved?.entry.rating == 4.5)
        #expect(saved?.entry.review == "Better the second night")
    }
}
