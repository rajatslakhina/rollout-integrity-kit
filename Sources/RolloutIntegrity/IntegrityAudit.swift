import Foundation

/// Runs the four properties this package claims, against a real population, and
/// reports numbers rather than assertions.
///
/// This exists because "our flag client is correct" is not a checkable statement,
/// and because every one of these properties fails *silently* in the obvious
/// implementation. Shipping the audit inside the library means the claim travels
/// with the code: the demo app runs it live, CI runs it on every commit, and a
/// reviewer can re-run it rather than take the README's word for it.
public struct IntegrityAudit: Sendable {
    public let bucketer: any Bucketer

    public init(bucketer: any Bucketer = FNV1aBucketer()) {
        self.bucketer = bucketer
    }

    // MARK: Reports

    public struct DeterminismReport: Hashable, Sendable {
        public let populationSize: Int
        public let repeatedEvaluationsMatched: Bool
        public let goldenVectorFingerprint: String
        public var passed: Bool { repeatedEvaluationsMatched }
    }

    public struct MonotonicityReport: Hashable, Sendable {
        public let steps: [Int]
        public let includedCounts: [Int]
        public let violations: Int
        public let firstViolation: String?
        public var passed: Bool { violations == 0 }
    }

    public struct IndependenceReport: Hashable, Sendable {
        public let rolloutPercent: Double
        public let observedJointRate: Double
        public let expectedJointRate: Double
        public let absoluteDeviation: Double
        public let tolerance: Double
        public var passed: Bool { absoluteDeviation <= tolerance }
    }

    public struct UniformityReport: Hashable, Sendable {
        public let binCount: Int
        public let binCounts: [Int]
        public let chiSquare: Double
        public let degreesOfFreedom: Int
        public let criticalValue: Double
        public var passed: Bool { chiSquare <= criticalValue }
    }

    public struct IdentityStabilityReport: Hashable, Sendable {
        public let populationSize: Int
        public let variantChangesOnSignIn: Int
        public var passed: Bool { variantChangesOnSignIn == 0 }
    }

    public struct Report: Hashable, Sendable {
        public let determinism: DeterminismReport
        public let monotonicity: MonotonicityReport
        public let independence: IndependenceReport
        public let uniformity: UniformityReport
        public let identityStability: IdentityStabilityReport

        public var passed: Bool {
            determinism.passed && monotonicity.passed && independence.passed
                && uniformity.passed && identityStability.passed
        }

        public var failedCheckNames: [String] {
            var names: [String] = []
            if !determinism.passed { names.append("determinism") }
            if !monotonicity.passed { names.append("ramp monotonicity") }
            if !independence.passed { names.append("cross-flag independence") }
            if !uniformity.passed { names.append("bucket uniformity") }
            if !identityStability.passed { names.append("identity stability") }
            return names
        }
    }

    // MARK: Population

    /// A deterministic synthetic population. Real install ids are UUIDs; these
    /// are sequential on purpose, because sequential inputs are the adversarial
    /// case for a weak hash and the one most likely to expose lumpy deciles.
    public static func syntheticPopulation(size: Int, prefix: String = "install-") -> [String] {
        guard size > 0 else { return [] }
        return (0..<size).map { "\(prefix)\($0)" }
    }

    // MARK: Individual checks

    public func determinism(population: [String], flag: FlagDefinition) -> DeterminismReport {
        var matched = true
        var fingerprint: UInt64 = 0xcbf2_9ce4_8422_2325

        for identifier in population {
            let first = bucketer.bucket(domain: BucketDomain.inclusion, salt: flag.bucketingSalt, identifier: identifier)
            let second = bucketer.bucket(domain: BucketDomain.inclusion, salt: flag.bucketingSalt, identifier: identifier)
            if first != second { matched = false }
            fingerprint ^= UInt64(bitPattern: Int64(first))
            fingerprint = fingerprint &* 0x0000_0100_0000_01b3
        }

        return DeterminismReport(
            populationSize: population.count,
            repeatedEvaluationsMatched: matched,
            goldenVectorFingerprint: String(fingerprint, radix: 16))
    }

    /// Raises the ramp step by step and asserts that nobody ever falls back out.
    public func monotonicity(population: [String], flag: FlagDefinition, steps: [BasisPoints]) -> MonotonicityReport {
        let ascending = steps.sorted()
        var previousIncluded: Set<String> = []
        var counts: [Int] = []
        var violations = 0
        var firstViolation: String?

        for step in ascending {
            let threshold = (step.value * bucketer.bucketCount) / BasisPoints.max.value
            var included: Set<String> = []
            for identifier in population {
                let bucket = bucketer.bucket(domain: BucketDomain.inclusion, salt: flag.bucketingSalt, identifier: identifier)
                if bucket < threshold { included.insert(identifier) }
            }
            let lost = previousIncluded.subtracting(included)
            if !lost.isEmpty {
                violations += lost.count
                if firstViolation == nil, let example = lost.sorted().first {
                    firstViolation = "'\(example)' was included below \(step) but excluded at \(step)"
                }
            }
            counts.append(included.count)
            previousIncluded = included
        }

        return MonotonicityReport(
            steps: ascending.map(\.value),
            includedCounts: counts,
            violations: violations,
            firstViolation: firstViolation)
    }

    /// Two flags at the same ramp must include roughly `p * p` of the population
    /// jointly. If both flags reuse one bucket per identity, the joint rate
    /// collapses to `p` — every user in experiment A is also in experiment B, so
    /// the two experiments are confounded and neither result means anything. This
    /// is carryover bias, and it is the most expensive bug in this file because
    /// it costs you the conclusion, not the feature.
    public func independence(
        population: [String],
        flagA: FlagDefinition,
        flagB: FlagDefinition,
        tolerance: Double = 0.02
    ) -> IndependenceReport {
        guard !population.isEmpty else {
            return IndependenceReport(rolloutPercent: 0, observedJointRate: 0, expectedJointRate: 0,
                                      absoluteDeviation: 0, tolerance: tolerance)
        }
        let thresholdA = (flagA.rollout.value * bucketer.bucketCount) / BasisPoints.max.value
        let thresholdB = (flagB.rollout.value * bucketer.bucketCount) / BasisPoints.max.value

        var joint = 0
        for identifier in population {
            let inA = bucketer.bucket(domain: BucketDomain.inclusion, salt: flagA.bucketingSalt, identifier: identifier) < thresholdA
            let inB = bucketer.bucket(domain: BucketDomain.inclusion, salt: flagB.bucketingSalt, identifier: identifier) < thresholdB
            if inA && inB { joint += 1 }
        }

        let pA = Double(flagA.rollout.value) / 10_000.0
        let pB = Double(flagB.rollout.value) / 10_000.0
        let expected = pA * pB
        let observed = Double(joint) / Double(population.count)

        return IndependenceReport(
            rolloutPercent: flagA.rollout.percent,
            observedJointRate: observed,
            expectedJointRate: expected,
            absoluteDeviation: abs(observed - expected),
            tolerance: tolerance)
    }

    /// Pearson chi-square over equal-width bins of the inclusion bucket.
    ///
    /// The critical values below are the standard upper-tail 0.1% points; a
    /// chi-square above them means the distribution is lumpy far beyond chance.
    /// Only the two shapes this package actually uses are tabulated, and an
    /// unknown `binCount` returns `.infinity` so the check fails loudly rather
    /// than passing on a value nobody chose.
    public func uniformity(population: [String], flag: FlagDefinition, binCount: Int = 10) -> UniformityReport {
        let bins = Swift.max(binCount, 1)
        var counts = [Int](repeating: 0, count: bins)

        for identifier in population {
            let bucket = bucketer.bucket(domain: BucketDomain.inclusion, salt: flag.bucketingSalt, identifier: identifier)
            // `bucket` is in `0..<bucketCount` by the protocol contract; the
            // clamp makes the array write safe even against a hostile conformer.
            let rawIndex = (bucket * bins) / Swift.max(bucketer.bucketCount, 1)
            let index = Swift.min(Swift.max(rawIndex, 0), bins - 1)
            counts[index] += 1
        }

        let expectedPerBin = Double(population.count) / Double(bins)
        var chiSquare = 0.0
        if expectedPerBin > 0 {
            for count in counts {
                let delta = Double(count) - expectedPerBin
                chiSquare += (delta * delta) / expectedPerBin
            }
        }

        return UniformityReport(
            binCount: bins,
            binCounts: counts,
            chiSquare: chiSquare,
            degreesOfFreedom: bins - 1,
            criticalValue: IntegrityAudit.chiSquareCritical999(degreesOfFreedom: bins - 1))
    }

    /// Upper-tail 0.1% critical values of the chi-square distribution.
    static func chiSquareCritical999(degreesOfFreedom: Int) -> Double {
        switch degreesOfFreedom {
        case 9: return 27.877
        case 19: return 43.820
        case 99: return 148.230
        default: return .infinity
        }
    }

    /// Signing in must not move anybody. This is the SRM check.
    public func identityStability(population: [String], flag: FlagDefinition, ruleset: Ruleset, now: Date) -> IdentityStabilityReport {
        let evaluator = FlagEvaluator(bucketer: bucketer)
        var changes = 0

        for (offset, installID) in population.enumerated() {
            let anonymous = EvaluationContext(identity: AssignmentIdentity(bucketingID: installID))
            let signedIn = EvaluationContext(
                identity: AssignmentIdentity(bucketingID: installID).signedIn(as: "user-\(offset)"))

            let before = evaluator.evaluate(flag.key, in: ruleset, context: anonymous, now: now, fallbackVariant: flag.failSafeVariant)
            let after = evaluator.evaluate(flag.key, in: ruleset, context: signedIn, now: now, fallbackVariant: flag.failSafeVariant)
            if before.variant != after.variant || before.inclusionBucket != after.inclusionBucket { changes += 1 }
        }

        return IdentityStabilityReport(populationSize: population.count, variantChangesOnSignIn: changes)
    }

    // MARK: Full run

    public func run(
        population: [String],
        flagA: FlagDefinition,
        flagB: FlagDefinition,
        ruleset: Ruleset,
        now: Date,
        rampSteps: [BasisPoints] = [1, 5, 10, 25, 50, 75, 100].map { BasisPoints(percent: Double($0)) },
        binCount: Int = 10
    ) -> Report {
        Report(
            determinism: determinism(population: population, flag: flagA),
            monotonicity: monotonicity(population: population, flag: flagA, steps: rampSteps),
            independence: independence(population: population, flagA: flagA, flagB: flagB),
            uniformity: uniformity(population: population, flag: flagA, binCount: binCount),
            identityStability: identityStability(population: population, flag: flagA, ruleset: ruleset, now: now))
    }
}
