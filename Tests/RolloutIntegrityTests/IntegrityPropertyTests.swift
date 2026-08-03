import XCTest
@testable import RolloutIntegrity

/// The four properties this package actually claims, tested against a real
/// population rather than a handful of examples.
///
/// Every one of these fails *silently* in the obvious implementation: nothing
/// crashes, nothing logs, the feature works, and the experiment result is wrong.
/// That is precisely why they are property tests and not spot checks.
final class IntegrityPropertyTests: XCTestCase {
    private let evaluator = FlagEvaluator()
    private let bucketer = FNV1aBucketer()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let population = IntegrityAudit.syntheticPopulation(size: 10_000)

    private func ruleset(rollout: BasisPoints) throws -> Ruleset {
        try Ruleset(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now,
                    flags: [SampleCatalog.expressPay(rollout: rollout), SampleCatalog.searchRanking(rollout: rollout)])
    }

    private func included(at rollout: BasisPoints) throws -> Set<String> {
        let set = try ruleset(rollout: rollout)
        var result: Set<String> = []
        for identifier in population {
            let context = EvaluationContext(identity: AssignmentIdentity(bucketingID: identifier))
            let decision = evaluator.evaluate(SampleCatalog.Keys.expressPay, in: set, context: context,
                                              now: now, fallbackVariant: "control")
            if case .rolloutIncluded = decision.reason { result.insert(identifier) }
        }
        return result
    }

    /// **Ramp monotonicity.** Raising the ramp may only ever add identities.
    ///
    /// The failure mode this guards against is the one users actually notice: an
    /// implementation that folds the percentage into the hash reshuffles the
    /// population on every ramp step, so going 10% → 20% takes the feature away
    /// from roughly 8% of the people who already had it. It looks like a bug
    /// report about "the feature disappeared", and it is completely invisible in
    /// the aggregate counts, which go up exactly as expected.
    func testRampIsMonotonicAcrossTheWholeLadder() throws {
        let steps: [BasisPoints] = [0, 1, 5, 25, 100, 250, 500, 1_000, 2_500, 5_000, 7_500, 9_000, 9_999, 10_000]
            .map { BasisPoints(clamping: $0) }

        var previous: Set<String> = []
        var previousCount = 0
        for step in steps {
            let current = try included(at: step)
            let lost = previous.subtracting(current)
            XCTAssertTrue(lost.isEmpty, "\(lost.count) identities fell out of the rollout at \(step)")
            XCTAssertGreaterThanOrEqual(current.count, previousCount)
            previous = current
            previousCount = current.count
        }
        XCTAssertEqual(previous.count, population.count, "100% must include everyone")
        XCTAssertEqual(try included(at: .min).count, 0, "0% must include nobody")
    }

    /// **Variant stability under ramp.** A user's variant is fixed the moment they
    /// enter and must not move when the ramp does.
    ///
    /// This is the second half of the monotonicity story and the one people miss:
    /// you can get inclusion right and still reshuffle variants, if the split is
    /// computed over "position within the included population" instead of over the
    /// full bucket space.
    func testVariantDoesNotChangeAsTheRampMoves() throws {
        let low = try ruleset(rollout: BasisPoints(percent: 10))
        let high = try ruleset(rollout: BasisPoints(percent: 100))
        var checked = 0

        for identifier in population {
            let context = EvaluationContext(identity: AssignmentIdentity(bucketingID: identifier))
            let atLow = evaluator.evaluate(SampleCatalog.Keys.expressPay, in: low, context: context, now: now, fallbackVariant: "control")
            guard case .rolloutIncluded = atLow.reason else { continue }
            let atHigh = evaluator.evaluate(SampleCatalog.Keys.expressPay, in: high, context: context, now: now, fallbackVariant: "control")
            XCTAssertEqual(atLow.variant, atHigh.variant, "\(identifier) changed variant when the ramp moved")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 800, "expected roughly 10% of 10,000 to be included at the low ramp")
    }

    /// **Cross-flag independence.** Two 50% experiments must overlap on ~25% of
    /// the population, not 50%.
    ///
    /// If both flags reuse a single per-identity bucket, every user in experiment
    /// A is also in experiment B. The experiments are then perfectly confounded
    /// and neither result is interpretable — carryover bias, and the most
    /// expensive bug in this package because it costs the conclusion rather than
    /// the feature.
    func testTwoExperimentsAtTheSameRampAreIndependent() {
        let audit = IntegrityAudit()
        let report = audit.independence(
            population: population,
            flagA: SampleCatalog.expressPay(rollout: BasisPoints(percent: 50)),
            flagB: SampleCatalog.searchRanking(rollout: BasisPoints(percent: 50)))
        XCTAssertEqual(report.expectedJointRate, 0.25, accuracy: 0.0001)
        XCTAssertEqual(report.observedJointRate, 0.25, accuracy: 0.02,
                       "joint inclusion is drifting toward p rather than p*p — the flags share a bucket")
        XCTAssertTrue(report.passed)
    }

    /// **Identity stability.** Signing in must not move anybody.
    ///
    /// Bucketing on `userID ?? deviceID` re-hashes a user the instant they log in
    /// and silently walks them across the control/treatment boundary. Because
    /// signing in correlates with engagement, the resulting sample-ratio mismatch
    /// does not average out.
    func testSigningInMovesNobody() throws {
        let set = try ruleset(rollout: BasisPoints(percent: 50))
        let audit = IntegrityAudit()
        let report = audit.identityStability(
            population: population,
            flag: SampleCatalog.expressPay(rollout: BasisPoints(percent: 50)),
            ruleset: set, now: now)
        XCTAssertEqual(report.variantChangesOnSignIn, 0)
        XCTAssertEqual(report.populationSize, population.count)
        XCTAssertTrue(report.passed)
    }

    /// **Uniformity.** Inclusion buckets must be flat across the space.
    func testBucketDistributionIsUniform() {
        let audit = IntegrityAudit()
        let report = audit.uniformity(population: population, flag: SampleCatalog.expressPay(), binCount: 10)
        XCTAssertEqual(report.binCounts.reduce(0, +), population.count)
        XCTAssertEqual(report.degreesOfFreedom, 9)
        XCTAssertLessThan(report.chiSquare, report.criticalValue,
                          "chi-square \(report.chiSquare) exceeds the 0.1% critical value \(report.criticalValue)")
        XCTAssertTrue(report.passed)
    }

    /// The realised rollout must be close to the requested one.
    func testRealisedRolloutTracksTheRequestedRamp() throws {
        for percent in [1.0, 5.0, 10.0, 25.0, 50.0, 75.0, 90.0] {
            let requested = BasisPoints(percent: percent)
            let count = try included(at: requested).count
            let realised = Double(count) / Double(population.count) * 100
            XCTAssertEqual(realised, percent, accuracy: 1.5,
                           "requested \(percent)% but realised \(realised)%")
        }
    }

    /// Weighted variant splits must land near their declared weights.
    func testWeightedSplitMatchesDeclaredWeights() throws {
        let set = try Ruleset(version: RulesetVersion(sequence: 1, etag: "e"), fetchedAt: now,
                              flags: [SampleCatalog.feedPageSize()])
        var counts: [String: Int] = [:]
        for identifier in population {
            let context = EvaluationContext(identity: AssignmentIdentity(bucketingID: identifier))
            let decision = evaluator.evaluate(SampleCatalog.Keys.feedPageSize, in: set, context: context,
                                              now: now, fallbackVariant: "medium-25")
            counts[decision.variant, default: 0] += 1
        }
        let total = Double(population.count)
        XCTAssertEqual(Double(counts["small-10"] ?? 0) / total, 0.20, accuracy: 0.02)
        XCTAssertEqual(Double(counts["medium-25"] ?? 0) / total, 0.60, accuracy: 0.02)
        XCTAssertEqual(Double(counts["large-50"] ?? 0) / total, 0.20, accuracy: 0.02)
    }

    // MARK: Audit harness edges

    func testFullAuditPasses() throws {
        let set = try ruleset(rollout: BasisPoints(percent: 50))
        let report = IntegrityAudit().run(
            population: population,
            flagA: SampleCatalog.expressPay(rollout: BasisPoints(percent: 50)),
            flagB: SampleCatalog.searchRanking(rollout: BasisPoints(percent: 50)),
            ruleset: set, now: now)
        XCTAssertTrue(report.passed, "failed: \(report.failedCheckNames)")
        XCTAssertTrue(report.failedCheckNames.isEmpty)
    }

    func testAuditHandlesAnEmptyPopulationWithoutCrashing() throws {
        let set = try ruleset(rollout: BasisPoints(percent: 50))
        let report = IntegrityAudit().run(
            population: [], flagA: SampleCatalog.expressPay(), flagB: SampleCatalog.searchRanking(),
            ruleset: set, now: now)
        XCTAssertEqual(report.determinism.populationSize, 0)
        XCTAssertEqual(report.independence.observedJointRate, 0)
        XCTAssertEqual(report.uniformity.binCounts, [Int](repeating: 0, count: 10))
        XCTAssertEqual(report.uniformity.chiSquare, 0)
        XCTAssertEqual(report.variantStability.identitiesCheckedAtLowRamp, 0)
    }

    func testSyntheticPopulationRejectsNonPositiveSizes() {
        XCTAssertTrue(IntegrityAudit.syntheticPopulation(size: 0).isEmpty)
        XCTAssertTrue(IntegrityAudit.syntheticPopulation(size: -10).isEmpty)
        XCTAssertEqual(IntegrityAudit.syntheticPopulation(size: 3), ["install-0", "install-1", "install-2"])
    }

    /// An untabulated degrees-of-freedom must fail **closed**. Returning
    /// `.infinity` as the threshold — the obvious "no opinion" value — makes every
    /// such case silently pass, which is the exact opposite of the intent.
    func testUnknownDegreesOfFreedomFailsClosed() {
        XCTAssertNil(IntegrityAudit.chiSquareCritical999(degreesOfFreedom: 7))
        XCTAssertEqual(IntegrityAudit.chiSquareCritical999(degreesOfFreedom: 9), 27.877)

        let report = IntegrityAudit().uniformity(population: population, flag: SampleCatalog.expressPay(), binCount: 8)
        XCTAssertFalse(report.isTabulated)
        XCTAssertFalse(report.passed, "no tabulated threshold must mean fail, not pass")
        XCTAssertLessThan(report.chiSquare, 100, "the distribution itself is fine; only the threshold is missing")

        let tabulated = IntegrityAudit().uniformity(population: population, flag: SampleCatalog.expressPay(), binCount: 10)
        XCTAssertTrue(tabulated.isTabulated)
        XCTAssertTrue(tabulated.passed)
    }

    /// The determinism check must be falsifiable. Half of it (evaluate twice in one
    /// process) holds for any deterministic function including `Hasher`; the golden
    /// fingerprint is the half with teeth.
    func testDeterminismIsFalsifiableViaTheGoldenFingerprint() {
        let good = IntegrityAudit().determinism(population: population, flag: SampleCatalog.expressPay())
        XCTAssertTrue(good.goldenVectorMatched)
        XCTAssertEqual(good.goldenVectorFingerprint, IntegrityAudit.goldenFingerprint)
        XCTAssertTrue(good.passed)

        // A different (but still perfectly deterministic) hash must fail the check.
        let drifted = IntegrityAudit(bucketer: SaltShiftedBucketer())
            .determinism(population: population, flag: SampleCatalog.expressPay())
        XCTAssertTrue(drifted.repeatedEvaluationsMatched, "still deterministic within the process")
        XCTAssertFalse(drifted.goldenVectorMatched, "but the fingerprint moved")
        XCTAssertFalse(drifted.passed, "so the check fails — which is the point")
    }

    /// A deterministic bucketer that is nonetheless *not this one*.
    private struct SaltShiftedBucketer: Bucketer {
        let bucketCount = 10_000
        func bucket(domain: String, salt: String, identifier: String) -> Int {
            FNV1aBucketer().bucket(domain: domain, salt: salt + "-drift", identifier: identifier)
        }
    }

    func testVariantStabilityIsPartOfTheAudit() {
        let report = IntegrityAudit().variantStability(population: population, flag: SampleCatalog.expressPay())
        XCTAssertGreaterThan(report.identitiesCheckedAtLowRamp, 800)
        XCTAssertEqual(report.variantChangesOnRampUp, 0)
        XCTAssertTrue(report.passed)
    }

    /// The README quotes this ladder; keeping the number in one place stops the
    /// prose and the code drifting apart.
    func testDefaultRampLadderShape() {
        XCTAssertEqual(IntegrityAudit.defaultRampLadder.count, 14)
        XCTAssertEqual(IntegrityAudit.defaultRampLadder.first?.value, 0)
        XCTAssertEqual(IntegrityAudit.defaultRampLadder.last?.value, 10_000)
        XCTAssertEqual(IntegrityAudit.defaultRampLadder, IntegrityAudit.defaultRampLadder.sorted())
    }

    func testUniformityClampsDegenerateBinCounts() {
        let report = IntegrityAudit().uniformity(population: population, flag: SampleCatalog.expressPay(), binCount: 0)
        XCTAssertEqual(report.binCount, 1)
        XCTAssertEqual(report.binCounts, [population.count])
    }

    /// **Mutation test for `IntegrityAudit.monotonicity` itself.**
    ///
    /// A property test that cannot fail is worse than no test, because it reads like
    /// coverage. So: feed the audit a bucketer that re-randomises between ramp steps
    /// — the exact shape of the bug, a hash that moves when the ramp moves — and
    /// assert the audit **reports the violation**. If someone gutted `monotonicity`
    /// to return `violations: 0`, this test would fail, which is the whole point.
    ///
    /// Note this drives the real `IntegrityAudit.monotonicity`, not a reimplementation
    /// of inclusion inline in the test. Asserting that a broken bucketer loses users
    /// proves something about the bucketer; only calling the audit proves something
    /// about the audit.
    func testMonotonicityCheckActuallyDetectsAViolation() {
        let steps: [BasisPoints] = [10, 20, 30, 40, 50].map { BasisPoints(percent: Double($0)) }
        let smallPopulation = IntegrityAudit.syntheticPopulation(size: 500)

        let drifting = StepDriftingBucketer(callsPerStep: smallPopulation.count)
        let brokenReport = IntegrityAudit(bucketer: drifting)
            .monotonicity(population: smallPopulation, flag: SampleCatalog.expressPay(), steps: steps)
        XCTAssertGreaterThan(brokenReport.violations, 0,
                             "the audit failed to notice a bucketer that re-randomises between ramp steps")
        XCTAssertNotNil(brokenReport.firstViolation)
        XCTAssertFalse(brokenReport.passed)

        // Control: the real bucketer over the identical inputs must pass.
        let goodReport = IntegrityAudit()
            .monotonicity(population: smallPopulation, flag: SampleCatalog.expressPay(), steps: steps)
        XCTAssertEqual(goodReport.violations, 0)
        XCTAssertTrue(goodReport.passed)
    }

    /// A bucketer that quietly changes its mapping every `callsPerStep` calls — i.e.
    /// once per ramp step, which is what folding the rollout percentage into the hash
    /// amounts to. Deterministic given a call count, so the test is not flaky.
    ///
    /// `@unchecked Sendable` is justified by the lock: `callCount` is private and
    /// every access is taken under it.
    private final class StepDriftingBucketer: Bucketer, @unchecked Sendable {
        let bucketCount = 10_000
        private let callsPerStep: Int
        private let lock = NSLock()
        private var callCount = 0

        init(callsPerStep: Int) { self.callsPerStep = Swift.max(callsPerStep, 1) }

        func bucket(domain: String, salt: String, identifier: String) -> Int {
            lock.lock()
            let generation = callCount / callsPerStep
            callCount += 1
            lock.unlock()
            return FNV1aBucketer().bucket(domain: domain, salt: "\(salt)-gen\(generation)", identifier: identifier)
        }
    }

    /// A conformer that violates the `Bucketer` contract by returning out-of-range
    /// values. The audit's binning must clamp rather than write out of bounds — which
    /// is a real assertion about defensive code, unlike checking that
    /// `Int(x % UInt64(n))` is less than `n`.
    private struct OutOfRangeBucketer: Bucketer {
        let bucketCount = 10_000
        func bucket(domain: String, salt: String, identifier: String) -> Int {
            identifier.hasSuffix("0") ? Int.min : Int.max
        }
    }

    func testAuditBinningClampsAHostileConformer() {
        let report = IntegrityAudit(bucketer: OutOfRangeBucketer())
            .uniformity(population: IntegrityAudit.syntheticPopulation(size: 200), flag: SampleCatalog.expressPay(), binCount: 10)
        XCTAssertEqual(report.binCounts.count, 10)
        XCTAssertEqual(report.binCounts.reduce(0, +), 200, "every identity must land in some bin")
        XCTAssertFalse(report.passed, "an obviously degenerate distribution must not pass")
    }
}
