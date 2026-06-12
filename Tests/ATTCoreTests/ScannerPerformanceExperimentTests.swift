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

        #expect(current.recordCount == fts.recordCount)
        #expect(current.recordCount == compiledQuery.recordCount)
        #expect(current.recordCount > 0)
        #expect(current.prunedDirectoryCount == fts.prunedDirectoryCount)
        #expect(current.prunedDirectoryCount == compiledQuery.prunedDirectoryCount)
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
    let records_per_second: Double
}

private enum ScannerBenchmarkRunner {
    static func run(
        root: URL,
        variant: ScannerBenchmarkVariant,
        rules: FileExclusionRules,
        maxEntries: Int? = nil
    ) -> ScannerBenchmarkMetrics {
        switch variant {
        case .currentLike:
            return runCurrentLike(root: root, rules: rules, maxEntries: maxEntries)
        case .ftsStatRecord:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: false,
                createsRecords: true
            )
        case .ftsStatDatalessPrune:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: true,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: false,
                createsRecords: true
            )
        case .ftsStatFastDefaultPrefilter:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: true,
                usesCompiledExclusionQuery: false,
                createsRecords: true
            )
        case .ftsStatCompiledExclusionQuery:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: true,
                createsRecords: true
            )
        case .ftsCountOnly:
            return runFTSStat(
                root: root,
                rules: rules,
                maxEntries: maxEntries,
                prunesDatalessDirectories: false,
                usesFastDefaultPrefilter: false,
                usesCompiledExclusionQuery: false,
                createsRecords: false
            )
        }
    }

    private static func runCurrentLike(
        root: URL,
        rules: FileExclusionRules,
        maxEntries: Int?
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
        createsRecords: Bool
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
            }

            if isDirectory, !decision.shouldDescend {
                fts_set(stream, entry, FTS_SKIP)
            }
        }

        return metrics
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

    private static func isDataless(_ statBlock: stat) -> Bool {
        (statBlock.st_flags & UInt32(SF_DATALESS)) != 0
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

    private static func timeIntervalSinceReferenceDate(_ timespec: timespec) -> TimeInterval {
        Date(timeIntervalSince1970: TimeInterval(timespec.tv_sec)).timeIntervalSinceReferenceDate
    }
}
