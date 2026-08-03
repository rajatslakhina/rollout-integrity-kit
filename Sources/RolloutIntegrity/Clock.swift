import Foundation

public protocol RolloutClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: RolloutClock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock the tests can move.
///
/// `@unchecked Sendable` is justified here and only here: `instant` is private,
/// every read and every write goes through `lock`, and there is no other mutable
/// state on the type. The alternative — an `actor` — would force `await` into the
/// evaluator's signature and destroy the "evaluation is a pure synchronous
/// function" property that the rest of this package depends on.
public final class ManualClock: RolloutClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.instant = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.addingTimeInterval(interval)
    }

    public func set(_ newValue: Date) {
        lock.lock()
        defer { lock.unlock() }
        instant = newValue
    }
}
