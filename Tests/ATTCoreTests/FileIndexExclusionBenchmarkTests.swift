@testable import ATTCore
import Foundation
import Testing

@Suite("File index exclusion benchmark", .serialized)
struct FileIndexExclusionBenchmarkTests {
    @Test("opt-in real-root FileIndex exclusion benchmark")
    func optInRealRootFileIndexExclusionBenchmark() async throws {
        guard let rootValue = ProcessInfo.processInfo.environment["ATT_FILE_INDEX_BENCH_ROOTS"],
              !rootValue.isEmpty
        else {
            return
        }

        let roots = Self.readableDirectoryRoots(from: rootValue)
        guard !roots.isEmpty else {
            Issue.record("ATT_FILE_INDEX_BENCH_ROOTS did not contain readable absolute directories")
            return
        }

        let repeatCount = Self.positiveEnvironmentInt(named: "ATT_FILE_INDEX_BENCH_REPEAT") ?? 1
        for repeatIndex in 0..<repeatCount {
            for mode in ExclusionEvaluationMode.allCases {
                try await Self.measureFullRebuild(roots: roots, mode: mode, repeatIndex: repeatIndex)
                try await Self.measureDirectoryUpdate(roots: roots, mode: mode, repeatIndex: repeatIndex)
            }
        }
    }

    @Test("opt-in real-root FileIndex frontier batch benchmark")
    func optInRealRootFileIndexFrontierBatchBenchmark() async throws {
        guard let rootValue = ProcessInfo.processInfo.environment["ATT_FILE_INDEX_FRONTIER_BENCH_ROOTS"],
              !rootValue.isEmpty
        else {
            return
        }

        let roots = Self.readableDirectoryRoots(from: rootValue)
        guard !roots.isEmpty else {
            Issue.record("ATT_FILE_INDEX_FRONTIER_BENCH_ROOTS did not contain readable absolute directories")
            return
        }

        let repeatCount = Self.positiveEnvironmentInt(named: "ATT_FILE_INDEX_FRONTIER_BENCH_REPEAT") ?? 1
        let batchSizes = Self.positiveEnvironmentIntList(
            named: "ATT_FILE_INDEX_FRONTIER_BENCH_BATCH_SIZES",
            defaultValue: [1, 2, 4, 8, 16]
        )
        for repeatIndex in 0..<repeatCount {
            for mode in ScanFrontierMode.allCases {
                for batchSize in Self.effectiveBatchSizes(for: mode, requestedBatchSizes: batchSizes) {
                    try await Self.measureFrontierFullRebuild(
                        roots: roots,
                        frontierMode: mode,
                        batchSize: batchSize,
                        repeatIndex: repeatIndex
                    )
                    try await Self.measureFrontierDirectoryUpdate(
                        roots: roots,
                        frontierMode: mode,
                        batchSize: batchSize,
                        repeatIndex: repeatIndex
                    )
                }
            }
        }
    }

    private static func measureFullRebuild(
        roots: [URL],
        mode: ExclusionEvaluationMode,
        repeatIndex: Int
    ) async throws {
        let applicationName = "AllTheThingsFileIndexBench-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try? FileManager.default.removeItem(at: supportDirectory)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.setExclusionEvaluationModeForTesting(mode)

        let start = Date()
        index.replaceRootsAndRebuild(roots, mode: .fresh)
        try await waitUntil(timeout: .seconds(600)) {
            !index.currentStats().isIndexing
        }

        emitResult(
            operation: "fullRebuild",
            mode: mode,
            roots: roots,
            repeatIndex: repeatIndex,
            elapsed: Date().timeIntervalSince(start),
            index: index
        )
    }

    private static func measureDirectoryUpdate(
        roots: [URL],
        mode: ExclusionEvaluationMode,
        repeatIndex: Int
    ) async throws {
        let applicationName = "AllTheThingsFileIndexBench-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try? FileManager.default.removeItem(at: supportDirectory)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.setExclusionEvaluationModeForTesting(mode)
        index.replaceRootsAndRebuild(roots, mode: .fresh)
        try await waitUntil(timeout: .seconds(600)) {
            !index.currentStats().isIndexing
        }

        let before = index.currentDiagnostics()
        let start = Date()
        index.update(paths: [roots[0].path])
        try await waitUntil(timeout: .seconds(600)) {
            let stats = index.currentStats()
            let diagnostics = index.currentDiagnostics()
            return !stats.isIndexing
                && (
                    diagnostics.completedRefreshBatches > before.completedRefreshBatches
                        || stats.status == "No file changes"
                )
        }

        emitResult(
            operation: "directoryUpdate",
            mode: mode,
            roots: roots,
            repeatIndex: repeatIndex,
            elapsed: Date().timeIntervalSince(start),
            index: index
        )
    }

    private static func measureFrontierFullRebuild(
        roots: [URL],
        frontierMode: ScanFrontierMode,
        batchSize: Int,
        repeatIndex: Int
    ) async throws {
        let applicationName = "AllTheThingsFrontierBench-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try? FileManager.default.removeItem(at: supportDirectory)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.setExclusionEvaluationModeForTesting(.compiledQuery)
        index.setScanFrontierBatchingForTesting(mode: frontierMode, batchSize: batchSize)

        let start = Date()
        index.replaceRootsAndRebuild(roots, mode: .fresh)
        try await waitUntil(timeout: .seconds(600)) {
            !index.currentStats().isIndexing
        }

        emitFrontierResult(
            operation: "fullRebuild",
            frontierMode: frontierMode,
            batchSize: batchSize,
            roots: roots,
            repeatIndex: repeatIndex,
            elapsed: Date().timeIntervalSince(start),
            index: index
        )
    }

    private static func measureFrontierDirectoryUpdate(
        roots: [URL],
        frontierMode: ScanFrontierMode,
        batchSize: Int,
        repeatIndex: Int
    ) async throws {
        let applicationName = "AllTheThingsFrontierBench-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try? FileManager.default.removeItem(at: supportDirectory)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.setExclusionEvaluationModeForTesting(.compiledQuery)
        index.setScanFrontierBatchingForTesting(mode: frontierMode, batchSize: batchSize)
        index.replaceRootsAndRebuild(roots, mode: .fresh)
        try await waitUntil(timeout: .seconds(600)) {
            !index.currentStats().isIndexing
        }

        let before = index.currentDiagnostics()
        let start = Date()
        index.update(paths: [roots[0].path])
        try await waitUntil(timeout: .seconds(600)) {
            let stats = index.currentStats()
            let diagnostics = index.currentDiagnostics()
            return !stats.isIndexing
                && (
                    diagnostics.completedRefreshBatches > before.completedRefreshBatches
                        || stats.status == "No file changes"
                )
        }

        emitFrontierResult(
            operation: "directoryUpdate",
            frontierMode: frontierMode,
            batchSize: batchSize,
            roots: roots,
            repeatIndex: repeatIndex,
            elapsed: Date().timeIntervalSince(start),
            index: index
        )
    }

    private static func emitResult(
        operation: String,
        mode: ExclusionEvaluationMode,
        roots: [URL],
        repeatIndex: Int,
        elapsed: TimeInterval,
        index: FileIndex
    ) {
        let stats = index.currentStats()
        let diagnostics = index.currentDiagnostics()
        let result = BenchmarkResult(
            operation: operation,
            mode: mode.rawValue,
            roots: roots.map(\.path),
            repeatIndex: repeatIndex,
            elapsedMs: Int((elapsed * 1_000).rounded()),
            indexedCount: stats.indexedCount,
            completedRebuilds: diagnostics.completedSnapshotRebuilds,
            completedRefreshBatches: diagnostics.completedRefreshBatches,
            recordsPerSecond: elapsed > 0 ? Double(stats.indexedCount) / elapsed : 0
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }

    private static func emitFrontierResult(
        operation: String,
        frontierMode: ScanFrontierMode,
        batchSize: Int,
        roots: [URL],
        repeatIndex: Int,
        elapsed: TimeInterval,
        index: FileIndex
    ) {
        let stats = index.currentStats()
        let diagnostics = index.currentDiagnostics()
        let metrics = diagnostics.scanFrontierMetrics
        let result = FrontierBenchmarkResult(
            operation: operation,
            frontierMode: frontierMode.rawValue,
            batchSize: batchSize,
            roots: roots.map(\.path),
            repeatIndex: repeatIndex,
            elapsedMs: Int((elapsed * 1_000).rounded()),
            indexedCount: stats.indexedCount,
            completedRebuilds: diagnostics.completedSnapshotRebuilds,
            completedRefreshBatches: diagnostics.completedRefreshBatches,
            recordsPerSecond: elapsed > 0 ? Double(stats.indexedCount) / elapsed : 0,
            enqueueCallCount: metrics.enqueueCallCount,
            enqueuedDirectoryCount: metrics.enqueuedDirectoryCount,
            claimCallCount: metrics.claimCallCount,
            claimedDirectoryCount: metrics.claimedDirectoryCount,
            finishCallCount: metrics.finishCallCount,
            finishedDirectoryCount: metrics.finishedDirectoryCount,
            maxPendingDirectoryCount: metrics.maxPendingDirectoryCount,
            maxActiveDirectoryCount: metrics.maxActiveDirectoryCount,
            appendCallCount: metrics.appendCallCount,
            appendedRecordCount: metrics.appendedRecordCount
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }

    private static func readableDirectoryRoots(from value: String) -> [URL] {
        let fileManager = FileManager.default
        return value.split(separator: ":", omittingEmptySubsequences: true).compactMap { rawPath in
            let path = String(rawPath)
            guard path.hasPrefix("/") else { return nil }

            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.isReadableFile(atPath: url.path)
            else {
                return nil
            }
            return url
        }
    }

    private static func positiveEnvironmentInt(named name: String) -> Int? {
        guard let value = ProcessInfo.processInfo.environment[name],
              let parsed = Int(value),
              parsed > 0
        else {
            return nil
        }
        return parsed
    }

    private static func positiveEnvironmentIntList(named name: String, defaultValue: [Int]) -> [Int] {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return defaultValue
        }

        let parsed = value
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
        let unique = Array(Set(parsed)).sorted()
        return unique.isEmpty ? defaultValue : unique
    }

    private static func effectiveBatchSizes(
        for mode: ScanFrontierMode,
        requestedBatchSizes: [Int]
    ) -> [Int] {
        mode.usesBatchedClaim ? requestedBatchSizes : [1]
    }

    private static func supportDirectory(applicationName: String) -> URL {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return supportRoot.appendingPathComponent(applicationName, isDirectory: true)
    }

    private static func waitUntil(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(100),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        Issue.record("Timed out waiting for FileIndex benchmark condition")
        throw BenchmarkTimeoutError()
    }

    private struct BenchmarkTimeoutError: Error {}

    private struct BenchmarkResult: Encodable {
        let operation: String
        let mode: String
        let roots: [String]
        let repeatIndex: Int
        let elapsedMs: Int
        let indexedCount: Int
        let completedRebuilds: UInt64
        let completedRefreshBatches: UInt64
        let recordsPerSecond: Double

        enum CodingKeys: String, CodingKey {
            case operation
            case mode
            case roots
            case repeatIndex = "repeat_index"
            case elapsedMs = "elapsed_ms"
            case indexedCount = "indexed_count"
            case completedRebuilds = "completed_rebuilds"
            case completedRefreshBatches = "completed_refresh_batches"
            case recordsPerSecond = "records_per_second"
        }
    }

    private struct FrontierBenchmarkResult: Encodable {
        let operation: String
        let frontierMode: String
        let batchSize: Int
        let roots: [String]
        let repeatIndex: Int
        let elapsedMs: Int
        let indexedCount: Int
        let completedRebuilds: UInt64
        let completedRefreshBatches: UInt64
        let recordsPerSecond: Double
        let enqueueCallCount: UInt64
        let enqueuedDirectoryCount: UInt64
        let claimCallCount: UInt64
        let claimedDirectoryCount: UInt64
        let finishCallCount: UInt64
        let finishedDirectoryCount: UInt64
        let maxPendingDirectoryCount: Int
        let maxActiveDirectoryCount: Int
        let appendCallCount: UInt64
        let appendedRecordCount: UInt64

        enum CodingKeys: String, CodingKey {
            case operation
            case frontierMode = "frontier_mode"
            case batchSize = "batch_size"
            case roots
            case repeatIndex = "repeat_index"
            case elapsedMs = "elapsed_ms"
            case indexedCount = "indexed_count"
            case completedRebuilds = "completed_rebuilds"
            case completedRefreshBatches = "completed_refresh_batches"
            case recordsPerSecond = "records_per_second"
            case enqueueCallCount = "enqueue_call_count"
            case enqueuedDirectoryCount = "enqueued_directory_count"
            case claimCallCount = "claim_call_count"
            case claimedDirectoryCount = "claimed_directory_count"
            case finishCallCount = "finish_call_count"
            case finishedDirectoryCount = "finished_directory_count"
            case maxPendingDirectoryCount = "max_pending_directory_count"
            case maxActiveDirectoryCount = "max_active_directory_count"
            case appendCallCount = "append_call_count"
            case appendedRecordCount = "appended_record_count"
        }
    }
}
