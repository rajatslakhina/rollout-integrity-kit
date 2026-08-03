import XCTest
@testable import RolloutIntegrity

/// Every case here traps with the plain operator. A ruleset is untrusted network
/// payload, so each of these is reachable — not hypothetical.
final class SafeArithmeticTests: XCTestCase {
    func testSaturatingAddition() {
        XCTAssertEqual(SafeMath.addingSaturating(2, 3), 5)
        XCTAssertEqual(SafeMath.addingSaturating(.max, 1), .max)
        XCTAssertEqual(SafeMath.addingSaturating(.max, .max), .max)
        XCTAssertEqual(SafeMath.addingSaturating(.min, -1), .min)
        XCTAssertEqual(SafeMath.addingSaturating(.min, .min), .min)
    }

    func testSaturatingMultiplication() {
        XCTAssertEqual(SafeMath.multiplyingSaturating(6, 7), 42)
        XCTAssertEqual(SafeMath.multiplyingSaturating(.max, 2), .max)
        XCTAssertEqual(SafeMath.multiplyingSaturating(.max, -2), .min)
        XCTAssertEqual(SafeMath.multiplyingSaturating(.min, 2), .min)
        XCTAssertEqual(SafeMath.multiplyingSaturating(0, .max), 0)
    }

    func testScaledNeverDividesByZeroOrOverflows() {
        XCTAssertEqual(SafeMath.scaled(5_000, by: 10_000, over: 10_000), 5_000)
        XCTAssertEqual(SafeMath.scaled(1, by: .max, over: 1), .max)
        XCTAssertEqual(SafeMath.scaled(10, by: 10, over: 0), 0)
    }

    func testRoundedClampedToIntHandlesEveryTrappingInput() {
        XCTAssertEqual(SafeMath.roundedClampedToInt(.nan), 0)
        XCTAssertEqual(SafeMath.roundedClampedToInt(.infinity), Int(9.0e18))
        XCTAssertEqual(SafeMath.roundedClampedToInt(-.infinity), 0)
        XCTAssertEqual(SafeMath.roundedClampedToInt(1e300), Int(9.0e18))
        XCTAssertEqual(SafeMath.roundedClampedToInt(-1e300), 0)
        XCTAssertEqual(SafeMath.roundedClampedToInt(.greatestFiniteMagnitude), Int(9.0e18))
        XCTAssertEqual(SafeMath.roundedClampedToInt(300.4), 300)
        XCTAssertEqual(SafeMath.roundedClampedToInt(300.6), 301)
        XCTAssertEqual(SafeMath.roundedClampedToInt(-5), 0)
    }
}

/// The same protection, exercised through the public API rather than the helper.
final class OverflowThroughPublicAPITests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// `[Variant(weight: .max), Variant(weight: .max)]` satisfies `weight > 0`, so
    /// without an upper bound it passes validation and then traps the first time
    /// anything sums the weights.
    func testAbsurdVariantWeightsAreRejectedAtValidation() {
        let flag = FlagDefinition(
            key: FlagKey("f"),
            variants: [Variant(name: "a", weight: .max), Variant(name: "b", weight: .max)],
            failSafeVariant: "a", rollout: .max, bucketingSalt: "s")
        XCTAssertThrowsError(try Ruleset(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now, flags: [flag])) { error in
            XCTAssertEqual(error as? RulesetValidationError,
                           .variantWeightTooLarge(flag: "f", variant: "a", weight: .max))
        }
    }

    func testTooManyVariantsIsRejected() {
        let variants = (0..<(FlagDefinition.maxVariantCount + 1)).map { Variant(name: "v\($0)", weight: 1) }
        let flag = FlagDefinition(key: FlagKey("f"), variants: variants, failSafeVariant: "v0",
                                  rollout: .max, bucketingSalt: "s")
        XCTAssertThrowsError(try Ruleset(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now, flags: [flag])) { error in
            XCTAssertEqual(error as? RulesetValidationError,
                           .tooManyVariants(flag: "f", count: FlagDefinition.maxVariantCount + 1))
        }
    }

    /// Second layer: even a hand-built definition that skipped validation must not
    /// trap when its weights are summed or split.
    func testHandBuiltAbsurdWeightsSaturateRatherThanTrap() {
        let flag = FlagDefinition(
            key: FlagKey("f"),
            variants: [Variant(name: "a", weight: .max), Variant(name: "b", weight: .max)],
            failSafeVariant: "a", rollout: .max, bucketingSalt: "s")
        XCTAssertEqual(flag.totalWeight, .max)
        XCTAssertNotNil(flag.variant(forSplitBucket: 5_000, bucketCount: 10_000))

        let ruleset = Ruleset.unvalidated(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now, flags: [flag])
        let decision = FlagEvaluator().evaluate(
            FlagKey("f"), in: ruleset,
            context: EvaluationContext(identity: AssignmentIdentity(bucketingID: "install-0")),
            now: now, fallbackVariant: "a")
        XCTAssertTrue(["a", "b"].contains(decision.variant))
    }

    /// A hostile bucket count would overflow the rollout-threshold multiplication.
    func testExtremeBucketCountIsBoundedAtBothEnds() {
        XCTAssertEqual(FNV1aBucketer(bucketCount: .max).bucketCount, FNV1aBucketer.maxBucketCount)
        XCTAssertEqual(FNV1aBucketer(bucketCount: .min).bucketCount, 1)

        let bucketer = FNV1aBucketer(bucketCount: .max)
        let flag = SampleCatalog.expressPay(rollout: BasisPoints(percent: 50))
        guard let ruleset = try? Ruleset(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now, flags: [flag]) else {
            return XCTFail("sample flag should validate")
        }
        let decision = FlagEvaluator(bucketer: bucketer).evaluate(
            flag.key, in: ruleset,
            context: EvaluationContext(identity: AssignmentIdentity(bucketingID: "install-0")),
            now: now, fallbackVariant: "control")
        XCTAssertNotNil(decision.inclusionBucket)
    }
}
