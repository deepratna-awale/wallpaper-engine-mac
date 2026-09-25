/// A small least-recently-used cache. Eviction scans for the oldest entry, which is fine for the
/// hundred-odd entries it holds (it only happens on insert past capacity).
struct SceneLRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var entries: [Key: (value: Value, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = max(capacity, 1) }

    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        clock &+= 1
        entries[key] = (value, clock)
        while entries.count > capacity,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() { entries.removeAll(keepingCapacity: true) }

    /// Keeps only the `count` most recently used entries (memory pressure).
    mutating func trim(to count: Int) {
        guard entries.count > count else { return }
        let kept = entries.sorted { $0.value.lastUse > $1.value.lastUse }.prefix(max(count, 0))
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
