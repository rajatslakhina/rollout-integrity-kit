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
        if value == .infinity { return Swift.min(upperBound, Int(9.0e18)) }
        if value == -.infinity { return 0 }
        let rounded = value.rounded()
        // 9.0e18 is comfortably inside Int64's range (~9.22e18) and comfortably
        // outside any duration this package will ever see, so it is a safe
        // conversion boundary that avoids the Double-to-Int rounding hazard at
        // exactly `Int.max`.
        let ceiling = Swift.min(Double(upperBound), 9.0e18)
        if rounded >= ceiling { return Swift.min(upperBound, Int(ceiling)) }
        if rounded <= -9.0e18 { return 0 }
        return Swift.max(0, Swift.min(upperBound, Int(rounded)))
    }
}

extension Double {
    /// A finite `Double` clamped into `Int`'s representable range, so `Int(_:)` on
    /// the result cannot trap. Public because the SwiftUI layer formats durations
    /// and must not be the one place that reaches for a bare conversion.
    public var clampedToIntRange: Double {
        if isNaN { return 0 }
        return Swift.min(Swift.max(self, -9.0e18), 9.0e18)
    }
}
