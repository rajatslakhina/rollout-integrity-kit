import Foundation

// MARK: - AssignmentIdentity

/// The identity a decision is computed against.
///
/// The split between `bucketingID` and `authenticatedID` is the single most
/// important decision in this package, and it is not cosmetic.
///
/// The obvious implementation buckets on `userID ?? deviceID`. That is a
/// **sample-ratio-mismatch generator**: the moment a user signs in mid-session
/// the bucketing input changes, so the user is re-hashed into a different bucket
/// and can silently cross from control into treatment. Your experiment's
/// exposure counts then no longer match the assignment you intended, and the
/// standard significance test you are about to run assumes exactly the thing you
/// just broke. Worse, the effect is *correlated with signing in* — i.e. with
/// engagement — so it does not average out.
///
/// The fix is a hard separation of concerns:
///
/// - `bucketingID` is install-scoped, generated once, persisted, and **never**
///   changes for the life of the install. It is the only input to the hash.
/// - `authenticatedID` is available to *targeting* (e.g. "only these 40 internal
///   accounts") but never reaches the bucketer.
public struct AssignmentIdentity: Hashable, Sendable {
    /// Stable for the lifetime of the install. The only value fed to the hash.
    public let bucketingID: String
    /// Present only once the user signs in. Targeting-only, never bucketed on.
    public let authenticatedID: String?

    public init(bucketingID: String, authenticatedID: String? = nil) {
        self.bucketingID = bucketingID
        self.authenticatedID = authenticatedID
    }

    /// Returns the same identity with a signed-in user attached. The bucketing
    /// input is preserved by construction — this is the API that makes the
    /// correct behaviour the easy one.
    public func signedIn(as userID: String) -> AssignmentIdentity {
        AssignmentIdentity(bucketingID: bucketingID, authenticatedID: userID)
    }
}

// MARK: - AttributeValue

public enum AttributeValue: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case version(SemanticVersion)

    var numericValue: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .double(let d): return d.isFinite ? d : nil
        case .string, .boolean, .version: return nil
        }
    }

    var versionValue: SemanticVersion? {
        switch self {
        case .version(let v): return v
        case .string(let s): return SemanticVersion(s)
        case .integer, .double, .boolean: return nil
        }
    }
}

// MARK: - EvaluationContext

/// Everything an evaluation is allowed to see. Deliberately a value type with no
/// reference to a client, a network, or a clock: evaluation is a pure function of
/// this plus a `Ruleset`, which is what makes the whole thing replayable in tests.
public struct EvaluationContext: Hashable, Sendable {
    public let identity: AssignmentIdentity
    public let attributes: [String: AttributeValue]

    public init(identity: AssignmentIdentity, attributes: [String: AttributeValue] = [:]) {
        self.identity = identity
        self.attributes = attributes
    }

    public func attribute(_ name: String) -> AttributeValue? {
        if name == EvaluationContext.authenticatedIDAttribute, let uid = identity.authenticatedID {
            return .string(uid)
        }
        return attributes[name]
    }

    /// Reserved attribute name exposing the signed-in user id to targeting rules
    /// *without* exposing it to the bucketer.
    public static let authenticatedIDAttribute = "$authenticatedID"

    public func with(_ name: String, _ value: AttributeValue) -> EvaluationContext {
        var merged = attributes
        merged[name] = value
        return EvaluationContext(identity: identity, attributes: merged)
    }
}
