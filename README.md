# RolloutIntegrityKit

**A feature flag looks like a `Bool` and behaves like a distributed system.**

Three of the four properties that decide whether your experiment results are
trustworthy are silently violated by the obvious implementation. Nothing crashes.
Nothing logs. The feature works. The conclusion is wrong.

This package is a client-side feature-flag and experiment-assignment engine built
around those properties, plus a runnable audit that proves them against a real
population instead of asserting them in a README.

```
swift build   →  clean, 0 warnings, Swift 6 language mode
swift test    →  102 tests, 251 assertion sites, 0 failures
```

---

## The four properties, and how each one fails quietly

### 1. Ramp monotonicity — raising the rollout may only ever *add* users

The tempting implementation hashes the ramp into the bucket
(`hash("\(userID)-\(percentage)")`) or takes the bucket modulo a ramp-derived
count. Both reshuffle the entire population on every ramp step. Going 10% → 20%
then takes the feature away from roughly 8% of the people who already had it.

It arrives as a support ticket saying *"the new checkout disappeared"* and it is
invisible in your dashboards, because the aggregate count went up by exactly the
amount you expected.

Here, inclusion is `bucket < basisPoints` where the bucket does not depend on the
ramp at all. Monotonicity is a property of the construction, not a thing you
remember to preserve.

### 2. Variant stability under ramp — a user's variant is fixed when they enter

The half people miss. You can get inclusion right and *still* reshuffle variants,
if the control/treatment split is computed over "position within the included
population". Every ramp step renormalises the boundaries and flips users who were
already in.

Here the split uses a **second, independent bucket** over the full space, so it
does not move when the ramp does.

### 3. Cross-flag independence — two 50% experiments must overlap on ~25%

If every flag reuses one bucket per identity, everyone in experiment A is also in
experiment B. The two are perfectly confounded and neither result is
interpretable. This is carryover bias, and it is the most expensive bug in this
repository, because it costs you the *conclusion* rather than the feature.

Buckets here are domain-separated by an explicit per-flag salt, and
`IntegrityAudit.independence` measures the joint rate against `p × p`.

### 4. Identity stability — signing in must not move anybody

`bucketingID` and `authenticatedID` are separate fields, and only the first
reaches the hash. The reflex — bucket on `userID ?? deviceID` — re-hashes a user
the moment they log in and silently walks them across the control/treatment
boundary. Because signing in correlates with engagement, the resulting
sample-ratio mismatch does not average out; it tilts the result in the direction
of your most engaged users.

---

## What the audit reports

`IntegrityAudit` ships inside the library and runs against 10,000 synthetic
identities. Measured values from this build:

| Check | Result |
|---|---|
| Ramp monotonicity | 0 identities lost across 14 ramp steps (0% → 100%) |
| Variant stability | 0 variant changes between a 10% and a 100% ramp |
| Cross-flag independence | joint rate **0.2455** vs expected **0.2500** |
| Bucket uniformity | χ² = **4.54**, df 9, 0.1% critical value 27.88 |
| Identity stability | 0 variants moved on sign-in, across 10,000 identities |

The audit is not decoration. `testMonotonicityCheckActuallyDetectsAViolation`
builds a deliberately broken, ramp-sensitive bucketer and asserts that the check
*fails* against it — a property test that cannot fail is worse than no test,
because it reads like coverage.

---

## Architecture

Evaluation is a **pure synchronous function**. Everything that varies — the
ruleset, the clock, the pin, the overrides — is a parameter.

```
                    ┌───────────────────────────────────────┐
   ruleset ────────▶│                                       │
   context ────────▶│   FlagEvaluator.evaluate(…)           │──▶ FlagDecision
   now     ────────▶│   pure · synchronous · no I/O         │    (variant + reason
   overrides ──────▶│                                       │     + buckets + version)
   pinned  ────────▶└───────────────────────────────────────┘
                                    ▲
                                    │ owns the mutable state
                    ┌───────────────┴───────────────────────┐
                    │  RolloutClient (actor)                │
                    │   · atomic ruleset swap, seq-ordered  │
                    │   · sticky pins (bounded LRU)         │
                    │   · exposures (deduped, bounded)      │
                    └───────────────────────────────────────┘
```

That split is the whole reason a 10,000-identity property test is cheap enough to
run on every commit.

**Precedence, highest first:**

1. Local override (developer/QA) — *never* produces an exposure
2. Stale-ruleset fail-safe
3. Sticky pin
4. Targeting rules (first match wins)
5. Rollout bucket
6. Fail-safe variant

| File | Responsibility |
|---|---|
| `Bucketer.swift` | FNV-1a/64 + SplitMix64 finaliser, domain-separated |
| `FlagEvaluator.swift` | The pure decision function and its precedence chain |
| `Ruleset.swift` | Immutable, validated, sequence-versioned snapshot |
| `RolloutClient.swift` | Actor: ruleset lifecycle, pins, exposures |
| `StickyAssignmentStore.swift` | Bounded LRU pin store with an eviction counter |
| `ExposureRecorder.swift` | Deduped, bounded exposure buffer with a drop counter |
| `IntegrityAudit.swift` | The five checks above, as runnable code |
| `SampleCatalog.swift` | A realistic bundled-fallback ruleset |

---

## Decisions worth defending in review

**A stale kill switch outranks a sticky pin.** A kill switch that a pin can
outvote is not a kill switch. The cost is real — a user can be un-pinned by a
network outage — which is exactly why the `.experiment` staleness class has *no
ceiling at all*. Experiments never take this path, so an assignment is never
yanked because the device went through a tunnel.

**Staleness is per-flag, not global.** A kill switch and an experiment want
opposite behaviour under the same network failure. `.killSwitch` fails closed
after 5 minutes; `.operational` after an hour; `.experiment` never.

**A bundled fallback ruleset is required, not optional.** "No ruleset yet" is the
state that makes a flag neither on nor off at first launch, after which every call
site invents its own default and cold-start behaviour ends up defined by whichever
engineer typed `?? false` last. Requiring a compiled-in fallback makes that state
unrepresentable.

**Overrides are served but never exposed.** A QA device forcing treatment is not a
user who was assigned treatment. Counting it is direct, silent contamination.

**Rollout is basis points, not a percentage.** Percent-as-`Int` cannot express a
0.5% canary; percent-as-`Double` makes the inclusion comparison floating-point,
which is a terrible property for something that must be bit-for-bit reproducible
across app versions.

**`internal-always-on` is `.overrideRollout(100%)`, not `.forceVariant`.**
Forcing a variant for internal builds pushes the whole company into treatment and
destroys the dogfooding signal. Overriding the *ramp* keeps them bucketed.

**The drop counter is reported, never swallowed.** A telemetry buffer that
discards silently under backpressure produces an analysis that is quietly wrong
and looks completely fine: the counts are plausible, just low, and low in
proportion to how busy the device was — which correlates with engagement.

### Rejected alternatives

| Considered | Why not |
|---|---|
| `Hasher` / `hashValue` for bucketing | Swift seeds its hasher per process. Every cold launch re-randomises every experiment — and no single-process test can catch it. |
| CRC32 or raw FNV-1a with no finaliser | Weak avalanche in the low bits, which is exactly what `% bucketCount` consumes. Sequential install ids produce visibly lumpy deciles. |
| Server-side assignment | Correct, and unusable offline or before the first response. Client-side determinism is what makes the flag answerable at launch. |
| Renormalising the variant split over the included population | Simpler-looking and breaks property 2 on every ramp step. |
| One shared bucket per identity across all flags | One hash instead of two, and it destroys cross-flag independence. |
| Storing pins in an unbounded dictionary | Fine until an experimentation platform starts minting per-cohort flag keys, then a slow leak that only reproduces for heavy users. |
| Percent as `Double` throughout | Floating-point comparison on the decision path; no exact reproducibility. |
| `precondition` on malformed rulesets | A flag client must never be the reason an app crashes. Everything clamps, validates, or fails safe. |

---

## Verification — exactly what was checked

- `swift build` — clean, **0 warnings**, Swift 6 language mode (tools-version 6.0).
- `swift test` — **102 tests, 251 assertion sites, 0 failures**, on Swift 6.0.3
  (aarch64 Linux).
- **0 force-unwraps and 0 `try!`** in `Sources/` (only a doc comment mentions the
  latter). Every collection access is bounds-checked; every numeric conversion
  that can trap (`Int(Double)`, `%` by zero) is guarded or clamped.
- The bucketing golden vector was produced by an **independent Python
  reimplementation** of FNV-1a/64 + SplitMix64, not by printing what the Swift
  code returned. `testGoldenVectorIsFrozen` fails if the hash ever drifts —
  because that change would re-randomise every live experiment.
- `RolloutIntegrityUI` is compiled out on Linux by `#if canImport(SwiftUI)`, so
  the Linux job does not type-check it. The macOS CI job in
  `.github/workflows/ci.yml` exists specifically to close that gap.

---

## Usage

```swift
import RolloutIntegrity

let client = RolloutClient(
    bundledFallback: SampleCatalog.bundledFallback()  // compiled in; never undefined
)

// Apply a ruleset fetched from your config service. Older sequences are rejected.
await client.apply(freshRuleset)

let context = EvaluationContext(
    identity: AssignmentIdentity(bucketingID: installID, authenticatedID: userID),
    attributes: ["app_version": .version(SemanticVersion(major: 3, minor: 4))]
)

let decision = await client.decision(for: FlagKey("checkout.express_pay"), context: context)

decision.variant          // "treatment"
decision.reason           // in rollout
decision.auditLine        // checkout.express_pay = treatment [in rollout] @ v42(a1b2), bucket 3380
decision.producesExposure // false for overrides and unknown flags
```

Run the audit yourself:

```swift
let audit = IntegrityAudit()
let report = audit.run(
    population: IntegrityAudit.syntheticPopulation(size: 10_000),
    flagA: SampleCatalog.expressPay(),
    flagB: SampleCatalog.searchRanking(),
    ruleset: ruleset,
    now: Date())

report.passed            // true
report.failedCheckNames  // []
```

### Install

```swift
.package(url: "https://github.com/rajatslakhina/rollout-integrity-kit.git", branch: "main")
```

Requires Swift 6.0+ / iOS 17+ / macOS 14+.

---

## Demo app

_Added after the companion repo is pushed — see below._

---

## Repository layout

This repository contains **only the library** — no app target, no executable
product. The runnable demo lives in its own repository and consumes this package
by its published git URL, exactly the way any external client would.

MIT licensed.
