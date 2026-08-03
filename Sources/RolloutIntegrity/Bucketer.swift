import Foundation

/// Maps an identifier into a bucket in `0..<bucketCount`.
///
/// Requirements a conforming type must meet, all of which are checked by
/// `IntegrityAudit` and by the test suite:
///
/// 1. **Deterministic across processes and app versions.** This rules out
///    `Hasher`/`hashValue`: Swift seeds its hasher per process, so the same user
///    lands in a different bucket after every cold launch. That is not a subtle
///    bug — it re-randomises your entire experiment on every app start, and it
///    does it *without failing any test that runs in a single process*.
/// 2. **Domain-separated.** `bucket(domain:salt:identifier:)` must not be
///    expressible as a hash of a naive concatenation, or `("ab", "c")` and
///    `("a", "bc")` collide.
/// 3. **Well-distributed in the low bits**, because the bucket is taken modulo
///    `bucketCount`.
public protocol Bucketer: Sendable {
    var bucketCount: Int { get }
    func bucket(domain: String, salt: String, identifier: String) -> Int
}

/// Domains used to derive *independent* buckets for the same identifier.
public enum BucketDomain {
    /// "Is this user in the rollout at all?"
    public static let inclusion = "inclusion"
    /// "Given that they are in, which variant?" — must be independent of `inclusion`.
    public static let variantSplit = "split"
}

/// FNV-1a/64 with a SplitMix64 finalisation mix.
///
/// FNV-1a alone is a poor choice here: its avalanche in the low bits is weak for
/// short inputs, and the low bits are exactly what `% bucketCount` consumes, so
/// raw FNV-1a produces visibly lumpy deciles for sequential ids like
/// `user-1 … user-N`. The SplitMix64 finaliser fixes the avalanche; the
/// combination is a few nanoseconds and is verified by
/// `IntegrityAudit.uniformity`.
///
/// Modulo bias is present and is deliberately accepted: `2^64 mod 10_000 = 1616`,
/// so 1,616 of the 10,000 buckets are over-represented by a factor of
/// `1 + 2^-64`. That is roughly 1 part in 10^19 and is many orders of magnitude
/// below the sampling noise of any experiment this will ever gate.
public struct FNV1aBucketer: Bucketer {
    public let bucketCount: Int

    public init(bucketCount: Int = 10_000) {
        // Clamped rather than precondition-checked: a zero bucket count would
        // make the modulo trap, and trapping is never an acceptable outcome for
        // a flag client on a user's device.
        self.bucketCount = Swift.max(bucketCount, 1)
    }

    public func bucket(domain: String, salt: String, identifier: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3

        func absorb(_ bytes: String.UTF8View) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }
        // 0x1F is the ASCII unit separator. Absorbing it between fields is what
        // makes this domain-separated rather than a hash of a concatenation.
        func separator() {
            hash ^= 0x1F
            hash = hash &* prime
        }

        absorb(domain.utf8)
        separator()
        absorb(salt.utf8)
        separator()
        absorb(identifier.utf8)

        var mixed = hash
        mixed ^= mixed >> 30
        mixed = mixed &* 0xbf58_476d_1ce4_e5b9
        mixed ^= mixed >> 27
        mixed = mixed &* 0x94d0_49bb_1331_11eb
        mixed ^= mixed >> 31

        // `mixed % UInt64(bucketCount)` is strictly less than `bucketCount`,
        // which is an `Int`, so this conversion cannot trap.
        return Int(mixed % UInt64(bucketCount))
    }
}
