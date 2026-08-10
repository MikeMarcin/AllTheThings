@_spi(ATTInternal) @testable import ATTCore
import Darwin
import Foundation
import Testing

@Suite("File index", .serialized)
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

    @Test("scans traversal-only directories without indexing pruned siblings")
    func scansTraversalOnlyDirectoriesWithoutIndexingPrunedSiblings() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        let vendorDirectory = root.appendingPathComponent("Vendor", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)
        let included = sourceDirectory.appendingPathComponent("App.swift")
        let prunedFile = sourceDirectory.appendingPathComponent("README.md")
        let prunedDirectoryFile = vendorDirectory.appendingPathComponent("Library.swift")
        try "included".write(to: included, atomically: true, encoding: .utf8)
        try "pruned".write(to: prunedFile, atomically: true, encoding: .utf8)
        try "vendor".write(to: prunedDirectoryFile, atomically: true, encoding: .utf8)

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            exclusionPatterns: [
                "*",
                "!*/",
                "!*.swift",
                "Vendor/"
            ]
        )
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            !index.currentStats().isIndexing
        }

        #expect(searchPaths(in: index, query: "App.swift").contains(included.path))
        #expect(!searchPaths(in: index, query: "README.md").contains(prunedFile.path))
        #expect(!searchPaths(in: index, query: "Library.swift").contains(prunedDirectoryFile.path))
        #expect(!searchPaths(in: index, query: "Sources").contains(sourceDirectory.path))
    }

    @Test("scoped update traverses excluded parents with explicit re-includes")
    func scopedUpdateTraversesExcludedParentsWithExplicitReIncludes() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            exclusionPatterns: [
                "*",
                "!*/",
                "Generated/",
                "!Generated/Keep.swift"
            ]
        )
        index.replaceRootsAndRebuild([root])
        try await waitUntil {
            !index.currentStats().isIndexing
        }

        let generatedDirectory = root.appendingPathComponent("Generated", isDirectory: true)
        try fileManager.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        let kept = generatedDirectory.appendingPathComponent("Keep.swift")
        let dropped = generatedDirectory.appendingPathComponent("Drop.swift")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "dropped".write(to: dropped, atomically: true, encoding: .utf8)
        index.update(paths: [generatedDirectory.path])

        try await waitUntil {
            searchPaths(in: index, query: "Keep.swift").contains(kept.path)
        }
        #expect(!searchPaths(in: index, query: "Drop.swift").contains(dropped.path))
        #expect(!searchPaths(in: index, query: "Generated").contains(generatedDirectory.path))
    }

    @Test("default git rules index useful git files only")
    func defaultGitRulesIndexUsefulGitFilesOnly() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let hooksDirectory = gitDirectory.appendingPathComponent("hooks", isDirectory: true)
        let infoDirectory = gitDirectory.appendingPathComponent("info", isDirectory: true)
        let refsDirectory = gitDirectory.appendingPathComponent("refs/heads", isDirectory: true)
        let objectsDirectory = gitDirectory.appendingPathComponent("objects/ab", isDirectory: true)
        try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: refsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let config = gitDirectory.appendingPathComponent("config")
        let hook = hooksDirectory.appendingPathComponent("pre-commit")
        let infoExclude = infoDirectory.appendingPathComponent("exclude")
        let fetchHead = gitDirectory.appendingPathComponent("FETCH_HEAD")
        let ref = refsDirectory.appendingPathComponent("main")
        let object = objectsDirectory.appendingPathComponent("cdef")
        try "config".write(to: config, atomically: true, encoding: .utf8)
        try "hook".write(to: hook, atomically: true, encoding: .utf8)
        try "exclude".write(to: infoExclude, atomically: true, encoding: .utf8)
        try "fetch".write(to: fetchHead, atomically: true, encoding: .utf8)
        try "ref".write(to: ref, atomically: true, encoding: .utf8)
        try "object".write(to: object, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            !index.currentStats().isIndexing
        }

        #expect(searchPaths(in: index, query: "config", includeHidden: true).contains(config.path))
        #expect(searchPaths(in: index, query: "pre-commit", includeHidden: true).contains(hook.path))
        #expect(searchPaths(in: index, query: "exclude", includeHidden: true).contains(infoExclude.path))
        #expect(!searchPaths(in: index, query: "FETCH_HEAD", includeHidden: true).contains(fetchHead.path))
        #expect(!searchPaths(in: index, query: "main", includeHidden: true).contains(ref.path))
        #expect(!searchPaths(in: index, query: "cdef", includeHidden: true).contains(object.path))
    }

    @Test("compiled exclusion mode matches legacy full rebuild paths")
    func compiledExclusionModeMatchesLegacyFullRebuildPaths() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        let gitHooksDirectory = root.appendingPathComponent(".git/hooks", isDirectory: true)
        let gitObjectsDirectory = root.appendingPathComponent(".git/objects/ab", isDirectory: true)
        let nodeModuleDirectory = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent(".cache/build", isDirectory: true)
        let nestedRoot = root.appendingPathComponent("NestedRoot", isDirectory: true)
        let nestedSourceDirectory = nestedRoot.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitHooksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitObjectsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeModuleDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nestedSourceDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let appSource = sourceDirectory.appendingPathComponent("App.swift")
        let appReadme = sourceDirectory.appendingPathComponent("README.md")
        let gitConfig = root.appendingPathComponent(".git/config")
        let gitHook = gitHooksDirectory.appendingPathComponent("pre-commit")
        let gitObject = gitObjectsDirectory.appendingPathComponent("cdef")
        let nodeModuleFile = nodeModuleDirectory.appendingPathComponent("Skipped.js")
        let cacheFile = cacheDirectory.appendingPathComponent("Cache.db")
        let nestedSource = nestedSourceDirectory.appendingPathComponent("Nested.swift")
        try "app".write(to: appSource, atomically: true, encoding: .utf8)
        try "readme".write(to: appReadme, atomically: true, encoding: .utf8)
        try "config".write(to: gitConfig, atomically: true, encoding: .utf8)
        try "hook".write(to: gitHook, atomically: true, encoding: .utf8)
        try "object".write(to: gitObject, atomically: true, encoding: .utf8)
        try "module".write(to: nodeModuleFile, atomically: true, encoding: .utf8)
        try "cache".write(to: cacheFile, atomically: true, encoding: .utf8)
        try "nested".write(to: nestedSource, atomically: true, encoding: .utf8)

        let roots = [root, nestedRoot]
        let legacyPaths = try await indexedPaths(
            roots: roots,
            mode: .legacyRules,
            applicationName: "AllTheThingsTests-\(UUID().uuidString)"
        )
        let compiledPaths = try await indexedPaths(
            roots: roots,
            mode: .compiledQuery,
            applicationName: "AllTheThingsTests-\(UUID().uuidString)"
        )

        #expect(compiledPaths == legacyPaths)
        #expect(compiledPaths.contains(appSource.path))
        #expect(compiledPaths.contains(appReadme.path))
        #expect(compiledPaths.contains(gitConfig.path))
        #expect(compiledPaths.contains(gitHook.path))
        #expect(compiledPaths.contains(nestedSource.path))
        #expect(!compiledPaths.contains(gitObject.path))
        #expect(!compiledPaths.contains(nodeModuleFile.path))
        #expect(!compiledPaths.contains(cacheFile.path))
    }

    @Test("full rebuild retries transient filesystem lookups")
    func fullRebuildRetriesTransientFileSystemLookup() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let file = root.appendingPathComponent("Transient.swift")
        try "transient".write(to: file, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.failNextFileSystemLookupsForTesting(path: file.path)
        index.replaceRootsAndRebuild([root], mode: .fresh)

        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        #expect(index.currentStats().phase == .ready)
        #expect(allIndexedPaths(in: index).contains(file.path))
    }

    @Test("full rebuild fails instead of publishing a partial snapshot after exhausted lookup retries")
    func fullRebuildDoesNotCompleteAfterExhaustedFileSystemLookupRetries() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let file = root.appendingPathComponent("Unreadable.swift")
        try "unreadable".write(to: file, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.failNextFileSystemLookupsForTesting(path: file.path, count: 10)
        index.replaceRootsAndRebuild([root], mode: .fresh)

        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        #expect(index.currentStats().phase == .failed)
        #expect(!allIndexedPaths(in: index).contains(file.path))
    }

    @Test("compiled exclusion mode matches legacy scoped update paths")
    func compiledExclusionModeMatchesLegacyScopedUpdatePaths() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let patterns = [
            "*",
            "!*/",
            "Generated/",
            "!Generated/Keep.swift"
        ]
        let legacyAppName = "AllTheThingsTests-\(UUID().uuidString)"
        let compiledAppName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: legacyAppName))
            try? fileManager.removeItem(at: supportDirectory(applicationName: compiledAppName))
        }

        let legacyIndex = FileIndex(
            applicationName: legacyAppName,
            loadsSnapshotImmediately: false,
            exclusionPatterns: patterns
        )
        legacyIndex.setExclusionEvaluationModeForTesting(.legacyRules)
        let compiledIndex = FileIndex(
            applicationName: compiledAppName,
            loadsSnapshotImmediately: false,
            exclusionPatterns: patterns
        )
        compiledIndex.setExclusionEvaluationModeForTesting(.compiledQuery)

        legacyIndex.replaceRootsAndRebuild([root], mode: .fresh)
        compiledIndex.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            !legacyIndex.currentStats().isIndexing && !compiledIndex.currentStats().isIndexing
        }

        let generatedDirectory = root.appendingPathComponent("Generated", isDirectory: true)
        try fileManager.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        let kept = generatedDirectory.appendingPathComponent("Keep.swift")
        let dropped = generatedDirectory.appendingPathComponent("Drop.swift")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "dropped".write(to: dropped, atomically: true, encoding: .utf8)

        let legacyBefore = legacyIndex.currentDiagnostics()
        let compiledBefore = compiledIndex.currentDiagnostics()
        legacyIndex.update(paths: [generatedDirectory.path])
        compiledIndex.update(paths: [generatedDirectory.path])

        try await waitUntil {
            legacyIndex.currentDiagnostics().completedRefreshBatches > legacyBefore.completedRefreshBatches
                && compiledIndex.currentDiagnostics().completedRefreshBatches > compiledBefore.completedRefreshBatches
                && !legacyIndex.currentStats().isIndexing
                && !compiledIndex.currentStats().isIndexing
        }

        let legacyPaths = allIndexedPaths(in: legacyIndex)
        let compiledPaths = allIndexedPaths(in: compiledIndex)
        #expect(compiledPaths == legacyPaths)
        #expect(compiledPaths.contains(kept.path))
        #expect(!compiledPaths.contains(dropped.path))
        #expect(!compiledPaths.contains(generatedDirectory.path))
    }

    @Test("deferred optimization publishes complete rebuild results and later persists optimized snapshot")
    func deferredOptimizationPublishesCompleteRebuildResults() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let appFile = sourceDirectory.appendingPathComponent("App.swift")
        let readmeFile = root.appendingPathComponent("README.md")
        try "app".write(to: appFile, atomically: true, encoding: .utf8)
        try "readme".write(to: readmeFile, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.setDeferredOptimizationRecordThresholdForTesting(1)
        index.replaceRootsAndRebuild([root], mode: .fresh)

        try await waitUntil {
            !index.currentStats().isIndexing
        }

        let paths = allIndexedPaths(in: index)
        #expect(paths.contains(root.path))
        #expect(paths.contains(sourceDirectory.path))
        #expect(paths.contains(appFile.path))
        #expect(paths.contains(readmeFile.path))

        let response = index.search(SearchRequest(
            query: "App",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: true
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == appFile.path })

        try await waitUntil(timeout: .seconds(90)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let reloadedPaths = allIndexedPaths(in: reloaded)
        #expect(reloadedPaths == allIndexedPaths(in: index))
    }

    @Test("scoped reconciliation publishes a durable delta before deferred compaction")
    func deferredOptimizationPreservesScopedReconcileResults() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let removedFile = sourceDirectory.appendingPathComponent("Removed.swift")
        let retainedFile = sourceDirectory.appendingPathComponent("Retained.swift")
        let addedFile = sourceDirectory.appendingPathComponent("Added.swift")
        try "removed".write(to: removedFile, atomically: true, encoding: .utf8)
        try "retained".write(to: retainedFile, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.setDeferredOptimizationRecordThresholdForTesting(1)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            !index.currentStats().isIndexing
        }

        try await waitUntil(timeout: .seconds(60)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        try fileManager.removeItem(at: removedFile)
        try "added".write(to: addedFile, atomically: true, encoding: .utf8)

        let recorder = StatsRecorder()
        index.onStatsChanged = { @MainActor @Sendable stats in
            recorder.append(stats)
        }
        index.reconcileIndexedRootsInBackground(rootURLs: [sourceDirectory])

        try await waitUntil(timeout: .seconds(10)) {
            !index.currentStats().isIndexing
        }

        let paths = allIndexedPaths(in: index)
        #expect(paths.contains(addedFile.path))
        #expect(paths.contains(retainedFile.path))
        #expect(!paths.contains(removedFile.path))

        let diagnostics = index.currentDiagnostics()
        #expect(diagnostics.recordStoreKind == .overlay)
        #expect(diagnostics.optimizedCount == 0)
        try await waitUntil {
            recorder.snapshot().contains {
                $0.phase == .ready && $0.indexedCount > 0 && $0.optimizedCount == 0
            }
        }
        #expect(recorder.snapshot().contains {
            $0.phase == .ready && $0.indexedCount > 0 && $0.optimizedCount == 0
        })

        let reconciledStatus = index.currentStats().status
        #expect(reconciledStatus.hasPrefix("Reconciled "))
        #expect(reconciledStatus.contains(" in "))

        let refreshesBeforeNoop = diagnostics.completedRefreshBatches
        index.update(paths: [
            root
                .appendingPathComponent(".git/objects/ab/\(UUID().uuidString)")
                .path
        ])
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().completedRefreshBatches > refreshesBeforeNoop
        }
        #expect(index.currentStats().status == reconciledStatus)
    }

    @Test("frontier batch modes match single-directory full rebuild paths")
    func frontierBatchModesMatchSingleDirectoryFullRebuildPaths() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Sources", isDirectory: true)
        let gitHooksDirectory = root.appendingPathComponent(".git/hooks", isDirectory: true)
        let gitObjectsDirectory = root.appendingPathComponent(".git/objects/ab", isDirectory: true)
        let nodeModuleDirectory = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent(".cache/build", isDirectory: true)
        let nestedRoot = root.appendingPathComponent("NestedRoot", isDirectory: true)
        let nestedSourceDirectory = nestedRoot.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitHooksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitObjectsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeModuleDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nestedSourceDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let included = sourceDirectory.appendingPathComponent("App.swift")
        let gitConfig = root.appendingPathComponent(".git/config")
        let gitHook = gitHooksDirectory.appendingPathComponent("pre-commit")
        let gitObject = gitObjectsDirectory.appendingPathComponent("cdef")
        let nodeModuleFile = nodeModuleDirectory.appendingPathComponent("Skipped.js")
        let cacheFile = cacheDirectory.appendingPathComponent("Cache.db")
        let nestedSource = nestedSourceDirectory.appendingPathComponent("Nested.swift")
        try "app".write(to: included, atomically: true, encoding: .utf8)
        try "config".write(to: gitConfig, atomically: true, encoding: .utf8)
        try "hook".write(to: gitHook, atomically: true, encoding: .utf8)
        try "object".write(to: gitObject, atomically: true, encoding: .utf8)
        try "module".write(to: nodeModuleFile, atomically: true, encoding: .utf8)
        try "cache".write(to: cacheFile, atomically: true, encoding: .utf8)
        try "nested".write(to: nestedSource, atomically: true, encoding: .utf8)

        let roots = [root, nestedRoot]
        let baseline = try await indexedPaths(
            roots: roots,
            mode: .compiledQuery,
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            frontierMode: .singleDirectory,
            frontierBatchSize: 1
        )

        for frontierMode in ScanFrontierMode.allCases where frontierMode != .singleDirectory {
            let paths = try await indexedPaths(
                roots: roots,
                mode: .compiledQuery,
                applicationName: "AllTheThingsTests-\(UUID().uuidString)",
                frontierMode: frontierMode,
                frontierBatchSize: 4
            )
            #expect(paths == baseline)
        }

        #expect(baseline.contains(included.path))
        #expect(baseline.contains(gitConfig.path))
        #expect(baseline.contains(gitHook.path))
        #expect(baseline.contains(nestedSource.path))
        #expect(!baseline.contains(gitObject.path))
        #expect(!baseline.contains(nodeModuleFile.path))
        #expect(!baseline.contains(cacheFile.path))
    }

    @Test("frontier batch modes match single-directory scoped update paths")
    func frontierBatchModesMatchSingleDirectoryScopedUpdatePaths() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let patterns = [
            "*",
            "!*/",
            "Generated/",
            "!Generated/Keep.swift"
        ]
        let modes = ScanFrontierMode.allCases
        var indexes: [(mode: ScanFrontierMode, index: FileIndex, applicationName: String, before: FileIndexDiagnostics)] = []
        indexes.reserveCapacity(modes.count)
        defer {
            for item in indexes {
                try? fileManager.removeItem(at: supportDirectory(applicationName: item.applicationName))
            }
        }

        for mode in modes {
            let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
            let index = FileIndex(
                applicationName: applicationName,
                loadsSnapshotImmediately: false,
                exclusionPatterns: patterns
            )
            index.setScanFrontierBatchingForTesting(mode: mode, batchSize: 4)
            index.replaceRootsAndRebuild([root], mode: .fresh)
            indexes.append((mode, index, applicationName, index.currentDiagnostics()))
        }

        try await waitUntil {
            indexes.allSatisfy { !$0.index.currentStats().isIndexing }
        }
        indexes = indexes.map { item in
            (item.mode, item.index, item.applicationName, item.index.currentDiagnostics())
        }

        let generatedDirectory = root.appendingPathComponent("Generated", isDirectory: true)
        try fileManager.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        let kept = generatedDirectory.appendingPathComponent("Keep.swift")
        let dropped = generatedDirectory.appendingPathComponent("Drop.swift")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "dropped".write(to: dropped, atomically: true, encoding: .utf8)

        for item in indexes {
            item.index.update(paths: [generatedDirectory.path])
        }

        try await waitUntil {
            indexes.allSatisfy { item in
                item.index.currentDiagnostics().completedRefreshBatches > item.before.completedRefreshBatches
                    && !item.index.currentStats().isIndexing
            }
        }

        let baseline = allIndexedPaths(in: try #require(indexes.first { $0.mode == .singleDirectory }?.index))
        for item in indexes where item.mode != .singleDirectory {
            #expect(allIndexedPaths(in: item.index) == baseline)
        }
        #expect(baseline.contains(kept.path))
        #expect(!baseline.contains(dropped.path))
        #expect(!baseline.contains(generatedDirectory.path))
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

    @Test("structural overlay defers secondary sort rebuild until prioritized")
    func structuralOverlayDefersSecondarySortRebuildUntilPrioritized() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let original = root.appendingPathComponent("Original.swift")
        try "original".write(to: original, atomically: true, encoding: .utf8)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 2
        }
        index.prioritizeSearchOptimization(for: .created)
        try await waitUntil {
            index.hasOptimizedSortOrderForTesting(.created)
        }

        let before = index.currentDiagnostics()
        let added = root.appendingPathComponent("Added.swift")
        try "added".write(to: added, atomically: true, encoding: .utf8)
        index.update(paths: [added.path])

        try await waitUntil {
            index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches
        }
        #expect(!index.hasOptimizedSortOrderForTesting(.created))

        index.prioritizeSearchOptimization(for: .created)
        try await waitUntil {
            index.hasOptimizedSortOrderForTesting(.created)
        }

        let response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .created, ascending: true)
        ), maxResults: 10)
        #expect(response.executionProfile.executionPath == .emptyQuerySortedOrder)
        #expect(response.results.contains { $0.record.path == added.path })
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

    @Test("background catch up reconciliation keeps background presentation and covers duplicates")
    func backgroundCatchUpReconciliationKeepsBackgroundPresentationAndCoversDuplicates() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Changed", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let changedFile = folder.appendingPathComponent("WakeChanged.txt")
        try "changed".write(to: changedFile, atomically: true, encoding: .utf8)

        let rootRecord = try #require(FileRecord(url: root))
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([rootRecord], roots: [root])
        let slicesBefore = index.currentInsightsSnapshot().usage.maintenance
            .counters(for: .backgroundSlice).yieldedSlices

        let firstResult = index.reconcileIndexedRootsInBackground(
            rootURLs: [folder],
            activityPresentation: .backgroundCatchUp
        )
        let duplicateResult = index.reconcileIndexedRootsInBackground(
            rootURLs: [folder],
            activityPresentation: .backgroundCatchUp
        )

        #expect(firstResult == .started)
        #expect(duplicateResult == .coveredByActive)
        #expect(index.currentStats().activityPresentation == .backgroundCatchUp)
        #expect(index.currentStats().status == "Catching up changes")

        try await waitUntil(timeout: .seconds(10)) {
            let stats = index.currentStats()
            let response = index.search(SearchRequest(
                query: "WakeChanged",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return !stats.isIndexing
                && stats.activityPresentation == .backgroundCatchUp
                && stats.status.hasPrefix("Caught up")
                && response.results.contains { $0.record.path == changedFile.path }
        }
        #expect(index.currentInsightsSnapshot().usage.maintenance
            .counters(for: .backgroundSlice).yieldedSlices == slicesBefore)
    }

    @Test("reconciliation obeys the background duty cycle and resumes in foreground")
    func reconciliationObeysBackgroundDutyCycleAndResumesInForeground() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let existingFile = root.appendingPathComponent("Existing.txt")
        try "existing".write(to: existingFile, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let createdFile = root.appendingPathComponent("CreatedWhileAway.txt")
        try "created".write(to: createdFile, atomically: true, encoding: .utf8)
        let slicesBefore = index.currentInsightsSnapshot().usage.maintenance
            .counters(for: .backgroundSlice).yieldedSlices

        index.setBackgroundMaintenanceEnabled(true)
        defer { index.setBackgroundMaintenanceEnabled(false) }
        #expect(index.reconcileIndexedRootsInBackground(rootURLs: [root]) == .started)

        try await waitUntil(timeout: .seconds(5)) {
            index.currentStats().isReconciling
                && index.currentInsightsSnapshot().usage.maintenance
                    .counters(for: .backgroundSlice).yieldedSlices > slicesBefore
        }
        index.update(
            exactPaths: [createdFile.path],
            recursivePaths: [],
            priority: .background
        )
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingRefreshPathsForTesting().contains(createdFile.path)
        }
        let pendingResponse = index.search(SearchRequest(
            query: "CreatedWhileAway",
            sort: SortSpec(column: .relevance, ascending: false),
            mode: .interactivePreview
        ), maxResults: 10)
        #expect(pendingResponse.totalMatches == 1)
        #expect(pendingResponse.results.map(\.record.path) == [createdFile.path])

        index.setBackgroundMaintenanceEnabled(false)
        try await waitUntil(timeout: .seconds(10)) {
            !index.currentStats().isIndexing
                && index.search(SearchRequest(
                    query: "CreatedWhileAway",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == createdFile.path }
        }

        let scanWork = index.currentDiagnostics().scanFrontierMetrics
        #expect(scanWork.retainedRecordDictionaryCount < index.currentStats().indexedCount)
        #expect(index.currentInsightsSnapshot().usage.maintenance
            .counters(for: .reconcile).yieldedSlices > 0)
    }

    @Test("explicit promotion resumes a parked background reconciliation")
    func explicitPromotionResumesParkedBackgroundReconciliation() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "existing".write(
            to: root.appendingPathComponent("Existing.txt"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let createdFile = root.appendingPathComponent("CreatedBeforePromotion.txt")
        try "created".write(to: createdFile, atomically: true, encoding: .utf8)
        let slicesBefore = index.currentInsightsSnapshot().usage.maintenance
            .counters(for: .backgroundSlice).yieldedSlices

        index.setBackgroundMaintenanceEnabled(true)
        defer { index.setBackgroundMaintenanceEnabled(false) }
        #expect(index.reconcileIndexedRootsInBackground(rootURLs: [root]) == .started)
        try await waitUntil(timeout: .seconds(5)) {
            index.currentInsightsSnapshot().usage.maintenance
                .counters(for: .backgroundSlice).yieldedSlices > slicesBefore
        }

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(5)) {
            !index.currentStats().isIndexing
                && index.search(SearchRequest(
                    query: "CreatedBeforePromotion",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == createdFile.path }
        }
    }

    @Test("a root rebuild promptly cancels a parked background reconciliation")
    func rootRebuildCancelsParkedBackgroundReconciliation() async throws {
        let fileManager = FileManager.default
        let originalRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)-original", isDirectory: true)
        let replacementRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)-replacement", isDirectory: true)
        try fileManager.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        try "original".write(
            to: originalRoot.appendingPathComponent("Original.txt"),
            atomically: true,
            encoding: .utf8
        )
        let replacementFile = replacementRoot.appendingPathComponent("Replacement.txt")
        try "replacement".write(to: replacementFile, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: originalRoot)
            try? fileManager.removeItem(at: replacementRoot)
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([originalRoot], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let slicesBefore = index.currentInsightsSnapshot().usage.maintenance
            .counters(for: .backgroundSlice).yieldedSlices
        index.setBackgroundMaintenanceEnabled(true)
        defer { index.setBackgroundMaintenanceEnabled(false) }
        #expect(index.reconcileIndexedRootsInBackground(
            activityPresentation: .backgroundCatchUp
        ) == .started)
        try await waitUntil(timeout: .seconds(5)) {
            index.currentInsightsSnapshot().usage.maintenance
                .counters(for: .backgroundSlice).yieldedSlices > slicesBefore
        }

        index.replaceRootsAndRebuild([replacementRoot], mode: .fresh)
        try await waitUntil(timeout: .seconds(5)) {
            !index.currentStats().isIndexing
                && index.search(SearchRequest(
                    query: "Replacement",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == replacementFile.path }
        }
        #expect(index.allRoots().map(\.standardizedFileURL.path) == [replacementRoot.standardizedFileURL.path])
        #expect(index.currentDiagnostics().activeIndexJobs == 0)
    }

    @Test("partially overlapping reconciliation queues only uncovered catch up scopes")
    func partiallyOverlappingReconciliationQueuesOnlyUncoveredCatchUpScopes() async throws {
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

        let firstFile = firstFolder.appendingPathComponent("FirstWakeChanged.txt")
        let secondFile = secondFolder.appendingPathComponent("SecondWakeChanged.txt")
        try "first".write(to: firstFile, atomically: true, encoding: .utf8)
        try "second".write(to: secondFile, atomically: true, encoding: .utf8)

        let rootRecord = try #require(FileRecord(url: root))
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([rootRecord], roots: [root])

        let firstResult = index.reconcileIndexedRootsInBackground(
            rootURLs: [firstFolder],
            activityPresentation: .backgroundCatchUp
        )
        let overlappingResult = index.reconcileIndexedRootsInBackground(
            rootURLs: [firstFolder, secondFolder],
            activityPresentation: .backgroundCatchUp
        )

        #expect(firstResult == .started)
        #expect(overlappingResult == .queued)

        try await waitUntil(timeout: .seconds(10)) {
            let first = index.search(SearchRequest(
                query: "FirstWakeChanged",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            let second = index.search(SearchRequest(
                query: "SecondWakeChanged",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return !index.currentStats().isIndexing
                && first.results.contains { $0.record.path == firstFile.path }
                && second.results.contains { $0.record.path == secondFile.path }
        }
        #expect(index.currentStats().activityPresentation == .backgroundCatchUp)
    }

    @Test("large structural overlay updates schedule mapped snapshot compaction")
    func largeStructuralOverlayUpdatesScheduleMappedSnapshotCompaction() async throws {
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
        let addedFile = root.appendingPathComponent("Added.txt")
        try "new".write(to: addedFile, atomically: true, encoding: .utf8)
        index.update(paths: [addedFile.path])

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

    @Test("structural delta compaction deadline does not slide as changes continue")
    func structuralDeltaCompactionScheduleDoesNotSlide() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: 0,
            largeOverlayPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            !index.currentStats().isIndexing
                && index.currentDiagnostics().recordStoreKind == .mapped
        }

        let firstFile = root.appendingPathComponent("First.swift")
        try "first".write(to: firstFile, atomically: true, encoding: .utf8)
        let firstCompletion = CompletionFlag()
        index.update(paths: [firstFile.path]) { firstCompletion.mark() }
        try await waitUntil(timeout: .seconds(5)) {
            firstCompletion.isMarked
                && index.structuralDeltaCompactionScheduleForTesting() != nil
        }
        let firstSchedule = try #require(index.structuralDeltaCompactionScheduleForTesting())

        let secondFile = root.appendingPathComponent("Second.swift")
        try "second".write(to: secondFile, atomically: true, encoding: .utf8)
        let secondCompletion = CompletionFlag()
        index.update(paths: [secondFile.path]) { secondCompletion.mark() }
        try await waitUntil(timeout: .seconds(5)) { secondCompletion.isMarked }
        let secondSchedule = try #require(index.structuralDeltaCompactionScheduleForTesting())

        #expect(secondSchedule.revision == firstSchedule.revision)
        #expect(secondSchedule.scheduledAt == firstSchedule.scheduledAt)
        #expect(
            secondSchedule.writerConflictWarningDeadline
                == firstSchedule.writerConflictWarningDeadline
        )
        #expect(index.search(SearchRequest(
            query: "Second",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == secondFile.path })
    }

    @Test("structural delta compaction is not postponed by queued background refreshes")
    func structuralDeltaCompactionBypassesBackgroundRefreshBacklog() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let blocker = root.appendingPathComponent("Blocker", isDirectory: true)
        try fileManager.createDirectory(at: blocker, withIntermediateDirectories: true)
        try "existing".write(
            to: blocker.appendingPathComponent("Existing.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let support = supportDirectory(applicationName: applicationName)
        defer { try? fileManager.removeItem(at: support) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: 0,
            largeOverlayPersistDelay: 0.2,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            !index.currentStats().isIndexing
                && index.currentDiagnostics().recordStoreKind == .mapped
        }

        let added = root.appendingPathComponent("Added.swift")
        try "added".write(to: added, atomically: true, encoding: .utf8)
        index.update(paths: [added.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            index.currentDiagnostics().recordStoreKind == .overlay
                && index.structuralDeltaCompactionScheduleForTesting() != nil
        }

        index.update(paths: [blocker.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            index.currentDiagnostics().pendingBackgroundRefreshPathCount == 1
        }
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().recordStoreKind == .mapped
                && !fileManager.fileExists(atPath: support
                    .appendingPathComponent(StructuralDeltaStore.fileName)
                    .path)
        }
        #expect(index.currentDiagnostics().pendingBackgroundRefreshPathCount == 1)
        #expect(index.search(SearchRequest(
            query: "Added",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == added.path })

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().pendingRefreshPathCount == 0
        }
    }

    @Test("metadata-only updates persist sidecar without compacting mapped snapshot")
    func metadataOnlyUpdatesPersistSidecarWithoutCompactingMappedSnapshot() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let updatedFile = root.appendingPathComponent("Updated.txt")
        try "old".write(to: updatedFile, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            metadataOverlayPersistDelay: 0.1
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let before = index.currentDiagnostics()
        let recorder = StatsRecorder()
        index.onStatsChanged = { @MainActor @Sendable stats in
            recorder.append(stats)
        }

        let newContents = "new metadata payload"
        try newContents.write(to: updatedFile, atomically: true, encoding: .utf8)
        index.update(paths: [updatedFile.path])

        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.completedRefreshBatches > before.completedRefreshBatches
                && diagnostics.overlayCount == 1
                && diagnostics.optimizedCount == diagnostics.indexedCount
                && diagnostics.nameGramPostingCount == before.nameGramPostingCount
        }

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory(applicationName: applicationName))
        let metadataOverlayURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.metadataOverlay)
        try await waitUntil(timeout: .seconds(5)) {
            fileManager.fileExists(atPath: metadataOverlayURL.path)
                && index.currentDiagnostics().activeIndexJobs == 0
        }

        let afterPersist = index.currentDiagnostics()
        #expect(afterPersist.recordStoreKind == .overlay)
        #expect(afterPersist.overlayCount == 1)
        #expect(afterPersist.completedSnapshotRebuilds == before.completedSnapshotRebuilds)
        #expect(recorder.snapshot().contains { $0.phase == .saving })

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let reloadedDiagnostics = reloaded.currentDiagnostics()
        #expect(reloadedDiagnostics.recordStoreKind == .overlay)
        #expect(reloadedDiagnostics.overlayCount == 1)
        #expect(reloadedDiagnostics.optimizedCount == reloadedDiagnostics.indexedCount)
        #expect(reloadedDiagnostics.nameGramPostingCount == before.nameGramPostingCount)

        let response = reloaded.search(SearchRequest(
            query: "Updated",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        let result = try #require(response.results.first { $0.record.path == updatedFile.path })
        #expect(result.record.sizeBytes == UInt64(newContents.utf8.count))
    }

    @Test("update completion fires after exact refresh persists")
    func updateCompletionFiresAfterExactRefreshPersists() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let rootRecord = try #require(FileRecord(url: root))
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([rootRecord], roots: [root])

        let changedFile = root.appendingPathComponent("ExactRefreshCompletion.txt", isDirectory: false)
        try "changed".write(to: changedFile, atomically: true, encoding: .utf8)

        let before = index.currentDiagnostics()
        let completion = CompletionFlag()
        index.update(paths: [changedFile.path]) {
            completion.mark()
        }

        try await waitUntil(timeout: .seconds(5)) {
            completion.isMarked
        }

        let response = index.search(SearchRequest(
            query: "ExactRefreshCompletion",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == changedFile.path })
        #expect(index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches)
        #expect(index.currentDiagnostics().recordStoreKind == .mapped)
        #expect(fileManager.fileExists(atPath: SnapshotLayout.packageURL(
            in: supportDirectory(applicationName: applicationName)
        ).path))
    }

    @Test("structural refresh completion persists a delta without rewriting the base snapshot")
    func structuralRefreshPersistsDurableDelta() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let support = supportDirectory(applicationName: applicationName)
        defer { try? fileManager.removeItem(at: support) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let packageURL = SnapshotLayout.packageURL(in: support)
        let manifestURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.manifest)
        let originalManifest = try Data(contentsOf: manifestURL)
        let addedFile = root.appendingPathComponent("DurableDelta.swift")
        try "delta".write(to: addedFile, atomically: true, encoding: .utf8)
        let completion = CompletionFlag()
        index.update(paths: [addedFile.path]) { completion.mark() }

        try await waitUntil(timeout: .seconds(5)) { completion.isMarked }
        #expect(index.currentDiagnostics().recordStoreKind == .overlay)
        #expect(try Data(contentsOf: manifestURL) == originalManifest)
        #expect(fileManager.fileExists(atPath: support
            .appendingPathComponent(StructuralDeltaStore.fileName)
            .path))

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.currentDiagnostics().recordStoreKind == .overlay)
        let response = reloaded.search(
            SearchRequest(
                query: "DurableDelta",
                sort: SortSpec(column: .relevance, ascending: false)
            ),
            maxResults: 10
        )
        #expect(response.results.contains { $0.record.path == addedFile.path })
    }

    @Test("foreground promotion and search prioritization preserve a tiny durable delta")
    func foregroundPromotionPreservesTinyDurableStructuralDelta() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let unchangedFolder = root.appendingPathComponent("Unchanged", isDirectory: true)
        try fileManager.createDirectory(at: unchangedFolder, withIntermediateDirectories: true)
        try "existing".write(
            to: unchangedFolder.appendingPathComponent("Existing.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let support = supportDirectory(applicationName: applicationName)
        defer { try? fileManager.removeItem(at: support) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: 100,
            largeOverlayPersistDelay: 0.05,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let packageURL = SnapshotLayout.packageURL(in: support)
        let manifestURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.manifest)
        let originalManifest = try Data(contentsOf: manifestURL)
        let deltaURL = support.appendingPathComponent(StructuralDeltaStore.fileName)
        let addedFile = root.appendingPathComponent("ForegroundDelta.swift")
        try "delta".write(to: addedFile, atomically: true, encoding: .utf8)
        let completion = CompletionFlag()
        index.update(paths: [addedFile.path], priority: .background) { completion.mark() }

        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return completion.isMarked
                && diagnostics.recordStoreKind == .overlay
                && diagnostics.optimizedCount == 0
                && fileManager.fileExists(atPath: deltaURL.path)
        }

        index.update(paths: [unchangedFolder.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            index.currentDiagnostics().pendingBackgroundRefreshPathCount == 1
        }

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().pendingRefreshPathCount == 0
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(index.currentDiagnostics().recordStoreKind == .overlay)

        index.prioritizeSearchOptimization(for: .name)
        index.scheduleAutomaticPersistForTesting()
        try await Task.sleep(for: .milliseconds(250))

        let diagnostics = index.currentDiagnostics()
        #expect(diagnostics.recordStoreKind == .overlay)
        #expect(diagnostics.optimizedCount == 0)
        #expect(try Data(contentsOf: manifestURL) == originalManifest)
        #expect(fileManager.fileExists(atPath: deltaURL.path))
        #expect(index.search(SearchRequest(
            query: "ForegroundDelta",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == addedFile.path })

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.currentDiagnostics().recordStoreKind == .overlay)
        #expect(reloaded.search(SearchRequest(
            query: "ForegroundDelta",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == addedFile.path })
    }

    @Test("search prioritization still optimizes a non-durable overlay")
    func searchPrioritizationStillOptimizesNonDurableOverlay() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: 100,
            largeOverlayPersistDelay: 60,
            backgroundOptimizationPersistDelay: 60
        )
        let rootRecord = try #require(FileRecord(url: root))
        index.replaceRecordsForTesting([rootRecord], roots: [root])

        let addedFile = root.appendingPathComponent("NeedsCheckpoint.swift")
        try "checkpoint".write(to: addedFile, atomically: true, encoding: .utf8)
        index.update(paths: [addedFile.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.pendingRefreshPathCount == 0
                && diagnostics.recordStoreKind == .overlay
                && diagnostics.optimizedCount == 0
                && index.hasPendingDurabilityForTesting()
        }

        index.prioritizeSearchOptimization(for: .name)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
                && !index.hasPendingDurabilityForTesting()
        }
        #expect(index.search(SearchRequest(
            query: "NeedsCheckpoint",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == addedFile.path })
    }

    @Test("no-op refresh clears earlier durability debt before completing")
    func noopRefreshPersistsEarlierDurabilityDebt() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let support = supportDirectory(applicationName: applicationName)
        defer { try? fileManager.removeItem(at: support) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let deltaURL = support.appendingPathComponent(StructuralDeltaStore.fileName)
        try fileManager.createDirectory(at: deltaURL, withIntermediateDirectories: false)

        let addedFile = root.appendingPathComponent("DebtMustPersist.swift")
        try "debt".write(to: addedFile, atomically: true, encoding: .utf8)
        let firstCompletion = CompletionFlag()
        let before = index.currentDiagnostics()
        index.update(paths: [addedFile.path]) { firstCompletion.mark() }

        try await waitUntil(timeout: .seconds(3)) {
            index.currentDiagnostics().completedRefreshBatches > before.completedRefreshBatches
                && index.hasPendingDurabilityForTesting()
        }
        #expect(!firstCompletion.isMarked)

        try fileManager.removeItem(at: deltaURL)
        let secondCompletion = CompletionFlag()
        index.update(paths: [addedFile.path]) { secondCompletion.mark() }

        try await waitUntil(timeout: .seconds(10)) {
            firstCompletion.isMarked
                && secondCompletion.isMarked
                && !index.hasPendingDurabilityForTesting()
        }

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let response = reloaded.search(
            SearchRequest(
                query: "DebtMustPersist",
                sort: SortSpec(column: .relevance, ascending: false)
            ),
            maxResults: 10
        )
        #expect(response.results.contains { $0.record.path == addedFile.path })
    }

    @Test("deleting a directory removes descendants added by an earlier delta")
    func directoryDeletionRemovesDeltaAddedDescendants() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let originalFile = folder.appendingPathComponent("Original.txt")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try "original".write(to: originalFile, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let support = supportDirectory(applicationName: applicationName)
        defer { try? fileManager.removeItem(at: support) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let addedFile = folder.appendingPathComponent("AddedLater.swift")
        try "added".write(to: addedFile, atomically: true, encoding: .utf8)
        let addCompletion = CompletionFlag()
        index.update(paths: [addedFile.path]) { addCompletion.mark() }
        try await waitUntil { addCompletion.isMarked }
        #expect(allIndexedPaths(in: index).contains(addedFile.path))
        let ancestorMatches = index.search(
            SearchRequest(
                query: "folder",
                sort: SortSpec(column: .name, ascending: true)
            ),
            maxResults: 50
        )
        #expect(ancestorMatches.results.contains { $0.record.path == addedFile.path })

        try fileManager.removeItem(at: folder)
        let deleteCompletion = CompletionFlag()
        index.update(paths: [folder.path]) { deleteCompletion.mark() }
        try await waitUntil { deleteCompletion.isMarked }

        let currentPaths = allIndexedPaths(in: index)
        #expect(!currentPaths.contains(folder.path))
        #expect(!currentPaths.contains(originalFile.path))
        #expect(!currentPaths.contains(addedFile.path))

        let unrepresentedFolder = root.appendingPathComponent("AddedFolder", isDirectory: true)
        let onlyChild = unrepresentedFolder.appendingPathComponent("OnlyChild.swift")
        try fileManager.createDirectory(at: unrepresentedFolder, withIntermediateDirectories: true)
        try "child".write(to: onlyChild, atomically: true, encoding: .utf8)
        let childCompletion = CompletionFlag()
        index.update(paths: [onlyChild.path]) { childCompletion.mark() }
        try await waitUntil { childCompletion.isMarked }
        #expect(allIndexedPaths(in: index).contains(onlyChild.path))
        #expect(!allIndexedPaths(in: index).contains(unrepresentedFolder.path))

        try fileManager.removeItem(at: unrepresentedFolder)
        let ancestorCompletion = CompletionFlag()
        index.update(paths: [unrepresentedFolder.path]) { ancestorCompletion.mark() }
        try await waitUntil { ancestorCompletion.isMarked }
        #expect(!allIndexedPaths(in: index).contains(onlyChild.path))

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let reloadedPaths = allIndexedPaths(in: reloaded)
        #expect(!reloadedPaths.contains(folder.path))
        #expect(!reloadedPaths.contains(originalFile.path))
        #expect(!reloadedPaths.contains(addedFile.path))
        #expect(!reloadedPaths.contains(onlyChild.path))
    }

    @Test("metadata overlay checkpoints into mapped snapshot after quiet interval")
    func metadataOverlayCheckpointsIntoMappedSnapshotAfterQuietInterval() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let updatedFile = root.appendingPathComponent("Updated.txt")
        try "old".write(to: updatedFile, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            metadataOverlayPersistDelay: 0.05,
            metadataOverlayCheckpointDelay: 1
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let newContents = "new metadata payload"
        try newContents.write(to: updatedFile, atomically: true, encoding: .utf8)
        index.update(paths: [updatedFile.path])

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory(applicationName: applicationName))
        let metadataOverlayURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.metadataOverlay)
        try await waitUntil(timeout: .seconds(5)) {
            fileManager.fileExists(atPath: metadataOverlayURL.path)
        }
        let overlayData = try Data(contentsOf: metadataOverlayURL)
        #expect(Array(overlayData.prefix(8)) == Array("ATTMWAL1".utf8))

        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.recordStoreKind == .mapped
                && diagnostics.overlayCount == 0
                && !fileManager.fileExists(atPath: metadataOverlayURL.path)
                && diagnostics.activeIndexJobs == 0
        }

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let response = reloaded.search(SearchRequest(
            query: "Updated",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        let result = try #require(response.results.first { $0.record.path == updatedFile.path })
        #expect(result.record.sizeBytes == UInt64(newContents.utf8.count))
    }

    @Test("full rebuild discards metadata overlay WAL")
    func fullRebuildDiscardsMetadataOverlayWAL() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let updatedFile = root.appendingPathComponent("Updated.txt")
        try "old".write(to: updatedFile, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            metadataOverlayPersistDelay: 0.05,
            metadataOverlayCheckpointDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let newContents = "new metadata payload"
        try newContents.write(to: updatedFile, atomically: true, encoding: .utf8)
        index.update(paths: [updatedFile.path])

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory(applicationName: applicationName))
        let metadataOverlayURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.metadataOverlay)
        try await waitUntil(timeout: .seconds(5)) {
            fileManager.fileExists(atPath: metadataOverlayURL.path)
        }

        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.overlayCount == 0
                && !fileManager.fileExists(atPath: metadataOverlayURL.path)
        }

        let response = index.search(SearchRequest(
            query: "Updated",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        let result = try #require(response.results.first { $0.record.path == updatedFile.path })
        #expect(result.record.sizeBytes == UInt64(newContents.utf8.count))
    }

    @Test("large directory reconciliation publishes unoptimized overlay before compaction")
    func largeDirectoryReconciliationPublishesUnoptimizedOverlayBeforeCompaction() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: 0,
            largeOverlayPersistDelay: 0.2
        )
        index.replaceRootsAndRebuild([root])
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let before = index.currentDiagnostics()
        let createdFile = folder.appendingPathComponent("CreatedDuringCatchup.swift")
        try "created".write(to: createdFile, atomically: true, encoding: .utf8)
        index.update(paths: [folder.path])

        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.completedRefreshBatches > before.completedRefreshBatches
                && diagnostics.recordStoreKind == .overlay
                && diagnostics.overlayCount > 0
                && diagnostics.optimizedCount == 0
        }
        let overlayRevision = index.currentDiagnostics().snapshotRevision

        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.snapshotRevision > overlayRevision
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.overlayCount == 0
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }
    }

    @Test("default background directory maintenance targets a 2.5 percent duty cycle")
    func defaultBackgroundDirectoryMaintenanceHasBoundedDutyCycle() {
        let policy = FileIndex.defaultBackgroundDirectoryMaintenancePolicyForTesting

        #expect(policy.scanBudget == 1.5)
        #expect(policy.backoff == 60)
        #expect(policy.visitLimit == 2_048)
        #expect(policy.entryLimit == 8_192)
        #expect(policy.targetDutyCycle <= 0.025)
    }

    @Test("exact background bursts drain without directory traversal backoff")
    func exactBackgroundBurstsDrainContinuously() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshBatchLimit: 2,
            backgroundRefreshDrainBackoffDelay: 3_600,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let files = try (0..<5).map { offset in
            let file = root.appendingPathComponent("Burst-\(offset).swift")
            try "created".write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        let batchesBefore = index.currentDiagnostics().completedRefreshBatches
        let completion = CompletionFlag()

        index.update(paths: files.map(\.path), priority: .background) {
            completion.mark()
        }

        try await waitUntil(timeout: .seconds(10)) {
            completion.isMarked && index.currentDiagnostics().pendingRefreshPathCount == 0
        }
        let batchesAfter = index.currentDiagnostics().completedRefreshBatches
        #expect(batchesAfter - batchesBefore == 3)
        for file in files {
            #expect(index.search(SearchRequest(
                query: file.deletingPathExtension().lastPathComponent,
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10).results.contains { $0.record.path == file.path })
        }
    }

    @Test("wide directory enumeration resumes its cursor between background slices")
    func wideDirectoryEnumerationResumesBetweenSlices() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 0.25,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanEntryLimit: 8,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let wideDirectory = root.appendingPathComponent("Wide", isDirectory: true)
        try fileManager.createDirectory(at: wideDirectory, withIntermediateDirectories: true)
        for offset in 0..<200 {
            try "wide".write(
                to: wideDirectory.appendingPathComponent("Entry\(offset).swift"),
                atomically: true,
                encoding: .utf8
            )
        }

        let completion = CompletionFlag()
        index.update(paths: [wideDirectory.path], priority: .background) {
            completion.mark()
        }

        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: wideDirectory.path)?
                .activeEnumerationEntryCount == 8
        }
        let firstSlice = try #require(
            index.pendingDirectoryRefreshStateForTesting(path: wideDirectory.path)
        )
        #expect(firstSlice.pendingURLCount == 0)
        #expect(firstSlice.retryAttempt == 0)
        #expect(!completion.isMarked)

        try await waitUntil(timeout: .seconds(5)) {
            guard let entryCount = index.pendingDirectoryRefreshStateForTesting(path: wideDirectory.path)?
                .activeEnumerationEntryCount else {
                return false
            }
            return entryCount > (firstSlice.activeEnumerationEntryCount ?? 0)
        }

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            completion.isMarked
                && index.currentDiagnostics().pendingRefreshPathCount == 0
                && index.search(SearchRequest(
                    query: "Entry199",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains {
                    $0.record.path == wideDirectory.appendingPathComponent("Entry199.swift").path
                }
        }
    }

    @Test("persistent refresh errors use capped exponential backoff")
    func persistentRefreshErrorsUseExponentialBackoff() async throws {
        #expect(FileIndex.backgroundRefreshRetryDelayForTesting(
            baseDelay: 10,
            priorFailureCount: 0
        ) == 10)
        #expect(FileIndex.backgroundRefreshRetryDelayForTesting(
            baseDelay: 10,
            priorFailureCount: 1
        ) == 20)
        #expect(FileIndex.backgroundRefreshRetryDelayForTesting(
            baseDelay: 10,
            priorFailureCount: 20
        ) == 60 * 60)

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 10,
            backgroundDirectoryScanBudget: 60,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let created = folder.appendingPathComponent("Created.swift")
        try "created".write(to: created, atomically: true, encoding: .utf8)
        index.failNextFileSystemLookupsForTesting(path: folder.path)
        index.failNextDirectoryUpdateEnumerationsForTesting(path: folder.path)

        let completion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) {
            completion.mark()
        }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingRefreshRetryStateForTesting(path: folder.path)?.attempt == 1
        }
        let firstFailure = try #require(
            index.pendingRefreshRetryStateForTesting(path: folder.path)
        )
        let firstEligibility = try #require(firstFailure.eligibleAt)
        #expect(!completion.isMarked)

        index.resumePendingRefreshForTesting(path: folder.path)
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingRefreshRetryStateForTesting(path: folder.path)?.attempt == 2
        }
        let secondFailure = try #require(
            index.pendingRefreshRetryStateForTesting(path: folder.path)
        )
        let secondEligibility = try #require(secondFailure.eligibleAt)
        #expect(secondEligibility > firstEligibility)

        // A fresh background event coalesces into the failed work without waking
        // it or resetting the failure history.
        index.update(paths: [folder.path], priority: .background)
        let afterBackgroundEvent = try #require(
            index.pendingRefreshRetryStateForTesting(path: folder.path)
        )
        #expect(afterBackgroundEvent.attempt == 2)
        #expect(afterBackgroundEvent.eligibleAt == secondFailure.eligibleAt)

        // Explicit interactive promotion breaks the delay and clears the failed
        // attempts before retrying.
        index.promotePendingRefreshForTesting(path: folder.path)
        try await waitUntil(timeout: .seconds(10)) {
            completion.isMarked
                && index.currentDiagnostics().pendingRefreshPathCount == 0
                && index.search(SearchRequest(
                    query: "Created",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == created.path }
        }
    }

    @Test("new events do not wake a deferred background directory traversal")
    func newEventsDoNotBypassBackgroundTraversalBackoff() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let deferredFolder = root.appendingPathComponent("Deferred", isDirectory: true)
        try fileManager.createDirectory(at: deferredFolder, withIntermediateDirectories: true)
        try "existing".write(
            to: deferredFolder.appendingPathComponent("Existing.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 1,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil { !index.currentStats().isIndexing }

        index.update(paths: [deferredFolder.path], priority: .background)
        try await waitUntil {
            index.pendingDirectoryRefreshStateForTesting(path: deferredFolder.path) != nil
        }
        let progressBeforeEvent = try #require(
            index.pendingDirectoryRefreshStateForTesting(path: deferredFolder.path)
        )

        let independentFile = root.appendingPathComponent("Independent.swift")
        try "new".write(to: independentFile, atomically: true, encoding: .utf8)
        index.update(paths: [independentFile.path], priority: .background)
        try await waitUntil {
            index.search(
                SearchRequest(
                    query: "Independent",
                    sort: SortSpec(column: .relevance, ascending: false)
                ),
                maxResults: 10
            ).results.contains { $0.record.path == independentFile.path }
        }

        let progressAfterEvent = try #require(
            index.pendingDirectoryRefreshStateForTesting(path: deferredFolder.path)
        )
        #expect(progressAfterEvent.recordCount == progressBeforeEvent.recordCount)

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().pendingRefreshPathCount == 0
        }
    }

    @Test("background directory refresh yields and foreground promotion completes catch up")
    func backgroundDirectoryRefreshYieldsAndForegroundPromotionCompletesCatchUp() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let createdFile = folder.appendingPathComponent("DeferredCatchup.swift")
        try "created".write(to: createdFile, atomically: true, encoding: .utf8)
        let before = index.currentDiagnostics()
        index.update(paths: [folder.path], priority: .background)

        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.completedRefreshBatches > before.completedRefreshBatches
                && diagnostics.pendingBackgroundRefreshPathCount == 1
        }
        let yieldedSnapshot = index.currentInsightsSnapshot()
        #expect(yieldedSnapshot.health.maintenance.pendingBackgroundRefreshPathCount == 1)
        #expect(yieldedSnapshot.usage.maintenance.counters(for: .directoryRefresh).yieldedSlices >= 1)
        #expect(index.search(SearchRequest(
            query: "DeferredCatchup",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).totalMatches == 0)

        index.promoteBackgroundMaintenance()

        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            let response = index.search(SearchRequest(
                query: "DeferredCatchup",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return diagnostics.pendingRefreshPathCount == 0
                && response.results.contains { $0.record.path == createdFile.path }
        }
        let completedSnapshot = index.currentInsightsSnapshot()
        #expect(completedSnapshot.health.maintenance.pendingRefreshPathCount == 0)
        #expect(completedSnapshot.usage.maintenance.background.operations > 0)
    }

    @Test("background mode demotes queued interactive directory refreshes")
    func backgroundModeDemotesQueuedInteractiveRefresh() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let folder = root.appendingPathComponent("Deferred", isDirectory: true)
        let child = folder.appendingPathComponent("Child.swift")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try "child".write(to: child, atomically: true, encoding: .utf8)
        let completion = CompletionFlag()
        index.update(paths: [folder.path], priority: .interactive) { completion.mark() }
        index.setBackgroundMaintenanceEnabled(true)

        try await waitUntil(timeout: .seconds(5)) {
            index.currentDiagnostics().pendingBackgroundRefreshPathCount == 1
                && index.pendingDirectoryRefreshStateForTesting(path: folder.path) != nil
        }
        #expect(!completion.isMarked)

        index.setBackgroundMaintenanceEnabled(false)
        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            completion.isMarked
                && index.search(SearchRequest(
                    query: "Child",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == child.path }
        }
    }

    @Test("background directory refresh resumes across bounded slices")
    func backgroundDirectoryRefreshResumesAcrossBoundedSlices() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        for offset in 0..<1_000 {
            let file = folder.appendingPathComponent("Existing\(offset).swift")
            try "existing".write(to: file, atomically: true, encoding: .utf8)
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 0,
            backgroundDirectoryScanBudget: 0.005,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let createdFile = folder.appendingPathComponent("CreatedDuringCatchup.swift")
        try "created".write(to: createdFile, atomically: true, encoding: .utf8)
        let before = index.currentDiagnostics()
        index.update(paths: [folder.path], priority: .background)

        try await waitUntil(timeout: .seconds(20)) {
            let diagnostics = index.currentDiagnostics()
            let response = index.search(SearchRequest(
                query: "CreatedDuringCatchup",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return diagnostics.completedRefreshBatches > before.completedRefreshBatches + 1
                && diagnostics.pendingBackgroundRefreshPathCount == 0
                && response.results.contains { $0.record.path == createdFile.path }
        }

        let completedSnapshot = index.currentInsightsSnapshot()
        #expect(completedSnapshot.usage.maintenance.counters(for: .directoryRefresh).yieldedSlices > 1)
    }

    @Test("background refresh service rotates past a yielded ancestor")
    func backgroundRefreshServiceIsFairAcrossPendingPaths() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let oversized = root.appendingPathComponent("Oversized", isDirectory: true)
        let independent = root.appendingPathComponent("Independent", isDirectory: true)
        try fileManager.createDirectory(at: oversized, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: independent, withIntermediateDirectories: true)
        for offset in 0..<2_000 {
            try "existing".write(
                to: oversized.appendingPathComponent("Existing\(offset).swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshBatchLimit: 2,
            backgroundRefreshDrainBackoffDelay: 0.05,
            backgroundDirectoryScanBudget: 0.005,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let independentFile = independent.appendingPathComponent("Independent.swift")
        try "independent".write(to: independentFile, atomically: true, encoding: .utf8)
        let oversizedCompletion = CompletionFlag()
        let independentCompletion = CompletionFlag()
        let completionOrder = CompletionOrderRecorder()
        // Both paths share their initial eligibility. The first drain services the
        // older ancestor and exhausts the shared deadline. The next drain must
        // rotate to the selected-but-unvisited small directory.
        index.update(paths: [oversized.path], priority: .background) {
            completionOrder.append("oversized")
            oversizedCompletion.mark()
        }
        index.update(paths: [independent.path], priority: .background) {
            completionOrder.append("independent")
            independentCompletion.mark()
        }

        try await waitUntil(timeout: .seconds(5)) {
            independentCompletion.isMarked
                && index.search(SearchRequest(
                    query: "Independent",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == independentFile.path }
        }
        #expect(completionOrder.snapshot().first == "independent")

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            oversizedCompletion.isMarked && index.currentDiagnostics().pendingRefreshPathCount == 0
        }
    }

    @Test("bounded directory refresh publishes durable progress without starving newer descendants")
    func boundedDirectoryRefreshPublishesProgressAndDoesNotStarveDescendants() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let support = supportDirectory(applicationName: applicationName)
        defer { try? fileManager.removeItem(at: support) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 1,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let oversized = root.appendingPathComponent("Oversized", isDirectory: true)
        try fileManager.createDirectory(at: oversized, withIntermediateDirectories: true)
        for offset in 0..<20 {
            let child = oversized.appendingPathComponent("Child\(offset)", isDirectory: true)
            try fileManager.createDirectory(at: child, withIntermediateDirectories: true)
            try "existing".write(
                to: child.appendingPathComponent("Existing.swift"),
                atomically: true,
                encoding: .utf8
            )
        }

        let ancestorCompletion = CompletionFlag()
        index.update(paths: [oversized.path], priority: .background) {
            ancestorCompletion.mark()
        }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: oversized.path)?.recordCount == 1
        }

        #expect(!ancestorCompletion.isMarked)
        #expect(index.search(SearchRequest(
            query: "Oversized",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == oversized.path })
        #expect(fileManager.fileExists(atPath: support
            .appendingPathComponent(StructuralDeltaStore.fileName)
            .path))

        // The ancestor has already enumerated its children. A newer child must be
        // refreshed independently and excluded from the older scan's deletion pass.
        let lateFile = oversized.appendingPathComponent("Late.swift")
        try "late".write(to: lateFile, atomically: true, encoding: .utf8)
        let descendantCompletion = CompletionFlag()
        index.update(paths: [lateFile.path], priority: .background) {
            descendantCompletion.mark()
        }

        try await waitUntil(timeout: .seconds(5)) {
            descendantCompletion.isMarked
                && index.search(SearchRequest(
                    query: "Late",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == lateFile.path }
        }
        #expect(!ancestorCompletion.isMarked)
        #expect(index.currentDiagnostics().pendingBackgroundRefreshPathCount == 1)

        // A newer directory is itself bounded. Completing the older ancestor must
        // not release its receipt until this delegated subtree also completes.
        let lateDirectory = oversized.appendingPathComponent("LateDirectory", isDirectory: true)
        try fileManager.createDirectory(at: lateDirectory, withIntermediateDirectories: true)
        for offset in 0..<5 {
            try "late child".write(
                to: lateDirectory.appendingPathComponent("Child\(offset).swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        index.update(paths: [lateDirectory.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: lateDirectory.path) != nil
        }

        index.promotePendingRefreshForTesting(path: oversized.path)
        try await waitUntil(timeout: .seconds(5)) {
            let pending = index.pendingRefreshPathsForTesting()
            return !pending.contains(oversized.path) && pending.contains(lateDirectory.path)
        }
        #expect(!ancestorCompletion.isMarked)

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            ancestorCompletion.isMarked
                && index.currentDiagnostics().pendingRefreshPathCount == 0
        }
        #expect(index.search(SearchRequest(
            query: "Late",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == lateFile.path })
    }

    @Test("directory finalization resumes without rescanning or materializing retained paths")
    func directoryFinalizationIsBoundedAndResumable() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let files = try (0..<512).map { offset in
            let file = folder.appendingPathComponent(
                String(format: "Existing%04d.swift", offset)
            )
            try "existing".write(to: file, atomically: true, encoding: .utf8)
            return file
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 2_048,
            backgroundDirectoryScanEntryLimit: 8_192,
            backgroundDirectoryFinalizationLimit: 64,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        for file in files.prefix(3) {
            try fileManager.removeItem(at: file)
        }

        let completion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) { completion.mark() }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryFinalizationStateForTesting(path: folder.path) != nil
        }

        let initial = try #require(
            index.pendingDirectoryFinalizationStateForTesting(path: folder.path)
        )
        let traversalWorkCount = initial.traversalWorkCount
        var priorBaselineRowsVisited = 0
        var maximumMaterializedDeletionPathCount = 0

        for _ in 0..<20 where !completion.isMarked {
            if let state = index.pendingDirectoryFinalizationStateForTesting(path: folder.path) {
                #expect(state.traversalWorkCount == traversalWorkCount)
                #expect(state.baselineRowsVisited >= priorBaselineRowsVisited)
                #expect(state.baselineRowsVisited - priorBaselineRowsVisited <= 64)
                #expect(state.materializedDeletionPathCount <= 3)
                priorBaselineRowsVisited = state.baselineRowsVisited
                maximumMaterializedDeletionPathCount = max(
                    maximumMaterializedDeletionPathCount,
                    state.materializedDeletionPathCount
                )
                let priorPhase = state.phase
                index.resumePendingRefreshForTesting(path: folder.path)
                try await waitUntil(timeout: .seconds(2)) {
                    if completion.isMarked { return true }
                    guard let nextState = index.pendingDirectoryFinalizationStateForTesting(
                        path: folder.path
                    ) else {
                        return false
                    }
                    return nextState.baselineRowsVisited != priorBaselineRowsVisited
                        || nextState.phase != priorPhase
                }
            }
        }

        try await waitUntil(timeout: .seconds(10)) { completion.isMarked }
        #expect(maximumMaterializedDeletionPathCount == 3)
        #expect(index.currentDiagnostics().pendingRefreshPathCount == 0)
        for file in files.prefix(3) {
            #expect(!index.search(SearchRequest(
                query: file.deletingPathExtension().lastPathComponent,
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10).results.contains { $0.record.path == file.path })
        }
        #expect(index.search(SearchRequest(
            query: "Existing0511",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == files[511].path })
    }

    @Test("directory finalization drains unpublished additions with a stable cursor")
    func directoryFinalizationResumesUnpublishedUpserts() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 32,
            backgroundDirectoryScanEntryLimit: 8_192,
            backgroundDirectoryFinalizationLimit: 16,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let addedDirectory = root.appendingPathComponent("Added", isDirectory: true)
        try fileManager.createDirectory(at: addedDirectory, withIntermediateDirectories: true)
        for offset in 0..<220 {
            try "added".write(
                to: addedDirectory.appendingPathComponent(String(format: "Added%04d.swift", offset)),
                atomically: true,
                encoding: .utf8
            )
        }

        let completion = CompletionFlag()
        index.update(paths: [addedDirectory.path], priority: .background) { completion.mark() }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: addedDirectory.path) != nil
        }

        for _ in 0..<20
        where index.pendingDirectoryFinalizationStateForTesting(path: addedDirectory.path) == nil {
            let priorRecordCount = index.pendingDirectoryRefreshStateForTesting(
                path: addedDirectory.path
            )?.recordCount
            index.resumePendingRefreshForTesting(path: addedDirectory.path)
            try await waitUntil(timeout: .seconds(2)) {
                if index.pendingDirectoryFinalizationStateForTesting(
                    path: addedDirectory.path
                ) != nil {
                    return true
                }
                guard let state = index.pendingDirectoryRefreshStateForTesting(
                    path: addedDirectory.path
                ) else {
                    return false
                }
                return state.recordCount != priorRecordCount
            }
        }

        let initialFinalization = try #require(
            index.pendingDirectoryFinalizationStateForTesting(path: addedDirectory.path)
        )
        let traversalWorkCount = initialFinalization.traversalWorkCount
        var priorUpsertsVisited = initialFinalization.upsertsVisited
        var maximumUpsertsVisited = priorUpsertsVisited

        for _ in 0..<20 where !completion.isMarked {
            index.resumePendingRefreshForTesting(path: addedDirectory.path)
            try await waitUntil(timeout: .seconds(2)) {
                if completion.isMarked { return true }
                guard let state = index.pendingDirectoryFinalizationStateForTesting(
                    path: addedDirectory.path
                ) else {
                    return false
                }
                return state.upsertsVisited != priorUpsertsVisited
            }
            guard let state = index.pendingDirectoryFinalizationStateForTesting(
                path: addedDirectory.path
            ) else {
                continue
            }
            #expect(state.traversalWorkCount == traversalWorkCount)
            #expect(state.upsertsVisited >= priorUpsertsVisited)
            #expect(state.upsertsVisited - priorUpsertsVisited <= 16)
            priorUpsertsVisited = state.upsertsVisited
            maximumUpsertsVisited = max(maximumUpsertsVisited, state.upsertsVisited)
        }

        try await waitUntil(timeout: .seconds(10)) { completion.isMarked }
        #expect(maximumUpsertsVisited >= 32)
        #expect(index.search(SearchRequest(
            query: "Added0219",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains {
            $0.record.path == addedDirectory.appendingPathComponent("Added0219.swift").path
        })
    }

    @Test("newer exact events supersede deletion candidates prepared during finalization")
    func exactEventSupersedesPreparedDirectoryDeletion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let recreated = folder.appendingPathComponent("000-Recreated.swift")
        try "old".write(to: recreated, atomically: true, encoding: .utf8)
        for offset in 0..<256 {
            try "stable".write(
                to: folder.appendingPathComponent(String(format: "Stable%04d.swift", offset)),
                atomically: true,
                encoding: .utf8
            )
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 2_048,
            backgroundDirectoryScanEntryLimit: 8_192,
            backgroundDirectoryFinalizationLimit: 64,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        try fileManager.removeItem(at: recreated)
        let ancestorCompletion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) {
            ancestorCompletion.mark()
        }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryFinalizationStateForTesting(path: folder.path)?
                .materializedDeletionPathCount == 1
        }

        try "new content that must survive".write(
            to: recreated,
            atomically: true,
            encoding: .utf8
        )
        let exactCompletion = CompletionFlag()
        index.update(
            exactPaths: [recreated.path],
            recursivePaths: [],
            priority: .background
        ) {
            exactCompletion.mark()
        }
        try await waitUntil(timeout: .seconds(5)) { exactCompletion.isMarked }

        for _ in 0..<20 where !ancestorCompletion.isMarked {
            index.resumePendingRefreshForTesting(path: folder.path)
            try await Task.sleep(for: .milliseconds(25))
        }
        try await waitUntil(timeout: .seconds(10)) { ancestorCompletion.isMarked }

        let result = index.search(SearchRequest(
            query: "000-Recreated",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.first { $0.record.path == recreated.path }
        #expect(result?.record.sizeBytes == UInt64("new content that must survive".utf8.count))
    }

    @Test("transient path lookup and enumeration failures retry before releasing completion")
    func transientDirectoryFailuresRetainCompletion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 0.5,
            backgroundDirectoryScanBudget: 60,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let created = folder.appendingPathComponent("Created.swift")
        try "created".write(to: created, atomically: true, encoding: .utf8)
        index.failNextFileSystemLookupsForTesting(path: folder.path)
        index.failNextDirectoryUpdateEnumerationsForTesting(path: folder.path)
        let completion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) { completion.mark() }

        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: folder.path) != nil
        }
        #expect(!completion.isMarked)

        try await waitUntil(timeout: .seconds(5)) {
            completion.isMarked
                && index.search(SearchRequest(
                    query: "Created",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == created.path }
        }
    }

    @Test("persistent child failures do not block healthy directory siblings")
    func persistentChildFailuresDoNotBlockHealthySiblings() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 1,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for offset in 0..<6 {
            let branch = folder.appendingPathComponent("Branch\(offset)", isDirectory: true)
            try fileManager.createDirectory(at: branch, withIntermediateDirectories: true)
            try "healthy".write(
                to: branch.appendingPathComponent("Marker\(offset).swift"),
                atomically: true,
                encoding: .utf8
            )
        }

        let completion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) { completion.mark() }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryTraversalPathsForTesting(path: folder.path)?
                .pending.count == 6
        }

        let initial = try #require(
            index.pendingDirectoryTraversalPathsForTesting(path: folder.path)
        )
        let lookupFailure = try #require(initial.pending.last)
        let enumerationFailure = try #require(initial.pending.dropLast().last)
        let healthyBranch = try #require(initial.pending.dropLast(2).last)
        let healthyOffset = try #require(Int(URL(fileURLWithPath: healthyBranch)
            .lastPathComponent.dropFirst("Branch".count)))
        let healthyMarker = URL(fileURLWithPath: healthyBranch)
            .appendingPathComponent("Marker\(healthyOffset).swift")

        index.failNextFileSystemLookupsForTesting(path: lookupFailure, count: 100)
        index.failNextDirectoryUpdateEnumerationsForTesting(
            path: enumerationFailure,
            count: 100
        )
        index.promotePendingRefreshForTesting(path: folder.path)

        try await waitUntil(timeout: .seconds(10)) {
            guard let traversal = index.pendingDirectoryTraversalPathsForTesting(path: folder.path)
            else { return false }
            return Set(traversal.deferredRetries) == Set([lookupFailure, enumerationFailure])
                && index.search(SearchRequest(
                    query: healthyMarker.lastPathComponent,
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == healthyMarker.path }
        }
        #expect(!completion.isMarked)

        index.failNextFileSystemLookupsForTesting(path: lookupFailure, count: 0)
        index.failNextDirectoryUpdateEnumerationsForTesting(path: enumerationFailure, count: 0)
        index.promotePendingRefreshForTesting(path: folder.path)
        try await waitUntil(timeout: .seconds(10)) {
            completion.isMarked && index.currentDiagnostics().pendingRefreshPathCount == 0
        }
    }

    @Test("bounded directory progress caps incremental persistence amplification")
    func boundedDirectoryProgressCapsIncrementalPersistence() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 0.05,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 1,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let addedDirectory = root.appendingPathComponent("AddedDirectory", isDirectory: true)
        try fileManager.createDirectory(at: addedDirectory, withIntermediateDirectories: true)
        for offset in 0..<20 {
            try "added".write(
                to: addedDirectory.appendingPathComponent("Added\(offset).swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        index.update(paths: [addedDirectory.path], priority: .background)

        try await waitUntil(timeout: .seconds(5)) {
            guard let progress = index.pendingDirectoryRefreshStateForTesting(path: addedDirectory.path) else {
                return false
            }
            return progress.incrementalPublishBatchCount == 4
                && progress.unpublishedRecordCount > 0
        }
        let progress = try #require(
            index.pendingDirectoryRefreshStateForTesting(path: addedDirectory.path)
        )
        #expect(progress.incrementalPublishBatchCount == 4)
        #expect(progress.incrementallyPublishedChangeCount <= 2_048)
        #expect(progress.unpublishedRecordCount > 0)

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().pendingRefreshPathCount == 0
        }
        #expect(index.search(SearchRequest(
            query: "Added19",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains {
            $0.record.path == addedDirectory.appendingPathComponent("Added19.swift").path
        })
    }

    @Test("directory removed after transient enumeration failure is deleted on retry")
    func directoryRemovedAfterEnumerationFailureIsDeleted() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let vanishing = folder.appendingPathComponent("Vanishing", isDirectory: true)
        try fileManager.createDirectory(at: vanishing, withIntermediateDirectories: true)
        try "existing".write(
            to: vanishing.appendingPathComponent("Existing.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 0.5,
            backgroundDirectoryScanBudget: 60,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        index.failNextDirectoryUpdateEnumerationsForTesting(path: vanishing.path)
        let completion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) { completion.mark() }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: folder.path) != nil
        }
        try fileManager.removeItem(at: vanishing)

        try await waitUntil(timeout: .seconds(5)) {
            completion.isMarked
                && index.search(SearchRequest(
                    query: "Vanishing",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).totalMatches == 0
        }
    }

    @Test("redundant directory refresh preserves progress and schedules one follow-up pass")
    func redundantDirectoryRefreshPreservesProgressAndSchedulesFollowUp() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        for offset in 0..<5_000 {
            let file = folder.appendingPathComponent("Existing\(offset).swift")
            try "existing".write(to: file, atomically: true, encoding: .utf8)
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0.01,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(20)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let createdFile = folder.appendingPathComponent("CreatedDuringCatchup.swift")
        try "created".write(to: createdFile, atomically: true, encoding: .utf8)
        index.update(paths: [folder.path], priority: .background)

        try await waitUntil(timeout: .seconds(10)) {
            guard let state = index.pendingDirectoryRefreshStateForTesting(path: folder.path) else {
                return false
            }
            return state.recordCount > 0
        }
        let progressBeforeDuplicate = try #require(
            index.pendingDirectoryRefreshStateForTesting(path: folder.path)
        )

        index.update(paths: [folder.path], priority: .background)

        let progressAfterDuplicate = try #require(
            index.pendingDirectoryRefreshStateForTesting(path: folder.path)
        )
        #expect(progressAfterDuplicate.recordCount == progressBeforeDuplicate.recordCount)
        #expect(progressAfterDuplicate.requiresFollowUp)

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(20)) {
            let response = index.search(SearchRequest(
                query: "CreatedDuringCatchup",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            return index.currentDiagnostics().pendingRefreshPathCount == 0
                && response.results.contains { $0.record.path == createdFile.path }
        }
    }

    @Test("completed directory pass releases its receipt before a newer follow-up pass")
    func completedDirectoryPassReleasesCoveredCompletion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for offset in 0..<40 {
            try fileManager.createDirectory(
                at: folder.appendingPathComponent("Child\(offset)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 0.02,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 1,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let firstCompletion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) { firstCompletion.mark() }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: folder.path) != nil
        }

        let followUpCompletion = CompletionFlag()
        index.update(paths: [folder.path], priority: .background) { followUpCompletion.mark() }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: folder.path)?.requiresFollowUp == true
        }

        try await waitUntil(timeout: .seconds(10)) { firstCompletion.isMarked }
        #expect(!followUpCompletion.isMarked)
        #expect(
            index.pendingRefreshPathsForTesting().contains(folder.path)
                || index.currentStats().isUpdating
        )

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            followUpCompletion.isMarked
                && index.currentDiagnostics().pendingRefreshPathCount == 0
        }
    }

    @Test("exact metadata events do not turn a recursive follow-up into another subtree scan")
    func exactEventKeepsDirectoryFollowUpExact() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for offset in 0..<20 {
            try fileManager.createDirectory(
                at: folder.appendingPathComponent("Child\(offset)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 1,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        index.update(paths: [folder.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: folder.path) != nil
        }
        index.update(
            exactPaths: [folder.path],
            recursivePaths: [],
            priority: .background
        )
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: folder.path)?.requiresFollowUp == true
        }
        let state = try #require(index.pendingDirectoryRefreshStateForTesting(path: folder.path))
        #expect(state.recursivelyScansDirectory)
        #expect(!state.followUpRecursivelyScansDirectory)

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().pendingRefreshPathCount == 0
        }
    }

    @Test("directory catch up retains descendant events queued after the scan starts")
    func directoryCatchUpRetainsNewerDescendantEvents() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        for offset in 0..<1_000 {
            try "existing".write(
                to: folder.appendingPathComponent("Existing\(offset).swift"),
                atomically: true,
                encoding: .utf8
            )
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshBatchLimit: 512,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 60,
            backgroundDirectoryScanVisitLimit: 1,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(20)) {
            !index.currentStats().isIndexing
        }

        index.update(paths: [folder.path], priority: .background)
        try await waitUntil(timeout: .seconds(10)) {
            index.pendingDirectoryRefreshStateForTesting(path: folder.path) != nil
        }

        let lateFile = folder.appendingPathComponent("LateEvent.swift")
        try "late".write(to: lateFile, atomically: true, encoding: .utf8)
        let completion = CompletionFlag()
        index.update(paths: [lateFile.path], priority: .background) { completion.mark() }

        try await waitUntil(timeout: .seconds(5)) {
            completion.isMarked
                && index.search(SearchRequest(
                    query: "LateEvent",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == lateFile.path }
        }
        #expect(index.pendingRefreshPathsForTesting().contains(folder.path))

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            index.currentDiagnostics().pendingRefreshPathCount == 0
                && index.search(SearchRequest(
                    query: "LateEvent",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == lateFile.path }
        }
    }

    @Test("automatic snapshot persistence waits for refresh backlog")
    func automaticSnapshotPersistenceWaitsForRefreshBacklog() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let blocker = root.appendingPathComponent("Blocker", isDirectory: true)
        try fileManager.createDirectory(at: blocker, withIntermediateDirectories: true)
        try "existing".write(
            to: blocker.appendingPathComponent("Existing.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? fileManager.removeItem(at: root)
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 60,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 0.5
        )
        let rootRecord = try #require(FileRecord(url: root))
        let blockerRecord = try #require(FileRecord(url: blocker))
        let existingRecord = try #require(FileRecord(
            url: blocker.appendingPathComponent("Existing.swift")
        ))
        index.replaceRecordsForTesting(
            [rootRecord, blockerRecord, existingRecord],
            roots: [root]
        )

        let createdFile = root.appendingPathComponent("Created.swift")
        try "created".write(to: createdFile, atomically: true, encoding: .utf8)
        index.update(paths: [createdFile.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.recordStoreKind == .overlay
                && index.search(SearchRequest(
                    query: "Created",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == createdFile.path }
        }

        index.update(paths: [blocker.path], priority: .background)
        try await waitUntil(timeout: .seconds(5)) {
            index.currentDiagnostics().pendingBackgroundRefreshPathCount == 1
        }
        try await Task.sleep(for: .seconds(1))
        #expect(index.currentDiagnostics().recordStoreKind == .overlay)

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.pendingRefreshPathCount == 0
                && diagnostics.recordStoreKind == .mapped
        }
    }

    @Test("background structural update defers search optimization until promotion")
    func backgroundStructuralUpdateDefersSearchOptimizationUntilPromotion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let existingFile = root.appendingPathComponent("Existing.swift")
        try "existing".write(to: existingFile, atomically: true, encoding: .utf8)

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: 1,
            largeOverlayPersistDelay: nil,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let before = index.currentDiagnostics()
        let addedFile = root.appendingPathComponent("BackgroundAdded.swift")
        try "added".write(to: addedFile, atomically: true, encoding: .utf8)
        index.update(paths: [addedFile.path], priority: .background)

        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.completedRefreshBatches > before.completedRefreshBatches
                && diagnostics.recordStoreKind == .overlay
                && diagnostics.optimizedCount == 0
                && diagnostics.pendingRefreshPathCount == 0
        }
        let overlayRevision = index.currentDiagnostics().snapshotRevision

        index.promoteBackgroundMaintenance()

        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.snapshotRevision > overlayRevision
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }
    }

    @Test("queued refreshes continue draining after the maximum batch")
    func queuedRefreshesContinueDrainingAfterMaximumBatch() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 1
        }

        let beforeDiagnostics = index.currentDiagnostics()
        let fileCount = 650
        let files = try (0..<fileCount).map { offset in
            let file = root.appendingPathComponent("QueuedRefresh\(offset).swift")
            try "queued \(offset)".write(to: file, atomically: true, encoding: .utf8)
            return file
        }

        index.update(paths: files.map(\.path))

        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            let response = index.search(SearchRequest(
                query: "QueuedRefresh",
                sort: SortSpec(column: .name, ascending: true)
            ), maxResults: fileCount + 10)
            return diagnostics.completedRefreshBatches >= beforeDiagnostics.completedRefreshBatches + 2
                && response.totalMatches == fileCount
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
        index.replaceRecordsForTesting(
            records,
            roots: [URL(fileURLWithPath: "/tmp", isDirectory: true)]
        )

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

    @Test("exact directory refresh updates only the directory record")
    func exactDirectoryRefreshDoesNotTraverseChildren() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let directory = root.appendingPathComponent("Incoming", isDirectory: true)
        let child = directory.appendingPathComponent("AlreadyPresent.swift")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try "child".write(to: child, atomically: true, encoding: .utf8)

        let exactCompletion = CompletionFlag()
        index.update(
            exactPaths: [root.path + "/Unused/../Incoming"],
            recursivePaths: [],
            completion: { exactCompletion.mark() }
        )
        try await waitUntil(timeout: .seconds(5)) { exactCompletion.isMarked }
        #expect(index.search(SearchRequest(
            query: "Incoming",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == directory.path })
        #expect(index.search(SearchRequest(
            query: "AlreadyPresent",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).totalMatches == 0)

        let exactChildCompletion = CompletionFlag()
        index.update(
            exactPaths: [directory.path, child.path],
            recursivePaths: [],
            completion: { exactChildCompletion.mark() }
        )
        try await waitUntil(timeout: .seconds(5)) { exactChildCompletion.isMarked }
        #expect(index.search(SearchRequest(
            query: "AlreadyPresent",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == child.path })

        let recursivelyDiscovered = directory.appendingPathComponent("DiscoveredRecursively.swift")
        try "recursive".write(to: recursivelyDiscovered, atomically: true, encoding: .utf8)
        let recursiveCompletion = CompletionFlag()
        index.update(
            exactPaths: [],
            recursivePaths: [directory.path],
            completion: { recursiveCompletion.mark() }
        )
        try await waitUntil(timeout: .seconds(5)) { recursiveCompletion.isMarked }
        #expect(index.search(SearchRequest(
            query: "DiscoveredRecursively",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10).results.contains { $0.record.path == recursivelyDiscovered.path })
    }

    @Test("updates outside configured roots are discarded without traversal")
    func updatesOutsideConfiguredRootsAreDiscarded() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Indexed", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside".write(
            to: outside.appendingPathComponent("OutsideOnly.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? fileManager.removeItem(at: base)
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil {
            !index.currentStats().isIndexing
        }
        let before = index.currentDiagnostics()

        await withCheckedContinuation { continuation in
            index.update(paths: [outside.path]) {
                continuation.resume()
            }
        }

        let after = index.currentDiagnostics()
        let response = index.search(SearchRequest(
            query: "OutsideOnly",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(after.completedRefreshBatches == before.completedRefreshBatches)
        #expect(after.pendingRefreshPathCount == 0)
        #expect(response.totalMatches == 0)
    }

    @Test("deferred updates from removed roots are discarded after rebuild")
    func deferredUpdatesFromRemovedRootsAreDiscarded() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let removedRoot = base.appendingPathComponent("Removed", isDirectory: true)
        let retainedRoot = base.appendingPathComponent("Retained", isDirectory: true)
        let deferredFolder = removedRoot.appendingPathComponent("Deferred", isDirectory: true)
        try fileManager.createDirectory(at: deferredFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: retainedRoot, withIntermediateDirectories: true)
        let retainedFile = retainedRoot.appendingPathComponent("Retained.swift")
        try "retained".write(to: retainedFile, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: base) }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        defer { try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName)) }
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: nil,
            backgroundRefreshDrainBackoffDelay: 3_600,
            backgroundDirectoryScanBudget: 0,
            backgroundOptimizationPersistDelay: 60
        )
        index.replaceRootsAndRebuild([removedRoot], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) { !index.currentStats().isIndexing }

        let staleFile = deferredFolder.appendingPathComponent("StaleAfterRootChange.swift")
        try "stale".write(to: staleFile, atomically: true, encoding: .utf8)
        let completion = CompletionFlag()
        index.update(paths: [deferredFolder.path], priority: .background) {
            completion.mark()
        }
        try await waitUntil(timeout: .seconds(5)) {
            index.pendingDirectoryRefreshStateForTesting(path: deferredFolder.path) != nil
        }
        #expect(!completion.isMarked)

        index.replaceRootsAndRebuild([retainedRoot], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            !index.currentStats().isIndexing
                && index.search(SearchRequest(
                    query: "Retained",
                    sort: SortSpec(column: .relevance, ascending: false)
                ), maxResults: 10).results.contains { $0.record.path == retainedFile.path }
        }

        index.promoteBackgroundMaintenance()
        try await waitUntil(timeout: .seconds(10)) {
            completion.isMarked && index.currentDiagnostics().pendingRefreshPathCount == 0
        }
        let staleResponse = index.search(SearchRequest(
            query: "StaleAfterRootChange",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(staleResponse.totalMatches == 0)
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

    @Test("empty query name sort returns first page without walking full ordered snapshot")
    func emptyQueryNameSortReturnsFirstPageWithoutWalkingFullOrderedSnapshot() {
        let records = (0..<2_500).reversed().map { index in
            makeRecord(path: String(format: "/tmp/att-empty-name-sort/File%04d.txt", index))
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)

        let response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true)
        ), maxResults: 10)

        #expect(response.totalMatches == records.count)
        #expect(response.results.map(\.record.name) == (0..<10).map { String(format: "File%04d.txt", $0) })
        #expect(response.executionProfile.executionPath == .emptyQuerySortedOrder)
        #expect(response.executionProfile.scannedRowCount <= 10)
    }

    @Test("empty query name sort promotes ready unsorted snapshots")
    func emptyQueryNameSortPromotesReadyUnsortedSnapshots() {
        let recordCount = 100_050
        let records = (0..<recordCount).reversed().map { index in
            makeRecord(path: String(format: "/tmp/att-empty-unsorted-name-sort/File%06d.txt", index))
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records, buildsSearchStructures: false, phase: .ready)
        index.markSnapshotDurabilityPendingForTesting()
        let revisionsBeforePromotion = index.durabilityRevisionsForTesting()

        let firstResponse = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 10)
        let secondResponse = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 10)

        let expectedNames = (0..<10).map { String(format: "File%06d.txt", $0) }
        let revisionsAfterPromotion = index.durabilityRevisionsForTesting()
        #expect(revisionsAfterPromotion.snapshot > revisionsBeforePromotion.snapshot)
        #expect(revisionsAfterPromotion.unpersisted == revisionsAfterPromotion.snapshot)
        #expect(firstResponse.totalMatches == recordCount)
        #expect(firstResponse.results.map(\.record.name) == expectedNames)
        #expect(firstResponse.executionProfile.executionPath == .emptyQuerySortedOrder)
        #expect(firstResponse.executionProfile.scannedRowCount <= 10)
        #expect(secondResponse.totalMatches == recordCount)
        #expect(secondResponse.results.map(\.record.name) == expectedNames)
        #expect(secondResponse.executionProfile.scannedRowCount <= 10)
    }

    @Test("empty query modified sort promotes ready unsorted snapshots")
    func emptyQueryModifiedSortPromotesReadyUnsortedSnapshots() {
        let recordCount = 100_050
        let records = (0..<recordCount).reversed().map { index in
            makeRecord(
                path: String(format: "/tmp/att-empty-unsorted-modified-sort/File%06d.txt", index),
                modifiedTime: TimeInterval(index)
            )
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records, buildsSearchStructures: false, phase: .ready)

        let firstResponse = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false
        ), maxResults: 10)
        let secondResponse = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false
        ), maxResults: 10)

        let expectedNames = (0..<10).map { offset in
            String(format: "File%06d.txt", recordCount - offset - 1)
        }
        #expect(firstResponse.totalMatches == recordCount)
        #expect(firstResponse.results.map(\.record.name) == expectedNames)
        #expect(firstResponse.executionProfile.executionPath == .emptyQuerySortedOrder)
        #expect(firstResponse.executionProfile.scannedRowCount <= 10)
        #expect(secondResponse.totalMatches == recordCount)
        #expect(secondResponse.results.map(\.record.name) == expectedNames)
        #expect(secondResponse.executionProfile.scannedRowCount <= 10)
    }

    @Test("empty query additional sort skips missing sidecar rebuild")
    func emptyQueryAdditionalSortSkipsMissingSidecarRebuild() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let recordCount = 5_000
        let records = (0..<recordCount).map { offset in
            makeRecord(
                path: String(format: "/tmp/att-empty-created-missing-sidecar/File%06d.swift", offset),
                createdTime: TimeInterval(recordCount - offset)
            )
        }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.updateOptimizedSortColumns([.name, .modified])
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        let createdOrderURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.createdOrder)
        try Data().write(to: createdOrderURL)

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        reloaded.setExactEmptyQuerySortLimitForTesting(100)
        let response = reloaded.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .created, ascending: true),
            includeHidden: false
        ), maxResults: 10)

        #expect(response.totalMatches == recordCount)
        #expect(response.executionProfile.executionPath == .emptyQuerySortedOrder)
        #expect(response.executionProfile.scannedRowCount <= 20)
        #expect(response.results.map(\.record.path) == records.prefix(10).map(\.path))
        #expect(response.results.first?.record.path != records.last?.path)
    }

    @Test("mapped persistence preserves missing additional sort sidecars")
    func mappedPersistencePreservesMissingAdditionalSortSidecars() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let recordCount = 1_000
        let records = (0..<recordCount).map { offset in
            makeRecord(
                path: String(format: "/tmp/att-persist-missing-created-sidecar/File%06d.swift", offset),
                createdTime: TimeInterval(recordCount - offset)
            )
        }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.updateOptimizedSortColumns([.name, .modified])
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        let createdOrderURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.createdOrder)
        try Data().write(to: createdOrderURL)

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.allOptimizedSortColumns().contains(.created))
        #expect(fileSize(at: createdOrderURL) == 0)

        reloaded.persistSnapshotForTesting()

        #expect(fileSize(at: createdOrderURL) == 0)
    }

    @Test("mapped persistence keeps virtual ancestors out of search results")
    func mappedPersistenceKeepsVirtualAncestorsOutOfSearchResults() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let root = URL(fileURLWithPath: "/tmp/att-virtual-persist-\(UUID().uuidString)/Project", isDirectory: true)
        let records = [
            makeRecord(path: root.path, isDirectory: true),
            makeRecord(path: root.appendingPathComponent("Main.swift").path)
        ]
        let expectedPaths = records.map(\.path).sorted()
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting(records, roots: [root])

        index.persistSnapshotForTesting()
        let initiallyMapped = index.currentDiagnostics()
        #expect(initiallyMapped.recordStoreKind == .mapped)
        #expect(initiallyMapped.indexedCount == records.count)
        #expect(initiallyMapped.virtualRowCount > 0)

        // Persist the already-mapped store again. Virtual rows are necessary for
        // hierarchy traversal, but must not become real result rows when compacted.
        index.persistSnapshotForTesting()

        let response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .path, ascending: true),
            includeHidden: true
        ), maxResults: 100)
        #expect(response.totalMatches == records.count)
        #expect(response.results.map(\.record.path) == expectedPaths)
        #expect(index.currentDiagnostics().virtualRowCount > 0)

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let reloadedResponse = reloaded.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .path, ascending: true),
            includeHidden: true
        ), maxResults: 100)
        #expect(reloadedResponse.totalMatches == records.count)
        #expect(reloadedResponse.results.map(\.record.path) == expectedPaths)
        #expect(reloaded.currentDiagnostics().virtualRowCount > 0)
    }

    @Test("degraded active search scans bounded rows and optimized search returns rich totals")
    func degradedActiveSearchScansBoundedRowsAndOptimizedSearchReturnsRichTotals() {
        let recordCount = 30_000
        var records = (0..<recordCount).map { index in
            makeRecord(path: String(format: "/tmp/att-degraded-search/File%06d.txt", index))
        }
        let earlyNeedle = "/tmp/att-degraded-search/NeedleEarly.swift"
        let lateNeedle = "/tmp/att-degraded-search/NeedleLate.swift"
        records[100] = makeRecord(path: earlyNeedle)
        records[26_000] = makeRecord(path: lateNeedle)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(
            records,
            buildsSearchStructures: false,
            phase: .ready,
            prefersDegradedSearch: true
        )

        let degraded = index.search(SearchRequest(
            query: "Needle",
            sort: SortSpec(column: .relevance, ascending: false),
            mode: .interactivePreview
        ), maxResults: 10)

        #expect(degraded.results.map(\.record.path) == [earlyNeedle])
        #expect(degraded.totalMatches == 1)
        #expect(degraded.executionProfile.scannedRowCount == 25_000)
        #expect(degraded.executionProfile.scannedRowCount < recordCount)
        #expect(!degraded.executionProfile.didFallbackToFullScan)

        let complete = index.search(SearchRequest(
            query: "Needle",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)

        #expect(complete.totalMatches == 2)
        #expect(Set(complete.results.map(\.record.path)) == [earlyNeedle, lateNeedle])
        #expect(complete.executionProfile.scannedRowCount == recordCount)
        #expect(complete.executionProfile.didFallbackToFullScan)

        index.replaceRecordsForTesting(records, buildsSearchStructures: true, phase: .ready)
        let optimized = index.search(SearchRequest(
            query: ".swift",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)

        #expect(optimized.totalMatches == 2)
        #expect(Set(optimized.results.map(\.record.path)) == [earlyNeedle, lateNeedle])
        #expect(!optimized.executionProfile.didFallbackToFullScan)
        #expect(optimized.executionProfile.scannedRowCount < recordCount)
    }

    @Test("large unoptimized overlay searches use last optimized candidates")
    func largeUnoptimizedOverlaySearchesUseLastOptimizedCandidates() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let changedFolder = root.appendingPathComponent("Changed", isDirectory: true)
        try fileManager.createDirectory(at: changedFolder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            largeOverlayPersistRecordLimit: nil,
            largeOverlayPersistDelay: 60
        )
        defer {
            try? fileManager.removeItem(at: index.dataDirectoryURL)
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }

        var records = [
            makeRecord(path: root.path, isDirectory: true),
            makeRecord(path: changedFolder.path, isDirectory: true)
        ]
        records.reserveCapacity(30_003)
        for offset in 0..<30_000 {
            records.append(makeRecord(
                path: root.appendingPathComponent("Stable/File\(String(format: "%06d", offset)).swift").path,
                modifiedTime: TimeInterval(offset)
            ))
        }
        let lateNeedle = root.appendingPathComponent("Stable/zzzz-AitoNeedle.swift").path
        records.append(makeRecord(path: lateNeedle, modifiedTime: 40_000))
        let removedNeedle = changedFolder.appendingPathComponent("RemovedNeedle.swift").path
        records.append(makeRecord(path: removedNeedle, modifiedTime: 40_001))

        index.replaceRecordsForTesting(records, roots: [root])
        let optimizedResponse = index.search(SearchRequest(
            query: "AitoNeedle",
            sort: SortSpec(column: .name, ascending: true),
            mode: .interactivePreview
        ), maxResults: 10)
        #expect(optimizedResponse.usesIndexedCandidates)
        #expect(optimizedResponse.results.map { $0.record.path } == [lateNeedle])

        let changedFile = changedFolder.appendingPathComponent("Changed.swift")
        try "changed".write(to: changedFile, atomically: true, encoding: .utf8)
        let before = index.currentDiagnostics()
        index.update(paths: [changedFolder.path], priority: IndexWorkPriority.background)

        try await waitUntil(timeout: .seconds(5)) {
            let diagnostics = index.currentDiagnostics()
            return diagnostics.completedRefreshBatches > before.completedRefreshBatches
                && diagnostics.recordStoreKind == .overlay
                && diagnostics.optimizedCount == 0
        }

        for sortColumn in SortColumn.allCases {
            let response = index.search(SearchRequest(
                query: "AitoNeedle",
                sort: SortSpec(column: sortColumn, ascending: sortColumn != .relevance),
                mode: .interactivePreview
            ), maxResults: 10)
            let profileSummary = "sort: \(sortColumn.rawValue), path: \(response.executionProfile.executionPath.rawValue), candidates: \(response.executionProfile.candidateCount), scanned: \(response.executionProfile.scannedRowCount)"

            #expect(response.usesIndexedCandidates, "\(profileSummary)")
            #expect(response.executionProfile.executionPath != SearchExecutionPath.fullFallbackScan, "\(profileSummary)")
            #expect(response.totalMatches == 1, "\(profileSummary)")
            #expect(response.results.map { $0.record.path } == [lateNeedle], "\(profileSummary)")
        }

        let addedResponse = index.search(SearchRequest(
            query: "Changed.swift",
            sort: SortSpec(column: .relevance, ascending: false),
            mode: .interactivePreview
        ), maxResults: 10)
        #expect(addedResponse.usesIndexedCandidates)
        #expect(addedResponse.totalMatches == 1)
        #expect(addedResponse.results.map(\.record.path) == [changedFile.path])

        let removedResponse = index.search(SearchRequest(
            query: "RemovedNeedle",
            sort: SortSpec(column: .relevance, ascending: false),
            mode: .interactivePreview
        ), maxResults: 10)
        #expect(removedResponse.usesIndexedCandidates)
        #expect(removedResponse.totalMatches == 0)
        #expect(removedResponse.results.isEmpty)
    }

    @Test("broad preview searches are bounded for every sort column")
    func broadPreviewSearchesAreBoundedForEverySortColumn() {
        let recordCount = 8_000
        let rootA = "/tmp/att-broad-preview-sort/a-root"
        let rootZ = "/tmp/att-broad-preview-sort/z-root"
        let extensions = ["swift", "md", "cpp", "txt"]
        let records = (0..<recordCount).map { offset in
            let root = offset.isMultiple(of: 2) ? rootA : rootZ
            let isApplication = offset.isMultiple(of: 211)
            let isFolder = !isApplication && offset.isMultiple(of: 97)
            let suffix = isApplication ? ".app" : (isFolder ? "" : ".\(extensions[offset % extensions.count])")
            return makeRecord(
                path: String(format: "\(root)/bucket-%03d/AitoFile%06d\(suffix)", offset % 37, offset),
                isDirectory: isApplication || isFolder,
                modifiedTime: TimeInterval(offset),
                createdTime: TimeInterval(recordCount - offset),
                sizeBytes: UInt64((offset * 37) % 100_000 + 1),
                volumeName: "Volume-\(offset % 9)"
            )
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records, roots: [
            URL(fileURLWithPath: rootA, isDirectory: true),
            URL(fileURLWithPath: rootZ, isDirectory: true)
        ])

        for sortColumn in SortColumn.optimizedIndexColumns {
            for ascending in [true, false] {
                let sort = SortSpec(column: sortColumn, ascending: ascending)
                let response = index.search(SearchRequest(
                    query: "aito",
                    sort: sort,
                    mode: .interactivePreview
                ), maxResults: 20)
                let ascendingExpectedRecords = expectedSortedRecords(
                    records,
                    sort: SortSpec(column: sortColumn, ascending: true),
                    roots: [rootA, rootZ]
                )
                let expectedRecords = ascending ? ascendingExpectedRecords : Array(ascendingExpectedRecords.reversed())
                let expectedPaths = expectedRecords
                    .prefix(20)
                    .map(\.path)
                let profileSummary = "sort: \(sortColumn.rawValue), ascending: \(ascending), path: \(response.executionProfile.executionPath.rawValue), candidates: \(response.executionProfile.candidateCount), scanned: \(response.executionProfile.scannedRowCount)"

                #expect(response.usesIndexedCandidates, "\(profileSummary)")
                #expect(response.executionProfile.executionPath != SearchExecutionPath.fullFallbackScan, "\(profileSummary)")
                #expect(!response.executionProfile.didFallbackToFullScan, "\(profileSummary)")
                #expect(response.executionProfile.indexesUsed.contains(sortColumn == .modified ? .modifiedOrder : .sortOrder), "\(profileSummary)")
                #expect(response.executionProfile.candidateCount > 0, "\(profileSummary)")
                #expect(response.executionProfile.candidateCount <= recordCount, "\(profileSummary)")
                #expect(response.executionProfile.scannedRowCount <= 40, "\(profileSummary)")
                if sortColumn != .root {
                    #expect(response.results.map(\.record.path) == Array(expectedPaths), "\(profileSummary)")
                }
            }
        }
    }

    @Test("optimized sort columns rank sparse candidates instead of scanning sorted order")
    func optimizedSortColumnsRankSparseCandidatesInsteadOfScanningSortedOrder() {
        let recordCount = 30_000
        let rootA = "/tmp/att-sparse-sort-parity/a-root"
        let rootZ = "/tmp/att-sparse-sort-parity/z-root"
        var records: [FileRecord] = []
        records.reserveCapacity(recordCount + 8)
        for offset in 0..<recordCount {
            records.append(makeRecord(
                path: String(format: "\(rootA)/stable/File%06d.swift", offset),
                modifiedTime: TimeInterval(offset),
                createdTime: TimeInterval(offset),
                sizeBytes: UInt64(offset + 1)
            ))
        }

        var matchingRecords: [FileRecord] = []
        matchingRecords.reserveCapacity(8)
        for offset in 0..<8 {
            let path = String(format: "%@/zzzz/AitoNeedle%02d.swift", rootZ, offset)
            let timestamp = TimeInterval(100_000 + offset)
            matchingRecords.append(makeRecord(
                path: path,
                modifiedTime: timestamp,
                createdTime: timestamp,
                sizeBytes: UInt64(100_000 + offset)
            ))
        }
        records.append(contentsOf: matchingRecords)

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records, roots: [
            URL(fileURLWithPath: rootA, isDirectory: true),
            URL(fileURLWithPath: rootZ, isDirectory: true)
        ])

        for sortColumn in SortColumn.optimizedIndexColumns {
            let sort = SortSpec(column: sortColumn, ascending: true)
            let response = index.search(SearchRequest(
                query: "AitoNeedle",
                sort: sort,
                mode: .interactivePreview
            ), maxResults: 5)
            let expectedNames = expectedSortedRecords(matchingRecords, sort: sort, roots: [rootA, rootZ])
                .prefix(5)
                .map(\.name)
            let profileSummary = "sort: \(sortColumn.rawValue), path: \(response.executionProfile.executionPath.rawValue), candidates: \(response.executionProfile.candidateCount), scanned: \(response.executionProfile.scannedRowCount)"
            let directlySortsNameCandidates = sortColumn == .name

            #expect(response.usesIndexedCandidates, "\(profileSummary)")
            #expect(
                response.executionProfile.executionPath
                    == (directlySortsNameCandidates ? .nameComponentIndex : .optimizedSortedFastPath),
                "\(profileSummary)"
            )
            #expect(!response.executionProfile.didFallbackToFullScan, "\(profileSummary)")
            if directlySortsNameCandidates {
                #expect(response.executionProfile.indexesUsed.contains(.nameGrams), "\(profileSummary)")
                #expect(!response.executionProfile.indexesUsed.contains(.sortOrder), "\(profileSummary)")
            } else {
                #expect(
                    response.executionProfile.indexesUsed.contains(
                        sortColumn == .modified ? .modifiedOrder : .sortOrder
                    ),
                    "\(profileSummary)"
                )
            }
            #expect(response.executionProfile.scannedRowCount <= matchingRecords.count, "\(profileSummary)")
            #expect(response.results.map(\.record.name) == Array(expectedNames), "\(profileSummary)")
        }
    }

    @Test("created descending preview falls back from empty ordered prefix to ranked candidates")
    func createdDescendingPreviewFallsBackFromEmptyOrderedPrefixToRankedCandidates() {
        let fillerCount = 30_000
        let matchCount = 1_500
        var records: [FileRecord] = []
        records.reserveCapacity(fillerCount + matchCount)
        for offset in 0..<fillerCount {
            records.append(makeRecord(
                path: String(format: "/tmp/att-created-descending/new/File%06d.swift", offset),
                modifiedTime: TimeInterval(100_000 + offset),
                createdTime: TimeInterval(100_000 + offset)
            ))
        }
        for offset in 0..<matchCount {
            records.append(makeRecord(
                path: String(format: "/tmp/att-created-descending/old/AitoNeedle%06d.swift", offset),
                modifiedTime: TimeInterval(offset),
                createdTime: TimeInterval(offset)
            ))
        }

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)

        let response = index.search(SearchRequest(
            query: "aito",
            sort: SortSpec(column: .created, ascending: false),
            mode: .interactivePreview
        ), maxResults: 20)
        let expectedNames = (0..<20).map { offset in
            String(format: "AitoNeedle%06d.swift", matchCount - offset - 1)
        }

        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(response.executionProfile.indexesUsed.contains(.sortOrder))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.candidateCount >= matchCount)
        #expect(response.executionProfile.scannedRowCount <= matchCount)
        #expect(response.results.map(\.record.name) == expectedNames)
    }

    @Test("created sort preview uses optimized sort order by default")
    func createdSortPreviewUsesOptimizedSortOrderByDefault() {
        let recordCount = 5_000
        let records = (0..<recordCount).map { offset in
            makeRecord(
                path: String(format: "/tmp/att-created-sort-preview/AitoFile%06d.swift", offset),
                modifiedTime: TimeInterval(recordCount - offset),
                createdTime: TimeInterval(offset)
            )
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)

        let response = index.search(SearchRequest(
            query: "aito",
            sort: SortSpec(column: .created, ascending: true),
            mode: .interactivePreview
        ), maxResults: 20)

        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.sortOrder))
        #expect(response.executionProfile.scannedRowCount <= 20)
        #expect(response.results.map(\.record.name) == (0..<20).map { String(format: "AitoFile%06d.swift", $0) })
    }

    @Test("persisted created sort preview uses name postings and created sidecar without path postings")
    func persistedCreatedSortPreviewUsesNamePostingsAndCreatedSidecarWithoutPathPostings() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let recordCount = 2_000
        let records = (0..<recordCount).map { offset in
            makeRecord(
                path: String(format: "/tmp/att-created-sort-persisted/project-%03d/AitoFile%06d.swift", offset % 256, offset),
                modifiedTime: TimeInterval(recordCount - offset),
                createdTime: TimeInterval(offset)
            )
        }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        #expect(index.currentDiagnostics().pathGramIndexEnabled)
        index.removePathGramAccelerationForTesting()
        #expect(!index.currentDiagnostics().pathGramIndexEnabled)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()
        #expect(diagnostics.recordStoreKind == .mapped)
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.nameGramPostingCount > 0)

        let response = reloaded.search(SearchRequest(
            query: "aito",
            sort: SortSpec(column: .created, ascending: true),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 20)

        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(response.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(response.executionProfile.indexesUsed.contains(.sortOrder))
        #expect(!response.executionProfile.indexesUsed.contains(.pathGrams))
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.scannedRowCount <= 20)
        #expect(response.results.map(\.record.name) == (0..<20).map { String(format: "AitoFile%06d.swift", $0) })

        let emptyPreview = reloaded.search(SearchRequest(
            query: "zzzz",
            sort: SortSpec(column: .created, ascending: true),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 20)
        #expect(emptyPreview.usesIndexedCandidates)
        #expect(emptyPreview.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(emptyPreview.executionProfile.indexesUsed.contains(.nameGrams))
        #expect(emptyPreview.executionProfile.indexesUsed.contains(.sortOrder))
        #expect(!emptyPreview.executionProfile.indexesUsed.contains(.pathGrams))
        #expect(!emptyPreview.executionProfile.didFallbackToFullScan)
        #expect(emptyPreview.executionProfile.scannedRowCount == 0)
        #expect(emptyPreview.results.isEmpty)

        let complete = reloaded.search(SearchRequest(
            query: "aito",
            sort: SortSpec(column: .created, ascending: true),
            includeHidden: false
        ), maxResults: 20)
        #expect(complete.usesIndexedCandidates)
        #expect(complete.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(complete.executionProfile.indexesUsed.contains(.sortOrder))
        #expect(!complete.executionProfile.didFallbackToFullScan)
        #expect(complete.executionProfile.scannedRowCount <= recordCount)
        #expect(complete.results.map(\.record.name) == (0..<20).map { String(format: "AitoFile%06d.swift", $0) })
    }

    @Test("persisted sidecar sort previews use name postings without path postings")
    func persistedSidecarSortPreviewsUseNamePostingsWithoutPathPostings() {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let recordCount = 3_000
        let rootA = "/tmp/att-sidecar-sort-persisted/a-root"
        let rootZ = "/tmp/att-sidecar-sort-persisted/z-root"
        let extensions = ["swift", "md", "cpp", "txt"]
        var records: [FileRecord] = []
        records.reserveCapacity(recordCount)
        for offset in 0..<recordCount {
            let root = offset.isMultiple(of: 2) ? rootA : rootZ
            let isApplication = offset.isMultiple(of: 157)
            let isFolder = !isApplication && offset.isMultiple(of: 71)
            let suffix = isApplication ? ".app" : (isFolder ? "" : ".\(extensions[offset % extensions.count])")
            let path = String(
                format: "\(root)/project-%03d/AitoFile%06d\(suffix)",
                offset % 128,
                offset
            )
            records.append(makeRecord(
                path: path,
                isDirectory: isApplication || isFolder,
                modifiedTime: TimeInterval(recordCount - offset),
                createdTime: TimeInterval(offset),
                sizeBytes: UInt64((offset * 53) % 80_000 + 1),
                volumeName: "Volume-\(offset % 7)"
            ))
        }
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records, roots: [
            URL(fileURLWithPath: rootA, isDirectory: true),
            URL(fileURLWithPath: rootZ, isDirectory: true)
        ])
        index.removePathGramAccelerationForTesting()
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(reloaded.currentDiagnostics().recordStoreKind == .mapped)
        #expect(!reloaded.currentDiagnostics().pathGramIndexEnabled)

        for sortColumn in SortColumn.optimizedIndexColumns {
            let response = reloaded.search(SearchRequest(
                query: "aito",
                sort: SortSpec(column: sortColumn, ascending: true),
                includeHidden: false,
                mode: .interactivePreview
            ), maxResults: 20)
            let expectedPaths = expectedSortedRecords(
                records,
                sort: SortSpec(column: sortColumn, ascending: true),
                roots: [rootA, rootZ]
            )
                .prefix(20)
                .map(\.path)
            let profileSummary = "sort: \(sortColumn.rawValue), path: \(response.executionProfile.executionPath.rawValue), candidates: \(response.executionProfile.candidateCount), scanned: \(response.executionProfile.scannedRowCount)"

            #expect(response.usesIndexedCandidates, "\(profileSummary)")
            #expect(response.executionProfile.executionPath == .optimizedSortedFastPath, "\(profileSummary)")
            #expect(response.executionProfile.indexesUsed.contains(.nameGrams), "\(profileSummary)")
            #expect(response.executionProfile.indexesUsed.contains(sortColumn == .modified ? .modifiedOrder : .sortOrder), "\(profileSummary)")
            #expect(!response.executionProfile.indexesUsed.contains(.pathGrams), "\(profileSummary)")
            #expect(!response.executionProfile.didFallbackToFullScan, "\(profileSummary)")
            #expect(response.executionProfile.scannedRowCount <= 40, "\(profileSummary)")
            if sortColumn != .root {
                #expect(response.results.map(\.record.path) == Array(expectedPaths), "\(profileSummary)")
            }
        }
    }

    @Test("name-sorted previews fall through to path matches when no filename matches")
    func nameSortedPreviewFallsThroughToPathMatches() {
        let rootPath = "/tmp/att-name-preview-fallthrough"
        let matchingPath = "\(rootPath)/NeedleFolder/Ordinary.swift"
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false
        )
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(
            [makeRecord(path: matchingPath)],
            roots: [URL(fileURLWithPath: rootPath, isDirectory: true)]
        )
        index.persistSnapshotForTesting()
        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)

        let response = reloaded.search(SearchRequest(
            query: "NeedleFolder",
            sort: SortSpec(column: .name, ascending: true),
            mode: .interactivePreview
        ), maxResults: 20)

        let profile = response.executionProfile
        let summary = "path: \(profile.executionPath.rawValue), candidates: \(profile.candidateCount), scanned: \(profile.scannedRowCount), indexes: \(profile.indexesUsed.map(\.rawValue).sorted())"
        #expect(response.results.map(\.record.path) == [matchingPath], "\(summary)")
    }

    @Test("disabled created sort index falls back to bounded preview")
    func disabledCreatedSortIndexFallsBackToBoundedPreview() {
        let recordCount = 5_000
        let records = (0..<recordCount).map { offset in
            makeRecord(
                path: String(format: "/tmp/att-disabled-created-sort/AitoFile%06d.swift", offset),
                modifiedTime: TimeInterval(recordCount - offset),
                createdTime: TimeInterval(offset)
            )
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        var enabledColumns = Set(SortColumn.optimizedIndexColumns)
        enabledColumns.remove(.created)
        index.updateOptimizedSortColumns(enabledColumns)
        index.replaceRecordsForTesting(records)

        let response = index.search(SearchRequest(
            query: "aito",
            sort: SortSpec(column: .created, ascending: true),
            mode: .interactivePreview
        ), maxResults: 20)

        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath != .optimizedSortedFastPath)
        #expect(!response.executionProfile.indexesUsed.contains(.sortOrder))
        #expect(response.executionProfile.scannedRowCount <= 50_000)
        #expect(response.results.count == 20)
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
        let finderHiddenFile = root.appendingPathComponent("FinderHidden.swift")
        let hiddenDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let hiddenChild = hiddenDirectory.appendingPathComponent("config")
        try fileManager.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try "visible".write(to: visibleFile, atomically: true, encoding: .utf8)
        try "secret".write(to: hiddenFile, atomically: true, encoding: .utf8)
        try "finder hidden".write(to: finderHiddenFile, atomically: true, encoding: .utf8)
        try "config".write(to: hiddenChild, atomically: true, encoding: .utf8)
        let chflagsResult = chflags(finderHiddenFile.path, UInt32(UF_HIDDEN))
        #expect(chflagsResult == 0)
        defer {
            _ = chflags(finderHiddenFile.path, 0)
        }

        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)")
        index.replaceRootsAndRebuild([root])

        try await waitUntil {
            let stats = index.currentStats()
            return !stats.isIndexing && stats.indexedCount >= 6
        }

        var response = index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 20)
        #expect(response.results.contains { $0.record.path == visibleFile.path })
        #expect(!response.results.contains { $0.record.path == hiddenFile.path })
        #expect(!response.results.contains { $0.record.path == finderHiddenFile.path })
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

        response = index.search(SearchRequest(
            query: "FinderHidden",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: true
        ), maxResults: 20)
        #expect(response.results.contains { $0.record.path == finderHiddenFile.path })
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
        #expect(!diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.pathGramPostingCount == 0)
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

    @Test("persisted complete path gram sidecars reload")
    func persistedCompletePathGramSidecarsReload() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/allthethings-tests/project/Sources/SearchWindowController.swift"),
            makeRecord(path: "/tmp/allthethings-tests/project/README.md")
        ])
        index.persistSnapshotForTesting()
        index.completePathGramIndexForTesting()
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()

        #expect(diagnostics.recordStoreKind == .mapped)
        #expect(diagnostics.pathGramIndexEnabled)
        #expect(diagnostics.pathGramPostingCount > 0)
        #expect(diagnostics.pathGramCoveredRowCount == diagnostics.pathGramTotalRowCount)
        #expect(reloaded.search(SearchRequest(
            query: "path:Sources/SearchWindowController",
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

    @Test("missing v7 sidecars load unoptimized persisted records")
    func missingV7SidecarsLoadUnoptimizedPersistedRecords() async throws {
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
        try await waitUntil {
            index.currentDiagnostics().activeIndexJobs == 0
        }

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        try FileManager.default.removeItem(at: packageURL.appendingPathComponent(SnapshotLayout.FileName.modifiedOrder))

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()
        #expect(diagnostics.indexedCount == 1)
        #expect(diagnostics.recordStoreKind == .mapped)
        #expect(FileManager.default.fileExists(atPath: packageURL.path))

        let response = reloaded.search(SearchRequest(
            query: "Alpha",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.map(\.record.name) == ["Alpha.swift"])
    }

    @Test("empty required v7 sidecars load unoptimized persisted records")
    func emptyRequiredV7SidecarsLoadUnoptimizedPersistedRecords() async throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/att-query-regression/project/Alpha.swift")
        ])
        index.persistSnapshotForTesting()
        try await waitUntil {
            index.currentDiagnostics().activeIndexJobs == 0
        }

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        try Data().write(to: packageURL.appendingPathComponent(SnapshotLayout.FileName.namePostings))

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let diagnostics = reloaded.currentDiagnostics()
        #expect(diagnostics.indexedCount == 1)
        #expect(diagnostics.recordStoreKind == .mapped)
        #expect(FileManager.default.fileExists(atPath: packageURL.path))

        let response = reloaded.search(SearchRequest(
            query: "Alpha",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.map(\.record.name) == ["Alpha.swift"])
    }

    @Test("persisting unoptimized final snapshots writes core search sidecars")
    func persistingUnoptimizedFinalSnapshotsWritesCoreSearchSidecars() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let supportDirectory = supportDirectory(applicationName: applicationName)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRecordsForTesting([
            makeRecord(path: "/tmp/att-query-regression/project/Tests/FileIndexTests.swift"),
            makeRecord(path: "/tmp/att-query-regression/project/Sources/TestRunner.swift"),
            makeRecord(path: "/tmp/att-query-regression/project/README.md")
        ], buildsSearchStructures: false)
        index.persistSnapshotForTesting()

        let packageURL = SnapshotLayout.packageURL(in: supportDirectory)
        for fileName in [
            SnapshotLayout.FileName.modifiedOrder,
            SnapshotLayout.FileName.visibleModifiedOrder,
            SnapshotLayout.FileName.namePostings
        ] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: packageURL.appendingPathComponent(fileName).path
            )
            #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0)
        }
        let legacyComponentAttributes = try FileManager.default.attributesOfItem(
            atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings).path
        )
        #expect((legacyComponentAttributes[.size] as? NSNumber)?.intValue ?? 0 == 0)
        let componentMarkerAttributes = try FileManager.default.attributesOfItem(
            atPath: packageURL.appendingPathComponent(SnapshotLayout.FileName.componentSupplementPostings).path
        )
        #expect((componentMarkerAttributes[.size] as? NSNumber)?.intValue ?? -1 == 0)

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let response = reloaded.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .size, ascending: false)
        ), maxResults: 10)

        #expect(response.usesIndexedCandidates)
        #expect(response.totalMatches == 2)
        #expect(Set(response.results.map(\.record.name)) == ["FileIndexTests.swift", "TestRunner.swift"])
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

    @Test("fast scans do not package full-prefix checkpoints")
    func fastScansDoNotPackageFullPrefixCheckpoints() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        var schedule = ScanCheckpointSchedule(operationStartedAt: startedAt)
        var checkpointCount = 0
        var checkpointRowWork = 0

        for second in 0..<60 {
            let recordCount = (second + 1) * 20_000
            if schedule.shouldCreateCheckpoint(
                recordCount: recordCount,
                at: startedAt.addingTimeInterval(TimeInterval(second))
            ) {
                checkpointCount += 1
                checkpointRowWork += recordCount
            }
        }

        #expect(checkpointCount == 0)
        #expect(checkpointRowWork == 0)

        let firstCheckpointCount = 1_220_000
        let createsFirstCheckpoint = schedule.shouldCreateCheckpoint(
            recordCount: firstCheckpointCount,
            at: startedAt.addingTimeInterval(60)
        )
        #expect(createsFirstCheckpoint)
        checkpointCount += 1
        checkpointRowWork += firstCheckpointCount

        let createsPrematureCheckpoint = schedule.shouldCreateCheckpoint(
            recordCount: firstCheckpointCount + 200_000,
            at: startedAt.addingTimeInterval(61)
        )
        #expect(!createsPrematureCheckpoint)
        let createsSecondCheckpoint = schedule.shouldCreateCheckpoint(
            recordCount: firstCheckpointCount + 200_000,
            at: startedAt.addingTimeInterval(120)
        )
        #expect(createsSecondCheckpoint)
        checkpointCount += 1
        checkpointRowWork += firstCheckpointCount + 200_000

        #expect(checkpointCount == 2)
        #expect(checkpointRowWork == 2_640_000)
    }

    @Test("heap-paged partial snapshots reuse incremental counts and root attribution")
    func heapPagedPartialSnapshotsReuseIncrementalMetadata() throws {
        let root = "/tmp/allthethings-incremental-snapshot"
        let recordCount = HeapPagedRecordStore.pageSize + 1
        let builder = HeapPagedRecordStore.Builder(reservedCapacity: recordCount, roots: [root])

        for index in 0..<recordCount {
            builder.append(makeRecord(path: "\(root)/File-\(index).txt", sizeBytes: 1))
        }

        for _ in 0..<8 {
            let snapshot = builder.snapshot()
            #expect(snapshot.storedResultCount == recordCount)
            let summary = try #require(snapshot.storedRootAttribution?.roots.first)
            #expect(summary.trackedFileCount == recordCount)
            #expect(summary.indexedContentBytes == UInt64(recordCount))
        }

        #expect(builder.diagnostics.snapshotCount == 8)
        #expect(builder.diagnostics.rootAttributionEvaluationCount == recordCount)

        let originalSnapshot = builder.snapshot()
        builder.append(makeRecord(path: "\(root)/File-0.txt", sizeBytes: 42))
        let replacedSnapshot = builder.snapshot()
        let originalSummary = try #require(originalSnapshot.storedRootAttribution?.roots.first)
        let replacedSummary = try #require(replacedSnapshot.storedRootAttribution?.roots.first)
        #expect(originalSnapshot.sizeBytes(at: 0) == 1)
        #expect(originalSummary.indexedContentBytes == UInt64(recordCount))
        #expect(replacedSnapshot.count == recordCount)
        #expect(replacedSnapshot.storedResultCount == recordCount)
        #expect(replacedSummary.trackedFileCount == recordCount)
        #expect(replacedSummary.indexedContentBytes == UInt64(recordCount - 1 + 42))
        #expect(builder.diagnostics.snapshotCount == 10)
        #expect(builder.diagnostics.rootAttributionEvaluationCount == recordCount + 1)
    }

    @Test("heap-paged root attribution copies bounded pages while snapshots are retained")
    func heapPagedRootAttributionSnapshotCopiesStayBounded() throws {
        let root = "/tmp/allthethings-paged-root-attribution"
        let snapshotInterval = 512
        let recordCount = HeapPagedRecordStore.pageSize * 3 + 257
        let builder = HeapPagedRecordStore.Builder(reservedCapacity: recordCount, roots: [root])
        var retainedSnapshots: [HeapPagedRecordStore] = []

        for index in 0..<recordCount {
            builder.append(makeRecord(path: "\(root)/File-\(index).txt", sizeBytes: 1))
            if (index + 1).isMultiple(of: snapshotInterval) {
                retainedSnapshots.append(builder.snapshot())
            }
        }

        for (index, snapshot) in retainedSnapshots.enumerated() {
            let expectedCount = (index + 1) * snapshotInterval
            #expect(snapshot.count == expectedCount)
            #expect(snapshot.rootID(at: expectedCount - 1) == 0)
            let summary = try #require(snapshot.storedRootAttribution?.roots.first)
            #expect(summary.trackedFileCount == expectedCount)
        }

        let diagnostics = builder.diagnostics
        #expect(diagnostics.rootIDPageCopyCount > 0)
        #expect(diagnostics.rootIDPageCopyCount <= diagnostics.snapshotCount)
        #expect(diagnostics.maximumRootIDCopyElementCount <= HeapPagedRecordStore.pageSize)
        #expect(
            diagnostics.rootIDCopiedElementCount
                <= diagnostics.rootIDPageCopyCount * HeapPagedRecordStore.pageSize
        )

        let finalSnapshot = builder.snapshot()
        #expect(finalSnapshot.count == recordCount)
        #expect(finalSnapshot.rootID(at: recordCount - 1) == 0)
        let finalSummary = try #require(finalSnapshot.storedRootAttribution?.roots.first)
        #expect(finalSummary.trackedFileCount == recordCount)
        #expect(builder.diagnostics.rootAttributionEvaluationCount == recordCount)
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
        resumed.setDeferredOptimizationRecordThresholdForTesting(1)
        resumed.replaceRootsAndRebuild([root], mode: .resumeIfAvailable)

        try await waitUntil(timeout: .seconds(10)) {
            let stats = resumed.currentStats()
            let diagnostics = resumed.currentDiagnostics()
            return !stats.isIndexing
                && stats.indexedCount >= 3
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let response = resumed.search(SearchRequest(
            query: "Pending",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == pendingFile.path })
        #expect(!resumed.checkpointExistsForTesting())
    }

    @Test("resumed checkpoints optimize when external reconciliation is already up to date")
    func resumedCheckpointsOptimizeWhenExternalReconciliationIsAlreadyUpToDate() async throws {
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

        let reconciliationRequested = CompletionFlag()
        let resumed = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        resumed.setDeferredOptimizationRecordThresholdForTesting(1)
        resumed.onBackgroundReconciliationRequested = { _ in
            // An external FSEvents reconciler that reports `upToDate` has no
            // changed paths to send back to FileIndex.
            reconciliationRequested.mark()
        }
        resumed.replaceRootsAndRebuild([root], mode: .resumeIfAvailable)

        try await waitUntil(timeout: .seconds(10)) {
            let stats = resumed.currentStats()
            let diagnostics = resumed.currentDiagnostics()
            return reconciliationRequested.isMarked
                && !stats.isIndexing
                && stats.indexedCount >= 3
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
                && !resumed.checkpointExistsForTesting()
        }

        let response = resumed.search(SearchRequest(
            query: "Pending",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == pendingFile.path })
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
        #expect(index.currentDiagnostics().scanFrontierMetrics.retainedRecordDictionaryCount == 0)
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

        let scanWork = index.currentDiagnostics().scanFrontierMetrics
        #expect(scanWork.searchableSnapshotCount == 0)
        #expect(scanWork.searchableSnapshotRowCount == 0)
        #expect(scanWork.checkpointSnapshotCount == 0)
        #expect(scanWork.finalSnapshotCount == 0)
        #expect(scanWork.finalSnapshotRowCount == 0)
        #expect(scanWork.retainedRecordDictionaryCount == 0)
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

    @Test("unchanged reconciliation performs no package or snapshot rebuild")
    func unchangedReconciliationIsDiffFirstNoop() async throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "stable".write(
            to: root.appendingPathComponent("Stable.swift"),
            atomically: true,
            encoding: .utf8
        )
        let support = supportDirectory(applicationName: applicationName)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: support)
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        let before = index.currentDiagnostics()
        let manifestURL = SnapshotLayout.packageURL(in: support)
            .appendingPathComponent(SnapshotLayout.FileName.manifest)
        let manifestBefore = try Data(contentsOf: manifestURL)
        #expect(index.reconcileIndexedRootsInBackground() == .started)
        try await waitUntil(timeout: .seconds(10)) {
            !index.currentStats().isIndexing
                && index.currentStats().status.hasPrefix("Reconciled ")
        }

        let after = index.currentDiagnostics()
        #expect(after.snapshotRevision == before.snapshotRevision)
        #expect(after.completedSnapshotRebuilds == before.completedSnapshotRebuilds)
        #expect(after.recordStoreKind == .mapped)
        #expect(try Data(contentsOf: manifestURL) == manifestBefore)
        #expect(!fileManager.fileExists(atPath: support
            .appendingPathComponent(StructuralDeltaStore.fileName)
            .path))
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

    @Test("scoped reconciliation persists a delta without rebuilding the mapped package")
    func scopedReconciliationPersistsDeltaWithoutRebuildingMappedPackage() async throws {
        let fileManager = FileManager.default
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AllTheThingsTests-\(UUID().uuidString)", isDirectory: true)
        let changedFolder = root.appendingPathComponent("Project/Sources/Changed", isDirectory: true)
        let unchangedFolder = root.appendingPathComponent("Project/Docs/Unchanged", isDirectory: true)
        try fileManager.createDirectory(at: changedFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unchangedFolder, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: supportDirectory(applicationName: applicationName))
        }

        let deletedFile = changedFolder.appendingPathComponent("DeletedTarget.swift")
        let replacedFile = changedFolder.appendingPathComponent("ReplacedTarget.swift")
        let addedFile = changedFolder.appendingPathComponent("AddedTarget.swift")
        let retainedFile = unchangedFolder.appendingPathComponent("RetainedTarget.md")
        try "deleted".write(to: deletedFile, atomically: true, encoding: .utf8)
        try "old".write(to: replacedFile, atomically: true, encoding: .utf8)
        try "retained".write(to: retainedFile, atomically: true, encoding: .utf8)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_000_200)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: replacedFile.path)

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        index.replaceRootsAndRebuild([root], mode: .fresh)
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .mapped
                && diagnostics.optimizedCount == diagnostics.indexedCount
        }

        try fileManager.removeItem(at: deletedFile)
        try "new".write(to: replacedFile, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.modificationDate: newDate], ofItemAtPath: replacedFile.path)
        try "added".write(to: addedFile, atomically: true, encoding: .utf8)

        let memoryEvents = FileIndexMemoryEventRecorder()
        FileIndex.setMemoryTelemetrySinkForTesting { event in
            memoryEvents.append(event)
        }
        defer {
            FileIndex.setMemoryTelemetrySinkForTesting(nil)
        }

        index.reconcileIndexedRootsInBackground(rootURLs: [changedFolder])
        try await waitUntil(timeout: .seconds(10)) {
            let diagnostics = index.currentDiagnostics()
            let replaced = index.search(SearchRequest(
                query: "ReplacedTarget",
                sort: SortSpec(column: .relevance, ascending: false)
            ), maxResults: 10)
            guard let replacedRecord = replaced.results.first?.record else { return false }
            let paths = allIndexedPaths(in: index)
            return !index.currentStats().isIndexing
                && diagnostics.recordStoreKind == .overlay
                && diagnostics.optimizedCount == 0
                && diagnostics.virtualRowCount > 0
                && paths.contains(addedFile.path)
                && paths.contains(retainedFile.path)
                && !paths.contains(deletedFile.path)
                && abs(replacedRecord.modifiedTime - newDate.timeIntervalSinceReferenceDate) < 1
        }

        let response = index.search(SearchRequest(
            query: "Target",
            sort: SortSpec(column: .relevance, ascending: false)
        ), maxResults: 10)
        #expect(response.results.contains { $0.record.path == addedFile.path })
        #expect(response.results.contains { $0.record.path == replacedFile.path })
        #expect(response.results.contains { $0.record.path == retainedFile.path })
        #expect(!response.results.contains { $0.record.path == deletedFile.path })

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        let reloadedDiagnostics = reloaded.currentDiagnostics()
        #expect(reloadedDiagnostics.recordStoreKind == .overlay)
        #expect(reloadedDiagnostics.virtualRowCount > 0)
        #expect(allIndexedPaths(in: reloaded) == allIndexedPaths(in: index))

        let capturedMemoryEvents = memoryEvents.snapshot()
        #expect(capturedMemoryEvents.contains {
            $0.event == "reconcile.scan.finished"
                && $0.reconcilesAllRoots == false
                && $0.storeKind == nil
                && $0.heapPageCount == 0
        })
        #expect(!capturedMemoryEvents.contains { $0.event == "reconcile.heapStore.build.end" })
        #expect(index.currentDiagnostics().scanFrontierMetrics.retainedRecordDictionaryCount <= 4)
    }

    @Test("directory entry decoding reads only record name bytes")
    func directoryEntryDecodingReadsOnlyRecordNameBytes() throws {
        let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
        let mappingSize = pageSize * 2
        let mappingPointer = mmap(nil, mappingSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let mappingPointer, mappingPointer != MAP_FAILED else {
            Issue.record("mmap failed with errno \(errno)")
            return
        }
        defer {
            munmap(mappingPointer, mappingSize)
        }

        guard mprotect(mappingPointer.advanced(by: pageSize), pageSize, PROT_NONE) == 0 else {
            Issue.record("mprotect failed with errno \(errno)")
            return
        }

        let recordLengthOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_reclen))
        let nameLengthOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_namlen))
        let typeOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_type))
        let nameOffset = try #require(MemoryLayout<dirent>.offset(of: \.d_name))
        let nameBytes = Array("BoundaryName.swiftx".utf8)
        let entryStartOffset = pageSize - nameOffset - nameBytes.count
        let entryPointer = mappingPointer.advanced(by: entryStartOffset)
        entryPointer.storeBytes(
            of: UInt16(nameOffset + nameBytes.count),
            toByteOffset: recordLengthOffset,
            as: UInt16.self
        )
        entryPointer.storeBytes(
            of: UInt16(nameBytes.count),
            toByteOffset: nameLengthOffset,
            as: UInt16.self
        )
        entryPointer.storeBytes(of: UInt8(DT_DIR), toByteOffset: typeOffset, as: UInt8.self)
        UnsafeMutableRawBufferPointer(
            start: entryPointer.advanced(by: nameOffset),
            count: nameBytes.count
        ).copyBytes(from: nameBytes)

        let decoded = try #require(FileIndex.directoryEntryInfo(entryPointer.assumingMemoryBound(to: dirent.self)))
        #expect(decoded.name == "BoundaryName.swiftx")
        #expect(decoded.isDirectory)
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

    @Test("plain test query finds names when sorted by size")
    func plainTestQueryFindsNamesWhenSortedBySize() {
        let root = "/tmp/att-query-regression/project"
        let records = [
            makeRecord(path: "\(root)/Tests/FileIndexTests.swift"),
            makeRecord(path: "\(root)/Sources/TestRunner.swift"),
            makeRecord(path: "\(root)/README.md")
        ]
        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records)

        let response = index.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .size, ascending: false)
        ), maxResults: 10)

        #expect(response.usesIndexedCandidates)
        #expect(response.totalMatches == 2)
        #expect(Set(response.results.map(\.record.name)) == ["FileIndexTests.swift", "TestRunner.swift"])
    }

    @Test("exact path substring previews use sidecar sort order")
    func exactPathSubstringPreviewsUseSidecarSortOrder() {
        let recordCount = 3_000
        let rootA = "/tmp/att-path-preview-sort/a-root"
        let rootZ = "/tmp/att-path-preview-sort/z-root"
        let extensions = ["swift", "md", "cpp", "txt"]
        let records = (0..<recordCount).map { offset in
            let root = offset.isMultiple(of: 2) ? rootA : rootZ
            let path = String(
                format: "\(root)/NeedleSegment-%03d/File%06d.\(extensions[offset % extensions.count])",
                offset % 41,
                offset
            )
            return makeRecord(
                path: path,
                modifiedTime: TimeInterval(recordCount - offset),
                createdTime: TimeInterval(offset),
                sizeBytes: UInt64((offset * 29) % 60_000 + 1),
                volumeName: "Volume-\(offset % 5)"
            )
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records, roots: [
            URL(fileURLWithPath: rootA, isDirectory: true),
            URL(fileURLWithPath: rootZ, isDirectory: true)
        ])

        for sortColumn in [SortColumn.path, .created, .size, .fileExtension, .kind, .volume, .root] {
            let sort = SortSpec(column: sortColumn, ascending: true)
            let response = index.search(SearchRequest(
                query: "path:NeedleSegment",
                sort: sort,
                mode: .interactivePreview
            ), maxResults: 20)
            let expectedPaths = expectedSortedRecords(records, sort: sort, roots: [rootA, rootZ])
                .prefix(20)
                .map(\.path)
            let profileSummary = "sort: \(sortColumn.rawValue), path: \(response.executionProfile.executionPath.rawValue), candidates: \(response.executionProfile.candidateCount), scanned: \(response.executionProfile.scannedRowCount)"

            #expect(response.usesIndexedCandidates, "\(profileSummary)")
            #expect(response.executionProfile.indexesUsed.contains(.sortOrder), "\(profileSummary)")
            #expect(response.executionProfile.indexesUsed.contains(.pathGrams) || response.executionProfile.indexesUsed.contains(.componentGrams), "\(profileSummary)")
            #expect(!response.executionProfile.didFallbackToFullScan, "\(profileSummary)")
            #expect(response.executionProfile.scannedRowCount <= 40, "\(profileSummary)")
            if sortColumn != .root {
                #expect(response.results.map(\.record.path) == Array(expectedPaths), "\(profileSummary)")
            }
        }
    }

    @Test("exact extension previews use sidecar sort order")
    func exactExtensionPreviewsUseSidecarSortOrder() {
        let recordCount = 3_000
        let rootA = "/tmp/att-extension-preview-sort/a-root"
        let rootZ = "/tmp/att-extension-preview-sort/z-root"
        let records = (0..<recordCount).map { offset in
            let root = offset.isMultiple(of: 2) ? rootA : rootZ
            return makeRecord(
                path: String(format: "\(root)/project-%03d/File%06d.cpp", offset % 43, offset),
                modifiedTime: TimeInterval(recordCount - offset),
                createdTime: TimeInterval(offset),
                sizeBytes: UInt64((offset * 31) % 70_000 + 1),
                volumeName: "Volume-\(offset % 6)"
            )
        }
        let index = FileIndex(applicationName: "AllTheThingsTests-\(UUID().uuidString)", loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records, roots: [
            URL(fileURLWithPath: rootA, isDirectory: true),
            URL(fileURLWithPath: rootZ, isDirectory: true)
        ])

        for sortColumn in [SortColumn.path, .created, .size, .fileExtension, .kind, .volume, .root] {
            let sort = SortSpec(column: sortColumn, ascending: true)
            let response = index.search(SearchRequest(
                query: "ext:cpp",
                sort: sort,
                mode: .interactivePreview
            ), maxResults: 20)
            let expectedPaths = expectedSortedRecords(records, sort: sort, roots: [rootA, rootZ])
                .prefix(20)
                .map(\.path)
            let profileSummary = "sort: \(sortColumn.rawValue), path: \(response.executionProfile.executionPath.rawValue), candidates: \(response.executionProfile.candidateCount), scanned: \(response.executionProfile.scannedRowCount)"

            #expect(response.usesIndexedCandidates, "\(profileSummary)")
            #expect(response.executionProfile.executionPath == .extensionCandidateIntersection, "\(profileSummary)")
            #expect(response.executionProfile.indexesUsed.contains(.extensionPostings), "\(profileSummary)")
            #expect(response.executionProfile.indexesUsed.contains(.sortOrder), "\(profileSummary)")
            #expect(!response.executionProfile.didFallbackToFullScan, "\(profileSummary)")
            #expect(response.executionProfile.scannedRowCount <= 40, "\(profileSummary)")
            if sortColumn != .root {
                #expect(response.results.map(\.record.path) == Array(expectedPaths), "\(profileSummary)")
            }
        }
    }

    @Test("exact extension searches use extension postings and sorted sidecars")
    func exactExtensionSearchesUseExtensionPostingsAndSortedSidecars() {
        let root = "/tmp/allthethings-extension-fast-path"
        let cppCount = 750
        var records: [FileRecord] = []
        records.reserveCapacity(cppCount + 253)

        for offset in 0..<cppCount {
            records.append(makeRecord(path: "\(root)/cpp/File\(String(format: "%05d", offset)).cpp"))
        }
        for offset in 0..<250 {
            records.append(makeRecord(path: "\(root)/swift/File\(String(format: "%05d", offset)).swift"))
        }
        records.append(makeRecord(path: "\(root)/modules/Module.cppm"))
        records.append(makeRecord(path: "\(root)/headers/Bridge.hpp"))
        records.append(makeRecord(path: "\(root)/headers/Bridge.ipp"))

        let index = FileIndex(
            applicationName: "AllTheThingsTests-\(UUID().uuidString)",
            loadsSnapshotImmediately: false
        )
        index.replaceRecordsForTesting(records)

        for query in [".cpp", "*.cpp", "ext:cpp"] {
            let response = index.search(SearchRequest(
                query: query,
                sort: SortSpec(column: .name, ascending: true)
            ), maxResults: 25)

            #expect(response.usesIndexedCandidates)
            #expect(response.executionProfile.executionPath == .extensionCandidateIntersection)
            #expect(response.executionProfile.indexesUsed.contains(.extensionPostings))
            #expect(response.executionProfile.indexesUsed.contains(.sortOrder))
            #expect(response.executionProfile.candidateCount == cppCount)
            #expect(response.executionProfile.scannedRowCount <= response.executionProfile.candidateCount)
            #expect(response.totalMatches == cppCount)
            #expect(response.results.count == 25)
            #expect(response.results.allSatisfy { $0.record.fileExtension == "cpp" })
        }

        for query in ["ext:cpp,cppm", "*.cpp|*.cppm"] {
            let response = index.search(SearchRequest(
                query: query,
                sort: SortSpec(column: .name, ascending: true)
            ), maxResults: 25)

            #expect(response.usesIndexedCandidates)
            #expect(response.executionProfile.executionPath == .extensionCandidateIntersection)
            #expect(response.executionProfile.indexesUsed.contains(.extensionPostings))
            #expect(response.executionProfile.indexesUsed.contains(.sortOrder))
            #expect(response.executionProfile.candidateCount == cppCount + 1)
            #expect(response.executionProfile.scannedRowCount <= response.executionProfile.candidateCount)
            #expect(response.totalMatches == cppCount + 1)
            #expect(response.results.count == 25)
            #expect(response.results.allSatisfy { ["cpp", "cppm"].contains($0.record.fileExtension) })
        }

        for query in ["*.[hic]pp", "ext:[hic]pp"] {
            let response = index.search(SearchRequest(
                query: query,
                sort: SortSpec(column: .name, ascending: true)
            ), maxResults: 25)

            #expect(response.usesIndexedCandidates)
            #expect(response.executionProfile.executionPath == .extensionCandidateIntersection)
            #expect(response.executionProfile.indexesUsed.contains(.extensionPostings))
            #expect(response.executionProfile.indexesUsed.contains(.sortOrder))
            #expect(response.executionProfile.candidateCount == cppCount + 2)
            #expect(response.executionProfile.scannedRowCount <= response.executionProfile.candidateCount)
            #expect(response.totalMatches == cppCount + 2)
            #expect(response.results.count == 25)
            #expect(response.results.allSatisfy { ["cpp", "hpp", "ipp"].contains($0.record.fileExtension) })
        }
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

    @Test("interactive preview returns modified sorted text matches without full count")
    func interactivePreviewReturnsModifiedSortedTextMatchesWithoutFullCount() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = "/tmp/allthethings-modified-preview-\(UUID().uuidString)"
        let recordCount = 10_000
        let records = (0..<recordCount).map { index in
            makeRecord(
                path: "\(root)/TestFile\(String(format: "%06d", index)).txt",
                modifiedTime: TimeInterval(index)
            )
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        #expect(index.currentDiagnostics().pathGramIndexEnabled)

        let optimizedPreviewResponse = index.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 10)
        let optimizedCompleteResponse = index.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false
        ), maxResults: 10)

        let expectedNames = (0..<10).map { offset in
            String(format: "TestFile%06d.txt", recordCount - offset - 1)
        }
        #expect(optimizedPreviewResponse.results.map(\.record.name) == expectedNames)
        #expect(optimizedPreviewResponse.totalMatches == 10)
        #expect(optimizedPreviewResponse.executionProfile.scannedRowCount <= 10)
        #expect(optimizedCompleteResponse.results.map(\.record.name) == expectedNames)
        #expect(optimizedCompleteResponse.totalMatches == recordCount)
        #expect(optimizedCompleteResponse.executionProfile.scannedRowCount <= 10)

        index.persistSnapshotForTesting()
        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(!reloaded.currentDiagnostics().pathGramIndexEnabled)

        let previewResponse = reloaded.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 10)
        let completeResponse = reloaded.search(SearchRequest(
            query: "test",
            sort: SortSpec(column: .modified, ascending: false),
            includeHidden: false
        ), maxResults: 10)

        #expect(previewResponse.results.map(\.record.name) == expectedNames)
        #expect(previewResponse.totalMatches == 10)
        #expect(previewResponse.executionProfile.scannedRowCount <= 10)
        #expect(completeResponse.results.map(\.record.name) == expectedNames)
        #expect(completeResponse.totalMatches == recordCount)
        #expect(completeResponse.executionProfile.scannedRowCount <= 10)
    }

    @Test("broad relevance path substring uses exact component fast path")
    func broadRelevancePathSubstringUsesExactComponentFastPath() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = "/tmp/allthethings-broad-fast-path-\(UUID().uuidString)"
        let documents = "\(root)/Documents"
        let recordCount = 5_000
        var records = [
            makeRecord(path: root, isDirectory: true),
            makeRecord(path: documents, isDirectory: true)
        ]
        records.reserveCapacity(recordCount + records.count)
        for index in 0..<recordCount {
            records.append(makeRecord(
                path: "\(documents)/File\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(index)
            ))
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(!reloaded.currentDiagnostics().pathGramIndexEnabled)

        let previewResponse = reloaded.search(SearchRequest(
            query: "documents",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false,
            mode: .interactivePreview
        ), maxResults: 25)
        let response = reloaded.search(SearchRequest(
            query: "documents",
            sort: SortSpec(column: .relevance, ascending: false),
            includeHidden: false
        ), maxResults: 25)

        #expect(previewResponse.usesIndexedCandidates)
        #expect(previewResponse.executionProfile.executionPath != .fullFallbackScan)
        #expect(!previewResponse.executionProfile.didFallbackToFullScan)
        #expect(previewResponse.executionProfile.indexesUsed.contains(.componentGrams))
        #expect(previewResponse.totalMatches == 25)
        #expect(previewResponse.results.count == 25)
        #expect(previewResponse.results.contains { $0.match?.field == .ancestorPath })

        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath != .fullFallbackScan)
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.indexesUsed.contains(.componentGrams))
        #expect(response.totalMatches == recordCount + 1)
        #expect(response.results.count == 25)
    }

    @Test("broad name path substring returns exact total without scoring every descendant")
    func broadNamePathSubstringReturnsExactTotalWithoutScoringEveryDescendant() throws {
        let applicationName = "AllTheThingsTests-\(UUID().uuidString)"
        let root = "/tmp/allthethings-broad-name-fast-path-\(UUID().uuidString)"
        let documents = "\(root)/Documents"
        let recordCount = 5_000
        var records = [
            makeRecord(path: root, isDirectory: true),
            makeRecord(path: documents, isDirectory: true)
        ]
        records.reserveCapacity(recordCount + records.count)
        for index in 0..<recordCount {
            records.append(makeRecord(
                path: "\(documents)/File\(String(format: "%06d", index)).swift",
                modifiedTime: TimeInterval(index)
            ))
        }

        let index = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: false)
        defer {
            try? FileManager.default.removeItem(at: index.dataDirectoryURL)
        }
        index.replaceRecordsForTesting(records)
        index.persistSnapshotForTesting()

        let reloaded = FileIndex(applicationName: applicationName, loadsSnapshotImmediately: true)
        #expect(!reloaded.currentDiagnostics().pathGramIndexEnabled)

        let response = reloaded.search(SearchRequest(
            query: "documents",
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: false
        ), maxResults: 25)

        #expect(response.usesIndexedCandidates)
        #expect(response.executionProfile.executionPath == .optimizedSortedFastPath)
        #expect(!response.executionProfile.didFallbackToFullScan)
        #expect(response.executionProfile.indexesUsed.contains(.componentGrams))
        #expect(response.totalMatches == recordCount + 1)
        #expect(response.results.count == 25)
        #expect(response.results.first?.record.name == "Documents")
        #expect(response.executionProfile.scannedRowCount <= 75)
    }

    @Test("sparse overlay initialization does not walk the base store")
    func sparseOverlayUsesRankSelectRowMapping() {
        let records = (0..<5).map { makeRecord(path: "/tmp/allthethings-store/Item\($0).txt") }
        let added = makeRecord(path: "/tmp/allthethings-store/Added.txt")
        let base = CountingRecordStore(records: records)
        let overlay = OverlayRecordStore(base: base, upserts: [added], deletedRows: [1, 3])

        #expect(base.recordCallCount == 0)
        #expect(base.allRecordsCallCount == 0)
        #expect(overlay.count == 4)
        #expect((0..<overlay.count).map { overlay.path(at: $0) } == [
            records[0].path,
            records[2].path,
            records[4].path,
            added.path
        ])
        #expect(overlay.rowID(forPath: records[0].path) == 0)
        #expect(overlay.rowID(forPath: records[1].path) == nil)
        #expect(overlay.rowID(forPath: records[2].path) == 1)
        #expect(overlay.rowID(forPath: records[4].path) == 2)
        #expect(overlay.rowID(forPath: added.path) == 3)
    }

    @Test("repeated sparse updates flatten onto one base store")
    func repeatedSparseUpdatesFlattenOntoOneBaseStore() {
        let path = "/tmp/allthethings-store/Repeated.txt"
        let base = CountingRecordStore(records: [makeRecord(path: path)])
        var store: RecordStore = base

        for version in 1...100 {
            let existingRow = store.rowID(forPath: path)
            store = OverlayRecordStore(
                base: store,
                upserts: [makeRecord(path: path, sizeBytes: UInt64(version))],
                deletedRows: Set(existingRow.map { [$0] } ?? [])
            )
        }

        guard let overlay = store as? OverlayRecordStore else {
            Issue.record("Expected a flattened overlay store")
            return
        }
        #expect(overlay.overlayCount == 2)
        #expect(overlay.record(at: 0).sizeBytes == 100)
        #expect(overlay.allRecords().map(\.path) == [path])
        #expect(base.allRecordsCallCount == 1)
    }

    @Test("deleting a metadata replacement does not preserve its upsert")
    func deletingMetadataReplacementRemovesPath() {
        let path = "/tmp/allthethings-store/Replaced.txt"
        let base = CountingRecordStore(records: [makeRecord(path: path)])
        let replacing = ReplacingRecordStore(
            base: base,
            replacements: [0: makeRecord(path: path, sizeBytes: 42)]
        )
        let overlay = OverlayRecordStore(base: replacing, upserts: [], deletedRows: [0])

        #expect(overlay.count == 0)
        #expect(overlay.rowID(forPath: path) == nil)
        #expect(overlay.allRecords().isEmpty)
    }

    @Test("overlay allRecords uses base bulk materialization")
    func overlayAllRecordsUsesBaseBulkMaterialization() throws {
        let alpha = makeRecord(path: "/tmp/allthethings-store/Alpha.txt")
        let beta = makeRecord(path: "/tmp/allthethings-store/Beta.txt")
        let gamma = makeRecord(path: "/tmp/allthethings-store/Gamma.txt")
        let base = CountingRecordStore(records: [alpha, beta])
        let overlay = OverlayRecordStore(base: base, upserts: [gamma], deletedRows: [1])

        let records = overlay.allRecords()

        #expect(records.map(\.path) == [alpha.path, gamma.path])
        #expect(base.allRecordsCallCount == 1)
        #expect(base.recordCallCount == 1)
    }

    @Test("replacing allRecords uses base bulk materialization")
    func replacingAllRecordsUsesBaseBulkMaterialization() throws {
        let alpha = makeRecord(path: "/tmp/allthethings-store/Alpha.txt")
        let beta = makeRecord(path: "/tmp/allthethings-store/Beta.txt")
        let replacement = makeRecord(path: "/tmp/allthethings-store/Alpha Renamed.txt")
        let base = CountingRecordStore(records: [alpha, beta])
        let replacing = ReplacingRecordStore(base: base, replacements: [0: replacement])

        let records = replacing.allRecords()

        #expect(records.map(\.path) == [replacement.path, beta.path])
        #expect(base.allRecordsCallCount == 1)
        #expect(base.recordCallCount == 0)
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

    private func searchPaths(in index: FileIndex, query: String, includeHidden: Bool = false) -> [String] {
        index.search(SearchRequest(
            query: query,
            sort: SortSpec(column: .name, ascending: true),
            includeHidden: includeHidden
        ), maxResults: 50).results.map(\.record.path)
    }

    private func allIndexedPaths(in index: FileIndex) -> [String] {
        index.search(SearchRequest(
            query: "",
            sort: SortSpec(column: .path, ascending: true),
            includeHidden: true
        ), maxResults: 20_000).results.map(\.record.path)
    }

    private func indexedPaths(
        roots: [URL],
        mode: ExclusionEvaluationMode,
        applicationName: String,
        exclusionPatterns: [String] = FileExclusionRules.defaultPatterns,
        frontierMode: ScanFrontierMode = .singleDirectory,
        frontierBatchSize: Int = 1
    ) async throws -> [String] {
        let index = FileIndex(
            applicationName: applicationName,
            loadsSnapshotImmediately: false,
            exclusionPatterns: exclusionPatterns
        )
        index.setExclusionEvaluationModeForTesting(mode)
        index.setScanFrontierBatchingForTesting(mode: frontierMode, batchSize: frontierBatchSize)
        defer {
            try? FileManager.default.removeItem(at: supportDirectory(applicationName: applicationName))
        }

        index.replaceRootsAndRebuild(roots, mode: .fresh)
        try await waitUntil {
            !index.currentStats().isIndexing
        }
        return allIndexedPaths(in: index)
    }

    private func supportDirectory(applicationName: String) -> URL {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return supportRoot.appendingPathComponent(applicationName, isDirectory: true)
    }

    private func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func expectedSortedRecords(
        _ records: [FileRecord],
        sort: SortSpec,
        roots: [String] = []
    ) -> [FileRecord] {
        func ordered<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool? {
            guard lhs != rhs else { return nil }
            return sort.ascending ? lhs < rhs : lhs > rhs
        }

        func rootPath(for record: FileRecord) -> String {
            roots
                .filter { record.path == $0 || record.path.hasPrefix($0 + "/") }
                .max { $0.count < $1.count } ?? ""
        }

        func kindName(for record: FileRecord) -> String {
            record.isDirectory && record.fileExtension == "app"
                ? "Application"
                : (record.isDirectory ? "Folder" : "File")
        }

        return records.sorted { lhs, rhs in
            let primary: Bool?
            switch sort.column {
            case .relevance:
                primary = ordered(lhs.modifiedTime, rhs.modifiedTime)
            case .name:
                primary = ordered(lhs.normalizedName, rhs.normalizedName)
            case .path:
                primary = ordered(lhs.normalizedPath, rhs.normalizedPath)
            case .modified:
                primary = ordered(lhs.modifiedTime, rhs.modifiedTime)
            case .created:
                primary = ordered(lhs.createdTime ?? 0, rhs.createdTime ?? 0)
            case .size:
                primary = ordered(lhs.sizeBytes, rhs.sizeBytes)
            case .fileExtension:
                primary = ordered(lhs.fileExtension, rhs.fileExtension)
            case .kind:
                primary = ordered(kindName(for: lhs), kindName(for: rhs))
            case .volume:
                primary = ordered(lhs.volumeName, rhs.volumeName)
            case .root:
                primary = ordered(rootPath(for: lhs), rootPath(for: rhs))
            }

            if let primary {
                return primary
            }
            if lhs.normalizedName != rhs.normalizedName {
                return lhs.normalizedName < rhs.normalizedName
            }
            return lhs.path < rhs.path
        }
    }

    private func makeRecord(
        path: String,
        isDirectory: Bool = false,
        isHidden: Bool? = nil,
        modifiedTime: TimeInterval = Date().timeIntervalSinceReferenceDate,
        createdTime: TimeInterval? = nil,
        sizeBytes: UInt64 = 128,
        volumeName: String = "Test"
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
            sizeBytes: isDirectory ? 0 : sizeBytes,
            modifiedTime: modifiedTime,
            createdTime: createdTime,
            isDirectory: isDirectory,
            isHidden: isHidden ?? FileRecord.pathIsHidden(path),
            volumeName: volumeName,
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }
}

private final class CountingRecordStore: RecordStore, @unchecked Sendable {
    let kind = RecordStoreKind.heapPaged
    private let records: [FileRecord]
    private(set) var recordCallCount = 0
    private(set) var allRecordsCallCount = 0

    var count: Int { records.count }

    init(records: [FileRecord]) {
        self.records = records
    }

    func record(at index: Int) -> FileRecord {
        recordCallCount += 1
        return records[index]
    }

    func recordID(at index: Int) -> UInt64 {
        records[index].id
    }

    func rowID(forPath path: String) -> Int? {
        records.firstIndex { $0.path == path }
    }

    func allRecords() -> [FileRecord] {
        allRecordsCallCount += 1
        return records
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

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var isMarked: Bool {
        lock.withLock { marked }
    }

    func mark() {
        lock.withLock {
            marked = true
        }
    }
}

private final class CompletionOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    func snapshot() -> [String] {
        lock.withLock { values }
    }
}

private final class FileIndexMemoryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FileIndexMemoryTelemetryEvent] = []

    func append(_ event: FileIndexMemoryTelemetryEvent) {
        lock.withLock {
            events.append(event)
        }
    }

    func snapshot() -> [FileIndexMemoryTelemetryEvent] {
        lock.withLock {
            events
        }
    }
}
