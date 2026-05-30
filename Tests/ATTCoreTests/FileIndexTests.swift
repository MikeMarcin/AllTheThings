@testable import ATTCore
import Foundation
import Testing

@Suite("File index")
struct FileIndexTests {
    @Test("search combines fuzzy text with wildcard and structured path clauses")
    func searchCombinesFuzzyWildcardAndStructuredPathClauses() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source/gct/strings", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let cppMatch = sourceDirectory.appendingPathComponent("AITOBridge.cpp")
        let swiftMiss = sourceDirectory.appendingPathComponent("AITOBridge.swift")
        let fuzzyHeader = sourceDirectory.appendingPathComponent("fuzzy_match.hpp")
        let cppMiss = root.appendingPathComponent("Other.cpp")
        try "cpp".write(to: cppMatch, atomically: true, encoding: .utf8)
        try "swift".write(to: swiftMiss, atomically: true, encoding: .utf8)
        try "hpp".write(to: fuzzyHeader, atomically: true, encoding: .utf8)
        try "other".write(to: cppMiss, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 8
        }

        var response = index.search(SearchRequest(
            query: "aito *.cpp",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.map(\.record.path) == [cppMatch.path])

        response = index.search(SearchRequest(
            query: "source/**/*.hpp",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.map(\.record.path) == [fuzzyHeader.path])

        response = index.search(SearchRequest(
            query: "\(root.path)/source/gct/str/fuzzy",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.map(\.record.path) == [fuzzyHeader.path])
    }

    @Test("refresh moves an updated file to the top of modified sort")
    func refreshResortsModifiedResults() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let olderFile = root.appendingPathComponent("older.txt")
        let newerFile = root.appendingPathComponent("newer.txt")
        try "older".write(to: olderFile, atomically: true, encoding: .utf8)
        try "newer".write(to: newerFile, atomically: true, encoding: .utf8)

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_000_100)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: olderFile.path)
        try fileManager.setAttributes([.modificationDate: newDate], ofItemAtPath: newerFile.path)
        try fileManager.setAttributes([.modificationDate: oldDate.addingTimeInterval(-100)], ofItemAtPath: root.path)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 3
        }

        var response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .modified, ascending: false)
        ), maxResults: 5)
        #expect(response.results.first?.record.path == newerFile.path)

        let newestDate = Date(timeIntervalSince1970: 1_700_000_200)
        try fileManager.setAttributes([.modificationDate: newestDate], ofItemAtPath: olderFile.path)
        index.refresh(paths: [olderFile.path])

        try await waitUntil {
            response = index.search(SearchRequest(
                query: "",
                sort: SortSpec(column: .modified, ascending: false)
            ), maxResults: 5)
            return response.results.first?.record.path == olderFile.path
        }

        let refreshedModifiedTime = try #require(response.results.first?.record.modifiedTime)
        #expect(abs(refreshedModifiedTime - newestDate.timeIntervalSinceReferenceDate) < 0.001)
    }

    @Test("search applies name sort to small result sets")
    func searchAppliesNameSortToSmallResultSets() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let beta = root.appendingPathComponent("Beta.swift")
        let alpha = root.appendingPathComponent("Alpha.swift")
        try "beta".write(to: beta, atomically: true, encoding: .utf8)
        try "alpha".write(to: alpha, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 3
        }

        let response = index.search(SearchRequest(
            query: ".swift",
            sort: SortSpec(column: .name, ascending: true)
        ), maxResults: 10)

        #expect(response.results.map(\.record.name) == ["Alpha.swift", "Beta.swift"])
    }

    @Test("search can hide hidden files")
    func searchCanHideHiddenFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let visibleFile = root.appendingPathComponent("Visible.swift")
        let hiddenFile = root.appendingPathComponent(".Secret.swift")
        let hiddenDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let hiddenChild = hiddenDirectory.appendingPathComponent("config")
        try fileManager.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try "visible".write(to: visibleFile, atomically: true, encoding: .utf8)
        try "secret".write(to: hiddenFile, atomically: true, encoding: .utf8)
        try "config".write(to: hiddenChild, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 5
        }

        var response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 20)
        #expect(response.results.contains { $0.record.path == visibleFile.path })
        #expect(!response.results.contains { $0.record.path == hiddenFile.path })
        #expect(!response.results.contains { $0.record.path == hiddenChild.path })

        response = index.search(SearchRequest(
            query: "Secret",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false
        ), maxResults: 20)
        #expect(response.results.isEmpty)
        #expect(response.totalMatches == 0)

        response = index.search(SearchRequest(
            query: "Secret",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: true
        ), maxResults: 20)
        #expect(response.results.contains { $0.record.path == hiddenFile.path })

        response = index.search(SearchRequest(
            query: "config",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false
        ), maxResults: 20)
        #expect(response.results.isEmpty)
    }

    @Test("optimized search keeps fuzzy and acronym filename matches")
    func optimizedSearchKeepsFuzzyAndAcronymFilenameMatches() throws {
        let acronymPath = "/tmp/allthethings-tests/reports/PhotoSyncReport.final.pdf"
        let typoPath = "/tmp/allthethings-tests/docs/README.md"
        let exactPath = "/tmp/allthethings-tests/docs/redme-notes.txt"
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting([
            makeRecord(path: acronymPath),
            makeRecord(path: typoPath),
            makeRecord(path: exactPath)
        ])

        var response = index.search(SearchRequest(
            query: "psr",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == acronymPath })

        response = index.search(SearchRequest(
            query: "redme",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == typoPath })
        #expect(response.results.contains { $0.record.path == exactPath })
    }

    @Test("persisted snapshots reload optimized search structures")
    func persistedSnapshotsReloadOptimizedSearchStructures() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/allthethings-tests/project/Sources/SearchWindowController.swift"),
            makeRecord(path: "/tmp/allthethings-tests/project/README.md")
        ])
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()

        #expect(diagnostics.recordStoreKind == .mapped)
        #expect(diagnostics.optimizedCount == diagnostics.indexedCount)
        #expect(diagnostics.nameGramPostingCount > 0)
        #expect(diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.pathGramPostingCount > 0)
        #expect(reloaded.search(SearchRequest(
            query: "swc",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 5).results.contains { $0.record.name == "SearchWindowController.swift" })
    }

    @Test("custom exclusions apply during scan and refresh")
    func customExclusionsApplyDuringScanAndRefresh() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let ignoredDirectory = root.appendingPathComponent("ignored", isDirectory: true)
        try fileManager.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let visibleFile = root.appendingPathComponent("Visible.swift")
        let ignoredFile = root.appendingPathComponent("Ignored.tmp")
        let ignoredChild = ignoredDirectory.appendingPathComponent("Hidden.swift")
        try "visible".write(to: visibleFile, atomically: true, encoding: .utf8)
        try "ignored".write(to: ignoredFile, atomically: true, encoding: .utf8)
        try "hidden".write(to: ignoredChild, atomically: true, encoding: .utf8)

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            exclusionPatterns: [
                "*.tmp",
                "ignored/"
            ]
        )
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 2
        }

        var response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true)
        ), maxResults: 20)
        var paths = Set(response.results.map(\.record.path))
        #expect(paths.contains(visibleFile.path))
        #expect(!paths.contains(ignoredFile.path))
        #expect(!paths.contains(ignoredChild.path))

        let refreshedVisible = root.appendingPathComponent("Refreshed.swift")
        let refreshedIgnored = root.appendingPathComponent("Refreshed.tmp")
        try "visible".write(to: refreshedVisible, atomically: true, encoding: .utf8)
        try "ignored".write(to: refreshedIgnored, atomically: true, encoding: .utf8)
        index.refresh(paths: [refreshedVisible.path, refreshedIgnored.path])

        try await waitUntil {
            response = index.search(SearchRequest(
                query: "",
                sort: SortSpec(column: .name, ascending: true)
            ), maxResults: 20)
            return response.results.contains { $0.record.path == refreshedVisible.path }
        }

        paths = Set(response.results.map(\.record.path))
        #expect(paths.contains(refreshedVisible.path))
        #expect(!paths.contains(refreshedIgnored.path))
    }

    @Test("search responses identify the source snapshot revision")
    func searchResponsesIdentifySourceSnapshotRevision() {
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )

        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/allthethings-tests/project/Alpha.swift")
        ])

        let firstStats = index.currentStats()
        let firstResponse = index.search(SearchRequest(
            query: "Alpha",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(firstResponse.snapshotRevision == firstStats.snapshotRevision)

        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/allthethings-tests/project/Alpha.swift"),
            makeRecord(path: "/tmp/allthethings-tests/project/Beta.swift")
        ])

        let secondStats = index.currentStats()
        let secondResponse = index.search(SearchRequest(
            query: "Beta",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)

        #expect(secondStats.snapshotRevision > firstStats.snapshotRevision)
        #expect(secondResponse.snapshotRevision == secondStats.snapshotRevision)
    }

    @Test("search responses identify indexed candidate searches")
    func searchResponsesIdentifyIndexedCandidateSearches() {
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        var records = (0..<32).map {
            makeRecord(path: "/tmp/allthethings-tests/project/Other\($0).txt")
        }
        records.append(makeRecord(path: "/tmp/allthethings-tests/project/NeedleUnique.txt"))
        index.replaceRecordsForTesting(records)

        let indexedResponse = index.search(SearchRequest(
            query: "NeedleUnique",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(indexedResponse.usesIndexedCandidates)
        #expect(indexedResponse.results.map(\.record.name) == ["NeedleUnique.txt"])

        let fullScanResponse = index.search(SearchRequest(
            query: "tmp",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(!fullScanResponse.usesIndexedCandidates)
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

    private func makeRecord(path: String, isDirectory: Bool = false) -> FileRecord {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let directory = url.deletingLastPathComponent().path
        return FileRecord(
            id: FileRecord.stableID(for: path),
            path: path,
            name: name,
            directoryPath: directory,
            fileExtension: url.pathExtension.lowercased(),
            sizeBytes: isDirectory ? 0 : 128,
            modifiedTime: Date().timeIntervalSinceReferenceDate,
            createdTime: nil,
            isDirectory: isDirectory,
            isHidden: FileRecord.pathIsHidden(path),
            volumeName: "Test",
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }
}
