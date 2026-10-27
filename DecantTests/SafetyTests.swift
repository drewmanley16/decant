import Foundation
import Testing
@testable import Decant

@Suite("Safety: block & report")
struct SafetyTests {
    private func makeBackend() async throws -> LocalBackend {
        let backend = LocalBackend(store: LocalStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID()).json")))
        _ = try await backend.startLocalSession(username: "safety", displayName: "Safety")
        return backend
    }

    @Test func blockingHidesContentAndRemovesFollows() async throws {
        let backend = try await makeBackend()
        let friend = LocalSampleCommunity.profiles[1]
        #expect(try await backend.entries(forUser: friend.id).isEmpty == false)

        try await backend.block(friend.id)
        #expect(try await backend.entries(forUser: friend.id).isEmpty)
        #expect(try await backend.feed(before: nil, limit: 100).allSatisfy { $0.actor.id != friend.id })
        #expect(try await backend.profileSummary(userID: friend.id).isFollowing == false)
        #expect(try await backend.blockedUsers().map(\.id) == [friend.id])

        try await backend.follow(friend.id) // blocked users can't be re-followed
        #expect(try await backend.profileSummary(userID: friend.id).isFollowing == false)

        try await backend.unblock(friend.id)
        #expect(try await backend.blockedUsers().isEmpty)
    }

    @Test func reportingHidesItemForReporterOnly() async throws {
        let backend = try await makeBackend()
        let item = try #require(try await backend.feed(before: nil, limit: 50).first { $0.entry != nil })
        let entry = try #require(item.entry)
        try await backend.report(.entry(id: entry.id, author: item.actor.id), reason: .spam, details: "test")
        #expect(try await backend.feed(before: nil, limit: 100).allSatisfy { $0.entry?.id != entry.id })
        await #expect(throws: AppError.self) { try await backend.entry(id: entry.id) }
    }

    @Test func reportingCommentHidesIt() async throws {
        let backend = try await makeBackend()
        let feed = try await backend.feed(before: nil, limit: 100)
        var target: (entry: UUID, comment: ReviewComment)?
        for item in feed {
            if let first = try await backend.comments(entryID: item.id).first { target = (item.id, first); break }
        }
        let found = try #require(target)
        try await backend.report(.comment(id: found.comment.id, author: found.comment.author.id), reason: .harassment, details: nil)
        #expect(try await backend.comments(entryID: found.entry).allSatisfy { $0.id != found.comment.id })
    }
}
