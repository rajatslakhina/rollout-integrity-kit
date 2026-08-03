import XCTest
@testable import RolloutIntegrity

final class BasisPointsTests: XCTestCase {
    func testClampsOutOfRangeInput() {
        XCTAssertEqual(BasisPoints(clamping: -1).value, 0)
        XCTAssertEqual(BasisPoints(clamping: 999_999).value, 10_000)
        XCTAssertEqual(BasisPoints(clamping: Int.min).value, 0)
        XCTAssertEqual(BasisPoints(clamping: Int.max).value, 10_000)
    }

    /// `Int(Double)` traps on NaN, on infinity, and on anything outside `Int`'s
    /// range. A ruleset arriving from the network is untrusted input, so every one
    /// of these must produce a value rather than a crash.
    ///
    /// Note the deliberate asymmetry: a *non-finite* percent clamps to 0, while a
    /// merely *huge but finite* one clamps to 100%. NaN and infinity mean the
    /// payload is malformed, and the safe reading of a malformed payload is "do
    /// not ship this to anybody" — turning a feature on for the entire user base
    /// because a JSON field decoded badly is the worst available outcome. A finite
    /// 1e300 is an out-of-range number, not a corrupt one, so it saturates.
    func testNonFiniteAndExtremePercentsDoNotTrap() {
        XCTAssertEqual(BasisPoints(percent: .nan).value, 0)
        XCTAssertEqual(BasisPoints(percent: .infinity).value, 0)
        XCTAssertEqual(BasisPoints(percent: -.infinity).value, 0)
        XCTAssertEqual(BasisPoints(percent: .greatestFiniteMagnitude).value, 10_000)
        XCTAssertEqual(BasisPoints(percent: -.greatestFiniteMagnitude).value, 0)
        XCTAssertEqual(BasisPoints(percent: 1e300).value, 10_000)
        XCTAssertEqual(BasisPoints(percent: .signalingNaN).value, 0)
    }

    func testPercentRoundTrip() {
        XCTAssertEqual(BasisPoints(percent: 50).value, 5_000)
        XCTAssertEqual(BasisPoints(percent: 0.5).value, 50)
        XCTAssertEqual(BasisPoints(percent: 0.01).value, 1)
        XCTAssertEqual(BasisPoints(percent: 12.34).percent, 12.34, accuracy: 0.0001)
    }

    func testOrdering() {
        XCTAssertLessThan(BasisPoints(percent: 10), BasisPoints(percent: 25))
        XCTAssertEqual(BasisPoints.min.value, 0)
        XCTAssertEqual(BasisPoints.max.value, 10_000)
    }
}

final class SemanticVersionTests: XCTestCase {
    /// The bug this type exists to prevent: `"1.10.0" < "1.9.0"` is true as
    /// strings and false as versions, so a "requires >= 1.9" rule written against
    /// strings silently excludes everyone who upgraded.
    func testDoubleDigitMinorOutranksSingleDigit() {
        XCTAssertTrue("1.10.0" < "1.9.0")
        guard let ten = SemanticVersion("1.10.0"), let nine = SemanticVersion("1.9.0") else {
            return XCTFail("both versions should parse")
        }
        XCTAssertGreaterThan(ten, nine)
    }

    func testParsingShapes() {
        XCTAssertEqual(SemanticVersion("3"), SemanticVersion(major: 3))
        XCTAssertEqual(SemanticVersion("3.4"), SemanticVersion(major: 3, minor: 4))
        XCTAssertEqual(SemanticVersion("3.4.5"), SemanticVersion(major: 3, minor: 4, patch: 5))
        XCTAssertEqual(SemanticVersion("3.4.5-beta.2"), SemanticVersion(major: 3, minor: 4, patch: 5))
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("x.y.z"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion("-1.0.0"))
        XCTAssertNil(SemanticVersion("1..2"))
        XCTAssertNil(SemanticVersion("-beta"))
    }

    func testNegativeComponentsAreClampedNotTrapped() {
        XCTAssertEqual(SemanticVersion(major: -5, minor: -1, patch: -9).description, "0.0.0")
    }
}

final class FlagKeyTests: XCTestCase {
    func testTrimsAndReportsWellFormedness() {
        XCTAssertEqual(FlagKey("  checkout.pay  ").rawValue, "checkout.pay")
        XCTAssertTrue(FlagKey("checkout.pay").isWellFormed)
        XCTAssertFalse(FlagKey("").isWellFormed)
        XCTAssertFalse(FlagKey("   ").isWellFormed)
        XCTAssertFalse(FlagKey(String(repeating: "a", count: 129)).isWellFormed)
        XCTAssertTrue(FlagKey(String(repeating: "a", count: 128)).isWellFormed)
    }
}
