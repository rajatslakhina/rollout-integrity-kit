# RolloutIntegrityKit

[![CI](https://github.com/rajatslakhina/rollout-integrity-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/rollout-integrity-kit/actions/workflows/ci.yml)

**A feature flag looks like a `Bool` and behaves like a distributed system.**

Four properties decide whether your rollout is safe and your experiment results are
trustworthy. Every one of them is silently violated by the obvious implementation.
Nothing crashes. Nothing logs. The feature works. The conclusion is wrong.

This is a client-side flag and experiment-assignment engine built around those four
properties — plus a runnable audit that proves them against a real population instead
of asserting them in a README.

```
swift build   →  clean, 0 warnings, Swift 6 language mode
swift test    →  147 tests, 0 failures  (Linux + macOS CI, both green)
demo app      →  resolves this package from GitHub and builds for an iOS Simulator
```

---

## The four properties, and how each one fails quietly

### 1. Ramp monotonicity — raising the rollout may only ever *add* users

The tempting implementation hashes the ramp into the bucket
(`hash("\(userID)-\(percentage)")`) or takes the bucket modulo a ramp-derived count.
Both reshuffle the population on every ramp step, so 10% → 20% takes the feature
*away* from roughly 8% of the people who already had it.

It arrives as a support ticket saying *"the new checkout disappeared"*, and it is
invisible in your dashboards, because the aggregate count went up by exactly the
amount you expected.

Here, inclusion is `bucket < basisPoints` where the bucket does not depend on the ramp
at all. Monotonicity is a property of the construction, not a thing you remember to
preserve.

There is a second, nastier way to lose this one, and it does not live in the hash. If
the client **pins a user who was excluded**, that pin outranks the rollout check on
every later evaluation and raising the ramp can never admit them again. The pure
evaluator stays monotonic; the shipped client does not; and the property test covering
the evaluator stays green the entire time. So only *assignments* pin here — see
`DecisionReason.producesPin`.

### 2. Variant stability under ramp — a user's variant is fixed when they enter

The half people miss. You can get inclusion right and *still* reshuffle variants, if
the control/treatment split is computed over "position within the included
population". Every ramp step renormalises the boundaries and flips users already in.

Here the split uses a **second, independent bucket** over the full space, so it does
not move when the ramp does.

### 3. Cross-flag independence — two 50% experiments must overlap on ~25%

If every flag reuses one bucket per identity, everyone in experiment A is also in
experiment B. The two are perfectly confounded and neither result is interpretable.
This is carryover bias, and it is the most expensive bug in this repository, because
it costs you the *conclusion* rather than the feature.

Buckets here are domain-separated by an explicit per-flag salt, and
`IntegrityAudit.independence` measures the joint rate against `p × p`.

### 4. Identity stability — signing in must not move anybody

`bucketingID` and `authenticatedID` are separate fields, and only the first reaches
the hash. The reflex — bucket on `userID ?? deviceID` — re-hashes a user the moment
they log in and silently walks them across the control/treatment boundary. Because
signing in correlates with engagement, the resulting sample-ratio mismatch does not
average out; it tilts the result toward your most engaged users.

---

## What the audit reports

`IntegrityAudit` ships inside the library and runs against 10,000 synthetic
identities. These are its six checks and the values from this build:

| Check | Result |
|---|---|
| Determinism (frozen golden fingerprint) | `4f04c709d65059ae` — matches |
| Ramp monotonicity | 0 identities lost across the 14-step default ladder (0% → 100%) |
| Variant stability | 0 of ~1,000 identities flipped variant between a 10% and a 100% ramp |
| Cross-flag independence | joint rate **0.2455** vs expected **0.2500** |
| Bucket uniformity | χ² = **4.54**, df 9, 0.1% critical value 27.88 |
| Identity stability | 0 variants moved on sign-in, across 10,000 identities |

The audit is not decoration, and it is deliberately built so that each check *can*
fail:

- `testMonotonicityCheckActuallyDetectsAViolation` builds a ramp-sensitive bucketer
  and asserts the check **fails** against it.
- `testDeterminismIsFalsifiableViaTheGoldenFingerprint` runs a different-but-still-
  deterministic bucketer and asserts the check **fails**. This matters because half of
  a determinism check — "call the pure function twice in one process" — holds for
  *any* deterministic implementation, including `Hasher`, the exact bug it exists to
  catch. Only the frozen fingerprint has teeth.
- An untabulated χ² shape sets `isTabulated = false` and the report **fails closed**.
  Returning `.infinity` as the threshold, the obvious "no opinion" value, would make
  every such case pass silently.

---

## Architecture

Evaluation is a **pure synchronous function**. Everything that varies — the ruleset,
the clock, the pin, the overrides — is a parameter.

```
   JSON ──▶ RulesetDecoder ──▶ Ruleset (immutable, validated, sequence-versioned)
                                  │
                                  ▼
                    ┌───────────────────────────────────────┐
   context ────────▶│                                       │
   now     ────────▶│   FlagEvaluator.evaluate(…)           │──▶ FlagDecision
   overrides ──────▶│   pure · synchronous · no I/O         │    (variant + reason
   pinned  ────────▶│                                       │     + buckets + version)
                    └───────────────────────────────────────┘
                                    ▲
                                    │ owns the mutable state
                    ┌───────────────┴───────────────────────┐
                    │  RolloutClient (actor)                │
                    │   · atomic ruleset swap, seq-ordered  │
                    │   · sticky pins (bounded, persisted)  │
                    │   · exposures (deduped, bounded)      │
                    └───────────────────────────────────────┘
```

That split is the whole reason a 10,000-identity property test is cheap enough to run
on every commit.

**Precedence, highest first:**

1. Local override (developer/QA) — *never* produces an exposure or a pin
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
| `WireFormat.swift` | The JSON a config service sends, and its decoder |
| `RolloutClient.swift` | Actor: ruleset lifecycle, pins, exposures |
| `StickyAssignmentStore.swift` | Bounded LRU pin store, in-memory and persisted |
| `ExposureRecorder.swift` | Deduped, bounded exposure buffer with a drop counter |
| `IntegrityAudit.swift` | The six checks above, as runnable code |
| `SafeArithmetic.swift` | Saturating helpers for every operator that can trap |
| `SampleCatalog.swift` | A realistic bundled-fallback ruleset |

---

## Decisions worth defending in review

**Only assignments pin; exclusions never do.** Pinning an exclusion converts the
headline monotonicity guarantee into a lie at the client layer, invisibly. This is the
single highest-value line in the package and it is four cases in an enum.

**A stale kill switch outranks a sticky pin.** A kill switch that a pin can outvote is
not a kill switch. The cost is real — a user can be un-pinned by a network outage —
which is exactly why the `.experiment` staleness class has *no ceiling at all*.
Experiments never take this path, so an assignment is never yanked because the device
went through a tunnel.

**Staleness is per-flag, not global.** A kill switch and an experiment want opposite
behaviour under the same network failure. `.killSwitch` fails closed after 5 minutes;
`.operational` after an hour; `.experiment` never.

**Pins are scoped to `(flag, bucketingID)`, and the store owns check-then-act.**
Keying on the flag alone serves identity A's variant to identity B the first time the
process evaluates a second user. And `pinned(for:)` + `pin(_:)` is a check-then-act
pair straddling an `await`, so two concurrent first reads can both see "no pin" and
the second can overwrite the first — after the first already returned a variant and
recorded an exposure for it. `pinIfAbsent` returns the authoritative winner and the
client **adopts** it.

**A bundled fallback ruleset is required, not optional.** "No ruleset yet" is the
state that makes a flag neither on nor off at first launch, after which every call site
invents its own default and cold-start behaviour ends up defined by whichever engineer
typed `?? false` last. Requiring a compiled-in fallback makes that state
unrepresentable.

**Overrides are served but never exposed and never pinned.** A QA device forcing
treatment is not a user who was assigned treatment. Counting it is direct, silent
contamination.

**The fail-safe value is not a treatment arm.** `variants` is the set of arms an
included user can be served; `failSafeVariant` is what everyone else gets. Forcing the
fail-safe *into* the arm set is what makes a boolean flag impossible to express
honestly — you declare `["on", "off"]`, and the variant split then hands `off` to half
of the *included* population, so a "100% rollout" silently ships the feature to 50% of
users. Keeping them separate lets `variants: ["on"]` mean exactly what it looks like,
and it is why `payments.express_checkout` in the sample catalog is a one-arm flag.

**Rollout is basis points, not a percentage.** Percent-as-`Int` cannot express a 0.5%
canary; percent-as-`Double` makes the inclusion comparison floating-point, which is a
terrible property for something that must be bit-for-bit reproducible across app
versions.

**Decoding clamps numbers and throws on names.** A rollout of 99,999 basis points is a
typo; shipping 100% beats taking the ruleset down and stranding the client on a stale
one. An *unrecognised predicate or effect* is different: this client is older than the
ruleset, and silently dropping the rule would apply a targeting policy nobody wrote —
which is how a hold-out segment quietly ends up inside an experiment.

**The drop counter is reported, never swallowed.** A telemetry buffer that discards
silently under backpressure produces an analysis that is quietly wrong and looks
completely fine: the counts are plausible, just low, and low in proportion to how busy
the device was — which correlates with engagement.

**Every decision carries its buckets, including the ones that never consulted them.**
The first question about any flag is "why is this off for me?", and a decision that
omits the bucket precisely when something unusual happened is missing the field you
needed.

### Rejected alternatives

| Considered | Why not |
|---|---|
| Requiring the fail-safe to be one of `variants` | Makes a boolean flag inexpressible; a 100% rollout of `["on","off"]` ships to half the included users. |
| `Hasher` / `hashValue` for bucketing | Swift seeds its hasher per process. Every cold launch re-randomises every experiment — and no single-process test can catch it. |
| CRC32 or raw FNV-1a with no finaliser | Weak avalanche in the low bits, which is exactly what `% bucketCount` consumes. Sequential install ids produce visibly lumpy deciles. |
| Server-side assignment | Correct, and unusable offline or before the first response. Client-side determinism is what makes the flag answerable at launch. |
| Renormalising the variant split over the included population | Simpler-looking, and breaks property 2 on every ramp step. |
| One shared bucket per identity across all flags | One hash instead of two, and it destroys cross-flag independence. |
| Pinning on every exposure-producing decision | Looks symmetric, silently breaks property 1. See above. |
| `Codable` directly on the domain types | A synthesised `init(from:)` is a second, unvalidated constructor for `Ruleset`. The wire types are separate so the domain type stays unconstructible without validation. |
| Percent as `Double` throughout | Floating-point comparison on the decision path; no exact reproducibility. |
| `precondition` on malformed rulesets | A flag client must never be the reason an app crashes. Everything clamps, validates, or fails safe. |
| Unbounded pin and dedup stores | Fine until a platform starts minting per-cohort flag keys; then a slow leak that only reproduces for heavy users. |

### Explicit non-goals

- **No networking.** `RulesetDecoder` takes `Data`; fetching, retry and conditional-GET
  policy belong to the app's existing network stack, not to a flag client.
- **No analytics transport.** `ExposureRecorder.drain()` hands you a batch; shipping it
  is your pipeline's job.
- **No remote config UI or authoring tooling.** This is the client half only.

---

## Verification — exactly what was checked

- `swift build -Xswiftc -warnings-as-errors` — clean, from a deleted `.build`, in
  Swift 6 language mode. The flag is the point: "zero warnings" asserted in prose is
  a claim nobody can fail, so the Linux CI job runs the build *with warnings promoted
  to errors*. If a warning appears, the badge goes red.
- `swift test` — **147 tests, 0 failures**, on Swift 6.0.3 (aarch64 Linux).
- **CI runs on GitHub's own runners** — the badge above reflects the current head,
  and [the full history is here](https://github.com/rajatslakhina/rollout-integrity-kit/actions):
  - `ubuntu-latest` / `swift:6.0` container — `swift build -Xswiftc
    -warnings-as-errors` + `swift test`.
  - `macos-15` — `xcodebuild build -scheme RolloutIntegrityUI -destination
    'platform=iOS Simulator,name=iPhone 16'` plus `swift test`. That job exists
    because `RolloutIntegrityUI` is compiled out on Linux by `#if canImport(SwiftUI)`;
    it is the only thing that type-checks the SwiftUI layer, and it does so **against
    the iOS SDK** rather than macOS, because iOS-only API drift is exactly what a
    macOS-only build would miss.
- **The demo app builds for an iOS Simulator, verified independently.** The companion
  repository's [CI](https://github.com/rajatslakhina/rollout-integrity-kit-demo-app/actions)
  resolves this package by its GitHub URL (`xcodebuild -resolvePackageDependencies`)
  and then compiles the app target for an iOS Simulator. So the split-repo dependency
  is not a claim: a machine that had never seen either repository resolved it and
  built against it.
- **0 force-unwraps and 0 `try!`** in `Sources/`. Every collection access is
  bounds-checked; every numeric operation that can trap (`Int(Double)`, `%` by zero,
  `+`/`*` overflow, and `Int.min / -1`) is guarded, clamped or saturating, and
  `SafeArithmeticTests` exercises each one — including the `Int.min / -1` division
  and the `Int`-range ceiling, which is derived from `Int.max` rather than hardcoded
  so it stays correct on a 32-bit `Int`.
- The bucketing golden vector and the audit's frozen fingerprint were produced by an
  **independent Python reimplementation** of FNV-1a/64 + SplitMix64, not by printing
  what the Swift code returns. `testGoldenVectorIsFrozen` fails if the hash ever
  drifts — because that change would re-randomise every live experiment.
- **Not done:** the demo app has never been *launched* on a Simulator, and there are no
  screenshots in either repository. It compiles and links for iOS; nobody has watched
  it run. Its README says so plainly rather than implying otherwise.

## Usage

```swift
import RolloutIntegrity

let client = RolloutClient(
    bundledFallback: SampleCatalog.bundledFallback(),        // compiled in; never undefined
    stickyStore: PersistentStickyAssignmentStore(storage: UserDefaultsStickyStorage())
)

// Apply a ruleset fetched from your config service. Older sequences are rejected.
let ruleset = try RulesetDecoder().decode(responseData, fetchedAt: Date())
await client.apply(ruleset)

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
let report = IntegrityAudit().run(
    population: IntegrityAudit.syntheticPopulation(size: 10_000),
    flagA: SampleCatalog.expressPay(),
    flagB: SampleCatalog.searchRanking(),
    ruleset: ruleset,
    now: Date())

report.passed            // true
report.failedCheckNames  // []
```

---

## Run it yourself

```bash
git clone https://github.com/rajatslakhina/rollout-integrity-kit.git
cd rollout-integrity-kit
swift build
swift test
```

Requires Swift 6.0+. The core module is platform-agnostic (it builds and tests on
Linux); `RolloutIntegrityUI` needs an Apple platform — iOS 17+ / macOS 14+. tvOS and
watchOS are deliberately *not* declared, because no CI job builds them.

### Install

Released versions are tagged; the current one is
[v1.0.0](https://github.com/rajatslakhina/rollout-integrity-kit/releases/tag/v1.0.0).

```swift
.package(url: "https://github.com/rajatslakhina/rollout-integrity-kit.git", from: "1.0.0")
```

---

## Demo app

**[rollout-integrity-kit-demo-app](https://github.com/rajatslakhina/rollout-integrity-kit-demo-app)**
— a SwiftUI app that consumes this package by its GitHub URL
(`XCRemoteSwiftPackageReference` pinned to `v1.0.0`), not by a local path. Drag the ramp
slider and watch nobody get kicked out; toggle "Signed in" and watch every bucket stay
put; run the 10,000-identity audit live.

Its CI resolves this package from GitHub and builds the app for an iOS Simulator, and
is green. Stated plainly: it has still never been *launched* on a Simulator and ships
with no screenshots. See its README for the full verification status.

---

## Repository layout

This repository contains **only the library** — no app target, no executable product.
The runnable demo lives in its own repository and consumes this package by its
published git URL, exactly the way any external client would.

MIT licensed.
