@testable import ATTCore
import Foundation
import Testing

@Suite("File index insights")
struct FileIndexInsightsTests {
    @Test("insights attribute records and estimated index bytes to roots")
    func insightsAttributeRecordsAndEstimatedIndexBytesToRoots() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsInsights-\(UUID().uuidString)", isDirectory: true)
        let rootA = root.appendingPathComponent("RootA", isDirectory: true)
        let rootB = root.appendingPathComponent("RootB", isDirectory: true)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try String(repeating: "a", count: 128).write(
            to: rootA.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )
        try String(repeating: "b", count: 256).write(
            to: rootB.appendingPathComponent("beta.txt"),
            atomically: true,
            encoding: .utf8
        )

        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.replaceRootsAndRebuild([rootA, rootB])
        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 4
        }

        let snapshot = index.currentInsightsSnapshot()
        #expect(snapshot.roots.count == 2)
        #expect(snapshot.roots.map(\.path).contains(rootA.standardizedFileURL.path))
        #expect(snapshot.roots.map(\.path).contains(rootB.standardizedFileURL.path))
        #expect(snapshot.roots.allSatisfy { $0.attributionSource == .persistedExact })
        #expect(snapshot.roots.reduce(0) { $0 + $1.trackedFileCount } >= 2)
        #expect(snapshot.roots.reduce(UInt64(0)) { $0 + $1.indexedContentBytes } >= 384)
        #expect(snapshot.storage.indexPackageBytes > 0)
        #expect(snapshot.roots.reduce(UInt64(0)) { $0 + $1.estimatedIndexBytes } > 0)
    }

    @Test("storage insights reports index package creation date when package exists")
    func storageInsightsReportsIndexPackageCreationDateWhenPackageExists() throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        #expect(index.currentInsightsSnapshot().storage.indexPackageCreatedAt == nil)

        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/AllTheThingsInsights/alpha.txt", size: 12)
        ])
        index.persistSnapshotForTesting()

        let snapshot = index.currentInsightsSnapshot()
        let createdAt = try #require(snapshot.storage.indexPackageCreatedAt)
        #expect(snapshot.storage.indexPackageBytes > 0)
        #expect(createdAt <= Date())
    }

    @Test("nested roots attribute descendants to deepest configured root")
    func nestedRootsAttributeDescendantsToDeepestConfiguredRoot() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsNestedRoots-\(UUID().uuidString)", isDirectory: true)
        let childRoot = root.appendingPathComponent("App", isDirectory: true)
        try fileManager.createDirectory(at: childRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try "parent".write(
            to: root.appendingPathComponent("ParentOnly.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "child".write(
            to: childRoot.appendingPathComponent("ChildOnly.txt"),
            atomically: true,
            encoding: .utf8
        )

        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.replaceRootsAndRebuild([root, childRoot])
        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.phase == .ready
        }

        let roots = Dictionary(uniqueKeysWithValues: index.currentInsightsSnapshot().roots.map { ($0.path, $0) })
        let parentInsight = try #require(roots[root.standardizedFileURL.path])
        let childInsight = try #require(roots[childRoot.standardizedFileURL.path])

        #expect(parentInsight.attributionSource == .persistedExact)
        #expect(childInsight.attributionSource == .persistedExact)
        #expect(parentInsight.trackedFileCount == 1)
        #expect(childInsight.trackedFileCount == 1)
        #expect(parentInsight.indexedContentBytes >= 6)
        #expect(childInsight.indexedContentBytes >= 5)
    }

    @Test("root attribution matcher preserves nested roots and persisted schema")
    func rootAttributionMatcherPreservesNestedRootsAndPersistedSchema() throws {
        let root = "/tmp/allthethings-root-attribution"
        let childRoot = "\(root)/App"
        let records = [
            RootAttributionInput(path: "\(root)/ParentOnly.txt", isResultRow: true, isDirectory: false, isHidden: false, sizeBytes: 12),
            RootAttributionInput(path: "\(childRoot)/ChildOnly.txt", isResultRow: true, isDirectory: false, isHidden: false, sizeBytes: 34)
        ]

        let result = try RootAttributionTable.build(roots: [root, childRoot], rowCount: records.count) { index in
            records[index]
        }

        #expect(result.rootIDs == [0, 1])
        #expect(result.table.rootID(forNormalizedPath: "\(root)/ParentOnly.txt") == 0)
        #expect(result.table.rootID(forNormalizedPath: "\(childRoot)/Nested/ChildOnly.txt") == 1)
        #expect(result.table.rootID(forNormalizedPath: "\(root)-sibling/Other.txt") == nil)

        let data = try JSONEncoder().encode(result.table)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schemaVersion\""))
        #expect(json.contains("\"roots\""))
        #expect(!json.contains("matcher"))
        #expect(try JSONDecoder().decode(RootAttributionTable.self, from: data) == result.table)
    }

    @Test("root attribution rejects more roots than fit in UInt16")
    func rootAttributionRejectsMoreRootsThanFitInUInt16() throws {
        let roots = (0...FileIndex.maximumIndexedRootCount).map { "/tmp/allthethings-root-\($0)" }

        do {
            _ = try RootAttributionTable.build(roots: roots, rowCount: 0) { _ in
                RootAttributionInput(path: "/tmp/unused", isResultRow: true, isDirectory: false, isHidden: false, sizeBytes: 0)
            }
            Issue.record("Expected root attribution to reject too many roots")
        } catch RootAttributionError.tooManyRoots(let count) {
            #expect(count == FileIndex.maximumIndexedRootCount + 1)
        } catch {
            Issue.record("Expected tooManyRoots, got \(error)")
        }
    }

    @Test("successful rebuild does not record indexing failures")
    func successfulRebuildDoesNotRecordIndexingFailures() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsInsights-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try "ok".write(
            to: root.appendingPathComponent("alpha.txt"),
            atomically: true,
            encoding: .utf8
        )

        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.replaceRootsAndRebuild([root])
        try await waitUntil {
            !index.currentStats().isIndexing
        }

        #expect(index.currentInsightsSnapshot().usage.health.indexingFailures == 0)
    }

    @Test("search profiles and metrics stay aggregate and phase separated")
    func searchProfilesAndMetricsStayAggregateAndPhaseSeparated() throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        let privatePath = "/tmp/AllTheThingsPrivate/AlphaSecret.swift"
        index.replaceRecordsForTesting([
            makeRecord(path: privatePath, size: 12),
            makeRecord(path: "/tmp/AllTheThingsPrivate/Beta.txt", size: 8)
        ])

        let previewResponse = index.search(SearchRequest(
            query: "AlphaSecret",
            sort: SortSpec(column: .name, ascending: true),
            mode: .interactivePreview
        ))
        let response = index.search(SearchRequest(
            query: "AlphaSecret",
            sort: SortSpec(column: .name, ascending: true)
        ))

        #expect(previewResponse.executionProfile.elapsed >= 0)
        #expect(response.executionProfile.elapsed >= 0)
        #expect(response.executionProfile.executionPath != .unprofiled)

        let usage = index.currentInsightsSnapshot().usage
        #expect(usage.allTimeSearches.started == 2)
        #expect(usage.allTimeSearches.completed == 2)
        #expect(usage.initialSearches.started == 1)
        #expect(usage.initialSearches.completed == 1)
        #expect(usage.refinedSearches.started == 1)
        #expect(usage.refinedSearches.completed == 1)
        #expect(!usage.allTimeSearches.executionPathCounts.isEmpty)
        #expect(!usage.initialSearches.routeCounts.isEmpty)
        #expect(!usage.refinedSearches.routeCounts.isEmpty)

        let data = try JSONEncoder().encode(usage)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("alphasecret"))
        #expect(!json.contains("allthethingsprivate"))
        #expect(!json.contains(privatePath.lowercased()))
    }

    @Test("search metrics classify mapped sidecar and full scan routes")
    func searchMetricsClassifyRoutes() {
        var metrics = IndexUsageMetrics()
        for profile in [
            SearchExecutionProfile(
                executionPath: .indexedCandidateIntersection,
                indexesUsed: [.nameGrams, .visibleBitset],
                elapsed: 1
            ),
            SearchExecutionProfile(
                executionPath: .extensionCandidateIntersection,
                indexesUsed: [.extensionPostings, .visibleBitset],
                elapsed: 2
            ),
            SearchExecutionProfile(
                executionPath: .fullFallbackScan,
                indexesUsed: [.visibleBitset],
                didFallbackToFullScan: true,
                elapsed: 3
            ),
            SearchExecutionProfile(
                executionPath: .applicationCatalog,
                indexesUsed: [.applicationCatalog],
                elapsed: 4
            )
        ] {
            metrics.recordSearchStarted(phase: .refinedResults)
            metrics.recordSearchCompleted(profile, phase: .refinedResults)
        }

        let refined = metrics.refinedSearches
        #expect(refined.completed == 4)
        #expect(refined.routeCounts[.mappedIndex] == 1)
        #expect(refined.routeCounts[.sidecar] == 1)
        #expect(refined.routeCounts[.fullScan] == 1)
        #expect(refined.routeCounts[.applicationCatalog] == 1)
        #expect(refined.averageLatency(for: .mappedIndex) == 1)
        #expect(refined.averageLatency(for: .sidecar) == 2)
        #expect(refined.averageLatency(for: .fullScan) == 3)
        #expect(refined.averageLatency(for: .applicationCatalog) == 4)
    }

    @Test("external searches contribute application route metrics")
    func externalSearchesContributeApplicationRouteMetrics() throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.recordExternalSearchStarted(phase: .refinedResults)
        index.recordExternalSearchCompleted(
            SearchExecutionProfile(
                executionPath: .applicationCatalog,
                indexesUsed: [.applicationCatalog],
                candidateCount: 12,
                scannedRowCount: 12,
                elapsed: 0.25
            ),
            phase: .refinedResults
        )

        let usage = index.currentInsightsSnapshot().usage
        #expect(usage.allTimeSearches.started == 1)
        #expect(usage.allTimeSearches.completed == 1)
        #expect(usage.allTimeSearches.routeCounts[.applicationCatalog] == 1)
        #expect(usage.allTimeSearches.averageLatency(for: .applicationCatalog) == 0.25)
        #expect(usage.refinedSearches.started == 1)
        #expect(usage.refinedSearches.completed == 1)
        #expect(usage.refinedSearches.routeCounts[.applicationCatalog] == 1)
        #expect(usage.refinedSearches.averageLatency(for: .applicationCatalog) == 0.25)
    }

    @Test("cancelled searches stay phase specific without route counts")
    func cancelledSearchesStayPhaseSpecificWithoutRouteCounts() throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/AllTheThingsPrivate/AlphaSecret.swift", size: 12)
        ])

        let preview = index.search(
            SearchRequest(
                query: "AlphaSecret",
                sort: SortSpec(column: .name, ascending: true),
                mode: .interactivePreview
            ),
            shouldCancel: { true }
        )
        let refined = index.search(
            SearchRequest(
                query: "AlphaSecret",
                sort: SortSpec(column: .name, ascending: true)
            ),
            shouldCancel: { true }
        )

        #expect(preview == nil)
        #expect(refined == nil)

        let usage = index.currentInsightsSnapshot().usage
        #expect(usage.initialSearches.started == 1)
        #expect(usage.initialSearches.cancelled == 1)
        #expect(usage.initialSearches.completed == 0)
        #expect(usage.initialSearches.routeCounts.isEmpty)
        #expect(!usage.initialSearches.latencyBuckets.isEmpty)
        #expect(usage.refinedSearches.started == 1)
        #expect(usage.refinedSearches.cancelled == 1)
        #expect(usage.refinedSearches.completed == 0)
        #expect(usage.refinedSearches.routeCounts.isEmpty)
        #expect(!usage.refinedSearches.latencyBuckets.isEmpty)
        #expect(usage.allTimeSearches.started == 2)
        #expect(usage.allTimeSearches.cancelled == 2)
    }

    @Test("average latency uses all measured searches")
    func averageLatencyUsesAllMeasuredSearches() {
        var counters = SearchUsageCounters(
            completed: 2,
            cancelled: 1,
            totalLatency: 9
        )

        #expect(counters.averageLatency == 3)

        counters.completed = 0
        counters.cancelled = 1
        counters.totalLatency = 4
        #expect(counters.averageLatency == 4)

        counters.cancelled = 0
        counters.totalLatency = 4
        #expect(counters.averageLatency == 0)

        counters.routeCounts[.mappedIndex] = 2
        #expect(!counters.hasAverageLatency(for: .mappedIndex))
        counters.routeLatencyTotals[.mappedIndex] = 7
        #expect(counters.hasAverageLatency(for: .mappedIndex))
        #expect(counters.averageLatency(for: .mappedIndex) == 3.5)
        #expect(!counters.hasAverageLatency(for: .applicationCatalog))
        #expect(counters.averageLatency(for: .applicationCatalog) == 0)
    }

    @Test("legacy v1 metrics migrate without backfilling phase counters")
    func legacyV1MetricsMigrateWithoutBackfillingPhaseCounters() throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationName, isDirectory: true)
        try? fileManager.removeItem(at: supportDirectory)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: supportDirectory)
        }

        let metricsURL = supportDirectory.appendingPathComponent("index-metrics.json", isDirectory: false)
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "allTimeSearches": {
            "started": 7,
            "completed": 5,
            "cancelled": 2,
            "fallbackScans": 1
          },
          "dailyBuckets": [
            {
              "day": "2026-06-14",
              "searches": {
                "started": 7,
                "completed": 5,
                "cancelled": 2
              }
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: metricsURL)

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        let usage = index.currentInsightsSnapshot().usage
        #expect(usage.schemaVersion == IndexUsageMetrics.currentSchemaVersion)
        #expect(usage.allTimeSearches.started == 7)
        #expect(usage.allTimeSearches.completed == 5)
        #expect(usage.allTimeSearches.cancelled == 2)
        #expect(usage.initialSearches.started == 0)
        #expect(usage.refinedSearches.started == 0)
        #expect(usage.dailyBuckets.first?.searches.completed == 5)
        #expect(usage.dailyBuckets.first?.initialSearches.completed == 0)
        #expect(usage.dailyBuckets.first?.refinedSearches.completed == 0)
    }

    @Test("first launch date is write once and clear keeps metrics sidecars")
    func firstLaunchDateIsWriteOnceAndClearKeepsMetricsSidecars() async throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.recordAppLaunch(appVersion: "1.0")
        let firstLaunch = try #require(index.currentInsightsSnapshot().lifetime.firstLaunchDate)
        try await Task.sleep(for: .milliseconds(10))
        index.recordAppLaunch(appVersion: "1.1")

        let cursorURL = index.dataDirectoryURL.appendingPathComponent("fsevents-cursors.json", isDirectory: false)
        try Data("{}".utf8).write(to: cursorURL)
        index.replaceRecordsForTesting([makeRecord(path: "/tmp/AllTheThingsPrivate/Alpha.swift", size: 12)])
        index.persistSnapshotForTesting()
        try await waitUntil {
            index.currentDiagnostics().activeIndexJobs == 0
        }

        try index.clearPersistedIndexData()

        let snapshot = index.currentInsightsSnapshot()
        #expect(snapshot.lifetime.firstLaunchDate == firstLaunch)
        #expect(snapshot.lifetime.launchCount == 2)
        #expect(snapshot.stats.indexedCount == 0)
        #expect(fileManager.fileExists(atPath: cursorURL.path))
        #expect(fileManager.fileExists(atPath: index.dataDirectoryURL.appendingPathComponent("index-metrics.json").path))
    }

    private func makeRecord(path: String, size: UInt64) -> FileRecord {
        FileRecord(
            id: FileRecord.stableID(for: path),
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            directoryPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            fileExtension: URL(fileURLWithPath: path).pathExtension.lowercased(),
            sizeBytes: size,
            modifiedTime: Date().timeIntervalSinceReferenceDate,
            createdTime: nil,
            isDirectory: false,
            isHidden: FileRecord.pathIsHidden(path),
            volumeName: "Test",
            normalizedName: FuzzyMatcher.normalize(URL(fileURLWithPath: path).lastPathComponent),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(25),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: pollInterval)
        }

        Issue.record("Timed out waiting for condition")
    }
}
