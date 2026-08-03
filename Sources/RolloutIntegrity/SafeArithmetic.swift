import Foundation

/// Saturating integer helpers.
///
/// Every one of these exists because the plain operator traps, and a feature-flag
/// client must never be the reason an app crashes. The inputs here are not
/// hypothetical: a ruleset is untrusted network payload, and `Int` overflow in a
/// weight sum or a threshold multiplication is reachable from a malformed one.
enum SafeMath {
    /// `a + b`, saturating at `Int.min`/`Int.max` instead of trapping.
    static func addingSaturating(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return b > 0 ? Int.max : Int.min
    }

    /// `a * b`, saturating instead of trapping.
    static func multiplyingSaturating(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return product }
        return (a > 0) == (b > 0) ? Int.max : Int.min
    }

    /// `(a * b) / c`, computed so the intermediate product cannot overflow and the
    /// divisor cannot be zero.
    static func scaled(_ a: Int, by numerator: Int, over denominator: Int) -> Int {
        guard denominator != 0 else { return 0 }
        let product = multiplyingSaturating(a, numerator)
        // `Int.min / -1` overflows and traps — the one division that does. Reachable
        // only from a hostile `Bucketer` conformer, but a helper whose entire premise
        // is "this cannot trap" has to actually mean it.
        let (quotient, overflow) = product.dividedReportingOverflow(by: denominator)
        return overflow ? Int.max : quotient
    }

    /// `Int(value.rounded())` without the `Int(Double)` trap on NaN, on infinity,
    /// or on a magnitude outside `Int`'s representable range.
    ///
    /// This is used for *magnitudes* (an age in seconds), so `+infinity` saturates
    /// at the ceiling — an infinitely stale ruleset is maximally stale, not fresh.
    /// Note that `BasisPoints(percent:)` deliberately maps non-finite input to **0**
    /// instead: there, a NaN means the payload is corrupt and the safe reading is
    /// "ship this to nobody". Same hazard, opposite safe answer, because one value
    /// describes how bad things are and the other decides who gets a feature.
    static func roundedClampedToInt(_ value: Double, upperBound: Int = Int.max) -> Int {
        if value.isNaN { return 0 }
        let ceiling = Swift.min(upperBound, Double.safeIntCeiling)
        if value == .infinity { return ceiling }
        if value == -.infinity { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(ceiling) { return ceiling }
        if rounded <= 0 { return 0 }
        return Swift.min(ceiling, Int(rounded))
    }
}

extension Double {
    /// The largest `Int` that is exactly representable as a `Double` on this
    /// platform, so a round-trip through `Double` cannot overshoot `Int.max`.
    ///
    /// Derived from `Int.max` rather than hardcoded, because `Int` is 32-bit on
    /// `arm64_32` (every watchOS device) and a literal tuned for 64-bit would trap
    /// there — the precise class of bug this file exists to eliminate. `Double` has
    /// a 53-bit significand, so the top bits of a 64-bit `Int.max` are not
    /// representable; masking them off yields a value that is safe in both
    /// directions.
    static let safeIntCeiling: Int = {
        // 2^53 is the largest integer a `Double` represents exactly. Take the
        // smaller of that and `Int.max`, compared as `Double`s so the choice is made
        // at runtime and is correct for both a 64-bit `Int` (where 2^53 wins) and a
        // 32-bit one (where `Int.max` wins).
        let largestExactDouble = 9_007_199_254_740_992.0  // 2^53
        return largestExactDouble >= Double(Int.max) ? Int.max : Int(largestExactDouble)
    }()

    /// A `Double` clamped into `Int`'s exactly-representable range, so `Int(_:)` on
    /// the result cannot trap on any platform this package supports. Public because
    /// the SwiftUI layer formats durations and must not be the one place that
    /// reaches for a bare conversion.
    public var clampedToIntRange: Double {
        if isNaN { return 0 }
        let ceiling = Double(Double.safeIntCeiling)
        return Swift.min(Swift.max(self, -ceiling), ceiling)
    }
}
