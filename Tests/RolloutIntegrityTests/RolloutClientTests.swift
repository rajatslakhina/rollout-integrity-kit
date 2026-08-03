import XCTest
@testable import RolloutIntegrity

final class RolloutClientTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeClient(
        clock: ManualClock,
        rollout: BasisPoints = BasisPoints(percent: 100)
    ) -> RolloutClient {
        RolloutClient(
            bundledFallback: SampleCatalog.bundledFallback(at: clock.now, expressPayRollout: rollout),
            clock: clock,
            stickyStore: InMemoryStickyAssignmentStore(capacity: 32),
            exposures: ExposureRecorder(capacity: 64))
    }

    private func ruleset(sequence: Int, at instant: Date, rollout: BasisPoints = .max) throws -> Ruleset {
        try Ruleset(version: RulesetVersion(sequence: sequence, etag: "e\(sequence)"),
                    fetchedAt: instant, flags: SampleCatalog.allFlags(expressPayRollout: rollout))
    }

    // MARK: Ruleset ordering

    func testNewerRulesetIsApplied() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        let outcome = await client.apply(try ruleset(sequence: 5, at: start))
        XCTAssertEqual(outcome, .applied(replacing: RulesetVersion(sequence: 1, etag: "bundled")))
        let version = await client.currentVersion
        XCTAssertEqual(version.sequence, 5)
    }

    /// Out-of-order delivery is routine: a CDN edge, a retry and a background
    /// refresh can land in any order. A client that applies whatever arrived last
    /// rolls itself backwards.
    func testOlderRulesetIsRejected() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        _ = await client.apply(try ruleset(sequence: 9, at: start))
        let outcome = await client.apply(try ruleset(sequence: 4, at: start))
        XCTAssertEqual(outcome, .rejectedOlder(current: RulesetVersion(sequence: 9, etag: "e9"),
                                               incoming: RulesetVersion(sequence: 4, etag: "e4")))
        let version = await client.currentVersion
        XCTAssertEqual(version.sequence, 9)
    }

    /// The 304 case: same payload, renewed freshness.
    func testSameSequenceRefreshesFreshnessWithoutChangingDecisions() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        _ = await client.apply(try ruleset(sequence: 3, at: start))
        clock.advance(by: 1_000)

        let outcome = await client.apply(try ruleset(sequence: 3, at: clock.now))
        XCTAssertEqual(outcome, .refreshedSameVersion(RulesetVersion(sequence: 3, etag: "e3")))
        let age = await client.rulesetAge
        XCTAssertEqual(age, 0, accuracy: 0.001)
    }

    func testMarkRefreshedResetsTheStalenessClock() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        _ = await client.apply(try ruleset(sequence: 2, at: start))
        clock.advance(by: 400)

        var decision = await client.decision(for: SampleCatalog.Keys.emergencyDisable, context: SampleCatalog.demoContext())
        XCTAssertEqual(decision.reason, .staleRulesetFailSafe(ageSeconds: 400, ceilingSeconds: 300))

        await client.markRefreshed()
        decision = await client.decision(for: SampleCatalog.Keys.emergencyDisable, context: SampleCatalog.demoContext())
        XCTAssertNotEqual(decision.reason, .staleRulesetFailSafe(ageSeconds: 400, ceilingSeconds: 300))
    }

    // MARK: Pins and exposures

    func testFirstExposurePinsAndSubsequentReadsUseThePin() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: BasisPoints(percent: 100))
        let context = SampleCatalog.demoContext()

        let first = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        XCTAssertEqual(first.reason, .rolloutIncluded(ruleID: nil))

        let pins = await client.pinnedAssignments()
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?.variant, first.variant)

        // Ramp the flag down to zero. The already-exposed user keeps their variant.
        _ = await client.apply(try ruleset(sequence: 20, at: clock.now, rollout: .min))
        let second = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        XCTAssertEqual(second.variant, first.variant)
        XCTAssertEqual(second.reason, .stickyPin(pinnedAtSequence: 1))
    }

    /// **The regression test for the bug this package exists to prevent.**
    ///
    /// A user evaluated while *out* of the rollout must not be pinned to the
    /// fail-safe variant. If they were, the pin would outrank the rollout check on
    /// every later evaluation and raising the ramp could never admit them — the
    /// pure evaluator would still be monotonic, the client would not be, and the
    /// evaluator's own property tests would stay green the whole time.
    func testRampUpAdmitsAPreviouslyExcludedUser() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: .min)
        let context = SampleCatalog.demoContext()

        let excluded = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        XCTAssertEqual(excluded.reason, .rolloutExcluded(ruleID: nil))

        let pins = await client.pinnedAssignments()
        XCTAssertTrue(pins.isEmpty, "an exclusion must never create a pin")

        _ = await client.apply(try ruleset(sequence: 30, at: clock.now, rollout: .max))
        let admitted = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        XCTAssertEqual(admitted.reason, .rolloutIncluded(ruleID: nil),
                       "raising the ramp must be able to admit a user who was previously out")
    }

    /// The same thing at population scale: walk the ramp up and assert the included
    /// set only ever grows, through the *client*, pins and all.
    func testClientLevelRampIsMonotonicAcrossAPopulation() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: .min)
        let identities = (0..<400).map { "install-\($0)" }
        var previous: Set<String> = []
        var sequence = 10

        for percent in [0.0, 5.0, 20.0, 50.0, 80.0, 100.0] {
            sequence += 1
            _ = await client.apply(try ruleset(sequence: sequence, at: clock.now, rollout: BasisPoints(percent: percent)))
            var included: Set<String> = []
            for id in identities {
                let decision = await client.decision(
                    for: SampleCatalog.Keys.expressPay, context: SampleCatalog.demoContext(installID: id))
                switch decision.reason {
                case .rolloutIncluded, .stickyPin: included.insert(id)
                default: break
                }
            }
            XCTAssertTrue(previous.subtracting(included).isEmpty,
                          "\(previous.subtracting(included).count) identities fell out at \(percent)%")
            previous = included
        }
        XCTAssertEqual(previous.count, identities.count, "100% must include everyone")
    }

    /// Pins must not leak between identities.
    func testPinsDoNotLeakAcrossIdentities() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: .max)
        let a = SampleCatalog.demoContext(installID: "install-A")
        let b = SampleCatalog.demoContext(installID: "install-B")

        let first = await client.decision(for: SampleCatalog.Keys.feedPageSize, context: a)
        let second = await client.decision(for: SampleCatalog.Keys.feedPageSize, context: b)

        XCTAssertEqual(first.reason, .rolloutIncluded(ruleID: nil))
        XCTAssertEqual(second.reason, .rolloutIncluded(ruleID: nil),
                       "identity B must be evaluated, not handed identity A's pin")
        let pins = await client.pinnedAssignments()
        XCTAssertEqual(Set(pins.map(\.bucketingID)), ["install-A", "install-B"])
    }

    /// Concurrent first reads must agree: whatever variant is served is the variant
    /// that got pinned, for every racer.
    func testConcurrentFirstReadsAgreeWithThePin() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: .max)
        let context = SampleCatalog.demoContext(installID: "install-race")

        let variants = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<32 {
                group.addTask { await client.decision(for: SampleCatalog.Keys.expressPay, context: context).variant }
            }
            var collected: [String] = []
            for await variant in group { collected.append(variant) }
            return collected
        }

        XCTAssertEqual(Set(variants).count, 1, "concurrent first reads disagreed: \(Set(variants))")
        let pins = await client.pinnedAssignments()
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?.variant, variants.first)
    }

    func testPinPolicyNeverDoesNotPin() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        _ = await client.decision(for: SampleCatalog.Keys.emergencyDisable, context: SampleCatalog.demoContext())
        let pins = await client.pinnedAssignments()
        XCTAssertTrue(pins.isEmpty, "a kill switch must never pin")
    }

    func testDiscardPinsReEvaluates() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: BasisPoints(percent: 100))
        let context = SampleCatalog.demoContext()
        _ = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        await client.discardPins()
        let pins = await client.pinnedAssignments()
        XCTAssertTrue(pins.isEmpty)
    }

    func testOverridesAreServedButNeverExposed() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        let context = SampleCatalog.demoContext()

        await client.setOverride("treatment", for: SampleCatalog.Keys.expressPay)
        let decision = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        XCTAssertEqual(decision.variant, "treatment")
        XCTAssertEqual(decision.reason, .localOverride)

        let batch = await client.drainExposures()
        XCTAssertTrue(batch.events.isEmpty, "an override must not contaminate the experiment")
        let pins = await client.pinnedAssignments()
        XCTAssertTrue(pins.isEmpty, "an override must not create a pin either")

        await client.clearOverride(SampleCatalog.Keys.expressPay)
        let cleared = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        XCTAssertNotEqual(cleared.reason, .localOverride)

        await client.setOverride("treatment", for: SampleCatalog.Keys.expressPay)
        await client.clearAllOverrides()
        let overrides = await client.activeOverrides
        XCTAssertTrue(overrides.isEmpty)
    }

    func testExposuresAreDedupedAcrossRepeatedReads() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        let context = SampleCatalog.demoContext()
        for _ in 0..<50 {
            _ = await client.decision(for: SampleCatalog.Keys.expressPay, context: context)
        }
        let batch = await client.drainExposures()
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.suppressedDuplicates, 49)
    }

    func testUnknownFlagUsesCallerFallbackAndProducesNoExposure() async {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        let decision = await client.decision(for: FlagKey("nope.not.here"),
                                             context: SampleCatalog.demoContext(),
                                             fallbackVariant: "caller-default")
        XCTAssertEqual(decision.variant, "caller-default")
        XCTAssertEqual(decision.reason, .unknownFlag)
        let batch = await client.drainExposures()
        XCTAssertTrue(batch.events.isEmpty)
    }

    func testIsEnabledConvenience() async {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        let internalContext = SampleCatalog.demoContext(isInternalBuild: true)
        let enabled = await client.isEnabled(SampleCatalog.Keys.newProfile, context: internalContext)
        XCTAssertTrue(enabled, "internal builds are forced on by the sample ruleset")
    }

    /// `decisions(context:)` suspends on the sticky store between flags, so a loop
    /// that re-read `self.ruleset` each iteration could return an array whose rows
    /// came from two different rulesets — one view rendering the old treatment and
    /// its sibling the new one. The snapshot is taken once, at the top.
    func testDecisionsAreCoherentAcrossAConcurrentApply() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: .max)
        let context = SampleCatalog.demoContext(installID: "install-tear")

        async let reading: [FlagDecision] = client.decisions(context: context)
        // Publish new rulesets while the read is in flight.
        for sequence in 50..<70 {
            _ = await client.apply(try ruleset(sequence: sequence, at: clock.now, rollout: .max))
        }
        let decisions = await reading

        XCTAssertEqual(decisions.count, 5)
        let versions = Set(decisions.compactMap(\.rulesetVersion))
        XCTAssertEqual(versions.count, 1,
                       "decisions() returned a torn read across \(versions.count) rulesets: \(versions)")
    }

    func testDecisionsCoversEveryFlagInTheRuleset() async {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        let decisions = await client.decisions(context: SampleCatalog.demoContext())
        XCTAssertEqual(decisions.count, 5)
        XCTAssertEqual(Set(decisions.map(\.key)).count, 5)
    }

    /// Bundled fallback: a flag is never undefined, even before the first network
    /// response.
    func testBundledFallbackServesBeforeAnyNetworkResponse() async {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock)
        let decision = await client.decision(for: SampleCatalog.Keys.feedPageSize, context: SampleCatalog.demoContext())
        XCTAssertNotEqual(decision.reason, .unknownFlag)
        XCTAssertTrue(["small-10", "medium-25", "large-50"].contains(decision.variant))
    }

    /// Concurrent readers must all observe one coherent ruleset — never a torn
    /// mix of the old and the new.
    func testConcurrentReadsAreCoherent() async throws {
        let clock = ManualClock(start)
        let client = makeClient(clock: clock, rollout: BasisPoints(percent: 100))
        let contexts = (0..<64).map { SampleCatalog.demoContext(installID: "install-\($0)") }

        let decisions = await withTaskGroup(of: FlagDecision.self, returning: [FlagDecision].self) { group in
            for context in contexts {
                group.addTask { await client.decision(for: SampleCatalog.Keys.feedPageSize, context: context) }
            }
            var collected: [FlagDecision] = []
            for await decision in group { collected.append(decision) }
            return collected
        }

        XCTAssertEqual(decisions.count, 64)
        XCTAssertEqual(Set(decisions.compactMap(\.rulesetVersion)).count, 1,
                       "all readers must have seen the same ruleset version")
        for decision in decisions {
            XCTAssertTrue(["small-10", "medium-25", "large-50"].contains(decision.variant))
        }
    }
}
