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

public enum MatchClass: Int, Codable, CaseIterable, Sendable {
    case metadata = 0
    case weakPath = 1
    case near = 2
    case substring = 3
    case prefix = 4
    case exact = 5
}

public struct MatchQuality: Codable, Equatable, Comparable, Sendable {
    public let matchClass: MatchClass
    public let scoreBin: Int

    public init(matchClass: MatchClass, scoreBin: Int) {
        self.matchClass = matchClass
        self.scoreBin = max(0, min(scoreBin, 4))
    }

    public init(matchClass: MatchClass, score: Int) {
        self.init(matchClass: matchClass, scoreBin: score / 2_000)
    }

    public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool {
        if lhs.matchClass.rawValue != rhs.matchClass.rawValue {
            return lhs.matchClass.rawValue < rhs.matchClass.rawValue
        }
        return lhs.scoreBin < rhs.scoreBin
    }
}

public enum MatchField: String, Codable, Sendable {
    case name
    case path
    case ancestorPath
    case fileExtension = "extension"
    case kind
}

public enum MatchSpanStyle: String, Codable, Sendable {
    case contiguous
    case subsequence
    case typo
}

public struct MatchSpan: Codable, Equatable, Sendable {
    public let field: MatchField
    public let location: Int
    public let length: Int
    public let style: MatchSpanStyle

    public init(field: MatchField, location: Int, length: Int, style: MatchSpanStyle) {
        self.field = field
        self.location = location
        self.length = length
        self.style = style
    }
}

public struct MatchExplanation: Codable, Equatable, Sendable {
    public let quality: MatchQuality
    public let score: Int
    public let field: MatchField
    public let reason: String
    public let spans: [MatchSpan]

    public var matchClass: MatchClass {
        quality.matchClass
    }

    public init(
        matchClass: MatchClass,
        score: Int,
        field: MatchField,
        reason: String,
        spans: [MatchSpan] = []
    ) {
        self.quality = MatchQuality(matchClass: matchClass, score: score)
        self.score = score
        self.field = field
        self.reason = reason
        self.spans = spans
    }

    public init(
        quality: MatchQuality,
        score: Int,
        field: MatchField,
        reason: String,
        spans: [MatchSpan] = []
    ) {
        self.quality = quality
        self.score = score
        self.field = field
        self.reason = reason
        self.spans = spans
    }
}

public struct SearchResult: Identifiable, Sendable {
    public let record: FileRecord
    public let score: Int
    public let match: MatchExplanation?

    public init(record: FileRecord, score: Int, match: MatchExplanation? = nil) {
        self.record = record
        self.score = score
        self.match = match
    }

    public var id: UInt64 {
        record.id
    }
}

public struct SearchResponse: Sendable {
    public let results: [SearchResult]
    public let totalMatches: Int
    public let elapsed: TimeInterval
    public let snapshotRevision: UInt64?
    public let usesIndexedCandidates: Bool
    public let executionProfile: SearchExecutionProfile

    public init(
        results: [SearchResult],
        totalMatches: Int,
        elapsed: TimeInterval,
        snapshotRevision: UInt64? = nil,
        usesIndexedCandidates: Bool = false,
        executionProfile: SearchExecutionProfile? = nil
    ) {
        self.results = results
        self.totalMatches = totalMatches
        self.elapsed = elapsed
        self.snapshotRevision = snapshotRevision
        self.usesIndexedCandidates = usesIndexedCandidates
        self.executionProfile = executionProfile ?? SearchExecutionProfile(
            executionPath: usesIndexedCandidates ? .unprofiledIndexed : .unprofiled,
            indexesUsed: usesIndexedCandidates ? [.nameGrams] : [],
            candidateCount: usesIndexedCandidates ? results.count : 0,
            scannedRowCount: usesIndexedCandidates ? 0 : results.count,
            didFallbackToFullScan: !usesIndexedCandidates,
            elapsed: elapsed
        )
    }
}

public enum IndexPhase: String, Codable, Sendable {
    case idle
    case loading
    case scanning
    case optimizing
    case saving
    case ready
    case failed
}

public struct IndexStats: Codable, Equatable, Sendable {
    public let indexedCount: Int
    public let isIndexing: Bool
    public let isLoadingSnapshot: Bool
    public let phase: IndexPhase
    public let discoveredCount: Int
    public let searchableCount: Int
    public let optimizedCount: Int
    public let snapshotRevision: UInt64
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
        snapshotRevision: UInt64 = 0,
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
        self.snapshotRevision = snapshotRevision
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
    let recordStoreKind: RecordStoreKind
    let mappedByteSize: Int
    let heapPageCount: Int
    let overlayCount: Int
    let columnarSidecarsLoaded: Bool
    let visibleCount: Int?
    let visibleModifiedOrderCount: Int
    let simdTextVerificationEnabled: Bool
    let pathGramIndexEnabled: Bool
    let pathGramKeyCount: Int
    let pathGramPostingCount: Int
    let nameGramKeyCount: Int
    let nameGramPostingCount: Int
    let componentGramKeyCount: Int
    let componentGramPostingCount: Int
    let extensionKeyCount: Int
    let extensionPostingCount: Int
    let completedRefreshBatches: UInt64
    let completedSnapshotRebuilds: UInt64
    let activeIndexJobs: Int
    let schemaVersion: Int
    let resultCount: Int
    let virtualRowCount: Int
    let fallbackScanCount: UInt64
    let scannedRowCount: UInt64
    let pathMaterializationCount: UInt64
}

public final class FileIndex: @unchecked Sendable {
    private static let maximumRefreshBatchPaths = 512
    private static let primaryPublishRecordInterval = 25_000
    private static let primaryPublishTimeInterval: TimeInterval = 1
    private static let pathGramRecordLimit = 200_000
    private static let pathGramTotalPathByteLimit = 24 * 1024 * 1024
    private static let exactEmptyQuerySortLimit = 100_000

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

    private struct LoadedMappedSnapshot {
        let manifest: CompactSnapshotManifest
        let store: MappedRecordStore
        let searchStructures: PersistedSearchStructures
    }

    private struct PersistedSearchStructures {
        let modifiedDescending: [Int]?
        let visibleModifiedDescending: [Int]?
        let nameGramIndex: MappedIntPostingIndex?
        let componentGramIndex: MappedIntPostingIndex?
        let pathGramIndex: MappedIntPostingIndex?
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
        let componentGramKeyCount: Int
        let componentGramPostingCount: Int
        let extensionKeyCount: Int
        let extensionPostingCount: Int
        let simdTextVerificationEnabled: Bool
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

    private struct SearchMatch {
        let rowID: Int
        let score: Int
        let match: MatchExplanation?

        init(rowID: Int, score: Int, match: MatchExplanation? = nil) {
            self.rowID = rowID
            self.score = score
            self.match = match
        }
    }

    private struct RowInterval {
        let start: Int
        let end: Int
    }

    private struct RowIntervalSet {
        let intervals: [RowInterval]

        var isEmpty: Bool { intervals.isEmpty }

        func contains(_ rowID: Int) -> Bool {
            var low = 0
            var high = intervals.count
            while low < high {
                let middle = (low + high) / 2
                let interval = intervals[middle]
                if rowID < interval.start {
                    high = middle
                } else if rowID >= interval.end {
                    low = middle + 1
                } else {
                    return true
                }
            }
            return false
        }

        func count(using prefixCounts: [Int]) -> Int {
            guard !intervals.isEmpty else { return 0 }
            var total = 0
            for interval in intervals {
                total += prefixCounts[interval.end] - prefixCounts[interval.start]
            }
            return total
        }

        static func build(_ intervals: [RowInterval]) -> RowIntervalSet {
            guard !intervals.isEmpty else { return RowIntervalSet(intervals: []) }
            let sorted = intervals.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
            var merged: [RowInterval] = []
            merged.reserveCapacity(sorted.count)
            for interval in sorted where interval.start < interval.end {
                guard let last = merged.last else {
                    merged.append(interval)
                    continue
                }
                if interval.start <= last.end {
                    merged[merged.count - 1] = RowInterval(start: last.start, end: max(last.end, interval.end))
                } else {
                    merged.append(interval)
                }
            }
            return RowIntervalSet(intervals: merged)
        }
    }

    private enum SnapshotLoadState {
        case notStarted
        case loading
        case finished
    }

    private struct ScanResult {
        let records: [String: FileRecord]
        let store: HeapPagedRecordStore
        let visited: Int
    }

    private struct ScanProgress {
        let store: HeapPagedRecordStore
        let visited: Int
    }

    private final class ConcurrentScanState: @unchecked Sendable {
        private let condition = NSCondition()
        private var pendingDirectories: [URL] = []
        private var activeDirectories = 0
        private var shouldStop = false
        private var records: [String: FileRecord]
        private let builder: HeapPagedRecordStore.Builder
        private var visited = 0
        private var lastPublishedCount = 0
        private var lastPublishedAt = Date.distantPast

        init(reservedCapacity: Int) {
            records = [:]
            records.reserveCapacity(reservedCapacity)
            builder = HeapPagedRecordStore.Builder(reservedCapacity: reservedCapacity)
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
            builder.append(record)
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
                builder.append(record)
                visited += 1
            }
            condition.unlock()
        }

        func publishSnapshotIfNeeded(force: Bool) -> ScanProgress? {
            condition.lock()
            defer { condition.unlock() }

            let now = Date()
            let shouldPublish = force
                || records.count - lastPublishedCount >= FileIndex.primaryPublishRecordInterval
                || now.timeIntervalSince(lastPublishedAt) >= FileIndex.primaryPublishTimeInterval
            guard shouldPublish else { return nil }

            lastPublishedCount = records.count
            lastPublishedAt = now
            return ScanProgress(store: builder.snapshot(includesPathIndex: false), visited: visited)
        }

        func result() -> (ScanResult, Bool) {
            condition.lock()
            defer { condition.unlock() }
            return (ScanResult(records: records, store: builder.snapshot(includesPathIndex: true), visited: visited), shouldStop)
        }
    }

    private final class SearchSnapshot: @unchecked Sendable {
        static let empty = SearchSnapshot(store: EmptyRecordStore.shared, buildsSearchStructures: false)

        let store: RecordStore
        let modifiedDescending: [Int]
        let modifiedAscending: [Int]
        let nameAscending: [Int]
        let nameDescending: [Int]
        let visibleModifiedDescending: [Int]
        let visibleModifiedAscending: [Int]
        let gramIndex: MappedIntPostingIndex?
        let nameGramIndex: MappedIntPostingIndex?
        let componentGramIndex: MappedIntPostingIndex?
        let resultPrefixCounts: [Int]
        let visibleResultPrefixCounts: [Int]
        let extensionIndex: [String: [Int32]]
        private let childLinks: ChildLinks?
        let visibleCount: Int?
        let hasSortedOrder: Bool
        let diagnostics: SearchStructureDiagnostics

        private struct ChildLinks {
            let firstChild: [Int32]
            let nextSibling: [Int32]
            let roots: [Int32]
        }

        var count: Int { store.count }
        var resultCount: Int { store.storedResultCount ?? (0..<store.count).filter { store.isResultRow(at: $0) }.count }
        var virtualRowCount: Int { count - resultCount }
        var records: [FileRecord] { store.allRecords() }
        var isOptimizedForSearch: Bool {
            resultCount == 0 || (hasSortedOrder && nameGramIndex != nil && componentGramIndex != nil)
        }

        init(records: [FileRecord], buildsSearchStructures: Bool = true) {
            self.store = HeapPagedRecordStore(records: records)
            if buildsSearchStructures {
                let metrics = FileIndex.metrics(for: store)
                let buildsPathGramIndex = FileIndex.shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes)
                self.gramIndex = buildsPathGramIndex ? Self.makePathGramIndex(store: store) : nil
                self.nameGramIndex = Self.makeNameGramIndex(store: store)
                self.componentGramIndex = Self.makeComponentGramIndex(store: store)
                self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
                self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
                let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
                self.extensionIndex = extensionData.extensionIndex
                self.childLinks = Self.makeChildLinks(store: store)
                self.visibleCount = extensionData.visibleCount
                let sortedByModified = Self.makeModifiedDescending(store: store)
                self.modifiedDescending = sortedByModified
                self.modifiedAscending = Array(sortedByModified.reversed())
                let sortedByName = Self.makeNameAscending(store: store)
                self.nameAscending = sortedByName
                self.nameDescending = Array(sortedByName.reversed())
                let visibleSortedByModified = Self.makeVisibleModifiedDescending(
                    modifiedDescending: sortedByModified,
                    store: store
                )
                self.visibleModifiedDescending = visibleSortedByModified
                self.visibleModifiedAscending = Array(visibleSortedByModified.reversed())
                self.hasSortedOrder = true
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: buildsPathGramIndex,
                    gramIndex: gramIndex,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            } else {
                self.gramIndex = nil
                self.nameGramIndex = nil
                self.componentGramIndex = nil
                self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
                self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
                self.extensionIndex = [:]
                self.childLinks = nil
                self.visibleCount = Self.makeVisibleCount(store: store)
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.nameAscending = []
                self.nameDescending = []
                self.visibleModifiedDescending = []
                self.visibleModifiedAscending = []
                self.hasSortedOrder = false
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: false,
                    gramIndex: gramIndex,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            }
        }

        init(store: RecordStore, buildsSearchStructures: Bool = true) {
            self.store = store
            if buildsSearchStructures {
                let metrics = FileIndex.metrics(for: store)
                let buildsPathGramIndex = FileIndex.shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes)
                self.gramIndex = buildsPathGramIndex ? Self.makePathGramIndex(store: store) : nil
                self.nameGramIndex = Self.makeNameGramIndex(store: store)
                self.componentGramIndex = Self.makeComponentGramIndex(store: store)
                self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
                self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
                let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
                self.extensionIndex = extensionData.extensionIndex
                self.childLinks = Self.makeChildLinks(store: store)
                self.visibleCount = extensionData.visibleCount
                let sortedByModified = Self.makeModifiedDescending(store: store)
                self.modifiedDescending = sortedByModified
                self.modifiedAscending = Array(sortedByModified.reversed())
                let sortedByName = Self.makeNameAscending(store: store)
                self.nameAscending = sortedByName
                self.nameDescending = Array(sortedByName.reversed())
                let visibleSortedByModified = Self.makeVisibleModifiedDescending(
                    modifiedDescending: sortedByModified,
                    store: store
                )
                self.visibleModifiedDescending = visibleSortedByModified
                self.visibleModifiedAscending = Array(visibleSortedByModified.reversed())
                self.hasSortedOrder = true
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: buildsPathGramIndex,
                    gramIndex: gramIndex,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            } else {
                self.gramIndex = nil
                self.nameGramIndex = nil
                self.componentGramIndex = nil
                self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
                self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
                self.extensionIndex = [:]
                self.childLinks = nil
                self.visibleCount = nil
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.nameAscending = []
                self.nameDescending = []
                self.visibleModifiedDescending = []
                self.visibleModifiedAscending = []
                self.hasSortedOrder = false
                self.diagnostics = Self.makeDiagnostics(
                    pathGramIndexEnabled: false,
                    gramIndex: gramIndex,
                    nameGramIndex: nameGramIndex,
                    componentGramIndex: componentGramIndex,
                    extensionIndex: extensionIndex
                )
            }
        }

        init(store: RecordStore, persistedStructures: PersistedSearchStructures) {
            self.store = store
            self.gramIndex = persistedStructures.pathGramIndex
            self.nameGramIndex = persistedStructures.nameGramIndex
            self.componentGramIndex = persistedStructures.componentGramIndex ?? persistedStructures.nameGramIndex
            self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
            self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
            let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
            self.extensionIndex = extensionData.extensionIndex
            self.childLinks = Self.makeChildLinks(store: store)
            self.visibleCount = extensionData.visibleCount

            let expectedModifiedCount = store.storedResultCount ?? store.count
            if let modifiedDescending = persistedStructures.modifiedDescending, modifiedDescending.count == expectedModifiedCount {
                self.modifiedDescending = modifiedDescending
                self.modifiedAscending = Array(modifiedDescending.reversed())
                let sortedByName = Self.makeNameAscending(store: store)
                self.nameAscending = sortedByName
                self.nameDescending = Array(sortedByName.reversed())
                let visibleModifiedDescending = persistedStructures.visibleModifiedDescending
                    ?? Self.makeVisibleModifiedDescending(modifiedDescending: modifiedDescending, store: store)
                self.visibleModifiedDescending = visibleModifiedDescending
                self.visibleModifiedAscending = Array(visibleModifiedDescending.reversed())
                self.hasSortedOrder = true
            } else {
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.nameAscending = []
                self.nameDescending = []
                self.visibleModifiedDescending = []
                self.visibleModifiedAscending = []
                self.hasSortedOrder = false
            }

            self.diagnostics = Self.makeDiagnostics(
                pathGramIndexEnabled: gramIndex != nil,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex
            )
        }

        private init(
            store: RecordStore,
            modifiedDescending: [Int],
            gramIndex: MappedIntPostingIndex?,
            nameGramIndex: MappedIntPostingIndex?,
            componentGramIndex: MappedIntPostingIndex?,
            extensionIndex: [String: [Int32]],
            childLinks: ChildLinks? = nil,
            nameAscending: [Int]? = nil,
            nameDescending: [Int]? = nil,
            visibleCount: Int?,
            hasSortedOrder: Bool
        ) {
            self.store = store
            self.modifiedDescending = modifiedDescending
            self.modifiedAscending = Array(modifiedDescending.reversed())
            let expectedNameOrderCount = store.storedResultCount ?? store.count
            if !hasSortedOrder {
                self.nameAscending = []
                self.nameDescending = []
            } else if let nameAscending, nameAscending.count == expectedNameOrderCount {
                self.nameAscending = nameAscending
                if let nameDescending, nameDescending.count == expectedNameOrderCount {
                    self.nameDescending = nameDescending
                } else {
                    self.nameDescending = Array(nameAscending.reversed())
                }
            } else {
                let sortedByName = Self.makeNameAscending(store: store)
                self.nameAscending = sortedByName
                self.nameDescending = Array(sortedByName.reversed())
            }
            let visibleModifiedDescending = Self.makeVisibleModifiedDescending(
                modifiedDescending: modifiedDescending,
                store: store
            )
            self.visibleModifiedDescending = visibleModifiedDescending
            self.visibleModifiedAscending = Array(visibleModifiedDescending.reversed())
            self.gramIndex = gramIndex
            self.nameGramIndex = nameGramIndex
            self.componentGramIndex = componentGramIndex
            self.resultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: false)
            self.visibleResultPrefixCounts = Self.makeResultPrefixCounts(store: store, visibleOnly: true)
            self.extensionIndex = extensionIndex
            self.childLinks = childLinks ?? Self.makeChildLinks(store: store)
            self.visibleCount = visibleCount
            self.hasSortedOrder = hasSortedOrder
            self.diagnostics = Self.makeDiagnostics(
                pathGramIndexEnabled: gramIndex != nil,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex
            )
        }

        func updatingMetadata(for upserts: [String: FileRecord]) -> SearchSnapshot? {
            guard hasSortedOrder, !upserts.isEmpty else { return nil }

            var replacements: [Int: FileRecord] = [:]
            replacements.reserveCapacity(upserts.count)
            var changedIndices: [Int] = []
            changedIndices.reserveCapacity(upserts.count)

            for (path, record) in upserts {
                guard let index = store.rowID(forPath: path), searchKeysMatch(rowID: index, replacement: record) else {
                    return nil
                }
                replacements[index] = record
                changedIndices.append(index)
            }

            let updatedStore = ReplacingRecordStore(base: store, replacements: replacements)
            let changed = Set(changedIndices)
            let unchangedDescending = modifiedDescending.filter { !changed.contains($0) }
            let changedDescending = changedIndices.sorted {
                Self.modifiedDescendingPrecedes($0, $1, store: updatedStore)
            }
            let mergedDescending = Self.mergeModifiedDescending(
                changed: changedDescending,
                unchanged: unchangedDescending,
                store: updatedStore
            )

            return SearchSnapshot(
                store: updatedStore,
                modifiedDescending: mergedDescending,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                visibleCount: Self.makeVisibleCount(store: updatedStore),
                hasSortedOrder: true
            )
        }

        private func searchKeysMatch(rowID: Int, replacement: FileRecord) -> Bool {
            let existing = store.view(at: rowID)
            return existing.path == replacement.path
                && existing.name == replacement.name
                && existing.directoryPath == replacement.directoryPath
                && existing.fileExtension == replacement.fileExtension
                && existing.normalizedName == replacement.normalizedName
                && existing.normalizedPath == replacement.normalizedPath
        }

        func addingNameGramIndex() -> SearchSnapshot {
            guard nameGramIndex == nil || componentGramIndex == nil else { return self }
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex ?? Self.makeNameGramIndex(store: store),
                componentGramIndex: componentGramIndex ?? Self.makeComponentGramIndex(store: store),
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                visibleCount: visibleCount,
                hasSortedOrder: hasSortedOrder
            )
        }

        func addingExtensionIndex() -> SearchSnapshot {
            guard extensionIndex.isEmpty || visibleCount == nil else { return self }
            let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex.isEmpty ? extensionData.extensionIndex : extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                visibleCount: visibleCount ?? extensionData.visibleCount,
                hasSortedOrder: hasSortedOrder
            )
        }

        func addingModifiedSortOrder() -> SearchSnapshot {
            guard !hasSortedOrder else { return self }
            return SearchSnapshot(
                store: store,
                modifiedDescending: Self.makeModifiedDescending(store: store),
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                visibleCount: visibleCount,
                hasSortedOrder: true
            )
        }

        func addingPathGramIndexIfBudgetAllows() -> SearchSnapshot {
            guard gramIndex == nil else { return self }
            let metrics = FileIndex.metrics(for: store)
            guard FileIndex.shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes) else {
                return self
            }
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: Self.makePathGramIndex(store: store),
                nameGramIndex: nameGramIndex,
                componentGramIndex: componentGramIndex,
                extensionIndex: extensionIndex,
                childLinks: childLinks,
                nameAscending: nameAscending,
                nameDescending: nameDescending,
                visibleCount: visibleCount,
                hasSortedOrder: hasSortedOrder
            )
        }

        func record(at index: Int) -> FileRecord {
            store.record(at: index)
        }

        func view(at index: Int) -> RecordSearchView {
            store.view(at: index)
        }

        func isHiddenInPath(at index: Int, cache: inout [Int: Bool]) -> Bool {
            store.isHiddenInPath(at: index, cache: &cache)
        }

        func isVisible(at index: Int) -> Bool {
            store.isVisible(at: index)
        }

        func orderedIndices(for sort: SortSpec, queryIsEmpty: Bool, includeHidden: Bool) -> [Int]? {
            guard hasSortedOrder else { return nil }

            switch sort.column {
            case .modified:
                if includeHidden {
                    return sort.ascending ? modifiedAscending : modifiedDescending
                }
                return sort.ascending ? visibleModifiedAscending : visibleModifiedDescending
            case .relevance where queryIsEmpty:
                return includeHidden ? modifiedDescending : visibleModifiedDescending
            case .relevance, .name, .path, .created, .size, .fileExtension, .kind, .volume:
                return nil
            }
        }

        func candidatePathIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            guard let gramIndex else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = gramIndex.values(for: key) else {
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

        func candidatePathIndices(containingAllBytes tokenBytes: [UInt8]) -> [Int32]? {
            candidateIndices(in: gramIndex, containingAllBytes: tokenBytes)
        }

        func candidateIndices(containing tokenBytes: [UInt8], field: FuzzyMatcher.QueryField) -> [Int32]? {
            switch field {
            case .name:
                return candidateNameIndices(containing: tokenBytes)
            case .path:
                return candidatePathIndices(containing: tokenBytes)
            case .any:
                guard
                    let nameCandidates = candidateNameIndices(containing: tokenBytes),
                    let pathCandidates = candidatePathIndices(containing: tokenBytes)
                else {
                    return nil
                }
                return FileIndex.unionPostingLists(pathCandidates, nameCandidates)
            }
        }

        func candidateNameIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            guard let nameGramIndex else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = nameGramIndex.values(for: key) else {
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

        func candidateNameIndices(containingAllBytes tokenBytes: [UInt8]) -> [Int32]? {
            candidateIndices(in: nameGramIndex, containingAllBytes: tokenBytes)
        }

        func candidateComponentIndices(containing tokenBytes: [UInt8]) -> [Int32]? {
            guard let componentGramIndex else { return nil }

            let keys = FileIndex.searchGramKeys(for: tokenBytes)
            guard !keys.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(keys.count)

            for key in keys {
                guard let values = componentGramIndex.values(for: key) else {
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

        func candidateComponentIndices(containingAllBytes tokenBytes: [UInt8]) -> [Int32]? {
            candidateIndices(in: componentGramIndex, containingAllBytes: tokenBytes)
        }

        func candidatePathIndicesByScanning(containing token: String, shouldCancel: @Sendable () -> Bool) -> [Int32]? {
            guard gramIndex == nil, !token.isEmpty else { return nil }

            var cache: [Int: Bool] = [:]
            var candidates: [Int32] = []
            for rowID in 0..<count {
                if rowID.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                if store.normalizedPath(at: rowID, contains: token, cache: &cache) {
                    candidates.append(Int32(rowID))
                }
            }
            return candidates
        }

        private func expandedPathComponentCandidates(
            directRows: [Int32],
            rootMatches: (Int) -> Bool,
            shouldCancel: @Sendable () -> Bool
        ) -> [Int32]? {
            guard let childLinks else { return nil }

            var included = Array(repeating: UInt8(0), count: count)
            var candidates: [Int32] = []
            var visited = 0
            var stack: [Int] = []

            func includeSubtree(startingAt start: Int) -> Bool {
                guard start >= 0, start < count, included[start] == 0 else {
                    return true
                }

                let intervalEnd = min(store.subtreeEnd(at: start), count)
                if intervalEnd > start + 1 {
                    for rowID in start..<intervalEnd where included[rowID] == 0 {
                        visited += 1
                        if visited & 511 == 0, shouldCancel() {
                            return false
                        }

                        included[rowID] = 1
                        candidates.append(Int32(rowID))
                    }
                    return true
                }

                stack.append(start)
                while let rowID = stack.popLast() {
                    guard rowID >= 0, rowID < count, included[rowID] == 0 else {
                        continue
                    }

                    visited += 1
                    if visited & 511 == 0, shouldCancel() {
                        return false
                    }

                    included[rowID] = 1
                    candidates.append(Int32(rowID))

                    var child = childLinks.firstChild[rowID]
                    while child >= 0 {
                        let childRow = Int(child)
                        stack.append(childRow)
                        child = childLinks.nextSibling[childRow]
                    }
                }

                return true
            }

            for (offset, row) in directRows.enumerated() {
                if offset & 511 == 0, shouldCancel() {
                    return nil
                }
                guard includeSubtree(startingAt: Int(row)) else {
                    return nil
                }
            }

            for (offset, row) in childLinks.roots.enumerated() {
                if offset & 511 == 0, shouldCancel() {
                    return nil
                }

                let rowID = Int(row)
                guard included[rowID] == 0, rootMatches(rowID) else { continue }
                guard includeSubtree(startingAt: rowID) else {
                    return nil
                }
            }

            candidates.sort()
            return candidates
        }

        func candidatePathIndicesByComponentExpansion(
            containing token: String,
            shouldCancel: @Sendable () -> Bool
        ) -> [Int32]? {
            guard
                gramIndex == nil,
                componentGramIndex != nil,
                !token.isEmpty,
                !FileIndex.tokenContainsPathSeparator(token)
            else {
                return nil
            }

            let componentCandidates = candidateComponentIndices(containing: Array(token.utf8)) ?? []
            var directRows: [Int32] = []
            directRows.reserveCapacity(componentCandidates.count)
            for candidate in componentCandidates {
                let rowID = Int(candidate)
                guard rowID >= 0, rowID < count else { continue }
                if store.normalizedName(at: rowID, contains: token) {
                    directRows.append(candidate)
                }
            }

            if let candidates = expandedPathComponentCandidates(
                directRows: directRows,
                rootMatches: { rowID in
                    store.normalizedPath(at: rowID).contains(token)
                },
                shouldCancel: shouldCancel
            ) {
                return candidates
            }

            guard store.schemaVersion < SnapshotLayout.schemaVersion else {
                return nil
            }

            let directMatches = Set(directRows.map(Int.init))
            var memo = Array(repeating: Int8(-1), count: count)
            var pathContainsCache: [Int: Bool] = [:]

            func pathMatches(at rowID: Int) -> Bool {
                if directMatches.contains(rowID) {
                    memo[rowID] = 1
                    return true
                }

                switch memo[rowID] {
                case 0:
                    return false
                case 1:
                    return true
                default:
                    break
                }

                guard let parent = store.parentRowID(at: rowID) else {
                    let matches = store.normalizedPath(at: rowID, contains: token, cache: &pathContainsCache)
                    memo[rowID] = matches ? 1 : 0
                    return matches
                }

                guard parent >= 0, parent < count, parent != rowID else {
                    memo[rowID] = 0
                    return false
                }

                let matches = pathMatches(at: parent)
                memo[rowID] = matches ? 1 : 0
                return matches
            }

            var candidates: [Int32] = []
            for rowID in 0..<count {
                if rowID.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                if pathMatches(at: rowID) {
                    candidates.append(Int32(rowID))
                }
            }
            return candidates
        }

        func candidatePathIndicesByShortFuzzyComponentExpansion(
            containing tokenBytes: [UInt8],
            shouldCancel: @Sendable () -> Bool
        ) -> [Int32]? {
            guard
                gramIndex == nil,
                componentGramIndex != nil,
                !tokenBytes.isEmpty,
                tokenBytes.count <= 3
            else {
                return nil
            }

            let distinctBytes = FileIndex.distinctBytes(in: tokenBytes)
            guard let componentCandidates = candidateComponentIndices(containingAllBytes: distinctBytes) else {
                return nil
            }

            var directRows: [Int32] = []
            directRows.reserveCapacity(componentCandidates.count)
            var directMatches = Array(repeating: false, count: count)
            for candidate in componentCandidates {
                let rowID = Int(candidate)
                guard rowID >= 0, rowID < count else { continue }
                if FileIndex.shortFuzzyPathComponentMatches(store.normalizedName(at: rowID), tokenBytes: tokenBytes) {
                    directMatches[rowID] = true
                    directRows.append(candidate)
                }
            }

            if let candidates = expandedPathComponentCandidates(
                directRows: directRows,
                rootMatches: { rowID in
                    FileIndex.shortFuzzyPathComponentMatches(store.normalizedPath(at: rowID), tokenBytes: tokenBytes)
                },
                shouldCancel: shouldCancel
            ) {
                return candidates
            }

            guard store.schemaVersion < SnapshotLayout.schemaVersion else {
                return nil
            }

            var memo = Array(repeating: Int8(-1), count: count)
            var resolutionStack: [Int] = []
            resolutionStack.reserveCapacity(64)

            func pathMatches(at rowID: Int) -> Bool {
                if directMatches[rowID] {
                    memo[rowID] = 1
                    return true
                }

                let existing = memo[rowID]
                if existing != -1 {
                    return existing == 1
                }

                resolutionStack.removeAll(keepingCapacity: true)
                var current = rowID
                var matches = false

                while true {
                    if directMatches[current] {
                        matches = true
                        memo[current] = 1
                        break
                    }

                    let known = memo[current]
                    if known != -1 {
                        matches = known == 1
                        break
                    }

                    guard let parent = store.parentRowID(at: current) else {
                        matches = FileIndex.shortFuzzyPathComponentMatches(
                            store.normalizedPath(at: current),
                            tokenBytes: tokenBytes
                        )
                        memo[current] = matches ? 1 : 0
                        break
                    }

                    guard parent >= 0, parent < count, parent != current else {
                        matches = false
                        memo[current] = 0
                        break
                    }

                    resolutionStack.append(current)
                    current = parent
                }

                let value: Int8 = matches ? 1 : 0
                for row in resolutionStack {
                    memo[row] = value
                }
                return matches
            }

            var candidates: [Int32] = []
            for rowID in 0..<count {
                if rowID & 511 == 0, shouldCancel() {
                    return nil
                }
                if pathMatches(at: rowID) {
                    candidates.append(Int32(rowID))
                }
            }
            return candidates
        }

        func componentPathIntervalSet(
            containing token: String,
            tokenBytes: [UInt8],
            shortFuzzy: Bool,
            shouldCancel: @Sendable () -> Bool
        ) -> RowIntervalSet? {
            guard
                gramIndex == nil,
                componentGramIndex != nil,
                !tokenBytes.isEmpty,
                !FileIndex.tokenContainsPathSeparator(token)
            else {
                return nil
            }

            let componentCandidates: [Int32]?
            if shortFuzzy {
                componentCandidates = candidateComponentIndices(containingAllBytes: FileIndex.distinctBytes(in: tokenBytes))
            } else {
                componentCandidates = candidateComponentIndices(containing: tokenBytes)
            }
            guard let componentCandidates else { return nil }

            var intervals: [RowInterval] = []
            intervals.reserveCapacity(componentCandidates.count)
            for (offset, candidate) in componentCandidates.enumerated() {
                if offset & 511 == 0, shouldCancel() {
                    return nil
                }

                let rowID = Int(candidate)
                guard rowID >= 0, rowID < count else { continue }
                let matches = shortFuzzy
                    ? FileIndex.shortFuzzyPathComponentMatches(store.normalizedName(at: rowID), tokenBytes: tokenBytes)
                    : store.normalizedName(at: rowID, contains: token)
                guard matches else { continue }

                let end = max(rowID + 1, min(store.subtreeEnd(at: rowID), count))
                intervals.append(RowInterval(start: rowID, end: end))
            }

            return RowIntervalSet.build(intervals)
        }

        private func candidateIndices(in postingIndex: MappedIntPostingIndex?, containingAllBytes tokenBytes: [UInt8]) -> [Int32]? {
            guard let postingIndex, !tokenBytes.isEmpty else { return nil }

            var postings: [[Int32]] = []
            postings.reserveCapacity(tokenBytes.count)

            for byte in tokenBytes {
                let key = FileIndex.searchGramKey(bytes: [byte], start: 0, length: 1)
                guard let values = postingIndex.values(for: key) else {
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

        private static func mergeModifiedDescending(changed: [Int], unchanged: [Int], store: RecordStore) -> [Int] {
            var merged: [Int] = []
            merged.reserveCapacity(changed.count + unchanged.count)

            var changedIndex = 0
            var unchangedIndex = 0

            while changedIndex < changed.count, unchangedIndex < unchanged.count {
                let changedRecordIndex = changed[changedIndex]
                let unchangedRecordIndex = unchanged[unchangedIndex]

                if modifiedDescendingPrecedes(changedRecordIndex, unchangedRecordIndex, store: store) {
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

        private static func modifiedDescendingPrecedes(_ lhs: Int, _ rhs: Int, store: RecordStore) -> Bool {
            let left = store.view(at: lhs)
            let right = store.view(at: rhs)

            if left.modifiedTime != right.modifiedTime {
                return left.modifiedTime > right.modifiedTime
            }
            if left.normalizedName != right.normalizedName {
                return left.normalizedName < right.normalizedName
            }
            return left.path < right.path
        }

        private static func makeModifiedDescending(store: RecordStore) -> [Int] {
            (0..<store.count).filter { store.isResultRow(at: $0) }.sorted {
                modifiedDescendingPrecedes($0, $1, store: store)
            }
        }

        private static func makeNameAscending(store: RecordStore) -> [Int] {
            (0..<store.count).filter { store.isResultRow(at: $0) }.sorted {
                let leftName = store.normalizedName(at: $0)
                let rightName = store.normalizedName(at: $1)
                if leftName != rightName {
                    return leftName < rightName
                }
                return store.path(at: $0) < store.path(at: $1)
            }
        }

        private static func makePathGramIndex(store: RecordStore) -> MappedIntPostingIndex? {
            var index: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for recordIndex in 0..<store.count {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: store.normalizedPath(at: recordIndex), into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }

            return try? MappedIntPostingIndex.build(from: index, temporaryName: "att-path-postings")
        }

        private static func makeDiagnostics(
            pathGramIndexEnabled: Bool,
            gramIndex: MappedIntPostingIndex?,
            nameGramIndex: MappedIntPostingIndex?,
            componentGramIndex: MappedIntPostingIndex?,
            extensionIndex: [String: [Int32]]
        ) -> SearchStructureDiagnostics {
            SearchStructureDiagnostics(
                pathGramIndexEnabled: pathGramIndexEnabled,
                pathGramKeyCount: gramIndex?.keyCount ?? 0,
                pathGramPostingCount: gramIndex?.postingCount ?? 0,
                nameGramKeyCount: nameGramIndex?.keyCount ?? 0,
                nameGramPostingCount: nameGramIndex?.postingCount ?? 0,
                componentGramKeyCount: componentGramIndex?.keyCount ?? 0,
                componentGramPostingCount: componentGramIndex?.postingCount ?? 0,
                extensionKeyCount: extensionIndex.count,
                extensionPostingCount: extensionIndex.values.reduce(0) { $0 + $1.count },
                simdTextVerificationEnabled: true
            )
        }

        private static func makeNameGramIndex(store: RecordStore) -> MappedIntPostingIndex? {
            var index: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for recordIndex in 0..<store.count {
                guard store.isResultRow(at: recordIndex) else { continue }
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: store.normalizedName(at: recordIndex), into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }

            return try? MappedIntPostingIndex.build(from: index, temporaryName: "att-name-postings")
        }

        private static func makeComponentGramIndex(store: RecordStore) -> MappedIntPostingIndex? {
            var index: [Int: [Int32]] = [:]
            var keys = Set<Int>()

            for recordIndex in 0..<store.count {
                keys.removeAll(keepingCapacity: true)
                FileIndex.collectSearchGramKeys(from: store.normalizedName(at: recordIndex), into: &keys)

                let storedIndex = Int32(recordIndex)
                for key in keys {
                    index[key, default: []].append(storedIndex)
                }
            }

            return try? MappedIntPostingIndex.build(from: index, temporaryName: "att-component-postings")
        }

        private static func makeChildLinks(store: RecordStore) -> ChildLinks? {
            guard store.count > 0 else { return nil }

            var firstChild = Array(repeating: Int32(-1), count: store.count)
            var nextSibling = Array(repeating: Int32(-1), count: store.count)
            var roots: [Int32] = []
            roots.reserveCapacity(16)

            for rowID in 0..<store.count {
                guard
                    let parent = store.parentRowID(at: rowID),
                    parent >= 0,
                    parent < store.count,
                    parent != rowID
                else {
                    roots.append(Int32(rowID))
                    continue
                }

                nextSibling[rowID] = firstChild[parent]
                firstChild[parent] = Int32(rowID)
            }

            return ChildLinks(firstChild: firstChild, nextSibling: nextSibling, roots: roots)
        }

        private static func makeVisibleCount(store: RecordStore) -> Int {
            if let visibleCount = store.storedVisibleCount {
                return visibleCount
            }

            var count = 0

            for recordIndex in 0..<store.count where store.isVisible(at: recordIndex) {
                count += 1
            }

            return count
        }

        private static func makeResultPrefixCounts(store: RecordStore, visibleOnly: Bool) -> [Int] {
            var prefix = Array(repeating: 0, count: store.count + 1)
            guard store.count > 0 else { return prefix }

            for rowID in 0..<store.count {
                let included = store.isResultRow(at: rowID) && (!visibleOnly || store.isVisible(at: rowID))
                prefix[rowID + 1] = prefix[rowID] + (included ? 1 : 0)
            }
            return prefix
        }

        private static func makeVisibleModifiedDescending(modifiedDescending: [Int], store: RecordStore) -> [Int] {
            modifiedDescending.filter { store.isVisible(at: $0) }
        }

        private static func makeExtensionIndexAndVisibleCount(store: RecordStore) -> (extensionIndex: [String: [Int32]], visibleCount: Int) {
            var index: [String: [Int32]] = [:]
            var visibleCount = 0

            for recordIndex in 0..<store.count {
                guard store.isResultRow(at: recordIndex) else { continue }
                if store.isVisible(at: recordIndex) {
                    visibleCount += 1
                }

                let fileExtension = store.fileExtension(at: recordIndex)
                guard !fileExtension.isEmpty else { continue }
                index[fileExtension, default: []].append(Int32(recordIndex))
            }

            return (index, visibleCount)
        }
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let supportDirectory: URL
    private let snapshotURL: URL
    private let metricsURL: URL
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
    private var fallbackScanCount: UInt64 = 0
    private var scannedRowCount: UInt64 = 0
    private var pathMaterializationCount: UInt64 = 0
    private var activeIndexJobs = 0
    private var usageMetrics = IndexUsageMetrics()
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
        self.snapshotURL = SnapshotLayout.packageURL(in: supportDirectory)
        self.metricsURL = supportDirectory.appendingPathComponent("index-metrics.json", isDirectory: false)
        self.usageMetrics = Self.loadUsageMetrics(from: metricsURL, fileManager: fileManager)
        cleanupStaleTemporaryFiles()
        cleanupObsoleteIndexFiles()

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

    public var dataDirectoryURL: URL {
        supportDirectory
    }

    public func recordAppLaunch(appVersion: String? = nil) {
        updateUsageMetrics { metrics in
            metrics.recordAppLaunch(appVersion: appVersion)
        }
    }

    public func recordFileAction(_ action: FileActionMetric) {
        updateUsageMetrics { metrics in
            metrics.recordFileAction(action)
        }
    }

    public func recordMemorySample(bytes: UInt64) {
        updateUsageMetrics { metrics in
            metrics.recordMemorySample(bytes: bytes)
        }
    }

    public func recordRecursiveRescan() {
        updateUsageMetrics { metrics in
            metrics.recordRecursiveRescan()
        }
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

    public func currentInsightsSnapshot() -> IndexInsightsSnapshot {
        let state = lock.withLock {
            (
                snapshot: searchSnapshot,
                roots: roots,
                stats: lockedStatsWithoutLock(),
                usage: usageMetrics,
                health: currentHealthDiagnosticsWithoutLock()
            )
        }

        let storage = Self.storageInsights(
            supportDirectory: supportDirectory,
            snapshotURL: snapshotURL,
            applicationName: supportDirectory.lastPathComponent,
            fileManager: fileManager
        )
        let rootInsights = Self.rootInsights(
            snapshot: state.snapshot,
            roots: state.roots,
            estimatedIndexBytes: storage.indexPackageBytes
        )

        return IndexInsightsSnapshot(
            generatedAt: Date(),
            stats: state.stats,
            roots: rootInsights,
            storage: storage,
            usage: state.usage,
            lifetime: state.usage.lifetime,
            health: state.health
        )
    }

    public enum ClearCachedIndexError: LocalizedError {
        case busy

        public var errorDescription: String? {
            switch self {
            case .busy:
                "AllTheThings is currently indexing. Wait for the current index job to finish before clearing the cached index."
            }
        }
    }

    public func clearPersistedIndexData() throws {
        let canClear = lock.withLock {
            activeIndexJobs == 0 && !indexing && snapshotLoadState != .loading
        }
        guard canClear else {
            throw ClearCachedIndexError.busy
        }

        try indexQueue.sync {
            try removePersistedIndexFiles()
            lock.withLock {
                recordsByPath.removeAll(keepingCapacity: false)
                searchSnapshot = .empty
                searchSnapshotRevision &+= 1
                discoveredCount = 0
                searchableCount = 0
                optimizedCount = 0
                phase = .idle
                status = "Cached index cleared"
                lastUpdated = Date()
            }
        }
        publishStats()
    }

    public func replaceRootsAndRebuild(_ rootURLs: [URL]) {
        let canonicalRoots = canonicalizedRoots(rootURLs)
        let rebuildStarted = Date()
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
            self?.rebuild(roots: canonicalRoots, generation: currentGeneration, started: rebuildStarted)
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

    public func search(_ request: SearchRequest, maxResults: Int = 2_000) -> SearchResponse {
        search(request, maxResults: maxResults, shouldCancel: { false }) ?? SearchResponse(results: [], totalMatches: 0, elapsed: 0)
    }

    public func search(
        _ request: SearchRequest,
        maxResults: Int = 2_000,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        let started = Date()
        recordSearchStarted()
        var didCompleteSearch = false

        func finish(_ response: SearchResponse) -> SearchResponse {
            didCompleteSearch = true
            recordSearchCompleted(response.executionProfile)
            return response
        }

        defer {
            if !didCompleteSearch {
                recordSearchCancelled(elapsed: Date().timeIntervalSince(started))
            }
        }

        let snapshotData = lock.withLock {
            (snapshot: searchSnapshot, revision: searchSnapshotRevision)
        }
        let snapshot = snapshotData.snapshot
        let snapshotRevision = snapshotData.revision

        guard !shouldCancel() else { return nil }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = FuzzyMatcher.parse(trimmedQuery)
        let boundedMaxResults = max(maxResults, 0)
        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(snapshot.count, boundedMaxResults))
        let trimThreshold = boundedMaxResults > 0 ? boundedMaxResults * 5 : 0
        var total = 0
        var shouldSortMatches = true

        func sortAndLimitMatches() {
            guard boundedMaxResults > 0 else { return }
            matches.sort {
                Self.compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: parsedQuery.isEmpty)
            }
            if matches.count > boundedMaxResults {
                matches.removeSubrange(boundedMaxResults..<matches.count)
            }
        }

        func trimMatches() {
            guard boundedMaxResults > 0, matches.count > boundedMaxResults else { return }
            sortAndLimitMatches()
        }

        func appendMatch(rowID: Int, score: Int, match: MatchExplanation? = nil) {
            guard snapshot.store.isResultRow(at: rowID) else { return }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { return }
            total += 1
            guard boundedMaxResults > 0 else { return }
            matches.append(SearchMatch(rowID: rowID, score: score, match: match))
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        if parsedQuery.isEmpty {
            if let orderedRecords = snapshot.orderedIndices(
                for: request.sort,
                queryIsEmpty: true,
                includeHidden: request.includeHidden
            ) {
                for (offset, index) in orderedRecords.enumerated() {
                    if offset.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }
                    appendMatch(rowID: index, score: 0)
                }
            } else if snapshot.count > Self.exactEmptyQuerySortLimit, boundedMaxResults > 0 {
                shouldSortMatches = false
                let canStopAtResultLimit = request.includeHidden || snapshot.visibleCount != nil
                var matchedVisibleCount = 0
                for index in 0..<snapshot.count {
                    if index.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }

                    guard request.includeHidden || snapshot.isVisible(at: index) else {
                        continue
                    }

                    matchedVisibleCount += 1
                    if matches.count < boundedMaxResults {
                        matches.append(SearchMatch(rowID: index, score: 0))
                    } else if canStopAtResultLimit {
                        break
                    }
                }

                total = request.includeHidden ? snapshot.resultCount : (snapshot.visibleCount ?? matchedVisibleCount)
            } else {
                for index in 0..<snapshot.count {
                    if index.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }
                    appendMatch(rowID: index, score: 0)
                }
            }
        } else {
            if let fastResponse = Self.fastV6ComponentNameSortedSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
            ) {
                return finish(fastResponse)
            }

            if let fastResponse = Self.fastLargeShortFuzzyComponentSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
            ) {
                return finish(fastResponse)
            }

            if let fastResponse = Self.fastLargePathSubstringSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
            ) {
                return finish(fastResponse)
            }

            if let indexedResponse = Self.indexedCandidateSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
            ) {
                return finish(indexedResponse)
            }

            lock.withLock {
                fallbackScanCount &+= 1
                scannedRowCount &+= UInt64(snapshot.count)
            }
            for index in 0..<snapshot.count {
                if index.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                guard snapshot.store.isResultRow(at: index) else { continue }
                let record = snapshot.view(at: index)
                if let explanation = FuzzyMatcher.explain(record: record, parsedQuery: parsedQuery) {
                    appendMatch(rowID: index, score: explanation.score, match: explanation)
                }
            }
        }

        guard !shouldCancel() else { return nil }

        if shouldSortMatches {
            sortAndLimitMatches()
        }

        guard !shouldCancel() else { return nil }

        let elapsed = Date().timeIntervalSince(started)
        let profile: SearchExecutionProfile
        if parsedQuery.isEmpty {
            profile = SearchExecutionProfile(
                executionPath: .emptyQuerySortedOrder,
                indexesUsed: request.includeHidden ? [.modifiedOrder] : [.modifiedOrder, .visibleBitset],
                candidateCount: total,
                scannedRowCount: min(snapshot.count, total),
                elapsed: elapsed
            )
        } else {
            profile = SearchExecutionProfile(
                executionPath: .fullFallbackScan,
                scannedRowCount: snapshot.count,
                didFallbackToFullScan: true,
                elapsed: elapsed
            )
        }

        return finish(SearchResponse(
            results: Self.materialize(matches, from: snapshot),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: parsedQuery.isEmpty,
            executionProfile: profile
        ))
    }

    private static func materialize(_ matches: [SearchMatch], from snapshot: SearchSnapshot) -> [SearchResult] {
        matches.map { SearchResult(record: snapshot.record(at: $0.rowID), score: $0.score, match: $0.match) }
    }

    private static func fastV6ComponentNameSortedSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            snapshot.store.schemaVersion >= SnapshotLayout.schemaVersion,
            request.sort.column == .name,
            maxResults > 0,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            mode == .fuzzy || mode == .exact,
            !tokenContainsPathSeparator(pattern.token)
        else {
            return nil
        }

        let tokenBytes = Array(pattern.token.utf8)
        guard !tokenBytes.isEmpty, tokenBytes.allSatisfy({ $0 < 128 }) else {
            return nil
        }
        let shortFuzzy = mode == .fuzzy && tokenBytes.count <= 3

        var intervals: [RowInterval] = []
        if field != .name {
            guard let pathIntervals = snapshot.componentPathIntervalSet(
                containing: pattern.token,
                tokenBytes: tokenBytes,
                shortFuzzy: shortFuzzy,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            intervals.append(contentsOf: pathIntervals.intervals)
        }

        if field != .path {
            let nameCandidates: [Int32]?
            if shortFuzzy {
                nameCandidates = shortFuzzyNameCandidateIndices(
                    snapshot: snapshot,
                    tokenBytes: tokenBytes,
                    shouldCancel: shouldCancel
                )
            } else if mode == .fuzzy {
                nameCandidates = fuzzyNameCandidateIndices(snapshot: snapshot, tokenBytes: tokenBytes)
            } else {
                nameCandidates = snapshot.candidateNameIndices(containing: tokenBytes)
            }

            guard let nameCandidates else { return nil }
            intervals.reserveCapacity(intervals.count + nameCandidates.count)
            for (offset, candidate) in nameCandidates.enumerated() {
                if offset & 511 == 0, shouldCancel() {
                    return nil
                }
                let rowID = Int(candidate)
                guard rowID >= 0, rowID < snapshot.count, snapshot.store.isResultRow(at: rowID) else { continue }
                if mode == .exact && !snapshot.store.normalizedName(at: rowID, contains: pattern.token) {
                    continue
                }
                if mode == .fuzzy && !shortFuzzy {
                    guard FuzzyMatcher.score(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) != nil else {
                        continue
                    }
                }
                intervals.append(RowInterval(start: rowID, end: rowID + 1))
            }
        }

        let rowSet = RowIntervalSet.build(intervals)
        guard !rowSet.isEmpty else {
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .optimizedSortedFastPath,
                    indexesUsed: [.nameGrams, .componentGrams],
                    candidateCount: 0,
                    elapsed: elapsed
                )
            )
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(maxResults)
        let trimThreshold = maxResults * 5
        var total = 0

        func sortAndLimitMatches() {
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for interval in rowSet.intervals {
            for rowID in interval.start..<interval.end {
                if rowID & 511 == 0, shouldCancel() {
                    return nil
                }
                guard rowID >= 0, rowID < snapshot.count else { continue }
                guard snapshot.store.isResultRow(at: rowID) else { continue }
                guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
                guard let explanation = FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) else {
                    continue
                }

                total += 1
                matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
                if matches.count > trimThreshold {
                    sortAndLimitMatches()
                }
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        let elapsed = Date().timeIntervalSince(started)
        let candidateCount = rowSet.intervals.reduce(0) { $0 + max($1.end - $1.start, 0) }
        return SearchResponse(
            results: materialize(matches, from: snapshot),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .optimizedSortedFastPath,
                indexesUsed: [.nameGrams, .componentGrams],
                candidateCount: candidateCount,
                elapsed: elapsed
            )
        )
    }

    private static func fastLargeShortFuzzyComponentSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.sort.column == .name,
            maxResults > 0,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            mode == .fuzzy,
            !tokenContainsPathSeparator(pattern.token)
        else {
            return nil
        }

        let tokenBytes = Array(pattern.token.utf8)
        guard !tokenBytes.isEmpty, tokenBytes.count <= 3, tokenBytes.allSatisfy({ $0 < 128 }) else {
            return nil
        }

        let nameCandidates: [Int32]
        switch field {
        case .path:
            nameCandidates = []
        case .name, .any:
            guard let candidates = shortFuzzyNameCandidateIndices(
                snapshot: snapshot,
                tokenBytes: tokenBytes,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            nameCandidates = candidates
        }

        let pathCandidates: [Int32]
        switch field {
        case .name:
            pathCandidates = []
        case .path, .any:
            guard let candidates = snapshot.candidatePathIndicesByShortFuzzyComponentExpansion(
                containing: tokenBytes,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            pathCandidates = candidates
        }

        let candidates = unionPostingLists(pathCandidates, nameCandidates)
        guard !candidates.isEmpty else {
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .nameComponentIndex,
                    indexesUsed: [.nameGrams, .componentGrams],
                    candidateCount: 0,
                    elapsed: elapsed
                )
            )
        }

        guard let selected = nameSortedPathSubstringMatches(
            snapshot: snapshot,
            candidates: candidates,
            parsedQuery: parsedQuery,
            request: request,
            maxResults: maxResults,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(selected.matches, from: snapshot),
            totalMatches: selected.total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .nameComponentIndex,
                indexesUsed: [.nameGrams, .componentGrams],
                candidateCount: candidates.count,
                elapsed: elapsed
            )
        )
    }

    private static func shortFuzzyNameCandidateIndices(
        snapshot: SearchSnapshot,
        tokenBytes: [UInt8],
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        guard let candidates = fuzzyNameCandidateIndices(snapshot: snapshot, tokenBytes: tokenBytes) else {
            return nil
        }

        var matches: [Int32] = []
        matches.reserveCapacity(candidates.count)
        for (offset, candidate) in candidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            if shortFuzzyNameMatches(snapshot.store.normalizedName(at: rowID), tokenBytes: tokenBytes) {
                matches.append(candidate)
            }
        }
        return matches
    }

    private static func fastLargePathSubstringSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard
            request.sort.column != .relevance,
            request.sort.column != .path,
            snapshot.gramIndex == nil,
            snapshot.nameGramIndex != nil,
            parsedQuery.negative.isEmpty,
            parsedQuery.positive.count == 1,
            let clause = parsedQuery.positive.first,
            clause.alternatives.count == 1,
            let part = clause.alternatives.first,
            case .text(let field, let pattern, let mode) = part,
            mode == .fuzzy || mode == .exact,
            !tokenContainsPathSeparator(pattern.token),
            pattern.token.utf8.count > 3
        else {
            return nil
        }

        let tokenBytes = Array(pattern.token.utf8)
        let exactNameCandidates = snapshot.candidateNameIndices(containing: tokenBytes) ?? []
        let exactPathCandidates: [Int32]
        switch field {
        case .name:
            exactPathCandidates = exactNameCandidates
        case .any, .path:
            guard let pathCandidates = snapshot.candidatePathIndicesByComponentExpansion(
                containing: pattern.token,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            exactPathCandidates = field == .any ? unionPostingLists(pathCandidates, exactNameCandidates) : pathCandidates
        }

        guard exactPathCandidates.count >= max(maxResults, 1) || exactPathCandidates.count > 1_000 else {
            return nil
        }

        if request.sort.column == .modified, snapshot.hasSortedOrder {
            var candidateSet = Set<Int>()
            candidateSet.reserveCapacity(exactPathCandidates.count)
            for candidate in exactPathCandidates {
                let rowID = Int(candidate)
                guard rowID >= 0, rowID < snapshot.count else { continue }
                candidateSet.insert(rowID)
            }

            let orderedRows: [Int]
            if request.includeHidden {
                orderedRows = request.sort.ascending ? snapshot.modifiedAscending : snapshot.modifiedDescending
            } else {
                orderedRows = request.sort.ascending ? snapshot.visibleModifiedAscending : snapshot.visibleModifiedDescending
            }
            var matches: [SearchMatch] = []
            matches.reserveCapacity(min(candidateSet.count, maxResults))
            var total = 0

            for (offset, rowID) in orderedRows.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                guard candidateSet.contains(rowID) else { continue }
                guard snapshot.store.isResultRow(at: rowID) else { continue }
                guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
                guard let explanation = FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) else {
                    continue
                }

                total += 1
                if maxResults > 0 {
                    matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
                }
            }

            guard total >= max(maxResults, 1) || total > 1_000 else {
                return nil
            }

            guard !shouldCancel() else { return nil }
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: materialize(matches, from: snapshot),
                totalMatches: total,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .pathGramIndex,
                    indexesUsed: [.nameGrams, .pathGrams, .modifiedOrder],
                    candidateCount: exactPathCandidates.count,
                    elapsed: elapsed
                )
            )
        }

        if request.sort.column == .name, maxResults > 0 {
            guard let selected = nameSortedPathSubstringMatches(
                snapshot: snapshot,
                candidates: exactPathCandidates,
                parsedQuery: parsedQuery,
                request: request,
                maxResults: maxResults,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }

            guard selected.total >= max(maxResults, 1) || selected.total > 1_000 else {
                return nil
            }

            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: materialize(selected.matches, from: snapshot),
                totalMatches: selected.total,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .pathGramIndex,
                    indexesUsed: [.nameGrams, .pathGrams],
                    candidateCount: exactPathCandidates.count,
                    elapsed: elapsed
                )
            )
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(exactPathCandidates.count, maxResults))
        let trimThreshold = maxResults > 0 ? maxResults * 5 : 0
        var total = 0

        func sortAndLimitMatches() {
            guard maxResults > 0 else { return }
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
            }
            if matches.count > maxResults {
                matches.removeSubrange(maxResults..<matches.count)
            }
        }

        for (offset, candidate) in exactPathCandidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard let explanation = FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) else {
                continue
            }

            total += 1
            guard maxResults > 0 else { continue }

            matches.append(SearchMatch(rowID: rowID, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                sortAndLimitMatches()
            }
        }

        guard total >= max(maxResults, 1) || total > 1_000 else {
            return nil
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        guard !shouldCancel() else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(matches, from: snapshot),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: .pathGramIndex,
                indexesUsed: [.nameGrams, .pathGrams],
                candidateCount: exactPathCandidates.count,
                elapsed: elapsed
            )
        )
    }

    private struct NameSortedSelection {
        let matches: [SearchMatch]
        let total: Int
    }

    private struct NameSortCandidate {
        let rowID: Int
        let normalizedName: String
    }

    private struct NamePathSortCandidate {
        let rowID: Int
        let normalizedName: String
        let path: String
        let match: MatchExplanation?
    }

    private static func nameSortedPathSubstringMatches(
        snapshot: SearchSnapshot,
        candidates: [Int32],
        parsedQuery: FuzzyMatcher.ParsedQuery,
        request: SearchRequest,
        maxResults: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> NameSortedSelection? {
        let ascending = request.sort.ascending
        if maxResults > 0, !snapshot.nameAscending.isEmpty {
            var included = Array(repeating: UInt8(0), count: snapshot.count)
            var explanations: [Int: MatchExplanation] = [:]
            explanations.reserveCapacity(min(candidates.count, maxResults * 8))
            var total = 0
            for (offset, candidate) in candidates.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }

                let rowID = Int(candidate)
                guard rowID >= 0, rowID < snapshot.count else { continue }
                guard snapshot.store.isResultRow(at: rowID) else { continue }
                guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
                guard included[rowID] == 0 else { continue }
                guard let explanation = FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) else {
                    continue
                }
                included[rowID] = 1
                explanations[rowID] = explanation
                total += 1
            }

            guard total > 0 else {
                return NameSortedSelection(matches: [], total: 0)
            }

            let order = ascending ? snapshot.nameAscending : snapshot.nameDescending
            var matches: [SearchMatch] = []
            matches.reserveCapacity(min(maxResults, total))
            for (offset, rowID) in order.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                guard included[rowID] != 0 else { continue }
                let explanation = explanations[rowID]
                matches.append(SearchMatch(rowID: rowID, score: explanation?.score ?? 0, match: explanation))
                if matches.count == maxResults {
                    break
                }
            }

            return NameSortedSelection(matches: matches, total: total)
        }

        var heap: [NameSortCandidate] = []
        heap.reserveCapacity(maxResults)
        var total = 0

        func precedes(_ lhs: NameSortCandidate, _ rhs: NameSortCandidate) -> Bool {
            if lhs.normalizedName != rhs.normalizedName {
                return ascending ? lhs.normalizedName < rhs.normalizedName : lhs.normalizedName > rhs.normalizedName
            }
            return lhs.rowID < rhs.rowID
        }

        func isWorse(_ lhs: NameSortCandidate, than rhs: NameSortCandidate) -> Bool {
            precedes(rhs, lhs)
        }

        func siftUp(_ startIndex: Int) {
            var child = startIndex
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWorse(heap[child], than: heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        func siftDown(_ startIndex: Int) {
            var parent = startIndex
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var candidate = parent

                if left < heap.count, isWorse(heap[left], than: heap[candidate]) {
                    candidate = left
                }
                if right < heap.count, isWorse(heap[right], than: heap[candidate]) {
                    candidate = right
                }
                guard candidate != parent else { break }
                heap.swapAt(parent, candidate)
                parent = candidate
            }
        }

        func appendToHeap(_ candidate: NameSortCandidate) {
            if heap.count < maxResults {
                heap.append(candidate)
                siftUp(heap.count - 1)
            } else if let worst = heap.first, precedes(candidate, worst) {
                heap[0] = candidate
                siftDown(0)
            }
        }

        for (offset, candidate) in candidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            guard request.includeHidden || snapshot.isVisible(at: rowID) else { continue }
            guard FuzzyMatcher.explain(record: snapshot.view(at: rowID), parsedQuery: parsedQuery) != nil else {
                continue
            }

            total += 1
            appendToHeap(NameSortCandidate(
                rowID: rowID,
                normalizedName: snapshot.store.normalizedName(at: rowID)
            ))
        }

        guard total > 0 else {
            return NameSortedSelection(matches: [], total: 0)
        }

        return NameSortedSelection(
            matches: sortNamePathCandidates(
                heap.map {
                    let explanation = FuzzyMatcher.explain(record: snapshot.view(at: $0.rowID), parsedQuery: parsedQuery)
                    return NamePathSortCandidate(
                        rowID: $0.rowID,
                        normalizedName: $0.normalizedName,
                        path: snapshot.store.path(at: $0.rowID),
                        match: explanation
                    )
                },
                ascending: ascending,
                maxResults: maxResults
            ),
            total: total
        )
    }

    private static func sortNamePathCandidates(
        _ candidates: [NamePathSortCandidate],
        ascending: Bool,
        maxResults: Int
    ) -> [SearchMatch] {
        var candidates = candidates
        candidates.sort {
            if $0.normalizedName != $1.normalizedName {
                return ascending ? $0.normalizedName < $1.normalizedName : $0.normalizedName > $1.normalizedName
            }
            return $0.path < $1.path
        }
        if candidates.count > maxResults {
            candidates.removeSubrange(maxResults..<candidates.count)
        }
        return candidates.map { SearchMatch(rowID: $0.rowID, score: $0.match?.score ?? 0, match: $0.match) }
    }

    private static func indexedCandidateSearch(
        snapshot: SearchSnapshot,
        request: SearchRequest,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        maxResults: Int,
        started: Date,
        snapshotRevision: UInt64,
        shouldCancel: @Sendable () -> Bool
    ) -> SearchResponse? {
        guard let candidateIndices = candidateIndices(
            snapshot: snapshot,
            parsedQuery: parsedQuery,
            shouldCancel: shouldCancel
        ) else {
            return nil
        }

        if candidateIndices.isEmpty {
            let elapsed = Date().timeIntervalSince(started)
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: elapsed,
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true,
                executionProfile: SearchExecutionProfile(
                    executionPath: .indexedCandidateIntersection,
                    indexesUsed: Self.indexUses(for: parsedQuery),
                    candidateCount: 0,
                    elapsed: elapsed
                )
            )
        }

        guard candidateIndices.count < snapshot.count else {
            return nil
        }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(candidateIndices.count, maxResults))
        let trimThreshold = maxResults > 0 ? maxResults * 5 : 0
        var total = 0

        func sortAndLimitMatches() {
            guard maxResults > 0 else { return }
            matches.sort {
                compare($0, $1, snapshot: snapshot, sort: request.sort, queryIsEmpty: false)
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
            guard index >= 0, index < snapshot.count else {
                continue
            }
            guard snapshot.store.isResultRow(at: index) else {
                continue
            }

            let record = snapshot.view(at: index)
            guard request.includeHidden || snapshot.isVisible(at: index) else {
                continue
            }
            guard let explanation = FuzzyMatcher.explain(record: record, parsedQuery: parsedQuery) else {
                continue
            }

            total += 1
            guard maxResults > 0 else {
                continue
            }

            matches.append(SearchMatch(rowID: index, score: explanation.score, match: explanation))
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        guard !shouldCancel() else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        return SearchResponse(
            results: materialize(matches, from: snapshot),
            totalMatches: total,
            elapsed: elapsed,
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true,
            executionProfile: SearchExecutionProfile(
                executionPath: Self.executionPath(forIndexedCandidateQuery: parsedQuery),
                indexesUsed: Self.indexUses(for: parsedQuery),
                candidateCount: candidateIndices.count,
                elapsed: elapsed
            )
        )
    }

    private static func executionPath(forIndexedCandidateQuery parsedQuery: FuzzyMatcher.ParsedQuery) -> SearchExecutionPath {
        let uses = indexUses(for: parsedQuery)
        if uses.contains(.extensionPostings) {
            return .extensionCandidateIntersection
        }
        if uses.contains(.pathGrams) {
            return .pathGramIndex
        }
        if uses.contains(.nameGrams) || uses.contains(.componentGrams) {
            return .nameComponentIndex
        }
        return .indexedCandidateIntersection
    }

    private static func indexUses(for parsedQuery: FuzzyMatcher.ParsedQuery) -> Set<SearchIndexUse> {
        var uses = Set<SearchIndexUse>()

        for clause in parsedQuery.positive {
            for alternative in clause.alternatives {
                switch alternative {
                case .fileExtension:
                    uses.insert(.extensionPostings)
                    uses.insert(.nameGrams)
                case .kind:
                    break
                case .text(let field, let pattern, _):
                    if field != .path {
                        uses.insert(.nameGrams)
                    }
                    if field != .name || tokenContainsPathSeparator(pattern.token) {
                        uses.insert(.pathGrams)
                        uses.insert(.componentGrams)
                    }
                }
            }
        }

        return uses
    }

    private static func recordIsHidden<Record: SearchRecordReadable>(_ record: Record) -> Bool {
        record.isHidden || FileRecord.pathIsHidden(record.path)
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        parsedQuery: FuzzyMatcher.ParsedQuery,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        var candidates: [Int32]?
        var foundUsableClause = false

        for clause in parsedQuery.positive {
            guard let clauseCandidates = candidateIndices(
                snapshot: snapshot,
                clause: clause,
                shouldCancel: shouldCancel
            ) else {
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

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        clause: FuzzyMatcher.QueryClause,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        var candidates: [Int32] = []
        var foundUsableAlternative = false

        for alternative in clause.alternatives {
            guard let alternativeCandidates = candidateIndices(
                snapshot: snapshot,
                part: alternative,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }

            foundUsableAlternative = true
            candidates = unionPostingLists(candidates, alternativeCandidates)
        }

        return foundUsableAlternative ? candidates : nil
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        part: FuzzyMatcher.QueryPart,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        switch part {
        case .kind(let token):
            return candidateIndices(snapshot: snapshot, kind: token, shouldCancel: shouldCancel)
        case .fileExtension(let pattern, let mode):
            return snapshot.candidateIndices(fileExtension: pattern.token, mode: mode)
                ?? candidateIndices(
                    snapshot: snapshot,
                    token: pattern.token,
                    mode: mode,
                    allowsFuzzyPrefix: true,
                    shouldCancel: shouldCancel
                )
        case .text(let field, let pattern, let mode):
            return candidateIndices(
                snapshot: snapshot,
                field: field,
                token: pattern.token,
                mode: mode,
                shouldCancel: shouldCancel
            )
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        field: FuzzyMatcher.QueryField,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        switch mode {
        case .exact:
            return exactTextCandidateIndices(
                snapshot: snapshot,
                field: field,
                token: token,
                shouldCancel: shouldCancel
            )
        case .wildcard:
            let candidateField: FuzzyMatcher.QueryField = field == .any && tokenContainsPathSeparator(token) ? .path : field
            return candidateIndices(
                snapshot: snapshot,
                requiredFragments: wildcardRequiredFragments(from: token),
                field: candidateField,
                shouldCancel: shouldCancel
            )
        case .fuzzy:
            if tokenContainsPathSeparator(token) {
                guard field != .name else {
                    return nil
                }
                return candidateIndices(
                    snapshot: snapshot,
                    requiredFragments: pathLiteralFragments(from: token),
                    field: .path,
                    shouldCancel: shouldCancel
                )
            }

            return fuzzyTextCandidateIndices(
                snapshot: snapshot,
                field: field,
                token: token,
                shouldCancel: shouldCancel
            )
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        kind token: String,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        guard !token.isEmpty else { return nil }
        var candidates: [Int32] = []
        candidates.reserveCapacity(snapshot.resultCount)

        for rowID in 0..<snapshot.count {
            if rowID & 511 == 0, shouldCancel() {
                return nil
            }
            guard snapshot.store.isResultRow(at: rowID) else { continue }

            if snapshot.store.isDirectory(at: rowID) {
                if "folder".hasPrefix(token) || "directory".hasPrefix(token) || "dir".hasPrefix(token) {
                    candidates.append(Int32(rowID))
                }
            } else if "file".hasPrefix(token) {
                candidates.append(Int32(rowID))
            }
        }

        return candidates
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        token: String,
        mode: FuzzyMatcher.MatchMode,
        allowsFuzzyPrefix: Bool,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        switch mode {
        case .exact:
            return pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: token,
                shouldCancel: shouldCancel
            )
        case .wildcard:
            return candidateIndices(
                snapshot: snapshot,
                requiredFragments: wildcardRequiredFragments(from: token),
                field: .path,
                shouldCancel: shouldCancel
            )
        case .fuzzy:
            guard allowsFuzzyPrefix else {
                return nil
            }
            return pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: token,
                shouldCancel: shouldCancel
            )
        }
    }

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        requiredFragments fragments: [[UInt8]],
        field: FuzzyMatcher.QueryField,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        guard !fragments.isEmpty else {
            return nil
        }

        var candidates: [Int32]?

        for fragment in fragments {
            guard let fragmentCandidates = candidateIndices(
                snapshot: snapshot,
                fragment: fragment,
                field: field,
                shouldCancel: shouldCancel
            ) else {
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

    private static func candidateIndices(
        snapshot: SearchSnapshot,
        fragment: [UInt8],
        field: FuzzyMatcher.QueryField,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        switch field {
        case .name:
            return snapshot.candidateNameIndices(containing: fragment)
        case .path:
            return pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: String(decoding: fragment, as: UTF8.self),
                shouldCancel: shouldCancel
            )
        case .any:
            guard let nameCandidates = snapshot.candidateNameIndices(containing: fragment) else {
                return nil
            }
            guard let pathCandidates = pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: String(decoding: fragment, as: UTF8.self),
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            return unionPostingLists(pathCandidates, nameCandidates)
        }
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

    private static func exactTextCandidateIndices(
        snapshot: SearchSnapshot,
        field: FuzzyMatcher.QueryField,
        token: String,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        let tokenBytes = Array(token.utf8)
        switch field {
        case .name:
            return snapshot.candidateNameIndices(containing: tokenBytes)
        case .path:
            return pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: token,
                shouldCancel: shouldCancel
            )
        case .any:
            guard let nameCandidates = snapshot.candidateNameIndices(containing: tokenBytes) else {
                return nil
            }
            guard let pathCandidates = pathSubstringCandidateIndices(
                snapshot: snapshot,
                token: token,
                shouldCancel: shouldCancel
            ) else {
                return nil
            }
            return unionPostingLists(pathCandidates, nameCandidates)
        }
    }

    private static func pathSubstringCandidateIndices(
        snapshot: SearchSnapshot,
        token: String,
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        let tokenBytes = Array(token.utf8)
        if let candidates = snapshot.candidatePathIndices(containing: tokenBytes) {
            return candidates
        }

        if let candidates = snapshot.candidatePathIndicesByComponentExpansion(
            containing: token,
            shouldCancel: shouldCancel
        ) {
            return candidates
        }

        guard tokenBytes.count > 3 else {
            return nil
        }

        guard snapshot.store.schemaVersion < SnapshotLayout.schemaVersion else {
            return nil
        }

        return snapshot.candidatePathIndicesByScanning(
            containing: token,
            shouldCancel: shouldCancel
        )
    }

    private static func fuzzyTextCandidateIndices(
        snapshot: SearchSnapshot,
        field: FuzzyMatcher.QueryField,
        token: String,
        shouldCancel: @Sendable () -> Bool
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
            return fuzzyPathCandidateIndices(
                snapshot: snapshot,
                token: token,
                tokenBytes: tokenBytes,
                shouldCancel: shouldCancel
            )
        case .any:
            guard
                let nameCandidates,
                let pathCandidates = fuzzyPathCandidateIndices(
                    snapshot: snapshot,
                    token: token,
                    tokenBytes: tokenBytes,
                    shouldCancel: shouldCancel
                )
            else {
                return nil
            }
            return unionPostingLists(pathCandidates, nameCandidates)
        }
    }

    private static func fuzzyNameCandidateIndices(snapshot: SearchSnapshot, tokenBytes: [UInt8]) -> [Int32]? {
        let distinctBytes = distinctBytes(in: tokenBytes)
        guard !distinctBytes.isEmpty else {
            return nil
        }

        let allowedMissing = tokenBytes.count <= 5 ? 1 : 2
        let requiredCount = max(1, distinctBytes.count - allowedMissing)
        guard requiredCount >= 2 else {
            return snapshot.candidateNameIndices(containingAllBytes: distinctBytes)
        }

        guard requiredCount < distinctBytes.count else {
            return snapshot.candidateNameIndices(containingAllBytes: distinctBytes)
        }

        let requiredSubsets = byteSubsets(distinctBytes, count: requiredCount)
        guard !requiredSubsets.isEmpty, requiredSubsets.count <= 256 else {
            return nil
        }

        return snapshot.candidateNameIndices(containingAny: requiredSubsets)
    }

    private static func fuzzyPathCandidateIndices(
        snapshot: SearchSnapshot,
        token: String,
        tokenBytes: [UInt8],
        shouldCancel: @Sendable () -> Bool
    ) -> [Int32]? {
        guard !tokenBytes.isEmpty else {
            return nil
        }

        if tokenBytes.count <= 3 {
            let distinctBytes = distinctBytes(in: tokenBytes)
            guard !distinctBytes.isEmpty else {
                return nil
            }
            if let candidates = snapshot.candidatePathIndices(containingAllBytes: distinctBytes) {
                return candidates
            }
            return snapshot.candidatePathIndicesByShortFuzzyComponentExpansion(
                containing: tokenBytes,
                shouldCancel: shouldCancel
            )
        }

        return pathSubstringCandidateIndices(
            snapshot: snapshot,
            token: token,
            shouldCancel: shouldCancel
        )
    }

    private static func distinctBytes(in bytes: [UInt8]) -> [UInt8] {
        var seen = Set<UInt8>()
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)

        for byte in bytes where seen.insert(byte).inserted {
            result.append(byte)
        }

        return result
    }

    private static func shortFuzzyPathComponentMatches(_ text: String, tokenBytes: [UInt8]) -> Bool {
        guard !tokenBytes.isEmpty else { return false }

        var tokenIndex = 0
        for byte in text.utf8 {
            if isBoundaryByte(byte) {
                tokenIndex = 0
                continue
            }

            if byte == tokenBytes[tokenIndex] {
                tokenIndex += 1
                if tokenIndex == tokenBytes.count {
                    return true
                }
            }
        }

        return false
    }

    private static func shortFuzzyNameMatches(_ text: String, tokenBytes: [UInt8]) -> Bool {
        guard !tokenBytes.isEmpty else { return false }
        if bytesContainSubsequence(text.utf8, tokenBytes: tokenBytes) {
            return true
        }

        var component: [UInt8] = []
        component.reserveCapacity(min(text.utf8.count, 32))

        func componentHasTypoMatch() -> Bool {
            guard abs(component.count - tokenBytes.count) <= 1 else {
                return false
            }
            return boundedByteLevenshtein(component, tokenBytes, limit: 1) != nil
        }

        for byte in text.utf8 {
            if isBoundaryByte(byte) {
                if componentHasTypoMatch() {
                    return true
                }
                component.removeAll(keepingCapacity: true)
            } else {
                component.append(byte)
            }
        }

        return componentHasTypoMatch()
    }

    private static func bytesContainSubsequence(_ bytes: String.UTF8View, tokenBytes: [UInt8]) -> Bool {
        var tokenIndex = 0
        for byte in bytes where byte == tokenBytes[tokenIndex] {
            tokenIndex += 1
            if tokenIndex == tokenBytes.count {
                return true
            }
        }
        return false
    }

    private static func boundedByteLevenshtein(_ lhs: [UInt8], _ rhs: [UInt8], limit: Int) -> Int? {
        guard abs(lhs.count - rhs.count) <= limit else { return nil }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for row in 1...lhs.count {
            current[0] = row
            var rowMinimum = current[0]

            for column in 1...rhs.count {
                let cost = lhs[row - 1] == rhs[column - 1] ? 0 : 1
                current[column] = min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[column])
            }

            if rowMinimum > limit {
                return nil
            }

            swap(&previous, &current)
        }

        let distance = previous[rhs.count]
        return distance <= limit ? distance : nil
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
        cleanupObsoleteIndexFiles()
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

        let metrics = RecordCollectionMetrics(recordCount: persisted.store.count, totalPathBytes: 0, maxPathBytes: 0)
        let snapshot = SearchSnapshot(store: persisted.store, persistedStructures: persisted.searchStructures)
        let loadedOptimized = snapshot.isOptimizedForSearch
        MemoryTelemetry.log(
            "snapshot.load.mapped",
            records: metrics,
            structures: snapshot.diagnostics,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        let didApply = lock.withLock { () -> Bool in
            guard generation == generationAtStart else {
                return false
            }

            guard persisted.manifest.exclusionPatterns == exclusionRules.patterns else {
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

            self.recordsByPath.removeAll(keepingCapacity: false)
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            roots = persisted.manifest.roots
            snapshotLoadState = .finished
            phase = .ready
            status = "Loaded \(snapshot.resultCount) indexed files"
            indexing = false
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = loadedOptimized ? snapshot.resultCount : 0
            lastUpdated = persisted.manifest.savedAt
            return true
        }

        if didApply {
            publishStats()
            MemoryTelemetry.log(
                "snapshot.load.applied",
                records: metrics,
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )

            if !loadedOptimized {
                indexQueue.async { [weak self] in
                    self?.optimizeLoadedSnapshot(generation: generationAtStart)
                }
            }
        }
    }

    private func rebuild(roots rootURLs: [URL], generation currentGeneration: UInt64, started: Date) {
        let jobID = beginIndexJob("rebuild")
        defer { endIndexJob("rebuild", jobID: jobID) }

        let exclusions = lock.withLock { exclusionRules }
        let publishPrimary: @Sendable (_ store: HeapPagedRecordStore, _ visited: Int, _ force: Bool) -> Void = { [weak self] store, visited, _ in
            self?.publishPrimarySnapshot(store, visited: visited, generation: currentGeneration)
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
        publishPrimary(scanResult.store, scanResult.visited, true)
        optimizeAndPublish(recordsByPath: scanResult.records, initialStore: scanResult.store, generation: currentGeneration)
        guard isCurrentGeneration(currentGeneration) else { return }
        recordFullRebuild(duration: Date().timeIntervalSince(started))
    }

    private func scanConcurrently(
        roots rootURLs: [URL],
        exclusions: FileExclusionRules,
        generation currentGeneration: UInt64,
        progress: @escaping @Sendable (_ store: HeapPagedRecordStore, _ visited: Int, _ force: Bool) -> Void
    ) -> ScanResult? {
        let rootPaths = rootURLs.map(\.path)
        let currentCount = lock.withLock { searchSnapshot.count }
        let state = ConcurrentScanState(reservedCapacity: max(8_192, currentCount))

        let publish: @Sendable (_ result: ScanProgress?, _ force: Bool) -> Void = { result, force in
            guard let result else { return }
            progress(result.store, result.visited, force)
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

    private func publishPrimarySnapshot(_ store: HeapPagedRecordStore, visited: Int, generation currentGeneration: UInt64) {
        let snapshot = SearchSnapshot(store: store, buildsSearchStructures: false)
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = true
            phase = .scanning
            discoveredCount = visited
            searchableCount = snapshot.resultCount
            optimizedCount = 0
            status = "Indexing \(visited.formatted()) discovered"
            lastUpdated = Date()
            return true
        }

        guard didApply else { return }
        publishStats()

        if snapshot.count.isMultiple(of: Self.primaryPublishRecordInterval) {
            MemoryTelemetry.log(
                "rebuild.primary.applied",
                records: Self.metrics(for: snapshot.store),
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
        }
    }

    private func optimizeAndPublish(recordsByPath: [String: FileRecord], initialStore: HeapPagedRecordStore, generation currentGeneration: UInt64) {
        let records = Array(recordsByPath.values)
        var snapshot = SearchSnapshot(store: initialStore, buildsSearchStructures: false)
        var pendingMappedPackageURL: URL?

        guard isCurrentGeneration(currentGeneration) else { return }
        publishRebuildStatus(
            phase: .optimizing,
            status: "Optimizing compact store",
            discovered: records.count,
            searchable: records.count,
            optimized: 0,
            isIndexing: true,
            generation: currentGeneration
        )

        do {
            let packageURL = SnapshotLayout.temporaryPackageURL(in: supportDirectory)
            let snapshotSettings = lock.withLock {
                (
                    roots: roots,
                    exclusionPatterns: exclusionRules.patterns
                )
            }
            try MappedRecordStore.writePackage(
                records: records,
                roots: snapshotSettings.roots,
                exclusionPatterns: snapshotSettings.exclusionPatterns,
                packageURL: packageURL,
                fileManager: fileManager
            )
            let mappedStore = try MappedRecordStore(packageURL: packageURL, schemaVersion: SnapshotLayout.schemaVersion)
            pendingMappedPackageURL = packageURL
            snapshot = SearchSnapshot(store: mappedStore, buildsSearchStructures: false)
            publishOptimizedSnapshot(
                snapshot,
                status: "Optimizing names",
                optimized: 0,
                generation: currentGeneration
            )
        } catch {
            failIndexing("Could not build compact index: \(error.localizedDescription)", generation: currentGeneration)
            return
        }

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
            optimized: snapshot.resultCount,
            generation: currentGeneration
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        publishRebuildStatus(
            phase: .saving,
            status: "Saving index",
            discovered: records.count,
            searchable: snapshot.resultCount,
            optimized: snapshot.resultCount,
            isIndexing: true,
            generation: currentGeneration
        )
        if let pendingMappedPackageURL {
            do {
                try persistSearchStructures(for: snapshot, packageURL: pendingMappedPackageURL)
            } catch {
                failIndexing("Could not save optimized search index: \(error.localizedDescription)", generation: currentGeneration)
                return
            }

            guard installMappedSnapshotPackage(pendingMappedPackageURL, generation: currentGeneration) else { return }
        } else {
            guard persistSnapshot() else { return }
        }

        let didFinish = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            self.recordsByPath.removeAll(keepingCapacity: false)
            indexing = false
            phase = .ready
            discoveredCount = records.count
            searchableCount = snapshot.resultCount
            optimizedCount = snapshot.resultCount
            status = "Indexed \(records.count.formatted()) files"
            lastUpdated = Date()
            completedSnapshotRebuilds &+= 1
            return true
        }

        if didFinish {
            publishStats()
            MemoryTelemetry.log(
                "rebuild.optimized.applied",
                records: Self.metrics(for: snapshot.store),
                structures: snapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
        }
    }

    private func optimizeLoadedSnapshot(generation currentGeneration: UInt64) {
        let jobID = beginIndexJob("optimizeLoadedSnapshot")
        defer { endIndexJob("optimizeLoadedSnapshot", jobID: jobID) }

        var snapshot = lock.withLock { searchSnapshot }
        guard !snapshot.isOptimizedForSearch, snapshot.count > 0, isCurrentGeneration(currentGeneration) else {
            return
        }

        publishOptimizedSnapshot(
            snapshot,
            status: "Optimizing names",
            optimized: 0,
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

        do {
            try persistSearchStructures(for: snapshot, packageURL: snapshotURL)
        } catch {
            failIndexing("Could not save optimized search index: \(error.localizedDescription)", generation: currentGeneration)
            return
        }

        let didFinish = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            indexing = false
            phase = .ready
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = snapshot.resultCount
            status = "Loaded \(snapshot.resultCount) indexed files"
            lastUpdated = Date()
            return true
        }

        if didFinish {
            publishStats()
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
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = optimized
            self.status = status
            lastUpdated = Date()
            return true
        }

        if didApply {
            recordIndexingFailure()
            publishStats()
        }
    }

    private func installMappedSnapshotPackage(_ packageURL: URL, generation currentGeneration: UInt64) -> Bool {
        guard isCurrentGeneration(currentGeneration) else {
            try? fileManager.removeItem(at: packageURL)
            return false
        }

        do {
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try fileManager.removeItem(at: snapshotURL)
            }
            try fileManager.moveItem(at: packageURL, to: snapshotURL)
            cleanupObsoleteIndexFiles()
            return true
        } catch {
            failIndexing("Could not install compact index: \(error.localizedDescription)", generation: currentGeneration)
            return false
        }
    }

    private func failIndexing(_ message: String, generation currentGeneration: UInt64) {
        let didApply = lock.withLock { () -> Bool in
            guard generation == currentGeneration else {
                return false
            }

            indexing = false
            phase = .failed
            status = message
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
        guard !lock.withLock({ indexing }) else {
            return
        }

        let refreshStarted = Date()
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
            recordIncrementalRefresh(duration: Date().timeIntervalSince(refreshStarted))
            return
        }

        let previousSnapshot = lock.withLock { searchSnapshot }
        var deletedRows = Set<Int>()

        if
            deletedPrefixes.isEmpty,
            shallowDirectoryChildren.isEmpty,
            let updatedSnapshot = previousSnapshot.updatingMetadata(for: upserts)
        {
            let changedPathCount = upserts.count
            lock.withLock {
                searchSnapshot = updatedSnapshot
                searchSnapshotRevision &+= 1
                status = "Updated \(changedPathCount) changed path\(changedPathCount == 1 ? "" : "s")"
                phase = .ready
                indexing = false
                discoveredCount = updatedSnapshot.resultCount
                searchableCount = updatedSnapshot.resultCount
                optimizedCount = updatedSnapshot.isOptimizedForSearch ? updatedSnapshot.resultCount : 0
                recordsByPath.removeAll(keepingCapacity: false)
                lastUpdated = Date()
                completedRefreshBatches &+= 1
            }

            publishStats()
            schedulePersist()
            MemoryTelemetry.log(
                "refresh.metadataApplied",
                records: RecordCollectionMetrics(recordCount: updatedSnapshot.count, totalPathBytes: 0, maxPathBytes: 0),
                structures: updatedSnapshot.diagnostics,
                refreshBatchSize: paths.count,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            return
        }

        for path in upserts.keys {
            if let rowID = previousSnapshot.store.rowID(forPath: path) {
                deletedRows.insert(rowID)
            }
        }

        if !deletedPrefixes.isEmpty || !shallowDirectoryChildren.isEmpty {
            for rowID in 0..<previousSnapshot.count {
                guard !deletedRows.contains(rowID) else { continue }
                let view = previousSnapshot.view(at: rowID)

                if deletedPrefixes.contains(where: { view.path == $0 || view.path.hasPrefix($0 + "/") }) {
                    deletedRows.insert(rowID)
                    continue
                }

                for (directory, currentChildren) in shallowDirectoryChildren where view.directoryPath == directory && !currentChildren.contains(view.path) {
                    deletedRows.insert(rowID)
                }
            }
        }

        let overlayStore = OverlayRecordStore(
            base: previousSnapshot.store,
            upserts: Array(upserts.values),
            deletedRows: deletedRows
        )
        let snapshot = SearchSnapshot(store: overlayStore, buildsSearchStructures: previousSnapshot.isOptimizedForSearch)
        let changedPathCount = upserts.count + deletedPrefixes.count

        lock.withLock {
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            status = "Updated \(changedPathCount) changed path\(changedPathCount == 1 ? "" : "s")"
            phase = .ready
            indexing = false
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = snapshot.isOptimizedForSearch ? snapshot.resultCount : 0
            recordsByPath.removeAll(keepingCapacity: false)
            lastUpdated = Date()
            completedRefreshBatches &+= 1
        }

        publishStats()
        schedulePersist()
        MemoryTelemetry.log(
            "refresh.overlayApplied",
            records: RecordCollectionMetrics(recordCount: snapshot.count, totalPathBytes: 0, maxPathBytes: 0),
            structures: snapshot.diagnostics,
            refreshBatchSize: paths.count,
            activeIndexJobs: currentActiveIndexJobCount()
        )
        recordIncrementalRefresh(duration: Date().timeIntervalSince(refreshStarted))
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
            discoveredCount = snapshot.resultCount
            searchableCount = snapshot.resultCount
            optimizedCount = isIndexing ? 0 : snapshot.resultCount
            self.status = status
            lastUpdated = Date()
            if !isIndexing {
                completedSnapshotRebuilds &+= 1
            }
        }
        publishStats()

        MemoryTelemetry.log(
            isIndexing ? "snapshot.partial.applied" : "snapshot.final.applied",
            records: Self.metrics(for: snapshot.store),
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
                snapshot: searchSnapshot
            )
        }

        let jobID = beginIndexJob("persist")
        defer { endIndexJob("persist", jobID: jobID) }

        let metrics = Self.metrics(for: snapshotData.snapshot.store)
        MemoryTelemetry.log(
            "snapshot.persist.begin",
            records: metrics,
            structures: lock.withLock { searchSnapshot.diagnostics },
            activeIndexJobs: currentActiveIndexJobCount()
        )

        do {
            let mappedStore = try persistMappedSnapshot(
                roots: snapshotData.roots,
                exclusionPatterns: snapshotData.exclusionPatterns,
                store: snapshotData.snapshot.store
            )
            let persistedSnapshot = SearchSnapshot(
                store: mappedStore,
                buildsSearchStructures: snapshotData.snapshot.isOptimizedForSearch
            )
            try persistSearchStructures(for: persistedSnapshot, packageURL: snapshotURL)
            MemoryTelemetry.log(
                "snapshot.persist.finished",
                records: metrics,
                structures: persistedSnapshot.diagnostics,
                activeIndexJobs: currentActiveIndexJobCount()
            )
            if snapshotData.snapshot.store.kind == .overlay || snapshotData.snapshot.store.kind == .heapPaged {
                lock.withLock {
                    searchSnapshot = persistedSnapshot
                    searchSnapshotRevision &+= 1
                    recordsByPath.removeAll(keepingCapacity: false)
                    discoveredCount = persistedSnapshot.resultCount
                    searchableCount = persistedSnapshot.resultCount
                    optimizedCount = persistedSnapshot.isOptimizedForSearch ? persistedSnapshot.resultCount : 0
                    lastUpdated = Date()
                }
                publishStats()
            }
            return true
        } catch {
            lock.withLock {
                phase = .failed
                indexing = false
                status = "Could not persist index: \(error.localizedDescription)"
                lastUpdated = Date()
            }
            recordPersistFailure()
            publishStats()
            return false
        }
    }

    private func persistMappedSnapshot(roots: [String], exclusionPatterns: [String], store: RecordStore) throws -> MappedRecordStore {
        cleanupStaleTemporaryFiles()
        let temporaryURL = SnapshotLayout.temporaryPackageURL(in: supportDirectory)
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try MappedRecordStore.writePackage(
            records: store.allRecords(),
            roots: roots,
            exclusionPatterns: exclusionPatterns,
            packageURL: temporaryURL,
            fileManager: fileManager
        )

        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
        cleanupObsoleteIndexFiles()
        return try MappedRecordStore(packageURL: snapshotURL, schemaVersion: SnapshotLayout.schemaVersion)
    }

    private func persistSearchStructures(for snapshot: SearchSnapshot, packageURL: URL) throws {
        let modifiedOrderURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.modifiedOrder, isDirectory: false)
        if snapshot.hasSortedOrder {
            try CompactSearchStructureFiles.writeModifiedOrder(
                snapshot.modifiedDescending,
                to: modifiedOrderURL
            )
        } else {
            try Data().write(to: modifiedOrderURL, options: .atomic)
        }

        let visibleModifiedOrderURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.visibleModifiedOrder, isDirectory: false)
        if snapshot.hasSortedOrder {
            try CompactSearchStructureFiles.writeModifiedOrder(
                snapshot.visibleModifiedDescending,
                to: visibleModifiedOrderURL
            )
        } else {
            try Data().write(to: visibleModifiedOrderURL, options: .atomic)
        }

        let namePostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.namePostings, isDirectory: false)
        if let nameGramIndex = snapshot.nameGramIndex {
            try nameGramIndex.write(to: namePostingsURL)
        } else {
            try Data().write(to: namePostingsURL, options: .atomic)
        }

        let componentPostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings, isDirectory: false)
        if let componentGramIndex = snapshot.componentGramIndex {
            try componentGramIndex.write(to: componentPostingsURL)
        } else {
            try Data().write(to: componentPostingsURL, options: .atomic)
        }

        let pathPostingsURL = packageURL.appendingPathComponent(SnapshotLayout.FileName.pathPostings, isDirectory: false)
        if let gramIndex = snapshot.gramIndex {
            try gramIndex.write(to: pathPostingsURL)
        } else {
            try Data().write(to: pathPostingsURL, options: .atomic)
        }
    }

    private func loadPersistedSnapshot() -> LoadedMappedSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return nil
        }
        do {
            let manifestURL = snapshotURL.appendingPathComponent(SnapshotLayout.FileName.manifest, isDirectory: false)
            let manifest = try JSONDecoder().decode(CompactSnapshotManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == SnapshotLayout.schemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let store = try MappedRecordStore(packageURL: snapshotURL, schemaVersion: manifest.schemaVersion)
            guard store.count == manifest.recordCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let searchStructures = loadPersistedSearchStructures(packageURL: snapshotURL, store: store) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return LoadedMappedSnapshot(
                manifest: manifest,
                store: store,
                searchStructures: searchStructures
            )
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            recordSnapshotLoadFailure(corruptSnapshotRemoved: true)
            MemoryTelemetry.log("snapshot.load.failed", activeIndexJobs: currentActiveIndexJobCount())
            return nil
        }
    }

    private func loadPersistedSearchStructures(packageURL: URL, store: MappedRecordStore) -> PersistedSearchStructures? {
        guard let modifiedDescending = CompactSearchStructureFiles.loadModifiedOrder(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.modifiedOrder, isDirectory: false),
            expectedCount: store.storedResultCount ?? store.count,
            rowIDUpperBound: store.count,
            fileManager: fileManager
        ) else {
            return nil
        }
        guard let visibleModifiedDescending = CompactSearchStructureFiles.loadModifiedOrder(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.visibleModifiedOrder, isDirectory: false),
            expectedCount: store.storedVisibleCount ?? 0,
            rowIDUpperBound: store.count,
            fileManager: fileManager
        ) else {
            return nil
        }
        let nameGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.namePostings, isDirectory: false),
            fileManager: fileManager
        )
        let pathGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.pathPostings, isDirectory: false),
            fileManager: fileManager
        )
        let componentGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent(SnapshotLayout.FileName.componentPostings, isDirectory: false),
            fileManager: fileManager
        )

        return PersistedSearchStructures(
            modifiedDescending: modifiedDescending,
            visibleModifiedDescending: visibleModifiedDescending,
            nameGramIndex: nameGramIndex ?? nil,
            componentGramIndex: componentGramIndex ?? nameGramIndex ?? nil,
            pathGramIndex: pathGramIndex ?? nil
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
        var removedCount: UInt64 = 0
        for url in contents {
            let name = url.lastPathComponent
            let isTemporary = name.hasPrefix(".dat.nosync")
                || SnapshotLayout.isCurrentTemporaryPackageName(name)
            guard isTemporary else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard minimumAge <= 0 || now.timeIntervalSince(modified) >= minimumAge else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removedCount &+= 1
            }
        }

        if removedCount > 0 {
            recordTempCleanup(count: removedCount)
        }
    }

    private func cleanupObsoleteIndexFiles() {
        var removedCount: UInt64 = 0
        for name in SnapshotLayout.obsoletePackageNames + SnapshotLayout.obsoleteFileNames {
            if (try? fileManager.removeItem(at: supportDirectory.appendingPathComponent(name))) != nil {
                removedCount &+= 1
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: supportDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }

        for url in contents {
            let name = url.lastPathComponent
            if SnapshotLayout.isObsoleteTemporaryName(name) {
                if (try? fileManager.removeItem(at: url)) != nil {
                    removedCount &+= 1
                }
            }
        }

        if removedCount > 0 {
            recordTempCleanup(count: removedCount)
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

    private static func metrics(for store: RecordStore) -> RecordCollectionMetrics {
        var totalPathBytes = 0
        var maxPathBytes = 0

        for rowID in 0..<store.count {
            let pathBytes = store.path(at: rowID).utf8.count
            totalPathBytes += pathBytes
            maxPathBytes = max(maxPathBytes, pathBytes)
        }

        return RecordCollectionMetrics(recordCount: store.count, totalPathBytes: totalPathBytes, maxPathBytes: maxPathBytes)
    }

    private func beginIndexJob(_ name: String) -> Int {
        let activeJobs = lock.withLock { () -> Int in
            activeIndexJobs += 1
            usageMetrics.recordActiveJobHighWaterMark(activeIndexJobs)
            return activeIndexJobs
        }
        saveUsageMetricsSnapshot()
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
            currentDiagnosticsWithoutLock()
        }
    }

    private func currentDiagnosticsWithoutLock() -> FileIndexDiagnostics {
        FileIndexDiagnostics(
            indexedCount: searchSnapshot.resultCount,
            snapshotRevision: searchSnapshotRevision,
            phase: phase,
            discoveredCount: discoveredCount,
            searchableCount: searchableCount,
            optimizedCount: optimizedCount,
            recordStoreKind: searchSnapshot.store.kind,
            mappedByteSize: searchSnapshot.store.mappedByteSize,
            heapPageCount: searchSnapshot.store.heapPageCount,
            overlayCount: searchSnapshot.store.overlayCount,
            columnarSidecarsLoaded: searchSnapshot.store.hasColumnarSidecars,
            visibleCount: searchSnapshot.visibleCount,
            visibleModifiedOrderCount: searchSnapshot.visibleModifiedDescending.count,
            simdTextVerificationEnabled: searchSnapshot.diagnostics.simdTextVerificationEnabled,
            pathGramIndexEnabled: searchSnapshot.diagnostics.pathGramIndexEnabled,
            pathGramKeyCount: searchSnapshot.diagnostics.pathGramKeyCount,
            pathGramPostingCount: searchSnapshot.diagnostics.pathGramPostingCount,
            nameGramKeyCount: searchSnapshot.diagnostics.nameGramKeyCount,
            nameGramPostingCount: searchSnapshot.diagnostics.nameGramPostingCount,
            componentGramKeyCount: searchSnapshot.diagnostics.componentGramKeyCount,
            componentGramPostingCount: searchSnapshot.diagnostics.componentGramPostingCount,
            extensionKeyCount: searchSnapshot.diagnostics.extensionKeyCount,
            extensionPostingCount: searchSnapshot.diagnostics.extensionPostingCount,
            completedRefreshBatches: completedRefreshBatches,
            completedSnapshotRebuilds: completedSnapshotRebuilds,
            activeIndexJobs: activeIndexJobs,
            schemaVersion: searchSnapshot.store.schemaVersion,
            resultCount: searchSnapshot.resultCount,
            virtualRowCount: searchSnapshot.virtualRowCount,
            fallbackScanCount: fallbackScanCount,
            scannedRowCount: scannedRowCount,
            pathMaterializationCount: pathMaterializationCount
        )
    }

    private func currentHealthDiagnosticsWithoutLock() -> IndexHealthDiagnostics {
        IndexHealthDiagnostics(
            phase: phase,
            status: status,
            activeIndexJobs: activeIndexJobs,
            activeIndexJobHighWaterMark: usageMetrics.health.activeJobHighWaterMark,
            schemaVersion: searchSnapshot.store.schemaVersion,
            snapshotRevision: searchSnapshotRevision,
            recordStoreKind: searchSnapshot.store.kind.rawValue,
            mappedByteSize: searchSnapshot.store.mappedByteSize,
            heapPageCount: searchSnapshot.store.heapPageCount,
            overlayCount: searchSnapshot.store.overlayCount,
            columnarSidecarsLoaded: searchSnapshot.store.hasColumnarSidecars,
            resultCount: searchSnapshot.resultCount,
            virtualRowCount: searchSnapshot.virtualRowCount,
            visibleCount: searchSnapshot.visibleCount,
            pathGramIndexEnabled: searchSnapshot.diagnostics.pathGramIndexEnabled,
            nameGramKeyCount: searchSnapshot.diagnostics.nameGramKeyCount,
            componentGramKeyCount: searchSnapshot.diagnostics.componentGramKeyCount,
            pathGramKeyCount: searchSnapshot.diagnostics.pathGramKeyCount,
            extensionKeyCount: searchSnapshot.diagnostics.extensionKeyCount,
            completedRefreshBatches: completedRefreshBatches,
            completedSnapshotRebuilds: completedSnapshotRebuilds,
            fallbackScanCount: fallbackScanCount,
            scannedRowCount: scannedRowCount,
            pathMaterializationCount: pathMaterializationCount,
            canClearCachedIndex: activeIndexJobs == 0 && !indexing && snapshotLoadState != .loading
        )
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
                searchableCount = snapshot.resultCount
                optimizedCount = buildsSearchStructures ? snapshot.resultCount : 0
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
                    indexedCount: searchSnapshot.resultCount,
                    isIndexing: indexing,
                    isLoadingSnapshot: snapshotLoadState == .loading,
                    phase: phase,
                    discoveredCount: discoveredCount,
                    searchableCount: searchableCount,
                    optimizedCount: optimizedCount,
                    snapshotRevision: searchSnapshotRevision,
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
            lockedStatsWithoutLock()
        }
    }

    private func lockedStatsWithoutLock() -> IndexStats {
        IndexStats(
            indexedCount: searchSnapshot.resultCount,
            isIndexing: indexing,
            isLoadingSnapshot: snapshotLoadState == .loading,
            phase: phase,
            discoveredCount: discoveredCount,
            searchableCount: searchableCount,
            optimizedCount: optimizedCount,
            snapshotRevision: searchSnapshotRevision,
            status: status,
            lastUpdated: lastUpdated
        )
    }

    private func recordSearchStarted() {
        updateUsageMetrics { metrics in
            metrics.recordSearchStarted()
        }
    }

    private func recordSearchCompleted(_ profile: SearchExecutionProfile) {
        updateUsageMetrics { metrics in
            metrics.recordSearchCompleted(profile)
        }
    }

    private func recordSearchCancelled(elapsed: TimeInterval) {
        updateUsageMetrics { metrics in
            metrics.recordSearchCancelled(elapsed: elapsed)
        }
    }

    private func recordFullRebuild(duration: TimeInterval) {
        updateUsageMetrics { metrics in
            metrics.recordFullRebuild(duration: duration)
        }
    }

    private func recordIncrementalRefresh(duration: TimeInterval) {
        updateUsageMetrics { metrics in
            metrics.recordIncrementalRefresh(duration: duration)
        }
    }

    private func recordIndexingFailure() {
        updateUsageMetrics { metrics in
            metrics.recordIndexingFailure()
        }
    }

    private func recordSnapshotLoadFailure(corruptSnapshotRemoved: Bool) {
        updateUsageMetrics { metrics in
            metrics.recordSnapshotLoadFailure(corruptSnapshotRemoved: corruptSnapshotRemoved)
        }
    }

    private func recordPersistFailure() {
        updateUsageMetrics { metrics in
            metrics.recordPersistFailure()
        }
    }

    private func recordTempCleanup(count: UInt64) {
        updateUsageMetrics { metrics in
            metrics.recordTempCleanup(count: count)
        }
    }

    private func updateUsageMetrics(_ body: (inout IndexUsageMetrics) -> Void) {
        let metrics = lock.withLock { () -> IndexUsageMetrics in
            body(&usageMetrics)
            usageMetrics.schemaVersion = IndexUsageMetrics.currentSchemaVersion
            return usageMetrics
        }
        Self.saveUsageMetrics(metrics, to: metricsURL, fileManager: fileManager)
    }

    private func saveUsageMetricsSnapshot() {
        let metrics = lock.withLock { usageMetrics }
        Self.saveUsageMetrics(metrics, to: metricsURL, fileManager: fileManager)
    }

    private static func loadUsageMetrics(from url: URL, fileManager: FileManager) -> IndexUsageMetrics {
        guard
            fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            var metrics = try? JSONDecoder().decode(IndexUsageMetrics.self, from: data),
            metrics.schemaVersion == IndexUsageMetrics.currentSchemaVersion
        else {
            return IndexUsageMetrics(schemaVersion: IndexUsageMetrics.currentSchemaVersion)
        }

        metrics.pruneDailyBuckets()
        return metrics
    }

    private static func saveUsageMetrics(_ metrics: IndexUsageMetrics, to url: URL, fileManager: FileManager) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metrics)
            try data.write(to: url, options: .atomic)
        } catch {
            MemoryTelemetry.log("metrics.save.failed")
        }
    }

    private func removePersistedIndexFiles() throws {
        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }

        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: supportDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        else {
            return
        }

        for url in contents where SnapshotLayout.isCurrentTemporaryPackageName(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
        cleanupObsoleteIndexFiles()
    }

    private static func rootInsights(
        snapshot: SearchSnapshot,
        roots: [String],
        estimatedIndexBytes: UInt64
    ) -> [IndexRootInsight] {
        guard !roots.isEmpty else { return [] }

        struct MutableRootInsight {
            var trackedFileCount = 0
            var directoryCount = 0
            var hiddenCount = 0
            var indexedContentBytes: UInt64 = 0
            var pathByteWeight: UInt64 = 0
        }

        let normalizedRoots = roots
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
            .sorted { $0.count > $1.count }
        var values = Dictionary(uniqueKeysWithValues: normalizedRoots.map { ($0, MutableRootInsight()) })

        for rowID in 0..<snapshot.count {
            guard snapshot.store.isResultRow(at: rowID) else { continue }
            let path = snapshot.store.path(at: rowID)
            guard let root = normalizedRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                continue
            }

            if snapshot.store.isDirectory(at: rowID) {
                values[root, default: MutableRootInsight()].directoryCount += 1
            } else {
                values[root, default: MutableRootInsight()].trackedFileCount += 1
                values[root, default: MutableRootInsight()].indexedContentBytes &+= snapshot.store.sizeBytes(at: rowID)
            }
            if snapshot.store.isHidden(at: rowID) {
                values[root, default: MutableRootInsight()].hiddenCount += 1
            }
            values[root, default: MutableRootInsight()].pathByteWeight &+= UInt64(path.utf8.count)
        }

        let totalWeight = values.values.reduce(UInt64(0)) { $0 &+ $1.pathByteWeight }
        return roots.map { root in
            let path = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
            let value = values[path] ?? MutableRootInsight()
            let estimatedBytes = totalWeight == 0
                ? 0
                : UInt64((Double(value.pathByteWeight) / Double(totalWeight) * Double(estimatedIndexBytes)).rounded())
            return IndexRootInsight(
                path: path,
                trackedFileCount: value.trackedFileCount,
                directoryCount: value.directoryCount,
                hiddenCount: value.hiddenCount,
                indexedContentBytes: value.indexedContentBytes,
                pathByteWeight: value.pathByteWeight,
                estimatedIndexBytes: estimatedBytes
            )
        }
    }

    private static func storageInsights(
        supportDirectory: URL,
        snapshotURL: URL,
        applicationName: String,
        fileManager: FileManager
    ) -> IndexStorageInsights {
        var locations: [IndexStorageLocationInsight] = []
        var seenPaths = Set<String>()

        func appendLocation(label: String, url: URL) {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted, fileManager.fileExists(atPath: path) else { return }
            locations.append(IndexStorageLocationInsight(
                label: label,
                path: path,
                allocatedBytes: allocatedSize(of: url, fileManager: fileManager)
            ))
        }

        appendLocation(label: "Application Support", url: supportDirectory)

        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let cacheNames = [
            bundleIdentifier,
            "com.gamecoretech.allthethings",
            "com.gamecoretech.AllTheThings",
            applicationName
        ].compactMap { $0 }

        for name in cacheNames {
            if let cachesRoot {
                appendLocation(label: "Caches", url: cachesRoot.appendingPathComponent(name, isDirectory: true))
            }
        }

        let indexPackageBytes = allocatedSize(of: snapshotURL, fileManager: fileManager)
        let totalBytes = locations.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
        let cacheBytes = locations
            .filter { $0.label == "Caches" }
            .reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }

        return IndexStorageInsights(
            totalATTDataBytes: totalBytes,
            indexPackageBytes: indexPackageBytes,
            cacheBytes: cacheBytes,
            locations: locations,
            sidecars: sidecarInsights(in: snapshotURL, fileManager: fileManager)
        )
    }

    private static func sidecarInsights(in packageURL: URL, fileManager: FileManager) -> [IndexSidecarInsight] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: packageURL,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return contents
            .filter { !$0.hasDirectoryPath }
            .map { url in
                IndexSidecarInsight(
                    name: url.lastPathComponent,
                    allocatedBytes: allocatedSize(of: url, fileManager: fileManager)
                )
            }
            .sorted {
                if $0.allocatedBytes != $1.allocatedBytes {
                    return $0.allocatedBytes > $1.allocatedBytes
                }
                return $0.name < $1.name
            }
    }

    private static func allocatedSize(of url: URL, fileManager: FileManager) -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }

        var total: UInt64 = allocatedFileSize(of: url)
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) {
            for case let child as URL in enumerator {
                total &+= allocatedFileSize(of: child)
            }
        }

        return total
    }

    private static func allocatedFileSize(of url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
            return 0
        }

        return UInt64(max(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0, 0))
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

    private static func compare(_ lhs: SearchMatch, _ rhs: SearchMatch, snapshot: SearchSnapshot, sort: SortSpec, queryIsEmpty: Bool) -> Bool {
        compareRecords(
            lhs: snapshot.view(at: lhs.rowID),
            lhsScore: lhs.score,
            lhsMatch: lhs.match,
            rhs: snapshot.view(at: rhs.rowID),
            rhsScore: rhs.score,
            rhsMatch: rhs.match,
            sort: sort,
            queryIsEmpty: queryIsEmpty
        )
    }

    private static func compare(_ lhs: SearchResult, _ rhs: SearchResult, sort: SortSpec, queryIsEmpty: Bool) -> Bool {
        compareRecords(
            lhs: lhs.record,
            lhsScore: lhs.score,
            lhsMatch: lhs.match,
            rhs: rhs.record,
            rhsScore: rhs.score,
            rhsMatch: rhs.match,
            sort: sort,
            queryIsEmpty: queryIsEmpty
        )
    }

    private static func compareRecords<L: SearchRecordReadable, R: SearchRecordReadable>(
        lhs: L,
        lhsScore: Int,
        lhsMatch: MatchExplanation?,
        rhs: R,
        rhsScore: Int,
        rhsMatch: MatchExplanation?,
        sort: SortSpec,
        queryIsEmpty: Bool
    ) -> Bool {
        let ascending = sort.ascending

        func ordered<T: Comparable>(_ left: T, _ right: T) -> Bool? {
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        }

        if !queryIsEmpty {
            let lhsQuality = lhsMatch?.quality ?? MatchQuality(matchClass: .metadata, scoreBin: 0)
            let rhsQuality = rhsMatch?.quality ?? MatchQuality(matchClass: .metadata, scoreBin: 0)
            if lhsQuality != rhsQuality {
                return lhsQuality > rhsQuality
            }
        }

        let primary: Bool?
        switch sort.column {
        case .relevance:
            if queryIsEmpty {
                primary = lhs.modifiedTime == rhs.modifiedTime ? nil : lhs.modifiedTime > rhs.modifiedTime
            } else {
                primary = nil
            }
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
            primary = ordered(lhs.isDirectory ? "Folder" : "File", rhs.isDirectory ? "Folder" : "File")
        case .volume:
            primary = ordered(lhs.volumeName, rhs.volumeName)
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
