import Foundation

// MARK: - FlagKey

/// A feature-flag identifier.
///
/// Deliberately *not* a failable initializer. A failable `FlagKey` pushes an
/// `Optional` into every call site, and the usual reflex there is `!` — which is
/// exactly the crash we are trying to design out. Instead the type normalises on
/// construction and exposes `isWellFormed`; enforcement happens once, at
/// `Ruleset` construction, where it can throw with a useful message.
public struct FlagKey: Hashable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-empty and short enough to be a stable analytics dimension.
    public var isWellFormed: Bool { !rawValue.isEmpty && rawValue.count <= 128 }

    public var description: String { rawValue }

    public static func < (lhs: FlagKey, rhs: FlagKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - BasisPoints

/// A rollout percentage expressed in basis points (1 bp = 0.01%).
///
/// Percent-as-`Int` is too coarse for a real ramp (you cannot express a 0.5%
/// canary) and percent-as-`Double` makes the inclusion comparison
/// floating-point, which is a terrible property for something that must be
/// bit-for-bit reproducible across app versions. Basis points give exact integer
/// comparison against the bucket space, which is also 10,000 wide.
public struct BasisPoints: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let min = BasisPoints(clamping: 0)
    public static let max = BasisPoints(clamping: 10_000)

    public let value: Int

    /// Clamping is the only non-throwing entry point on purpose: a ruleset that
    /// arrives from the network with `rollout: 12_000` should ship 100%, not trap.
    public init(clamping raw: Int) {
        self.value = Swift.min(Swift.max(raw, 0), 10_000)
    }

    public init(percent: Double) {
        // Non-finite input is a malformed payload, not a 100% rollout: a NaN
        // that decoded out of a bad JSON field must not turn a feature on for
        // the entire user base. A merely huge *finite* value is out of range
        // rather than corrupt, so it saturates at 100% instead. Rounding happens
        // before the `Int` conversion and the input is range-checked, because
        // `Int(Double)` traps on NaN, on infinity, and outside `Int`'s range.
        guard percent.isFinite else {
            self.init(clamping: 0)
            return
        }
        let scaled = (percent * 100).rounded()
        guard scaled >= 0 else {
            self.init(clamping: 0)
            return
        }
        guard scaled <= 10_000 else {
            self.init(clamping: 10_000)
            return
        }
        self.init(clamping: Int(scaled))
    }

    public var percent: Double { Double(value) / 100.0 }
    public var description: String { "\(percent)%" }
    public static func < (lhs: BasisPoints, rhs: BasisPoints) -> Bool { lhs.value < rhs.value }
}

// MARK: - SemanticVersion

/// Minimal semantic version used for app-version targeting.
///
/// Exists because string comparison of versions is a real, shipped bug class:
/// `"1.10.0" < "1.9.0"` is `true` lexicographically and `false` in reality, so a
/// rule written as "iOS app >= 1.9.0" silently excludes every user on 1.10.
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = Swift.max(major, 0)
        self.minor = Swift.max(minor, 0)
        self.patch = Swift.max(patch, 0)
    }

    /// Parses `1`, `1.2`, `1.2.3`, and tolerates a build/prerelease suffix
    /// (`1.2.3-beta.4`) by discarding it. Returns `nil` rather than guessing.
    public init?(_ string: String) {
        let core = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = core.first, !head.isEmpty else { return nil }
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        // Bounds-checked reads; `numbers` has between 1 and 3 elements here.
        self.major = numbers.count > 0 ? numbers[0] : 0
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
