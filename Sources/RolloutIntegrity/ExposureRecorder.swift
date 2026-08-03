import Foundation

public struct ExposureEvent: Hashable, Sendable {
    public let key: FlagKey
    public let variant: String
    public let reason: String
    public let rulesetSequence: Int
    public let bucketingID: String
    public let occurredAt: Date

    public init(key: FlagKey, variant: String, reason: String, rulesetSequence: Int, bucketingID: String, occurredAt: Date) {
        self.key = key
        self.variant = variant
        self.reason = reason
        self.rulesetSequence = rulesetSequence
        self.bucketingID = bucketingID
        self.occurredAt = occurredAt
    }

    /// Two exposures are "the same" if they would land in the same cell of the
    /// experiment analysis. Time is deliberately excluded.
    var dedupKey: String { "\(key.rawValue)|\(variant)|\(rulesetSequence)|\(bucketingID)" }
}

public struct ExposureBatch: Hashable, Sendable {
    public let events: [ExposureEvent]
    /// Events that were never buffered because the buffer was full. Reported
    /// rather than swallowed — see `ExposureRecorder`.
    public let droppedSinceLastDrain: Int
    public let suppressedDuplicates: Int

    public var isEmpty: Bool { events.isEmpty && droppedSinceLastDrain == 0 }
}

/// Buffers exposure events with deduplication, a hard capacity, and an honest
/// drop counter.
///
/// A flag evaluated inside a SwiftUI `body` runs on every layout pass, so the
/// naive "record on every evaluation" design emits thousands of duplicate events
/// per screen. Deduplication is therefore not an optimisation, it is a
/// correctness requirement for the downstream count.
///
/// The drop counter matters more than it looks. A telemetry buffer that silently
/// discards under backpressure produces an analysis that is quietly wrong and
/// looks completely fine — the counts are plausible, they are just low, and they
/// are low *in proportion to how busy the device was*, which correlates with
/// engagement. Surfacing `droppedSinceLastDrain` turns an invisible bias into a
/// number someone can alert on.
public actor ExposureRecorder {
    private var buffer: [ExposureEvent] = []
    private var dedupOrder: [String] = []
    private var dedupSet: Set<String> = []
    private var dropped: Int = 0
    private var suppressed: Int = 0

    private let capacity: Int
    private let dedupWindow: Int

    public init(capacity: Int = 512, dedupWindow: Int = 1_024) {
        self.capacity = Swift.max(capacity, 1)
        self.dedupWindow = Swift.max(dedupWindow, 1)
    }

    /// Returns `true` when the event was newly buffered.
    @discardableResult
    public func record(_ event: ExposureEvent) -> Bool {
        let dedupKey = event.dedupKey
        guard !dedupSet.contains(dedupKey) else {
            suppressed += 1
            return false
        }

        guard buffer.count < capacity else {
            // Drop the *newest*, not the oldest. The oldest events are the ones
            // most likely to be a user's first exposure on a screen, which is the
            // observation the experiment actually needs; a late duplicate-ish
            // event from a busy scroll is the cheaper thing to lose.
            dropped += 1
            return false
        }

        buffer.append(event)
        dedupSet.insert(dedupKey)
        dedupOrder.append(dedupKey)
        trimDedupWindow()
        return true
    }

    public func drain() -> ExposureBatch {
        let batch = ExposureBatch(events: buffer, droppedSinceLastDrain: dropped, suppressedDuplicates: suppressed)
        buffer.removeAll(keepingCapacity: true)
        dropped = 0
        suppressed = 0
        // The dedup window intentionally survives a drain: shipping a batch does
        // not make it correct to re-emit the same exposure a moment later.
        return batch
    }

    public var pendingCount: Int { buffer.count }
    public var droppedCount: Int { dropped }

    private func trimDedupWindow() {
        while dedupOrder.count > dedupWindow, !dedupOrder.isEmpty {
            let evicted = dedupOrder.removeFirst()
            dedupSet.remove(evicted)
        }
    }
}
