import Foundation

/// Every piece of DIRECT state lives on this one actor, the Swift counterpart of the
/// single-threaded dispatcher on Android. Platform callbacks hop onto it with `Task { @DirectActor in }`.
@globalActor
public actor DirectActor {
    public static let shared = DirectActor()
}

func sleepMs(_ ms: Int64) async {
    guard ms > 0 else { return }
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
}

public func wallClockMs() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

/// A one-shot value that several callers can await. Completing twice is ignored.
@DirectActor
final class Waiter<T> {
    private var value: T?
    private var done = false
    private var continuations: [CheckedContinuation<T, Never>] = []

    var isCompleted: Bool { done }

    func complete(_ result: T) {
        guard !done else { return }
        done = true
        value = result
        let waiting = continuations
        continuations = []
        waiting.forEach { $0.resume(returning: result) }
    }

    func wait() async -> T {
        if done, let value { return value }
        return await withCheckedContinuation { continuations.append($0) }
    }

    /// Waits up to `timeoutMs`; on timeout the waiter completes with `fallback` for everyone.
    func wait(timeoutMs: Int64, fallback: T) async -> T {
        if done, let value { return value }
        Task { @DirectActor [weak self] in
            await sleepMs(timeoutMs)
            self?.complete(fallback)
        }
        return await wait()
    }
}

/// Conflated wake-up: any number of `fire()` calls before the next `wait` count as one.
@DirectActor
final class WakeSignal {
    private var pending = false
    private var waiter: Waiter<Void>?

    func fire() {
        if let waiter {
            self.waiter = nil
            waiter.complete(())
        } else {
            pending = true
        }
    }

    func wait(timeoutMs: Int64) async {
        if pending {
            pending = false
            return
        }
        let next = Waiter<Void>()
        waiter = next
        await next.wait(timeoutMs: timeoutMs, fallback: ())
        if waiter === next { waiter = nil }
    }
}
