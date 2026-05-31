@testable import AllTheThings
import ATTCore
import Foundation
import Testing

@Suite("Diagnostics report builder")
struct DiagnosticsReportBuilderTests {
    @Test("diagnostics report redacts root paths by default")
    func diagnosticsReportRedactsRootPathsByDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let rootPath = "/Users/example/Documents/SecretProject"
        AppSettings.saveIndexedRoots([URL(fileURLWithPath: rootPath, isDirectory: true)], defaults: defaults)

        let report = DiagnosticsReportBuilder.build(
            snapshot: makeSnapshot(rootPath: rootPath),
            defaults: defaults,
            includeRootPaths: false
        )

        #expect(report.contains("Root 1"))
        #expect(!report.contains(rootPath))
        #expect(!report.contains("SecretProject"))
        #expect(!report.lowercased().contains("query text:"))
    }

    @Test("diagnostics report can include root paths explicitly")
    func diagnosticsReportCanIncludeRootPathsExplicitly() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let rootPath = "/Users/example/Documents/SecretProject"
        AppSettings.saveIndexedRoots([URL(fileURLWithPath: rootPath, isDirectory: true)], defaults: defaults)

        let report = DiagnosticsReportBuilder.build(
            snapshot: makeSnapshot(rootPath: rootPath),
            defaults: defaults,
            includeRootPaths: true
        )

        #expect(report.contains(rootPath))
    }

    private func makeSnapshot(rootPath: String) -> IndexInsightsSnapshot {
        var usage = IndexUsageMetrics()
        usage.lifetime.firstLaunchDate = Date(timeIntervalSince1970: 1_700_000_000)
        usage.lifetime.launchCount = 3
        usage.allTimeSearches.started = 4
        usage.allTimeSearches.completed = 3
        usage.allTimeSearches.fallbackScans = 1
        usage.allTimeSearches.executionPathCounts[.nameComponentIndex] = 2
        usage.allTimeSearches.indexUseCounts[.nameGrams] = 2
        usage.allTimeSearches.latencyBuckets["10-50ms"] = 3
        usage.dailyBuckets = [
            DailyUsageBucket(
                day: "2026-05-30",
                searches: usage.allTimeSearches,
                fileActions: [.open: 2],
                health: IndexHealthCounters(incrementalRefreshBatches: 1),
                launches: 1,
                memory: MemoryUsageCounters(latestBytes: 42_000_000, dailyMinimumBytes: 40_000_000, dailyMaximumBytes: 45_000_000)
            )
        ]

        let stats = IndexStats(
            indexedCount: 10,
            isIndexing: false,
            phase: .ready,
            snapshotRevision: 2,
            status: "Ready",
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let health = IndexHealthDiagnostics(
            phase: .ready,
            status: "Ready",
            activeIndexJobs: 0,
            activeIndexJobHighWaterMark: 1,
            schemaVersion: 6,
            snapshotRevision: 2,
            recordStoreKind: "mapped",
            mappedByteSize: 1024,
            heapPageCount: 0,
            overlayCount: 0,
            columnarSidecarsLoaded: true,
            resultCount: 10,
            virtualRowCount: 1,
            visibleCount: 9,
            pathGramIndexEnabled: true,
            nameGramKeyCount: 20,
            componentGramKeyCount: 15,
            pathGramKeyCount: 4,
            extensionKeyCount: 3,
            completedRefreshBatches: 1,
            completedSnapshotRebuilds: 1,
            fallbackScanCount: 1,
            scannedRowCount: 10,
            pathMaterializationCount: 2,
            canClearCachedIndex: true
        )

        return IndexInsightsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            stats: stats,
            roots: [
                IndexRootInsight(
                    path: rootPath,
                    trackedFileCount: 7,
                    directoryCount: 3,
                    hiddenCount: 1,
                    indexedContentBytes: 1_024,
                    pathByteWeight: 512,
                    estimatedIndexBytes: 256
                )
            ],
            storage: IndexStorageInsights(
                totalATTDataBytes: 2_048,
                indexPackageBytes: 1_024,
                cacheBytes: 128,
                locations: [
                    IndexStorageLocationInsight(label: "Application Support", path: "/Users/example/Library/Application Support/AllTheThings", allocatedBytes: 1_920)
                ],
                sidecars: [
                    IndexSidecarInsight(name: "records.bin", allocatedBytes: 512)
                ]
            ),
            usage: usage,
            lifetime: usage.lifetime,
            health: health
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AllTheThingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
