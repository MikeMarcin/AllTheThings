@testable import ATTCore
import Foundation
import Testing

@Suite("Real-root phase timing", .serialized)
struct RealRootPhaseTimingTests {
    @Test("opt-in real-root phase timing")
    func optInRealRootPhaseTiming() async throws {
        guard let rootValue = ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_ROOTS"],
              !rootValue.isEmpty
        else {
            return
        }

        let roots = rootValue
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        guard !roots.isEmpty else {
            Issue.record("ATT_PHASE_BENCH_ROOTS did not contain readable absolute directories")
            return
        }

        let repeatCount = max(1, Int(ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_REPEAT"] ?? "") ?? 1)
        for repeatIndex in 0..<repeatCount {
            try await Self.measure(operation: "fullRebuild", roots: roots, repeatIndex: repeatIndex) { index in
                Self.applyDeferredOptimizationThresholdOverride(to: index)
                index.replaceRootsAndRebuild(roots, mode: .fresh)
            }
            try await Self.measure(operation: "fullReconcile", roots: roots, repeatIndex: repeatIndex) { index in
                Self.applyDeferredOptimizationThresholdOverride(to: index)
                index.replaceRootsAndRebuild(roots, mode: .fresh)
                try await Self.waitUntil(timeoutSeconds: 600) {
                    !index.currentStats().isIndexing
                }
                _ = index.reconcileIndexedRootsInBackground(rootURLs: roots)
            }
        }
    }

    private static func measure(
        operation: String,
        roots: [URL],
        repeatIndex: Int,
        start: (FileIndex) async throws -> Void
    ) async throws {
        let applicationName = "AllTheThingsPhaseBench-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try? FileManager.default.removeItem(at: supportDirectory)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        var events: [(elapsed: TimeInterval, phase: IndexPhase, status: String, indexed: Int, discovered: Int)] = []
        let lock = NSLock()
        let started = Date()
        index.onStatsChanged = { @MainActor @Sendable stats in
            lock.lock()
            events.append((
                elapsed: Date().timeIntervalSince(started),
                phase: stats.phase,
                status: stats.status,
                indexed: stats.indexedCount,
                discovered: stats.discoveredCount
            ))
            lock.unlock()
        }

        try await start(index)
        try await waitUntil(timeoutSeconds: 600) {
            !index.currentStats().isIndexing
        }
        let elapsed = Date().timeIntervalSince(started)
        let captured = lock.withLock { events }
        let stats = index.currentStats()
        print("{\"operation\":\"\(operation)\",\"roots\":\(Self.jsonArray(roots.map(\.path))),\"repeat_index\":\(repeatIndex),\"elapsed_ms\":\(Int((elapsed * 1000).rounded())),\"indexed_count\":\(stats.indexedCount),\"phase_events\":\(Self.jsonEvents(captured))}")
    }

    private static func applyDeferredOptimizationThresholdOverride(to index: FileIndex) {
        guard let value = ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_DEFERRED_OPTIMIZATION_THRESHOLD"],
              let threshold = Int(value)
        else {
            return
        }
        index.setDeferredOptimizationRecordThresholdForTesting(threshold)
    }

    private static func waitUntil(
        timeoutSeconds: UInt64,
        pollNanoseconds: UInt64 = 25_000_000,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        Issue.record("Timed out waiting for condition")
    }

    private static func supportDirectory(applicationName: String) -> URL {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return supportRoot.appendingPathComponent(applicationName, isDirectory: true)
    }

    private static func jsonArray(_ values: [String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func jsonEvents(_ events: [(elapsed: TimeInterval, phase: IndexPhase, status: String, indexed: Int, discovered: Int)]) -> String {
        let values = events.map {
            [
                "elapsed_ms": Int(($0.elapsed * 1000).rounded()),
                "phase": $0.phase.rawValue,
                "status": $0.status,
                "indexed_count": $0.indexed,
                "discovered_count": $0.discovered
            ] as [String: Any]
        }
        let data = try? JSONSerialization.data(withJSONObject: values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
