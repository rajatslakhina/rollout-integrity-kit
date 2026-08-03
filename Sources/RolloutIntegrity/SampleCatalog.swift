import Foundation

/// A realistic, compiled-in ruleset used by the demo app, the audit and the
/// tests.
///
/// It doubles as the **bundled fallback** an app would ship in its binary so that
/// no flag is ever undefined at first launch, before the first network response.
public enum SampleCatalog {
    public enum Keys {
        public static let expressPay = FlagKey("checkout.express_pay")
        public static let searchRanking = FlagKey("search.ranking_v2")
        public static let expressCheckout = FlagKey("payments.express_checkout")
        public static let feedPageSize = FlagKey("feed.page_size")
        public static let newProfile = FlagKey("profile.redesign")
    }

    public static let internalBuildAttribute = "is_internal_build"
    public static let appVersionAttribute = "app_version"
    public static let localeAttribute = "locale"

    public static func expressPay(rollout: BasisPoints = BasisPoints(percent: 50)) -> FlagDefinition {
        FlagDefinition(
            key: Keys.expressPay,
            variants: [Variant(name: "control", weight: 50), Variant(name: "treatment", weight: 50)],
            failSafeVariant: "control",
            rollout: rollout,
            bucketingSalt: "express-pay-2026-q3",
            targetingRules: [
                TargetingRule(
                    id: "internal-always-in",
                    conditions: [AttributeCondition(attribute: internalBuildAttribute, predicate: .equals(.boolean(true)))],
                    // Not `.forceVariant`: internal builds stay on the bucketed
                    // path at 100% so the internal population still splits
                    // control/treatment and dogfooding produces real signal.
                    effect: .overrideRollout(.max))
            ],
            stalenessClass: .experiment,
            pinPolicy: .pinOnFirstExposure)
    }

    public static func searchRanking(rollout: BasisPoints = BasisPoints(percent: 50)) -> FlagDefinition {
        FlagDefinition(
            key: Keys.searchRanking,
            variants: [Variant(name: "control", weight: 50), Variant(name: "treatment", weight: 50)],
            failSafeVariant: "control",
            rollout: rollout,
            // A different salt is the *only* reason this experiment is
            // independent of `express_pay`. Reusing one salt across flags is the
            // carryover-bias bug `IntegrityAudit.independence` exists to catch.
            bucketingSalt: "search-ranking-2026-q3",
            stalenessClass: .experiment,
            pinPolicy: .pinOnFirstExposure)
    }

    /// A feature guarded by a kill switch.
    ///
    /// Note the shape: **one** treatment arm (`on`) and a held-out value (`off`).
    /// Declaring `["on", "off"]` as two arms would be wrong — the variant split
    /// would then hand `off` to half of the *included* population, so a "100%
    /// rollout" would silently ship the feature to 50% of users.
    ///
    /// The staleness ceiling is what makes this a kill switch rather than a toggle:
    /// if the client cannot confirm the ruleset is fresh within five minutes, it
    /// must assume the switch may have fired since, and serves the held-out value.
    /// The feature turns **off** when we lose confidence — that is failing closed.
    public static func expressCheckout() -> FlagDefinition {
        FlagDefinition(
            key: Keys.expressCheckout,
            variants: [Variant(name: "on", weight: 1)],
            failSafeVariant: "off",
            rollout: .max,
            bucketingSalt: "payments-express-checkout",
            stalenessClass: .killSwitch,
            pinPolicy: .never)
    }

    public static func feedPageSize() -> FlagDefinition {
        FlagDefinition(
            key: Keys.feedPageSize,
            variants: [
                Variant(name: "small-10", weight: 20),
                Variant(name: "medium-25", weight: 60),
                Variant(name: "large-50", weight: 20)
            ],
            failSafeVariant: "medium-25",
            rollout: .max,
            bucketingSalt: "feed-page-size-v3",
            stalenessClass: .operational,
            pinPolicy: .pinOnFirstExposure)
    }

    public static func newProfile() -> FlagDefinition {
        FlagDefinition(
            key: Keys.newProfile,
            variants: [Variant(name: "on", weight: 1)],
            failSafeVariant: "off",
            rollout: BasisPoints(percent: 25),
            bucketingSalt: "profile-redesign-2026",
            targetingRules: [
                TargetingRule(
                    id: "requires-3-2",
                    conditions: [AttributeCondition(
                        attribute: appVersionAttribute,
                        predicate: .versionBelow(SemanticVersion(major: 3, minor: 2)))],
                    effect: .exclude),
                TargetingRule(
                    id: "internal-forced-on",
                    conditions: [AttributeCondition(attribute: internalBuildAttribute, predicate: .equals(.boolean(true)))],
                    effect: .forceVariant("on"))
            ],
            stalenessClass: .operational,
            pinPolicy: .pinOnFirstExposure)
    }

    public static func allFlags(expressPayRollout: BasisPoints = BasisPoints(percent: 50)) -> [FlagDefinition] {
        [expressPay(rollout: expressPayRollout), searchRanking(), expressCheckout(), feedPageSize(), newProfile()]
    }

    /// The compiled-in fallback. `try?` is deliberate and safe: the inputs are
    /// literals in this file, so the only way construction can fail is a
    /// programming error introduced in this file, and even then the app must
    /// still launch. `emptyFallback` is a valid, if useless, ruleset.
    public static func bundledFallback(
        at instant: Date = Date(timeIntervalSince1970: 1_700_000_000),
        expressPayRollout: BasisPoints = BasisPoints(percent: 50)
    ) -> Ruleset {
        let version = RulesetVersion(sequence: 1, etag: "bundled")
        if let ruleset = try? Ruleset(version: version, fetchedAt: instant, flags: allFlags(expressPayRollout: expressPayRollout)) {
            return ruleset
        }
        return emptyFallback(at: instant)
    }

    public static func emptyFallback(at instant: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Ruleset {
        Ruleset.empty(at: instant)
    }

    public static func demoContext(
        installID: String = "install-demo-0001",
        signedInAs userID: String? = nil,
        isInternalBuild: Bool = false,
        appVersion: SemanticVersion = SemanticVersion(major: 3, minor: 4, patch: 1),
        locale: String = "en_IN"
    ) -> EvaluationContext {
        let identity = AssignmentIdentity(bucketingID: installID, authenticatedID: userID)
        return EvaluationContext(identity: identity, attributes: [
            internalBuildAttribute: .boolean(isInternalBuild),
            appVersionAttribute: .version(appVersion),
            localeAttribute: .string(locale)
        ])
    }
}
