import Foundation

/// Wire formats for Supabase tables/views. Decoded with `SupabaseCoding.decoder`
/// (snake_case → camelCase). Mapping to domain models lives here so views never see rows.
enum SupabaseCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date \(raw)")
        }
        return decoder
    }()

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) ?? iso.date(from: raw) { return d }
        // Postgres `date` columns.
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    static func dayString(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }
}

struct WineCatalogRow: Decodable {
    struct Characteristics: Decodable {
        var sweetness, acidity, body, tannin, fruitiness: Double?
        var flavors: [String]?
        var tastingNotes: String?
        var serveMinC, serveMaxC, decantMinutes, agingYears: Int?
        var source: InfoSource
    }

    var id: UUID
    var productId: UUID
    var name: String
    var type: WineType
    var country, region, appellation: String?
    var grapes: [String]
    var grapePercentages: [Int]?
    var year: Int?
    var bottleSizeMl: Int
    var abv: Double?
    var priceEstimate: Double?
    var currency: String
    var drinkFrom, drinkUntil: Int?
    var labelImagePath, bottleImagePath: String?
    var factsSource: InfoSource
    var wineryId: UUID
    var wineryName: String
    var wineryCountry, wineryRegion: String?
    var wineryFoundedYear: Int?
    var wineryStory: String?
    var wineryPractices: [String]
    var wineryHighlights: [String]
    var winerySource: InfoSource
    var characteristics: Characteristics?
    var pairings: [String]
    var avgRating: Double?
    var ratingsCount: Int

    var wine: Wine {
        let winery = Winery(id: wineryId, name: wineryName, country: wineryCountry, region: wineryRegion,
                            foundedYear: wineryFoundedYear, story: wineryStory, practices: wineryPractices,
                            highlights: wineryHighlights, source: winerySource)
        let grapeShares = grapes.enumerated().map { index, name in
            GrapeShare(name: name, percentage: grapePercentages.flatMap { index < $0.count ? $0[index] : nil })
        }
        let profile = characteristics.map { c in
            WineCharacteristics(
                sweetness: c.sweetness, acidity: c.acidity, body: c.body, tannin: c.tannin, fruitiness: c.fruitiness,
                flavors: c.flavors ?? [], tastingNotes: c.tastingNotes,
                servingTempC: c.serveMinC.flatMap { min in c.serveMaxC.map { min...max($0, min) } },
                decantMinutes: c.decantMinutes, agingPotentialYears: c.agingYears, source: c.source)
        }
        return Wine(
            id: id, productID: productId, name: name, winery: winery, vintage: year, type: type, grapes: grapeShares,
            country: country, region: region, appellation: appellation, abv: abv, bottleSizeML: bottleSizeMl,
            price: priceEstimate.map { Price(amount: Decimal($0), currency: currency) },
            labelImagePath: labelImagePath, bottleImagePath: bottleImagePath, drinkFrom: drinkFrom, drinkUntil: drinkUntil,
            characteristics: profile, pairings: pairings, factsSource: factsSource,
            communityRating: avgRating, ratingsCount: ratingsCount
        )
    }
}

struct ProfileRow: Codable {
    var id: UUID
    var username: String
    var displayName: String
    var avatarUrl: String?
    var bio: String?
    var isPrivate: Bool
    var favoriteTypes: [WineType]
    var defaultVisibility: Visibility
    var cellarFinish: String?
    var cellarSort: String?
    var createdAt: Date

    var profile: Profile {
        Profile(id: id, username: username, displayName: displayName.isEmpty ? username : displayName,
                avatarURL: avatarUrl.flatMap(URL.init(string:)), bio: bio, isPrivate: isPrivate,
                favoriteTypes: favoriteTypes, defaultVisibility: defaultVisibility, createdAt: createdAt)
    }
}

struct ProfileUpdate: Encodable {
    var username: String
    var displayName: String
    var bio: String?
    var isPrivate: Bool
    var favoriteTypes: [WineType]
    var defaultVisibility: Visibility
    var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case username, bio
        case displayName = "display_name", isPrivate = "is_private", favoriteTypes = "favorite_types"
        case defaultVisibility = "default_visibility", avatarUrl = "avatar_url"
    }
}

struct TastingRow: Decodable {
    var id: UUID
    var userId: UUID
    var vintageId: UUID
    var rating: Double?
    var consumedOn: Date
    var location, occasion: String?
    var drinkAgain: Bool?
    var isFavorite: Bool
    var visibility: Visibility
    var taggedUserIds: [UUID]
    var photoPaths: [String]
    var createdAt: Date
}

struct TastingInsert: Encodable {
    var userId: UUID
    var vintageId: UUID
    var rating: Double?
    var consumedOn: String
    var location, occasion: String?
    var drinkAgain: Bool?
    var isFavorite: Bool
    var visibility: Visibility
    var taggedUserIds: [UUID]
    var photoPaths: [String]

    enum CodingKeys: String, CodingKey {
        case rating, location, occasion, visibility
        case userId = "user_id", vintageId = "vintage_id", consumedOn = "consumed_on", drinkAgain = "drink_again"
        case isFavorite = "is_favorite", taggedUserIds = "tagged_user_ids", photoPaths = "photo_paths"
    }
}

struct ReviewRow: Codable {
    var entryId: UUID
    var userId: UUID
    var body: String

    enum CodingKeys: String, CodingKey {
        case body
        case entryId = "entry_id", userId = "user_id"
    }
}

struct PrivateNoteRow: Codable {
    var entryId: UUID
    var userId: UUID
    var notes: String

    enum CodingKeys: String, CodingKey {
        case notes
        case entryId = "entry_id", userId = "user_id"
    }
}

struct EntryStatsRow: Decodable {
    var entryId: UUID
    var likeCount: Int
    var commentCount: Int
    var likedByMe: Bool
}

struct CommentRow: Decodable {
    var id: UUID
    var entryId: UUID
    var userId: UUID
    var body: String
    var createdAt: Date
}

struct ActivityRow: Decodable {
    var id: UUID
    var actorId: UUID
    var kind: ActivityKind
    var vintageId: UUID?
    var entryId: UUID?
    var createdAt: Date
}

struct NotificationRow: Decodable {
    var id: UUID
    var actorId: UUID
    var kind: String
    var entryId: UUID?
    var createdAt: Date
    var readAt: Date?
}

struct FollowRow: Decodable {
    var followerId: UUID
    var followeeId: UUID
    var status: String
}

struct BottleRow: Decodable {
    var id: UUID
    var vintageId: UUID
    var quantity: Int
    var consumedCount: Int
    var purchasePrice: Double?
    var currency: String
    var purchaseDate: Date?
    var storageLocation: String?
    var collectionId: UUID?
    var addedAt: Date
}

struct BottleWrite: Encodable {
    var userId: UUID
    var vintageId: UUID
    var quantity: Int
    var consumedCount: Int
    var purchasePrice: Double?
    var currency: String
    var purchaseDate: String?
    var storageLocation: String?
    var collectionId: UUID?

    enum CodingKeys: String, CodingKey {
        case quantity, currency
        case userId = "user_id", vintageId = "vintage_id", consumedCount = "consumed_count"
        case purchasePrice = "purchase_price", purchaseDate = "purchase_date"
        case storageLocation = "storage_location", collectionId = "collection_id"
    }
}

struct PlacementRow: Decodable {
    var bottleId: UUID
    var shelfIndex: Int
    var slotIndex: Int
}

struct CollectionRow: Decodable {
    var id: UUID
    var name: String
    var symbol: String
    var createdAt: Date
}

struct WishlistRow: Decodable {
    var vintageId: UUID
    var createdAt: Date
}

struct ScanRow: Decodable {
    var id: UUID
    var vintageId: UUID?
    var labelImagePath: String?
    var confidence: Double?
    var createdAt: Date
}

/// Response from the `identify-wine` Edge Function.
struct IdentifyResponse: Decodable {
    struct Label: Decodable {
        var producer, wineName: String?
        var vintage: Int?
        var type: WineType?
        var grapes: [String]?
        var country, region, appellation: String?
        var abv: Double?
        var volumeMl: Int?
    }

    struct Suggestion: Decodable {
        struct Characteristics: Decodable {
            var sweetness, acidity, body, tannin, fruitiness: Double?
            var flavors: [String]?
            var serveMinC, serveMaxC, decantMinutes, agingYears: Int?
        }
        var characteristics: Characteristics?
        var pairings: [String]?
        var summary: String?
    }

    struct Candidate: Decodable {
        var vintageId: UUID
        var score: Double
    }

    var textHash: String
    var extraction: Label
    var identityConfidence: Double
    var suggestion: Suggestion?
    var candidates: [Candidate]
}
