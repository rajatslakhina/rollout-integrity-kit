import XCTest
@testable import RolloutIntegrity

final class BucketerTests: XCTestCase {
    private let bucketer = FNV1aBucketer()
    private let salt = "express-pay-2026-q3"

    /// Frozen golden vector.
    ///
    /// These values were produced by an *independent* reference implementation of
    /// FNV-1a/64 + SplitMix64 written in Python, not by printing what the Swift
    /// code happened to return. If this test ever fails, the bucketing function
    /// changed and every user in every live experiment has just been re-randomised
    /// — which is exactly the kind of change that must never land quietly.
    func testGoldenVectorIsFrozen() {
        let expectedInclusion: [(String, Int)] = [
            ("install-0", 7533), ("install-1", 672), ("install-2", 3380),
            ("install-3", 4942), ("install-4", 4646), ("install-5", 1647)
        ]
        for (identifier, expected) in expectedInclusion {
            XCTAssertEqual(
                bucketer.bucket(domain: BucketDomain.inclusion, salt: salt, identifier: identifier),
                expected, "inclusion bucket drifted for \(identifier)")
        }

        let expectedSplit: [(String, Int)] = [
            ("install-0", 3380), ("install-1", 9081), ("install-2", 5360),
            ("install-3", 7337), ("install-4", 5983), ("install-5", 9122)
        ]
        for (identifier, expected) in expectedSplit {
            XCTAssertEqual(
                bucketer.bucket(domain: BucketDomain.variantSplit, salt: salt, identifier: identifier),
                expected, "split bucket drifted for \(identifier)")
        }
    }

    /// The **weak half** of determinism, labelled as such.
    ///
    /// Calling a pure function twice in one process passes for any deterministic
    /// implementation — including `Hasher`, whose per-process seed is exactly the bug
    /// this package cares about. It is kept because it catches a genuinely different
    /// class of mistake (hidden per-call state, an accumulating hasher reused across
    /// calls), and it is named so nobody mistakes it for the real guard. The real
    /// guard is `testGoldenVectorIsFrozen`, which is falsifiable across processes and
    /// across toolchain versions.
    func testRepeatedCallsAreStable_weakHalfOfDeterminism() {
        for index in 0..<500 {
            let identifier = "install-\(index)"
            let first = bucketer.bucket(domain: BucketDomain.inclusion, salt: salt, identifier: identifier)
            let second = bucketer.bucket(domain: BucketDomain.inclusion, salt: salt, identifier: identifier)
            XCTAssertEqual(first, second)
        }
    }

    /// `("ab","c")` and `("a","bc")` must not collide. Without the unit-separator
    /// absorb this is a hash of a concatenation and they would.
    func testDomainSeparationPreventsFieldSmearing() {
        XCTAssertNotEqual(
            bucketer.bucket(domain: "ab", salt: "c", identifier: "x"),
            bucketer.bucket(domain: "a", salt: "bc", identifier: "x"))
        XCTAssertNotEqual(
            bucketer.bucket(domain: "a", salt: "b", identifier: "cd"),
            bucketer.bucket(domain: "a", salt: "bc", identifier: "d"))
    }

    func testInclusionAndSplitDomainsAreDecorrelated() {
        var equalCount = 0
        let population = IntegrityAudit.syntheticPopulation(size: 5_000)
        for identifier in population {
            let inclusion = bucketer.bucket(domain: BucketDomain.inclusion, salt: salt, identifier: identifier)
            let split = bucketer.bucket(domain: BucketDomain.variantSplit, salt: salt, identifier: identifier)
            if inclusion == split { equalCount += 1 }
        }
        // With 10,000 buckets, chance collisions should be around 0.5 in 5,000.
        XCTAssertLessThan(equalCount, 15, "inclusion and split domains look correlated")
    }

    /// A zero or negative bucket count would make `% bucketCount` trap. It is
    /// clamped instead, because a flag client must never be the reason an app
    /// crashes.
    func testDegenerateBucketCountIsClampedNotTrapped() {
        let zero = FNV1aBucketer(bucketCount: 0)
        XCTAssertEqual(zero.bucketCount, 1)
        XCTAssertEqual(zero.bucket(domain: "d", salt: "s", identifier: "i"), 0)

        let negative = FNV1aBucketer(bucketCount: -50)
        XCTAssertEqual(negative.bucketCount, 1)
        XCTAssertEqual(negative.bucket(domain: "d", salt: "s", identifier: "i"), 0)
    }

    func testEmptyAndUnicodeInputsAreHandled() {
        XCTAssertEqual(bucketer.bucket(domain: BucketDomain.inclusion, salt: salt, identifier: ""), 8091)
        let unicode = bucketer.bucket(domain: BucketDomain.inclusion, salt: salt, identifier: "उपयोगकर्ता-७")
        XCTAssertGreaterThanOrEqual(unicode, 0)
        XCTAssertLessThan(unicode, 10_000)
    }
}
