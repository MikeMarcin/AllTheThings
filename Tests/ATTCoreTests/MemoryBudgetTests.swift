@testable import ATTCore
import Foundation
import Testing

@Suite("Memory budget")
struct MemoryBudgetTests {
    @Test("large synthetic indexes disable full path gram postings")
    func largeSyntheticIndexesDisableFullPathGramPostings() {
        let recordCount = 100_000
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        var records = makeSyntheticRecords(count: recordCount)
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

    @Test("old streaming snapshots are ignored")
    func oldStreamingSnapshotsAreIgnored() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = try applicationSupportDirectory(for: applicationName)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let snapshotURL = supportDirectory.appendingPathComponent("filename-index-v2.jsonl")
        let staleHeader = """
        {"schemaVersion":2,"savedAt":0,"roots":[],"exclusionPatterns":[],"recordCount":1}

        """
        try staleHeader.write(to: snapshotURL, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(index.currentStats().indexedCount == 0)
        #expect(index.search(SearchRequest(
            query: "type_trai",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.isEmpty)
    }

    @Test("refresh storms are coalesced")
    func refreshStormsAreCoalesced() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        var files: [URL] = []
        for offset in 0..<20 {
            let file = root.appendingPathComponent("Refresh\(offset).swift")
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
            index.refresh(paths: [file.path])
        }

        try await waitUntil {
            index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches
        }

        let after = index.currentDiagnostics()
        #expect(after.completedRefreshBatches - before.completedRefreshBatches == 1)
        #expect(after.completedSnapshotRebuilds == before.completedSnapshotRebuilds)
    }

    @Test("streaming snapshot persists and reloads")
    func streamingSnapshotPersistsAndReloads() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let records = makeSyntheticRecords(count: 25)
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.currentStats().indexedCount == records.count)
        #expect(reloaded.search(SearchRequest(
            query: "File000010",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 5).results.contains { $0.record.name == "File000010.swift" })
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
        if recordCount > 75_000 {
            #expect(!diagnostics.pathGramIndexEnabled)
        }
    }

    private func makeSyntheticRecords(count: Int) -> [FileRecord] {
        var records: [FileRecord] = []
        records.reserveCapacity(count)

        for index in 0..<count {
            let name = String(format: "File%06d.swift", index)
            let directory = "/tmp/allthethings-memory/project-\(index % 256)/module-\((index / 256) % 512)"
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
