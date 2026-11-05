import Foundation

/// Persisted state for Local Mode. Serialized as one JSON document.
struct LocalSnapshot: Codable, Sendable {
    struct Follow: Codable, Hashable, Sendable { var follower: UUID; var followee: UUID; var pending: Bool }
    struct Like: Codable, Hashable, Sendable { var entryID: UUID; var userID: UUID }
    struct Comment: Codable, Hashable, Sendable { var id: UUID; var entryID: UUID; var userID: UUID; var body: String; var createdAt: Date }
    struct Bottle: Codable, Hashable, Sendable {
        var id: UUID, wineID: UUID, quantity: Int, purchasePrice: Price?, purchaseDate: Date?
        var storageLocation: String?, collectionID: UUID?, addedAt: Date, consumedCount: Int
    }
    struct Wish: Codable, Hashable, Sendable { var wineID: UUID; var addedAt: Date }
    struct Notice: Codable, Hashable, Sendable {
        var id: UUID, recipient: UUID, actor: UUID, kind: NotificationKind, entryID: UUID?, createdAt: Date, read: Bool
    }

    static let currentSeedVersion = 1

    var seedVersion = 0
    var currentUserID: UUID?
    var profiles: [UUID: Profile] = [:]
    var wines: [UUID: Wine] = [:]
    var entries: [TastingEntry] = []
    var follows: [Follow] = []
    var likes: [Like] = []
    var comments: [Comment] = []
    var bottles: [Bottle] = []
    var placements: [CellarPlacement] = []
    var collections: [CellarCollection] = []
    var settings = CellarSettings()
    var wishlist: [Wish] = []
    var scans: [ScanRecord] = []
    var textCache: [String: UUID] = [:]
    var recentlyViewed: [UUID] = []
    var notifications: [Notice] = []
    // Added later; optional so stores written by older builds still decode.
    var blocks: [Block]?
    var reports: [Report]?

    struct Block: Codable, Hashable, Sendable { var blocker: UUID; var blocked: UUID }
    struct Report: Codable, Hashable, Sendable {
        var id: UUID, reporter: UUID, entryID: UUID?, commentID: UUID?, userID: UUID?, reason: ReportReason, details: String?, createdAt: Date
    }
}

/// Actor-isolated owner of the local snapshot with debounced persistence.
actor LocalStore {
    private(set) var snapshot: LocalSnapshot
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL = LocalFiles.root.appendingPathComponent("local-store.json")) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? decoder.decode(LocalSnapshot.self, from: data) {
            snapshot = stored
        } else {
            snapshot = LocalSnapshot()
        }
        if snapshot.seedVersion < LocalSnapshot.currentSeedVersion {
            Self.seedCatalog(into: &snapshot)
        }
    }

    func read<T: Sendable>(_ body: (LocalSnapshot) throws -> T) rethrows -> T {
        try body(snapshot)
    }

    @discardableResult
    func write<T: Sendable>(_ body: (inout LocalSnapshot) throws -> T) rethrows -> T {
        let result = try body(&snapshot)
        scheduleSave()
        return result
    }

    func flush() async {
        saveTask?.cancel()
        persist()
    }

    func reset() {
        snapshot = LocalSnapshot()
        Self.seedCatalog(into: &snapshot)
        persist()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private static func seedCatalog(into snapshot: inout LocalSnapshot) {
        for wine in SeedCatalog.load() where snapshot.wines[wine.id] == nil {
            snapshot.wines[wine.id] = wine
        }
        snapshot.seedVersion = LocalSnapshot.currentSeedVersion
    }
}
