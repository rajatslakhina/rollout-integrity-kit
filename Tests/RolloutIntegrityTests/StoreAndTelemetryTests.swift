import XCTest
@testable import RolloutIntegrity

final class StickyAssignmentStoreTests: XCTestCase {
    func testEvictsLeastRecentlyUsedAtCapacity() async {
        let store = InMemoryStickyAssignmentStore(capacity: 3)
        for index in 0..<3 {
            await store.pin(PinnedAssignment(key: FlagKey("f\(index)"), variant: "v", pinnedAtSequence: 1))
        }
        // Touch f0 so f1 becomes the least recently used.
        _ = await store.pinned(for: FlagKey("f0"))
        await store.pin(PinnedAssignment(key: FlagKey("f3"), variant: "v", pinnedAtSequence: 1))

        let count = await store.count
        XCTAssertEqual(count, 3)
        let evictions = await store.evictionCount
        XCTAssertEqual(evictions, 1)
        let survivor = await store.pinned(for: FlagKey("f0"))
        XCTAssertNotNil(survivor)
        let evicted = await store.pinned(for: FlagKey("f1"))
        XCTAssertNil(evicted, "least recently used entry should have been evicted")
    }

    /// A zero capacity would make the eviction loop remove the entry it just
    /// inserted, or spin. It is clamped to 1.
    func testDegenerateCapacityIsClamped() async {
        let store = InMemoryStickyAssignmentStore(capacity: 0)
        await store.pin(PinnedAssignment(key: FlagKey("a"), variant: "v", pinnedAtSequence: 1))
        await store.pin(PinnedAssignment(key: FlagKey("b"), variant: "v", pinnedAtSequence: 1))
        let count = await store.count
        XCTAssertEqual(count, 1)
        let latest = await store.pinned(for: FlagKey("b"))
        XCTAssertNotNil(latest)
    }

    func testDiscardAndSnapshot() async {
        let store = InMemoryStickyAssignmentStore(capacity: 8)
        await store.pin(PinnedAssignment(key: FlagKey("b"), variant: "v1", pinnedAtSequence: 1))
        await store.pin(PinnedAssignment(key: FlagKey("a"), variant: "v2", pinnedAtSequence: 2))

        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.map(\.key.rawValue), ["a", "b"], "snapshot should be key-sorted for stable output")

        await store.discard(FlagKey("a"))
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)

        await store.discardAll()
        snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func testRepinOverwritesWithoutGrowing() async {
        let store = InMemoryStickyAssignmentStore(capacity: 4)
        for sequence in 1...10 {
            await store.pin(PinnedAssignment(key: FlagKey("same"), variant: "v\(sequence)", pinnedAtSequence: sequence))
        }
        let count = await store.count
        XCTAssertEqual(count, 1)
        let pinned = await store.pinned(for: FlagKey("same"))
        XCTAssertEqual(pinned?.variant, "v10")
        let evictions = await store.evictionCount
        XCTAssertEqual(evictions, 0)
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
