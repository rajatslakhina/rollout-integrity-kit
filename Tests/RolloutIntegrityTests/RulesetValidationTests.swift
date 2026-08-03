import XCTest
@testable import RolloutIntegrity

final class RulesetValidationTests: XCTestCase {
    private let version = RulesetVersion(sequence: 7, etag: "abc")
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func flag(
        key: String = "a.flag",
        variants: [Variant] = [Variant(name: "off", weight: 1), Variant(name: "on", weight: 1)],
        failSafe: String = "off",
        salt: String = "salt",
        rules: [TargetingRule] = []
    ) -> FlagDefinition {
        FlagDefinition(key: FlagKey(key), variants: variants, failSafeVariant: failSafe,
                       rollout: .max, bucketingSalt: salt, targetingRules: rules)
    }

    private func assertThrows(_ expected: RulesetValidationError, _ flags: [FlagDefinition],
                              file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try Ruleset(version: version, fetchedAt: instant, flags: flags)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as RulesetValidationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testRejectsMalformedKey() {
        assertThrows(.malformedFlagKey(""), [flag(key: "   ")])
    }

    func testRejectsDuplicateKey() {
        assertThrows(.duplicateFlagKey("a.flag"), [flag(), flag()])
    }

    func testRejectsEmptyVariantSet() {
        assertThrows(.emptyVariantSet(flag: "a.flag"), [flag(variants: [], failSafe: "off")])
    }

    func testRejectsDuplicateVariantName() {
        assertThrows(.duplicateVariantName(flag: "a.flag", variant: "on"),
                     [flag(variants: [Variant(name: "on", weight: 1), Variant(name: "on", weight: 1)], failSafe: "on")])
    }

    func testRejectsNonPositiveWeight() {
        assertThrows(.nonPositiveVariantWeight(flag: "a.flag", variant: "on", weight: 0),
                     [flag(variants: [Variant(name: "off", weight: 1), Variant(name: "on", weight: 0)])])
        assertThrows(.nonPositiveVariantWeight(flag: "a.flag", variant: "on", weight: -3),
                     [flag(variants: [Variant(name: "off", weight: 1), Variant(name: "on", weight: -3)])])
    }

    /// The fail-safe value is the *held-out* value, not a treatment arm, so it is
    /// allowed to sit outside `variants` — that is how a boolean flag is expressed
    /// (`variants: ["on"]`, fail-safe `"off"`). It must still exist.
    func testFailSafeMaySitOutsideTheTreatmentSet() throws {
        let ruleset = try Ruleset(version: version, fetchedAt: instant,
                                  flags: [flag(variants: [Variant(name: "on", weight: 1)], failSafe: "off")])
        let definition = try XCTUnwrap(ruleset.definition(for: FlagKey("a.flag")))
        XCTAssertTrue(definition.containsVariant(named: "off"))
        XCTAssertTrue(definition.containsVariant(named: "on"))
        XCTAssertFalse(definition.containsVariant(named: "ghost"))
    }

    func testRejectsEmptyFailSafe() {
        assertThrows(.emptyFailSafeVariant(flag: "a.flag"), [flag(failSafe: "")])
    }

    /// A single-arm flag at 100% must serve that arm to everyone. Declaring
    /// `["on", "off"]` instead would hand "off" to half the included population —
    /// a "100% rollout" that silently ships to 50% of users.
    func testBooleanFlagAtFullRampServesEveryoneTheSingleArm() throws {
        let boolean = FlagDefinition(
            key: FlagKey("b.flag"), variants: [Variant(name: "on", weight: 1)],
            failSafeVariant: "off", rollout: .max, bucketingSalt: "salt")
        let ruleset = try Ruleset(version: version, fetchedAt: instant, flags: [boolean])
        let evaluator = FlagEvaluator()
        for index in 0..<500 {
            let context = EvaluationContext(identity: AssignmentIdentity(bucketingID: "install-\(index)"))
            let decision = evaluator.evaluate(FlagKey("b.flag"), in: ruleset, context: context,
                                              now: instant, fallbackVariant: "off")
            XCTAssertEqual(decision.variant, "on")
        }
    }

    func testBooleanFlagAtZeroRampServesTheHeldOutValue() throws {
        let boolean = FlagDefinition(
            key: FlagKey("b.flag"), variants: [Variant(name: "on", weight: 1)],
            failSafeVariant: "off", rollout: .min, bucketingSalt: "salt")
        let ruleset = try Ruleset(version: version, fetchedAt: instant, flags: [boolean])
        let evaluator = FlagEvaluator()
        for index in 0..<200 {
            let context = EvaluationContext(identity: AssignmentIdentity(bucketingID: "install-\(index)"))
            XCTAssertEqual(evaluator.evaluate(FlagKey("b.flag"), in: ruleset, context: context,
                                              now: instant, fallbackVariant: "off").variant, "off")
        }
    }

    func testRejectsEmptySalt() {
        assertThrows(.emptyBucketingSalt(flag: "a.flag"), [flag(salt: "")])
    }

    func testRejectsForcedVariantOutsideVariantSet() {
        let rule = TargetingRule(id: "r1", conditions: [], effect: .forceVariant("ghost"))
        assertThrows(.forcedVariantNotInSet(flag: "a.flag", rule: "r1", variant: "ghost"), [flag(rules: [rule])])
    }

    func testRejectsDuplicateRuleID() {
        let a = TargetingRule(id: "r1", conditions: [], effect: .exclude)
        let b = TargetingRule(id: "r1", conditions: [], effect: .exclude)
        assertThrows(.duplicateRuleID(flag: "a.flag", rule: "r1"), [flag(rules: [a, b])])
    }

    /// An empty `oneOf` matches nothing, which reads as "this rule is broken" far
    /// more often than it reads as intent.
    func testRejectsEmptyMembershipSet() {
        let rule = TargetingRule(
            id: "r1",
            conditions: [AttributeCondition(attribute: "locale", predicate: .oneOf([]))],
            effect: .exclude)
        assertThrows(.emptyMembershipSet(flag: "a.flag", rule: "r1", attribute: "locale"), [flag(rules: [rule])])
    }

    func testEmptyRulesetIsValid() throws {
        let ruleset = try Ruleset(version: version, fetchedAt: instant, flags: [])
        XCTAssertEqual(ruleset.flagCount, 0)
        XCTAssertTrue(ruleset.flagKeys.isEmpty)
        XCTAssertNil(ruleset.definition(for: FlagKey("anything")))
    }

    func testEmptyFactoryIsTotal() {
        let ruleset = Ruleset.empty()
        XCTAssertEqual(ruleset.flagCount, 0)
        XCTAssertTrue(ruleset.definitions.isEmpty)
    }

    /// Device clocks run ahead of servers all the time. A ruleset stamped in the
    /// future must read as fresh, not as a negative age that inverts every
    /// staleness comparison.
    func testAgeIsFlooredAtZeroUnderClockSkew() throws {
        let ruleset = try Ruleset(version: version, fetchedAt: instant, flags: [flag()])
        XCTAssertEqual(ruleset.age(at: instant.addingTimeInterval(-3_600)), 0)
        XCTAssertEqual(ruleset.age(at: instant), 0)
        XCTAssertEqual(ruleset.age(at: instant.addingTimeInterval(90)), 90, accuracy: 0.001)
    }

    func testRefreshedPreservesContentAndVersion() throws {
        let ruleset = try Ruleset(version: version, fetchedAt: instant, flags: [flag()])
        let refreshed = ruleset.refreshed(at: instant.addingTimeInterval(500))
        XCTAssertEqual(refreshed.version, ruleset.version)
        XCTAssertEqual(refreshed.flagKeys, ruleset.flagKeys)
        XCTAssertEqual(refreshed.age(at: instant.addingTimeInterval(500)), 0)
    }

    func testVersionOrdersBySequenceNotEtag() {
        XCTAssertLessThan(RulesetVersion(sequence: 1, etag: "zzz"), RulesetVersion(sequence: 2, etag: "aaa"))
    }

    func testSampleCatalogFallbackIsValid() {
        let fallback = SampleCatalog.bundledFallback()
        XCTAssertEqual(fallback.flagCount, 5)
        XCTAssertNotNil(fallback.definition(for: SampleCatalog.Keys.expressPay))
        XCTAssertNotNil(fallback.definition(for: SampleCatalog.Keys.expressCheckout))
    }
}

final class VariantSplitTests: XCTestCase {
    private let definition = FlagDefinition(
        key: FlagKey("f"),
        variants: [Variant(name: "a", weight: 20), Variant(name: "b", weight: 60), Variant(name: "c", weight: 20)],
        failSafeVariant: "b", rollout: .max, bucketingSalt: "s")

    func testRespectsWeightBoundaries() {
        XCTAssertEqual(definition.variant(forSplitBucket: 0, bucketCount: 10_000), "a")
        XCTAssertEqual(definition.variant(forSplitBucket: 1_999, bucketCount: 10_000), "a")
        XCTAssertEqual(definition.variant(forSplitBucket: 2_000, bucketCount: 10_000), "b")
        XCTAssertEqual(definition.variant(forSplitBucket: 7_999, bucketCount: 10_000), "b")
        XCTAssertEqual(definition.variant(forSplitBucket: 8_000, bucketCount: 10_000), "c")
        XCTAssertEqual(definition.variant(forSplitBucket: 9_999, bucketCount: 10_000), "c")
    }

    /// Out-of-range buckets are clamped rather than used as an array index.
    func testOutOfRangeBucketsAreClamped() {
        XCTAssertEqual(definition.variant(forSplitBucket: -1, bucketCount: 10_000), "a")
        XCTAssertEqual(definition.variant(forSplitBucket: Int.min, bucketCount: 10_000), "a")
        XCTAssertEqual(definition.variant(forSplitBucket: 10_000, bucketCount: 10_000), "c")
        XCTAssertEqual(definition.variant(forSplitBucket: Int.max, bucketCount: 10_000), "c")
    }

    func testDegenerateDefinitionsReturnNilRatherThanIndexing() {
        let empty = FlagDefinition(key: FlagKey("f"), variants: [], failSafeVariant: "x",
                                   rollout: .max, bucketingSalt: "s")
        XCTAssertNil(empty.variant(forSplitBucket: 5, bucketCount: 10_000))
        XCTAssertNil(definition.variant(forSplitBucket: 5, bucketCount: 0))
        XCTAssertNil(definition.variant(forSplitBucket: 5, bucketCount: -1))
    }

    func testEveryBucketMapsToSomeVariant() {
        for bucket in stride(from: 0, to: 10_000, by: 7) {
            XCTAssertNotNil(definition.variant(forSplitBucket: bucket, bucketCount: 10_000))
        }
    }
}
