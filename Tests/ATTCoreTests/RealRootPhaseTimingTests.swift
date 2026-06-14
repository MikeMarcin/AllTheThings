@preconcurrency import Darwin
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

        let roots = Self.readableDirectoryRoots(from: rootValue)
        guard !roots.isEmpty else {
            Issue.record("ATT_PHASE_BENCH_ROOTS did not contain readable absolute directories")
            return
        }
        let scopedCatchUpRoots = Self.scopedCatchUpRoots(inside: roots)

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
            if !scopedCatchUpRoots.isEmpty {
                try await Self.measureBackgroundCatchUp(
                    roots: roots,
                    scopeRoots: scopedCatchUpRoots,
                    repeatIndex: repeatIndex
                )
            }
        }
    }

    private static func measure(
        operation: String,
        roots: [URL],
        scopeRoots: [URL]? = nil,
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
        let memoryTimeline = MemoryTimelineRecorder(started: started)
        let memoryTask = memoryTimeline.start()
        defer {
            memoryTask.cancel()
        }
        memoryTimeline.mark("beforeStart")
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
            memoryTimeline.mark("stats.\(stats.phase.rawValue)", stats: stats)
        }

        try await start(index)
        memoryTimeline.mark(
            "afterStart",
            stats: index.currentStats(),
            diagnostics: index.currentDiagnostics()
        )
        try await waitUntilReady(index)
        let readyElapsed = Date().timeIntervalSince(started)
        memoryTimeline.mark(
            "ready",
            stats: index.currentStats(),
            diagnostics: index.currentDiagnostics()
        )
        let optimizationTimings = try await optimizationTimingsIfRequested(for: index, started: started)
        if optimizationTimings != nil {
            memoryTimeline.mark(
                "optimizedWaitFinished",
                stats: index.currentStats(),
                diagnostics: index.currentDiagnostics()
            )
        }
        memoryTask.cancel()
        let captured = lock.withLock { events }
        let stats = index.currentStats()
        let diagnostics = index.currentDiagnostics()
        print(Self.jsonLine(
            operation: operation,
            roots: roots,
            scopeRoots: scopeRoots,
            repeatIndex: repeatIndex,
            readyElapsed: readyElapsed,
            optimizationTimings: optimizationTimings,
            stats: stats,
            diagnostics: diagnostics,
            events: captured,
            memorySamples: memoryTimeline.snapshot()
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
        let memoryTimeline = MemoryTimelineRecorder(started: started)
        let memoryTask = memoryTimeline.start()
        defer {
            memoryTask.cancel()
        }
        memoryTimeline.mark(
            "beforeDirectFullReconcile",
            stats: index.currentStats(),
            diagnostics: index.currentDiagnostics()
        )
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
            memoryTimeline.mark("stats.\(stats.phase.rawValue)", stats: stats)
        }

        _ = index.reconcileIndexedRootsInBackground(rootURLs: roots)
        try await waitUntilReady(index)
        let readyElapsed = Date().timeIntervalSince(started)
        memoryTimeline.mark(
            "ready",
            stats: index.currentStats(),
            diagnostics: index.currentDiagnostics()
        )
        let optimizationTimings = try await optimizationTimingsIfRequested(for: index, started: started)
        if optimizationTimings != nil {
            memoryTimeline.mark(
                "optimizedWaitFinished",
                stats: index.currentStats(),
                diagnostics: index.currentDiagnostics()
            )
        }
        memoryTask.cancel()
        let captured = lock.withLock { events }
        let stats = index.currentStats()
        let diagnostics = index.currentDiagnostics()
        print(Self.jsonLine(
            operation: "directFullReconcile",
            roots: roots,
            scopeRoots: roots,
            repeatIndex: repeatIndex,
            readyElapsed: readyElapsed,
            optimizationTimings: optimizationTimings,
            stats: stats,
            diagnostics: diagnostics,
            events: captured,
            memorySamples: memoryTimeline.snapshot()
        ))
    }

    private static func measureBackgroundCatchUp(roots: [URL], scopeRoots: [URL], repeatIndex: Int) async throws {
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
        if waitsForOptimizedCompletion {
            try await waitUntilPathGramCompleteOrInactive(index)
        }

        var events: [(elapsed: TimeInterval, phase: IndexPhase, status: String, indexed: Int, discovered: Int)] = []
        let lock = NSLock()
        let started = Date()
        let memoryTimeline = MemoryTimelineRecorder(started: started)
        let memoryTask = memoryTimeline.start()
        defer {
            memoryTask.cancel()
        }
        memoryTimeline.mark(
            "beforeBackgroundCatchUp",
            stats: index.currentStats(),
            diagnostics: index.currentDiagnostics()
        )
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
            memoryTimeline.mark("stats.\(stats.phase.rawValue)", stats: stats)
        }

        _ = index.reconcileIndexedRootsInBackground(
            rootURLs: scopeRoots,
            activityPresentation: .backgroundCatchUp
        )
        try await waitUntilReady(index)
        let readyElapsed = Date().timeIntervalSince(started)
        memoryTimeline.mark(
            "ready",
            stats: index.currentStats(),
            diagnostics: index.currentDiagnostics()
        )
        let optimizationTimings = try await optimizationTimingsIfRequested(for: index, started: started)
        if optimizationTimings != nil {
            memoryTimeline.mark(
                "optimizedWaitFinished",
                stats: index.currentStats(),
                diagnostics: index.currentDiagnostics()
            )
        }
        memoryTask.cancel()
        let captured = lock.withLock { events }
        let stats = index.currentStats()
        let diagnostics = index.currentDiagnostics()
        print(Self.jsonLine(
            operation: "backgroundCatchUpScopedReconcile",
            roots: roots,
            scopeRoots: scopeRoots,
            repeatIndex: repeatIndex,
            readyElapsed: readyElapsed,
            optimizationTimings: optimizationTimings,
            stats: stats,
            diagnostics: diagnostics,
            events: captured,
            memorySamples: memoryTimeline.snapshot()
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

    private struct ProcessMemorySample {
        let physicalFootprintBytes: UInt64
        let residentBytes: UInt64
        let virtualBytes: UInt64
    }

    private struct TimelineMemorySample {
        let elapsed: TimeInterval
        let label: String
        let physicalFootprintBytes: UInt64
        let residentBytes: UInt64
        let virtualBytes: UInt64
        let phase: IndexPhase?
        let status: String?
        let indexedCount: Int?
        let discoveredCount: Int?
        let optimizedCount: Int?
        let recordStoreKind: RecordStoreKind?
        let mappedByteSize: Int?
        let heapPageCount: Int?
        let overlayCount: Int?
    }

    private final class MemoryTimelineRecorder: @unchecked Sendable {
        private let started: Date
        private let pollNanoseconds: UInt64
        private let lock = NSLock()
        private var samples: [TimelineMemorySample] = []

        init(started: Date) {
            self.started = started
            let pollMilliseconds = max(
                25,
                Int(ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_MEMORY_SAMPLE_MS"] ?? "") ?? 250
            )
            self.pollNanoseconds = UInt64(pollMilliseconds) * 1_000_000
        }

        func start() -> Task<Void, Never> {
            Task.detached { [pollNanoseconds] in
                while !Task.isCancelled {
                    self.mark("poll")
                    try? await Task.sleep(nanoseconds: pollNanoseconds)
                }
            }
        }

        func mark(
            _ label: String,
            stats: IndexStats? = nil,
            diagnostics: FileIndexDiagnostics? = nil
        ) {
            guard let memory = Self.currentMemory() else { return }
            let sample = TimelineMemorySample(
                elapsed: Date().timeIntervalSince(started),
                label: label,
                physicalFootprintBytes: memory.physicalFootprintBytes,
                residentBytes: memory.residentBytes,
                virtualBytes: memory.virtualBytes,
                phase: stats?.phase ?? diagnostics?.phase,
                status: stats?.status,
                indexedCount: stats?.indexedCount ?? diagnostics?.indexedCount,
                discoveredCount: stats?.discoveredCount ?? diagnostics?.discoveredCount,
                optimizedCount: stats?.optimizedCount ?? diagnostics?.optimizedCount,
                recordStoreKind: diagnostics?.recordStoreKind,
                mappedByteSize: diagnostics?.mappedByteSize,
                heapPageCount: diagnostics?.heapPageCount,
                overlayCount: diagnostics?.overlayCount
            )
            lock.withLock {
                samples.append(sample)
            }
        }

        func snapshot() -> [TimelineMemorySample] {
            lock.withLock { samples }
        }

        private static func currentMemory() -> ProcessMemorySample? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }

            guard result == KERN_SUCCESS else { return nil }
            return ProcessMemorySample(
                physicalFootprintBytes: UInt64(info.phys_footprint),
                residentBytes: UInt64(info.resident_size),
                virtualBytes: UInt64(info.virtual_size)
            )
        }
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

    private static func readableDirectoryRoots(from value: String) -> [URL] {
        value
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
    }

    private static func scopedCatchUpRoots(inside roots: [URL]) -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_SCOPED_ROOTS"],
           !configured.isEmpty {
            return readableDirectoryRoots(from: configured)
        }

        let limit = max(
            1,
            Int(ProcessInfo.processInfo.environment["ATT_PHASE_BENCH_SCOPED_ROOT_LIMIT"] ?? "") ?? 1
        )
        var scopedRoots: [URL] = []
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children.sorted(by: { $0.path < $1.path }) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    continue
                }
                scopedRoots.append(child.standardizedFileURL)
                if scopedRoots.count >= limit {
                    return scopedRoots
                }
            }
        }
        return scopedRoots
    }

    private static func jsonLine(
        operation: String,
        roots: [URL],
        scopeRoots: [URL]? = nil,
        repeatIndex: Int,
        readyElapsed: TimeInterval,
        optimizationTimings: OptimizationTimings?,
        stats: IndexStats,
        diagnostics: FileIndexDiagnostics,
        events: [(elapsed: TimeInterval, phase: IndexPhase, status: String, indexed: Int, discovered: Int)],
        memorySamples: [TimelineMemorySample]
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
            "phase_events": phaseEventValues(events),
            "memory_samples": memorySampleValues(memorySamples),
            "memory_report": memoryReport(operation: operation, samples: memorySamples)
        ]
        if let scopeRoots {
            payload["scope_roots"] = scopeRoots.map(\.path)
        }
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

    private static func memorySampleValues(_ samples: [TimelineMemorySample]) -> [[String: Any]] {
        samples.map { sample in
            var value: [String: Any] = [
                "elapsed_ms": Int((sample.elapsed * 1000).rounded()),
                "label": sample.label,
                "physical_footprint_bytes": jsonInt(sample.physicalFootprintBytes),
                "resident_bytes": jsonInt(sample.residentBytes),
                "virtual_bytes": jsonInt(sample.virtualBytes)
            ]
            if let phase = sample.phase {
                value["phase"] = phase.rawValue
            }
            if let status = sample.status {
                value["status"] = status
            }
            if let indexedCount = sample.indexedCount {
                value["indexed_count"] = indexedCount
            }
            if let discoveredCount = sample.discoveredCount {
                value["discovered_count"] = discoveredCount
            }
            if let optimizedCount = sample.optimizedCount {
                value["optimized_count"] = optimizedCount
            }
            if let recordStoreKind = sample.recordStoreKind {
                value["record_store_kind"] = recordStoreKind.rawValue
            }
            if let mappedByteSize = sample.mappedByteSize {
                value["mapped_byte_size"] = mappedByteSize
            }
            if let heapPageCount = sample.heapPageCount {
                value["heap_page_count"] = heapPageCount
            }
            if let overlayCount = sample.overlayCount {
                value["overlay_count"] = overlayCount
            }
            return value
        }
    }

    private static func memoryReport(operation: String, samples: [TimelineMemorySample]) -> [String: Any] {
        guard let peak = samples.max(by: { $0.physicalFootprintBytes < $1.physicalFootprintBytes }) else {
            return [
                "sample_count": 0,
                "summary": "No memory samples were captured."
            ]
        }
        let first = samples.first ?? peak
        let last = samples.last ?? peak
        let peakMinusStart = peak.physicalFootprintBytes > first.physicalFootprintBytes
            ? peak.physicalFootprintBytes - first.physicalFootprintBytes
            : 0
        let peakMinusFinal = peak.physicalFootprintBytes > last.physicalFootprintBytes
            ? peak.physicalFootprintBytes - last.physicalFootprintBytes
            : 0
        let classification = peakMinusFinal >= 512 * 1024 * 1024 && peak.physicalFootprintBytes > last.physicalFootprintBytes * 2
            ? "transient_spike"
            : "retained_or_plateau"
        let attribution: String
        if operation == "backgroundCatchUpScopedReconcile" {
            attribution = "Compare peak_label with IndexMemory OS log events; peaks near previousRecords or merge events indicate whole-index materialization during scoped catch-up."
        } else if operation.contains("Reconcile") {
            attribution = "Compare with scoped catch-up output; full-root reconcile should avoid previous snapshot materialization."
        } else {
            attribution = "Use as baseline for scan, mapped-store write, search-structure build, and allocator retention."
        }
        return [
            "sample_count": samples.count,
            "classification": classification,
            "peak_label": peak.label,
            "peak_elapsed_ms": Int((peak.elapsed * 1000).rounded()),
            "peak_physical_footprint_bytes": jsonInt(peak.physicalFootprintBytes),
            "peak_resident_bytes": jsonInt(peak.residentBytes),
            "final_physical_footprint_bytes": jsonInt(last.physicalFootprintBytes),
            "peak_minus_start_bytes": jsonInt(peakMinusStart),
            "peak_minus_final_bytes": jsonInt(peakMinusFinal),
            "summary": "Peak \(byteString(peak.physicalFootprintBytes)) at \(peak.label); final \(byteString(last.physicalFootprintBytes)); \(classification).",
            "attribution_hint": attribution
        ]
    }

    private static func jsonInt(_ value: UInt64) -> Int64 {
        Int64(min(value, UInt64(Int64.max)))
    }

    private static func byteString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: jsonInt(bytes))
    }
}
