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
            try await Self.measureDirectFullReconcile(roots: roots, repeatIndex: repeatIndex)
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
        try await waitUntilReady(index)
        let readyElapsed = Date().timeIntervalSince(started)
        let optimizationTimings = try await optimizationTimingsIfRequested(for: index, started: started)
        let captured = lock.withLock { events }
        let stats = index.currentStats()
        let diagnostics = index.currentDiagnostics()
        print(Self.jsonLine(
            operation: operation,
            roots: roots,
            repeatIndex: repeatIndex,
            readyElapsed: readyElapsed,
            optimizationTimings: optimizationTimings,
            stats: stats,
            diagnostics: diagnostics,
            events: captured
        ))
    }

    private static func measureDirectFullReconcile(roots: [URL], repeatIndex: Int) async throws {
        let applicationName = "AllTheThingsPhaseBench-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try? FileManager.default.removeItem(at: supportDirectory)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        Self.applyDeferredOptimizationThresholdOverride(to: index)
        index.replaceRootsAndRebuild(roots, mode: .fresh)
        try await waitUntilReady(index)
        try await waitUntilCoreOptimized(index)
        try await waitUntilPathGramCompleteOrInactive(index)

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

        _ = index.reconcileIndexedRootsInBackground(rootURLs: roots)
        try await waitUntilReady(index)
        let readyElapsed = Date().timeIntervalSince(started)
        let optimizationTimings = try await optimizationTimingsIfRequested(for: index, started: started)
        let captured = lock.withLock { events }
        let stats = index.currentStats()
        let diagnostics = index.currentDiagnostics()
        print(Self.jsonLine(
            operation: "directFullReconcile",
            roots: roots,
            repeatIndex: repeatIndex,
            readyElapsed: readyElapsed,
            optimizationTimings: optimizationTimings,
            stats: stats,
            diagnostics: diagnostics,
            events: captured
        ))
    }

    private static func applyDeferredOptimizationThresholdOverride(to index: FileIndex) {
        guard let value = ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_DEFERRED_OPTIMIZATION_THRESHOLD"],
              let threshold = Int(value)
        else {
            return
        }
        index.setDeferredOptimizationRecordThresholdForTesting(threshold)
    }

    private static var waitsForOptimizedCompletion: Bool {
        ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_WAIT_FOR_OPTIMIZED"] == "1"
    }

    private static func waitUntilReady(_ index: FileIndex) async throws {
        try await waitUntil(timeoutSeconds: 600) {
            !index.currentStats().isIndexing
        }
    }

    private struct OptimizationTimings {
        var coreOptimizedElapsed: TimeInterval?
        var pathGramFirstShardElapsed: TimeInterval?
        var pathGramCompleteElapsed: TimeInterval?
    }

    private static func waitUntilCoreOptimized(_ index: FileIndex) async throws {
        try await waitUntil(timeoutSeconds: 600) {
            let stats = index.currentStats()
            let diagnostics = index.currentDiagnostics()
            return !stats.isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }
    }

    private static func waitUntilPathGramFirstShardOrInactive(_ index: FileIndex) async throws {
        try await waitUntil(timeoutSeconds: 600) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.pathGramIndexEnabled
                || diagnostics.pathGramCoveredRowCount > 0
                || (diagnostics.activeIndexJobs == 0 && diagnostics.pathGramTotalRowCount == 0)
        }
    }

    private static func waitUntilPathGramCompleteOrInactive(_ index: FileIndex) async throws {
        try await waitUntil(timeoutSeconds: 600) {
            let diagnostics = index.currentDiagnostics()
            guard diagnostics.pathGramTotalRowCount > 0 else {
                return diagnostics.activeIndexJobs == 0
            }
            return diagnostics.pathGramIndexEnabled
                && diagnostics.pathGramCoveredRowCount == diagnostics.pathGramTotalRowCount
                && diagnostics.activeIndexJobs == 0
        }
    }

    private static func optimizationTimingsIfRequested(for index: FileIndex, started: Date) async throws -> OptimizationTimings? {
        guard waitsForOptimizedCompletion else {
            return nil
        }
        try await waitUntilCoreOptimized(index)
        let coreElapsed = Date().timeIntervalSince(started)
        try await Task.sleep(nanoseconds: 25_000_000)
        try await waitUntilPathGramFirstShardOrInactive(index)
        let firstShardElapsed = index.currentDiagnostics().pathGramCoveredRowCount > 0
            ? Date().timeIntervalSince(started)
            : nil
        try await waitUntilPathGramCompleteOrInactive(index)
        let completeElapsed = index.currentDiagnostics().pathGramIndexEnabled
            ? Date().timeIntervalSince(started)
            : nil
        return OptimizationTimings(
            coreOptimizedElapsed: coreElapsed,
            pathGramFirstShardElapsed: firstShardElapsed,
            pathGramCompleteElapsed: completeElapsed
        )
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

    private static func jsonLine(
        operation: String,
        roots: [URL],
        repeatIndex: Int,
        readyElapsed: TimeInterval,
        optimizationTimings: OptimizationTimings?,
        stats: IndexStats,
        diagnostics: FileIndexDiagnostics,
        events: [(elapsed: TimeInterval, phase: IndexPhase, status: String, indexed: Int, discovered: Int)]
    ) -> String {
        var payload: [String: Any] = [
            "operation": operation,
            "roots": roots.map(\.path),
            "repeat_index": repeatIndex,
            "elapsed_ms": Int((readyElapsed * 1000).rounded()),
            "ready_elapsed_ms": Int((readyElapsed * 1000).rounded()),
            "indexed_count": stats.indexedCount,
            "searchable_count": stats.searchableCount,
            "optimized_count": diagnostics.optimizedCount,
            "record_store_kind": diagnostics.recordStoreKind.rawValue,
            "active_index_jobs": diagnostics.activeIndexJobs,
            "path_gram_index_enabled": diagnostics.pathGramIndexEnabled,
            "path_gram_posting_count": diagnostics.pathGramPostingCount,
            "path_gram_covered_row_count": diagnostics.pathGramCoveredRowCount,
            "path_gram_total_row_count": diagnostics.pathGramTotalRowCount,
            "name_gram_posting_count": diagnostics.nameGramPostingCount,
            "component_gram_posting_count": diagnostics.componentGramPostingCount,
            "phase_events": phaseEventValues(events)
        ]
        if let coreOptimizedElapsed = optimizationTimings?.coreOptimizedElapsed {
            payload["optimized_elapsed_ms"] = Int((coreOptimizedElapsed * 1000).rounded())
            payload["core_optimized_elapsed_ms"] = Int((coreOptimizedElapsed * 1000).rounded())
        } else {
            payload["optimized_elapsed_ms"] = NSNull()
            payload["core_optimized_elapsed_ms"] = NSNull()
        }
        if let pathGramFirstShardElapsed = optimizationTimings?.pathGramFirstShardElapsed {
            payload["path_gram_first_shard_elapsed_ms"] = Int((pathGramFirstShardElapsed * 1000).rounded())
        } else {
            payload["path_gram_first_shard_elapsed_ms"] = NSNull()
        }
        if let pathGramCompleteElapsed = optimizationTimings?.pathGramCompleteElapsed {
            payload["path_gram_complete_elapsed_ms"] = Int((pathGramCompleteElapsed * 1000).rounded())
        } else {
            payload["path_gram_complete_elapsed_ms"] = NSNull()
        }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func phaseEventValues(_ events: [(elapsed: TimeInterval, phase: IndexPhase, status: String, indexed: Int, discovered: Int)]) -> [[String: Any]] {
        events.map {
            [
                "elapsed_ms": Int(($0.elapsed * 1000).rounded()),
                "phase": $0.phase.rawValue,
                "status": $0.status,
                "indexed_count": $0.indexed,
                "discovered_count": $0.discovered
            ] as [String: Any]
        }
    }
}
