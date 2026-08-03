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
/// atomic across a suspension point.
///
/// That distinction is load-bearing in `decision(for:context:)`, which has to
/// touch the sticky store (an `await`) in the middle of deciding. The naive
/// shape — read the pin, evaluate, write the pin — is a check-then-act pair
/// straddling a suspension, so two concurrent first reads of the same flag can
/// both see "no pin", both evaluate against different rulesets, and the second
/// can overwrite the first's pin *after* the first has already returned a variant
/// and recorded an exposure for it. The user ends up counted in one arm and shown
/// the other.
///
/// The fix is not a lock. It is moving the check-then-act inside the store, where
/// it is one uninterrupted critical section: `StickyAssignmentStore.pinIfAbsent`
/// returns the authoritative assignment, and this actor **adopts** it rather than
/// assuming its own computation won.
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
        await decision(for: key, in: ruleset, overrides: overrides, context: context, fallbackVariant: fallbackVariant)
    }

    /// The real implementation. `snapshot` and `activeOverrides` are parameters
    /// rather than reads of `self`, so a caller that needs several decisions to
    /// agree can take one snapshot and pass it to all of them.
    private func decision(
        for key: FlagKey,
        in snapshot: Ruleset,
        overrides activeOverrides: OverrideSet,
        context: EvaluationContext,
        fallbackVariant: String
    ) async -> FlagDecision {
        let scope = PinScope(key: key, bucketingID: context.identity.bucketingID)
        let pinned = await stickyStore.pinned(for: scope)
        let instant = clock.now

        var decision = evaluator.evaluate(
            key, in: snapshot, context: context, now: instant,
            overrides: activeOverrides, pinned: pinned, fallbackVariant: fallbackVariant)

        // Pin only on an actual assignment. Pinning an exclusion would make raising
        // the ramp unable to admit that user ever again — see `producesPin`.
        if pinned == nil,
           decision.producesPin,
           let definition = snapshot.definition(for: key),
           definition.pinPolicy == .pinOnFirstExposure {
            let winner = await stickyStore.pinIfAbsent(PinnedAssignment(
                scope: scope, variant: decision.variant, pinnedAtSequence: snapshot.version.sequence))
            if winner.variant != decision.variant {
                // A concurrent evaluation pinned first. Adopt its answer instead of
                // our own so the variant served and the variant recorded agree.
                decision = FlagDecision(
                    key: key, variant: winner.variant,
                    reason: .stickyPin(pinnedAtSequence: winner.pinnedAtSequence),
                    rulesetVersion: decision.rulesetVersion,
                    inclusionBucket: decision.inclusionBucket, splitBucket: decision.splitBucket)
            }
        }

        guard decision.producesExposure else { return decision }

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

    /// Evaluates every flag against **one** ruleset snapshot.
    ///
    /// The snapshot is taken here, once, and threaded through every evaluation. That
    /// is not defensive tidiness: `decision(for:context:)` suspends on the sticky
    /// store, so a loop that re-read `self.ruleset` on each iteration could observe
    /// an `apply(_:)` landing midway and return an array whose rows came from two
    /// different rulesets — one view rendering the old treatment and its sibling the
    /// new one, which is exactly the torn read `Ruleset`'s own documentation forbids.
    public func decisions(context: EvaluationContext) async -> [FlagDecision] {
        let snapshot = ruleset
        let activeOverrides = overrides
        var results: [FlagDecision] = []
        for key in snapshot.flagKeys {
            results.append(await decision(
                for: key, in: snapshot, overrides: activeOverrides,
                context: context, fallbackVariant: "off"))
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

    public func discardPin(for key: FlagKey, bucketingID: String) async {
        await stickyStore.discard(PinScope(key: key, bucketingID: bucketingID))
    }
}
