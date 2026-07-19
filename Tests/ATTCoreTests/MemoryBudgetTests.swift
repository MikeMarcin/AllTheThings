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

    @Test("medium synthetic indexes qualify for path gram postings")
    func mediumSyntheticIndexesQualifyForPathGramPostings() {
        let records = makeSyntheticRecords(count: 12_000)
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

        let diagnostics = optimized.currentDiagnostics()
        #expect(diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.pathGramKeyCount > 0)
        #expect(diagnostics.pathGramPostingCount > 0)
        #expect(diagnostics.nameGramPostingCount > 0)
        #expect(diagnostics.componentGramPostingCount > 0)

        let requests = [
            SearchRequest(query: "path:module-1", sort: SortSpec(column: .name, ascending: true)),
            SearchRequest(query: "path:project-1/module-0", sort: SortSpec(column: .name, ascending: true)),
            SearchRequest(query: "File000010", sort: SortSpec(column: .name, ascending: true))
        ]

        for request in requests {
            let primaryResponse = primary.search(request, maxResults: 50)
            let optimizedResponse = optimized.search(request, maxResults: 50)

            #expect(primaryResponse.totalMatches == optimizedResponse.totalMatches)
            #expect(primaryResponse.results.map(\.record.path) == optimizedResponse.results.map(\.record.path))
        }

        let componentPathResponse = optimized.search(requests[0], maxResults: 50)
        #expect(componentPathResponse.usesIndexedCandidates)
    }

    @Test("path gram acceleration states preserve query results")
    func pathGramAccelerationStatesPreserveQueryResults() {
        let records = [
            makeRecord(path: "/tmp/allthethings-path/project/Sources/AppKit/SearchWindowController.swift", modifiedTime: 50),
            makeRecord(path: "/tmp/allthethings-path/project/Sources/AppKit/HiddenThing.swift", isHidden: true, modifiedTime: 60),
            makeRecord(path: "/tmp/allthethings-path/project/Sources/Core/FileIndex.swift", modifiedTime: 70),
            makeRecord(path: "/tmp/allthethings-path/project/Tests/FileIndexTests.swift", modifiedTime: 40),
            makeRecord(path: "/tmp/allthethings-path/project/README.md", modifiedTime: 30),
            makeRecord(path: "/tmp/allthethings-path/other/Sources/AppKit/OtherWindow.swift", modifiedTime: 20)
        ]
        let primary = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        primary.replaceRecordsForTesting(records, buildsSearchStructures: false, phase: .scanning)

        let requests = [
            SearchRequest(query: "AppKit", sort: SortSpec(column: .name, ascending: true)),
            SearchRequest(query: "path:Sources/AppKit", sort: SortSpec(column: .name, ascending: true)),
            SearchRequest(query: "project/Sources/Core", sort: SortSpec(column: .modified, ascending: false)),
            SearchRequest(query: "path:**/FileIndex*.swift", sort: SortSpec(column: .name, ascending: true)),
            SearchRequest(query: "HiddenThing", sort: SortSpec(column: .name, ascending: true), includeHidden: false),
            SearchRequest(query: "HiddenThing", sort: SortSpec(column: .modified, ascending: false), includeHidden: true)
        ]

        func assertMatchesPrimary(_ index: FileIndex) {
            for request in requests {
                let expected = primary.search(request, maxResults: 20)
                let actual = index.search(request, maxResults: 20)
                #expect(actual.totalMatches == expected.totalMatches)
                #expect(actual.results.map(\.record.path) == expected.results.map(\.record.path))
            }
        }

        let noShards = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        noShards.replaceRecordsForTesting(records)
        noShards.removePathGramAccelerationForTesting()
        #expect(!noShards.currentDiagnostics().pathGramIndexEnabled)
        #expect(noShards.currentDiagnostics().pathGramCoveredRowCount == 0)
        assertMatchesPrimary(noShards)

        let oneShard = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        oneShard.replaceRecordsForTesting(records)
        oneShard.removePathGramAccelerationForTesting()
        oneShard.addPathGramShardForTesting(range: 0..<2)
        #expect(!oneShard.currentDiagnostics().pathGramIndexEnabled)
        #expect(oneShard.currentDiagnostics().pathGramCoveredRowCount == 2)
        assertMatchesPrimary(oneShard)

        let multipleShards = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        multipleShards.replaceRecordsForTesting(records)
        multipleShards.removePathGramAccelerationForTesting()
        multipleShards.addPathGramShardForTesting(range: 0..<2)
        multipleShards.addPathGramShardForTesting(range: 4..<6)
        #expect(!multipleShards.currentDiagnostics().pathGramIndexEnabled)
        #expect(multipleShards.currentDiagnostics().pathGramCoveredRowCount == 4)
        assertMatchesPrimary(multipleShards)

        let completeSidecar = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        completeSidecar.replaceRecordsForTesting(records)
        completeSidecar.removePathGramAccelerationForTesting()
        completeSidecar.completePathGramIndexForTesting()
        #expect(completeSidecar.currentDiagnostics().pathGramIndexEnabled)
        #expect(completeSidecar.currentDiagnostics().pathGramCoveredRowCount == records.count)
        assertMatchesPrimary(completeSidecar)
    }

    @Test("structural snapshot changes discard partial path gram shards")
    func structuralSnapshotChangesDiscardPartialPathGramShards() {
        var records = makeSyntheticRecords(count: 32)
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records)
        index.removePathGramAccelerationForTesting()
        index.addPathGramShardForTesting(range: 0..<16)
        #expect(index.currentDiagnostics().pathGramCoveredRowCount == 16)

        let addedPath = "/tmp/allthethings-memory/project-new/module-new/Added.swift"
        records.append(FileRecord(
            id: FileRecord.stableID(for: addedPath),
            path: addedPath,
            name: "Added.swift",
            directoryPath: "/tmp/allthethings-memory/project-new/module-new",
            fileExtension: "swift",
            sizeBytes: 12,
            modifiedTime: 42,
            createdTime: nil,
            isDirectory: false,
            isHidden: false,
            volumeName: "Synthetic",
            normalizedName: FuzzyMatcher.normalize("Added.swift"),
            normalizedPath: FuzzyMatcher.normalize(addedPath)
        ))
        index.replaceRecordsForTesting(records, buildsSearchStructures: false, phase: .scanning)

        let diagnostics = index.currentDiagnostics()
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.pathGramCoveredRowCount == 0)
        #expect(index.search(SearchRequest(
            query: "path:project-new/module-new",
            sort: SortSpec(column: .name, ascending: true)
        ), maxResults: 10).results.map(\.record.path) == [addedPath])
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
            let diagnostics = index.currentDiagnostics()
            return !stats.isIndexing
                && stats.indexedCount >= files.count + 1
                && diagnostics.completedSnapshotRebuilds > 0
        }

        let before = index.currentDiagnostics()
        for file in files {
            try "new".write(to: file, atomically: true, encoding: .utf8)
            index.update(paths: [file.path])
        }

        try await waitUntil(timeout: .seconds(15)) {
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

    @Test("package row preparation shares ancestor work across records")
    func packageRowPreparationSharesAncestorWorkAcrossRecords() {
        let recordCount = 10_000
        let root = "/tmp/allthethings-package-work"
        let directory = "\(root)/shared/deep"
        let records = (0..<recordCount).map { index in
            makeRecord(path: "\(directory)/File\(index).swift")
        }

        let diagnostics = MappedRecordStore.packageRowPreparationDiagnosticsForTesting(
            records: records,
            roots: [root]
        )

        #expect(diagnostics.sourceRecordCount == recordCount)
        #expect(diagnostics.resultRowCount == recordCount)
        #expect(diagnostics.virtualRowCount == 4)
        #expect(diagnostics.ancestorPathProbeCount == 5)
    }

    @Test("optimized package row preparation preserves virtual depth-first layout")
    func optimizedPackageRowPreparationPreservesVirtualDepthFirstLayout() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThings-PackageRows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let root = "/workspace/project"
        let records = [
            makeRecord(path: root, isDirectory: true),
            makeRecord(path: "\(root)/zeta/Z.txt"),
            makeRecord(path: "\(root)/alpha", isDirectory: true),
            makeRecord(path: "\(root)/alpha/A.txt")
        ]
        try MappedRecordStore.writePackage(
            records: records,
            roots: [root],
            exclusionPatterns: [],
            packageURL: packageURL
        )

        let store = try MappedRecordStore(packageURL: packageURL)
        #expect((0..<store.count).map { store.path(at: $0) } == [
            "/workspace",
            "/workspace/project",
            "/workspace/project/alpha",
            "/workspace/project/alpha/A.txt",
            "/workspace/project/zeta",
            "/workspace/project/zeta/Z.txt"
        ])
        #expect((0..<store.count).map { store.isVirtual(at: $0) } == [true, false, false, false, true, false])
        #expect(store.storedResultCount == records.count)
        #expect(store.parentRowID(at: 3) == 2)
        #expect(store.subtreeEnd(at: 0) == store.count)
        #expect(store.subtreeEnd(at: 2) == 4)
    }

    @Test("mapped and overlay path lookup avoids path materialization")
    func mappedAndOverlayPathLookupAvoidsPathMaterialization() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThings-PathLookup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let root = "/tmp/allthethings-path-lookup"
        let unicodeDirectory = "\(root)/Café 😺".decomposedStringWithCanonicalMapping
        let unicodeFile = "\(unicodeDirectory)/résumé.swift".decomposedStringWithCanonicalMapping
        let sibling = "\(root)/Sibling.txt"
        let records = [
            makeRecord(path: root, isDirectory: true),
            makeRecord(path: unicodeDirectory, isDirectory: true),
            makeRecord(path: unicodeFile),
            makeRecord(path: sibling)
        ]
        try MappedRecordStore.writePackage(
            records: records,
            roots: [root],
            exclusionPatterns: [],
            packageURL: packageURL
        )

        let mapped = try MappedRecordStore(packageURL: packageURL)
        #expect(mapped.pathMaterializationCountForTesting == 0)
        for path in records.map(\.path) {
            #expect(mapped.rowID(forPath: path) != nil)
        }
        #expect(mapped.rowID(forPath: "\(unicodeDirectory)/resume.swift") == nil)
        #expect(mapped.rowID(forPath: unicodeFile + "/") == nil)
        #expect(mapped.rowID(forPath: "\(root)/Missing.txt") == nil)
        #expect(mapped.pathMaterializationCountForTesting == 0)

        let deletedRow = try #require(mapped.rowID(forPath: sibling))
        let added = makeRecord(path: "\(root)/Added.txt")
        let overlay = OverlayRecordStore(base: mapped, upserts: [added], deletedRows: [deletedRow])
        let materializedBeforeOverlayLookups = mapped.pathMaterializationCountForTesting

        #expect(overlay.rowID(forPath: unicodeFile) != nil)
        #expect(overlay.rowID(forPath: sibling) == nil)
        #expect(overlay.rowID(forPath: added.path) != nil)
        #expect(overlay.rowID(forPath: "\(root)/Still-Missing.txt") == nil)
        #expect(mapped.pathMaterializationCountForTesting == materializedBeforeOverlayLookups)
    }

    @Test("subtree cursors enumerate mapped overlay replacing and heap stores in bounded batches")
    func subtreeCursorsEnumerateEveryStoreKindInBoundedBatches() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThings-SubtreeCursor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let root = "/tmp/allthethings-subtree-cursor/project"
        let deletedPath = "\(root)/Deleted.txt"
        let existingPath = "\(root)/Sources/Existing.swift"
        let outsidePath = "/tmp/allthethings-subtree-cursor/Outside.txt"
        let records = [
            makeRecord(path: root, isDirectory: true),
            makeRecord(path: "\(root)/Sources", isDirectory: true),
            makeRecord(path: existingPath),
            makeRecord(path: deletedPath),
            makeRecord(path: outsidePath)
        ]
        try MappedRecordStore.writePackage(
            records: records,
            roots: ["/tmp/allthethings-subtree-cursor"],
            exclusionPatterns: [],
            packageURL: packageURL
        )

        let mapped = try MappedRecordStore(packageURL: packageURL)
        var mappedCursor = mapped.makeSubtreeRowCursor(atPath: root)
        var mappedRows: [Int] = []
        var mappedBatchCount = 0
        while let batch = mappedCursor.nextBatch(maximumVisitedRows: 2) {
            #expect(batch.rowRange.count <= 2)
            #expect(batch.includesEveryRow)
            mappedBatchCount += 1
            batch.forEachMatchingRow { mappedRows.append($0) }
        }
        #expect(mappedBatchCount > 1)
        #expect(mappedCursor.isComplete)
        #expect(mapped.pathMaterializationCountForTesting == 0)
        #expect(Set(mappedRows.map { mapped.path(at: $0) }) == [
            root,
            "\(root)/Sources",
            existingPath,
            deletedPath
        ])

        let existingRow = try #require(mapped.rowID(forPath: existingPath))
        let replacement = makeRecord(path: existingPath, modifiedTime: 42)
        let replacing = ReplacingRecordStore(base: mapped, replacements: [existingRow: replacement])
        let materializedBeforeReplacingCursor = mapped.pathMaterializationCountForTesting
        var replacingCursor = replacing.makeSubtreeRowCursor(atPath: root)
        var replacingRows: [Int] = []
        while let batch = replacingCursor.nextBatch(maximumVisitedRows: 3) {
            #expect(batch.includesEveryRow)
            batch.forEachMatchingRow { replacingRows.append($0) }
        }
        #expect(replacingRows == mappedRows)
        #expect(mapped.pathMaterializationCountForTesting == materializedBeforeReplacingCursor)

        let deletedRow = try #require(mapped.rowID(forPath: deletedPath))
        let newPath = "\(root)/Sources/New.swift"
        let similarPrefixPath = "\(root)-peer/Not-A-Descendant.swift"
        let overlay = OverlayRecordStore(
            base: mapped,
            upserts: [
                makeRecord(path: root, isDirectory: true, modifiedTime: 43),
                makeRecord(path: newPath),
                makeRecord(path: similarPrefixPath)
            ],
            deletedRows: [deletedRow]
        )
        let materializedBeforeOverlayCursor = mapped.pathMaterializationCountForTesting
        var overlayCursor = overlay.makeSubtreeRowCursor(atPath: root)
        var overlayRows: [Int] = []
        while let batch = overlayCursor.nextBatch(maximumVisitedRows: 2) {
            #expect(batch.rowRange.count <= 2)
            #expect(batch.includesEveryRow)
            batch.forEachMatchingRow { overlayRows.append($0) }
        }
        #expect(mapped.pathMaterializationCountForTesting == materializedBeforeOverlayCursor)
        #expect(Set(overlayRows.map { overlay.path(at: $0) }) == [
            root,
            "\(root)/Sources",
            existingPath,
            newPath
        ])

        let heap = HeapPagedRecordStore(records: [
            makeRecord(path: outsidePath),
            makeRecord(path: existingPath),
            makeRecord(path: root, isDirectory: true),
            makeRecord(path: similarPrefixPath),
            makeRecord(path: "\(root)/Sources", isDirectory: true)
        ])
        var heapCursor = heap.makeSubtreeRowCursor(atPath: root)
        var heapRows: [Int] = []
        var visitedRowCount = 0
        while let batch = heapCursor.nextBatch(maximumVisitedRows: 2) {
            #expect(batch.rowRange.count <= 2)
            #expect(!batch.includesEveryRow)
            visitedRowCount += batch.rowRange.count
            batch.forEachMatchingRow { heapRows.append($0) }
        }
        #expect(visitedRowCount == heap.count)
        #expect(Set(heapRows.map { heap.path(at: $0) }) == [
            root,
            "\(root)/Sources",
            existingPath
        ])
    }

    @Test("subtree cursor retains its immutable store")
    func subtreeCursorRetainsItsStore() {
        var heap: HeapPagedRecordStore? = HeapPagedRecordStore(records: [
            makeRecord(path: "/tmp/allthethings-retained-cursor", isDirectory: true)
        ])
        weak var retainedStore = heap
        var cursor = heap?.makeSubtreeRowCursor(atPath: "/tmp/allthethings-retained-cursor")

        heap = nil
        #expect(retainedStore != nil)
        #expect(cursor?.nextBatch(maximumVisitedRows: 1)?.rowRange.count == 1)
        cursor = nil
        #expect(retainedStore == nil)
    }

    @Test("snapshots share name and virtual component postings")
    func snapshotsShareNameAndVirtualComponentPostings() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = try applicationSupportDirectory(for: applicationName)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let records = makeCatalogRecords(count: 2_000)
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        let namePostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.namePostings)
        let legacyComponentPostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings)
        let componentSupplementURL = packageURL.appendingPathComponent(
            SnapshotLayout.FileName.componentSupplementPostings
        )
        let fileManager = FileManager.default
        let nameByteCount = try fileSize(at: namePostingsURL, fileManager: fileManager)
        let legacyComponentByteCount = try fileSize(at: legacyComponentPostingsURL, fileManager: fileManager)

        #expect(nameByteCount > 0)
        #expect(legacyComponentByteCount == 0)
        #expect(try fileSize(at: componentSupplementURL, fileManager: fileManager) == 0)

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()

        #expect(diagnostics.schemaVersion == SnapshotLayout.schemaVersion)
        #expect(diagnostics.indexedCount == records.count)
        #expect(diagnostics.resultCount == records.count)
        #expect(diagnostics.virtualRowCount > 0)
        #expect(diagnostics.componentGramPostingCount == diagnostics.nameGramPostingCount)

        let response = reloaded.search(SearchRequest(
            query: "catalog",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 25)

        #expect(response.usesIndexedCandidates)
        #expect(response.totalMatches == records.count)
        #expect(response.results.count == 25)
    }

    @Test("legacy combined component postings remain searchable")
    func legacyCombinedComponentPostingsRemainSearchable() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = try applicationSupportDirectory(for: applicationName)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let records = makeCatalogRecords(count: 1_000)
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let fileManager = FileManager.default
        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        let store = try MappedRecordStore(packageURL: packageURL)
        var combinedPostingMap: [Int: [Int32]] = [:]
        var keys = Set<Int>()
        for rowID in 0..<store.count {
            keys.removeAll(keepingCapacity: true)
            collectSearchGramKeysForTesting(from: store.normalizedName(at: rowID), into: &keys)
            for key in keys {
                combinedPostingMap[key, default: []].append(Int32(rowID))
            }
        }
        let builtCombinedIndex = try MappedIntPostingIndex.build(
            from: combinedPostingMap,
            temporaryName: "att-legacy-component-postings-test"
        )
        let combinedIndex = try #require(builtCombinedIndex)
        try combinedIndex.write(
            to: packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings)
        )
        let supplementURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.componentSupplementPostings)
        if fileManager.fileExists(atPath: supplementURL.path) {
            try fileManager.removeItem(at: supplementURL)
        }

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let ancestorResponse = reloaded.search(SearchRequest(
            query: "catalog",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 25)
        let nameResponse = reloaded.search(SearchRequest(
            query: "File000123",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false
        ), maxResults: 25)

        #expect(ancestorResponse.usesIndexedCandidates)
        #expect(ancestorResponse.totalMatches == records.count)
        #expect(nameResponse.results.contains { $0.record.name == "File000123.swift" })
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

    @Test("large empty optimized snapshots honor name sort order")
    func largeEmptyOptimizedSnapshotsHonorNameSortOrder() {
        let records = Array(makeSyntheticRecords(
            count: 120_000,
            directoryPadding: String(repeating: "x", count: 220)
        ).reversed())
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records)

        let diagnostics = index.currentDiagnostics()
        #expect(diagnostics.indexedCount == records.count)
        #expect(diagnostics.optimizedCount == records.count)
        #expect(!diagnostics.pathGramIndexEnabled)

        let modifiedPreview = index.search(SearchRequest(
            query: "File",
            sort: SortSpec(column: .modified, ascending: false),
            mode: .interactivePreview
        ), maxResults: 25)
        #expect(modifiedPreview.totalMatches == 25)
        #expect(modifiedPreview.results.count == 25)
        #expect(modifiedPreview.results.first?.record.name == "File119999.swift")
        #expect(modifiedPreview.results.last?.record.name == "File119975.swift")
        #expect(modifiedPreview.executionProfile.scannedRowCount <= 25)

        let ascending = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true)
        ), maxResults: 25)
        #expect(ascending.totalMatches == records.count)
        #expect(ascending.results.count == 25)
        #expect(ascending.results.first?.record.name == "File000000.swift")
        #expect(ascending.results.last?.record.name == "File000024.swift")

        let descending = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: false)
        ), maxResults: 25)
        #expect(descending.totalMatches == records.count)
        #expect(descending.results.count == 25)
        #expect(descending.results.first?.record.name == "File119999.swift")
        #expect(descending.results.last?.record.name == "File119975.swift")
    }

    @Test("large mapped modified previews use name postings without path postings")
    func largeMappedModifiedPreviewsUseNamePostingsWithoutPathPostings() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let recordCount = 30_000
        let directoryPadding = String(repeating: "x", count: 900)
        let records = (0..<recordCount).map { index in
            makeRecord(
                path: "/tmp/allthethings-memory/\(directoryPadding)project-\(index % 256)/TestFile\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(index)
            )
        }

        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        #expect(!index.currentDiagnostics().pathGramIndexEnabled)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()
        #expect(diagnostics.recordStoreKind == .mapped)
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.nameGramPostingCount > 0)

        let response = reloaded.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 25)

        let expectedNames = (0..<25).map { offset in
            String(format: "TestFile%06d.swift", recordCount - offset - 1)
        }
        #expect(response.results.map(\.record.name) == expectedNames)
        #expect(response.totalMatches == 25)
        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(response.executionProfile.indexesUsed.contains(.modifiedOrder))
        #expect(!response.executionProfile.indexesUsed.contains(.pathGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.scannedRowCount <= 25)
    }

    @Test("large mapped relevance previews return ranked name matches without path postings")
    func largeMappedRelevancePreviewsReturnRankedNameMatchesWithoutPathPostings() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let recordCount = 30_000
        let directoryPadding = String(repeating: "x", count: 900)
        let records = (0..<recordCount).map { index in
            makeRecord(
                path: "/tmp/allthethings-memory/\(directoryPadding)project-\(index % 256)/test-\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(recordCount - index)
            )
        }

        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        #expect(!index.currentDiagnostics().pathGramIndexEnabled)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()
        #expect(diagnostics.recordStoreKind == .mapped)
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.nameGramPostingCount > 0)

        let response = reloaded.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 25)

        let expectedNames = (0..<25).map { index in
            String(format: "test-%06d.swift", index)
        }
        #expect(response.results.map(\.record.name) == expectedNames)
        #expect(response.totalMatches == 25)
        #expect(response.results.count == 25)
        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(!response.executionProfile.indexesUsed.contains(.pathGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.candidateCount == 25)
        #expect(response.executionProfile.scannedRowCount == 25)
    }

    @Test("large mapped relevance previews return partial ranked name matches")
    func largeMappedRelevancePreviewsReturnPartialRankedNameMatches() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let recordCount = 30_000
        let matchingRows = 75
        let directoryPadding = String(repeating: "x", count: 900)
        let records = (0..<recordCount).map { index in
            let name = index < matchingRows
                ? "search-\(String(format: "%06d", index)).swift"
                : "other-\(String(format: "%06d", index)).swift"
            return makeRecord(
                path: "/tmp/allthethings-memory/\(directoryPadding)search-root-\(index % 256)/\(name)",
                modifiedTime: TimeInterval(index)
            )
        }

        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        #expect(!index.currentDiagnostics().pathGramIndexEnabled)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.currentDiagnostics().recordStoreKind == .mapped)
        #expect(!reloaded.currentDiagnostics().pathGramIndexEnabled)

        let response = reloaded.search(SearchRequest(
            query: "search",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 200)

        #expect(response.results.count == matchingRows)
        #expect(response.totalMatches == matchingRows)
        #expect(response.results.first?.record.name == "search-000000.swift")
        #expect(response.results.last?.record.name == "search-000074.swift")
        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(!response.executionProfile.indexesUsed.contains(.pathGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.scannedRowCount <= recordCount + matchingRows)
    }

    @Test("large mapped name previews return partial ranked name matches")
    func largeMappedNamePreviewsReturnPartialRankedNameMatches() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let recordCount = 30_000
        let matchingRows = 75
        let directoryPadding = String(repeating: "x", count: 900)
        let records = (0..<recordCount).map { index in
            let name = index < matchingRows
                ? "search-\(String(format: "%06d", index)).swift"
                : "other-\(String(format: "%06d", index)).swift"
            return makeRecord(
                path: "/tmp/allthethings-memory/\(directoryPadding)search-root-\(index % 256)/\(name)",
                modifiedTime: TimeInterval(index)
            )
        }

        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        #expect(!index.currentDiagnostics().pathGramIndexEnabled)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.currentDiagnostics().recordStoreKind == .mapped)
        #expect(!reloaded.currentDiagnostics().pathGramIndexEnabled)

        let response = reloaded.search(SearchRequest(
            query: "search",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 200)

        #expect(response.results.count == matchingRows)
        #expect(response.totalMatches == matchingRows)
        #expect(response.results.first?.record.name == "search-000000.swift")
        #expect(response.results.last?.record.name == "search-000074.swift")
        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(!response.executionProfile.indexesUsed.contains(.pathGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.scannedRowCount <= recordCount + matchingRows)
    }

    @Test("large relevance previews do not fall back while waiting for name postings")
    func largeRelevancePreviewsDoNotFallBackWhileWaitingForNamePostings() {
        let recordCount = 40_000
        let matchingRows = 100
        let records = (0..<recordCount).map { index in
            let name = index < matchingRows
                ? "test-\(String(format: "%06d", index)).swift"
                : "other-\(String(format: "%06d", index)).swift"
            return makeRecord(
                path: "/tmp/allthethings-memory/relevance-preview/\(index % 256)/\(name)",
                modifiedTime: TimeInterval(index)
            )
        }
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records, buildsSearchStructures: false)
        #expect(index.currentDiagnostics().nameGramPostingCount == 0)

        let response = index.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 25)

        #expect(response.results.count == 25)
        #expect(response.totalMatches == matchingRows)
        #expect(response.results.first?.record.name == "test-000000.swift")
        #expect(!response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(!response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.scannedRowCount == recordCount)
    }

    @Test("large modified previews do not fall back while waiting for name postings")
    func largeModifiedPreviewsDoNotFallBackWhileWaitingForNamePostings() {
        let recordCount = 40_000
        let skippedRecentRows = 12_000
        let matchingRows = 50
        let records = (0..<recordCount).map { index in
            let descendingOffset = recordCount - index - 1
            let name = (skippedRecentRows..<(skippedRecentRows + matchingRows)).contains(descendingOffset)
                ? "test-\(String(format: "%06d", index))"
                : "other-\(String(format: "%06d", index))"
            return makeRecord(
                path: "/tmp/allthethings-memory/post-reconcile/\(name).swift",
                modifiedTime: TimeInterval(index)
            )
        }
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records, buildsSearchStructures: false)

        let warmup = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .modified, ascending: false)
        ), maxResults: 25)
        #expect(warmup.executionProfile.executionPath == .emptyQuerySortedOrder)
        #expect(index.currentDiagnostics().nameGramPostingCount == 0)

        let response = index.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 25)

        #expect(response.results.count == 25)
        #expect(response.totalMatches == 25)
        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.modifiedOrder))
        #expect(!response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.scannedRowCount < recordCount)
    }

    @Test("large name previews use promoted name order without name postings")
    func largeNamePreviewsUsePromotedNameOrderWithoutNamePostings() {
        let recordCount = 40_000
        let matchingRows = 100
        let records = (0..<recordCount).map { index in
            let name = index < matchingRows
                ? "test-\(String(format: "%06d", index)).swift"
                : "other-\(String(format: "%06d", index)).swift"
            return makeRecord(
                path: "/tmp/allthethings-memory/name-preview/\(index % 256)/\(name)",
                modifiedTime: TimeInterval(index)
            )
        }
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records, buildsSearchStructures: false)

        let warmup = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: false)
        ), maxResults: 25)
        #expect(warmup.executionProfile.executionPath == .emptyQuerySortedOrder)
        #expect(index.currentDiagnostics().nameGramPostingCount == 0)

        let response = index.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .name, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 25)

        let expectedNames = (0..<25).map { offset in
            String(format: "test-%06d.swift", matchingRows - offset - 1)
        }
        #expect(response.results.map(\.record.name) == expectedNames)
        #expect(response.totalMatches == 25)
        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(!response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.scannedRowCount < recordCount)
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

    private func fileSize(at url: URL, fileManager: FileManager) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try #require((attributes[.size] as? NSNumber)?.intValue)
    }

    private func collectSearchGramKeysForTesting(from text: String, into keys: inout Set<Int>) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }

        for length in 1...min(3, bytes.count) {
            for start in 0...(bytes.count - length) {
                var key = length << 24
                for offset in 0..<length {
                    key |= Int(bytes[start + offset]) << ((2 - offset) * 8)
                }
                keys.insert(key)
            }
        }
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
