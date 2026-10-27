import Foundation

struct Profile: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var username: String
    var displayName: String
    var avatarURL: URL?
    var bio: String?
    var isPrivate: Bool
    var favoriteTypes: [WineType]
    var defaultVisibility: Visibility
    var createdAt: Date

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? String(username.prefix(1)).uppercased() : letters.uppercased()
    }
}

/// Who can see a review / tasting entry. Matches the `visibility` Postgres enum.
enum Visibility: String, Codable, CaseIterable, Sendable, Identifiable {
    case everyone = "public"
    case friends
    case onlyMe = "private"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyone: "Public"
        case .friends: "Friends"
        case .onlyMe: "Only me"
        }
    }

    var systemImage: String {
        switch self {
        case .everyone: "globe"
        case .friends: "person.2"
        case .onlyMe: "lock"
        }
    }
}

/// One diary entry: a user drinking a wine on a date. A user may log the same
/// wine many times. Ratings are 0.5...5 in half-star steps.
struct TastingEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var userID: UUID
    var wineID: UUID
    var rating: Double?
    var review: String?
    var personalNotes: String?
    var photoPaths: [String]
    var consumedOn: Date
    var location: String?
    var occasion: String?
    var taggedUserIDs: [UUID]
    var drinkAgain: Bool?
    var isFavorite: Bool
    var visibility: Visibility
    var createdAt: Date
    var likeCount: Int
    var commentCount: Int
    var likedByMe: Bool

    static func normalizedRating(_ value: Double) -> Double {
        min(5, max(0.5, (value * 2).rounded() / 2))
    }
}

/// Input for creating a tasting entry.
struct TastingDraft: Sendable, Hashable {
    var rating: Double?
    var review: String = ""
    var personalNotes: String = ""
    var photoPaths: [String] = []
    var consumedOn: Date = .now
    var location: String = ""
    var occasion: String = ""
    var taggedUserIDs: [UUID] = []
    var drinkAgain: Bool?
    var isFavorite: Bool = false
    var visibility: Visibility = .everyone
    var addToCellar: Bool = false
}

/// A tasting entry joined with its author and wine, for feeds and wine pages.
struct ReviewItem: Hashable, Sendable, Identifiable {
    var entry: TastingEntry
    var author: Profile
    var wine: Wine
    var id: UUID { entry.id }
}

enum ActivityKind: String, Codable, Sendable {
    case rated
    case cellared
    case wishlisted
    case followed
}

struct FeedItem: Hashable, Sendable, Identifiable {
    var id: UUID
    var kind: ActivityKind
    var actor: Profile
    var wine: Wine?
    var entry: TastingEntry?
    var createdAt: Date
}

struct ReviewComment: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var entryID: UUID
    var author: Profile
    var body: String
    var createdAt: Date
}

enum NotificationKind: String, Codable, Sendable {
    case follow, like, comment, tag
}

struct AppNotification: Hashable, Sendable, Identifiable {
    var id: UUID
    var kind: NotificationKind
    var actor: Profile
    var entryID: UUID?
    var wineName: String?
    var createdAt: Date
    var isRead: Bool

    var message: String {
        switch kind {
        case .follow: "started following you"
        case .like: "liked your review\(wineName.map { " of \($0)" } ?? "")"
        case .comment: "commented on your review\(wineName.map { " of \($0)" } ?? "")"
        case .tag: "tagged you in a tasting\(wineName.map { " of \($0)" } ?? "")"
        }
    }
}

/// A friend's rating summary for a wine's detail page.
struct FriendRating: Hashable, Sendable, Identifiable {
    var friend: Profile
    var rating: Double?
    var entryID: UUID
    var id: UUID { entryID }
}

struct ProfileSummary: Hashable, Sendable {
    var profile: Profile
    var followers: Int
    var following: Int
    var tastings: Int
    var isFollowing: Bool
    var canViewContent: Bool
}

// MARK: - Safety & moderation

enum ReportReason: String, Codable, CaseIterable, Sendable, Identifiable {
    case spam, harassment, hate, sexual, violence, misinformation, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam: "Spam or scam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate speech"
        case .sexual: "Sexual content"
        case .violence: "Violence or threats"
        case .misinformation: "False information"
        case .other: "Something else"
        }
    }
}

/// What is being reported. Reported content is hidden from the reporter immediately.
enum ReportTarget: Hashable, Sendable {
    case user(UUID)
    case entry(id: UUID, author: UUID)
    case comment(id: UUID, author: UUID)

    var authorID: UUID {
        switch self {
        case .user(let id): id
        case .entry(_, let author), .comment(_, let author): author
        }
    }

    var noun: String {
        switch self {
        case .user: "account"
        case .entry: "review"
        case .comment: "comment"
        }
    }
}
