@testable import ATTCore
import Darwin
import Foundation
import Testing

@Suite("Scanner performance experiments", .serialized)
struct ScannerPerformanceExperimentTests {
    @Test("current-like and fts stat scanners index the same fixture record count")
    func currentLikeAndFTSStatScannersIndexSameFixtureRecordCount() throws {
        let fixture = try ScannerBenchmarkFixture()
        defer { fixture.remove() }

        try fixture.writeFile("Alpha.txt")
        try fixture.writeFile("Source/Beta.swift")
        try fixture.writeFile("Source/Nested/Gamma.md")
        try fixture.writeFile("node_modules/pkg/Skipped.js")

        let current = ScannerBenchmarkRunner.run(
            root: fixture.root,
            variant: .currentLike,
            rules: FileExclusionRules()
        )
        let fts = ScannerBenchmarkRunner.run(
            root: fixture.root,
            variant: .ftsStatRecord,
            rules: FileExclusionRules()
        )
        let compiledQuery = ScannerBenchmarkRunner.run(
            root: fixture.root,
            variant: .ftsStatCompiledExclusionQuery,
            rules: FileExclusionRules()
        )
        let bulk = ScannerBenchmarkRunner.run(
            root: fixture.root,
            variant: .getattrlistbulkRecord,
            rules: FileExclusionRules()
        )

        #expect(current.recordCount == fts.recordCount)
        #expect(current.recordCount == compiledQuery.recordCount)
        #expect(current.recordCount == bulk.recordCount)
        #expect(current.recordCount > 0)
        #expect(current.prunedDirectoryCount == fts.prunedDirectoryCount)
        #expect(current.prunedDirectoryCount == compiledQuery.prunedDirectoryCount)
        #expect(current.prunedDirectoryCount == bulk.prunedDirectoryCount)
    }

    @Test("getattrlistbulk scanner matches compiled fts fixture paths")
    func getattrlistbulkScannerMatchesCompiledFTSFixturePaths() throws {
        let fixture = try ScannerBenchmarkFixture()
        defer { fixture.remove() }

        try fixture.writeFile("Alpha.txt")
        try fixture.writeFile("Source/Beta.swift")
        try fixture.writeFile("Source/Nested/Gamma.md")
        try fixture.writeFile("Source/Nested/Spaced Name.txt")
        try fixture.writeFile("Source/Nested/cafe\u{301}.txt")
        try fixture.writeFile(".hidden")
        try fixture.writeFile("node_modules/pkg/Skipped.js")
        let emptyDirectory = fixture.root.appendingPathComponent("Source/Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("Source/LinkToAlpha", isDirectory: false)
        let result = symlink(fixture.root.appendingPathComponent("Alpha.txt").path, link.path)
        #expect(result == 0)

        let fts = ScannerBenchmarkRunner.run(
            root: fixture.root,
            variant: .ftsStatCompiledExclusionQuery,
            rules: FileExclusionRules(),
            collectsIndexedPaths: true
        )
        let bulk = ScannerBenchmarkRunner.run(
            root: fixture.root,
            variant: .getattrlistbulkRecord,
            rules: FileExclusionRules(),
            collectsIndexedPaths: true
        )

        #expect(bulk.indexedPaths == fts.indexedPaths)
        #expect(!bulk.indexedPaths.contains(fixture.root.appendingPathComponent("node_modules").path))
        #expect(bulk.indexedPaths.contains(fixture.root.appendingPathComponent("Source/Nested/cafe\u{301}.txt").path))
    }

    @Test("getattrlistbulk parser handles valid and optional synthetic entries")
    func getattrlistbulkParserHandlesValidAndOptionalSyntheticEntries() throws {
        let validEntry = BulkAttributeTestEntryBuilder.entry(name: "alpha.txt")
        let parsed = try BulkAttributeBufferParser.parseSingleEntry(validEntry)
        #expect(parsed.name == "alpha.txt")
        #expect(parsed.isDirectory == false)
        #expect(parsed.isSymlink == false)
        #expect(parsed.modifiedTime != nil)
        #expect(parsed.createdTime != nil)
        #expect(parsed.flags != nil)
        #expect(parsed.sizeBytes == 123)
        #expect(parsed.requiresStatFallback == false)

        let noOptionalEntry = BulkAttributeTestEntryBuilder.entry(
            name: "directory",
            objectType: Int32(VDIR.rawValue),
            includesCreationTime: false,
            includesFlags: false,
            includesFileLength: false
        )
        let noOptional = try BulkAttributeBufferParser.parseSingleEntry(noOptionalEntry)
        #expect(noOptional.isDirectory)
        #expect(noOptional.createdTime == nil)
        #expect(noOptional.flags == nil)
        #expect(noOptional.requiresStatFallback == false)

        let unsupportedType = try BulkAttributeBufferParser.parseSingleEntry(
            BulkAttributeTestEntryBuilder.entry(name: "socket", objectType: Int32(VSOCK.rawValue))
        )
        #expect(unsupportedType.isDirectory == false)
        #expect(unsupportedType.isSymlink == false)

        let missingModifiedTime = try BulkAttributeBufferParser.parseSingleEntry(
            BulkAttributeTestEntryBuilder.entry(name: "fallback.txt", includesModifiedTime: false)
        )
        #expect(missingModifiedTime.requiresStatFallback)
    }

    @Test("getattrlistbulk parser rejects malformed synthetic entries")
    func getattrlistbulkParserRejectsMalformedSyntheticEntries() throws {
        expectBulkParserFailure([])
        expectBulkParserFailure([1, 0, 0, 0])

        var badNameReference = BulkAttributeTestEntryBuilder.entry(name: "alpha.txt")
        badNameReference[24] = 0xff
        badNameReference[25] = 0x7f
        expectBulkParserFailure(badNameReference)

        expectBulkParserFailure(BulkAttributeTestEntryBuilder.entry(nameBytes: [0xff, 0x00]))

        let missingObjectType = BulkAttributeTestEntryBuilder.entry(
            name: "missing-type",
            includesObjectType: false
        )
        expectBulkParserFailure(missingObjectType)
    }

    @Test("scanner variants do not follow symlink loops")
    func scannerVariantsDoNotFollowSymlinkLoops() throws {
        let fixture = try ScannerBenchmarkFixture()
        defer { fixture.remove() }

        try fixture.writeFile("Target/Leaf.txt")
        let target = fixture.root.appendingPathComponent("Target", isDirectory: true)
        let loop = target.appendingPathComponent("Loop", isDirectory: true)
        let result = symlink(fixture.root.path, loop.path)
        #expect(result == 0)

        for variant in ScannerBenchmarkVariant.allCases {
            let metrics = ScannerBenchmarkRunner.run(
                root: fixture.root,
                variant: variant,
                rules: FileExclusionRules(),
                maxEntries: 200
            )
            #expect(metrics.visitedCount < 200)
        }
    }

    @Test("default exclusion prefilter only prunes paths that full rules prune")
    func defaultExclusionPrefilterOnlyPrunesFullRulePrunes() {
        let root = "/tmp/allthethings-prefilter-root"
        let rules = FileExclusionRules()
        let prefilter = FastDefaultExclusionPrefilter(rootPath: root)
        let cases: [(relativePath: String, isDirectory: Bool)] = [
            ("node_modules", true),
            ("node_modules/react/index.js", false),
            ("DerivedData", true),
            ("Source/.cache", true),
            ("Source/.cache/build.db", false),
            (".venv", true),
            (".venv/bin/python", false),
            (".Trash", true),
            ("Library/Caches", true),
            (".git", true),
            (".git/config", false),
            ("Source/App.swift", false)
        ]

        for testCase in cases {
            let path = root + "/" + testCase.relativePath
            let prefilterDecision = prefilter.decision(path: path, isDirectory: testCase.isDirectory)
            if prefilterDecision == .prune {
                let fullDecision = rules.decision(
                    url: URL(fileURLWithPath: path, isDirectory: testCase.isDirectory),
                    roots: [root],
                    isDirectory: testCase.isDirectory
                )
                #expect(fullDecision == .prune)
            }
        }

        #expect(prefilter.decision(path: root + "/.git", isDirectory: true) == nil)
        #expect(prefilter.decision(path: root + "/Library/Caches", isDirectory: true) == nil)
    }

    @Test("compiled exclusion query matches full rules on sampled real-root paths")
    func compiledExclusionQueryMatchesFullRulesOnSampledRealRootPaths() throws {
        guard let rawRoots = ProcessInfo.processInfo.environment["ATT_SCANNER_BENCH_ROOTS"] else {
            return
        }

        let roots = Self.benchmarkRoots(from: rawRoots)
        guard !roots.isEmpty else {
            Issue.record("ATT_SCANNER_BENCH_ROOTS did not contain any absolute paths")
            return
        }

        let maxEntries = Self.positiveEnvironmentInteger("ATT_SCANNER_BENCH_MAX_ENTRIES") ?? 500
        let rules = FileExclusionRules()

        for root in roots {
            let rootPath = root.path
            let query = rules.makeQuery(roots: [rootPath])
            for sample in ScannerBenchmarkRunner.sampleFTSEntries(root: root, maxEntries: maxEntries) {
                var instrumentation = FileExclusionQuery.Instrumentation()
                let queryDecision = query.decision(
                    path: sample.path,
                    isDirectory: sample.isDirectory,
                    instrumentation: &instrumentation
                )
                let fullDecision = rules.decision(
                    url: URL(fileURLWithPath: sample.path, isDirectory: sample.isDirectory),
                    roots: [rootPath],
                    isDirectory: sample.isDirectory
                )
                #expect(queryDecision == fullDecision)
            }
        }
    }

    @Test("opt-in real-root scanner technique benchmark")
    func optInRealRootScannerTechniqueBenchmark() throws {
        guard let rawRoots = ProcessInfo.processInfo.environment["ATT_SCANNER_BENCH_ROOTS"] else {
            return
        }

        let roots = Self.benchmarkRoots(from: rawRoots)
        guard !roots.isEmpty else {
            Issue.record("ATT_SCANNER_BENCH_ROOTS did not contain any absolute paths")
            return
        }

        let repeatCount = Self.positiveEnvironmentInteger("ATT_SCANNER_BENCH_REPEAT") ?? 1
        let maxEntries = Self.positiveEnvironmentInteger("ATT_SCANNER_BENCH_MAX_ENTRIES")
        let rules = FileExclusionRules()
        let encoder = JSONEncoder()

        for repeatIndex in 0..<repeatCount {
            for root in roots {
                for variant in ScannerBenchmarkVariant.allCases {
                    let started = Date()
                    let metrics = ScannerBenchmarkRunner.run(
                        root: root,
                        variant: variant,
                        rules: rules,
                        maxEntries: maxEntries
                    )
                    let elapsed = max(Date().timeIntervalSince(started), .leastNonzeroMagnitude)
                    let result = ScannerBenchmarkResult(
                        variant: variant.rawValue,
                        root: root.path,
                        repeat_index: repeatIndex,
                        elapsed_ms: Int((elapsed * 1_000).rounded()),
                        visited_count: metrics.visitedCount,
                        record_count: metrics.recordCount,
                        directory_count: metrics.directoryCount,
                        file_count: metrics.fileCount,
                        pruned_directory_count: metrics.prunedDirectoryCount,
                        error_count: metrics.errorCount,
                        metadata_fetch_count: metrics.metadataFetchCount,
                        full_exclusion_decision_count: metrics.fullExclusionDecisionCount,
                        compiled_exclusion_decision_count: metrics.compiledExclusionInstrumentation.compiledExclusionDecisionCount,
                        component_split_count: metrics.compiledExclusionInstrumentation.componentSplitCount,
                        ancestor_match_check_count: metrics.compiledExclusionInstrumentation.ancestorMatchCheckCount,
                        regex_match_count: metrics.compiledExclusionInstrumentation.regexMatchCount,
                        fast_path_decision_count: metrics.compiledExclusionInstrumentation.fastPathDecisionCount,
                        bulk_directory_call_count: metrics.bulkDirectoryCallCount,
                        bulk_entry_count: metrics.bulkEntryCount,
                        bulk_directory_fallback_count: metrics.bulkDirectoryFallbackCount,
                        bulk_entry_fallback_count: metrics.bulkEntryFallbackCount,
                        bulk_buffer_retry_count: metrics.bulkBufferRetryCount,
                        bulk_parse_error_count: metrics.bulkParseErrorCount,
                        bulk_missing_required_attr_count: metrics.bulkMissingRequiredAttrCount,
                        bulk_symlink_count: metrics.bulkSymlinkCount,
                        bulk_dataless_directory_count: metrics.bulkDatalessDirectoryCount,
                        records_per_second: Double(metrics.recordCount) / elapsed
                    )
                    let data = try encoder.encode(result)
                    print(String(decoding: data, as: UTF8.self))
                }
            }
        }
    }

    private static func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard
            let rawValue = ProcessInfo.processInfo.environment[name],
            let value = Int(rawValue),
            value > 0
        else {
            return nil
        }
        return value
    }

    private static func benchmarkRoots(from rawRoots: String) -> [URL] {
        rawRoots
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private func expectBulkParserFailure(
        _ bytes: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try BulkAttributeBufferParser.parseSingleEntry(bytes)
            Issue.record("Expected bulk parser failure", sourceLocation: sourceLocation)
        } catch {
        }
    }
}

private struct ScannerBenchmarkFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllTheThingsScannerBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeFile(_ relativePath: String) throws {
        let file = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "scanner benchmark fixture".write(to: file, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ScannerBenchmarkVariant: String, CaseIterable {
    case currentLike
    case getattrlistbulkRecord
    case ftsStatRecord
    case ftsStatDatalessPrune
    case ftsStatFastDefaultPrefilter
    case ftsStatCompiledExclusionQuery
    case ftsCountOnly
}

private struct ScannerBenchmarkMetrics {
    var visitedCount = 0
    var recordCount = 0
    var directoryCount = 0
    var fileCount = 0
    var prunedDirectoryCount = 0
    var errorCount = 0
    var metadataFetchCount = 0
    var fullExclusionDecisionCount = 0
    var compiledExclusionInstrumentation = FileExclusionQuery.Instrumentation()
    var indexedPaths = Set<String>()
    var bulkDirectoryCallCount = 0
    var bulkEntryCount = 0
    var bulkDirectoryFallbackCount = 0
    var bulkEntryFallbackCount = 0
    var bulkBufferRetryCount = 0
    var bulkParseErrorCount = 0
    var bulkMissingRequiredAttrCount = 0
    var bulkSymlinkCount = 0
    var bulkDatalessDirectoryCount = 0
}

private struct ScannerBenchmarkResult: Encodable {
    let variant: String
    let root: String
    let repeat_index: Int
    let elapsed_ms: Int
    let visited_count: Int
    let record_count: Int
    let directory_count: Int
    let file_count: Int
    let pruned_directory_count: Int
    let error_count: Int
    let metadata_fetch_count: Int
    let full_exclusion_decision_count: Int
    let compiled_exclusion_decision_count: Int
    let component_split_count: Int
    let ancestor_match_check_count: Int
    let regex_match_count: Int
    let fast_path_decision_count: Int
    let bulk_directory_call_count: Int
    let bulk_entry_count: Int
    let bulk_directory_fallback_count: Int
    let bulk_entry_fallback_count: Int
    let bulk_buffer_retry_count: Int
    let bulk_parse_error_count: Int
    let bulk_missing_required_attr_count: Int
    let bulk_symlink_count: Int
    let bulk_dataless_directory_count: Int
    let records_per_second: Double
}

private enum ScannerBenchmarkRunner {
    static func run(
        root: URL,
        variant: ScannerBenchmarkVariant,
        rules: FileExclusionRules,
        maxEntries: Int? = nil,
        collectsIndexedPaths: Bool = false
    ) -> ScannerBenchmarkMetrics {
        switch variant {
        case .currentLike:
            return runCurrentLike(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                collectsIndexedPaths: collectsIndexedPaths
            )
        case .getattrlistbulkRecord:
            return runGetattrlistbulkRecord(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                collectsIndexedPaths: collectsIndexedPaths
            )
        case .ftsStatRecord:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: false,
                createsRecords: true,
                collectsIndexedPaths: collectsIndexedPaths
            )
        case .ftsStatDatalessPrune:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: true,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: false,
                createsRecords: true,
                collectsIndexedPaths: collectsIndexedPaths
            )
        case .ftsStatFastDefaultPrefilter:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: true,
                usesCompiledExclusionQuery: false,
                createsRecords: true,
                collectsIndexedPaths: collectsIndexedPaths
            )
        case .ftsStatCompiledExclusionQuery:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: true,
                createsRecords: true,
                collectsIndexedPaths: collectsIndexedPaths
            )
        case .ftsCountOnly:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: false,
                createsRecords: false,
                collectsIndexedPaths: collectsIndexedPaths
            )
        }
    }

    private static func runCurrentLike(
        root: URL,
        rules: FileExclusionRules,
        maxEntries: Int?,
        collectsIndexedPaths: Bool
    ) -> ScannerBenchmarkMetrics {
        var metrics = ScannerBenchmarkMetrics()
        let rootPath = root.standardizedFileURL.path
        var pendingDirectories = [root.standardizedFileURL]

        while let directory = pendingDirectories.popLast() {
            guard !hasReachedLimit(metrics, maxEntries: maxEntries) else { break }
            autoreleasepool {
                metrics.metadataFetchCount += 1
                guard let values = try? directory.resourceValues(forKeys: FileRecord.resourceKeys) else {
                    metrics.errorCount += 1
                    return
                }

                let isDirectory = values.isDirectory == true
                noteVisitedEntry(isDirectory: isDirectory, metrics: &metrics)
                metrics.fullExclusionDecisionCount += 1
                let decision = rules.decision(url: directory, roots: [rootPath], isDirectory: isDirectory)
                guard decision != .prune else {
                    if isDirectory {
                        metrics.prunedDirectoryCount += 1
                    }
                    return
                }

                guard !(isDirectory && isSymbolicLink(directory, metrics: &metrics)) else { return }

                if decision.shouldIndex, FileRecord(url: directory, resourceValues: values) != nil {
                    metrics.recordCount += 1
                    if collectsIndexedPaths {
                        metrics.indexedPaths.insert(directory.standardizedFileURL.path)
                    }
                }

                guard isDirectory, decision.shouldDescend else { return }
                enumerateShallowChildURLs(in: directory) { child in
                    pendingDirectories.append(child)
                    return true
                }
            }
        }

        return metrics
    }

    private static func runFTSStat(
        root: URL,
        rules: FileExclusionRules,
        maxEntries: Int?,
        prunesDatalessDirectories: Bool,
        usesFastDefaultPrefilter: Bool,
        usesCompiledExclusionQuery: Bool,
        createsRecords: Bool,
        collectsIndexedPaths: Bool
    ) -> ScannerBenchmarkMetrics {
        var metrics = ScannerBenchmarkMetrics()
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let volumeName = createsRecords ? rootVolumeName(rootURL, metrics: &metrics) : ""
        let prefilter = usesFastDefaultPrefilter ? FastDefaultExclusionPrefilter(rootPath: rootPath) : nil
        let compiledQuery = usesCompiledExclusionQuery ? rules.makeQuery(roots: [rootPath]) : nil

        guard let rootPathCString = strdup(rootPath) else {
            metrics.errorCount += 1
            return metrics
        }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootPathCString, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            free(rootPathCString)
            metrics.errorCount += 1
            return metrics
        }
        defer {
            fts_close(stream)
            free(rootPathCString)
        }

        while let entry = fts_read(stream) {
            guard !hasReachedLimit(metrics, maxEntries: maxEntries) else { break }

            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP {
                continue
            }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                metrics.errorCount += 1
                continue
            }

            let statBlock = entry.pointee.fts_statp.pointee
            let isDirectory = isDirectoryMode(statBlock.st_mode)
            noteVisitedEntry(isDirectory: isDirectory, metrics: &metrics)
            let path = String(cString: entry.pointee.fts_path)

            guard createsRecords else { continue }

            if prunesDatalessDirectories, isDirectory, isDataless(statBlock) {
                metrics.prunedDirectoryCount += 1
                fts_set(stream, entry, FTS_SKIP)
                continue
            }

            let decision: FileExclusionRules.Decision
            if let compiledQuery {
                decision = compiledQuery.decision(
                    path: path,
                    isDirectory: isDirectory,
                    instrumentation: &metrics.compiledExclusionInstrumentation
                )
            } else if let prefilterDecision = prefilter?.decision(path: path, isDirectory: isDirectory) {
                decision = prefilterDecision
            } else {
                metrics.fullExclusionDecisionCount += 1
                decision = rules.decision(
                    url: URL(fileURLWithPath: path, isDirectory: isDirectory),
                    roots: [rootPath],
                    isDirectory: isDirectory
                )
            }

            guard decision != .prune else {
                if isDirectory {
                    metrics.prunedDirectoryCount += 1
                    fts_set(stream, entry, FTS_SKIP)
                }
                continue
            }

            if createsRecords, decision.shouldIndex {
                _ = FileRecord.statDerived(
                    path: path,
                    statBlock: statBlock,
                    isDirectory: isDirectory,
                    volumeName: volumeName
                )
                metrics.recordCount += 1
                if collectsIndexedPaths {
                    metrics.indexedPaths.insert(path)
                }
            }

            if isDirectory, !decision.shouldDescend {
                fts_set(stream, entry, FTS_SKIP)
            }
        }

        return metrics
    }

    private static func runGetattrlistbulkRecord(
        root: URL,
        rules: FileExclusionRules,
        maxEntries: Int?,
        collectsIndexedPaths: Bool
    ) -> ScannerBenchmarkMetrics {
        var metrics = ScannerBenchmarkMetrics()
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let volumeName = rootVolumeName(rootURL, metrics: &metrics)
        let query = rules.makeQuery(roots: [rootPath])
        guard let rootCandidate = statRecordCandidate(path: rootPath, volumeName: volumeName) else {
            metrics.errorCount += 1
            return metrics
        }
        guard let rootDecision = processGetattrlistbulkCandidate(
            path: rootPath,
            isDirectory: rootCandidate.isDirectory,
            isSymlink: rootCandidate.isSymlink,
            record: rootCandidate.record,
            flags: rootCandidate.flags,
            query: query,
            metrics: &metrics,
            collectsIndexedPaths: collectsIndexedPaths
        ) else {
            return metrics
        }

        var pendingDirectories: [URL] = []
        if rootCandidate.isDirectory, !rootCandidate.isSymlink, rootDecision.shouldDescend {
            pendingDirectories.append(rootURL)
        }

        while let directory = pendingDirectories.popLast() {
            guard !hasReachedLimit(metrics, maxEntries: maxEntries) else { break }
            autoreleasepool {
                let directoryPath = directory.standardizedFileURL.path
                if let entries = readGetattrlistbulkChildren(in: directory, metrics: &metrics) {
                    for entry in entries {
                        guard !hasReachedLimit(metrics, maxEntries: maxEntries) else { break }
                        let childPath = childPath(parentPath: directoryPath, name: entry.name)
                        let record: FileRecord?
                        let isDirectory: Bool
                        let isSymlink: Bool
                        let flags: UInt32?

                        if entry.requiresStatFallback {
                            metrics.bulkMissingRequiredAttrCount += 1
                            metrics.bulkEntryFallbackCount += 1
                            guard let candidate = statRecordCandidate(path: childPath, volumeName: volumeName) else {
                                metrics.errorCount += 1
                                continue
                            }
                            record = candidate.record
                            isDirectory = candidate.isDirectory
                            isSymlink = candidate.isSymlink
                            flags = candidate.flags
                        } else {
                            record = FileRecord.bulkDerived(
                                path: childPath,
                                isDirectory: entry.isDirectory,
                                sizeBytes: entry.sizeBytes ?? 0,
                                modifiedTime: entry.modifiedTime ?? 0,
                                createdTime: entry.createdTime,
                                volumeName: volumeName
                            )
                            isDirectory = entry.isDirectory
                            isSymlink = entry.isSymlink
                            flags = entry.flags
                        }

                        guard let decision = processGetattrlistbulkCandidate(
                            path: childPath,
                            isDirectory: isDirectory,
                            isSymlink: isSymlink,
                            record: record,
                            flags: flags,
                            query: query,
                            metrics: &metrics,
                            collectsIndexedPaths: collectsIndexedPaths
                        ) else {
                            continue
                        }

                        if isDirectory, !isSymlink, decision.shouldDescend {
                            pendingDirectories.append(URL(fileURLWithPath: childPath, isDirectory: true))
                        }
                    }
                } else {
                    for candidate in fallbackChildren(in: directory, volumeName: volumeName, metrics: &metrics) {
                        guard !hasReachedLimit(metrics, maxEntries: maxEntries) else { break }
                        guard let decision = processGetattrlistbulkCandidate(
                            path: candidate.path,
                            isDirectory: candidate.isDirectory,
                            isSymlink: candidate.isSymlink,
                            record: candidate.record,
                            flags: candidate.flags,
                            query: query,
                            metrics: &metrics,
                            collectsIndexedPaths: collectsIndexedPaths
                        ) else {
                            continue
                        }

                        if candidate.isDirectory, !candidate.isSymlink, decision.shouldDescend {
                            pendingDirectories.append(URL(fileURLWithPath: candidate.path, isDirectory: true))
                        }
                    }
                }
            }
        }

        return metrics
    }

    private static func processGetattrlistbulkCandidate(
        path: String,
        isDirectory: Bool,
        isSymlink: Bool,
        record: FileRecord?,
        flags: UInt32?,
        query: FileExclusionQuery,
        metrics: inout ScannerBenchmarkMetrics,
        collectsIndexedPaths: Bool
    ) -> FileExclusionRules.Decision? {
        noteVisitedEntry(isDirectory: isDirectory, metrics: &metrics)
        if isSymlink {
            metrics.bulkSymlinkCount += 1
        }
        if isDirectory, let flags, (flags & BulkAttributeBufferParser.datalessFlag) != 0 {
            metrics.bulkDatalessDirectoryCount += 1
        }

        let decision = query.decision(
            path: path,
            isDirectory: isDirectory,
            instrumentation: &metrics.compiledExclusionInstrumentation
        )
        guard decision != .prune else {
            if isDirectory {
                metrics.prunedDirectoryCount += 1
            }
            return nil
        }

        if decision.shouldIndex, record != nil {
            metrics.recordCount += 1
            if collectsIndexedPaths {
                metrics.indexedPaths.insert(path)
            }
        }

        return decision
    }

    private static func readGetattrlistbulkChildren(
        in directory: URL,
        metrics: inout ScannerBenchmarkMetrics
    ) -> [BulkDirectoryEntry]? {
        var bufferSize = BulkAttributeBufferParser.initialBufferSize
        while bufferSize <= BulkAttributeBufferParser.maximumBufferSize {
            switch readGetattrlistbulkChildrenOnce(in: directory, bufferSize: bufferSize, metrics: &metrics) {
            case let .success(entries):
                return entries
            case .retryLargerBuffer:
                metrics.bulkBufferRetryCount += 1
                bufferSize *= 2
            case .fallback:
                metrics.bulkDirectoryFallbackCount += 1
                return nil
            }
        }

        metrics.bulkDirectoryFallbackCount += 1
        return nil
    }

    private static func readGetattrlistbulkChildrenOnce(
        in directory: URL,
        bufferSize: Int,
        metrics: inout ScannerBenchmarkMetrics
    ) -> BulkDirectoryReadOutcome {
        directory.withUnsafeFileSystemRepresentation { representation -> BulkDirectoryReadOutcome in
            guard let representation else { return .fallback }
            let descriptor = open(representation, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return .fallback }
            defer { close(descriptor) }

            var attrs = BulkAttributeBufferParser.requestedAttributes()
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var entries: [BulkDirectoryEntry] = []
            var options = UInt64(FSOPT_NOFOLLOW)

            while true {
                errno = 0
                metrics.bulkDirectoryCallCount += 1
                let returnedCount = getattrlistbulk(
                    descriptor,
                    &attrs,
                    &buffer,
                    buffer.count,
                    options
                )

                if returnedCount == 0 {
                    return .success(entries)
                }

                if returnedCount < 0 {
                    let code = errno
                    if code == EINVAL, options != 0 {
                        options = 0
                        continue
                    }
                    if code == ERANGE {
                        return .retryLargerBuffer
                    }
                    if code != ENOTSUP, code != EINVAL, code != ENOTTY {
                        metrics.errorCount += 1
                    }
                    return .fallback
                }

                do {
                    let parsedEntries = try BulkAttributeBufferParser.parseEntries(
                        buffer,
                        entryCount: Int(returnedCount)
                    )
                    metrics.bulkEntryCount += parsedEntries.count
                    entries.append(contentsOf: parsedEntries)
                } catch let error as BulkAttributeParseError {
                    metrics.bulkParseErrorCount += 1
                    return error.needsLargerBuffer ? .retryLargerBuffer : .fallback
                } catch {
                    metrics.bulkParseErrorCount += 1
                    return .fallback
                }
            }
        }
    }

    private static func fallbackChildren(
        in directory: URL,
        volumeName: String,
        metrics: inout ScannerBenchmarkMetrics
    ) -> [StatRecordCandidate] {
        let directoryPath = directory.standardizedFileURL.path
        guard let stream = openDirectoryStream(directory) else {
            metrics.errorCount += 1
            return []
        }
        defer { closedir(stream) }

        var candidates: [StatRecordCandidate] = []
        while let entry = readdir(stream) {
            guard let entryInfo = FileIndex.directoryEntryInfo(entry) else { continue }
            let name = entryInfo.name
            guard name != "." && name != ".." else { continue }

            let path = childPath(parentPath: directoryPath, name: name)
            guard let candidate = statRecordCandidate(path: path, volumeName: volumeName) else {
                metrics.errorCount += 1
                continue
            }
            metrics.bulkEntryFallbackCount += 1
            candidates.append(candidate)
        }
        return candidates
    }

    private static func statRecordCandidate(path: String, volumeName: String) -> StatRecordCandidate? {
        var statBlock = stat()
        let result = path.withCString { lstat($0, &statBlock) }
        guard result == 0 else { return nil }

        let isDirectory = isDirectoryMode(statBlock.st_mode)
        let isSymlink = isSymbolicLinkMode(statBlock.st_mode)
        return StatRecordCandidate(
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            flags: statBlock.st_flags,
            record: FileRecord.statDerived(
                path: path,
                statBlock: statBlock,
                isDirectory: isDirectory,
                volumeName: volumeName
            )
        )
    }

    struct SampledEntry {
        let path: String
        let isDirectory: Bool
    }

    static func sampleFTSEntries(root: URL, maxEntries: Int) -> [SampledEntry] {
        let rootPath = root.standardizedFileURL.path
        guard let rootPathCString = strdup(rootPath) else { return [] }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootPathCString, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            free(rootPathCString)
            return []
        }
        defer {
            fts_close(stream)
            free(rootPathCString)
        }

        var samples: [SampledEntry] = []
        while let entry = fts_read(stream), samples.count < maxEntries {
            let info = Int32(entry.pointee.fts_info)
            guard info != FTS_DP else { continue }
            guard info != FTS_DNR, info != FTS_ERR, info != FTS_NS else { continue }

            let statBlock = entry.pointee.fts_statp.pointee
            samples.append(SampledEntry(
                path: String(cString: entry.pointee.fts_path),
                isDirectory: isDirectoryMode(statBlock.st_mode)
            ))
        }

        return samples
    }

    private static func rootVolumeName(_ root: URL, metrics: inout ScannerBenchmarkMetrics) -> String {
        metrics.metadataFetchCount += 1
        return (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
    }

    private static func isSymbolicLink(_ url: URL, metrics: inout ScannerBenchmarkMetrics) -> Bool {
        metrics.metadataFetchCount += 1
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func noteVisitedEntry(isDirectory: Bool, metrics: inout ScannerBenchmarkMetrics) {
        metrics.visitedCount += 1
        if isDirectory {
            metrics.directoryCount += 1
        } else {
            metrics.fileCount += 1
        }
    }

    private static func hasReachedLimit(_ metrics: ScannerBenchmarkMetrics, maxEntries: Int?) -> Bool {
        guard let maxEntries else { return false }
        return metrics.visitedCount >= maxEntries
    }

    @discardableResult
    private static func enumerateShallowChildURLs(in directory: URL, _ body: (URL) -> Bool) -> Bool {
        guard let stream = openDirectoryStream(directory) else {
            return false
        }
        defer { closedir(stream) }

        while let entry = readdir(stream) {
            guard let entryInfo = FileIndex.directoryEntryInfo(entry) else { continue }
            let name = entryInfo.name
            guard name != "." && name != ".." else { continue }

            let child = directory.appendingPathComponent(name, isDirectory: entryInfo.isDirectory)
            guard body(child) else { return false }
        }

        return true
    }

    private static func openDirectoryStream(_ directory: URL) -> UnsafeMutablePointer<DIR>? {
        directory.withUnsafeFileSystemRepresentation { representation -> UnsafeMutablePointer<DIR>? in
            guard let representation else { return nil }
            let descriptor = open(representation, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            guard let stream = fdopendir(descriptor) else {
                close(descriptor)
                return nil
            }
            return stream
        }
    }

    private static func isDirectoryMode(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isSymbolicLinkMode(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static func isDataless(_ statBlock: stat) -> Bool {
        (statBlock.st_flags & UInt32(SF_DATALESS)) != 0
    }

    private static func childPath(parentPath: String, name: String) -> String {
        if parentPath == "/" {
            return "/" + name
        }
        return parentPath + "/" + name
    }
}

private struct StatRecordCandidate {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let flags: UInt32
    let record: FileRecord
}

private struct BulkDirectoryEntry {
    let name: String
    let objectType: Int32
    let sizeBytes: UInt64?
    let modifiedTime: TimeInterval?
    let createdTime: TimeInterval?
    let flags: UInt32?

    var isDirectory: Bool {
        objectType == Int32(VDIR.rawValue)
    }

    var isSymlink: Bool {
        objectType == Int32(VLNK.rawValue)
    }

    var requiresStatFallback: Bool {
        guard modifiedTime != nil else { return true }
        return !isDirectory && sizeBytes == nil
    }
}

private enum BulkDirectoryReadOutcome {
    case success([BulkDirectoryEntry])
    case retryLargerBuffer
    case fallback
}

private enum BulkAttributeParseError: Error {
    case shortEntry
    case invalidEntryLength
    case entryExceedsBuffer
    case missingReturnedAttributes
    case invalidNameReference
    case invalidName
    case missingName
    case missingObjectType
    case truncatedFixedAttribute

    var needsLargerBuffer: Bool {
        switch self {
        case .entryExceedsBuffer:
            return true
        case .shortEntry,
             .invalidEntryLength,
             .missingReturnedAttributes,
             .invalidNameReference,
             .invalidName,
             .missingName,
             .missingObjectType,
             .truncatedFixedAttribute:
            return false
        }
    }
}

private enum BulkAttributeBufferParser {
    static let initialBufferSize = 64 * 1_024
    static let maximumBufferSize = 1 * 1_024 * 1_024
    static let datalessFlag = attrBit(SF_DATALESS)

    private static let returnedAttrsBit = UInt32(ATTR_CMN_RETURNED_ATTRS)
    private static let nameBit = attrBit(ATTR_CMN_NAME)
    private static let objectTypeBit = attrBit(ATTR_CMN_OBJTYPE)
    private static let creationTimeBit = attrBit(ATTR_CMN_CRTIME)
    private static let modificationTimeBit = attrBit(ATTR_CMN_MODTIME)
    private static let flagsBit = attrBit(ATTR_CMN_FLAGS)
    private static let fileDataLengthBit = attrBit(ATTR_FILE_DATALENGTH)
    private static let requestedCommonAttrs = returnedAttrsBit
        | nameBit
        | objectTypeBit
        | creationTimeBit
        | modificationTimeBit
        | flagsBit

    static func requestedAttributes() -> attrlist {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = requestedCommonAttrs
        attrs.fileattr = fileDataLengthBit
        return attrs
    }

    static func parseEntries(_ buffer: [UInt8], entryCount: Int) throws -> [BulkDirectoryEntry] {
        try buffer.withUnsafeBytes { rawBuffer in
            var entries: [BulkDirectoryEntry] = []
            var offset = 0
            for _ in 0..<entryCount {
                guard offset + MemoryLayout<UInt32>.size <= rawBuffer.count else {
                    throw BulkAttributeParseError.shortEntry
                }

                let entryLength = Int(rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard entryLength >= MemoryLayout<UInt32>.size else {
                    throw BulkAttributeParseError.invalidEntryLength
                }
                guard offset + entryLength <= rawBuffer.count else {
                    throw BulkAttributeParseError.entryExceedsBuffer
                }

                let entryBytes = UnsafeRawBufferPointer(
                    rebasing: rawBuffer[offset..<(offset + entryLength)]
                )
                entries.append(try parseEntry(entryBytes))
                offset += entryLength
            }
            return entries
        }
    }

    static func parseSingleEntry(_ bytes: [UInt8]) throws -> BulkDirectoryEntry {
        try bytes.withUnsafeBytes { rawBuffer in
            try parseEntry(rawBuffer)
        }
    }

    private static func parseEntry(_ rawBuffer: UnsafeRawBufferPointer) throws -> BulkDirectoryEntry {
        guard rawBuffer.count >= MemoryLayout<UInt32>.size else {
            throw BulkAttributeParseError.shortEntry
        }

        let entryLength = Int(rawBuffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        guard entryLength == rawBuffer.count, entryLength >= MemoryLayout<UInt32>.size else {
            throw BulkAttributeParseError.invalidEntryLength
        }

        var cursor = MemoryLayout<UInt32>.size
        let returnedAttrs = try readReturnedAttributes(from: rawBuffer, cursor: &cursor)
        guard (returnedAttrs.common & returnedAttrsBit) != 0 else {
            throw BulkAttributeParseError.missingReturnedAttributes
        }

        var name: String?
        var objectType: Int32?
        var createdTime: TimeInterval?
        var modifiedTime: TimeInterval?
        var flags: UInt32?
        var sizeBytes: UInt64?

        if returnedAttrs.hasCommon(nameBit) {
            let referenceOffset = cursor
            let dataOffset = try readFixed(Int32.self, from: rawBuffer, cursor: &cursor)
            let dataLength = try readFixed(UInt32.self, from: rawBuffer, cursor: &cursor)
            name = try readName(
                from: rawBuffer,
                referenceOffset: referenceOffset,
                dataOffset: dataOffset,
                dataLength: dataLength
            )
        }
        if returnedAttrs.hasCommon(objectTypeBit) {
            objectType = try readFixed(Int32.self, from: rawBuffer, cursor: &cursor)
        }
        if returnedAttrs.hasCommon(creationTimeBit) {
            let value = try readFixed(timespec.self, from: rawBuffer, cursor: &cursor)
            if value.tv_sec > 0 {
                createdTime = FileRecord.timeIntervalSinceReferenceDateForScannerBenchmark(value)
            }
        }
        if returnedAttrs.hasCommon(modificationTimeBit) {
            let value = try readFixed(timespec.self, from: rawBuffer, cursor: &cursor)
            modifiedTime = FileRecord.timeIntervalSinceReferenceDateForScannerBenchmark(value)
        }
        if returnedAttrs.hasCommon(flagsBit) {
            flags = try readFixed(UInt32.self, from: rawBuffer, cursor: &cursor)
        }
        if returnedAttrs.hasFile(fileDataLengthBit) {
            let value = try readFixed(Int64.self, from: rawBuffer, cursor: &cursor)
            sizeBytes = value > 0 ? UInt64(value) : 0
        }

        guard let name else { throw BulkAttributeParseError.missingName }
        guard let objectType else { throw BulkAttributeParseError.missingObjectType }

        return BulkDirectoryEntry(
            name: name,
            objectType: objectType,
            sizeBytes: sizeBytes,
            modifiedTime: modifiedTime,
            createdTime: createdTime,
            flags: flags
        )
    }

    private static func readReturnedAttributes(
        from rawBuffer: UnsafeRawBufferPointer,
        cursor: inout Int
    ) throws -> ReturnedAttributes {
        let common = try readFixed(UInt32.self, from: rawBuffer, cursor: &cursor)
        let volume = try readFixed(UInt32.self, from: rawBuffer, cursor: &cursor)
        let directory = try readFixed(UInt32.self, from: rawBuffer, cursor: &cursor)
        let file = try readFixed(UInt32.self, from: rawBuffer, cursor: &cursor)
        let fork = try readFixed(UInt32.self, from: rawBuffer, cursor: &cursor)
        return ReturnedAttributes(
            common: common,
            volume: volume,
            directory: directory,
            file: file,
            fork: fork
        )
    }

    private static func readFixed<T>(
        _ type: T.Type,
        from rawBuffer: UnsafeRawBufferPointer,
        cursor: inout Int
    ) throws -> T {
        guard cursor + MemoryLayout<T>.size <= rawBuffer.count else {
            throw BulkAttributeParseError.truncatedFixedAttribute
        }
        let value = rawBuffer.loadUnaligned(fromByteOffset: cursor, as: T.self)
        cursor += MemoryLayout<T>.stride
        return value
    }

    private static func readName(
        from rawBuffer: UnsafeRawBufferPointer,
        referenceOffset: Int,
        dataOffset: Int32,
        dataLength: UInt32
    ) throws -> String {
        guard dataOffset >= 0, dataLength > 0 else {
            throw BulkAttributeParseError.invalidNameReference
        }

        let start = referenceOffset + Int(dataOffset)
        let length = Int(dataLength)
        guard start >= 0, start + length <= rawBuffer.count else {
            throw BulkAttributeParseError.invalidNameReference
        }

        var nameBytes = Array(rawBuffer[start..<(start + length)])
        if nameBytes.last == 0 {
            nameBytes.removeLast()
        }
        guard
            !nameBytes.isEmpty,
            let name = String(bytes: nameBytes, encoding: .utf8),
            name != ".",
            name != ".."
        else {
            throw BulkAttributeParseError.invalidName
        }
        return name
    }

    fileprivate static func attrBit(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: value)
    }

    fileprivate struct ReturnedAttributes {
        let common: UInt32
        let volume: UInt32
        let directory: UInt32
        let file: UInt32
        let fork: UInt32

        func hasCommon(_ bit: UInt32) -> Bool {
            (common & bit) != 0
        }

        func hasFile(_ bit: UInt32) -> Bool {
            (file & bit) != 0
        }
    }
}

private enum BulkAttributeTestEntryBuilder {
    static func entry(
        name: String = "alpha.txt",
        objectType: Int32 = Int32(VREG.rawValue),
        includesObjectType: Bool = true,
        includesCreationTime: Bool = true,
        includesModifiedTime: Bool = true,
        includesFlags: Bool = true,
        includesFileLength: Bool = true
    ) -> [UInt8] {
        entry(
            nameBytes: Array(name.utf8) + [0],
            objectType: objectType,
            includesObjectType: includesObjectType,
            includesCreationTime: includesCreationTime,
            includesModifiedTime: includesModifiedTime,
            includesFlags: includesFlags,
            includesFileLength: includesFileLength
        )
    }

    static func entry(
        nameBytes: [UInt8],
        objectType: Int32 = Int32(VREG.rawValue),
        includesObjectType: Bool = true,
        includesCreationTime: Bool = true,
        includesModifiedTime: Bool = true,
        includesFlags: Bool = true,
        includesFileLength: Bool = true
    ) -> [UInt8] {
        var commonAttrs = UInt32(ATTR_CMN_RETURNED_ATTRS)
            | BulkAttributeBufferParser.attrBit(ATTR_CMN_NAME)
        if includesObjectType {
            commonAttrs |= BulkAttributeBufferParser.attrBit(ATTR_CMN_OBJTYPE)
        }
        if includesCreationTime {
            commonAttrs |= BulkAttributeBufferParser.attrBit(ATTR_CMN_CRTIME)
        }
        if includesModifiedTime {
            commonAttrs |= BulkAttributeBufferParser.attrBit(ATTR_CMN_MODTIME)
        }
        if includesFlags {
            commonAttrs |= BulkAttributeBufferParser.attrBit(ATTR_CMN_FLAGS)
        }
        let fileAttrs = includesFileLength
            ? BulkAttributeBufferParser.attrBit(ATTR_FILE_DATALENGTH)
            : 0

        var bytes: [UInt8] = []
        append(UInt32(0), to: &bytes)
        append(commonAttrs, to: &bytes)
        append(UInt32(0), to: &bytes)
        append(UInt32(0), to: &bytes)
        append(fileAttrs, to: &bytes)
        append(UInt32(0), to: &bytes)

        let nameReferenceOffset = bytes.count
        append(Int32(0), to: &bytes)
        append(UInt32(nameBytes.count), to: &bytes)
        if includesObjectType {
            append(objectType, to: &bytes)
        }
        if includesCreationTime {
            append(timespec(tv_sec: 1_700_000_000, tv_nsec: 10), to: &bytes)
        }
        if includesModifiedTime {
            append(timespec(tv_sec: 1_700_000_001, tv_nsec: 20), to: &bytes)
        }
        if includesFlags {
            append(UInt32(0), to: &bytes)
        }
        if includesFileLength {
            append(Int64(123), to: &bytes)
        }

        let nameStart = bytes.count
        bytes.append(contentsOf: nameBytes)
        while bytes.count % 4 != 0 {
            bytes.append(0)
        }

        overwrite(UInt32(bytes.count), in: &bytes, at: 0)
        overwrite(Int32(nameStart - nameReferenceOffset), in: &bytes, at: nameReferenceOffset)
        return bytes
    }

    private static func append<T>(_ value: T, to bytes: inout [UInt8]) {
        var mutableValue = value
        withUnsafeBytes(of: &mutableValue) { rawBuffer in
            bytes.append(contentsOf: rawBuffer)
        }
    }

    private static func overwrite<T>(_ value: T, in bytes: inout [UInt8], at offset: Int) {
        var mutableValue = value
        withUnsafeBytes(of: &mutableValue) { rawBuffer in
            for index in rawBuffer.indices {
                bytes[offset + index] = rawBuffer[index]
            }
        }
    }
}

private struct FastDefaultExclusionPrefilter {
    private static let prunedDirectoryComponentNames: Set<String> = [
        "node_modules",
        "DerivedData",
        ".dart_tool",
        ".parcel-cache",
        ".turbo",
        ".venv",
        "venv",
        ".tox",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        ".cache",
        ".Trash"
    ]

    let rootPath: String

    func decision(path: String, isDirectory: Bool) -> FileExclusionRules.Decision? {
        let relativePath: String
        if path == rootPath {
            relativePath = ""
        } else if path.hasPrefix(rootPath + "/") {
            relativePath = String(path.dropFirst(rootPath.count + 1))
        } else {
            return nil
        }

        guard !relativePath.isEmpty else { return nil }
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }

        let directoryComponents = isDirectory ? components : components.dropLast()
        guard directoryComponents.contains(where: Self.prunedDirectoryComponentNames.contains) else {
            return nil
        }
        return .prune
    }
}

private extension FileRecord {
    static func bulkDerived(
        path: String,
        isDirectory: Bool,
        sizeBytes: UInt64,
        modifiedTime: TimeInterval,
        createdTime: TimeInterval?,
        volumeName: String
    ) -> FileRecord {
        let name = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        let directoryPath = (path as NSString).deletingLastPathComponent

        return FileRecord(
            id: FileRecord.stableID(for: path),
            path: path,
            name: name,
            directoryPath: directoryPath,
            fileExtension: (name as NSString).pathExtension.lowercased(),
            sizeBytes: isDirectory ? 0 : sizeBytes,
            modifiedTime: modifiedTime,
            createdTime: createdTime,
            isDirectory: isDirectory,
            isHidden: FileRecord.pathIsHidden(path),
            volumeName: volumeName,
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }

    static func statDerived(
        path: String,
        statBlock: stat,
        isDirectory: Bool,
        volumeName: String
    ) -> FileRecord {
        let name = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        let directoryPath = (path as NSString).deletingLastPathComponent
        let size = statBlock.st_size > 0 ? UInt64(statBlock.st_size) : 0
        let modifiedTime = timeIntervalSinceReferenceDate(statBlock.st_mtimespec)
        let createdTime = statBlock.st_birthtimespec.tv_sec > 0
            ? timeIntervalSinceReferenceDate(statBlock.st_birthtimespec)
            : nil

        return FileRecord(
            id: FileRecord.stableID(for: path),
            path: path,
            name: name,
            directoryPath: directoryPath,
            fileExtension: (name as NSString).pathExtension.lowercased(),
            sizeBytes: isDirectory ? 0 : size,
            modifiedTime: modifiedTime,
            createdTime: createdTime,
            isDirectory: isDirectory,
            isHidden: FileRecord.pathIsHidden(path),
            volumeName: volumeName,
            normalizedName: FuzzyMatcher.normalize(name),
            normalizedPath: FuzzyMatcher.normalize(path)
        )
    }

    static func timeIntervalSinceReferenceDateForScannerBenchmark(_ timespec: timespec) -> TimeInterval {
        timeIntervalSinceReferenceDate(timespec)
    }

    private static func timeIntervalSinceReferenceDate(_ timespec: timespec) -> TimeInterval {
        Date(timeIntervalSince1970: TimeInterval(timespec.tv_sec)).timeIntervalSinceReferenceDate
    }
}
