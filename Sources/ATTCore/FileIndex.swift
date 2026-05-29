@preconcurrency import Darwin
import Foundation
import os

public enum SortColumn: String, Codable, CaseIterable, Sendable {
    case relevance
    case name
    case path
    case modified
    case created
    case size
    case fileExtension
    case kind
    case volume
}

public struct SortSpec: Codable, Equatable, Sendable {
    public let column: SortColumn
    public let ascending: Bool

    public init(column: SortColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public struct SearchRequest: Sendable {
    public let query: String
    public let sort: SortSpec
    public let includeHidden: Bool

    public init(query: String, sort: SortSpec, includeHidden: Bool = true) {
        self.query = query
        self.sort = sort
        self.includeHidden = includeHidden
    }
}

public struct SearchResult: Identifiable, Sendable {
    public let record: FileRecord
    public let score: Int

    public var id: UInt64 {
        record.id
    }
}

public struct SearchResponse: Sendable {
    public let results: [SearchResult]
    public let totalMatches: Int
    public let elapsed: TimeInterval

    public init(results: [SearchResult], totalMatches: Int, elapsed: TimeInterval) {
        self.results = results
        self.totalMatches = totalMatches
        self.elapsed = elapsed
    }
}

public enum IndexPhase: String, Sendable {
    case idle
    case loading
    case scanning
    case optimizing
    case saving
    case ready
    case failed
}

public struct IndexStats: Sendable {
    public let indexedCount: Int
    public let isIndexing: Bool
    public let isLoadingSnapshot: Bool
    public let phase: IndexPhase
    public let discoveredCount: Int
    public let searchableCount: Int
    public let optimizedCount: Int
    public let status: String
    public let lastUpdated: Date

    public init(
        indexedCount: Int,
        isIndexing: Bool,
        isLoadingSnapshot: Bool = false,
        phase: IndexPhase? = nil,
        discoveredCount: Int? = nil,
        searchableCount: Int? = nil,
        optimizedCount: Int? = nil,
        status: String,
        lastUpdated: Date
    ) {
        self.indexedCount = indexedCount
        self.isIndexing = isIndexing
        self.isLoadingSnapshot = isLoadingSnapshot
        self.phase = phase ?? (isLoadingSnapshot ? .loading : (isIndexing ? .scanning : .ready))
        self.discoveredCount = discoveredCount ?? indexedCount
        self.searchableCount = searchableCount ?? indexedCount
        self.optimizedCount = optimizedCount ?? (isIndexing ? 0 : indexedCount)
        self.status = status
        self.lastUpdated = lastUpdated
    }
}

struct FileIndexDiagnostics: Sendable {
    let indexedCount: Int
    let snapshotRevision: UInt64
    let phase: IndexPhase
    let discoveredCount: Int
    let searchableCount: Int
    let optimizedCount: Int
    let pathGramIndexEnabled: Bool
    let pathGramKeyCount: Int
    let pathGramPostingCount: Int
    let nameGramKeyCount: Int
    let nameGramPostingCount: Int
    let extensionKeyCount: Int
    let extensionPostingCount: Int
    let completedRefreshBatches: UInt64
    let completedSnapshotRebuilds: UInt64
    let activeIndexJobs: Int
}

public final class FileIndex: @unchecked Sendable {
    private static let snapshotSchemaVersion = 3
    private static let maximumRefreshBatchPaths = 512
    private static let primaryPublishRecordInterval = 25_000
    private static let primaryPublishTimeInterval: TimeInterval = 1
    private static let pathGramRecordLimit = 75_000
    private static let pathGramTotalPathByteLimit = 24 * 1024 * 1024

    public var onStatsChanged: (@MainActor @Sendable (IndexStats) -> Void)? {
        get {
            lock.withLock {
                statsChangedHandler
            }
        }
        set {
            lock.withLock {
                statsChangedHandler = newValue
            }
        }
    }

    private struct PersistedSnapshot: Codable {
        let savedAt: Date
        let roots: [String]?
        let exclusionPatterns: [String]?
        let records: [FileRecord]
    }

    private struct PersistedSnapshotHeader: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let roots: [String]
        let exclusionPatterns: [String]
        let recordCount: Int
    }

    private struct RecordCollectionMetrics {
        let recordCount: Int
        let totalPathBytes: Int
        let maxPathBytes: Int
    }

    private struct SearchStructureDiagnostics {
        let pathGramIndexEnabled: Bool
        let pathGramKeyCount: Int
        let pathGramPostingCount: Int
        let nameGramKeyCount: Int
        let nameGramPostingCount: Int
        let extensionKeyCount: Int
        let extensionPostingCount: Int
    }

    private enum MemoryTelemetry {
        private struct MemorySample {
            let virtualBytes: UInt64
            let residentBytes: UInt64
            let physicalFootprintBytes: UInt64
        }

        private static let logger = Logger(subsystem: "com.allthethings.index", category: "memory")
        private static let signpostLog = OSLog(subsystem: "com.allthethings.index", category: .pointsOfInterest)

        static func log(
            _ event: String,
            records: RecordCollectionMetrics? = nil,
            structures: SearchStructureDiagnostics? = nil,
            refreshBatchSize: Int = 0,
            activeIndexJobs: Int = 0
        ) {
            os_signpost(.event, log: signpostLog, name: "IndexMemory")
            let memory = currentMemory()
            logger.info(
                """
                event=\(event, privacy: .public) \
                records=\(records?.recordCount ?? 0, privacy: .public) \
                totalPathBytes=\(records?.totalPathBytes ?? 0, privacy: .public) \
                maxPathBytes=\(records?.maxPathBytes ?? 0, privacy: .public) \
                pathGramKeys=\(structures?.pathGramKeyCount ?? 0, privacy: .public) \
                pathGramPostings=\(structures?.pathGramPostingCount ?? 0, privacy: .public) \
                nameGramKeys=\(structures?.nameGramKeyCount ?? 0, privacy: .public) \
                nameGramPostings=\(structures?.nameGramPostingCount ?? 0, privacy: .public) \
                extensionKeys=\(structures?.extensionKeyCount ?? 0, privacy: .public) \
                extensionPostings=\(structures?.extensionPostingCount ?? 0, privacy: .public) \
                refreshBatchSize=\(refreshBatchSize, privacy: .public) \
                activeIndexJobs=\(activeIndexJobs, privacy: .public) \
                residentBytes=\(memory?.residentBytes ?? 0, privacy: .public) \
                physicalFootprintBytes=\(memory?.physicalFootprintBytes ?? 0, privacy: .public) \
                virtualBytes=\(memory?.virtualBytes ?? 0, privacy: .public)
                """
            )
        }

        private static func currentMemory() -> MemorySample? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }

            guard result == KERN_SUCCESS else { return nil }
            return MemorySample(
                virtualBytes: UInt64(info.virtual_size),
                residentBytes: UInt64(info.resident_size),
                physicalFootprintBytes: UInt64(info.phys_footprint)
            )
        }
    }

    private struct ExactTextFastQuery {
        let clauses: [ExactTextFastClause]
    }

    private struct ExactTextFastClause {
        let alternatives: [ExactTextFastAlternative]
    }

    private struct ExactTextFastAlternative {
        let field: FuzzyMatcher.QueryField
        let token: String
        let tokenBytes: [UInt8]
    }

    private struct UTF8Match {
        let offset: Int
        let isBoundary: Bool
        let textByteCount: Int
    }

    private enum SnapshotLoadState {
        case notStarted
        case loading
        case finished
    }

    private struct ScanResult {
        let records: [String: FileRecord]
        let visited: Int
    }

    private final class ConcurrentScanState: @unchecked Sendable {
        private let condition = NSCondition()
        private var pendingDirectories: [URL] = []
        private var activeDirectories = 0
        private var shouldStop = false
        private var records: [String: FileRecord]
        private var visited = 0
        private var lastPublishedCount = 0
        private var lastPublishedAt = Date.distantPast

        init(reservedCapacity: Int) {
            records = [:]
            records.reserveCapacity(reservedCapacity)
        }

        func enqueue(_ directory: URL) {
            condition.lock()
            pendingDirectories.append(directory)
            condition.signal()
            condition.unlock()
        }

        func addInitialRecord(_ record: FileRecord) {
            condition.lock()
            records[record.path] = record
            visited += 1
            condition.unlock()
        }

        func markStopped() {
            condition.lock()
            shouldStop = true
            condition.broadcast()
            condition.unlock()
        }

        func nextDirectory() -> URL? {
            condition.lock()
            defer { condition.unlock() }

            while pendingDirectories.isEmpty, activeDirectories > 0, !shouldStop {
                condition.wait()
            }

            guard !shouldStop, !(pendingDirectories.isEmpty && activeDirectories == 0) else {
                return nil
            }

            activeDirectories += 1
            return pendingDirectories.removeLast()
        }

        func finishDirectory() {
            condition.lock()
            activeDirectories -= 1
            if shouldStop || (pendingDirectories.isEmpty && activeDirectories == 0) {
                condition.broadcast()
            } else {
                condition.signal()
            }
            condition.unlock()
        }

        func append(_ batch: [FileRecord]) {
            guard !batch.isEmpty else { return }

            condition.lock()
            for record in batch {
                records[record.path] = record
                visited += 1
            }
            condition.unlock()
        }

        func publishSnapshotIfNeeded(force: Bool) -> ScanResult? {
            condition.lock()
            defer { condition.unlock() }

            let now = Date()
            let shouldPublish = force
                || records.count - lastPublishedCount >= FileIndex.primaryPublishRecordInterval
                || now.timeIntervalSince(lastPublishedAt) >= FileIndex.primaryPublishTimeInterval
            guard shouldPublish else { return nil }

            lastPublishedCount = records.count
            lastPublishedAt = now
            return ScanResult(records: records, visited: visited)
        }

        func result() -> (ScanResult, Bool) {
            condition.lock()
            defer { condition.unlock() }
            return (ScanResult(records: records, visited: visited), shouldStop)
        }
    }

    private struct CandidateBitSet {
        private var words: [UInt64]

        init(count: Int) {
            words = Array(repeating: 0, count: (count + 63) / 64)
        }

        mutating func insert(_ index: Int) {
            words[index >> 6] |= UInt64(1) << UInt64(index & 63)
        }

        func contains(_ index: Int) -> Bool {
            (words[index >> 6] & (UInt64(1) << UInt64(index & 63))) != 0
        }
    }

    private final class SearchSnapshot: @unchecked Sendable {
        static let empty = SearchSnapshot(records: [], buildsSearchStructures: false)

        let records: [FileRecord]
        let modifiedDescending: [Int]
        let modifiedAscending: [Int]
        let gramIndex: [Int: [Int32]]
        let nameGramIndex: [Int: [Int32]]
        let extensionIndex: [String: [Int32]]
        let hasSortedOrder: Bool
        let diagnostics: SearchStructureDiagnostics

        init(records: [FileRecord], buildsSearchStructures: Bool = true) {
            self.records = records

            if buildsSearchStructures {
                let metrics = FileIndex.metrics(for: records)
                let buildsPathGramIndex = FileIndex.shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes)
                self.gramIndex = buildsPathGramIndex ? Self.makePathGramIndex(records: records) : [:]
                self.nameGramIndex = Self.makeNameGramIndex(records: records)
                self.extensionIndex = Self.makeExtensionIndex(records: records)
                let sortedByModified = Self.makeModifiedDescending(records: records)
                self.modifiedDescending = sortedByModified
                self.modifiedAscending = Array(sortedByModified.reversed())
                self.hasSortedOrder = true
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: buildsPathGramIndex,
                    gramIndex: gramIndex,
                    nameGramIndex: nameGramIndex,
                    extensionIndex: extensionIndex
                )
            } else {
                self.gramIndex = [:]
                self.nameGramIndex = [:]
                self.extensionIndex = [:]
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.hasSortedOrder = false
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: false,
                    gramIndex: gramIndex,
                    nameGramIndex: nameGramIndex,
                    extensionIndex: extensionIndex
                )
            }
        }

        private init(
            records: [FileRecord],
            modifiedDescending: [Int],
            gramIndex: [Int: [Int32]],
            nameGramIndex: [Int: [Int32]],
            extensionIndex: [String: [Int32]],
            hasSortedOrder: Bool
        ) {
            self.records = records
            self.modifiedDescending = modifiedDescending
            self.modifiedAscending = Array(modifiedDescending.reversed())
            self.gramIndex = gramIndex
            self.nameGramIndex = nameGramIndex
            self.extensionIndex = extensionIndex
            self.hasSortedOrder = hasSortedOrder
            self.diagnostics = Self.makeDiagnostics(
                pathGramIndexEnabled: !gramIndex.isEmpty,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                extensionIndex: extensionIndex
            )
        }

        func updatingMetadata(for upserts: [String: FileRecord]) -> SearchSnapshot? {
            guard hasSortedOrder, !upserts.isEmpty else { return nil }

            let upsertPaths = Set(upserts.keys)
            var existingIndices: [String: Int] = [:]
            existingIndices.reserveCapacity(upserts.count)

            for (index, record) in records.enumerated() where upsertPaths.contains(record.path) {
                existingIndices[record.path] = index
                if existingIndices.count == upserts.count {
                    break
                }
            }

            guard existingIndices.count == upserts.count else {
                return nil
            }

            var updatedRecords = records
            var changedIndices: [Int] = []
            changedIndices.reserveCapacity(upserts.count)

            for (path, record) in upserts {
                guard let index = existingIndices[path] else {
                    return nil
                }
                updatedRecords[index] = record
                changedIndices.append(index)
            }

            let changed = Set(changedIndices)
            let unchangedDescending = modifiedDescending.filter { !changed.contains($0) }
            let changedDescending = changedIndices.sorted {
                Self.modifiedDescendingPrecedes($0, $1, records: updatedRecords)
            }
            let mergedDescending = Self.mergeModifiedDescending(
                changed: changedDescending,
                unchanged: unchangedDescending,
                records: updatedRecords
            )

            return SearchSnapshot(
                records: updatedRecords,
                modifiedDescending: mergedDescending,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                extensionIndex: extensionIndex,
                hasSortedOrder: true
            )
        }

        func addingNameGramIndex() -> SearchSnapshot {
            guard nameGramIndex.isEmpty else { return self }
            return SearchSnapshot(
                records: records,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                nameGramIndex: Self.makeNameGramIndex(records: records),
                extensionIndex: extensionIndex,
                hasSortedOrder: hasSortedOrder
            )
        }

        func addingExtensionIndex() -> SearchSnapshot {
            guard extensionIndex.isEmpty else { return self }
            return SearchSnapshot(
                records: records,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                extensionIndex: Self.makeExtensionIndex(records: records),
                hasSortedOrder: hasSortedOrder
            )
        }

        func addingModifiedSortOrder() -> SearchSnapshot {
            guard !hasSortedOrder else { return self }
            return SearchSnapshot(
                records: records,
                modifiedDescending: Self.makeModifiedDescending(records: records),
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                extensionIndex: extensionIndex,
                hasSortedOrder: true
            )
        }

        func addingPathGramIndexIfBudgetAllows() -> SearchSnapshot {
            guard gramIndex.isEmpty else { return self }
            let metrics = FileIndex.metrics(for: records)
            guard FileIndex.shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes) else {
                return self
            }
            return SearchSnapshot(
                records: records,
                modifiedDescending: modifiedDescending,
                gramIndex: Self.makePathGramIndex(records: records),
                nameGramIndex: nameGramIndex,
                extensionIndex: extensionIndex,
                hasSortedOrder: hasSortedOrder
            )
        }

        func orderedIndices(for sort: SortSpec, queryIsEmpty: Bool) -> [Int]? {
            guard hasSortedOrder else { return nil }

            switch sort.column {
            case .modified:
                return sort.ascending ? modifiedAscending : modifiedDescending
            case .relevance where queryIsEmpty:
                return modifiedDescending
            case .relevance, .name, .path, .created, .size, .fileExtension, .kind, .volume:
                return nil
            }
        }

        func candidatePathIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            guard !gramIndex.isEmpty else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = gramIndex[key] else {
                    return []
                }
                postings.append(values)
            }

            postings.sort { $0.count < $1.count }
            if postings.count == 1 {
                return postings[0]
            }

            return FileIndex.intersectPostingLists(postings)
        }

        func candidateIndices(containing tokenBytes: [UInt8], field: FuzzyMatcher.QueryField) -> [Int32]? {
            switch field {
            case .name:
                return candidateNameIndices(containing: tokenBytes)
            case .path:
                return candidatePathIndices(containing: tokenBytes)
            case .any:
                let nameCandidates = candidateNameIndices(containing: tokenBytes)
                let pathCandidates = candidatePathIndices(containing: tokenBytes)
                switch (nameCandidates, pathCandidates) {
                case (.some(let name), .some(let path)):
                    return FileIndex.unionPostingLists(path, name)
                case (.some(let name), .none):
                    return name
                case (.none, .some(let path)):
                    return path
                case (.none, .none):
                    return nil
                }
            }
        }

        func candidateNameIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            guard !nameGramIndex.isEmpty else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = nameGramIndex[key] else {
                    return []
                }
                postings.append(values)
            }

            postings.sort { $0.count < $1.count }
            if postings.count == 1 {
                return postings[0]
            }

            return FileIndex.intersectPostingLists(postings)
        }

        func candidateNameIndices(containingAny tokenByteSets: [[UInt8]]) -> [Int32]? {
            guard !tokenByteSets.isEmpty else { return nil }

            var candidates: [Int32] = []
            for tokenBytes in tokenByteSets {
                guard let values = candidateNameIndices(containingAllBytes: tokenBytes) else {
                    return nil
                }
                candidates = FileIndex.unionPostingLists(candidates, values)
            }

            return candidates
        }

        private func candidateNameIndices(containingAllBytes tokenBytes: [UInt8]) -> [Int32]? {
            guard !nameGramIndex.isEmpty, !tokenBytes.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(tokenBytes.count)

            for byte in tokenBytes {
                let key = FileIndex.searchGramKey(bytes: [byte], start: 0, length: 1)
                guard let values = nameGramIndex[key] else {
                    return []
                }
                postings.append(values)
            }

            postings.sort { $0.count < $1.count }
            if postings.count == 1 {
                return postings[0]
            }

            return FileIndex.intersectPostingLists(postings)
        }

        func candidateIndices(fileExtension token: String, mode: FuzzyMatcher.MatchMode) -> [Int32]? {
            guard !extensionIndex.isEmpty, !token.isEmpty else { return nil }

            switch mode {
            case .exact:
                return extensionIndex[token] ?? []
            case .fuzzy:
                var candidates: [Int32] = []
                for (fileExtension, values) in extensionIndex where fileExtension == token || fileExtension.hasPrefix(token) {
                    candidates = FileIndex.unionPostingLists(candidates, values)
                }
                return candidates
            case .wildcard:
                if !token.contains("*"), !token.contains("?") {
                    return extensionIndex[token] ?? []
                }

                var candidates: [Int32] = []
                for (fileExtension, values) in extensionIndex where FileIndex.wildcardMatches(fileExtension, pattern: token) {
                    candidates = FileIndex.unionPostingLists(candidates, values)
                }
                return candidates
            }
        }

        private static func mergeModifiedDescending(changed: [Int], unchanged: [Int], records: [FileRecord]) -> [Int] {
            var merged: [Int] = []
            merged.reserveCapacity(changed.count + unchanged.count)

            var changedIndex = 0
            var unchangedIndex = 0

            while changedIndex < changed.count, unchangedIndex < unchanged.count {
                let changedRecordIndex = changed[changedIndex]
                let unchangedRecordIndex = unchanged[unchangedIndex]

                if modifiedDescendingPrecedes(changedRecordIndex, unchangedRecordIndex, records: records) {
                    merged.append(changedRecordIndex)
                    changedIndex += 1
                } else {
                    merged.append(unchangedRecordIndex)
                    unchangedIndex += 1
                }
            }

            if changedIndex < changed.count {
                merged.append(contentsOf: changed[changedIndex...])
            }

            if unchangedIndex < unchanged.count {
                merged.append(contentsOf: unchanged[unchangedIndex...])
            }

            return merged
        }

        private static func modifiedDescendingPrecedes(_ lhs: Int, _ rhs: Int, records: [FileRecord]) -> Bool {
            let left = records[lhs]
            let right = records[rhs]

            if left.modifiedTime != right.modifiedTime {
                return left.modifiedTime > right.modifiedTime
            }
            if left.normalizedName != right.normalizedName {
                return left.normalizedName < right.normalizedName
            }
            return left.path < right.path
        }

        private static func makeModifiedDescending(records: [FileRecord]) -> [Int] {
            records.indices.sorted {
                modifiedDescendingPrecedes($0, $1, records: records)
            }
        }

        private static func makePathGramIndex(records: [FileRecord]) -> [Int: [Int32]] {
            var index: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for (recordIndex, record) in records.enumerated() {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: record.normalizedPath, into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }

            return index
        }

        private static func makeDiagnostics(
            pathGramIndexEnabled: Bool,
            gramIndex: [Int: [Int32]],
            nameGramIndex: [Int: [Int32]],
            extensionIndex: [String: [Int32]]
        ) -> SearchStructureDiagnostics {
            SearchStructureDiagnostics(
                pathGramIndexEnabled: pathGramIndexEnabled,
                pathGramKeyCount: gramIndex.count,
                pathGramPostingCount: gramIndex.values.reduce(0) { $0 + $1.count },
                nameGramKeyCount: nameGramIndex.count,
                nameGramPostingCount: nameGramIndex.values.reduce(0) { $0 + $1.count },
                extensionKeyCount: extensionIndex.count,
                extensionPostingCount: extensionIndex.values.reduce(0) { $0 + $1.count }
            )
        }

        private static func makeNameGramIndex(records: [FileRecord]) -> [Int: [Int32]] {
            var index: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for (recordIndex, record) in records.enumerated() {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: record.normalizedName, into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }

            return index
        }

        private static func makeExtensionIndex(records: [FileRecord]) -> [String: [Int32]] {
            var index: [String: [Int32]] = [:]

            for (recordIndex, record) in records.enumerated() where !record.fileExtension.isEmpty {
                index[record.fileExtension, default: []].append(Int32(recordIndex))
            }

            return index
        }
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let supportDirectory: URL
    private let snapshotURL: URL
    private let legacySnapshotURL: URL
    private let indexQueue = DispatchQueue(label: "att.index.work", qos: .utility)
    private var recordsByPath: [String: FileRecord] = [:]
    private var searchSnapshot = SearchSnapshot.empty
    private var searchSnapshotRevision: UInt64 = 0
    private var roots: [String] = []
    private var exclusionRules: FileExclusionRules
    private var generation: UInt64 = 0
    private var persistRevision: UInt64 = 0
    private var pendingRefreshPaths = Set<String>()
    private var isRefreshDrainScheduled = false
    private var completedRefreshBatches: UInt64 = 0
    private var completedSnapshotRebuilds: UInt64 = 0
    private var activeIndexJobs = 0
    private var snapshotLoadState = SnapshotLoadState.notStarted
    private var indexing = false
    private var phase: IndexPhase = .idle
    private var discoveredCount = 0
    private var searchableCount = 0
    private var optimizedCount = 0
    private var status = "Starting"
    private var lastUpdated = Date()
    private var statsChangedHandler: (@MainActor @Sendable (IndexStats) -> Void)?

    public init(
        fileManager: FileManager = .default,
        applicationName: String = "AllTheThings",
        loadsSnapshotImmediately: Bool = true,
        exclusionPatterns: [String] = FileExclusionRules.defaultPatterns
    ) {
        self.fileManager = fileManager
        self.exclusionRules = FileExclusionRules(patterns: exclusionPatterns)

        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let supportDirectory = supportRoot.appendingPathComponent(applicationName, isDirectory: true)
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        self.supportDirectory = supportDirectory
        self.snapshotURL = supportDirectory.appendingPathComponent("filename-index-v2.jsonl", isDirectory: false)
        self.legacySnapshotURL = supportDirectory.appendingPathComponent("filename-index.json", isDirectory: false)
        cleanupStaleTemporaryFiles()

        if loadsSnapshotImmediately {
            if beginSnapshotLoad() {
                loadSnapshotAfterBegin(generationAtStart: currentGeneration())
            }
        } else {
            lock.withLock {
                phase = .idle
                status = "Waiting to load index"
                lastUpdated = Date()
            }
        }
    }

    public func currentStats() -> IndexStats {
        lockedStats()
    }

    public func allRoots() -> [URL] {
        lock.withLock {
            roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    public func allExclusionPatterns() -> [String] {
        lock.withLock {
            exclusionRules.patterns
        }
    }

    public func updateExclusionPatterns(_ patterns: [String]) {
        let rules = FileExclusionRules(patterns: patterns)
        lock.withLock {
            exclusionRules = rules
        }
    }

    public func replaceRootsAndRebuild(_ rootURLs: [URL]) {
        let canonicalRoots = canonicalizedRoots(rootURLs)
        let currentGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            snapshotLoadState = .finished
            roots = canonicalRoots.map(\.path)
            indexing = true
            phase = .scanning
            discoveredCount = 0
            searchableCount = 0
            optimizedCount = 0
            status = "Indexing \(canonicalRoots.count) scope\(canonicalRoots.count == 1 ? "" : "s")"
            lastUpdated = Date()
            return generation
        }

        publishStats()

        indexQueue.async { [weak self] in
            self?.rebuild(roots: canonicalRoots, generation: currentGeneration)
        }
    }

    @discardableResult
    public func loadSnapshotInBackground() -> Bool {
        guard beginSnapshotLoad() else { return false }
        let generationAtStart = currentGeneration()

        indexQueue.async { [weak self] in
            self?.loadSnapshotAfterBegin(generationAtStart: generationAtStart)
        }

        return true
    }

    public func refresh(paths rawPaths: [String]) {
        let paths = Set(rawPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard !paths.isEmpty else { return }

        let shouldSchedule = lock.withLock { () -> Bool in
            pendingRefreshPaths.formUnion(paths)
            guard !isRefreshDrainScheduled else {
                return false
            }
            isRefreshDrainScheduled = true
            return true
        }

        guard shouldSchedule else { return }

        indexQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.drainRefreshQueue()
        }
    }

    public func search(_ request: SearchRequest, maxResults: Int = 20_000) -> SearchResponse {
        search(request, maxResults: maxResults, shouldCancel: { false }) ?? SearchResponse(results: [], totalMatches: 0, elapsed: 0)
    }

    public func search(
        _ request: SearchRequest,
        maxResults: Int = 20_000,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        let started = Date()
        let snapshot = lock.withLock { searchSnapshot }
        let records = snapshot.records

        guard !shouldCancel() else { return nil }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = FuzzyMatcher.parse(trimmedQuery)
        let exactTextFastQuery = Self.exactTextFastQuery(from: parsedQuery)
        let boundedMaxResults = max(maxResults, 0)
        var matches: [SearchResult] = []
        matches.reserveCapacity(min(records.count, boundedMaxResults))
        let trimThreshold = boundedMaxResults > 0 ? boundedMaxResults * 5 : 0
        var total = 0

        func sortAndLimitMatches() {
            guard boundedMaxResults > 0 else { return }
            matches.sort {
                Self.compare($0, $1, sort: request.sort, queryIsEmpty: parsedQuery.isEmpty)
            }
            if matches.count > boundedMaxResults {
                matches.removeSubrange(boundedMaxResults..<matches.count)
            }
        }

        func trimMatches() {
            guard boundedMaxResults > 0, matches.count > boundedMaxResults else { return }
            sortAndLimitMatches()
        }

        func appendMatch(_ match: SearchResult) {
            guard request.includeHidden || !Self.recordIsHidden(match.record) else { return }
            total += 1
            guard boundedMaxResults > 0 else { return }
            matches.append(match)
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        if parsedQuery.isEmpty {
            let orderedRecords = snapshot.orderedIndices(for: request.sort, queryIsEmpty: true)
            for (offset, index) in (orderedRecords ?? Array(records.indices)).enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                let record = records[index]
                appendMatch(SearchResult(record: record, score: 0))
            }
        } else {
            if let exactTextFastQuery {
                if let indexedResponse = Self.indexedExactTextSearch(
                    snapshot: snapshot,
                    request: request,
                    query: exactTextFastQuery,
                    maxResults: boundedMaxResults,
                    started: started,
                    shouldCancel: shouldCancel
                ) {
                    return indexedResponse
                }

                if let orderedIndices = snapshot.orderedIndices(for: request.sort, queryIsEmpty: false) {
                    for (offset, index) in orderedIndices.enumerated() {
                        if offset.isMultiple(of: 512), shouldCancel() {
                            return nil
                        }
                        let record = records[index]
                        guard request.includeHidden || !Self.recordIsHidden(record) else { continue }
                        guard let score = Self.exactTextScore(record: record, query: exactTextFastQuery) else {
                            continue
                        }
                        total += 1
                        if matches.count < boundedMaxResults {
                            matches.append(SearchResult(record: record, score: score))
                        }
                    }

                    if total > 0 {
                        guard !shouldCancel() else { return nil }
                        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
                    }
                } else {
                    for (offset, record) in records.enumerated() {
                        if offset.isMultiple(of: 512), shouldCancel() {
                            return nil
                        }
                        if let score = Self.exactTextScore(record: record, query: exactTextFastQuery) {
                            appendMatch(SearchResult(record: record, score: score))
                        }
                    }

                    if total > 0 {
                        guard !shouldCancel() else { return nil }
                        sortAndLimitMatches()

                        guard !shouldCancel() else { return nil }
                        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
                    }
                }
            }

            if let indexedResponse = Self.indexedCandidateSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                shouldCancel: shouldCancel
            ) {
                return indexedResponse
            }

            for (offset, record) in records.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                if let score = FuzzyMatcher.score(record: record, parsedQuery: parsedQuery) {
                    appendMatch(SearchResult(record: record, score: score))
                }
            }
        }

        guard !shouldCancel() else { return nil }

        sortAndLimitMatches()

        guard !shouldCancel() else { return nil }

        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
    }

    private static func indexedCandidateSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard let candidateIndices = candidateIndices(snapshot: snapshot, parsedQuery: parsedQuery) else {
            return nil
        }

        if candidateIndices.isEmpty {
            return SearchResponse(results: [], totalMatches: 0, elapsed: Date().timeIntervalSince(started))
        }

        guard candidateIndices.count < snapshot.records.count else {
            return nil
        }

        var matches: [SearchResult] = []
        matches.reserveCapacity(min(candidateIndices.count, maxResults))
        let trimThreshold = maxResults > 0 ? maxResults * 5 : 0
        var total = 0

        func sortAndLimitMatches() {
            guard maxResults > 0 else { return }
            matches.sort {
                compare($0, $1, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        func trimMatches() {
            guard maxResults > 0, matches.count > maxResults else { return }
            sortAndLimitMatches()
        }

        for (offset, candidate) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let index = Int(candidate)
            guard index >= 0, index < snapshot.records.count else {
                continue
            }

            let record = snapshot.records[index]
            guard request.includeHidden || !recordIsHidden(record) else {
                continue
            }
            guard let score = FuzzyMatcher.score(record: record, parsedQuery: parsedQuery) else {
                continue
            }

            total += 1
            guard maxResults > 0 else {
                continue
            }

            matches.append(SearchResult(record: record, score: score))
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        guard !shouldCancel() else { return nil }
        return SearchResponse(results: matches, totalMatches: total, elapsed: Date().timeIntervalSince(started))
    }

    private static func indexedExactTextSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        query: ExactTextFastQuery,
        maxResults: Int,
        started: Date,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            let orderedIndices = snapshot.orderedIndices(for: request.sort, queryIsEmpty: false),
            query.clauses.count == 1,
            let clause = query.clauses.first,
            clause.alternatives.count == 1,
            let alternative = clause.alternatives.first,
            let candidateIndices = snapshot.candidateIndices(containing: alternative.tokenBytes, field: alternative.field),
            !candidateIndices.isEmpty
        else {
            return nil
        }

        var matches = CandidateBitSet(count: snapshot.records.count)
        var total = 0
        let candidateListIsExact = alternative.field == .any && alternative.tokenBytes.count <= 3

        for (offset, candidate) in candidateIndices.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let index = Int(candidate)
            guard index >= 0, index < snapshot.records.count else {
                continue
            }

            let record = snapshot.records[index]
            guard request.includeHidden || !recordIsHidden(record) else {
                continue
            }

            if !candidateListIsExact {
                guard exactTextScore(
                    record: record,
                    field: alternative.field,
                    token: alternative.token,
                    tokenBytes: alternative.tokenBytes
                ) != nil else {
                    continue
                }
            }

            total += 1
            matches.insert(index)
        }

        guard total > 0, !shouldCancel() else {
            return nil
        }

        var results: [SearchResult] = []
        results.reserveCapacity(min(maxResults, total))

        if maxResults > 0 {
            for (offset, index) in orderedIndices.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                guard matches.contains(index) else {
                    continue
                }
                results.append(SearchResult(record: snapshot.records[index], score: 0))
                if results.count >= maxResults {
                    break
                }
            }
        }

        guard !shouldCancel() else { return nil }
        return SearchResponse(results: results, totalMatches: total, elapsed: Date().timeIntervalSince(started))
    }

    private static func recordIsHidden(_ record: FileRecord) -> Bool {
        record.isHidden || FileRecord.pathIsHidden(record.path)
    }

    private static func candidateIndices(snapshot: SearchSnapshot, parsedQuery: FuzzyMatcher.ParsedQuery) -> [Int32]? {
        var candidates: [Int32]?
        var foundUsableClause = false

        for clause in parsedQuery.positive {
            guard let clauseCandidates = candidateIndices(snapshot: snapshot, clause: clause) else {
                continue
            }

            foundUsableClause = true
            guard !clauseCandidates.isEmpty else {
                return []
            }

            if let current = candidates {
                candidates = intersectPostingLists(current, clauseCandidates)
            } else {
                candidates = clauseCandidates
            }

            if candidates?.isEmpty == true {
                return []
            }
        }

        return foundUsableClause ? candidates : nil
    }

    private static func candidateIndices(snapshot: SearchSnapshot, clause: FuzzyMatcher.QueryClause) -> [Int32]? {
        var candidates: [Int32] = []
        var foundUsableAlternative = false

        for alternative in clause.alternatives {
            guard let alternativeCandidates = candidateIndices(snapshot: snapshot, part: alternative) else {
                return nil
            }

            foundUsableAlternative = true
            candidates = unionPostingLists(candidates, alternativeCandidates)
        }

        return foundUsableAlternative ? candidates : nil
    }

    private static func candidateIndices(snapshot: SearchSnapshot, part: FuzzyMatcher.QueryPart) -> [Int32]? {
        switch part {
        case .kind:
            return nil
        case .fileExtension(let pattern, let mode):
            return snapshot.candidateIndices(fileExtension: pattern.token, mode: mode)
                ?? candidateIndices(snapshot: snapshot, token: pattern.token, mode: mode, allowsFuzzyPrefix: true)
        case .text(let field, let pattern, let mode):
            return candidateIndices(snapshot: snapshot, field: field, token: pattern.token, mode: mode)
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        field: FuzzyMatcher.QueryField,
        token: String,
        mode: FuzzyMatcher.MatchMode
    ) -> [Int32]? {
        switch mode {
        case .exact:
            return snapshot.candidateIndices(containing: Array(token.utf8), field: field)
        case .wildcard:
            return candidateIndices(snapshot: snapshot, requiredFragments: wildcardRequiredFragments(from: token), field: field)
        case .fuzzy:
            if tokenContainsPathSeparator(token) {
                guard field != .name else {
                    return nil
                }
                return candidateIndices(snapshot: snapshot, requiredFragments: pathLiteralFragments(from: token), field: .path)
            }

            return fuzzyTextCandidateIndices(snapshot: snapshot, field: field, token: token)
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        allowsFuzzyPrefix: Bool
    ) -> [Int32]? {
        switch mode {
        case .exact:
            return snapshot.candidatePathIndices(containing: Array(token.utf8))
        case .wildcard:
            return candidateIndices(snapshot: snapshot, requiredFragments: wildcardRequiredFragments(from: token), field: .path)
        case .fuzzy:
            guard allowsFuzzyPrefix else {
                return nil
            }
            return snapshot.candidatePathIndices(containing: Array(token.utf8))
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        requiredFragments fragments: [[UInt8]],
        field: FuzzyMatcher.QueryField
    ) -> [Int32]? {
        guard !fragments.isEmpty else {
            return nil
        }

        var candidates: [Int32]?

        for fragment in fragments {
            guard let fragmentCandidates = snapshot.candidateIndices(containing: fragment, field: field) else {
                return nil
            }

            guard !fragmentCandidates.isEmpty else {
                return []
            }

            if let current = candidates {
                candidates = intersectPostingLists(current, fragmentCandidates)
            } else {
                candidates = fragmentCandidates
            }

            if candidates?.isEmpty == true {
                return []
            }
        }

        return candidates
    }

    private static func wildcardRequiredFragments(from pattern: String) -> [[UInt8]] {
        var fragments: [[UInt8]] = []
        var current: [UInt8] = []

        for byte in pattern.utf8 {
            if byte == 42 || byte == 47 || byte == 63 || byte == 92 {
                if !current.isEmpty {
                    fragments.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }

        if !current.isEmpty {
            fragments.append(current)
        }

        return fragments
    }

    private static func pathLiteralFragments(from token: String) -> [[UInt8]] {
        token.split { $0 == "/" || $0 == "\\" }
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { Array($0.utf8) }
    }

    private static func fuzzyTextCandidateIndices(
        snapshot: SearchSnapshot,
        field: FuzzyMatcher.QueryField,
        token: String
    ) -> [Int32]? {
        guard token.utf8.allSatisfy({ $0 < 128 }) else {
            return nil
        }

        let tokenBytes = Array(token.utf8)
        let nameCandidates = fuzzyNameCandidateIndices(snapshot: snapshot, tokenBytes: tokenBytes)

        switch field {
        case .name:
            return nameCandidates
        case .path:
            return snapshot.candidatePathIndices(containing: tokenBytes)
        case .any:
            let pathCandidates = snapshot.candidatePathIndices(containing: tokenBytes)
            switch (nameCandidates, pathCandidates) {
            case (.some(let name), .some(let path)):
                return unionPostingLists(path, name)
            case (.some(let name), .none):
                return name
            case (.none, .some(let path)):
                return path
            case (.none, .none):
                return nil
            }
        }
    }

    private static func fuzzyNameCandidateIndices(snapshot: SearchSnapshot, tokenBytes: [UInt8]) -> [Int32]? {
        guard tokenBytes.count >= 4, tokenBytes.count <= 12 else {
            return nil
        }

        var seen = Set<UInt8>()
        var distinctBytes: [UInt8] = []
        distinctBytes.reserveCapacity(tokenBytes.count)

        for byte in tokenBytes where seen.insert(byte).inserted {
            distinctBytes.append(byte)
        }

        guard distinctBytes.count == tokenBytes.count else {
            return nil
        }

        let allowedMissing = tokenBytes.count <= 5 ? 1 : 2
        let requiredCount = distinctBytes.count - allowedMissing
        guard requiredCount >= 3 else {
            return nil
        }

        let requiredSubsets = byteSubsets(distinctBytes, count: requiredCount)
        guard !requiredSubsets.isEmpty else {
            return nil
        }

        return snapshot.candidateNameIndices(containingAny: requiredSubsets)
    }

    private static func byteSubsets(_ bytes: [UInt8], count: Int) -> [[UInt8]] {
        guard count > 0, count <= bytes.count else {
            return []
        }

        var subsets: [[UInt8]] = []
        var current: [UInt8] = []
        current.reserveCapacity(count)

        func appendSubsets(start: Int) {
            if current.count == count {
                subsets.append(current)
                return
            }

            let remainingSlots = count - current.count
            guard bytes.count - start >= remainingSlots else {
                return
            }

            let lastStart = bytes.count - remainingSlots
            for index in start...lastStart {
                current.append(bytes[index])
                appendSubsets(start: index + 1)
                current.removeLast()
            }
        }

        appendSubsets(start: 0)
        return subsets
    }

    private static func tokenContainsPathSeparator(_ token: String) -> Bool {
        token.contains("/") || token.contains("\\")
    }

    private static func exactTextFastQuery(from parsedQuery: FuzzyMatcher.ParsedQuery) -> ExactTextFastQuery? {
        guard parsedQuery.negative.isEmpty, !parsedQuery.positive.isEmpty else {
            return nil
        }

        var clauses: [ExactTextFastClause] = []
        clauses.reserveCapacity(parsedQuery.positive.count)

        for clause in parsedQuery.positive {
            var alternatives: [ExactTextFastAlternative] = []
            alternatives.reserveCapacity(clause.alternatives.count)

            for alternative in clause.alternatives {
                switch alternative {
                case .text(let field, let pattern, .fuzzy):
                    guard !pattern.token.isEmpty, !tokenContainsPathSeparator(pattern.token) else { return nil }
                    alternatives.append(ExactTextFastAlternative(
                        field: field,
                        token: pattern.token,
                        tokenBytes: Array(pattern.token.utf8)
                    ))
                case .text, .fileExtension, .kind:
                    return nil
                }
            }

            guard !alternatives.isEmpty else {
                return nil
            }
            clauses.append(ExactTextFastClause(alternatives: alternatives))
        }

        return ExactTextFastQuery(clauses: clauses)
    }

    private static func exactTextScore(record: FileRecord, query: ExactTextFastQuery) -> Int? {
        var total = 0

        for clause in query.clauses {
            var best: Int?

            for alternative in clause.alternatives {
                guard let score = exactTextScore(
                    record: record,
                    field: alternative.field,
                    token: alternative.token,
                    tokenBytes: alternative.tokenBytes
                ) else {
                    continue
                }
                best = max(best ?? Int.min, score)
            }

            guard let best else {
                return nil
            }
            total += best
        }

        let depthPenalty = pathDepthPenalty(record.normalizedPath)
        let hiddenPenalty = record.isHidden ? 35 : 0
        return total - depthPenalty - hiddenPenalty
    }

    private static func exactTextScore(record: FileRecord, field: FuzzyMatcher.QueryField, token: String, tokenBytes: [UInt8]) -> Int? {
        switch field {
        case .any:
            let nameScore = exactNameScore(record.normalizedName, tokenBytes: tokenBytes)
            let pathScore = exactPathScore(record.normalizedPath, tokenBytes: tokenBytes, base: 3_600)
            switch (nameScore, pathScore) {
            case (.some(let name), .some(let path)):
                return max(name, path)
            case (.some(let name), .none):
                return name
            case (.none, .some(let path)):
                return path
            case (.none, .none):
                return nil
            }
        case .name:
            return exactNameScore(record.normalizedName, tokenBytes: tokenBytes)
        case .path:
            return exactPathScore(record.normalizedPath, tokenBytes: tokenBytes, base: 4_000)
        }
    }

    private static func exactNameScore(_ text: String, tokenBytes: [UInt8]) -> Int? {
        guard let match = firstUTF8Match(in: text, token: tokenBytes) else {
            return nil
        }

        if match.offset == 0, match.textByteCount == tokenBytes.count {
            return 10_000
        }

        if match.offset == 0 {
            return 9_200 - min(match.textByteCount, 300)
        }

        let boundaryBonus = match.isBoundary ? 650 : 0
        return 7_700 + boundaryBonus - min(match.offset * 12, 900)
    }

    private static func exactPathScore(_ text: String, tokenBytes: [UInt8], base: Int) -> Int? {
        guard let match = firstUTF8Match(in: text, token: tokenBytes) else {
            return nil
        }

        let boundaryBonus = match.isBoundary ? 500 : 0
        return base + boundaryBonus - min(match.offset * 10, 900)
    }

    private static func collectSearchGramKeys(from text: String, into keys: inout Set<Int>) {
        guard !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }

        let maximumLength = min(3, bytes.count)
        for length in 1...maximumLength {
            let lastStart = bytes.count - length
            for start in 0...lastStart {
                keys.insert(searchGramKey(bytes: bytes, start: start, length: length))
            }
        }
    }

    private static func searchGramKeys(for tokenBytes: [UInt8]) -> [Int] {
        guard !tokenBytes.isEmpty else { return [] }

        if tokenBytes.count <= 3 {
            return [searchGramKey(bytes: tokenBytes, start: 0, length: tokenBytes.count)]
        }

        var keys = Set<Int>()
        let lastStart = tokenBytes.count - 3
        for start in 0...lastStart {
            keys.insert(searchGramKey(bytes: tokenBytes, start: start, length: 3))
        }
        return Array(keys)
    }

    private static func searchGramKey(bytes: [UInt8], start: Int, length: Int) -> Int {
        var key = length << 24
        for offset in 0..<length {
            key |= Int(bytes[start + offset]) << ((2 - offset) * 8)
        }
        return key
    }

    private static func intersectPostingLists(_ postings: [[Int32]]) -> [Int32] {
        guard var result = postings.first else {
            return []
        }

        for posting in postings.dropFirst() {
            if result.isEmpty {
                break
            }
            result = intersectPostingLists(result, posting)
        }

        return result
    }

    private static func intersectPostingLists(_ lhs: [Int32], _ rhs: [Int32]) -> [Int32] {
        var result: [Int32] = []
        result.reserveCapacity(min(lhs.count, rhs.count))

        var leftIndex = 0
        var rightIndex = 0

        while leftIndex < lhs.count, rightIndex < rhs.count {
            let left = lhs[leftIndex]
            let right = rhs[rightIndex]

            if left == right {
                result.append(left)
                leftIndex += 1
                rightIndex += 1
            } else if left < right {
                leftIndex += 1
            } else {
                rightIndex += 1
            }
        }

        return result
    }

    private static func unionPostingLists(_ lhs: [Int32], _ rhs: [Int32]) -> [Int32] {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        var result: [Int32] = []
        result.reserveCapacity(lhs.count + rhs.count)

        var leftIndex = 0
        var rightIndex = 0

        while leftIndex < lhs.count, rightIndex < rhs.count {
            let left = lhs[leftIndex]
            let right = rhs[rightIndex]

            if left == right {
                result.append(left)
                leftIndex += 1
                rightIndex += 1
            } else if left < right {
                result.append(left)
                leftIndex += 1
            } else {
                result.append(right)
                rightIndex += 1
            }
        }

        if leftIndex < lhs.count {
            result.append(contentsOf: lhs[leftIndex...])
        }

        if rightIndex < rhs.count {
            result.append(contentsOf: rhs[rightIndex...])
        }

        return result
    }

    private static func wildcardMatches(_ text: String, pattern: String) -> Bool {
        let textBytes = Array(text.utf8)
        let patternBytes = Array(pattern.utf8)
        guard !patternBytes.isEmpty else { return false }

        var previous = Array(repeating: false, count: textBytes.count + 1)
        previous[0] = true

        for patternByte in patternBytes {
            var current = Array(repeating: false, count: textBytes.count + 1)

            if patternByte == 42 {
                current[0] = previous[0]
                if !textBytes.isEmpty {
                    for index in 1...textBytes.count {
                        current[index] = previous[index] || current[index - 1]
                    }
                }
            } else if !textBytes.isEmpty {
                for index in 1...textBytes.count {
                    current[index] = previous[index - 1] && (patternByte == 63 || patternByte == textBytes[index - 1])
                }
            }

            previous = current
        }

        return previous[textBytes.count]
    }

    private static func firstUTF8Match(in text: String, token: [UInt8]) -> UTF8Match? {
        guard !token.isEmpty else { return nil }

        if let match = text.utf8.withContiguousStorageIfAvailable({ haystack -> UTF8Match? in
            firstUTF8Match(in: haystack, token: token)
        }) {
            return match
        }

        return firstUTF8Match(in: Array(text.utf8), token: token)
    }

    private static func firstUTF8Match(in haystack: UnsafeBufferPointer<UInt8>, token: [UInt8]) -> UTF8Match? {
        guard token.count <= haystack.count else { return nil }

        let first = token[0]
        let lastStart = haystack.count - token.count
        var index = 0

        while index <= lastStart {
            if haystack[index] == first {
                var tokenIndex = 1
                while tokenIndex < token.count, haystack[index + tokenIndex] == token[tokenIndex] {
                    tokenIndex += 1
                }

                if tokenIndex == token.count {
                    return UTF8Match(
                        offset: index,
                        isBoundary: index == 0 || isBoundaryByte(haystack[index - 1]),
                        textByteCount: haystack.count
                    )
                }
            }

            index += 1
        }

        return nil
    }

    private static func firstUTF8Match(in haystack: ArraySlice<UInt8>, token: [UInt8]) -> UTF8Match? {
        firstUTF8Match(in: Array(haystack), token: token)
    }

    private static func firstUTF8Match(in haystack: [UInt8], token: [UInt8]) -> UTF8Match? {
        guard token.count <= haystack.count else { return nil }

        let first = token[0]
        let lastStart = haystack.count - token.count
        var index = 0

        while index <= lastStart {
            if haystack[index] == first {
                var tokenIndex = 1
                while tokenIndex < token.count, haystack[index + tokenIndex] == token[tokenIndex] {
                    tokenIndex += 1
                }

                if tokenIndex == token.count {
                    return UTF8Match(
                        offset: index,
                        isBoundary: index == 0 || isBoundaryByte(haystack[index - 1]),
                        textByteCount: haystack.count
                    )
                }
            }

            index += 1
        }

        return nil
    }

    private static func pathDepthPenalty(_ path: String) -> Int {
        var slashCount = 0
        for byte in path.utf8 where byte == 47 {
            slashCount += 1
            if slashCount >= 30 {
                return 120
            }
        }
        return min(slashCount * 4, 120)
    }

    private static func isBoundaryByte(_ byte: UInt8) -> Bool {
        byte == 47 || byte == 45 || byte == 95 || byte == 46 || byte == 32
    }

    public func deleteSnapshot() {
        lock.withLock {
            recordsByPath.removeAll(keepingCapacity: true)
            searchSnapshot = .empty
            searchSnapshotRevision &+= 1
            status = "Index deleted"
            indexing = false
            phase = .idle
            discoveredCount = 0
            searchableCount = 0
            optimizedCount = 0
            lastUpdated = Date()
            persistRevision &+= 1
        }
        try? fileManager.removeItem(at: snapshotURL)
        try? fileManager.removeItem(at: legacySnapshotURL)
        cleanupStaleTemporaryFiles()
        publishStats()
    }

    private func beginSnapshotLoad() -> Bool {
        let didBegin = lock.withLock { () -> Bool in
            guard snapshotLoadState == .notStarted else {
                return false
            }

            snapshotLoadState = .loading
            phase = .loading
            status = "Loading saved index"
            lastUpdated = Date()
            return true
        }

        if didBegin {
            publishStats()
        }

        return didBegin
    }

    private func loadSnapshotAfterBegin(generationAtStart: UInt64) {
        let jobID = beginIndexJob("loadSnapshot")
        defer { endIndexJob("loadSnapshot", jobID: jobID) }

        MemoryTelemetry.log("snapshot.load.begin", activeIndexJobs: currentActiveIndexJobCount())

        guard let persisted = loadPersistedSnapshot() else {
            let didUpdate = lock.withLock { () -> Bool in
                guard generation == generationAtStart else {
                    return false
                }

                snapshotLoadState = .finished
                phase = .idle
                status = "No index yet"
                indexing = false
                discoveredCount = 0
                searchableCount = 0
                optimizedCount = 0
                lastUpdated = Date()
                return true
            }

            if didUpdate {
                publishStats()
            }
            return
        }

        let metrics = Self.metrics(for: persisted.records)
        let records = Dictionary(uniqueKeysWithValues: persisted.records.map { ($0.path, $0) })
        let snapshot = SearchSnapshot(records: Array(records.values))
        MemoryTelemetry.log(
            "snapshot.load.decoded",
            records: metrics,
            structures: snapshot.diagnostics,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        let didApply = lock.withLock { () -> Bool in
            guard generation == generationAtStart else {
                return false
            }

            guard (persisted.exclusionPatterns ?? FileExclusionRules.defaultPatterns) == exclusionRules.patterns else {
                snapshotLoadState = .finished
                phase = .idle
                status = "Index settings changed"
                indexing = false
                discoveredCount = 0
                searchableCount = 0
                optimizedCount = 0
                lastUpdated = Date()
                return true
            }

            recordsByPath = records
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            roots = persisted.roots ?? []
            snapshotLoadState = .finished
            phase = .ready
            status = "Loaded \(records.count) indexed files"
            indexing = false
            discoveredCount = records.count
            searchableCount = snapshot.records.count
            optimizedCount = snapshot.records.count
            lastUpdated = persisted.savedAt
            return true
        }

        if didApply {
            publishStats()
            if !fileManager.fileExists(atPath: snapshotURL.path), fileManager.fileExists(atPath: legacySnapshotURL.path) {
                schedulePersist()
            }
            MemoryTelemetry.log(
                "snapshot.load.applied",
                records: metrics,
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
        }
    }

    private func rebuild(roots rootURLs: [URL], generation currentGeneration: UInt64) {
        let jobID = beginIndexJob("rebuild")
        defer { endIndexJob("rebuild", jobID: jobID) }

        let exclusions = lock.withLock { exclusionRules }
        let publishPrimary: @Sendable (_ records: [String: FileRecord], _ visited: Int, _ force: Bool) -> Void = { [weak self] records, visited, _ in
            self?.publishPrimarySnapshot(records, visited: visited, generation: currentGeneration)
        }

        MemoryTelemetry.log("rebuild.scan.begin", activeIndexJobs: currentActiveIndexJobCount())

        guard let scanResult = scanConcurrently(
            roots: rootURLs,
            exclusions: exclusions,
            generation: currentGeneration,
            progress: publishPrimary
        ) else {
            return
        }

        guard isCurrentGeneration(currentGeneration) else { return }
        publishPrimary(scanResult.records, scanResult.visited, true)
        optimizeAndPublish(recordsByPath: scanResult.records, generation: currentGeneration)
    }

    private func scanConcurrently(
        roots rootURLs: [URL],
        exclusions: FileExclusionRules,
        generation currentGeneration: UInt64,
        progress: @escaping @Sendable (_ records: [String: FileRecord], _ visited: Int, _ force: Bool) -> Void
    ) -> ScanResult? {
        let rootPaths = rootURLs.map(\.path)
        let currentCount = lock.withLock { recordsByPath.count }
        let state = ConcurrentScanState(reservedCapacity: max(8_192, currentCount))

        let publish: @Sendable (_ result: ScanResult?, _ force: Bool) -> Void = { result, force in
            guard let result else { return }
            progress(result.records, result.visited, force)
        }

        for root in rootURLs {
            guard fileManager.fileExists(atPath: root.path), !shouldExclude(root, exclusions: exclusions, rootPaths: rootPaths, isDirectory: true) else {
                continue
            }
            if let rootRecord = FileRecord(url: root) {
                state.addInitialRecord(rootRecord)
            }
            state.enqueue(root)
        }

        let workerCount = Self.scanWorkerCount()
        let workers = DispatchGroup()
        let workerQueue = DispatchQueue.global(qos: .utility)

        for _ in 0..<workerCount {
            workers.enter()
            workerQueue.async { [weak self] in
                defer { workers.leave() }
                guard let self else {
                    state.markStopped()
                    return
                }

                var batch: [FileRecord] = []
                batch.reserveCapacity(256)

                while true {
                    guard let directory = state.nextDirectory() else { break }
                    guard self.isCurrentGeneration(currentGeneration) else {
                        state.finishDirectory()
                        state.markStopped()
                        break
                    }

                    let children = (try? self.fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(FileRecord.resourceKeys),
                        options: []
                    )) ?? []

                    for child in children {
                        if !self.isCurrentGeneration(currentGeneration) {
                            state.markStopped()
                            break
                        }

                        autoreleasepool {
                            let values = try? child.resourceValues(forKeys: FileRecord.resourceKeys)
                            guard !self.shouldExclude(child, exclusions: exclusions, rootPaths: rootPaths, isDirectory: values?.isDirectory) else {
                                return
                            }

                            let isDirectory = values?.isDirectory == true
                            guard !(isDirectory && self.isLikelyLoop(child)) else {
                                return
                            }

                            if let record = FileRecord(url: child, resourceValues: values) {
                                batch.append(record)
                            }

                            if isDirectory {
                                state.enqueue(child)
                            }
                        }

                        if batch.count >= 256 {
                            state.append(batch)
                            batch.removeAll(keepingCapacity: true)
                            publish(state.publishSnapshotIfNeeded(force: false), false)
                        }
                    }

                    if !batch.isEmpty {
                        state.append(batch)
                        batch.removeAll(keepingCapacity: true)
                        publish(state.publishSnapshotIfNeeded(force: false), false)
                    }

                    state.finishDirectory()
                }
            }
        }

        workers.wait()
        publish(state.publishSnapshotIfNeeded(force: true), true)

        let (result, wasStopped) = state.result()
        return wasStopped && !isCurrentGeneration(currentGeneration) ? nil : result
    }

    private func publishPrimarySnapshot(_ records: [String: FileRecord], visited: Int, generation currentGeneration: UInt64) {
        let snapshot = SearchSnapshot(records: Array(records.values), buildsSearchStructures: false)
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            recordsByPath = records
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = true
            phase = .scanning
            discoveredCount = visited
            searchableCount = snapshot.records.count
            optimizedCount = 0
            status = "Indexing \(visited.formatted()) discovered"
            lastUpdated = Date()
            return true
        }

        guard didApply else { return }
        publishStats()

        if snapshot.records.count.isMultiple(of: Self.primaryPublishRecordInterval) {
            MemoryTelemetry.log(
                "rebuild.primary.applied",
                records: Self.metrics(for: snapshot.records),
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
        }
    }

    private func optimizeAndPublish(recordsByPath: [String: FileRecord], generation currentGeneration: UInt64) {
        let records = Array(recordsByPath.values)
        var snapshot = SearchSnapshot(records: records, buildsSearchStructures: false)

        guard isCurrentGeneration(currentGeneration) else { return }
        publishRebuildStatus(
            phase: .optimizing,
            status: "Optimizing names",
            discovered: records.count,
            searchable: records.count,
            optimized: 0,
            isIndexing: true,
            generation: currentGeneration
        )

        snapshot = snapshot.addingNameGramIndex()
        publishOptimizedSnapshot(
            snapshot,
            status: "Optimizing extensions",
            optimized: 0,
            generation: currentGeneration
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        snapshot = snapshot.addingExtensionIndex()
        publishOptimizedSnapshot(
            snapshot,
            status: "Optimizing modified sort",
            optimized: 0,
            generation: currentGeneration
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        snapshot = snapshot.addingModifiedSortOrder()
        publishOptimizedSnapshot(
            snapshot,
            status: "Optimizing paths",
            optimized: 0,
            generation: currentGeneration
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        snapshot = snapshot.addingPathGramIndexIfBudgetAllows()
        publishOptimizedSnapshot(
            snapshot,
            status: "Saving index",
            optimized: snapshot.records.count,
            generation: currentGeneration
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        publishRebuildStatus(
            phase: .saving,
            status: "Saving index",
            discovered: records.count,
            searchable: snapshot.records.count,
            optimized: snapshot.records.count,
            isIndexing: true,
            generation: currentGeneration
        )
        guard persistSnapshot() else { return }

        let didFinish = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            indexing = false
            phase = .ready
            discoveredCount = records.count
            searchableCount = snapshot.records.count
            optimizedCount = snapshot.records.count
            status = "Indexed \(records.count.formatted()) files"
            lastUpdated = Date()
            completedSnapshotRebuilds &+= 1
            return true
        }

        if didFinish {
            publishStats()
            MemoryTelemetry.log(
                "rebuild.optimized.applied",
                records: Self.metrics(for: snapshot.records),
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
        }
    }

    private func publishOptimizedSnapshot(
        _ snapshot: SearchSnapshot,
        status: String,
        optimized: Int,
        generation currentGeneration: UInt64
    ) {
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = true
            phase = .optimizing
            discoveredCount = snapshot.records.count
            searchableCount = snapshot.records.count
            optimizedCount = optimized
            self.status = status
            lastUpdated = Date()
            return true
        }

        if didApply {
            publishStats()
        }
    }

    private func publishRebuildStatus(
        phase: IndexPhase,
        status: String,
        discovered: Int,
        searchable: Int,
        optimized: Int,
        isIndexing: Bool,
        generation currentGeneration: UInt64
    ) {
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            indexing = isIndexing
            self.phase = phase
            discoveredCount = discovered
            searchableCount = searchable
            optimizedCount = optimized
            self.status = status
            lastUpdated = Date()
            return true
        }

        if didApply {
            publishStats()
        }
    }

    private static func scanWorkerCount() -> Int {
        if
            let rawValue = ProcessInfo.processInfo.environment["ATT_INDEX_SCAN_WORKERS"],
            let requested = Int(rawValue),
            requested > 0
        {
            return min(max(requested, 1), 64)
        }

        return min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    }

    private func drainRefreshQueue() {
        let paths = lock.withLock { () -> [String] in
            let batch = Array(pendingRefreshPaths.prefix(Self.maximumRefreshBatchPaths))
            for path in batch {
                pendingRefreshPaths.remove(path)
            }
            if pendingRefreshPaths.isEmpty {
                pendingRefreshPaths.removeAll(keepingCapacity: false)
                isRefreshDrainScheduled = false
            }
            return batch
        }

        if !paths.isEmpty {
            refreshNow(paths: paths)
        }

        let shouldContinue = lock.withLock { !pendingRefreshPaths.isEmpty }
        if shouldContinue {
            indexQueue.async { [weak self] in
                self?.drainRefreshQueue()
            }
        }
    }

    private func refreshNow(paths: [String]) {
        let jobID = beginIndexJob("refresh")
        defer { endIndexJob("refresh", jobID: jobID) }

        MemoryTelemetry.log(
            "refresh.begin",
            refreshBatchSize: paths.count,
            activeIndexJobs: currentActiveIndexJobCount()
        )

        let indexState = lock.withLock {
            (
                exclusions: exclusionRules,
                rootPaths: roots
            )
        }
        var upserts: [String: FileRecord] = [:]
        var deletedPrefixes: [String] = []
        var shallowDirectoryChildren: [String: Set<String>] = [:]

        for path in paths {
            autoreleasepool {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard !shouldExclude(url, exclusions: indexState.exclusions, rootPaths: indexState.rootPaths) else { return }

                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    guard !shouldExclude(url, exclusions: indexState.exclusions, rootPaths: indexState.rootPaths, isDirectory: isDirectory.boolValue) else { return }

                    if let record = FileRecord(url: url) {
                        upserts[record.path] = record
                    }

                    if isDirectory.boolValue {
                        let children = scanDirectoryShallow(url, exclusions: indexState.exclusions, rootPaths: indexState.rootPaths)
                        shallowDirectoryChildren[url.path] = Set(children.map(\.path))
                        for record in children {
                            upserts[record.path] = record
                        }
                    }
                } else {
                    deletedPrefixes.append(url.path)
                }
            }
        }

        guard !upserts.isEmpty || !deletedPrefixes.isEmpty || !shallowDirectoryChildren.isEmpty else {
            MemoryTelemetry.log(
                "refresh.noop",
                refreshBatchSize: paths.count,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            return
        }

        var fastSnapshot: SearchSnapshot?
        var snapshotRecords: [FileRecord] = []
        var snapshotRevision: UInt64 = 0
        let canUseFastMetadataUpdate = deletedPrefixes.isEmpty && shallowDirectoryChildren.isEmpty

        lock.withLock {
            let previousSnapshot = searchSnapshot

            for prefix in deletedPrefixes {
                var pathsToRemove: [String] = []
                pathsToRemove.reserveCapacity(16)
                for path in recordsByPath.keys where path == prefix || path.hasPrefix(prefix + "/") {
                    pathsToRemove.append(path)
                }
                for path in pathsToRemove {
                    recordsByPath.removeValue(forKey: path)
                }
            }

            for (directory, currentChildren) in shallowDirectoryChildren {
                var pathsToRemove: [String] = []
                pathsToRemove.reserveCapacity(16)
                for (path, record) in recordsByPath where record.directoryPath == directory && !currentChildren.contains(record.path) {
                    pathsToRemove.append(path)
                }
                for path in pathsToRemove {
                    recordsByPath.removeValue(forKey: path)
                }
            }

            for (path, record) in upserts {
                recordsByPath[path] = record
            }

            searchSnapshotRevision &+= 1
            snapshotRevision = searchSnapshotRevision
            status = "Updated \(upserts.count + deletedPrefixes.count) changed path\(upserts.count + deletedPrefixes.count == 1 ? "" : "s")"
            phase = .ready
            indexing = false
            discoveredCount = recordsByPath.count
            lastUpdated = Date()

            if canUseFastMetadataUpdate {
                fastSnapshot = previousSnapshot.updatingMetadata(for: upserts)
            }

            if fastSnapshot == nil {
                snapshotRecords = Array(recordsByPath.values)
            }

            completedRefreshBatches &+= 1
        }

        if let fastSnapshot {
            lock.withLock {
                if searchSnapshotRevision == snapshotRevision {
                    searchSnapshot = fastSnapshot
                    searchableCount = fastSnapshot.records.count
                    optimizedCount = fastSnapshot.records.count
                }
            }
            publishStats()
            schedulePersist()
            MemoryTelemetry.log(
                "refresh.fastMetadataUpdate",
                records: Self.metrics(for: fastSnapshot.records),
                structures: fastSnapshot.diagnostics,
                refreshBatchSize: paths.count,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            return
        }

        let snapshot = SearchSnapshot(records: snapshotRecords)
        lock.withLock {
            if searchSnapshotRevision == snapshotRevision {
                searchSnapshot = snapshot
                searchableCount = snapshot.records.count
                optimizedCount = snapshot.records.count
                completedSnapshotRebuilds &+= 1
            }
        }

        publishStats()
        schedulePersist()
        MemoryTelemetry.log(
            "refresh.snapshotRebuilt",
            records: Self.metrics(for: snapshot.records),
            structures: snapshot.diagnostics,
            refreshBatchSize: paths.count,
            activeIndexJobs: currentActiveIndexJobCount()
        )
    }

    private func scanDirectoryShallow(_ directory: URL, exclusions: FileExclusionRules, rootPaths: [String]) -> [FileRecord] {
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(FileRecord.resourceKeys),
                options: []
            )
        else {
            return []
        }

        return children.compactMap { child in
            autoreleasepool {
                let values = try? child.resourceValues(forKeys: FileRecord.resourceKeys)
                guard !shouldExclude(child, exclusions: exclusions, rootPaths: rootPaths, isDirectory: values?.isDirectory) else { return nil }
                return FileRecord(url: child, resourceValues: values)
            }
        }
    }

    private func updateIndexingProgress(status: String, indexedCount: Int) {
        lock.withLock {
            indexing = true
            self.status = "\(status) discovered"
            lastUpdated = Date()
        }
        publishStats()

        if indexedCount.isMultiple(of: 25_000) {
            MemoryTelemetry.log(
                "rebuild.progress",
                records: RecordCollectionMetrics(recordCount: indexedCount, totalPathBytes: 0, maxPathBytes: 0),
                activeIndexJobs: currentActiveIndexJobCount()
            )
        }
    }

    private func replaceRecords(_ records: [String: FileRecord], isIndexing: Bool, status: String) {
        MemoryTelemetry.log(
            isIndexing ? "snapshot.partial.begin" : "snapshot.final.begin",
            records: Self.metrics(for: records.values),
            activeIndexJobs: currentActiveIndexJobCount()
        )

        let snapshot = SearchSnapshot(records: Array(records.values), buildsSearchStructures: !isIndexing)
        lock.withLock {
            recordsByPath = records
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = isIndexing
            phase = isIndexing ? .scanning : .ready
            discoveredCount = snapshot.records.count
            searchableCount = snapshot.records.count
            optimizedCount = isIndexing ? 0 : snapshot.records.count
            self.status = status
            lastUpdated = Date()
            if !isIndexing {
                completedSnapshotRebuilds &+= 1
            }
        }
        publishStats()

        MemoryTelemetry.log(
            isIndexing ? "snapshot.partial.applied" : "snapshot.final.applied",
            records: Self.metrics(for: snapshot.records),
            structures: snapshot.diagnostics,
            activeIndexJobs: currentActiveIndexJobCount()
        )
    }

    private func schedulePersist() {
        let revision = lock.withLock { () -> UInt64 in
            persistRevision &+= 1
            return persistRevision
        }

        indexQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isPersistRevisionCurrent(revision) else { return }
            self.persistSnapshot()
        }
    }

    @discardableResult
    private func persistSnapshot() -> Bool {
        let snapshotData = lock.withLock {
            (
                roots: roots,
                exclusionPatterns: exclusionRules.patterns,
                records: searchSnapshot.records
            )
        }

        let jobID = beginIndexJob("persist")
        defer { endIndexJob("persist", jobID: jobID) }

        let metrics = Self.metrics(for: snapshotData.records)
        MemoryTelemetry.log(
            "snapshot.persist.begin",
            records: metrics,
            structures: lock.withLock { searchSnapshot.diagnostics },
            activeIndexJobs: currentActiveIndexJobCount()
        )

        do {
            try persistStreamingSnapshot(
                roots: snapshotData.roots,
                exclusionPatterns: snapshotData.exclusionPatterns,
                records: snapshotData.records
            )
            MemoryTelemetry.log(
                "snapshot.persist.finished",
                records: metrics,
                structures: lock.withLock { searchSnapshot.diagnostics },
                activeIndexJobs: currentActiveIndexJobCount()
            )
            return true
        } catch {
            lock.withLock {
                phase = .failed
                indexing = false
                status = "Could not persist index: \(error.localizedDescription)"
                lastUpdated = Date()
            }
            publishStats()
            return false
        }
    }

    private func persistStreamingSnapshot(roots: [String], exclusionPatterns: [String], records: [FileRecord]) throws {
        cleanupStaleTemporaryFiles()
        let encoder = JSONEncoder()
        let temporaryURL = supportDirectory.appendingPathComponent("filename-index-v2-\(UUID().uuidString).jsonl.tmp", isDirectory: false)

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        var didClose = false
        defer {
            if !didClose {
                try? handle.close()
            }
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let header = PersistedSnapshotHeader(
            schemaVersion: Self.snapshotSchemaVersion,
            savedAt: Date(),
            roots: roots,
            exclusionPatterns: exclusionPatterns,
            recordCount: records.count
        )

        try writeJSONLine(header, encoder: encoder, to: handle)
        for record in records {
            try autoreleasepool {
                try writeJSONLine(record, encoder: encoder, to: handle)
            }
        }

        try handle.close()
        didClose = true

        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
    }

    private func writeJSONLine<T: Encodable>(_ value: T, encoder: JSONEncoder, to handle: FileHandle) throws {
        let data = try encoder.encode(value)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([10]))
    }

    private func loadPersistedSnapshot() -> PersistedSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return nil
        }

        do {
            return try loadStreamingSnapshot(from: snapshotURL)
        } catch {
            MemoryTelemetry.log("snapshot.load.v2Failed", activeIndexJobs: currentActiveIndexJobCount())
            return nil
        }
    }

    private func loadStreamingSnapshot(from url: URL) throws -> PersistedSnapshot {
        let decoder = JSONDecoder()
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var buffer = Data()
        var lineNumber = 0
        var header: PersistedSnapshotHeader?
        var records: [FileRecord] = []

        func decodeLine(_ line: Data) throws {
            guard !line.isEmpty else { return }
            if lineNumber == 0 {
                let decodedHeader = try decoder.decode(PersistedSnapshotHeader.self, from: line)
                guard decodedHeader.schemaVersion == Self.snapshotSchemaVersion else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                header = decodedHeader
                records.reserveCapacity(decodedHeader.recordCount)
            } else {
                try autoreleasepool {
                    records.append(try decoder.decode(FileRecord.self, from: line))
                }
            }
            lineNumber += 1
        }

        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newlineIndex])
                try decodeLine(line)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
            }
        }

        if !buffer.isEmpty {
            try decodeLine(buffer)
        }

        guard let header else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return PersistedSnapshot(
            savedAt: header.savedAt,
            roots: header.roots,
            exclusionPatterns: header.exclusionPatterns,
            records: records
        )
    }

    private func cleanupStaleTemporaryFiles(olderThan minimumAge: TimeInterval = 600) {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: supportDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants]
            )
        else {
            return
        }

        let now = Date()
        for url in contents {
            let name = url.lastPathComponent
            let isTemporary = name.hasPrefix(".dat.nosync")
                || (name.hasPrefix("filename-index-v2-") && name.hasSuffix(".jsonl.tmp"))
                || name == "filename-index.json.tmp"
            guard isTemporary else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard minimumAge <= 0 || now.timeIntervalSince(modified) >= minimumAge else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func shouldBuildPathGramIndex(recordCount: Int, totalPathBytes: Int) -> Bool {
        recordCount <= pathGramRecordLimit && totalPathBytes <= pathGramTotalPathByteLimit
    }

    private static func metrics<S: Sequence>(for records: S) -> RecordCollectionMetrics where S.Element == FileRecord {
        var count = 0
        var totalPathBytes = 0
        var maxPathBytes = 0

        for record in records {
            let pathBytes = record.path.utf8.count
            count += 1
            totalPathBytes += pathBytes
            maxPathBytes = max(maxPathBytes, pathBytes)
        }

        return RecordCollectionMetrics(recordCount: count, totalPathBytes: totalPathBytes, maxPathBytes: maxPathBytes)
    }

    private func beginIndexJob(_ name: String) -> Int {
        let activeJobs = lock.withLock { () -> Int in
            activeIndexJobs += 1
            return activeIndexJobs
        }
        MemoryTelemetry.log("job.\(name).begin", activeIndexJobs: activeJobs)
        return activeJobs
    }

    private func endIndexJob(_ name: String, jobID _: Int) {
        let activeJobs = lock.withLock { () -> Int in
            activeIndexJobs = max(activeIndexJobs - 1, 0)
            return activeIndexJobs
        }
        MemoryTelemetry.log("job.\(name).end", activeIndexJobs: activeJobs)
    }

    private func currentActiveIndexJobCount() -> Int {
        lock.withLock { activeIndexJobs }
    }

    func currentDiagnostics() -> FileIndexDiagnostics {
        lock.withLock {
            FileIndexDiagnostics(
                indexedCount: recordsByPath.count,
                snapshotRevision: searchSnapshotRevision,
                phase: phase,
                discoveredCount: discoveredCount,
                searchableCount: searchableCount,
                optimizedCount: optimizedCount,
                pathGramIndexEnabled: searchSnapshot.diagnostics.pathGramIndexEnabled,
                pathGramKeyCount: searchSnapshot.diagnostics.pathGramKeyCount,
                pathGramPostingCount: searchSnapshot.diagnostics.pathGramPostingCount,
                nameGramKeyCount: searchSnapshot.diagnostics.nameGramKeyCount,
                nameGramPostingCount: searchSnapshot.diagnostics.nameGramPostingCount,
                extensionKeyCount: searchSnapshot.diagnostics.extensionKeyCount,
                extensionPostingCount: searchSnapshot.diagnostics.extensionPostingCount,
                completedRefreshBatches: completedRefreshBatches,
                completedSnapshotRebuilds: completedSnapshotRebuilds,
                activeIndexJobs: activeIndexJobs
            )
        }
    }

    func replaceRecordsForTesting(
        _ records: [FileRecord],
        buildsSearchStructures: Bool = true,
        phase: IndexPhase = .ready,
        status: String? = nil
    ) {
        let recordsByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
        indexQueue.sync {
            let snapshot = SearchSnapshot(records: records, buildsSearchStructures: buildsSearchStructures)
            lock.withLock {
                self.recordsByPath = recordsByPath
                searchSnapshot = snapshot
                searchSnapshotRevision &+= 1
                indexing = phase == .scanning || phase == .optimizing || phase == .saving
                self.phase = phase
                discoveredCount = records.count
                searchableCount = snapshot.records.count
                optimizedCount = buildsSearchStructures ? snapshot.records.count : 0
                self.status = status ?? "Indexed \(records.count.formatted()) test files"
                lastUpdated = Date()
                if phase == .ready {
                    completedSnapshotRebuilds &+= 1
                }
            }
            publishStats()
        }
    }

    func persistSnapshotForTesting() {
        _ = indexQueue.sync {
            persistSnapshot()
        }
    }

    private func publishStats() {
        let update = lock.withLock {
            (
                stats: IndexStats(
                    indexedCount: recordsByPath.count,
                    isIndexing: indexing,
                    isLoadingSnapshot: snapshotLoadState == .loading,
                    phase: phase,
                    discoveredCount: discoveredCount,
                    searchableCount: searchableCount,
                    optimizedCount: optimizedCount,
                    status: status,
                    lastUpdated: lastUpdated
                ),
                handler: statsChangedHandler
            )
        }

        guard let handler = update.handler else { return }
        let stats = update.stats
        Task { @MainActor in
            handler(stats)
        }
    }

    private func lockedStats() -> IndexStats {
        lock.withLock {
            IndexStats(
                indexedCount: recordsByPath.count,
                isIndexing: indexing,
                isLoadingSnapshot: snapshotLoadState == .loading,
                phase: phase,
                discoveredCount: discoveredCount,
                searchableCount: searchableCount,
                optimizedCount: optimizedCount,
                status: status,
                lastUpdated: lastUpdated
            )
        }
    }

    private func currentGeneration() -> UInt64 {
        lock.withLock {
            generation
        }
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        lock.withLock {
            generation == candidate
        }
    }

    private func isPersistRevisionCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock {
            persistRevision == candidate
        }
    }

    private func canonicalizedRoots(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path), !seen.contains(standardized.path) else {
                return nil
            }
            seen.insert(standardized.path)
            return standardized
        }
    }

    private func shouldExclude(
        _ url: URL,
        exclusions: FileExclusionRules,
        rootPaths: [String],
        isDirectory: Bool? = nil
    ) -> Bool {
        exclusions.excludes(url: url, roots: rootPaths, isDirectory: isDirectory)
    }

    private func isLikelyLoop(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private static func compare(_ lhs: SearchResult, _ rhs: SearchResult, sort: SortSpec, queryIsEmpty: Bool) -> Bool {
        let ascending = sort.ascending

        func ordered<T: Comparable>(_ left: T, _ right: T) -> Bool? {
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        }

        let primary: Bool?
        switch sort.column {
        case .relevance:
            if queryIsEmpty {
                primary = lhs.record.modifiedTime == rhs.record.modifiedTime ? nil : lhs.record.modifiedTime > rhs.record.modifiedTime
            } else if lhs.score != rhs.score {
                primary = lhs.score > rhs.score
            } else {
                primary = nil
            }
        case .name:
            primary = ordered(lhs.record.normalizedName, rhs.record.normalizedName)
        case .path:
            primary = ordered(lhs.record.normalizedPath, rhs.record.normalizedPath)
        case .modified:
            primary = ordered(lhs.record.modifiedTime, rhs.record.modifiedTime)
        case .created:
            primary = ordered(lhs.record.createdTime ?? 0, rhs.record.createdTime ?? 0)
        case .size:
            primary = ordered(lhs.record.sizeBytes, rhs.record.sizeBytes)
        case .fileExtension:
            primary = ordered(lhs.record.fileExtension, rhs.record.fileExtension)
        case .kind:
            primary = ordered(lhs.record.isDirectory ? "Folder" : "File", rhs.record.isDirectory ? "Folder" : "File")
        case .volume:
            primary = ordered(lhs.record.volumeName, rhs.record.volumeName)
        }

        if let primary {
            return primary
        }

        if lhs.record.normalizedName != rhs.record.normalizedName {
            return lhs.record.normalizedName < rhs.record.normalizedName
        }

        return lhs.record.path < rhs.record.path
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
