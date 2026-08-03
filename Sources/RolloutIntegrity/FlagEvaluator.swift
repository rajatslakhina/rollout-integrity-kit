import Foundation

/// The whole decision, as a pure function.
///
/// No I/O, no clock of its own, no storage, no `async`. Everything that varies —
/// time, the ruleset, the pin, the overrides — is a parameter. That is what makes
/// a 10,000-identity property test cheap enough to run on every commit, and it is
/// why the interesting invariants in this package are testable at all.
public struct FlagEvaluator: Sendable {
    public let bucketer: any Bucketer

    public init(bucketer: any Bucketer = FNV1aBucketer()) {
        self.bucketer = bucketer
    }

    /// Precedence, highest first:
    ///
    /// 1. **Local override** — developer/QA. Never produces an exposure.
    /// 2. **Stale fail-safe** — if the ruleset is older than the flag's staleness
    ///    ceiling, serve the fail-safe variant.
    /// 3. **Sticky pin** — a variant the user has already been shown.
    /// 4. **Targeting rules** — first match wins.
    /// 5. **Rollout bucket.**
    /// 6. **Fail-safe variant.**
    ///
    /// Two ordering decisions here are worth defending in review.
    ///
    /// **(2) outranks (3):** a kill switch that a sticky pin can outvote is not a
    /// kill switch. The cost is that a user can be un-pinned by a network outage —
    /// which is precisely why the `.experiment` staleness class has no ceiling at
    /// all, so experiments never hit this path and never get their assignment
    /// yanked by a tunnel.
    ///
    /// **(3) outranks (5), which is why only assignments may pin.** Because a pin
    /// short-circuits the rollout check, pinning an *exclusion* would make raising
    /// the ramp unable to admit that user ever again — silently converting the
    /// package's headline monotonicity guarantee into a lie at the client layer
    /// while the evaluator's own property tests stayed green. See
    /// `DecisionReason.producesPin`.
    public func evaluate(
        _ key: FlagKey,
        in ruleset: Ruleset?,
        context: EvaluationContext,
        now: Date,
        overrides: OverrideSet = OverrideSet(),
        pinned: PinnedAssignment? = nil,
        fallbackVariant: String
    ) -> FlagDecision {
        guard let ruleset, let definition = ruleset.definition(for: key) else {
            return FlagDecision(key: key, variant: fallbackVariant, reason: .unknownFlag, rulesetVersion: ruleset?.version)
        }

        // A definition that survived validation always has a usable variant set;
        // this guard covers a definition constructed directly in a test or by a
        // future decoder that bypasses `Ruleset.init`.
        guard !definition.variants.isEmpty, definition.totalWeight > 0 else {
            return FlagDecision(key: key, variant: fallbackVariant, reason: .malformedDefinition, rulesetVersion: ruleset.version)
        }

        let failSafe = definition.failSafeVariant

        // Buckets are computed once, up front, from `bucketingID` only — and they
        // are attached to *every* decision below, including the ones that never
        // consult them (a pin, a stale fail-safe, an override).
        //
        // That is a debuggability decision, not an accident. The single most common
        // support question about a flag is "why is this off for me?", and the answer
        // is only complete if it includes where the user actually landed. A decision
        // that omits the bucket precisely when something unusual happened is a
        // decision that is missing the field you needed.
        let identifier = context.identity.bucketingID
        let inclusionBucket = bucketer.bucket(
            domain: BucketDomain.inclusion, salt: definition.bucketingSalt, identifier: identifier)
        let splitBucket = bucketer.bucket(
            domain: BucketDomain.variantSplit, salt: definition.bucketingSalt, identifier: identifier)

        func decide(_ variant: String, _ reason: DecisionReason) -> FlagDecision {
            FlagDecision(key: key, variant: variant, reason: reason, rulesetVersion: ruleset.version,
                         inclusionBucket: inclusionBucket, splitBucket: splitBucket)
        }

        // 1. Local override — honoured only if it names a variant that still exists.
        if let forced = overrides.variant(for: key), definition.containsVariant(named: forced) {
            return decide(forced, .localOverride)
        }

        // 2. Staleness ceiling.
        if let ceiling = definition.stalenessClass.hardCeiling {
            let age = ruleset.age(at: now)
            if age > ceiling {
                return decide(failSafe, .staleRulesetFailSafe(
                    ageSeconds: SafeMath.roundedClampedToInt(age),
                    ceilingSeconds: SafeMath.roundedClampedToInt(ceiling)))
            }
        }

        // 3. Sticky pin — discarded if it belongs to another identity, or if the
        // pinned variant no longer exists.
        if definition.pinPolicy == .pinOnFirstExposure,
           let pinned,
           pinned.key == key,
           pinned.bucketingID == identifier,
           definition.containsVariant(named: pinned.variant) {
            return decide(pinned.variant, .stickyPin(pinnedAtSequence: pinned.pinnedAtSequence))
        }

        // 4. Targeting — first matching rule wins.
        var effectiveRollout = definition.rollout
        var matchedRuleID: String?

        for rule in definition.targetingRules where rule.matches(context) {
            switch rule.effect {
            case .forceVariant(let forced):
                guard definition.containsVariant(named: forced) else {
                    // Validation rejects this, so reaching it means the ruleset was
                    // built by hand. Fail safe rather than serve a variant the app
                    // has no code path for.
                    return decide(failSafe, .malformedDefinition)
                }
                return decide(forced, .targetingForced(ruleID: rule.id))
            case .exclude:
                return decide(failSafe, .targetingExcluded(ruleID: rule.id))
            case .overrideRollout(let override):
                effectiveRollout = override
                matchedRuleID = rule.id
            }
            break
        }

        // 5. Rollout. `bucket < basisPoints` is monotonic in `basisPoints` by
        // construction: the bucket does not depend on the ramp, so raising the ramp
        // can only ever *add* identities to the included set. Any implementation
        // that folds the percentage into the hash, or takes the bucket modulo a
        // ramp-derived count, loses this and will yank the feature away from users
        // who already had it.
        let scaledThreshold = SafeMath.scaled(
            effectiveRollout.value, by: bucketer.bucketCount, over: BasisPoints.max.value)
        guard inclusionBucket < scaledThreshold else {
            return decide(failSafe, .rolloutExcluded(ruleID: matchedRuleID))
        }

        let variant = definition.variant(forSplitBucket: splitBucket, bucketCount: bucketer.bucketCount) ?? failSafe
        return decide(variant, .rolloutIncluded(ruleID: matchedRuleID))
    }
}
