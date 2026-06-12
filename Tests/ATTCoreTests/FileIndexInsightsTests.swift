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

    @Test("search profiles and metrics stay aggregate only")
    func searchProfilesAndMetricsStayAggregateOnly() throws {
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

        let response = index.search(SearchRequest(
            query: "AlphaSecret",
            sort: SortSpec(column: .name, ascending: true)
        ))

        #expect(response.executionProfile.elapsed >= 0)
        #expect(response.executionProfile.executionPath != .unprofiled)

        let usage = index.currentInsightsSnapshot().usage
        #expect(usage.allTimeSearches.started == 1)
        #expect(usage.allTimeSearches.completed == 1)
        #expect(!usage.allTimeSearches.executionPathCounts.isEmpty)

        let data = try JSONEncoder().encode(usage)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("alphasecret"))
        #expect(!json.contains("allthethingsprivate"))
        #expect(!json.contains(privatePath.lowercased()))
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
        timeout: Duration = .seconds(5),
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
