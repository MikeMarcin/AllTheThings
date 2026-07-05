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

    @Test("storage insights reports package sidecars sorted by allocated size")
    func storageInsightsReportsPackageSidecarsSortedByAllocatedSize() throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/AllTheThingsInsights/alpha.txt", size: 12),
            makeRecord(path: "/tmp/AllTheThingsInsights/beta.txt", size: 34)
        ])
        index.persistSnapshotForTesting()

        let sidecars = index.currentInsightsSnapshot().storage.sidecars
        #expect(!sidecars.isEmpty)
        #expect(sidecars.map(\.name).contains(SnapshotLayout.FileName.manifest))
        #expect(sidecars.map(\.name).contains(SnapshotLayout.FileName.records))
        #expect(sidecars.map(\.allocatedBytes) == sidecars.map(\.allocatedBytes).sorted(by: >))
        #expect(sidecars.reduce(UInt64(0)) { $0 + $1.allocatedBytes } == index.currentInsightsSnapshot().storage.indexPackageBytes)
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
                executionPath: .optimizedSortedFastPath,
                indexesUsed: [.nameGrams, .sortOrder, .visibleBitset],
                elapsed: 2.5
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
        #expect(refined.completed == 5)
        #expect(refined.routeCounts[.mappedIndex] == 1)
        #expect(refined.routeCounts[.sidecar] == 2)
        #expect(refined.routeCounts[.fullScan] == 1)
        #expect(refined.routeCounts[.applicationCatalog] == 1)
        #expect(refined.averageLatency(for: .mappedIndex) == 1)
        #expect(refined.averageLatency(for: .sidecar) == 2.25)
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

    @Test("maintenance metrics clamp and aggregate by priority kind and day")
    func maintenanceMetricsClampAndAggregateByPriorityKindAndDay() {
        var metrics = IndexUsageMetrics()
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        metrics.recordMaintenance(IndexMaintenanceOperationMetric(
            kind: .directoryRefresh,
            priority: .background,
            completedAt: completedAt,
            wallTime: -1,
            approximateCPUTime: -2,
            paths: 3,
            records: 4,
            visited: 5,
            yieldedSlices: 1,
            deferredPaths: 2,
            largeOverlays: 1,
            exclusionDecisions: 7,
            exclusionRegexMatches: 8,
            exclusionFastPathDecisions: 9,
            exclusionFastPrunes: 10
        ))
        metrics.recordMaintenance(IndexMaintenanceOperationMetric(
            kind: .snapshotPersist,
            priority: .interactive,
            completedAt: completedAt,
            wallTime: 1.25,
            approximateCPUTime: 0.75,
            records: 11
        ))

        #expect(metrics.maintenance.total.operations == 2)
        #expect(metrics.maintenance.total.wallTime == 1.25)
        #expect(metrics.maintenance.total.approximateCPUTime == 0.75)
        #expect(metrics.maintenance.background.operations == 1)
        #expect(metrics.maintenance.interactive.operations == 1)
        #expect(metrics.maintenance.counters(for: .directoryRefresh).visited == 5)
        #expect(metrics.maintenance.counters(for: .directoryRefresh).exclusionFastPrunes == 10)
        #expect(metrics.maintenance.counters(for: .snapshotPersist).records == 11)
        #expect(metrics.dailyBuckets.count == 1)
        #expect(metrics.dailyBuckets[0].maintenance.total.operations == 2)
        #expect(metrics.dailyBuckets[0].day == IndexUsageMetrics.dayKey(for: completedAt))
    }

    @Test("maintenance metrics are visible immediately but saved on flush")
    func maintenanceMetricsAreVisibleImmediatelyButSavedOnFlush() throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            index.flushUsageMetrics()
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        let metricsURL = index.dataDirectoryURL.appendingPathComponent("index-metrics.json", isDirectory: false)
        try? fileManager.removeItem(at: metricsURL)

        index.recordMaintenanceForTesting(IndexMaintenanceOperationMetric(
            kind: .exactRefresh,
            priority: .background,
            wallTime: 0.25,
            approximateCPUTime: 0.1,
            paths: 2
        ))

        let liveUsage = index.currentInsightsSnapshot().usage
        #expect(liveUsage.maintenance.counters(for: .exactRefresh).operations == 1)
        #expect(liveUsage.maintenance.background.operations == 1)
        #expect(!fileManager.fileExists(atPath: metricsURL.path))

        index.flushUsageMetrics()

        let data = try Data(contentsOf: metricsURL)
        let persisted = try JSONDecoder().decode(IndexUsageMetrics.self, from: data)
        #expect(persisted.maintenance.counters(for: .exactRefresh).operations == 1)
        #expect(persisted.maintenance.background.operations == 1)
    }

    @Test("energy samples aggregate by mode rollup and day")
    func energySamplesAggregateByModeRollupAndDay() {
        var metrics = IndexUsageMetrics()
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let foregroundRecorded = metrics.recordEnergySample(
            completedAt: completedAt,
            duration: 30,
            cpuTime: 3,
            wakeups: 12,
            mode: .foreground
        )
        let backgroundRecorded = metrics.recordEnergySample(
            completedAt: completedAt.addingTimeInterval(60),
            duration: 60,
            cpuTime: 12,
            wakeups: 30,
            mode: .background
        )

        #expect(foregroundRecorded)
        #expect(backgroundRecorded)
        #expect(metrics.recentEnergySamples.count == 2)
        #expect(metrics.energyRollups.count == 1)
        #expect(metrics.energyRollups[0].energy.foreground.cpuTime == 3)
        #expect(metrics.energyRollups[0].energy.background.cpuTime == 12)
        #expect(metrics.energyRollups[0].energy.total.cpuTime == 15)
        #expect(metrics.energyRollups[0].energy.total.wakeups == 42)
        #expect(metrics.energyRollups[0].energy.total.peakCPULoad == 0.2)
        #expect(metrics.dailyBuckets.count == 1)
        #expect(metrics.dailyBuckets[0].energy.foreground.cpuTime == 3)
        #expect(metrics.dailyBuckets[0].energy.background.cpuTime == 12)
        #expect(metrics.dailyBuckets[0].energy.total.samples == 2)
    }

    @Test("calendar activity score uses existing search maintenance and refresh counters")
    func calendarActivityScoreUsesExistingSearchMaintenanceAndRefreshCounters() {
        let bucket = DailyUsageBucket(
            day: "2026-07-04",
            searches: SearchUsageCounters(
                completed: 2,
                cancelled: 1,
                candidateRowsExamined: 9,
                scannedRowsExamined: 4
            ),
            health: IndexHealthCounters(
                fullRebuilds: 1,
                incrementalRefreshBatches: 2,
                recursiveRescans: 1
            ),
            maintenance: IndexMaintenanceCostCounters(
                total: IndexMaintenanceOperationCounters(
                    operations: 1,
                    paths: 3,
                    records: 4,
                    visited: 5,
                    yieldedSlices: 1,
                    deferredPaths: 2
                )
            )
        )

        let components = bucket.calendarActivityScoreComponents
        let expectedSearch = log1p(Double(3)) + log1p(Double(13))
        let expectedIndex = log1p(Double(1)) + log1p(Double(12)) + log1p(Double(3))
        let expectedRefresh = log1p(Double(4))

        #expect(abs(components.search - expectedSearch) < 0.000_001)
        #expect(abs(components.index - expectedIndex) < 0.000_001)
        #expect(abs(components.refresh - expectedRefresh) < 0.000_001)
        #expect(abs(bucket.calendarActivityScore - (expectedSearch + expectedIndex + expectedRefresh)) < 0.000_001)
    }

    @Test("background energy impact uses only background CPU and wakeups")
    func backgroundEnergyImpactUsesOnlyBackgroundCPUAndWakeups() {
        let bucket = DailyUsageBucket(
            day: "2026-07-04",
            energy: EnergyUsageBreakdown(
                foreground: EnergyUsageCounters(cpuTime: 100, wakeups: 100_000),
                background: EnergyUsageCounters(cpuTime: 2, wakeups: 30_000)
            )
        )

        #expect(bucket.backgroundEnergyImpactScore == 5)
    }

    @Test("energy samples build five minute rollups")
    func energySamplesBuildFiveMinuteRollups() {
        var metrics = IndexUsageMetrics()
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        _ = metrics.recordEnergySample(completedAt: completedAt, duration: 30, cpuTime: 3, wakeups: 1, mode: .foreground)
        _ = metrics.recordEnergySample(
            completedAt: completedAt.addingTimeInterval(IndexUsageMetrics.energyRollupInterval + 1),
            duration: 30,
            cpuTime: 6,
            wakeups: 2,
            mode: .background
        )

        #expect(metrics.energyRollups.count == 2)
        #expect(metrics.energyRollups.map(\.bucketStart) == [
            IndexUsageMetrics.energyRollupStart(for: completedAt),
            IndexUsageMetrics.energyRollupStart(for: completedAt.addingTimeInterval(IndexUsageMetrics.energyRollupInterval + 1))
        ])
    }

    @Test("energy samples drop invalid deltas")
    func energySamplesDropInvalidDeltas() {
        var metrics = IndexUsageMetrics()
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let zeroDurationRecorded = metrics.recordEnergySample(
            completedAt: completedAt,
            duration: 0,
            cpuTime: 1,
            wakeups: 0,
            mode: .foreground
        )
        let negativeCPURecorded = metrics.recordEnergySample(
            completedAt: completedAt,
            duration: 30,
            cpuTime: -1,
            wakeups: 0,
            mode: .background
        )

        #expect(!zeroDurationRecorded)
        #expect(!negativeCPURecorded)
        #expect(metrics.recentEnergySamples.isEmpty)
        #expect(metrics.energyRollups.isEmpty)
        #expect(metrics.dailyBuckets.isEmpty)
    }

    @Test("energy history retention keeps recent intervals and two day rollups")
    func energyHistoryRetentionKeepsRecentIntervalsAndTwoDayRollups() {
        var metrics = IndexUsageMetrics()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = metrics.recordEnergySample(
            completedAt: now.addingTimeInterval(-3 * 60 * 60),
            duration: 30,
            cpuTime: 1,
            wakeups: 1,
            mode: .background
        )
        _ = metrics.recordEnergySample(
            completedAt: now.addingTimeInterval(-49 * 60 * 60),
            duration: 30,
            cpuTime: 1,
            wakeups: 1,
            mode: .background
        )
        _ = metrics.recordEnergySample(completedAt: now, duration: 30, cpuTime: 2, wakeups: 2, mode: .foreground)

        #expect(metrics.recentEnergySamples.map(\.completedAt) == [now])
        #expect(metrics.energyRollups.allSatisfy { $0.bucketStart >= now.addingTimeInterval(-IndexUsageMetrics.retainedEnergyRollupInterval) })
        #expect(metrics.energyRollups.contains { $0.energy.foreground.cpuTime == 2 })
    }

    @Test("legacy v3 metrics migrate with empty energy history")
    func legacyV3MetricsMigrateWithEmptyEnergyHistory() throws {
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
          "schemaVersion": 3,
          "dailyBuckets": [
            {
              "day": "2026-06-14"
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: metricsURL)

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        let usage = index.currentInsightsSnapshot().usage
        #expect(usage.schemaVersion == IndexUsageMetrics.currentSchemaVersion)
        #expect(usage.recentEnergySamples.isEmpty)
        #expect(usage.energyRollups.isEmpty)
        #expect(usage.dailyBuckets.first?.energy.total.cpuTime == 0)
    }

    @Test("legacy v2 metrics migrate with empty maintenance counters")
    func legacyV2MetricsMigrateWithEmptyMaintenanceCounters() throws {
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
          "schemaVersion": 2,
          "allTimeSearches": {
            "started": 3,
            "completed": 2
          },
          "dailyBuckets": [
            {
              "day": "2026-06-14",
              "searches": {
                "started": 3,
                "completed": 2
              }
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: metricsURL)

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        let usage = index.currentInsightsSnapshot().usage
        #expect(usage.schemaVersion == IndexUsageMetrics.currentSchemaVersion)
        #expect(usage.allTimeSearches.started == 3)
        #expect(usage.maintenance.total.operations == 0)
        #expect(usage.dailyBuckets.first?.maintenance.total.operations == 0)
    }

    @Test("incremental refresh records exact maintenance cost")
    func incrementalRefreshRecordsExactMaintenanceCost() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsMaintenance-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let file = root.appendingPathComponent("Exact.swift")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.replaceRootsAndRebuild([root])
        try await waitUntil {
            !index.currentStats().isIndexing
        }

        let before = index.currentInsightsSnapshot().usage.maintenance.counters(for: .exactRefresh).operations
        try "after".write(to: file, atomically: true, encoding: .utf8)
        index.update(paths: [file.path])

        try await waitUntil(timeout: .seconds(5)) {
            index.currentInsightsSnapshot().usage.maintenance.counters(for: .exactRefresh).operations > before
        }

        let snapshot = index.currentInsightsSnapshot()
        let exact = snapshot.usage.maintenance.counters(for: .exactRefresh)
        #expect(exact.paths >= 1)
        #expect(exact.records >= 1)
        #expect(snapshot.health.maintenance.lastOperation?.kind == .exactRefresh)
    }

    @Test("rebuild maintenance counts fast-pruned generated directories")
    func rebuildMaintenanceCountsFastPrunedGeneratedDirectories() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsMaintenance-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Sources", isDirectory: true)
        let buckOut = root.appendingPathComponent("buck-out", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: buckOut, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try "source".write(to: source.appendingPathComponent("Kept.swift"), atomically: true, encoding: .utf8)
        try "generated".write(to: buckOut.appendingPathComponent("Generated.swift"), atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsInsights-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
        }

        index.replaceRootsAndRebuild([root])
        try await waitUntil {
            !index.currentStats().isIndexing
                && index.currentInsightsSnapshot()
                    .usage
                    .maintenance
                    .counters(for: .fullRebuild)
                    .operations >= 1
        }

        let snapshot = index.currentInsightsSnapshot()
        let rebuild = snapshot.usage.maintenance.counters(for: .fullRebuild)
        #expect(rebuild.exclusionFastPrunes >= 1)
        #expect(index.search(SearchRequest(
            query: "Generated",
            sort: SortSpec(column: .name, ascending: true)
        )).totalMatches == 0)
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
