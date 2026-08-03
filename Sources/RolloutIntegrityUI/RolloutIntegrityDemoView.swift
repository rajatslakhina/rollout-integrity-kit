#if canImport(SwiftUI)
import SwiftUI
import RolloutIntegrity

/// View model for the demo surface.
///
/// `@Observable` rather than `ObservableObject`: the demo re-evaluates every flag
/// on every ramp change, and per-property change tracking is the difference
/// between redrawing one row and redrawing the whole list.
///
/// Note the deliberate absence of `didSet` on the tracked properties. Property
/// observers on `@Observable` stored properties are a known sharp edge — the
/// macro rewrites them into computed properties, and relying on an observer
/// firing there is exactly the kind of thing that works in a demo and silently
/// stops working after a toolchain bump. Change propagation is done explicitly
/// with `.onChange(of:)` in the view instead.
@MainActor
@Observable
public final class RolloutExplorerModel {
    public private(set) var decisions: [FlagDecision] = []
    public private(set) var auditReport: IntegrityAudit.Report?
    public private(set) var exposureSummary = "no exposures drained yet"
    /// Pins held for the identity currently on screen — not the global count.
    /// The global number grows on every "Shuffle install" and would contradict the
    /// claim, made two lines above it in the UI, that pins do not follow a new user.
    public private(set) var pinnedCount = 0
    public private(set) var isAuditing = false
    public private(set) var currentRuleset: Ruleset?
    public private(set) var clockOffsetSeconds: TimeInterval = 0

    /// Formatted without a bare `Int(Double)` conversion. `clockOffsetSeconds` is
    /// only ever advanced by this type, but the package's own claim is that no
    /// trapping numeric conversion survives anywhere in `Sources/`, and an
    /// exception "because this one is fine" is how that claim stops being true.
    public var stalenessDescription: String? {
        guard clockOffsetSeconds > 0, clockOffsetSeconds.isFinite else { return nil }
        let seconds = Int(clockOffsetSeconds.rounded().clampedToIntRange)
        return "ruleset is \(seconds)s stale — payments.express_checkout has failed closed to its held-out value"
    }

    /// Starts at 0 on purpose. Any non-zero start would evaluate `express_pay` as
    /// *included* before the user touches anything, pin it, and from then on every
    /// slider position would return the same sticky variant — so the one thing this
    /// screen exists to show, a user being admitted by raising the ramp, would never
    /// happen unless you first pressed "Discard pins".
    public var rolloutPercent: Double = 0
    public var isInternalBuild = false
    public var isSignedIn = false
    public var installID = "install-demo-0184"

    private let clock: ManualClock
    private let client: RolloutClient
    private var sequence = 1

    public init(bundledFallback: Ruleset = SampleCatalog.bundledFallback()) {
        let clock = ManualClock(bundledFallback.fetchedAt)
        self.clock = clock
        self.client = RolloutClient(bundledFallback: bundledFallback, clock: clock)
    }

    /// The bucket below which this flag includes *this* user right now. Rendering it
    /// beside each bucket is what makes the ramp legible: without it, a slider drag
    /// that has not yet crossed this identity's bucket looks like a broken control
    /// rather than a correct one.
    ///
    /// It resolves the **effective** ramp, not the base one — a matching
    /// `.overrideRollout` rule (internal builds, say) changes the threshold, and
    /// showing the base value there would print a row reading "in rollout" directly
    /// above "in below 1000" for a user whose bucket is 8452.
    public func inclusionThreshold(for key: FlagKey) -> Int {
        guard let definition = currentRuleset?.definition(for: key) else { return 0 }
        var effective = definition.rollout
        let evaluationContext = context
        for rule in definition.targetingRules where rule.matches(evaluationContext) {
            if case .overrideRollout(let override) = rule.effect { effective = override }
            break
        }
        return effective.value
    }

    /// Size of the bucket space, read from the bucketer rather than hardcoded.
    public let bucketSpace = FNV1aBucketer().bucketCount

    public var context: EvaluationContext {
        SampleCatalog.demoContext(
            installID: installID,
            signedInAs: isSignedIn ? "user-42" : nil,
            isInternalBuild: isInternalBuild)
    }

    /// Publishes a new ruleset at the current ramp and re-evaluates everything.
    public func refresh() async {
        sequence += 1
        let generation = sequence
        let rollout = BasisPoints(percent: rolloutPercent)
        if let ruleset = try? Ruleset(
            version: RulesetVersion(sequence: sequence, etag: "ramp-\(rollout.value)"),
            fetchedAt: clock.now,
            flags: SampleCatalog.allFlags(expressPayRollout: rollout)) {
            await client.apply(ruleset)
        }
        // `.task(id:)` cancels this task when the slider moves again, but neither
        // `await` below is a cancellation point — an actor hop is not one — so a
        // superseded refresh runs to completion and would otherwise publish its
        // stale results *after* the newer one. The generation check is what actually
        // prevents that; the `.task(id:)` cancellation alone does not.
        let ruleset = await client.currentRuleset
        let freshDecisions = await client.decisions(context: context)
        let pins = await pinsForCurrentIdentity()
        guard generation == sequence else { return }
        clockOffsetSeconds = 0
        currentRuleset = ruleset
        decisions = freshDecisions
        pinnedCount = pins
    }

    /// Re-evaluates without publishing a new ruleset — used when only the
    /// evaluation context changed.
    public func reevaluate() async {
        decisions = await client.decisions(context: context)
        pinnedCount = await pinsForCurrentIdentity()
    }

    private func pinsForCurrentIdentity() async -> Int {
        let id = installID
        return await client.pinnedAssignments().filter { $0.bucketingID == id }.count
    }

    /// Moves the clock past the kill switch's five-minute staleness ceiling
    /// *without* refreshing the ruleset, so the fail-closed path is visible.
    public func simulateNetworkOutage(seconds: TimeInterval) async {
        clock.advance(by: seconds)
        clockOffsetSeconds += seconds
        decisions = await client.decisions(context: context)
    }

    public func drainExposures() async {
        let batch = await client.drainExposures()
        exposureSummary = "\(batch.events.count) shipped · \(batch.suppressedDuplicates) duplicates suppressed · \(batch.droppedSinceLastDrain) dropped"
    }

    public func discardPins() async {
        await client.discardPins()
        await reevaluate()
    }


    public func runAudit(populationSize: Int = 10_000) async {
        isAuditing = true
        let rollout = BasisPoints(percent: rolloutPercent)
        let instant = clock.now
        let report: IntegrityAudit.Report? = await Task.detached(priority: .userInitiated) {
            let audit = IntegrityAudit()
            let population = IntegrityAudit.syntheticPopulation(size: populationSize)
            let flagA = SampleCatalog.expressPay(rollout: rollout)
            let flagB = SampleCatalog.searchRanking(rollout: rollout)
            guard let ruleset = try? Ruleset(
                version: RulesetVersion(sequence: 1, etag: "audit"),
                fetchedAt: instant,
                flags: [flagA, flagB]) else { return nil }
            return audit.run(population: population, flagA: flagA, flagB: flagB, ruleset: ruleset, now: instant)
        }.value
        auditReport = report
        isAuditing = false
    }
}

// MARK: - View

public struct RolloutIntegrityDemoView: View {
    @State private var model: RolloutExplorerModel

    /// The **app** decides which ruleset ships compiled into the binary — that is an
    /// app-level product decision, not a library default — so the fallback is a
    /// parameter here rather than something this view reaches out and picks.
    public init(bundledFallback: Ruleset = SampleCatalog.bundledFallback()) {
        _model = State(initialValue: RolloutExplorerModel(bundledFallback: bundledFallback))
    }

    public var body: some View {
        NavigationStack {
            List {
                contextSection
                decisionsSection
                auditSection
                telemetrySection
            }
            .navigationTitle("Rollout Integrity")
            .task { await model.runAudit() }
            // `.task(id:)` rather than `.onChange { Task { ... } }`: dragging the
            // slider fires on every tick, and an unstructured `Task` per tick is an
            // unbounded, uncancellable pile-up. `.task(id:)` cancels the in-flight
            // work when the value changes again, which is the behaviour you want
            // from a control that emits continuously.
            .task(id: model.rolloutPercent) { await model.refresh() }
            .task(id: model.installID) { await model.reevaluate() }
            .task(id: model.isInternalBuild) { await model.reevaluate() }
            .task(id: model.isSignedIn) { await model.reevaluate() }
        }
    }

    private var contextSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Ramp")
                    Spacer()
                    Text(String(format: "%.1f%%", model.rolloutPercent))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.rolloutPercent, in: 0...100, step: 0.5)
            }
            Toggle("Internal build", isOn: $model.isInternalBuild)
            Toggle("Signed in", isOn: $model.isSignedIn)
            HStack {
                Text("Install ID")
                Spacer()
                Text(model.installID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("Shuffle install") {
                model.installID = "install-demo-\(Int.random(in: 1000...9999))"
            }
        } header: {
            Text("Context")
        } footer: {
            Text("Drag the ramp **up**: a user crosses in the moment the threshold passes their bucket, and never falls back out as you keep raising it — that is ramp monotonicity. Drag it back **down** and they stay, but for a different reason: the sticky pin. Toggle \"Signed in\" and every bucket holds exactly where it was. \"Shuffle install\" is a different user, so buckets move and pins do not follow.")
        }
    }

    private var decisionsSection: some View {
        Section {
            if model.decisions.isEmpty {
                Text("No flags in the current ruleset.").foregroundStyle(.secondary)
            } else {
                ForEach(model.decisions, id: \.key) { decision in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(decision.key.rawValue).font(.callout.weight(.medium))
                            Spacer()
                            Text(decision.variant).font(.callout.monospaced())
                        }
                        Text(decision.reason.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let bucket = decision.inclusionBucket {
                            Text("bucket \(bucket)/\(model.bucketSpace) · in below \(model.inclusionThreshold(for: decision.key))\(decision.producesExposure ? "" : " · not counted as an exposure")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Button("Simulate a 10-minute outage") {
                Task { await model.simulateNetworkOutage(seconds: 600) }
            }
            if let staleness = model.stalenessDescription {
                Text(staleness)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Decisions")
        } footer: {
            Text("Every decision carries the reason it was made. A flag client that returns a bare Bool cannot answer \"why is this off for me?\" without a device in your hand.")
        }
    }

    @ViewBuilder
    private var auditSection: some View {
        Section {
            if model.isAuditing {
                HStack(spacing: 10) { ProgressView(); Text("Auditing 10,000 identities…") }
            } else if let report = model.auditReport {
                auditRow("Determinism", report.determinism.passed,
                         report.determinism.goldenVectorMatched
                            ? "golden fingerprint \(report.determinism.goldenVectorFingerprint) matches"
                            : "fingerprint \(report.determinism.goldenVectorFingerprint) != expected \(report.determinism.expectedFingerprint)")
                auditRow("Ramp monotonicity", report.monotonicity.passed,
                         "\(report.monotonicity.violations) identities lost across \(report.monotonicity.steps.count) ramp steps")
                auditRow("Variant stability", report.variantStability.passed,
                         "\(report.variantStability.variantChangesOnRampUp) of \(report.variantStability.identitiesCheckedAtLowRamp) flipped variant on ramp-up")
                auditRow("Cross-flag independence", report.independence.passed,
                         String(format: "joint %.4f vs expected %.4f", report.independence.observedJointRate, report.independence.expectedJointRate))
                auditRow("Bucket uniformity", report.uniformity.passed,
                         report.uniformity.isTabulated
                            ? String(format: "chi2 %.2f (crit %.2f, df %d)", report.uniformity.chiSquare, report.uniformity.criticalValue, report.uniformity.degreesOfFreedom)
                            : "no tabulated critical value for df \(report.uniformity.degreesOfFreedom) — failing closed")
                auditRow("Identity stability", report.identityStability.passed,
                         "\(report.identityStability.variantChangesOnSignIn) variants moved on sign-in")
            } else {
                Text("Audit has not run.").foregroundStyle(.secondary)
            }
            Button("Re-run audit") { Task { await model.runAudit() } }
        } header: {
            Text("Integrity audit")
        } footer: {
            Text("All six of these fail silently in the obvious implementation. The library ships the proof so nobody has to take the README's word for it.")
        }
    }

    private func auditRow(_ title: String, _ passed: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .foregroundStyle(passed ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var telemetrySection: some View {
        Section {
            Text(model.exposureSummary).font(.footnote.monospaced())
            Text("\(model.pinnedCount) sticky assignments held for this install").font(.footnote).foregroundStyle(.secondary)
            Button("Drain exposures") { Task { await model.drainExposures() } }
            Button("Discard pins", role: .destructive) { Task { await model.discardPins() } }
        } header: {
            Text("Telemetry")
        } footer: {
            Text("The drop counter is reported, never swallowed. A telemetry buffer that silently discards under load produces an analysis that is quietly wrong and looks completely fine.")
        }
    }
}

#Preview {
    RolloutIntegrityDemoView()
}
#endif
