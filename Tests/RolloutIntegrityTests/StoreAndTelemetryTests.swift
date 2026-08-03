import XCTest
@testable import RolloutIntegrity

final class StickyAssignmentStoreTests: XCTestCase {
    private func scope(_ flag: String, _ id: String = "install-0") -> PinScope {
        PinScope(key: FlagKey(flag), bucketingID: id)
    }
    private func pin(_ flag: String, _ id: String = "install-0", variant: String = "v", sequence: Int = 1) -> PinnedAssignment {
        PinnedAssignment(scope: scope(flag, id), variant: variant, pinnedAtSequence: sequence)
    }

    func testEvictsLeastRecentlyUsedAtCapacity() async {
        let store = InMemoryStickyAssignmentStore(capacity: 3)
        for index in 0..<3 { await store.pinIfAbsent(pin("f\(index)")) }
        // Touch f0 so f1 becomes the least recently used.
        _ = await store.pinned(for: scope("f0"))
        await store.pinIfAbsent(pin("f3"))

        let count = await store.count
        XCTAssertEqual(count, 3)
        let evictions = await store.evictionCount
        XCTAssertEqual(evictions, 1)
        let survivor = await store.pinned(for: scope("f0"))
        XCTAssertNotNil(survivor)
        let evicted = await store.pinned(for: scope("f1"))
        XCTAssertNil(evicted, "least recently used entry should have been evicted")
    }

    /// A zero capacity would make the eviction loop remove the entry it just
    /// inserted, or spin. It is clamped to 1.
    func testDegenerateCapacityIsClamped() async {
        let store = InMemoryStickyAssignmentStore(capacity: 0)
        await store.pinIfAbsent(pin("a"))
        await store.pinIfAbsent(pin("b"))
        let count = await store.count
        XCTAssertEqual(count, 1)
        let latest = await store.pinned(for: scope("b"))
        XCTAssertNotNil(latest)
    }

    /// `pinIfAbsent` is the whole reason the protocol is not `pin(_:)`: the winner
    /// is decided inside one uninterrupted critical section, and the loser adopts it.
    func testPinIfAbsentReturnsTheIncumbentAndNeverOverwrites() async {
        let store = InMemoryStickyAssignmentStore(capacity: 8)
        let first = await store.pinIfAbsent(pin("f", variant: "treatment", sequence: 1))
        XCTAssertEqual(first.variant, "treatment")

        let second = await store.pinIfAbsent(pin("f", variant: "control", sequence: 9))
        XCTAssertEqual(second.variant, "treatment", "the incumbent must win")
        XCTAssertEqual(second.pinnedAtSequence, 1)

        let stored = await store.pinned(for: scope("f"))
        XCTAssertEqual(stored?.variant, "treatment")
        let count = await store.count
        XCTAssertEqual(count, 1)
    }

    /// Exactly one writer wins under contention, and everyone is told who.
    func testConcurrentPinsAgreeOnASingleWinner() async {
        let store = InMemoryStickyAssignmentStore(capacity: 8)
        let candidates = (0..<64).map { pin("f", variant: "v\($0)", sequence: $0) }
        let results = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for candidate in candidates {
                group.addTask { await store.pinIfAbsent(candidate).variant }
            }
            var collected: [String] = []
            for await variant in group { collected.append(variant) }
            return collected
        }
        XCTAssertEqual(Set(results).count, 1, "all 64 racers must be told the same winning variant")
        let count = await store.count
        XCTAssertEqual(count, 1)
    }

    /// Pins are scoped to the identity, not just the flag.
    func testPinsAreScopedToTheBucketingIdentity() async {
        let store = InMemoryStickyAssignmentStore(capacity: 8)
        await store.pinIfAbsent(pin("f", "install-A", variant: "treatment"))
        let other = await store.pinned(for: scope("f", "install-B"))
        XCTAssertNil(other, "identity B must not inherit identity A's pin")

        await store.pinIfAbsent(pin("f", "install-B", variant: "control"))
        let a = await store.pinned(for: scope("f", "install-A"))
        let b = await store.pinned(for: scope("f", "install-B"))
        XCTAssertEqual(a?.variant, "treatment")
        XCTAssertEqual(b?.variant, "control")
    }

    func testDiscardAndSnapshot() async {
        let store = InMemoryStickyAssignmentStore(capacity: 8)
        await store.pinIfAbsent(pin("b", variant: "v1"))
        await store.pinIfAbsent(pin("a", variant: "v2"))

        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.map(\.key.rawValue), ["a", "b"], "snapshot should be key-sorted for stable output")

        await store.discard(scope("a"))
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)

        await store.discardAll()
        snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }
}

final class PersistentStickyAssignmentStoreTests: XCTestCase {
    private func scope(_ flag: String, _ id: String = "install-0") -> PinScope {
        PinScope(key: FlagKey(flag), bucketingID: id)
    }

    /// Without persistence, "sticky" is a slogan: a user shown treatment on Monday
    /// gets re-diced on Tuesday because the pin died with the process.
    func testPinsSurviveAProcessRestart() async {
        let storage = EphemeralStickyStorage()
        let first = PersistentStickyAssignmentStore(storage: storage)
        await first.pinIfAbsent(PinnedAssignment(scope: scope("f"), variant: "treatment", pinnedAtSequence: 3))

        // A brand-new store instance over the same storage is the restart.
        let second = PersistentStickyAssignmentStore(storage: storage)
        let restored = await second.pinned(for: scope("f"))
        XCTAssertEqual(restored?.variant, "treatment")
        XCTAssertEqual(restored?.pinnedAtSequence, 3)
        let failed = await second.loadFailed
        XCTAssertFalse(failed)
    }

    /// Corrupt stored data must degrade to "no pins", not to a thrown error. A flag
    /// evaluation failing because a cache blob did not decode is strictly worse than
    /// re-bucketing a few users once.
    func testCorruptStorageDegradesToEmptyAndIsReported() async {
        let corrupt = EphemeralStickyStorage(seeded: [
            PersistentStickyAssignmentStore.defaultStorageKey: Data("{ this is not json".utf8)
        ])
        let store = PersistentStickyAssignmentStore(storage: corrupt)
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let failed = await store.loadFailed
        XCTAssertTrue(failed, "the failure is surfaced rather than swallowed")

        // Still fully usable afterwards.
        await store.pinIfAbsent(PinnedAssignment(scope: scope("f"), variant: "v", pinnedAtSequence: 1))
        let recovered = await store.pinned(for: scope("f"))
        XCTAssertEqual(recovered?.variant, "v")
    }

    func testDiscardAllClearsPersistedState() async {
        let storage = EphemeralStickyStorage()
        let store = PersistentStickyAssignmentStore(storage: storage)
        await store.pinIfAbsent(PinnedAssignment(scope: scope("f"), variant: "v", pinnedAtSequence: 1))
        await store.discardAll()

        let reloaded = PersistentStickyAssignmentStore(storage: storage)
        let snapshot = await reloaded.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    /// A reload truncated by capacity must keep the freshest pins, not an arbitrary
    /// slice.
    func testReloadRespectsCapacityKeepingMostRecentlyUsed() async {
        let storage = EphemeralStickyStorage()
        let writer = PersistentStickyAssignmentStore(storage: storage, capacity: 10)
        for index in 0..<10 {
            await writer.pinIfAbsent(PinnedAssignment(scope: scope("f\(index)"), variant: "v", pinnedAtSequence: index))
        }
        let reader = PersistentStickyAssignmentStore(storage: storage, capacity: 3)
        let snapshot = await reader.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(Set(snapshot.map(\.key.rawValue)), ["f7", "f8", "f9"])
    }
}

final class ExposureRecorderTests: XCTestCase {
    private func event(_ key: String, variant: String = "on", sequence: Int = 1, id: String = "install-0") -> ExposureEvent {
        ExposureEvent(key: FlagKey(key), variant: variant, reason: "test", rulesetSequence: sequence,
                      bucketingID: id, occurredAt: Date(timeIntervalSince1970: 0))
    }

    /// A flag read inside a SwiftUI `body` runs on every layout pass. Without
    /// dedup the downstream exposure count is a layout counter, not a user count.
    func testDuplicatesAreSuppressed() async {
        let recorder = ExposureRecorder(capacity: 100)
        let first = await recorder.record(event("a"))
        XCTAssertTrue(first)
        for _ in 0..<500 {
            let repeated = await recorder.record(event("a"))
            XCTAssertFalse(repeated)
        }
        let batch = await recorder.drain()
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.suppressedDuplicates, 500)
        XCTAssertEqual(batch.droppedSinceLastDrain, 0)
    }

    func testDedupKeyIncludesVariantVersionAndIdentity() async {
        let recorder = ExposureRecorder(capacity: 100)
        await recorder.record(event("a", variant: "on", sequence: 1, id: "i1"))
        await recorder.record(event("a", variant: "off", sequence: 1, id: "i1"))
        await recorder.record(event("a", variant: "on", sequence: 2, id: "i1"))
        await recorder.record(event("a", variant: "on", sequence: 1, id: "i2"))
        let batch = await recorder.drain()
        XCTAssertEqual(batch.events.count, 4, "a different variant, ruleset or identity is a different exposure")
    }

    /// Drops are counted, never swallowed. A telemetry buffer that discards
    /// silently under backpressure produces an analysis that is quietly wrong and
    /// looks completely fine.
    func testOverflowIsCountedNotHidden() async {
        let recorder = ExposureRecorder(capacity: 5, dedupWindow: 10_000)
        for index in 0..<20 {
            await recorder.record(event("flag-\(index)"))
        }
        let pending = await recorder.pendingCount
        XCTAssertEqual(pending, 5)
        let dropped = await recorder.droppedCount
        XCTAssertEqual(dropped, 15)

        let batch = await recorder.drain()
        XCTAssertEqual(batch.events.count, 5)
        XCTAssertEqual(batch.droppedSinceLastDrain, 15)
        XCTAssertFalse(batch.isEmpty)

        let afterDrain = await recorder.droppedCount
        XCTAssertEqual(afterDrain, 0, "counters reset on drain so each batch reports its own loss")
    }

    /// Shipping a batch does not make it correct to re-emit the same exposure.
    func testDedupWindowSurvivesADrain() async {
        let recorder = ExposureRecorder(capacity: 10, dedupWindow: 100)
        await recorder.record(event("a"))
        _ = await recorder.drain()
        let repeated = await recorder.record(event("a"))
        XCTAssertFalse(repeated)
        let batch = await recorder.drain()
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(batch.suppressedDuplicates, 1)
    }

    /// The dedup set is itself bounded — otherwise it is an unbounded `Set<String>`
    /// on a long-lived process, which is a leak that only shows up for heavy users.
    func testDedupWindowIsBounded() async {
        let recorder = ExposureRecorder(capacity: 10_000, dedupWindow: 50)
        for index in 0..<200 {
            await recorder.record(event("flag-\(index)"))
        }
        _ = await recorder.drain()
        // The oldest key has aged out of the window, so it can be recorded again.
        let reRecorded = await recorder.record(event("flag-0"))
        XCTAssertTrue(reRecorded)
        // The newest key is still inside the window.
        let stillSuppressed = await recorder.record(event("flag-199"))
        XCTAssertFalse(stillSuppressed)
    }

    func testDegenerateCapacitiesAreClamped() async {
        let recorder = ExposureRecorder(capacity: 0, dedupWindow: 0)
        let accepted = await recorder.record(event("a"))
        XCTAssertTrue(accepted)
        let batch = await recorder.drain()
        XCTAssertEqual(batch.events.count, 1)
    }

    func testEmptyBatchReportsItself() async {
        let recorder = ExposureRecorder()
        let batch = await recorder.drain()
        XCTAssertTrue(batch.isEmpty)
    }
}

final class ManualClockTests: XCTestCase {
    func testAdvanceAndSet() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = ManualClock(start)
        XCTAssertEqual(clock.now, start)
        clock.advance(by: 60)
        XCTAssertEqual(clock.now, start.addingTimeInterval(60))
        clock.set(start)
        XCTAssertEqual(clock.now, start)
    }

    /// The `@unchecked Sendable` claim: every access goes through the lock.
    func testConcurrentAdvancesDoNotLoseUpdates() async {
        let clock = ManualClock(Date(timeIntervalSince1970: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { clock.advance(by: 1) }
            }
        }
        XCTAssertEqual(clock.now.timeIntervalSince1970, 200, accuracy: 0.0001)
    }
}
