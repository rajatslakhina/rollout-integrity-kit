import Foundation

public enum RulesetApplyOutcome: Hashable, Sendable, CustomStringConvertible {
    case applied(replacing: RulesetVersion?)
    /// The incoming ruleset is older than the one already in memory. Rejecting
    /// this is the entire defence against out-of-order delivery: a CDN edge, a
    /// retried request and a background refresh can all land in any order, and a
    /// client that applies whatever arrived last will roll itself backwards.
    case rejectedOlder(current: RulesetVersion, incoming: RulesetVersion)
    /// Same sequence — treated as a freshness refresh (the 304 case), which
    /// resets the staleness clock without disturbing any decision.
    case refreshedSameVersion(RulesetVersion)

    public var description: String {
        switch self {
        case .applied(let old): return old.map { "applied, replacing \($0)" } ?? "applied (first ruleset)"
        case .rejectedOlder(let current, let incoming): return "rejected \(incoming); already at \(current)"
        case .refreshedSameVersion(let v): return "refreshed \(v)"
        }
    }
}

/// The stateful shell around the pure evaluator.
///
/// Everything that must be serialised — the current ruleset, the override set —
/// lives here, behind actor isolation. What actor isolation buys is *mutual
/// exclusion*, and nothing else: it does not make a multi-step read-modify-write
/// atomic across a suspension point. That is why `apply(_:)` and
/// `decision(for:context:)` each perform their state transition without an
/// intervening `await` on the shared fields, and why the sticky-store round trip
/// in `decision` is written so that a lost race can only cost a redundant pin
/// write, never a changed variant.
public actor RolloutClient {
    private var ruleset: Ruleset
    private var overrides: OverrideSet
    private let evaluator: FlagEvaluator
    private let clock: any RolloutClock
    private let stickyStore: any StickyAssignmentStore
    private let exposures: ExposureRecorder

    public init(
        bundledFallback: Ruleset,
        bucketer: any Bucketer = FNV1aBucketer(),
        clock: any RolloutClock = SystemClock(),
        stickyStore: any StickyAssignmentStore = InMemoryStickyAssignmentStore(),
        exposures: ExposureRecorder = ExposureRecorder(),
        overrides: OverrideSet = OverrideSet()
    ) {
        // A bundled ruleset is required, not optional. "No ruleset yet" is the
        // state that produces a flag which is neither on nor off at first launch,
        // and every call site then invents its own default — so the app's cold
        // start behaviour ends up defined by whichever engineer typed `?? false`
        // last. Shipping a compiled-in fallback makes that state unrepresentable.
        self.ruleset = bundledFallback
        self.evaluator = FlagEvaluator(bucketer: bucketer)
        self.clock = clock
        self.stickyStore = stickyStore
        self.exposures = exposures
        self.overrides = overrides
    }

    // MARK: Ruleset lifecycle

    @discardableResult
    public func apply(_ incoming: Ruleset) -> RulesetApplyOutcome {
        let current = ruleset.version
        if incoming.version.sequence < current.sequence {
            return .rejectedOlder(current: current, incoming: incoming.version)
        }
        if incoming.version.sequence == current.sequence {
            ruleset = ruleset.refreshed(at: incoming.fetchedAt)
            return .refreshedSameVersion(current)
        }
        ruleset = incoming
        return .applied(replacing: current)
    }

    /// Conditional-GET 304: the payload is unchanged, but freshness is renewed.
    public func markRefreshed(at instant: Date? = nil) {
        ruleset = ruleset.refreshed(at: instant ?? clock.now)
    }

    public var currentVersion: RulesetVersion { ruleset.version }
    public var currentRuleset: Ruleset { ruleset }
    public var rulesetAge: TimeInterval { ruleset.age(at: clock.now) }

    // MARK: Decisions

    public func decision(
        for key: FlagKey,
        context: EvaluationContext,
        fallbackVariant: String = "off"
    ) async -> FlagDecision {
        let pinned = await stickyStore.pinned(for: key)
        // Snapshot the shared state into locals *after* the only `await` above,
        // so the evaluation below observes one coherent ruleset+override pair.
        let snapshot = ruleset
        let currentOverrides = overrides
        let instant = clock.now

        let decision = evaluator.evaluate(
            key, in: snapshot, context: context, now: instant,
            overrides: currentOverrides, pinned: pinned, fallbackVariant: fallbackVariant)

        guard decision.producesExposure else { return decision }

        if pinned == nil,
           let definition = snapshot.definition(for: key),
           definition.pinPolicy == .pinOnFirstExposure {
            await stickyStore.pin(PinnedAssignment(
                key: key, variant: decision.variant, pinnedAtSequence: snapshot.version.sequence))
        }

        await exposures.record(ExposureEvent(
            key: key,
            variant: decision.variant,
            reason: decision.reason.description,
            rulesetSequence: snapshot.version.sequence,
            bucketingID: context.identity.bucketingID,
            occurredAt: instant))

        return decision
    }

    /// Boolean convenience. Note that it still runs the full decision path — the
    /// exposure, the pin and the audit line all still happen, because a flag read
    /// that skips its exposure is how experiments end up with more conversions
    /// than assignments.
    public func isEnabled(
        _ key: FlagKey,
        context: EvaluationContext,
        enabledVariant: String = "on"
    ) async -> Bool {
        await decision(for: key, context: context).variant == enabledVariant
    }

    /// Evaluates every flag in the ruleset. Used by the debug surface and by the
    /// audit; not intended for the hot path.
    public func decisions(context: EvaluationContext) async -> [FlagDecision] {
        var results: [FlagDecision] = []
        for key in ruleset.flagKeys {
            results.append(await decision(for: key, context: context))
        }
        return results
    }

    // MARK: Overrides

    public func setOverride(_ variant: String, for key: FlagKey) {
        overrides.set(variant, for: key)
    }

    public func clearOverride(_ key: FlagKey) {
        overrides.clear(key)
    }

    public func clearAllOverrides() {
        overrides.clearAll()
    }

    public var activeOverrides: OverrideSet { overrides }

    // MARK: Telemetry

    public func drainExposures() async -> ExposureBatch {
        await exposures.drain()
    }

    public func pinnedAssignments() async -> [PinnedAssignment] {
        await stickyStore.snapshot()
    }

    public func discardPins() async {
        await stickyStore.discardAll()
    }
}
