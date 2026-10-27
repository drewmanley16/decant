import Foundation

/// SAMPLE DATA — Local Mode only.
/// A small simulated community so the social features (feed, friends' ratings,
/// likes, comments) can be exercised on-device without a server. These people
/// are not real and are never sent to Supabase. The UI labels Local Mode.
enum LocalSampleCommunity {
    struct Tasting {
        var user: Int
        var wineName: String
        var rating: Double
        var review: String?
        var daysAgo: Int
        var visibility: Visibility = .everyone
    }

    static let profiles: [Profile] = [
        sample("6b1e0f1a-0000-4000-8000-000000000001", "amelie.r", "Amélie Rousseau", "Burgundy obsessive. Pinot or bust.", [.red, .white]),
        sample("6b1e0f1a-0000-4000-8000-000000000002", "marcus_cellars", "Marcus Chen", "Collecting Napa Cabernet one vintage at a time.", [.red]),
        sample("6b1e0f1a-0000-4000-8000-000000000003", "sofia.vino", "Sofia Marino", "Natural wine & orange wine enthusiast.", [.orange, .white]),
        sample("6b1e0f1a-0000-4000-8000-000000000004", "jules", "Jules Okafor", "Bubbles for every occasion.", [.sparkling, .rose]),
        sample("6b1e0f1a-0000-4000-8000-000000000005", "hannah.k", "Hannah Kim", "WSET 3. Riesling apologist.", [.white, .dessert], isPrivate: true),
    ]

    /// Indices into `profiles` the local user is friends with (mutual follows).
    static let friendIndices = [0, 1, 2, 3]

    static let tastings: [Tasting] = [
        .init(user: 0, wineName: "Louis Jadot Bourgogne Pinot Noir", rating: 4, review: "Textbook village-level Burgundy for the price. Bright cherry and a little earth.", daysAgo: 1),
        .init(user: 1, wineName: "Opus One", rating: 5, review: "Decanted two hours. Silky, layered, endless finish. Worth the splurge for the anniversary.", daysAgo: 2),
        .init(user: 2, wineName: "Gravner Ribolla Gialla", rating: 4.5, review: "Amber, tea and dried apricot. Needs air and a big glass.", daysAgo: 3),
        .init(user: 3, wineName: "Moët Impérial Brut", rating: 3.5, review: "Reliable party fizz.", daysAgo: 4),
        .init(user: 0, wineName: "Domaine Leflaive Puligny-Montrachet", rating: 5, review: "Laser focused. Hazelnut, lemon, chalk. Stunning.", daysAgo: 6),
        .init(user: 1, wineName: "Caymus Cabernet Sauvignon", rating: 4, review: "Plush and crowd pleasing. Not subtle, but delicious with ribs.", daysAgo: 7),
        .init(user: 3, wineName: "Whispering Angel", rating: 4, review: "Rooftop wine. Exactly what I wanted.", daysAgo: 8),
        .init(user: 2, wineName: "Catena Malbec", rating: 4, review: "Juicy and floral, excellent value.", daysAgo: 9),
        .init(user: 4, wineName: "Dr. Loosen Blue Slate Riesling Kabinett", rating: 4.5, review: "Off-dry perfection with spicy noodles.", daysAgo: 10),
        .init(user: 1, wineName: "Tignanello", rating: 4.5, review: "Sour cherry and cedar. Would cellar a few more years.", daysAgo: 12),
        .init(user: 0, wineName: "Pio Cesare Barolo", rating: 4, review: "Tar and roses, firm tannins. Give it time.", daysAgo: 14),
        .init(user: 3, wineName: "Veuve Clicquot Yellow Label Brut", rating: 4, review: nil, daysAgo: 15),
        .init(user: 2, wineName: "Cloudy Bay Sauvignon Blanc", rating: 3.5, review: "Passion fruit bomb. Fun with goat cheese.", daysAgo: 18),
        .init(user: 1, wineName: "Château Margaux", rating: 5, review: "A once-in-a-decade bottle. Violets and graphite.", daysAgo: 21),
        .init(user: 0, wineName: "Kim Crawford Sauvignon Blanc", rating: 3, review: nil, daysAgo: 24),
        .init(user: 3, wineName: "Dom Pérignon", rating: 5, review: "Toasty, precise, gorgeous mousse.", daysAgo: 26, visibility: .friends),
        .init(user: 2, wineName: "Marqués de Riscal Reserva", rating: 3.5, review: "Classic vanilla-tinged Rioja.", daysAgo: 30),
        .init(user: 1, wineName: "Penfolds Grange", rating: 4.5, review: "Massive. Needs another decade.", daysAgo: 35),
        .init(user: 0, wineName: "Meiomi Pinot Noir", rating: 3, review: "Sweet-leaning but fine with pizza.", daysAgo: 40),
        .init(user: 3, wineName: "Santa Margherita Pinot Grigio", rating: 3.5, review: nil, daysAgo: 44),
        .init(user: 1, wineName: "Ridge Monte Bello", rating: 5, review: "Mountain Cabernet at its finest.", daysAgo: 50),
        .init(user: 2, wineName: "Taylor Fladgate 20 Year Old Tawny Port", rating: 4.5, review: "Caramel and walnut — dessert in a glass.", daysAgo: 55),
    ]

    static let comments: [(tastingIndex: Int, user: Int, body: String)] = [
        (1, 0, "Jealous! Which vintage?"),
        (1, 3, "Happy anniversary 🥂"),
        (4, 1, "Need to find a bottle of this."),
        (2, 3, "Adding to my list."),
    ]

    private static func sample(_ id: String, _ username: String, _ name: String, _ bio: String,
                               _ types: [WineType], isPrivate: Bool = false) -> Profile {
        Profile(id: UUID(uuidString: id) ?? UUID(), username: username, displayName: name, avatarURL: nil, bio: bio,
                isPrivate: isPrivate, favoriteTypes: types, defaultVisibility: .everyone,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
