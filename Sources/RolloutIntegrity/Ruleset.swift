import Foundation

/// Monotonic ruleset version.
///
/// `sequence` is server-assigned and strictly increasing. `etag` is carried for
/// cache validation and for attributing an exposure to the exact payload that
/// produced it, but ordering is decided by `sequence` alone — comparing opaque
/// etags is how out-of-order delivery quietly rolls a client backwards.
public struct RulesetVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let sequence: Int
    public let etag: String

    public init(sequence: Int, etag: String) {
        self.sequence = sequence
        self.etag = etag
    }

    public var description: String { "v\(sequence)(\(etag))" }
    public static func < (lhs: RulesetVersion, rhs: RulesetVersion) -> Bool { lhs.sequence < rhs.sequence }
}

public enum RulesetValidationError: Error, Hashable, CustomStringConvertible {
    case malformedFlagKey(String)
    case duplicateFlagKey(String)
    case emptyVariantSet(flag: String)
    case duplicateVariantName(flag: String, variant: String)
    case nonPositiveVariantWeight(flag: String, variant: String, weight: Int)
    case failSafeVariantNotInSet(flag: String, failSafe: String)
    case emptyBucketingSalt(flag: String)
    case forcedVariantNotInSet(flag: String, rule: String, variant: String)
    case duplicateRuleID(flag: String, rule: String)
    case emptyMembershipSet(flag: String, rule: String, attribute: String)

    public var description: String {
        switch self {
        case .malformedFlagKey(let k): return "malformed flag key '\(k)'"
        case .duplicateFlagKey(let k): return "duplicate flag key '\(k)'"
        case .emptyVariantSet(let f): return "flag '\(f)' has no variants"
        case .duplicateVariantName(let f, let v): return "flag '\(f)' declares variant '\(v)' twice"
        case .nonPositiveVariantWeight(let f, let v, let w): return "flag '\(f)' variant '\(v)' has weight \(w); must be > 0"
        case .failSafeVariantNotInSet(let f, let s): return "flag '\(f)' fail-safe variant '\(s)' is not in its variant set"
        case .emptyBucketingSalt(let f): return "flag '\(f)' has an empty bucketing salt"
        case .forcedVariantNotInSet(let f, let r, let v): return "flag '\(f)' rule '\(r)' forces unknown variant '\(v)'"
        case .duplicateRuleID(let f, let r): return "flag '\(f)' declares rule id '\(r)' twice"
        case .emptyMembershipSet(let f, let r, let a): return "flag '\(f)' rule '\(r)' has an empty oneOf set for '\(a)'"
        }
    }
}

/// An immutable, validated, versioned snapshot of every flag.
///
/// Immutability is a system-level guarantee, not a style preference. A single
/// evaluation pass across a screen must never observe two different rulesets —
/// otherwise one view renders the old treatment and its sibling renders the new
/// one, and the resulting screenshot is genuinely impossible to reason about.
/// Swapping a whole value is atomic; mutating a shared dictionary is not.
public struct Ruleset: Sendable, Equatable {
    public let version: RulesetVersion
    public let fetchedAt: Date
    private let flagsByKey: [FlagKey: FlagDefinition]

    public init(version: RulesetVersion, fetchedAt: Date, flags: [FlagDefinition]) throws {
        var byKey: [FlagKey: FlagDefinition] = [:]
        for flag in flags {
            guard flag.key.isWellFormed else { throw RulesetValidationError.malformedFlagKey(flag.key.rawValue) }
            guard byKey[flag.key] == nil else { throw RulesetValidationError.duplicateFlagKey(flag.key.rawValue) }
            try Ruleset.validate(flag)
            byKey[flag.key] = flag
        }
        self.version = version
        self.fetchedAt = fetchedAt
        self.flagsByKey = byKey
    }

    private static func validate(_ flag: FlagDefinition) throws {
        let name = flag.key.rawValue
        guard !flag.variants.isEmpty else { throw RulesetValidationError.emptyVariantSet(flag: name) }
        guard !flag.bucketingSalt.isEmpty else { throw RulesetValidationError.emptyBucketingSalt(flag: name) }

        var seenVariants: Set<String> = []
        for variant in flag.variants {
            guard seenVariants.insert(variant.name).inserted else {
                throw RulesetValidationError.duplicateVariantName(flag: name, variant: variant.name)
            }
            guard variant.weight > 0 else {
                throw RulesetValidationError.nonPositiveVariantWeight(flag: name, variant: variant.name, weight: variant.weight)
            }
        }
        guard seenVariants.contains(flag.failSafeVariant) else {
            throw RulesetValidationError.failSafeVariantNotInSet(flag: name, failSafe: flag.failSafeVariant)
        }

        var seenRules: Set<String> = []
        for rule in flag.targetingRules {
            guard seenRules.insert(rule.id).inserted else {
                throw RulesetValidationError.duplicateRuleID(flag: name, rule: rule.id)
            }
            if case .forceVariant(let forced) = rule.effect, !seenVariants.contains(forced) {
                throw RulesetValidationError.forcedVariantNotInSet(flag: name, rule: rule.id, variant: forced)
            }
            for condition in rule.conditions {
                if case .oneOf(let options) = condition.predicate, options.isEmpty {
                    throw RulesetValidationError.emptyMembershipSet(flag: name, rule: rule.id, attribute: condition.attribute)
                }
            }
        }
    }

    public func definition(for key: FlagKey) -> FlagDefinition? { flagsByKey[key] }
    public var flagKeys: [FlagKey] { flagsByKey.keys.sorted() }
    public var flagCount: Int { flagsByKey.count }
    public var definitions: [FlagDefinition] { flagKeys.compactMap { flagsByKey[$0] } }

    /// Age in seconds relative to `now`, floored at zero. A ruleset stamped in
    /// the future (clock skew between device and server is routine) must read as
    /// "fresh", never as a negative age that underflows a comparison.
    public func age(at now: Date) -> TimeInterval {
        Swift.max(0, now.timeIntervalSince(fetchedAt))
    }

    /// Same content, restamped. Used when a conditional GET returns 304: the
    /// payload did not change but our confidence in its freshness did.
    public func refreshed(at instant: Date) -> Ruleset {
        Ruleset(version: version, fetchedAt: instant, validatedFlags: flagsByKey)
    }

    private init(version: RulesetVersion, fetchedAt: Date, validatedFlags: [FlagKey: FlagDefinition]) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.flagsByKey = validatedFlags
    }

    /// Builds a ruleset **without validating it**.
    ///
    /// Internal, not public, and exists for exactly one reason: the evaluator
    /// carries defence-in-depth branches for definitions that validation would
    /// have rejected (an empty variant set, a rule forcing a variant that does not
    /// exist), and those branches are worthless if they cannot be tested. A
    /// public API for constructing an invalid ruleset would be a footgun; a
    /// `@testable`-only one is a test fixture.
    static func unvalidated(version: RulesetVersion, fetchedAt: Date, flags: [FlagDefinition]) -> Ruleset {
        var byKey: [FlagKey: FlagDefinition] = [:]
        for flag in flags { byKey[flag.key] = flag }
        return Ruleset(version: version, fetchedAt: fetchedAt, validatedFlags: byKey)
    }

    /// A ruleset with no flags.
    ///
    /// Non-throwing on purpose. `Ruleset.init` only throws while validating
    /// flags, so the empty case is total — and having a total constructor is
    /// what lets every fallback path in this package avoid `try!`.
    public static func empty(
        version: RulesetVersion = RulesetVersion(sequence: 0, etag: "empty"),
        at instant: Date = Date(timeIntervalSince1970: 0)
    ) -> Ruleset {
        Ruleset(version: version, fetchedAt: instant, validatedFlags: [:])
    }
}
