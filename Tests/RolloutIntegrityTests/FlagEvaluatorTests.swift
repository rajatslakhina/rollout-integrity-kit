import XCTest
@testable import RolloutIntegrity

final class FlagEvaluatorTests: XCTestCase {
    private let evaluator = FlagEvaluator()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let key = FlagKey("f")

    private func makeRuleset(
        _ definition: FlagDefinition,
        sequence: Int = 1,
        fetchedAt: Date? = nil
    ) throws -> Ruleset {
        try Ruleset(version: RulesetVersion(sequence: sequence, etag: "e"),
                    fetchedAt: fetchedAt ?? now, flags: [definition])
    }

    private func definition(
        rollout: BasisPoints = .max,
        staleness: StalenessClass = .experiment,
        pin: PinPolicy = .pinOnFirstExposure,
        rules: [TargetingRule] = []
    ) -> FlagDefinition {
        FlagDefinition(
            key: key,
            variants: [Variant(name: "off", weight: 1), Variant(name: "on", weight: 1)],
            failSafeVariant: "off", rollout: rollout, bucketingSalt: "salt",
            targetingRules: rules, stalenessClass: staleness, pinPolicy: pin)
    }

    private func context(_ id: String = "install-0", attributes: [String: AttributeValue] = [:]) -> EvaluationContext {
        EvaluationContext(identity: AssignmentIdentity(bucketingID: id), attributes: attributes)
    }

    // MARK: Missing / malformed input

    func testUnknownFlagReturnsCallerFallbackAndNoExposure() {
        let decision = evaluator.evaluate(
            FlagKey("nope"), in: Ruleset.empty(), context: context(), now: now, fallbackVariant: "fallback")
        XCTAssertEqual(decision.variant, "fallback")
        XCTAssertEqual(decision.reason, .unknownFlag)
        XCTAssertFalse(decision.producesExposure)
    }

    func testNilRulesetReturnsFallback() {
        let decision = evaluator.evaluate(key, in: nil, context: context(), now: now, fallbackVariant: "fallback")
        XCTAssertEqual(decision.variant, "fallback")
        XCTAssertEqual(decision.reason, .unknownFlag)
        XCTAssertNil(decision.rulesetVersion)
    }

    /// `Ruleset.init` rejects these, so it only happens when a definition reaches
    /// the evaluator through a decoder or a hand-built fixture. It must fail safe
    /// rather than index into an empty array.
    func testMalformedDefinitionFailsSafeWithoutCrashing() {
        let broken = FlagDefinition(key: key, variants: [], failSafeVariant: "off",
                                    rollout: .max, bucketingSalt: "s")
        let ruleset = Ruleset.unvalidated(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now, flags: [broken])
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, fallbackVariant: "caller")
        XCTAssertEqual(decision.variant, "caller")
        XCTAssertEqual(decision.reason, .malformedDefinition)
        XCTAssertFalse(decision.producesExposure)
    }

    func testZeroTotalWeightFailsSafe() {
        let broken = FlagDefinition(
            key: key,
            variants: [Variant(name: "off", weight: 0), Variant(name: "on", weight: 0)],
            failSafeVariant: "off", rollout: .max, bucketingSalt: "s")
        let ruleset = Ruleset.unvalidated(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now, flags: [broken])
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, fallbackVariant: "caller")
        XCTAssertEqual(decision.reason, .malformedDefinition)
    }

    /// A rule forcing a variant that is not in the set must fail safe, never
    /// serve a variant the app has no code path for.
    func testRuleForcingAnUnknownVariantFailsSafe() {
        let rule = TargetingRule(id: "ghost", conditions: [], effect: .forceVariant("ghost-variant"))
        let broken = FlagDefinition(
            key: key,
            variants: [Variant(name: "off", weight: 1), Variant(name: "on", weight: 1)],
            failSafeVariant: "off", rollout: .max, bucketingSalt: "s", targetingRules: [rule])
        let ruleset = Ruleset.unvalidated(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now, flags: [broken])
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, fallbackVariant: "caller")
        XCTAssertEqual(decision.variant, "off")
        XCTAssertEqual(decision.reason, .malformedDefinition)
    }

    // MARK: Overrides

    func testLocalOverrideWinsAndIsNeverAnExposure() throws {
        let ruleset = try makeRuleset(definition(rollout: .min))
        var overrides = OverrideSet()
        overrides.set("on", for: key)

        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now,
                                          overrides: overrides, fallbackVariant: "off")
        XCTAssertEqual(decision.variant, "on")
        XCTAssertEqual(decision.reason, .localOverride)
        XCTAssertFalse(decision.producesExposure,
                       "a QA device forcing treatment must never be counted as an assignment")
    }

    func testOverrideNamingARemovedVariantIsIgnored() throws {
        let ruleset = try makeRuleset(definition(rollout: .max))
        var overrides = OverrideSet()
        overrides.set("variant-that-no-longer-exists", for: key)

        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now,
                                          overrides: overrides, fallbackVariant: "off")
        XCTAssertNotEqual(decision.variant, "variant-that-no-longer-exists")
        XCTAssertEqual(decision.reason, .rolloutIncluded(ruleID: nil))
    }

    // MARK: Staleness

    func testKillSwitchFailsClosedPastItsCeiling() throws {
        let killSwitch = FlagDefinition(
            key: key,
            variants: [Variant(name: "enabled", weight: 1), Variant(name: "disabled", weight: 1)],
            failSafeVariant: "enabled", rollout: .max, bucketingSalt: "salt",
            stalenessClass: .killSwitch, pinPolicy: .never)
        let ruleset = try makeRuleset(killSwitch)

        let fresh = evaluator.evaluate(key, in: ruleset, context: context(), now: now.addingTimeInterval(299), fallbackVariant: "enabled")
        XCTAssertNotEqual(fresh.reason, .staleRulesetFailSafe(ageSeconds: 299, ceilingSeconds: 300))

        let stale = evaluator.evaluate(key, in: ruleset, context: context(), now: now.addingTimeInterval(301), fallbackVariant: "enabled")
        XCTAssertEqual(stale.variant, "enabled")
        XCTAssertEqual(stale.reason, .staleRulesetFailSafe(ageSeconds: 301, ceilingSeconds: 300))
        XCTAssertTrue(stale.producesExposure)
    }

    /// An experiment must NOT be re-decided because the device went through a
    /// tunnel — that would move assignments for reasons correlated with
    /// connectivity, which is a bias, not noise.
    func testExperimentNeverGoesStale() throws {
        let ruleset = try makeRuleset(definition(staleness: .experiment))
        let decision = evaluator.evaluate(key, in: ruleset, context: context(),
                                          now: now.addingTimeInterval(86_400 * 30), fallbackVariant: "off")
        XCTAssertEqual(decision.reason, .rolloutIncluded(ruleID: nil))
    }

    func testOperationalCeilingIsOneHour() throws {
        let ruleset = try makeRuleset(definition(staleness: .operational))
        let inside = evaluator.evaluate(key, in: ruleset, context: context(), now: now.addingTimeInterval(3_599), fallbackVariant: "off")
        XCTAssertEqual(inside.reason, .rolloutIncluded(ruleID: nil))
        let outside = evaluator.evaluate(key, in: ruleset, context: context(), now: now.addingTimeInterval(3_601), fallbackVariant: "off")
        XCTAssertEqual(outside.reason, .staleRulesetFailSafe(ageSeconds: 3_601, ceilingSeconds: 3_600))
    }

    // MARK: Sticky pins

    func testStickyPinIsHonoured() throws {
        let ruleset = try makeRuleset(definition(rollout: .min))
        let pin = PinnedAssignment(key: key, variant: "on", pinnedAtSequence: 1)
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, pinned: pin, fallbackVariant: "off")
        XCTAssertEqual(decision.variant, "on")
        XCTAssertEqual(decision.reason, .stickyPin(pinnedAtSequence: 1))
    }

    func testStickyPinIsDiscardedWhenItsVariantIsRemoved() throws {
        let ruleset = try makeRuleset(definition(rollout: .max))
        let pin = PinnedAssignment(key: key, variant: "variant-deleted-last-release", pinnedAtSequence: 1)
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, pinned: pin, fallbackVariant: "off")
        XCTAssertNotEqual(decision.variant, "variant-deleted-last-release")
        XCTAssertEqual(decision.reason, .rolloutIncluded(ruleID: nil))
    }

    func testStickyPinIsIgnoredWhenPolicyIsNever() throws {
        let ruleset = try makeRuleset(definition(rollout: .min, pin: .never))
        let pin = PinnedAssignment(key: key, variant: "on", pinnedAtSequence: 1)
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, pinned: pin, fallbackVariant: "off")
        XCTAssertEqual(decision.variant, "off")
        XCTAssertEqual(decision.reason, .rolloutExcluded(ruleID: nil))
    }

    /// The precedence decision worth defending: a kill switch a sticky pin can
    /// outvote is not a kill switch.
    func testStaleKillSwitchBeatsAStickyPin() throws {
        let killSwitch = FlagDefinition(
            key: key,
            variants: [Variant(name: "enabled", weight: 1), Variant(name: "disabled", weight: 1)],
            failSafeVariant: "enabled", rollout: .max, bucketingSalt: "salt",
            stalenessClass: .killSwitch, pinPolicy: .pinOnFirstExposure)
        let ruleset = try makeRuleset(killSwitch)
        let pin = PinnedAssignment(key: key, variant: "disabled", pinnedAtSequence: 1)

        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now.addingTimeInterval(3_600),
                                          pinned: pin, fallbackVariant: "enabled")
        XCTAssertEqual(decision.variant, "enabled")
        XCTAssertEqual(decision.reason, .staleRulesetFailSafe(ageSeconds: 3_600, ceilingSeconds: 300))
    }

    /// And the reason the ordering above is affordable: experiments have no
    /// ceiling, so their pins are never disturbed by an outage.
    func testExperimentPinSurvivesAnOutage() throws {
        let ruleset = try makeRuleset(definition(staleness: .experiment))
        let pin = PinnedAssignment(key: key, variant: "on", pinnedAtSequence: 1)
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now.addingTimeInterval(86_400),
                                          pinned: pin, fallbackVariant: "off")
        XCTAssertEqual(decision.reason, .stickyPin(pinnedAtSequence: 1))
    }

    // MARK: Targeting

    func testForceVariantRuleShortCircuitsTheRollout() throws {
        let rule = TargetingRule(
            id: "internal",
            conditions: [AttributeCondition(attribute: "internal", predicate: .equals(.boolean(true)))],
            effect: .forceVariant("on"))
        let ruleset = try makeRuleset(definition(rollout: .min, rules: [rule]))

        let matched = evaluator.evaluate(key, in: ruleset, context: context(attributes: ["internal": .boolean(true)]),
                                         now: now, fallbackVariant: "off")
        XCTAssertEqual(matched.variant, "on")
        XCTAssertEqual(matched.reason, .targetingForced(ruleID: "internal"))

        let unmatched = evaluator.evaluate(key, in: ruleset, context: context(attributes: ["internal": .boolean(false)]),
                                           now: now, fallbackVariant: "off")
        XCTAssertEqual(unmatched.reason, .rolloutExcluded(ruleID: nil))
    }

    func testExcludeRuleServesFailSafe() throws {
        let rule = TargetingRule(
            id: "too-old",
            conditions: [AttributeCondition(attribute: "app_version",
                                            predicate: .versionBelow(SemanticVersion(major: 3, minor: 2)))],
            effect: .exclude)
        let ruleset = try makeRuleset(definition(rollout: .max, rules: [rule]))

        let old = evaluator.evaluate(key, in: ruleset,
                                     context: context(attributes: ["app_version": .version(SemanticVersion(major: 3, minor: 1, patch: 9))]),
                                     now: now, fallbackVariant: "off")
        XCTAssertEqual(old.variant, "off")
        XCTAssertEqual(old.reason, .targetingExcluded(ruleID: "too-old"))

        let current = evaluator.evaluate(key, in: ruleset,
                                         context: context(attributes: ["app_version": .version(SemanticVersion(major: 3, minor: 10))]),
                                         now: now, fallbackVariant: "off")
        XCTAssertEqual(current.reason, .rolloutIncluded(ruleID: nil))
    }

    /// `.overrideRollout` keeps the segment on the bucketed path, so internal
    /// dogfooding still splits control/treatment instead of forcing everyone into
    /// treatment and destroying the internal signal.
    func testOverrideRolloutKeepsTheBucketedPath() throws {
        let rule = TargetingRule(
            id: "internal-100",
            conditions: [AttributeCondition(attribute: "internal", predicate: .equals(.boolean(true)))],
            effect: .overrideRollout(.max))
        let ruleset = try makeRuleset(definition(rollout: .min, rules: [rule]))

        var variants = Set<String>()
        for index in 0..<200 {
            let decision = evaluator.evaluate(
                key, in: ruleset,
                context: context("install-\(index)", attributes: ["internal": .boolean(true)]),
                now: now, fallbackVariant: "off")
            XCTAssertEqual(decision.reason, .rolloutIncluded(ruleID: "internal-100"))
            variants.insert(decision.variant)
        }
        XCTAssertEqual(variants, ["off", "on"], "internal population must still split across variants")
    }

    func testFirstMatchingRuleWins() throws {
        let first = TargetingRule(id: "first", conditions: [], effect: .exclude)
        let second = TargetingRule(id: "second", conditions: [], effect: .forceVariant("on"))
        let ruleset = try makeRuleset(definition(rules: [first, second]))
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, fallbackVariant: "off")
        XCTAssertEqual(decision.reason, .targetingExcluded(ruleID: "first"))
    }

    func testMissingAttributeIsANonMatchNotACrash() throws {
        let rule = TargetingRule(
            id: "needs-locale",
            conditions: [AttributeCondition(attribute: "locale", predicate: .oneOf([.string("en_IN")]))],
            effect: .exclude)
        let ruleset = try makeRuleset(definition(rules: [rule]))
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, fallbackVariant: "off")
        XCTAssertEqual(decision.reason, .rolloutIncluded(ruleID: nil))
    }

    // MARK: Rollout edges

    func testZeroAndFullRollout() throws {
        let none = try makeRuleset(definition(rollout: .min))
        let all = try makeRuleset(definition(rollout: .max))
        for index in 0..<500 {
            let ctx = context("install-\(index)")
            XCTAssertEqual(evaluator.evaluate(key, in: none, context: ctx, now: now, fallbackVariant: "off").reason,
                           .rolloutExcluded(ruleID: nil))
            XCTAssertEqual(evaluator.evaluate(key, in: all, context: ctx, now: now, fallbackVariant: "off").reason,
                           .rolloutIncluded(ruleID: nil))
        }
    }

    func testAuditLineIsUsable() throws {
        let ruleset = try makeRuleset(definition())
        let decision = evaluator.evaluate(key, in: ruleset, context: context(), now: now, fallbackVariant: "off")
        XCTAssertTrue(decision.auditLine.contains("f = "))
        XCTAssertTrue(decision.auditLine.contains("v1"))
        XCTAssertTrue(decision.auditLine.contains("bucket"))
    }
}

final class AttributePredicateTests: XCTestCase {
    func testMissingValueNeverMatches() {
        let predicates: [AttributePredicate] = [
            .exists, .equals(.integer(1)), .notEquals(.integer(1)), .oneOf([.integer(1)]),
            .versionAtLeast(SemanticVersion(major: 1)), .versionBelow(SemanticVersion(major: 1)),
            .numericAtLeast(0), .numericBelow(100)
        ]
        for predicate in predicates {
            XCTAssertFalse(predicate.matches(nil), "\(predicate) matched a missing attribute")
        }
    }

    func testNumericPredicatesRejectNonFiniteBoundsAndValues() {
        XCTAssertFalse(AttributePredicate.numericAtLeast(.nan).matches(.integer(5)))
        XCTAssertFalse(AttributePredicate.numericBelow(.nan).matches(.integer(5)))
        XCTAssertFalse(AttributePredicate.numericAtLeast(0).matches(.double(.nan)))
        XCTAssertFalse(AttributePredicate.numericAtLeast(0).matches(.double(.infinity)))
        XCTAssertTrue(AttributePredicate.numericAtLeast(4).matches(.integer(5)))
        XCTAssertTrue(AttributePredicate.numericBelow(6).matches(.double(5.5)))
    }

    func testVersionPredicateAcceptsStringAttributes() {
        XCTAssertTrue(AttributePredicate.versionAtLeast(SemanticVersion(major: 1, minor: 9)).matches(.string("1.10.0")))
        XCTAssertFalse(AttributePredicate.versionAtLeast(SemanticVersion(major: 1, minor: 9)).matches(.string("not-a-version")))
    }

    func testAuthenticatedIDIsVisibleToTargetingOnly() {
        let identity = AssignmentIdentity(bucketingID: "install-1").signedIn(as: "user-9")
        let ctx = EvaluationContext(identity: identity)
        XCTAssertEqual(ctx.attribute(EvaluationContext.authenticatedIDAttribute), .string("user-9"))
        XCTAssertEqual(ctx.identity.bucketingID, "install-1")
    }
}
