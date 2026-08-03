import Foundation

public protocol StickyAssignmentStore: Sendable {
    func pinned(for key: FlagKey) async -> PinnedAssignment?
    func pin(_ assignment: PinnedAssignment) async
    func discard(_ key: FlagKey) async
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
    private var assignments: [FlagKey: PinnedAssignment] = [:]
    /// Least-recently-used first.
    private var recency: [FlagKey] = []
    private let capacity: Int
    public private(set) var evictionCount: Int = 0

    public init(capacity: Int = 256) {
        // A zero or negative capacity would make eviction loop forever or evict
        // the entry we just inserted; clamp rather than trap.
        self.capacity = Swift.max(capacity, 1)
    }

    public func pinned(for key: FlagKey) -> PinnedAssignment? {
        guard let assignment = assignments[key] else { return nil }
        touch(key)
        return assignment
    }

    public func pin(_ assignment: PinnedAssignment) {
        assignments[assignment.key] = assignment
        touch(assignment.key)
        evictIfNeeded()
    }

    public func discard(_ key: FlagKey) {
        assignments.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    public func discardAll() {
        assignments.removeAll()
        recency.removeAll()
    }

    public func snapshot() -> [PinnedAssignment] {
        assignments.keys.sorted().compactMap { assignments[$0] }
    }

    public var count: Int { assignments.count }

    private func touch(_ key: FlagKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
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
