import Foundation

/// Uses monotonic time so clock changes cannot extend or shorten a search.
final class SearchRefinementBudget: @unchecked Sendable {
    private let deadline: TimeInterval?
    private let lock = NSLock()
    private var timedOut = false

    init(seconds: TimeInterval, startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        deadline = seconds > 0 ? startedAt + seconds : nil
    }

    var didTimeOut: Bool { lock.withLock { timedOut } }

    func shouldStop(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            if let deadline, now >= deadline { timedOut = true }
            return timedOut
        }
    }
}
