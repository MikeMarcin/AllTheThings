@testable import ATTCore
import Foundation
import Testing

@Suite("File index deferred optimization benchmark", .serialized)
struct FileIndexDeferredOptimizationBenchmarkTests {
    @Test("opt-in real-root deferred optimization path-set comparison")
    func optInRealRootDeferredOptimizationPathSetComparison() async throws {
        guard let rootValue = ProcessInfo.processInfo.environment["ATT_DEFERRED_OPTIMIZATION_PATHSET_ROOTS"],
              !rootValue.isEmpty
        else {
            return
        }

        let roots = Self.readableDirectoryRoots(from: rootValue)
        guard !roots.isEmpty else {
            Issue.record("ATT_DEFERRED_OPTIMIZATION_PATHSET_ROOTS did not contain readable absolute directories")
            return
        }

        let deferred = try await Self.indexedPathSet(
            roots: roots,
            threshold: ProcessInfo.processInfo.environment["ATT_DEFERRED_OPTIMIZATION_THRESHOLD"]
                .flatMap(Int.init) ?? 1
        )
        let synchronous = try await Self.indexedPathSet(
            roots: roots,
            threshold: ProcessInfo.processInfo.environment["ATT_SYNCHRONOUS_OPTIMIZATION_THRESHOLD"]
                .flatMap(Int.init) ?? Int.max
        )
        let onlyDeferred = deferred.subtracting(synchronous).sorted()
        let onlySynchronous = synchronous.subtracting(deferred).sorted()

        print("{\"operation\":\"deferredOptimizationPathSetComparison\",\"roots\":\(Self.jsonArray(roots.map(\.path))),\"deferred_count\":\(deferred.count),\"synchronous_count\":\(synchronous.count),\"only_deferred_count\":\(onlyDeferred.count),\"only_synchronous_count\":\(onlySynchronous.count)}")

        #expect(onlyDeferred.isEmpty)
        #expect(onlySynchronous.isEmpty)
    }

    private static func indexedPathSet(roots: [URL], threshold: Int) async throws -> Set<String> {
        let applicationName = "AllTheThingsDeferredPathSet-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try? FileManager.default.removeItem(at: supportDirectory)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.setDeferredOptimizationRecordThresholdForTesting(threshold)
        index.replaceRootsAndRebuild(roots, mode: .fresh)
        try await waitUntil(timeoutSeconds: 600) {
            !index.currentStats().isIndexing
        }

        let count = index.currentStats().indexedCount
        let response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .path, ascending: true),
            includeHidden: true
        ), maxResults: max(count + 100, 1_000))
        return Set(response.results.map(\.record.path))
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
}
