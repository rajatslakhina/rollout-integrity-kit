import Foundation

/// Why a variant was served.
///
/// A flag client that returns a bare `Bool` is unoperable at scale: when someone
/// reports "the new checkout is off for me", the only way to answer is to
/// reproduce their exact device state. Every decision here carries the reason,
/// the ruleset it came from, and the buckets it landed in, which turns that
/// conversation into a single log line.
public enum DecisionReason: Hashable, Sendable, CustomStringConvertible {
    case localOverride
    case staleRulesetFailSafe(ageSeconds: Int, ceilingSeconds: Int)
    case stickyPin(pinnedAtSequence: Int)
    case targetingForced(ruleID: String)
    case targetingExcluded(ruleID: String)
    case rolloutIncluded(ruleID: String?)
    case rolloutExcluded(ruleID: String?)
    case unknownFlag
    case malformedDefinition

    public var description: String {
        switch self {
        case .localOverride: return "local override"
        case .staleRulesetFailSafe(let age, let ceiling): return "stale ruleset (\(age)s > \(ceiling)s ceiling) — failed safe"
        case .stickyPin(let seq): return "sticky pin from v\(seq)"
        case .targetingForced(let id): return "targeting rule '\(id)' forced"
        case .targetingExcluded(let id): return "targeting rule '\(id)' excluded"
        case .rolloutIncluded(let id): return id.map { "in rollout (rule '\($0)')" } ?? "in rollout"
        case .rolloutExcluded(let id): return id.map { "out of rollout (rule '\($0)')" } ?? "out of rollout"
        case .unknownFlag: return "unknown flag — caller fallback"
        case .malformedDefinition: return "malformed definition — failed safe"
        }
    }

    /// Whether a decision with this reason should produce an experiment exposure.
    ///
    /// Local overrides and unknown flags must never be recorded. A QA device
    /// forcing treatment is not a user who was assigned treatment, and counting
    /// it is a direct, silent contamination of the experiment's results.
    public var producesExposure: Bool {
        switch self {
        case .localOverride, .unknownFlag, .malformedDefinition:
            return false
        case .staleRulesetFailSafe, .stickyPin, .targetingForced, .targetingExcluded,
             .rolloutIncluded, .rolloutExcluded:
            return true
        }
    }

    /// Whether a decision with this reason should be *pinned*.
    ///
    /// This is deliberately much narrower than `producesExposure`, and the
    /// distinction is load-bearing.
    ///
    /// Pinning an **exclusion** silently destroys ramp monotonicity at the client
    /// level: a user evaluated at 10% who was out would be pinned to the fail-safe
    /// variant, and because the pin outranks the rollout check, raising the ramp to
    /// 100% could never let them in. The pure evaluator would still be monotonic
    /// and the client would not be — which is the worst kind of bug, because the
    /// property test that covers the evaluator would stay green.
    ///
    /// Only an actual *assignment* pins: the user was let into the rollout, or a
    /// targeting rule forced them onto a variant. Being held out, failing safe on
    /// a stale ruleset, or reading a debug override are all states a user must be
    /// able to leave.
    public var producesPin: Bool {
        switch self {
        case .rolloutIncluded, .targetingForced:
            return true
        case .rolloutExcluded, .targetingExcluded, .staleRulesetFailSafe, .stickyPin,
             .localOverride, .unknownFlag, .malformedDefinition:
            return false
        }
    }
}

public struct FlagDecision: Hashable, Sendable {
    public let key: FlagKey
    public let variant: String
    public let reason: DecisionReason
    public let rulesetVersion: RulesetVersion?
    public let inclusionBucket: Int?
    public let splitBucket: Int?

    public init(
        key: FlagKey,
        variant: String,
        reason: DecisionReason,
        rulesetVersion: RulesetVersion?,
        inclusionBucket: Int? = nil,
        splitBucket: Int? = nil
    ) {
        self.key = key
        self.variant = variant
        self.reason = reason
        self.rulesetVersion = rulesetVersion
        self.inclusionBucket = inclusionBucket
        self.splitBucket = splitBucket
    }

    public var producesExposure: Bool { reason.producesExposure }
    public var producesPin: Bool { reason.producesPin }

    /// One-line explanation suitable for a log or a support tool.
    public var auditLine: String {
        let versionText = rulesetVersion.map(\.description) ?? "no-ruleset"
        let bucketText = inclusionBucket.map { "bucket \($0)" } ?? "no-bucket"
        return "\(key.rawValue) = \(variant) [\(reason)] @ \(versionText), \(bucketText)"
    }
}

/// Developer/QA forced values. Kept as its own type so it is impossible to
/// confuse a debug override with a server-delivered rule.
public struct OverrideSet: Hashable, Sendable {
    private var values: [FlagKey: String]

    public init(_ values: [FlagKey: String] = [:]) { self.values = values }

    public func variant(for key: FlagKey) -> String? { values[key] }
    public var isEmpty: Bool { values.isEmpty }
    public var count: Int { values.count }
    public var keys: [FlagKey] { values.keys.sorted() }

    public mutating func set(_ variant: String, for key: FlagKey) { values[key] = variant }
    public mutating func clear(_ key: FlagKey) { values.removeValue(forKey: key) }
    public mutating func clearAll() { values.removeAll() }
}

/// Identifies a pin. Scoped to **both** the flag and the bucketing identity.
///
/// Keying pins on the flag alone is a real bug with a boring cause: a store keyed
/// `[FlagKey: PinnedAssignment]` looks obviously correct right up until the process
/// evaluates a second identity — a device that signs out and back in as someone
/// else, a debug tool that previews another user, a test that reuses the client —
/// and then it serves identity A's pinned variant to identity B.
public struct PinScope: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let key: FlagKey
    public let bucketingID: String

    public init(key: FlagKey, bucketingID: String) {
        self.key = key
        self.bucketingID = bucketingID
    }

    public var description: String { "\(key.rawValue)@\(bucketingID)" }

    public static func < (lhs: PinScope, rhs: PinScope) -> Bool {
        (lhs.key, lhs.bucketingID) < (rhs.key, rhs.bucketingID)
    }
}

public struct PinnedAssignment: Hashable, Sendable {
    public let scope: PinScope
    public let variant: String
    public let pinnedAtSequence: Int

    public var key: FlagKey { scope.key }
    public var bucketingID: String { scope.bucketingID }

    public init(scope: PinScope, variant: String, pinnedAtSequence: Int) {
        self.scope = scope
        self.variant = variant
        self.pinnedAtSequence = pinnedAtSequence
    }

    public init(key: FlagKey, bucketingID: String, variant: String, pinnedAtSequence: Int) {
        self.init(scope: PinScope(key: key, bucketingID: bucketingID),
                  variant: variant, pinnedAtSequence: pinnedAtSequence)
    }
}
