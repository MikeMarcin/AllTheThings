@testable import ATTCore
import Foundation
import Testing

@Suite("Memory budget")
struct MemoryBudgetTests {
    @Test("large synthetic indexes disable full path gram postings")
    func largeSyntheticIndexesDisableFullPathGramPostings() {
        let recordCount = 20_000
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        var records = makeSyntheticRecords(
            count: recordCount,
            directoryPadding: String(repeating: "deep-directory-segment/", count: 70)
        )
        let specialPath = "/tmp/allthethings-memory/project/source/gct/core/type_traits.hpp"
        records[123] = FileRecord(
            id: FileRecord.stableID(for: specialPath),
            path: specialPath,
            name: "type_traits.hpp",
            directoryPath: "/tmp/allthethings-memory/project/source/gct/core",
            fileExtension: "hpp",
            sizeBytes: 1024,
            modifiedTime: 1_000_000,
            createdTime: nil,
            isDirectory: false,
            isHidden: false,
            volumeName: "Synthetic",
            normalizedName: FuzzyMatcher.normalize("type_traits.hpp"),
            normalizedPath: FuzzyMatcher.normalize(specialPath)
        )

        index.replaceRecordsForTesting(records)

        let diagnostics = index.currentDiagnostics()
        #expect(diagnostics.indexedCount == recordCount)
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.pathGramKeyCount == 0)
        #expect(diagnostics.pathGramPostingCount == 0)
        #expect(diagnostics.nameGramKeyCount > 0)
        #expect(diagnostics.nameGramPostingCount > 0)
        #expect(diagnostics.extensionKeyCount == 2)

        let typeTraitsResponse = index.search(SearchRequest(
            query: "type_trai",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(typeTraitsResponse.results.contains { $0.record.path == specialPath })

        let pathResponse = index.search(SearchRequest(
            query: "path:module-1",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(pathResponse.totalMatches > 0)

        let extensionResponse = index.search(SearchRequest(
            query: "ext:swift",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(extensionResponse.totalMatches == recordCount - 1)
    }

    @Test("path component expansion covers root base directory matches without path postings")
    func pathComponentExpansionCoversRootBaseDirectoryMatchesWithoutPathPostings() {
        let rootDirectory = "/tmp/allthethings-memory/"
            + String(repeating: "wide-directory-segment/", count: 120)
            + "aito/project"
        let hiddenPath = "/tmp/allthethings-memory/.hidden/AitoThing.swift"
        var records = [
            makeRecord(path: rootDirectory, isDirectory: true, modifiedTime: 0)
        ]

        for index in 0..<12_000 {
            records.append(makeRecord(
                path: "\(rootDirectory)/File\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(index + 1)
            ))
        }
        records.append(makeRecord(path: hiddenPath, isHidden: true, modifiedTime: 20_000))
        for index in 0..<100 {
            records.append(makeRecord(
                path: "/tmp/allthethings-memory/unrelated/Xxx\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(30_000 + index)
            ))
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records)

        let diagnostics = index.currentDiagnostics()
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.nameGramPostingCount > 0)

        let response = index.search(SearchRequest(
            query: "aito",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false
        ), maxResults: 10)

        #expect(response.usesIndexedCandidates)
        #expect(response.totalMatches == 12_001)
        #expect(response.results.contains { $0.record.path.hasPrefix(rootDirectory) })
        #expect(!response.results.contains { $0.record.path == hiddenPath })
    }

    @Test("short fuzzy path tokens use component expansion without path postings")
    func shortFuzzyPathTokensUseComponentExpansionWithoutPathPostings() {
        let rootDirectory = "/tmp/allthethings-memory/"
            + String(repeating: "wide-directory-segment/", count: 120)
        let klopfgeistDirectory = "\(rootDirectory)/Klopfgeist"
        let yellowGlowDirectory = "\(rootDirectory)/YellowGlow.funhouse"
        let longDirectory = "\(rootDirectory)/Long Vibrating Springs.patch"
        let klopfgeistChild = "\(klopfgeistDirectory)/#default.pst"
        let yellowGlowChild = "\(yellowGlowDirectory)/01B.tiff"
        let longChild = "\(longDirectory)/#Root.cst"
        var records = [
            makeRecord(path: klopfgeistDirectory, isDirectory: true, modifiedTime: 0),
            makeRecord(path: yellowGlowDirectory, isDirectory: true, modifiedTime: 1),
            makeRecord(path: longDirectory, isDirectory: true, modifiedTime: 2),
            makeRecord(path: klopfgeistChild, modifiedTime: 3),
            makeRecord(path: yellowGlowChild, modifiedTime: 4),
            makeRecord(path: longChild, modifiedTime: 5)
        ]

        for index in 0..<12_000 {
            records.append(makeRecord(
                path: "\(rootDirectory)/unrelated/File\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(10_000 + index)
            ))
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records)

        let diagnostics = index.currentDiagnostics()
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.nameGramPostingCount > 0)

        let response = index.search(SearchRequest(
            query: "log",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 20)

        #expect(response.usesIndexedCandidates)
        #expect(!response.results.contains { $0.record.path == klopfgeistChild })
        #expect(response.results.contains { $0.record.path == yellowGlowChild })
        #expect(response.results.contains { $0.record.path == longChild })
    }

    @Test("update storms are coalesced")
    func updateStormsAreCoalesced() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        var files: [URL] = []
        for offset in 0..<20 {
            let file = root.appendingPathComponent("Update\(offset).swift")
            try "old".write(to: file, atomically: true, encoding: .utf8)
            files.append(file)
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= files.count + 1
        }

        let before = index.currentDiagnostics()
        for file in files {
            try "new".write(to: file, atomically: true, encoding: .utf8)
            index.update(paths: [file.path])
        }

        try await waitUntil {
            index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches
        }

        let after = index.currentDiagnostics()
        #expect(after.completedRefreshBatches - before.completedRefreshBatches == 1)
        #expect(after.completedSnapshotRebuilds == before.completedSnapshotRebuilds)
    }

    @Test("mmap snapshot persists and reloads")
    func mmapSnapshotPersistsAndReloads() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let records = makeSyntheticRecords(count: 25)
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.currentStats().indexedCount == records.count)
        #expect(reloaded.currentDiagnostics().recordStoreKind == .mapped)
        #expect(reloaded.currentDiagnostics().mappedByteSize > 0)
        #expect(reloaded.search(SearchRequest(
            query: "File000010",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 5).results.contains { $0.record.name == "File000010.swift" })
    }

    @Test("v7 snapshots persist a virtual component namespace")
    func v7SnapshotsPersistVirtualComponentNamespace() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let records = makeCatalogRecords(count: 2_000)
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()

        #expect(diagnostics.schemaVersion == SnapshotLayout.schemaVersion)
        #expect(diagnostics.indexedCount == records.count)
        #expect(diagnostics.resultCount == records.count)
        #expect(diagnostics.virtualRowCount > 0)
        #expect(diagnostics.componentGramPostingCount > diagnostics.nameGramPostingCount)

        let response = reloaded.search(SearchRequest(
            query: "catalog",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 25)

        #expect(response.usesIndexedCandidates)
        #expect(response.totalMatches == records.count)
        #expect(response.results.count == 25)
    }

    @Test("corrupt mmap snapshots are ignored")
    func corruptMmapSnapshotsAreIgnored() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = try applicationSupportDirectory(for: applicationName)
        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let manifest = CompactSnapshotManifest(
            schemaVersion: SnapshotLayout.schemaVersion,
            savedAt: Date(),
            roots: [],
            exclusionPatterns: FileExclusionRules.defaultPatterns,
            recordCount: 1
        )
        try JSONEncoder().encode(manifest).write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.manifest))
        try Data([1, 2, 3]).write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.records))

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(index.currentStats().indexedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: packageURL.path))
    }

    @Test("primary-only snapshots are searchable while scanning")
    func primaryOnlySnapshotsAreSearchableWhileScanning() {
        let records = makeSyntheticRecords(count: 1_000)
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(
            records,
            buildsSearchStructures: false,
            phase: .scanning,
            status: "Indexing 1,000 discovered"
        )

        let stats = index.currentStats()
        #expect(stats.phase == .scanning)
        #expect(stats.isIndexing)
        #expect(stats.discoveredCount == records.count)
        #expect(stats.searchableCount == records.count)
        #expect(stats.optimizedCount == 0)
        #expect(index.currentDiagnostics().recordStoreKind == .heapPaged)
        #expect(index.currentDiagnostics().heapPageCount > 0)

        let response = index.search(SearchRequest(
            query: "File000010",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.name == "File000010.swift" })
    }

    @Test("large empty primary snapshots return bounded partial rows")
    func largeEmptyPrimarySnapshotsReturnBoundedPartialRows() {
        let records = Array(makeSyntheticRecords(count: 120_000).reversed())
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(
            records,
            buildsSearchStructures: false,
            phase: .scanning,
            status: "Indexing 120,000 discovered"
        )

        let response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true)
        ), maxResults: 25)

        #expect(response.totalMatches == records.count)
        #expect(response.results.count == 25)
        #expect(response.results.first?.record.name == "File119999.swift")
        #expect(response.results.contains { $0.record.name == "File119999.swift" })
        #expect(!response.results.contains { $0.record.name == "File000000.swift" })
    }

    @Test("primary-only and optimized snapshots return the same matches")
    func primaryOnlyAndOptimizedSnapshotsReturnSameMatches() {
        var records = makeSyntheticRecords(count: 50_000)
        let hiddenPath = "/tmp/allthethings-memory/.hidden/module/Secret500.swift"
        records.append(FileRecord(
            id: FileRecord.stableID(for: hiddenPath),
            path: hiddenPath,
            name: "Secret500.swift",
            directoryPath: "/tmp/allthethings-memory/.hidden/module",
            fileExtension: "swift",
            sizeBytes: 500,
            modifiedTime: 500_000,
            createdTime: nil,
            isDirectory: false,
            isHidden: true,
            volumeName: "Synthetic",
            normalizedName: FuzzyMatcher.normalize("Secret500.swift"),
            normalizedPath: FuzzyMatcher.normalize(hiddenPath)
        ))

        let primary = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        let optimized = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        primary.replaceRecordsForTesting(records, buildsSearchStructures: false, phase: .scanning)
        optimized.replaceRecordsForTesting(records)

        let requests = [
            SearchRequest(query: "File000010", sort: SortSpec(column: .relevance, ascending: false)),
            SearchRequest(query: "ext:swift", sort: SortSpec(column: .name, ascending: true)),
            SearchRequest(query: "path:module-1", sort: SortSpec(column: .relevance, ascending: false)),
            SearchRequest(query: "*.swift", sort: SortSpec(column: .modified, ascending: false)),
            SearchRequest(query: "Secret500", sort: SortSpec(column: .relevance, ascending: false), includeHidden: false),
            SearchRequest(query: "", sort: SortSpec(column: .modified, ascending: false))
        ]

        for request in requests {
            let primaryResponse = primary.search(request, maxResults: 25)
            let optimizedResponse = optimized.search(request, maxResults: 25)

            #expect(primaryResponse.totalMatches == optimizedResponse.totalMatches)
            #expect(primaryResponse.results.map(\.record.path) == optimizedResponse.results.map(\.record.path))
        }
    }

    @Test("index stats expose progressive phase counts")
    func indexStatsExposeProgressivePhaseCounts() {
        let records = makeSyntheticRecords(count: 100)
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )

        index.replaceRecordsForTesting(records, buildsSearchStructures: false, phase: .scanning)
        var stats = index.currentStats()
        #expect(stats.phase == .scanning)
        #expect(stats.isIndexing)
        #expect(stats.searchableCount == records.count)
        #expect(stats.optimizedCount == 0)

        index.replaceRecordsForTesting(records, buildsSearchStructures: false, phase: .saving)
        stats = index.currentStats()
        #expect(stats.phase == .saving)
        #expect(stats.isIndexing)

        index.replaceRecordsForTesting(records)
        stats = index.currentStats()
        #expect(stats.phase == .ready)
        #expect(!stats.isIndexing)
        #expect(stats.optimizedCount == records.count)
    }

    @Test("opt-in synthetic memory benchmark")
    func optInSyntheticMemoryBenchmark() {
        guard
            let rawCount = ProcessInfo.processInfo.environment["ATT_MEMORY_BENCH_RECORDS"],
            let recordCount = Int(rawCount),
            recordCount > 0
        else {
            return
        }

        let index = FileIndex(
            applicationName: "AllTheThingsMemoryBench-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(makeSyntheticRecords(count: recordCount))
        let diagnostics = index.currentDiagnostics()

        print(
            """
            ATT_MEMORY_BENCH_RECORDS=\(recordCount) \
            indexed=\(diagnostics.indexedCount) \
            pathGramIndexEnabled=\(diagnostics.pathGramIndexEnabled) \
            nameGramPostings=\(diagnostics.nameGramPostingCount)
            """
        )

        #expect(diagnostics.indexedCount == recordCount)
        if recordCount > 200_000 {
            #expect(!diagnostics.pathGramIndexEnabled)
        }
    }

    @Test("opt-in v7 mapped search benchmark")
    func optInV7MappedSearchBenchmark() {
        guard
            let rawCount = ProcessInfo.processInfo.environment["ATT_V7_SEARCH_BENCH_RECORDS"],
            let recordCount = Int(rawCount),
            recordCount > 0
        else {
            return
        }

        let index = FileIndex(
            applicationName: "AllTheThingsV7SearchBench-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        let records = makeCatalogRecords(count: recordCount)
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let threshold = (Double(ProcessInfo.processInfo.environment["ATT_V7_SEARCH_BENCH_MAX_MS"] ?? "200") ?? 200) / 1_000

        for query in ["log", "aito"] {
            let response = index.search(SearchRequest(
                query: query,
                sort: SortSpec(column: .name, ascending: true),
                includeHidden: false
            ), maxResults: 2_000)

            print(
                """
                ATT_V7_SEARCH_BENCH_RECORDS=\(recordCount) \
                query=\(query) \
                elapsed_ms=\(Int(response.elapsed * 1_000)) \
                total=\(response.totalMatches) \
                shown=\(response.results.count)
                """
            )

            #expect(response.usesIndexedCandidates)
            #expect(response.totalMatches == records.count)
            #expect(response.elapsed < threshold)
        }
    }

    private func makeSyntheticRecords(count: Int, directoryPadding: String = "") -> [FileRecord] {
        var records: [FileRecord] = []
        records.reserveCapacity(count)

        for index in 0..<count {
            let name = String(format: "File%06d.swift", index)
            let directory = "/tmp/allthethings-memory/\(directoryPadding)project-\(index % 256)/module-\((index / 256) % 512)"
            let path = "\(directory)/\(name)"
            records.append(FileRecord(
                id: FileRecord.stableID(for: path),
                path: path,
                name: name,
                directoryPath: directory,
                fileExtension: "swift",
                sizeBytes: UInt64(index % 16_384),
                modifiedTime: TimeInterval(index),
                createdTime: nil,
                isDirectory: false,
                isHidden: false,
                volumeName: "Synthetic",
                normalizedName: FuzzyMatcher.normalize(name),
                normalizedPath: FuzzyMatcher.normalize(path)
            ))
        }

        return records
    }

    private func makeCatalogRecords(count: Int) -> [FileRecord] {
        var records: [FileRecord] = []
        records.reserveCapacity(count)

        for index in 0..<count {
            let name = String(format: "File%06d.swift", index)
            let directory = "/tmp/allthethings-v7/aito/catalog-\(index % 512)/module-\((index / 512) % 512)"
            let path = "\(directory)/\(name)"
            records.append(FileRecord(
                id: FileRecord.stableID(for: path),
                path: path,
                name: name,
                directoryPath: directory,
                fileExtension: "swift",
                sizeBytes: UInt64(index % 16_384),
                modifiedTime: TimeInterval(index),
                createdTime: nil,
                isDirectory: false,
                isHidden: false,
                volumeName: "Synthetic",
                normalizedName: FuzzyMatcher.normalize(name),
                normalizedPath: FuzzyMatcher.normalize(path)
            ))
        }

        return records
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
            volumeName: "Synthetic",
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }

    private func applicationSupportDirectory(for applicationName: String) throws -> URL {
        let root = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        return root.appendingPathComponent(applicationName, isDirectory: true)
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
