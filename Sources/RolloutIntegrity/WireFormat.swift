import Foundation

/// The JSON a config service actually sends, kept deliberately separate from the
/// domain types.
///
/// This layer exists because without it the whole untrusted-input story in this
/// package is unreachable. `BasisPoints` clamps, `Ruleset` validates, variant
/// weights are bounded — but if the only way to build a `Ruleset` is to write
/// Swift literals, none of those defences ever meet a hostile value, and the
/// hardening is decoration.
///
/// Keeping the wire shape as its own type rather than putting `Codable` on the
/// domain types buys two concrete things:
///
/// 1. **The domain type stays unconstructible without validation.** A synthesised
///    `init(from:)` on `Ruleset` would be a second, unvalidated constructor.
/// 2. **The wire format can change without the domain changing, and vice versa.**
///    Renaming a Swift property should not silently break every client on the
///    previous app version.
public struct RulesetPayload: Codable, Sendable, Hashable {
    public let sequence: Int
    public let etag: String
    public let flags: [FlagPayload]

    public init(sequence: Int, etag: String, flags: [FlagPayload]) {
        self.sequence = sequence
        self.etag = etag
        self.flags = flags
    }
}

public struct FlagPayload: Codable, Sendable, Hashable {
    public let key: String
    public let variants: [VariantPayload]
    public let failSafeVariant: String
    public let rolloutBasisPoints: Int
    public let bucketingSalt: String
    public let targetingRules: [RulePayload]?
    public let staleness: String?
    public let pinPolicy: String?

    public init(key: String, variants: [VariantPayload], failSafeVariant: String,
                rolloutBasisPoints: Int, bucketingSalt: String,
                targetingRules: [RulePayload]? = nil, staleness: String? = nil, pinPolicy: String? = nil) {
        self.key = key
        self.variants = variants
        self.failSafeVariant = failSafeVariant
        self.rolloutBasisPoints = rolloutBasisPoints
        self.bucketingSalt = bucketingSalt
        self.targetingRules = targetingRules
        self.staleness = staleness
        self.pinPolicy = pinPolicy
    }
}

public struct VariantPayload: Codable, Sendable, Hashable {
    public let name: String
    public let weight: Int
    public init(name: String, weight: Int) { self.name = name; self.weight = weight }
}

public struct RulePayload: Codable, Sendable, Hashable {
    public let id: String
    public let conditions: [ConditionPayload]?
    public let effect: EffectPayload
    public init(id: String, conditions: [ConditionPayload]? = nil, effect: EffectPayload) {
        self.id = id; self.conditions = conditions; self.effect = effect
    }
}

public struct ConditionPayload: Codable, Sendable, Hashable {
    public let attribute: String
    public let op: String
    public let string: String?
    public let number: Double?
    public let bool: Bool?
    public let strings: [String]?

    public init(attribute: String, op: String, string: String? = nil, number: Double? = nil,
                bool: Bool? = nil, strings: [String]? = nil) {
        self.attribute = attribute; self.op = op; self.string = string
        self.number = number; self.bool = bool; self.strings = strings
    }
}

public struct EffectPayload: Codable, Sendable, Hashable {
    public let kind: String
    public let variant: String?
    public let rolloutBasisPoints: Int?
    public init(kind: String, variant: String? = nil, rolloutBasisPoints: Int? = nil) {
        self.kind = kind; self.variant = variant; self.rolloutBasisPoints = rolloutBasisPoints
    }
}

public enum RulesetWireError: Error, Hashable, CustomStringConvertible {
    case unknownPredicate(flag: String, rule: String, op: String)
    case unknownEffect(flag: String, rule: String, kind: String)
    case unknownStalenessClass(flag: String, value: String)
    case unknownPinPolicy(flag: String, value: String)
    case missingPredicateOperand(flag: String, rule: String, op: String)
    case malformedVersionOperand(flag: String, rule: String, value: String)

    public var description: String {
        switch self {
        case .unknownPredicate(let f, let r, let o): return "flag '\(f)' rule '\(r)': unknown predicate '\(o)'"
        case .unknownEffect(let f, let r, let k): return "flag '\(f)' rule '\(r)': unknown effect '\(k)'"
        case .unknownStalenessClass(let f, let v): return "flag '\(f)': unknown staleness class '\(v)'"
        case .unknownPinPolicy(let f, let v): return "flag '\(f)': unknown pin policy '\(v)'"
        case .missingPredicateOperand(let f, let r, let o): return "flag '\(f)' rule '\(r)': predicate '\(o)' has no operand"
        case .malformedVersionOperand(let f, let r, let v): return "flag '\(f)' rule '\(r)': '\(v)' is not a version"
        }
    }
}

/// Turns wire payloads into validated `Ruleset` values.
///
/// The policy split here is the interesting part, and it is deliberate:
///
/// - **Out-of-range numbers clamp.** A rollout of `99_999` basis points is a
///   number someone fat-fingered, and shipping 100% is the obvious reading. It
///   should not take the whole ruleset down and leave the client on a stale one.
/// - **Unrecognised *names* throw.** An unknown predicate operator or effect kind
///   means this client is older than the ruleset that produced it. There is no
///   safe guess: silently dropping the rule would apply a targeting policy nobody
///   wrote, which is how a hold-out segment quietly ends up in an experiment.
public struct RulesetDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data, fetchedAt: Date) throws -> Ruleset {
        let payload = try JSONDecoder().decode(RulesetPayload.self, from: data)
        return try ruleset(from: payload, fetchedAt: fetchedAt)
    }

    public func ruleset(from payload: RulesetPayload, fetchedAt: Date) throws -> Ruleset {
        let definitions = try payload.flags.map(definition(from:))
        return try Ruleset(
            version: RulesetVersion(sequence: payload.sequence, etag: payload.etag),
            fetchedAt: fetchedAt,
            flags: definitions)
    }

    private func definition(from payload: FlagPayload) throws -> FlagDefinition {
        let name = payload.key
        let staleness: StalenessClass
        switch payload.staleness {
        case nil, "operational": staleness = .operational
        case "killSwitch": staleness = .killSwitch
        case "experiment": staleness = .experiment
        case .some(let other): throw RulesetWireError.unknownStalenessClass(flag: name, value: other)
        }

        let pinPolicy: PinPolicy
        switch payload.pinPolicy {
        case nil, "pinOnFirstExposure": pinPolicy = .pinOnFirstExposure
        case "never": pinPolicy = .never
        case .some(let other): throw RulesetWireError.unknownPinPolicy(flag: name, value: other)
        }

        return FlagDefinition(
            key: FlagKey(payload.key),
            variants: payload.variants.map { Variant(name: $0.name, weight: $0.weight) },
            failSafeVariant: payload.failSafeVariant,
            // Clamped, not validated: an out-of-range percentage is a typo, not a
            // reason to reject a whole ruleset.
            rollout: BasisPoints(clamping: payload.rolloutBasisPoints),
            bucketingSalt: payload.bucketingSalt,
            targetingRules: try (payload.targetingRules ?? []).map { try rule(from: $0, flag: name) },
            stalenessClass: staleness,
            pinPolicy: pinPolicy)
    }

    private func rule(from payload: RulePayload, flag: String) throws -> TargetingRule {
        let effect: RuleEffect
        switch payload.effect.kind {
        case "forceVariant":
            guard let variant = payload.effect.variant else {
                throw RulesetWireError.unknownEffect(flag: flag, rule: payload.id, kind: "forceVariant(no variant)")
            }
            effect = .forceVariant(variant)
        case "exclude":
            effect = .exclude
        case "overrideRollout":
            effect = .overrideRollout(BasisPoints(clamping: payload.effect.rolloutBasisPoints ?? 0))
        case let other:
            throw RulesetWireError.unknownEffect(flag: flag, rule: payload.id, kind: other)
        }

        let conditions = try (payload.conditions ?? []).map { try condition(from: $0, flag: flag, rule: payload.id) }
        return TargetingRule(id: payload.id, conditions: conditions, effect: effect)
    }

    private func condition(from payload: ConditionPayload, flag: String, rule: String) throws -> AttributeCondition {
        func operandValue() throws -> AttributeValue {
            if let bool = payload.bool { return .boolean(bool) }
            if let string = payload.string { return .string(string) }
            if let number = payload.number { return .double(number) }
            throw RulesetWireError.missingPredicateOperand(flag: flag, rule: rule, op: payload.op)
        }
        func version() throws -> SemanticVersion {
            guard let raw = payload.string else {
                throw RulesetWireError.missingPredicateOperand(flag: flag, rule: rule, op: payload.op)
            }
            guard let parsed = SemanticVersion(raw) else {
                throw RulesetWireError.malformedVersionOperand(flag: flag, rule: rule, value: raw)
            }
            return parsed
        }
        func number() throws -> Double {
            guard let value = payload.number else {
                throw RulesetWireError.missingPredicateOperand(flag: flag, rule: rule, op: payload.op)
            }
            return value
        }

        let predicate: AttributePredicate
        switch payload.op {
        case "exists": predicate = .exists
        case "equals": predicate = .equals(try operandValue())
        case "notEquals": predicate = .notEquals(try operandValue())
        case "oneOf":
            guard let options = payload.strings else {
                throw RulesetWireError.missingPredicateOperand(flag: flag, rule: rule, op: payload.op)
            }
            // An empty set is left as-is so `Ruleset` validation rejects it with its
            // own, more specific error rather than this layer guessing.
            predicate = .oneOf(options.map { AttributeValue.string($0) })
        case "versionAtLeast": predicate = .versionAtLeast(try version())
        case "versionBelow": predicate = .versionBelow(try version())
        case "numericAtLeast": predicate = .numericAtLeast(try number())
        case "numericBelow": predicate = .numericBelow(try number())
        case let other: throw RulesetWireError.unknownPredicate(flag: flag, rule: rule, op: other)
        }
        return AttributeCondition(attribute: payload.attribute, predicate: predicate)
    }
}
