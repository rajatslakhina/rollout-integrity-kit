import XCTest
@testable import RolloutIntegrity

/// Decoding is where every "untrusted input" defence in this package finally meets
/// a hostile value. Without these tests the clamping and validation are decoration.
final class WireFormatTests: XCTestCase {
    private let decoder = RulesetDecoder()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func decode(_ json: String) throws -> Ruleset {
        try decoder.decode(Data(json.utf8), fetchedAt: now)
    }

    private let validJSON = """
    {
      "sequence": 42,
      "etag": "abc123",
      "flags": [
        {
          "key": "checkout.express_pay",
          "variants": [{"name": "control", "weight": 50}, {"name": "treatment", "weight": 50}],
          "failSafeVariant": "control",
          "rolloutBasisPoints": 2500,
          "bucketingSalt": "express-pay-2026-q3",
          "staleness": "experiment",
          "pinPolicy": "pinOnFirstExposure",
          "targetingRules": [
            {
              "id": "requires-3-2",
              "conditions": [{"attribute": "app_version", "op": "versionBelow", "string": "3.2.0"}],
              "effect": {"kind": "exclude"}
            },
            {
              "id": "internal-100",
              "conditions": [{"attribute": "is_internal_build", "op": "equals", "bool": true}],
              "effect": {"kind": "overrideRollout", "rolloutBasisPoints": 10000}
            }
          ]
        }
      ]
    }
    """

    func testDecodesAValidPayload() throws {
        let ruleset = try decode(validJSON)
        XCTAssertEqual(ruleset.version, RulesetVersion(sequence: 42, etag: "abc123"))
        XCTAssertEqual(ruleset.flagCount, 1)

        let flag = try XCTUnwrap(ruleset.definition(for: FlagKey("checkout.express_pay")))
        XCTAssertEqual(flag.rollout.value, 2_500)
        XCTAssertEqual(flag.stalenessClass, .experiment)
        XCTAssertEqual(flag.pinPolicy, .pinOnFirstExposure)
        XCTAssertEqual(flag.targetingRules.count, 2)
        XCTAssertEqual(flag.targetingRules.first?.effect, .exclude)
        XCTAssertEqual(flag.targetingRules.last?.effect, .overrideRollout(.max))
    }

    func testDecodedRulesetIsImmediatelyUsable() throws {
        let ruleset = try decode(validJSON)
        let decision = FlagEvaluator().evaluate(
            FlagKey("checkout.express_pay"), in: ruleset,
            context: EvaluationContext(
                identity: AssignmentIdentity(bucketingID: "install-0"),
                attributes: ["app_version": .version(SemanticVersion(major: 3, minor: 1))]),
            now: now, fallbackVariant: "control")
        XCTAssertEqual(decision.reason, .targetingExcluded(ruleID: "requires-3-2"))
    }

    /// Policy: an out-of-range *number* is a typo, so it clamps. Taking the whole
    /// ruleset down and leaving the client on a stale one is the worse outcome.
    func testOutOfRangeRolloutClampsRatherThanThrowing() throws {
        for (raw, expected) in [("99999", 10_000), ("-500", 0), ("10000", 10_000)] {
            let json = validJSON.replacingOccurrences(of: "\"rolloutBasisPoints\": 2500", with: "\"rolloutBasisPoints\": \(raw)")
            let flag = try XCTUnwrap(try decode(json).definition(for: FlagKey("checkout.express_pay")))
            XCTAssertEqual(flag.rollout.value, expected, "rolloutBasisPoints \(raw)")
        }
    }

    /// Policy: an unrecognised *name* throws. Silently dropping a rule this client
    /// does not understand applies a targeting policy nobody wrote — which is how a
    /// hold-out segment quietly ends up inside an experiment.
    func testUnknownPredicateThrows() {
        let json = validJSON.replacingOccurrences(of: "\"op\": \"versionBelow\"", with: "\"op\": \"matchesRegexV2\"")
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? RulesetWireError,
                           .unknownPredicate(flag: "checkout.express_pay", rule: "requires-3-2", op: "matchesRegexV2"))
        }
    }

    func testUnknownEffectThrows() {
        let json = validJSON.replacingOccurrences(of: "\"kind\": \"exclude\"", with: "\"kind\": \"holdoutV3\"")
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? RulesetWireError,
                           .unknownEffect(flag: "checkout.express_pay", rule: "requires-3-2", kind: "holdoutV3"))
        }
    }

    func testUnknownStalenessAndPinPolicyThrow() {
        let staleness = validJSON.replacingOccurrences(of: "\"staleness\": \"experiment\"", with: "\"staleness\": \"eventually\"")
        XCTAssertThrowsError(try decode(staleness)) { error in
            XCTAssertEqual(error as? RulesetWireError,
                           .unknownStalenessClass(flag: "checkout.express_pay", value: "eventually"))
        }
        let pin = validJSON.replacingOccurrences(of: "\"pinPolicy\": \"pinOnFirstExposure\"", with: "\"pinPolicy\": \"sometimes\"")
        XCTAssertThrowsError(try decode(pin)) { error in
            XCTAssertEqual(error as? RulesetWireError,
                           .unknownPinPolicy(flag: "checkout.express_pay", value: "sometimes"))
        }
    }

    func testMalformedVersionOperandThrows() {
        let json = validJSON.replacingOccurrences(of: "\"string\": \"3.2.0\"", with: "\"string\": \"three-point-two\"")
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? RulesetWireError,
                           .malformedVersionOperand(flag: "checkout.express_pay", rule: "requires-3-2", value: "three-point-two"))
        }
    }

    func testMissingPredicateOperandThrows() {
        let json = validJSON.replacingOccurrences(of: "\"op\": \"versionBelow\", \"string\": \"3.2.0\"", with: "\"op\": \"versionBelow\"")
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? RulesetWireError,
                           .missingPredicateOperand(flag: "checkout.express_pay", rule: "requires-3-2", op: "versionBelow"))
        }
    }

    /// The bound added to variant weights has to be reachable from the wire, or it
    /// is not really protecting anything.
    func testAbsurdWeightFromTheWireIsRejectedByValidation() {
        let json = validJSON.replacingOccurrences(of: "\"weight\": 50}, {\"name\": \"treatment\", \"weight\": 50}",
                                                  with: "\"weight\": 9223372036854775807}, {\"name\": \"treatment\", \"weight\": 50}")
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? RulesetValidationError,
                           .variantWeightTooLarge(flag: "checkout.express_pay", variant: "control", weight: .max))
        }
    }

    func testDomainValidationStillAppliesAfterDecoding() {
        let json = validJSON.replacingOccurrences(of: "\"failSafeVariant\": \"control\"", with: "\"failSafeVariant\": \"\"")
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? RulesetValidationError,
                           .emptyFailSafeVariant(flag: "checkout.express_pay"))
        }
    }

    /// A boolean flag on the wire: one treatment arm, a held-out value outside the
    /// set. This is the shape the wire format has to be able to express.
    func testBooleanFlagDecodes() throws {
        let json = """
        {"sequence": 1, "etag": "e", "flags": [{
          "key": "payments.express_checkout",
          "variants": [{"name": "on", "weight": 1}],
          "failSafeVariant": "off",
          "rolloutBasisPoints": 10000,
          "bucketingSalt": "s",
          "staleness": "killSwitch",
          "pinPolicy": "never"
        }]}
        """
        let flag = try XCTUnwrap(try decode(json).definition(for: FlagKey("payments.express_checkout")))
        XCTAssertEqual(flag.variants.count, 1)
        XCTAssertEqual(flag.failSafeVariant, "off")
        XCTAssertEqual(flag.stalenessClass, .killSwitch)
        XCTAssertTrue(flag.containsVariant(named: "off"))
    }

    func testMalformedJSONThrowsADecodingError() {
        XCTAssertThrowsError(try decode("{ not json at all")) { error in
            XCTAssertTrue(error is DecodingError, "expected a DecodingError, got \(error)")
        }
    }

    func testMissingRequiredFieldThrows() {
        let json = validJSON.replacingOccurrences(of: "\"bucketingSalt\": \"express-pay-2026-q3\",", with: "")
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testEmptyFlagListDecodesToAnEmptyRuleset() throws {
        let ruleset = try decode("{\"sequence\": 1, \"etag\": \"e\", \"flags\": []}")
        XCTAssertEqual(ruleset.flagCount, 0)
    }

    func testRoundTripThroughTheWireFormat() throws {
        let payload = RulesetPayload(sequence: 7, etag: "rt", flags: [
            FlagPayload(key: "a.flag",
                        variants: [VariantPayload(name: "off", weight: 1), VariantPayload(name: "on", weight: 3)],
                        failSafeVariant: "off", rolloutBasisPoints: 7_500, bucketingSalt: "salt")
        ])
        let encoded = try JSONEncoder().encode(payload)
        let ruleset = try decoder.decode(encoded, fetchedAt: now)
        let flag = try XCTUnwrap(ruleset.definition(for: FlagKey("a.flag")))
        XCTAssertEqual(flag.rollout.value, 7_500)
        XCTAssertEqual(flag.totalWeight, 4)
        XCTAssertEqual(flag.stalenessClass, .operational, "omitted staleness defaults to operational")
    }
}
