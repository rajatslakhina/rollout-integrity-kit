import Foundation

public protocol StickyAssignmentStore: Sendable {
    func pinned(for scope: PinScope) async -> PinnedAssignment?
    /// Inserts `assignment` only if nothing is pinned for its scope, and returns
    /// **whichever assignment is authoritative afterwards**.
    ///
    /// This signature is the whole point of the protocol. A plain `pin(_:)` plus a
    /// prior `pinned(for:)` is a check-then-act pair with an `await` in the middle:
    /// two concurrent first reads of the same flag can both observe "no pin", both
    /// evaluate, and the second can overwrite the first's pin — after the first has
    /// already returned a variant to the caller and recorded an exposure for it.
    /// The user is then counted in one arm and shown the other. Returning the winner
    /// lets the caller adopt it and stay consistent.
    @discardableResult
    func pinIfAbsent(_ assignment: PinnedAssignment) async -> PinnedAssignment
    func discard(_ scope: PinScope) async
    func discardAll() async
    func snapshot() async -> [PinnedAssignment]
}

/// Bounded, LRU-evicting in-memory pin store.
///
/// The bound is the point. A pin store keyed by flag looks like it cannot grow —
/// until an experimentation platform starts minting per-cohort or per-campaign
/// flag keys, at which point an unbounded dictionary on a long-lived process is a
/// slow leak that only reproduces for the heaviest users. Capacity is explicit,
/// eviction is least-recently-used, and `evictionCount` is observable so the
/// bound can be tuned from real data rather than guessed.
public actor InMemoryStickyAssignmentStore: StickyAssignmentStore {
    private var assignments: [PinScope: PinnedAssignment] = [:]
    /// Least-recently-used first.
    private var recency: [PinScope] = []
    private let capacity: Int
    public private(set) var evictionCount: Int = 0

    public init(capacity: Int = 256) {
        // A zero or negative capacity would make eviction loop forever or evict
        // the entry we just inserted; clamp rather than trap.
        self.capacity = Swift.max(capacity, 1)
    }

    public func pinned(for scope: PinScope) -> PinnedAssignment? {
        guard let assignment = assignments[scope] else { return nil }
        touch(scope)
        return assignment
    }

    @discardableResult
    public func pinIfAbsent(_ assignment: PinnedAssignment) -> PinnedAssignment {
        // Actor isolation makes this whole method one critical section precisely
        // because it contains no `await`. That is the property that makes the
        // check-then-act atomic; splitting it across two calls would not be.
        if let existing = assignments[assignment.scope] {
            touch(assignment.scope)
            return existing
        }
        assignments[assignment.scope] = assignment
        touch(assignment.scope)
        evictIfNeeded()
        return assignment
    }

    public func discard(_ scope: PinScope) {
        assignments.removeValue(forKey: scope)
        recency.removeAll { $0 == scope }
    }

    public func discardAll() {
        assignments.removeAll()
        recency.removeAll()
    }

    public func snapshot() -> [PinnedAssignment] {
        assignments.keys.sorted().compactMap { assignments[$0] }
    }

    public var count: Int { assignments.count }

    private func touch(_ scope: PinScope) {
        recency.removeAll { $0 == scope }
        recency.append(scope)
    }

    private func evictIfNeeded() {
        // `recency` and `assignments` are kept in step, and `capacity >= 1`, so
        // this terminates; `isEmpty` is checked before every removal regardless.
        while assignments.count > capacity, !recency.isEmpty {
            let oldest = recency.removeFirst()
            assignments.removeValue(forKey: oldest)
            evictionCount += 1
        }
    }
}

// MARK: - Persistence

/// The narrow slice of key-value storage a pin store needs.
///
/// A protocol rather than a direct `UserDefaults` dependency for one concrete
/// reason: the interesting behaviour of a persistent pin store is what it does
/// with *corrupt* stored data, and you cannot test that against a real
/// `UserDefaults` without writing garbage into the user's domain.
public protocol StickyStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// `UserDefaults`-backed storage.
///
/// `@unchecked Sendable` is required rather than chosen: `UserDefaults` is not
/// marked `Sendable` in Foundation, but it is documented as thread-safe and is
/// used concurrently by essentially every app on the platform. The unchecked
/// conformance is confined to this five-line wrapper, which holds no other state,
/// so the audit surface for the claim is exactly these two methods.
public struct UserDefaultsStickyStorage: StickyStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// In-memory `StickyStorage`, for tests and previews.
public final class EphemeralStickyStorage: StickyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init(seeded: [String: Data] = [:]) { self.storage = seeded }

    // `@unchecked Sendable` is justified because `storage` is private and every
    // access below is taken under `lock`; there is no other mutable state.
    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }
}

/// Pin store that survives process death.
///
/// Without this, sticky assignment is a slogan: pins held only in memory die at
/// app termination, so a user who is shown treatment on Monday can be re-diced on
/// Tuesday. Persistence is what makes "sticky" true across the app lifecycle.
///
/// Corrupt or unreadable stored data is treated as "no pins" rather than as an
/// error to propagate. Nothing good comes of failing a flag evaluation because a
/// cache blob did not decode; the worst case is that a few users get re-bucketed
/// once, which is exactly what happens on a fresh install anyway.
public actor PersistentStickyAssignmentStore: StickyAssignmentStore {
    public static let defaultStorageKey = "com.rolloutintegrity.pins.v1"

    private var assignments: [PinScope: PinnedAssignment]
    private var recency: [PinScope]
    private let capacity: Int
    private let storage: any StickyStorage
    private let storageKey: String
    public private(set) var evictionCount: Int = 0
    public private(set) var loadFailed: Bool = false

    public init(
        storage: any StickyStorage,
        storageKey: String = PersistentStickyAssignmentStore.defaultStorageKey,
        capacity: Int = 256
    ) {
        self.storage = storage
        self.storageKey = storageKey
        self.capacity = Swift.max(capacity, 1)

        var loaded: [PinnedAssignment] = []
        var failed = false
        if let data = storage.data(forKey: storageKey) {
            if let decoded = try? JSONDecoder().decode([StoredPin].self, from: data) {
                loaded = decoded.map(\.assignment)
            } else {
                failed = true
            }
        }
        self.loadFailed = failed
        var byScope: [PinScope: PinnedAssignment] = [:]
        var order: [PinScope] = []
        for assignment in loaded.suffix(self.capacity) {
            byScope[assignment.scope] = assignment
            order.append(assignment.scope)
        }
        self.assignments = byScope
        self.recency = order
    }

    public func pinned(for scope: PinScope) -> PinnedAssignment? {
        guard let assignment = assignments[scope] else { return nil }
        touch(scope)
        return assignment
    }

    @discardableResult
    public func pinIfAbsent(_ assignment: PinnedAssignment) -> PinnedAssignment {
        if let existing = assignments[assignment.scope] {
            touch(assignment.scope)
            return existing
        }
        assignments[assignment.scope] = assignment
        touch(assignment.scope)
        evictIfNeeded()
        persist()
        return assignment
    }

    public func discard(_ scope: PinScope) {
        assignments.removeValue(forKey: scope)
        recency.removeAll { $0 == scope }
        persist()
    }

    public func discardAll() {
        assignments.removeAll()
        recency.removeAll()
        persist()
    }

    public func snapshot() -> [PinnedAssignment] {
        assignments.keys.sorted().compactMap { assignments[$0] }
    }

    public var count: Int { assignments.count }

    private func touch(_ scope: PinScope) {
        recency.removeAll { $0 == scope }
        recency.append(scope)
    }

    private func evictIfNeeded() {
        while assignments.count > capacity, !recency.isEmpty {
            let oldest = recency.removeFirst()
            assignments.removeValue(forKey: oldest)
            evictionCount += 1
        }
    }

    private func persist() {
        // Written in LRU order so a truncated reload keeps the freshest pins.
        let ordered = recency.compactMap { assignments[$0] }.map(StoredPin.init)
        storage.set(try? JSONEncoder().encode(ordered), forKey: storageKey)
    }

    /// Storage shape, kept separate from `PinnedAssignment` so the public type is
    /// free to change without silently invalidating everybody's stored pins.
    private struct StoredPin: Codable {
        let flag: String
        let bucketingID: String
        let variant: String
        let sequence: Int

        init(_ assignment: PinnedAssignment) {
            flag = assignment.key.rawValue
            bucketingID = assignment.bucketingID
            variant = assignment.variant
            sequence = assignment.pinnedAtSequence
        }

        var assignment: PinnedAssignment {
            PinnedAssignment(key: FlagKey(flag), bucketingID: bucketingID,
                             variant: variant, pinnedAtSequence: sequence)
        }
    }
}
