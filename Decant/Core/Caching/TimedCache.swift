import Foundation

/// A small in-memory cache whose entries expire after `lifetime` seconds.
/// Used to avoid refetching wines and profiles that every screen shares.
actor TimedCache<Key: Hashable & Sendable, Value: Sendable> {
    private var entries: [Key: (value: Value, stored: Date)] = [:]
    private let lifetime: TimeInterval
    private let limit: Int

    init(lifetime: TimeInterval, limit: Int = 2000) {
        self.lifetime = lifetime
        self.limit = limit
    }

    func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard Date.now.timeIntervalSince(entry.stored) < lifetime else {
            entries[key] = nil
            return nil
        }
        return entry.value
    }

    /// Splits keys into cached values and the keys that still need fetching.
    func lookup(_ keys: [Key]) -> (hits: [Key: Value], misses: [Key]) {
        var hits: [Key: Value] = [:]
        var misses: [Key] = []
        for key in Set(keys) {
            if let value = value(for: key) { hits[key] = value } else { misses.append(key) }
        }
        return (hits, misses)
    }

    func store(_ value: Value, for key: Key) {
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = (value, .now)
    }

    func store(_ values: [Key: Value]) {
        for (key, value) in values { store(value, for: key) }
    }

    func remove(_ key: Key) {
        entries[key] = nil
    }

    func removeAll() {
        entries.removeAll()
    }
}
