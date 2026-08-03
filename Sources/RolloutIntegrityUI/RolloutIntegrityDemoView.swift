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
    public private(set) var pinnedCount = 0
    public private(set) var isAuditing = false
    public private(set) var clockOffsetSeconds: TimeInterval = 0

    public var rolloutPercent: Double = 50
    public var isInternalBuild = false
    public var isSignedIn = false
    public var installID = "install-demo-0001"

    private let clock: ManualClock
    private let client: RolloutClient
    private var sequence = 1

    public init() {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_700_000_000))
        self.clock = clock
        self.client = RolloutClient(
            bundledFallback: SampleCatalog.bundledFallback(at: clock.now),
            clock: clock)
    }

    public var context: EvaluationContext {
        SampleCatalog.demoContext(
            installID: installID,
            signedInAs: isSignedIn ? "user-42" : nil,
            isInternalBuild: isInternalBuild)
    }

    /// Publishes a new ruleset at the current ramp and re-evaluates everything.
    public func refresh() async {
        sequence += 1
        let rollout = BasisPoints(percent: rolloutPercent)
        if let ruleset = try? Ruleset(
            version: RulesetVersion(sequence: sequence, etag: "ramp-\(rollout.value)"),
            fetchedAt: clock.now,
            flags: SampleCatalog.allFlags(expressPayRollout: rollout)) {
            await client.apply(ruleset)
        }
        clockOffsetSeconds = 0
        decisions = await client.decisions(context: context)
        pinnedCount = await client.pinnedAssignments().count
    }

    /// Re-evaluates without publishing a new ruleset — used when only the
    /// evaluation context changed.
    public func reevaluate() async {
        decisions = await client.decisions(context: context)
        pinnedCount = await client.pinnedAssignments().count
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
    @State private var model = RolloutExplorerModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                contextSection
                decisionsSection
                auditSection
                telemetrySection
            }
            .navigationTitle("Rollout Integrity")
            .task {
                await model.refresh()
                await model.runAudit()
            }
            .onChange(of: model.rolloutPercent) { Task { await model.refresh() } }
            .onChange(of: model.installID) { Task { await model.reevaluate() } }
            .onChange(of: model.isInternalBuild) { Task { await model.reevaluate() } }
            .onChange(of: model.isSignedIn) { Task { await model.reevaluate() } }
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
            Text("Drag the ramp up and down. Nobody who is already in ever falls back out, and no variant flips — that is ramp monotonicity, live. Toggle \"Signed in\" and watch every bucket stay exactly where it was.")
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
                            Text("bucket \(bucket)/10000\(decision.producesExposure ? "" : " · not counted as an exposure")")
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
            if model.clockOffsetSeconds > 0 {
                Text("ruleset is \(Int(model.clockOffsetSeconds))s stale — the kill switch has already failed closed")
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
                         "fingerprint \(report.determinism.goldenVectorFingerprint)")
                auditRow("Ramp monotonicity", report.monotonicity.passed,
                         "\(report.monotonicity.violations) identities lost across \(report.monotonicity.steps.count) ramp steps")
                auditRow("Cross-flag independence", report.independence.passed,
                         String(format: "joint %.4f vs expected %.4f", report.independence.observedJointRate, report.independence.expectedJointRate))
                auditRow("Bucket uniformity", report.uniformity.passed,
                         String(format: "chi2 %.2f (crit %.2f, df %d)", report.uniformity.chiSquare, report.uniformity.criticalValue, report.uniformity.degreesOfFreedom))
                auditRow("Identity stability", report.identityStability.passed,
                         "\(report.identityStability.variantChangesOnSignIn) variants moved on sign-in")
            } else {
                Text("Audit has not run.").foregroundStyle(.secondary)
            }
            Button("Re-run audit") { Task { await model.runAudit() } }
        } header: {
            Text("Integrity audit")
        } footer: {
            Text("All five of these fail silently in the obvious implementation. The library ships the proof so nobody has to take the README's word for it.")
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
            Text("\(model.pinnedCount) sticky assignments held").font(.footnote).foregroundStyle(.secondary)
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
