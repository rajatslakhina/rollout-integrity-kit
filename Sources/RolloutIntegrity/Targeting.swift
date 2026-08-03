import Foundation

public enum AttributePredicate: Hashable, Sendable {
    case exists
    case equals(AttributeValue)
    case notEquals(AttributeValue)
    /// Membership test. An empty set is rejected at ruleset-validation time
    /// rather than silently matching nothing.
    case oneOf([AttributeValue])
    case versionAtLeast(SemanticVersion)
    case versionBelow(SemanticVersion)
    case numericAtLeast(Double)
    case numericBelow(Double)

    /// Total function over an *optional* value: a missing attribute is a
    /// non-match, never a crash and never an implicit `true`.
    public func matches(_ value: AttributeValue?) -> Bool {
        guard let value else { return false }
        switch self {
        case .exists:
            return true
        case .equals(let expected):
            return value == expected
        case .notEquals(let expected):
            return value != expected
        case .oneOf(let options):
            return options.contains(value)
        case .versionAtLeast(let floor):
            guard let actual = value.versionValue else { return false }
            return actual >= floor
        case .versionBelow(let ceiling):
            guard let actual = value.versionValue else { return false }
            return actual < ceiling
        case .numericAtLeast(let floor):
            guard let actual = value.numericValue, floor.isFinite else { return false }
            return actual >= floor
        case .numericBelow(let ceiling):
            guard let actual = value.numericValue, ceiling.isFinite else { return false }
            return actual < ceiling
        }
    }
}

public struct AttributeCondition: Hashable, Sendable {
    public let attribute: String
    public let predicate: AttributePredicate

    public init(attribute: String, predicate: AttributePredicate) {
        self.attribute = attribute
        self.predicate = predicate
    }
}

public enum RuleEffect: Hashable, Sendable {
    /// Serve this variant to the matched segment, bypassing the rollout entirely.
    case forceVariant(String)
    /// Hold this segment out of the flag completely (serves the fail-safe variant).
    case exclude
    /// Keep the segment on the normal bucketed path but at a different ramp —
    /// this is how "internal builds are always at 100%" is expressed without
    /// forcing a variant and thereby destroying the internal A/B signal.
    case overrideRollout(BasisPoints)
}

/// A targeting rule. All `conditions` must match (AND). Rules are evaluated in
/// declaration order and the first match wins — order is part of the contract, so
/// a ruleset is not a set.
public struct TargetingRule: Hashable, Sendable {
    public let id: String
    public let conditions: [AttributeCondition]
    public let effect: RuleEffect

    public init(id: String, conditions: [AttributeCondition], effect: RuleEffect) {
        self.id = id
        self.conditions = conditions
        self.effect = effect
    }

    /// An empty condition list is an intentional catch-all (useful as a final
    /// rule); it is allowed but validated to be unique-id'd like any other.
    public func matches(_ context: EvaluationContext) -> Bool {
        for condition in conditions {
            guard condition.predicate.matches(context.attribute(condition.attribute)) else {
                return false
            }
        }
        return true
    }
}
