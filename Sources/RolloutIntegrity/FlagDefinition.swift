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
    public let variants: [Variant]
    /// Served whenever the flag is off, excluded, or failing safe. Must be one of
    /// `variants`.
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

    public var totalWeight: Int { variants.reduce(0) { $0 + $1.weight } }

    public func containsVariant(named name: String) -> Bool {
        variants.contains { $0.name == name }
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
        let scaled = (clamped * total) / bucketCount

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
