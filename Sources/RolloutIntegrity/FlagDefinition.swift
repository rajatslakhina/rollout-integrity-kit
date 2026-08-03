import Foundation

public struct Variant: Hashable, Sendable {
    public let name: String
    /// Relative weight within the variant set. Must be > 0.
    public let weight: Int

    public init(name: String, weight: Int) {
        self.name = name
        self.weight = weight
    }
}

/// How long a decision derived from this flag may be served from a ruleset that
/// we have failed to refresh.
///
/// This is the flag client's most consequential system-level policy, and the
/// reason it is per-flag rather than global: a kill switch and an experiment want
/// opposite behaviour under the same network failure.
public enum StalenessClass: Hashable, Sendable, CaseIterable {
    /// A switch whose whole purpose is to turn something off in a hurry. If we
    /// cannot confirm the ruleset is fresh, we must assume it may have fired.
    case killSwitch
    /// Operational config (timeouts, page sizes). Stale is tolerable for a while.
    case operational
    /// An experiment. Stale is *correct*: an experiment's assignment must not
    /// change because the device went through a tunnel.
    case experiment

    /// `nil` means "never expires".
    public var hardCeiling: TimeInterval? {
        switch self {
        case .killSwitch: return 300        // 5 minutes
        case .operational: return 3_600     // 1 hour
        case .experiment: return nil
        }
    }
}

/// Whether a decision, once *exposed* to the user, is pinned.
public enum PinPolicy: Hashable, Sendable {
    case never
    /// Pin on first exposure. The pin is honoured only while the pinned variant
    /// still exists in the flag's variant set; if it is removed the pin is
    /// discarded and the flag is re-evaluated, which is the only safe behaviour.
    case pinOnFirstExposure
}

public struct FlagDefinition: Hashable, Sendable {
    public let key: FlagKey
    /// The **treatment arms**: what an included user can be served. A boolean flag
    /// has exactly one (`["on"]`); an A/B test has two; a multivariate test has more.
    public let variants: [Variant]
    /// What a user who is *not* served a treatment gets — held out, excluded,
    /// failing safe on a stale ruleset, or simply out of the rollout.
    ///
    /// Deliberately **not** required to be one of `variants`. Forcing it into the
    /// treatment set is what makes a boolean flag impossible to express honestly:
    /// you end up declaring `["on", "off"]` and the variant split then hands "off"
    /// to half of the *included* population, which is not what anybody meant by a
    /// 100% rollout. Keeping the held-out value separate lets `["on"]` mean exactly
    /// what it looks like.
    public let failSafeVariant: String
    public let rollout: BasisPoints
    /// Stable per-flag salt. Changing it deliberately re-randomises the whole
    /// population — which is occasionally what you want (a re-randomised re-run
    /// of a contaminated experiment) and is catastrophic if done by accident, so
    /// it is an explicit field rather than something derived from the key.
    public let bucketingSalt: String
    public let targetingRules: [TargetingRule]
    public let stalenessClass: StalenessClass
    public let pinPolicy: PinPolicy

    public init(
        key: FlagKey,
        variants: [Variant],
        failSafeVariant: String,
        rollout: BasisPoints,
        bucketingSalt: String,
        targetingRules: [TargetingRule] = [],
        stalenessClass: StalenessClass = .operational,
        pinPolicy: PinPolicy = .pinOnFirstExposure
    ) {
        self.key = key
        self.variants = variants
        self.failSafeVariant = failSafeVariant
        self.rollout = rollout
        self.bucketingSalt = bucketingSalt
        self.targetingRules = targetingRules
        self.stalenessClass = stalenessClass
        self.pinPolicy = pinPolicy
    }

    /// Upper bound on a single variant weight, enforced by `Ruleset` validation.
    ///
    /// The bound is not cosmetic: without it, two variants at `Int.max` pass
    /// validation (`weight > 0` is satisfied) and then trap the moment anything
    /// sums them. One million is four orders of magnitude finer than the 10,000
    /// bucket space can resolve, so it costs nothing real.
    public static let maxVariantWeight = 1_000_000

    /// Upper bound on the number of variants in one flag. 64 is far past any
    /// honest experiment design and keeps `totalWeight` trivially in range.
    public static let maxVariantCount = 64

    /// Saturating sum. Validation already bounds the inputs; this is the second
    /// layer, for definitions built by hand or by a future decoder.
    public var totalWeight: Int {
        variants.reduce(0) { SafeMath.addingSaturating($0, $1.weight) }
    }

    /// The same flag at a different ramp. Everything else — salt, variants,
    /// weights, rules — is preserved, which is what makes a ramp change a ramp
    /// change and not a re-randomisation.
    public func withRollout(_ newRollout: BasisPoints) -> FlagDefinition {
        FlagDefinition(
            key: key, variants: variants, failSafeVariant: failSafeVariant,
            rollout: newRollout, bucketingSalt: bucketingSalt, targetingRules: targetingRules,
            stalenessClass: stalenessClass, pinPolicy: pinPolicy)
    }

    /// Whether `name` is a value this flag can legitimately serve — a treatment arm
    /// or the held-out value.
    public func containsVariant(named name: String) -> Bool {
        name == failSafeVariant || variants.contains { $0.name == name }
    }

    /// Maps a split bucket to a variant using cumulative weight boundaries.
    ///
    /// The bucket spans the **entire** `0..<bucketCount` space, not the included
    /// sub-population. That is what keeps a variant stable while the ramp moves:
    /// if the split were computed over "position within the included set", every
    /// ramp step would renormalise the boundaries and reshuffle everyone who was
    /// already in.
    ///
    /// Returns `nil` only for a degenerate definition (no variants, or all
    /// weights <= 0); callers fall back to the fail-safe variant rather than
    /// indexing into an empty array.
    public func variant(forSplitBucket bucket: Int, bucketCount: Int) -> String? {
        guard !variants.isEmpty, bucketCount > 0 else { return nil }
        let total = totalWeight
        guard total > 0 else { return nil }

        // Scale the bucket into weight space with integer arithmetic; no
        // floating point anywhere on the decision path.
        let clamped = Swift.min(Swift.max(bucket, 0), bucketCount - 1)
        let scaled = SafeMath.scaled(clamped, by: total, over: bucketCount)

        var cumulative = 0
        for variant in variants {
            cumulative += Swift.max(variant.weight, 0)
            if scaled < cumulative { return variant.name }
        }
        // Unreachable when total > 0 because `scaled < total` by construction,
        // but returning the last element beats trapping if that ever stops holding.
        return variants.last?.name
    }
}
