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

    @Test("update moves an updated file to the top of modified sort")
    func updateResortsModifiedResults() async throws {
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
        index.update(paths: [olderFile.path])

        try await waitUntil {
            response = index.search(SearchRequest(
                query: "",
                sort: SortSpec(column: .modified, ascending: false)
            ), maxResults: 5)
            return response.results.first?.record.path == olderFile.path
        }

        let updatedModifiedTime = try #require(response.results.first?.record.modifiedTime)
        #expect(abs(updatedModifiedTime - newestDate.timeIntervalSinceReferenceDate) < 0.001)
    }

    @Test("same-path update preserves optimized search structures")
    func samePathUpdatePreservesOptimizedSearchStructures() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let match = root.appendingPathComponent("AitoProject.swift")
        let other = root.appendingPathComponent("Other.swift")
        try "old".write(to: match, atomically: true, encoding: .utf8)
        try "other".write(to: other, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 3
        }

        let before = index.currentDiagnostics()
        #expect(before.optimizedCount == before.indexedCount)
        #expect(before.nameGramPostingCount > 0)

        try "new".write(to: match, atomically: true, encoding: .utf8)
        index.update(paths: [match.path])

        try await waitUntil {
            index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches
        }

        let after = index.currentDiagnostics()
        #expect(after.optimizedCount == after.indexedCount)
        #expect(after.nameGramPostingCount == before.nameGramPostingCount)
        #expect(after.overlayCount == 1)

        let response = index.search(SearchRequest(
            query: "aitoproject",
            sort: SortSpec(column: .name, ascending: true)
        ), maxResults: 10)
        #expect(response.usesIndexedCandidates)
        #expect(response.results.contains { $0.record.path == match.path })
    }

    @Test("updates queued during fresh indexing apply after build finishes")
    func updatesQueuedDuringFreshIndexingApplyAfterBuildFinishes() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let existing = root.appendingPathComponent("Existing.swift")
        let createdDuringBuild = root.appendingPathComponent("CreatedDuringBuild.swift")
        try "existing".write(to: existing, atomically: true, encoding: .utf8)

        let rootRecord = try #require(FileRecord(url: root))
        let existingRecord = try #require(FileRecord(url: existing))
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(
            [rootRecord, existingRecord],
            roots: [root],
            buildsSearchStructures: false,
            phase: .scanning,
            status: "Indexing 2 discovered"
        )

        let before = index.currentDiagnostics()
        try "created".write(to: createdDuringBuild, atomically: true, encoding: .utf8)
        index.update(paths: [createdDuringBuild.path])
        try await Task.sleep(for: .milliseconds(250))
        #expect(index.currentDiagnostics().completedRefreshBatches == before.completedRefreshBatches)

        index.replaceRecordsForTesting([rootRecord, existingRecord], roots: [root])

        try await waitUntil {
            index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches
        }

        let response = index.search(SearchRequest(
            query: "CreatedDuringBuild",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == createdDuringBuild.path })
    }

    @Test("reconciliations queued during indexing coalesce after build finishes")
    func reconciliationsQueuedDuringIndexingCoalesceAfterBuildFinishes() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let firstFolder = root.appendingPathComponent("First", isDirectory: true)
        let secondFolder = root.appendingPathComponent("Second", isDirectory: true)
        try fileManager.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let firstFile = firstFolder.appendingPathComponent("FirstQueued.log")
        let secondFile = secondFolder.appendingPathComponent("SecondQueued.log")
        try "first".write(to: firstFile, atomically: true, encoding: .utf8)
        try "second".write(to: secondFile, atomically: true, encoding: .utf8)

        let rootRecord = try #require(FileRecord(url: root))
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(
            [rootRecord],
            roots: [root],
            phase: .scanning,
            status: "Indexing test records"
        )

        index.reconcileIndexedRootsInBackground(rootURLs: [firstFolder])
        index.reconcileIndexedRootsInBackground(rootURLs: [secondFolder])
        try await Task.sleep(for: .milliseconds(250))
        #expect(index.currentStats().status == "Indexing test records")

        let rebuildsBeforeReady = index.currentDiagnostics().completedSnapshotRebuilds
        index.replaceRecordsForTesting([rootRecord], roots: [root])

        try await waitUntil(timeout: .seconds(10)) {
            let first = index.search(SearchRequest(
                query: "FirstQueued",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            let second = index.search(SearchRequest(
                query: "SecondQueued",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return first.results.contains { $0.record.path == firstFile.path }
                && second.results.contains { $0.record.path == secondFile.path }
        }

        #expect(index.currentDiagnostics().completedSnapshotRebuilds == rebuildsBeforeReady + 2)
    }

    @Test("large overlay updates schedule mapped snapshot compaction")
    func largeOverlayUpdatesScheduleMappedSnapshotCompaction() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let updatedFile = root.appendingPathComponent("Updated.txt")
        try "old".write(to: updatedFile, atomically: true, encoding: .utf8)

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: 0,
            largeOverlayPersistDelay: 0.2
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.indexedCount >= 2
                && diagnostics.recordStoreKind == .mapped
        }

        let before = index.currentDiagnostics()
        try "new".write(to: updatedFile, atomically: true, encoding: .utf8)
        index.update(paths: [updatedFile.path])

        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.overlayCount > 0
                && diagnostics.completedRefreshBatches > before.completedRefreshBatches
        }
        let overlayRevision = index.currentDiagnostics().snapshotRevision

        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.snapshotRevision > overlayRevision
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.overlayCount == 0
        }
    }

    @Test("update applies optimized overlay so log and log.rb searches stay indexed")
    func updateAppliesOptimizedOverlaySoLogAndLogRBSearchesStayIndexed() async throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false
        )
        let fileCount = 1_000
        let rootPath = (
            "/tmp/attperf/"
                + String(repeating: "path-area/", count: 3)
        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absoluteRootPath = "/" + rootPath
        let deletedPath = "\(absoluteRootPath)/NeutralDeleted.txt"
        let rubyDirectory = "\(absoluteRootPath)/Ruby/lib/rubygems/resolver/molinillo/dependency_graph"
        let rubyLogPath = "\(rubyDirectory)/log.rb"
        var records: [FileRecord] = []
        records.reserveCapacity(fileCount + 256)
        var directoryPaths = Set<String>()

        func appendDirectory(_ path: String) {
            guard directoryPaths.insert(path).inserted else { return }
            records.append(makeRecord(path: path, isDirectory: true, modifiedTime: 0))
        }

        func appendDirectoryTree(_ path: String) {
            var currentDirectory = ""
            for component in path.split(separator: "/") {
                currentDirectory += "/" + component
                appendDirectory(currentDirectory)
            }
        }

        appendDirectoryTree(absoluteRootPath)
        appendDirectoryTree(rubyDirectory)
        records.append(makeRecord(path: rubyLogPath, modifiedTime: TimeInterval(fileCount + 1)))

        for row in 0..<fileCount {
            let projectDirectory = "\(absoluteRootPath)/Project\(row / 1_000)"
            appendDirectory(projectDirectory)
            let path: String
            if row == 10 {
                path = deletedPath
            } else if row.isMultiple(of: 1_000) {
                path = "\(projectDirectory)/LogReport\(row).txt"
            } else {
                path = "\(projectDirectory)/File\(row).txt"
            }
            records.append(makeRecord(path: path, modifiedTime: TimeInterval(row)))
        }
        index.replaceRecordsForTesting(records)

        let before = index.currentStats()
        #expect(before.optimizedCount == before.indexedCount)

        func expectFastIndexedLogSearches() {
            let logResponse = index.search(SearchRequest(
                query: "log",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 25)
            #expect(logResponse.usesIndexedCandidates)
            #expect(logResponse.executionProfile.executionPath != .fullFallbackScan)
            #expect(logResponse.executionProfile.candidateCount < before.indexedCount / 10)
            #expect(logResponse.executionProfile.scannedRowCount <= logResponse.executionProfile.candidateCount)
            #expect(logResponse.results.contains { $0.record.name.hasPrefix("LogReport") })

            let logRBResponse = index.search(SearchRequest(
                query: "log.rb",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 25)
            #expect(logRBResponse.usesIndexedCandidates)
            #expect(logRBResponse.executionProfile.executionPath != .fullFallbackScan)
            #expect(logRBResponse.executionProfile.candidateCount < before.indexedCount / 10)
            #expect(logRBResponse.executionProfile.scannedRowCount <= logRBResponse.executionProfile.candidateCount)
            #expect(logRBResponse.results.contains { $0.record.path == rubyLogPath })
        }

        expectFastIndexedLogSearches()

        let beforeDiagnostics = index.currentDiagnostics()
        let beforeRebuilds = beforeDiagnostics.completedSnapshotRebuilds
        index.update(paths: [deletedPath])

        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().completedRefreshBatches > beforeDiagnostics.completedRefreshBatches
        }

        let after = index.currentStats()
        let afterDiagnostics = index.currentDiagnostics()
        #expect(after.optimizedCount == after.indexedCount)
        #expect(after.indexedCount == before.indexedCount - 1)
        #expect(afterDiagnostics.overlayCount == 1)
        #expect(afterDiagnostics.completedSnapshotRebuilds == beforeRebuilds)

        expectFastIndexedLogSearches()
    }

    @Test("directory update removes deleted mapped children")
    func directoryUpdateRemovesDeletedMappedChildren() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let kept = folder.appendingPathComponent("Kept.swift")
        let deleted = folder.appendingPathComponent("Deleted.swift")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "deleted".write(to: deleted, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])
        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 4
        }

        let before = index.currentDiagnostics()
        #expect(before.recordStoreKind == .mapped)

        try fileManager.removeItem(at: deleted)
        index.update(paths: [deleted.path])

        try await waitUntil {
            guard index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches else {
                return false
            }

            let keptResponse = index.search(SearchRequest(
                query: "Kept",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            let deletedResponse = index.search(SearchRequest(
                query: "Deleted",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return keptResponse.results.contains { $0.record.path == kept.path }
                && !deletedResponse.results.contains { $0.record.path == deleted.path }
        }
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
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let index = FileIndex(
            applicationName: applicationName,
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
        #expect(diagnostics.columnarSidecarsLoaded)
        #expect(diagnostics.visibleCount == diagnostics.indexedCount)
        #expect(diagnostics.visibleModifiedOrderCount == diagnostics.indexedCount)
        #expect(diagnostics.simdTextVerificationEnabled)
        let packageURL = SnapshotLayout.packageURL(in: supportDirectory(applicationName: applicationName))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.parent).path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.flags).path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.visible).path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.subtreeEnd).path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.rootID).path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.roots).path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings).path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.visibleModifiedOrder).path))
        #expect(reloaded.search(SearchRequest(
            query: "swc",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 5).results.contains { $0.record.name == "SearchWindowController.swift" })
    }

    @Test("v7 cutover removes obsolete index artifacts")
    func v7CutoverRemovesObsoleteIndexArtifacts() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let obsoletePackages = [
            supportDirectory.appendingPathComponent("filename-index-v6.attindex", isDirectory: true),
            supportDirectory.appendingPathComponent("filename-index-v6-checkpoint.attindex", isDirectory: true),
            supportDirectory.appendingPathComponent("filename-index-v6-\(UUID().uuidString).attindex.tmp", isDirectory: true),
            supportDirectory.appendingPathComponent("filename-index-v6-checkpoint-\(UUID().uuidString).attindex.tmp", isDirectory: true),
            supportDirectory.appendingPathComponent("filename-index-v5.attindex", isDirectory: true),
            supportDirectory.appendingPathComponent("filename-index-v4.attindex", isDirectory: true),
            supportDirectory.appendingPathComponent("filename-index-v5-\(UUID().uuidString).attindex.tmp", isDirectory: true),
            supportDirectory.appendingPathComponent("filename-index-v4-\(UUID().uuidString).attindex.tmp", isDirectory: true)
        ]
        for package in obsoletePackages {
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        }

        let obsoleteFiles = [
            supportDirectory.appendingPathComponent("filename-index-v2.jsonl", isDirectory: false),
            supportDirectory.appendingPathComponent("filename-index-v2-\(UUID().uuidString).jsonl.tmp", isDirectory: false),
            supportDirectory.appendingPathComponent("filename-index.json", isDirectory: false),
            supportDirectory.appendingPathComponent("filename-index.json.tmp", isDirectory: false)
        ]
        for file in obsoleteFiles {
            try Data([1]).write(to: file)
        }

        _ = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)

        for url in obsoletePackages + obsoleteFiles {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("missing v7 sidecars invalidate persisted snapshots")
    func missingV7SidecarsInvalidatePersistedSnapshots() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/allthethings-tests/project/Alpha.swift")
        ])
        index.persistSnapshotForTesting()

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        try FileManager.default.removeItem(at: packageURL.appendingPathComponent(SnapshotLayout.FileName.rootID))

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()
        #expect(diagnostics.indexedCount == 0)
        #expect(diagnostics.recordStoreKind == .empty)
        #expect(!FileManager.default.fileExists(atPath: packageURL.path))
    }

    @Test("partial checkpoints load as searchable unoptimized snapshots")
    func partialCheckpointsLoadAsSearchableUnoptimizedSnapshots() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp/allthethings-checkpoint-fast", isDirectory: true)
        let records = [
            makeRecord(path: "\(root.path)/LogViewer.swift"),
            makeRecord(path: "\(root.path)/Other.txt")
        ]

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.persistCheckpointForTesting(
            records: records,
            roots: [root],
            pendingDirectories: []
        )

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        #expect(reloaded.loadCheckpointForTesting(roots: [root]))
        let stats = reloaded.currentStats()
        #expect(stats.resumedFromCheckpoint)
        #expect(stats.lastCheckpointAt != nil)
        #expect(stats.activeOperationStartedAt == Date(timeIntervalSince1970: 0))

        let response = reloaded.search(SearchRequest(
            query: "LogViewer",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(!response.usesIndexedCandidates)
        #expect(response.results.map(\.record.name) == ["LogViewer.swift"])
    }

    @Test("resumed checkpoints continue pending directories and clean up after final install")
    func resumedCheckpointsContinuePendingDirectoriesAndCleanUp() async throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let pendingDirectory = root.appendingPathComponent("pending", isDirectory: true)
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }

        let existingFile = root.appendingPathComponent("Existing.log")
        let pendingFile = pendingDirectory.appendingPathComponent("Pending.log")
        try "existing".write(to: existingFile, atomically: true, encoding: .utf8)
        try "pending".write(to: pendingFile, atomically: true, encoding: .utf8)

        let checkpointRecords = [root, existingFile].compactMap { FileRecord(url: $0) }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.persistCheckpointForTesting(
            records: checkpointRecords,
            roots: [root],
            pendingDirectories: [pendingDirectory],
            completedDirectories: [root]
        )
        #expect(index.checkpointExistsForTesting())

        let resumed = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        resumed.replaceRootsAndRebuild([root], mode: .resumeIfAvailable)

        try await waitUntil {
            let stats = resumed.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 3
        }

        let response = resumed.search(SearchRequest(
            query: "Pending",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == pendingFile.path })
        #expect(!resumed.checkpointExistsForTesting())
    }

    @Test("checkpoint cleanup covers settings mismatch fresh rebuild and final snapshot install")
    func checkpointCleanupCoversMismatchFreshRebuildAndFinalInstall() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let file = root.appendingPathComponent("Cleanup.log")
        try "cleanup".write(to: file, atomically: true, encoding: .utf8)
        let records = [root, file].compactMap { FileRecord(url: $0) }

        let mismatchApp = "AllTheThingsTests-\(UUID().uuidString)"
        let mismatchIndex = FileIndex(
            applicationName: mismatchApp,
            loadsSnapshotImmediately: false,
            exclusionPatterns: ["ignored/"]
        )
        mismatchIndex.persistCheckpointForTesting(records: records, roots: [root], pendingDirectories: [root])
        let mismatchReload = FileIndex(
            applicationName: mismatchApp,
            loadsSnapshotImmediately: false,
            exclusionPatterns: ["different/"]
        )
        #expect(!mismatchReload.hasResumableCheckpoint(for: [root]))
        #expect(!mismatchReload.checkpointExistsForTesting())

        let freshApp = "AllTheThingsTests-\(UUID().uuidString)"
        let freshIndex = FileIndex(applicationName: freshApp, loadsSnapshotImmediately: false)
        freshIndex.persistCheckpointForTesting(records: records, roots: [root], pendingDirectories: [root])
        freshIndex.replaceRootsAndRebuild([root], mode: .fresh)

        try await waitUntil {
            let stats = freshIndex.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 2
        }

        #expect(!freshIndex.checkpointExistsForTesting())
    }

    @Test("scan can suppress searchable snapshot publication until final index")
    func scanCanSuppressSearchableSnapshotPublicationUntilFinalIndex() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        for index in 0..<1_500 {
            let file = root.appendingPathComponent("Generated-\(index).txt")
            try "generated".write(to: file, atomically: true, encoding: .utf8)
        }

        let recorder = StatsRecorder()
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.setPublishesSearchableSnapshotsDuringScan(false)
        index.onStatsChanged = { @MainActor @Sendable stats in
            recorder.append(stats)
        }
        index.replaceRootsAndRebuild([root], mode: .fresh)

        try await waitUntil(timeout: .seconds(10)) {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 1_501
        }

        let indexingStats = recorder.snapshot().filter(\.isIndexing)
        #expect(indexingStats.contains { $0.discoveredCount > 0 })
        #expect(!indexingStats.contains { $0.isReconciling })
        #expect(!indexingStats.contains { $0.isUpdating })
        #expect(!indexingStats.contains { $0.indexedCount > 0 })
        #expect(index.currentStats().indexedCount >= 1_501)
    }

    @Test("reconciliation publishes reconciling scan progress from zero")
    func reconciliationPublishesReconcilingScanProgressFromZero() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        for index in 0..<1_500 {
            let file = root.appendingPathComponent("Generated-\(index).txt")
            try "generated".write(to: file, atomically: true, encoding: .utf8)
        }

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 1_501
        }

        let recorder = StatsRecorder()
        index.onStatsChanged = { @MainActor @Sendable stats in
            recorder.append(stats)
        }
        index.reconcileIndexedRootsInBackground(rootURLs: [root])

        try await waitUntil(timeout: .seconds(10)) {
            !index.currentStats().isIndexing
        }

        let scanStats = recorder.snapshot().filter { $0.isIndexing && $0.phase == .scanning }
        #expect(scanStats.contains { $0.status.hasPrefix("Reconciling") && $0.discoveredCount == 0 })
        #expect(scanStats.contains { $0.status.hasPrefix("Reconciling") && $0.discoveredCount > 0 })
        #expect(scanStats.allSatisfy { $0.isReconciling })
        #expect(!scanStats.contains { $0.isUpdating })
        #expect(!scanStats.contains { $0.status.hasPrefix("Indexing") })
        #expect(!index.currentStats().isReconciling)
    }

    @Test("loaded snapshots reconcile changes made while app was closed")
    func loadedSnapshotsReconcileChangesMadeWhileAppWasClosed() async throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }

        let originalFile = root.appendingPathComponent("Original.log")
        try "original".write(to: originalFile, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 2
        }

        let closedAppFile = root.appendingPathComponent("ClosedApp.log")
        try "closed".write(to: closedAppFile, atomically: true, encoding: .utf8)

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        try await waitUntil(timeout: .seconds(10)) {
            let response = reloaded.search(SearchRequest(
                query: "ClosedApp",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return response.results.contains { $0.record.path == closedAppFile.path }
        }
    }

    @Test("scoped reconciliation preserves records from unchanged roots")
    func scopedReconciliationPreservesRecordsFromUnchangedRoots() async throws {
        let fileManager = FileManager.default
        let rootA = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)-a", isDirectory: true)
        let rootB = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)-b", isDirectory: true)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: rootA)
            try? fileManager.removeItem(at: rootB)
        }

        let removedFile = rootA.appendingPathComponent("Removed.log")
        let retainedFile = rootB.appendingPathComponent("Retained.log")
        try "removed".write(to: removedFile, atomically: true, encoding: .utf8)
        try "retained".write(to: retainedFile, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([rootA, rootB], mode: .fresh)
        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 4
        }

        try fileManager.removeItem(at: removedFile)
        index.reconcileIndexedRootsInBackground(rootURLs: [rootA])

        try await waitUntil(timeout: .seconds(10)) {
            let removed = index.search(SearchRequest(
                query: "Removed",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            let retained = index.search(SearchRequest(
                query: "Retained",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return removed.results.isEmpty && retained.results.contains { $0.record.path == retainedFile.path }
        }
    }

    @Test("scoped reconciliation accepts changed folders inside an indexed root")
    func scopedReconciliationAcceptsChangedFoldersInsideIndexedRoot() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let changedFolder = root.appendingPathComponent("Changed", isDirectory: true)
        let unchangedFolder = root.appendingPathComponent("Unchanged", isDirectory: true)
        try fileManager.createDirectory(at: changedFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unchangedFolder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let removedFile = changedFolder.appendingPathComponent("Removed.log")
        let addedFile = changedFolder.appendingPathComponent("Added.log")
        let retainedFile = unchangedFolder.appendingPathComponent("Retained.log")
        try "removed".write(to: removedFile, atomically: true, encoding: .utf8)
        try "retained".write(to: retainedFile, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 5
        }

        try fileManager.removeItem(at: removedFile)
        try "added".write(to: addedFile, atomically: true, encoding: .utf8)
        index.reconcileIndexedRootsInBackground(rootURLs: [changedFolder])

        try await waitUntil(timeout: .seconds(10)) {
            let removed = index.search(SearchRequest(
                query: "Removed",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            let added = index.search(SearchRequest(
                query: "Added",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            let retained = index.search(SearchRequest(
                query: "Retained",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return removed.results.isEmpty
                && added.results.contains { $0.record.path == addedFile.path }
                && retained.results.contains { $0.record.path == retainedFile.path }
        }
    }

    @Test("visible bitset hides descendants of hidden parent rows")
    func visibleBitsetHidesDescendantsOfHiddenParentRows() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let hiddenParent = makeRecord(
            path: "/tmp/allthethings-tests/project/HiddenParent",
            isDirectory: true,
            isHidden: true,
            modifiedTime: 3_000
        )
        let hiddenChild = makeRecord(
            path: "/tmp/allthethings-tests/project/HiddenParent/Child.swift",
            isHidden: false,
            modifiedTime: 4_000
        )
        let visibleChild = makeRecord(
            path: "/tmp/allthethings-tests/project/Visible.swift",
            modifiedTime: 1_000
        )
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([hiddenParent, hiddenChild, visibleChild])
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)

        var response = reloaded.search(SearchRequest(
            query: "Child",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false
        ), maxResults: 10)
        #expect(response.results.isEmpty)

        response = reloaded.search(SearchRequest(
            query: "Child",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: true
        ), maxResults: 10)
        #expect(response.results.map(\.record.path) == [hiddenChild.path])

        response = reloaded.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false
        ), maxResults: 1)
        #expect(response.results.map(\.record.path) == [visibleChild.path])

        response = reloaded.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: true
        ), maxResults: 1)
        #expect(response.results.map(\.record.path) == [hiddenChild.path])
    }

    @Test("custom exclusions apply during scan and update")
    func customExclusionsApplyDuringScanAndUpdate() async throws {
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

        let updatedVisible = root.appendingPathComponent("Updated.swift")
        let updatedIgnored = root.appendingPathComponent("Updated.tmp")
        try "visible".write(to: updatedVisible, atomically: true, encoding: .utf8)
        try "ignored".write(to: updatedIgnored, atomically: true, encoding: .utf8)
        index.update(paths: [updatedVisible.path, updatedIgnored.path])

        try await waitUntil {
            response = index.search(SearchRequest(
                query: "",
                sort: SortSpec(column: .name, ascending: true)
            ), maxResults: 20)
            return response.results.contains { $0.record.path == updatedVisible.path }
        }

        paths = Set(response.results.map(\.record.path))
        #expect(paths.contains(updatedVisible.path))
        #expect(!paths.contains(updatedIgnored.path))
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

    @Test("search results expose root path and sort by root")
    func searchResultsExposeRootPathAndSortByRoot() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsRootSort-\(UUID().uuidString)", isDirectory: true)
        let rootA = root.appendingPathComponent("A-Root", isDirectory: true)
        let rootB = root.appendingPathComponent("B-Root", isDirectory: true)
        try? fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(
            [
                makeRecord(path: rootB.appendingPathComponent("Aardvark.txt").path),
                makeRecord(path: rootA.appendingPathComponent("Zebra.txt").path)
            ],
            roots: [rootA, rootB]
        )
        index.persistSnapshotForTesting()

        let response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .root, ascending: true)
        ), maxResults: 10)

        #expect(response.results.map(\.rootPath) == [
            rootA.standardizedFileURL.path,
            rootB.standardizedFileURL.path
        ])
        #expect(response.results.map(\.record.name) == ["Zebra.txt", "Aardvark.txt"])
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

    @Test("log search ranks match quality before selected column sort")
    func logSearchRanksMatchQualityBeforeSelectedColumnSort() throws {
        let root = "/tmp/allthethings-ranking"
        let records = [
            makeRecord(path: "\(root)/Arcology.md"),
            makeRecord(path: "\(root)/YellowGlow.funhouse"),
            makeRecord(path: "\(root)/22_ColorGradient"),
            makeRecord(path: "\(root)/Klopfgeist", isDirectory: true),
            makeRecord(path: "\(root)/Klopfgeist/#default.pst"),
            makeRecord(path: "\(root)/MALogicLegacySong.framework", isDirectory: true),
            makeRecord(path: "\(root)/MALogicLegacySong.framework/Versions", isDirectory: true),
            makeRecord(path: "\(root)/MALogicLegacySong.framework/Versions/A", isDirectory: true),
            makeRecord(path: "\(root)/MALoopManagement.framework", isDirectory: true),
            makeRecord(path: "\(root)/MALoopManagement.framework/Versions", isDirectory: true),
            makeRecord(path: "\(root)/MALoopManagement.framework/Versions/A", isDirectory: true),
            makeRecord(path: "\(root)/ca.lproj", isDirectory: true),
            makeRecord(path: "\(root)/ca.lproj/AlertCollector.strings")
        ]
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records)

        let response = index.search(SearchRequest(
            query: "log",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 20)

        let paths = response.results.map(\.record.path)
        #expect(!paths.contains("\(root)/Klopfgeist/#default.pst"))
        #expect(!paths.contains("\(root)/ca.lproj/AlertCollector.strings"))

        let arcologyIndex = try #require(paths.firstIndex(of: "\(root)/Arcology.md"))
        let yellowGlowIndex = try #require(paths.firstIndex(of: "\(root)/YellowGlow.funhouse"))
        let colorGradientIndex = try #require(paths.firstIndex(of: "\(root)/22_ColorGradient"))
        let logicChildIndex = try #require(paths.firstIndex(of: "\(root)/MALogicLegacySong.framework/Versions/A"))
        let loopChildIndex = try #require(paths.firstIndex(of: "\(root)/MALoopManagement.framework/Versions/A"))

        #expect(response.results[arcologyIndex].match?.matchClass == .substring)
        #expect(response.results[yellowGlowIndex].match?.matchClass == .near)
        #expect(response.results[colorGradientIndex].match?.matchClass == .near)
        #expect(response.results[logicChildIndex].match?.matchClass == .weakPath)
        #expect(response.results[logicChildIndex].match?.field == .ancestorPath)
        #expect(response.results[loopChildIndex].match?.matchClass == .weakPath)
        #expect(response.results[loopChildIndex].match?.field == .ancestorPath)
        #expect(arcologyIndex < logicChildIndex)
        #expect(yellowGlowIndex < logicChildIndex)
        #expect(colorGradientIndex < logicChildIndex)
    }

    @Test("interactive preview refines to complete short fuzzy path matches")
    func interactivePreviewRefinesToCompleteShortFuzzyPathMatches() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = "/tmp/allthethings-preview-refinement/"
            + String(repeating: "wide-directory-segment/", count: 200)
        var records = [
            makeRecord(path: "\(root)/Arcology.md"),
            makeRecord(path: "\(root)/MALoopManagement.framework", isDirectory: true),
            makeRecord(path: "\(root)/MALoopManagement.framework/Versions", isDirectory: true),
            makeRecord(path: "\(root)/MALoopManagement.framework/Versions/A", isDirectory: true)
        ]

        for index in 0..<6_000 {
            records.append(makeRecord(
                path: "\(root)/unrelated/File\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(10_000 + index)
            ))
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()
        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(!reloaded.currentDiagnostics().pathGramIndexEnabled)

        let previewResponse = reloaded.search(SearchRequest(
            query: "log",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 20)
        let completeResponse = reloaded.search(SearchRequest(
            query: "log",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 20)

        let refinedPath = "\(root)/MALoopManagement.framework/Versions/A"
        #expect(!previewResponse.results.map(\.record.path).contains(refinedPath))
        #expect(completeResponse.results.map(\.record.path).contains(refinedPath))
        #expect(completeResponse.totalMatches > previewResponse.totalMatches)
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

    private func supportDirectory(applicationName: String) -> URL {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return supportRoot.appendingPathComponent(applicationName, isDirectory: true)
    }

    private func makeRecord(
        path: String,
        isDirectory: Bool = false,
        isHidden: Bool? = nil,
        modifiedTime: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) -> FileRecord {
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
            modifiedTime: modifiedTime,
            createdTime: nil,
            isDirectory: isDirectory,
            isHidden: isHidden ?? FileRecord.pathIsHidden(path),
            volumeName: "Test",
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }
}

private final class StatsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stats: [IndexStats] = []

    func append(_ stats: IndexStats) {
        lock.withLock {
            self.stats.append(stats)
        }
    }

    func snapshot() -> [IndexStats] {
        lock.withLock {
            stats
        }
    }
}
