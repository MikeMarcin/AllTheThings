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
    public let snapshotRevision: UInt64?
    public let usesIndexedCandidates: Bool

    public init(
        results: [SearchResult],
        totalMatches: Int,
        elapsed: TimeInterval,
        snapshotRevision: UInt64? = nil,
        usesIndexedCandidates: Bool = false
    ) {
        self.results = results
        self.totalMatches = totalMatches
        self.elapsed = elapsed
        self.snapshotRevision = snapshotRevision
        self.usesIndexedCandidates = usesIndexedCandidates
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
    private static let snapshotSchemaVersion = 4
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

    private struct LoadedMappedSnapshot {
        let manifest: CompactSnapshotManifest
        let store: MappedRecordStore
        let searchStructures: PersistedSearchStructures
    }

    private struct PersistedSearchStructures {
        let modifiedDescending: [Int]?
        let nameGramIndex: MappedIntPostingIndex?
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

    private struct SearchMatch {
        let rowID: Int
        let score: Int
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
        let gramIndex: MappedIntPostingIndex?
        let nameGramIndex: MappedIntPostingIndex?
        let extensionIndex: [String: [Int32]]
        let visibleCount: Int?
        let hasSortedOrder: Bool
        let diagnostics: SearchStructureDiagnostics

        var count: Int { store.count }
        var records: [FileRecord] { store.allRecords() }
        var isOptimizedForSearch: Bool {
            count == 0 || (hasSortedOrder && nameGramIndex != nil)
        }

        init(records: [FileRecord], buildsSearchStructures: Bool = true) {
            self.store = HeapPagedRecordStore(records: records)
            if buildsSearchStructures {
                let metrics = FileIndex.metrics(for: store)
                let buildsPathGramIndex = FileIndex.shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes)
                self.gramIndex = buildsPathGramIndex ? Self.makePathGramIndex(store: store) : nil
                self.nameGramIndex = Self.makeNameGramIndex(store: store)
                let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
                self.extensionIndex = extensionData.extensionIndex
                self.visibleCount = extensionData.visibleCount
                let sortedByModified = Self.makeModifiedDescending(store: store)
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
                self.gramIndex = nil
                self.nameGramIndex = nil
                self.extensionIndex = [:]
                self.visibleCount = records.reduce(0) { partial, record in
                    partial + (record.isHidden ? 0 : 1)
                }
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

        init(store: RecordStore, buildsSearchStructures: Bool = true) {
            self.store = store
            if buildsSearchStructures {
                let metrics = FileIndex.metrics(for: store)
                let buildsPathGramIndex = FileIndex.shouldBuildPathGramIndex(recordCount: metrics.recordCount, totalPathBytes: metrics.totalPathBytes)
                self.gramIndex = buildsPathGramIndex ? Self.makePathGramIndex(store: store) : nil
                self.nameGramIndex = Self.makeNameGramIndex(store: store)
                let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
                self.extensionIndex = extensionData.extensionIndex
                self.visibleCount = extensionData.visibleCount
                let sortedByModified = Self.makeModifiedDescending(store: store)
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
                self.gramIndex = nil
                self.nameGramIndex = nil
                self.extensionIndex = [:]
                self.visibleCount = nil
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

        init(store: RecordStore, persistedStructures: PersistedSearchStructures) {
            self.store = store
            self.gramIndex = persistedStructures.pathGramIndex
            self.nameGramIndex = persistedStructures.nameGramIndex
            let extensionData = Self.makeExtensionIndexAndVisibleCount(store: store)
            self.extensionIndex = extensionData.extensionIndex
            self.visibleCount = extensionData.visibleCount

            if let modifiedDescending = persistedStructures.modifiedDescending, modifiedDescending.count == store.count {
                self.modifiedDescending = modifiedDescending
                self.modifiedAscending = Array(modifiedDescending.reversed())
                self.hasSortedOrder = true
            } else {
                self.modifiedDescending = []
                self.modifiedAscending = []
                self.hasSortedOrder = false
            }

            self.diagnostics = Self.makeDiagnostics(
                pathGramIndexEnabled: gramIndex != nil,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                extensionIndex: extensionIndex
            )
        }

        private init(
            store: RecordStore,
            modifiedDescending: [Int],
            gramIndex: MappedIntPostingIndex?,
            nameGramIndex: MappedIntPostingIndex?,
            extensionIndex: [String: [Int32]],
            visibleCount: Int?,
            hasSortedOrder: Bool
        ) {
            self.store = store
            self.modifiedDescending = modifiedDescending
            self.modifiedAscending = Array(modifiedDescending.reversed())
            self.gramIndex = gramIndex
            self.nameGramIndex = nameGramIndex
            self.extensionIndex = extensionIndex
            self.visibleCount = visibleCount
            self.hasSortedOrder = hasSortedOrder
            self.diagnostics = Self.makeDiagnostics(
                pathGramIndexEnabled: gramIndex != nil,
                gramIndex: gramIndex,
                nameGramIndex: nameGramIndex,
                extensionIndex: extensionIndex
            )
        }

        func updatingMetadata(for upserts: [String: FileRecord]) -> SearchSnapshot? {
            guard hasSortedOrder, !upserts.isEmpty else { return nil }

            var existingIndices: [String: Int] = [:]
            existingIndices.reserveCapacity(upserts.count)
            for path in upserts.keys {
                if let rowID = store.rowID(forPath: path) {
                    existingIndices[path] = rowID
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

            let updatedStore = HeapPagedRecordStore(records: updatedRecords)
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
                extensionIndex: extensionIndex,
                visibleCount: Self.makeVisibleCount(store: updatedStore),
                hasSortedOrder: true
            )
        }

        func addingNameGramIndex() -> SearchSnapshot {
            guard nameGramIndex == nil else { return self }
            return SearchSnapshot(
                store: store,
                modifiedDescending: modifiedDescending,
                gramIndex: gramIndex,
                nameGramIndex: Self.makeNameGramIndex(store: store),
                extensionIndex: extensionIndex,
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
                extensionIndex: extensionIndex.isEmpty ? extensionData.extensionIndex : extensionIndex,
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
                extensionIndex: extensionIndex,
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
                extensionIndex: extensionIndex,
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

        func candidatePathIndicesByComponentExpansion(
            containing token: String,
            shouldCancel: @Sendable () -> Bool
        ) -> [Int32]? {
            guard
                gramIndex == nil,
                nameGramIndex != nil,
                !token.isEmpty,
                !FileIndex.tokenContainsPathSeparator(token),
                let componentCandidates = candidateNameIndices(containing: Array(token.utf8))
            else {
                return nil
            }

            var directMatches = Set<Int>()
            directMatches.reserveCapacity(componentCandidates.count)
            for candidate in componentCandidates {
                let rowID = Int(candidate)
                guard rowID >= 0, rowID < count else { continue }
                if store.normalizedName(at: rowID).contains(token) {
                    directMatches.insert(rowID)
                }
            }

            guard !directMatches.isEmpty else { return nil }

            var memo = Array(repeating: Int8(-1), count: count)

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

                guard
                    let parent = store.parentRowID(at: rowID),
                    parent >= 0,
                    parent < count,
                    parent != rowID
                else {
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
            (0..<store.count).sorted {
                modifiedDescendingPrecedes($0, $1, store: store)
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
            extensionIndex: [String: [Int32]]
        ) -> SearchStructureDiagnostics {
            SearchStructureDiagnostics(
                pathGramIndexEnabled: pathGramIndexEnabled,
                pathGramKeyCount: gramIndex?.keyCount ?? 0,
                pathGramPostingCount: gramIndex?.postingCount ?? 0,
                nameGramKeyCount: nameGramIndex?.keyCount ?? 0,
                nameGramPostingCount: nameGramIndex?.postingCount ?? 0,
                extensionKeyCount: extensionIndex.count,
                extensionPostingCount: extensionIndex.values.reduce(0) { $0 + $1.count }
            )
        }

        private static func makeNameGramIndex(store: RecordStore) -> MappedIntPostingIndex? {
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

            return try? MappedIntPostingIndex.build(from: index, temporaryName: "att-name-postings")
        }

        private static func makeVisibleCount(store: RecordStore) -> Int {
            var count = 0

            for recordIndex in 0..<store.count where !store.isHidden(at: recordIndex) {
                count += 1
            }

            return count
        }

        private static func makeExtensionIndexAndVisibleCount(store: RecordStore) -> (extensionIndex: [String: [Int32]], visibleCount: Int) {
            var index: [String: [Int32]] = [:]
            var visibleCount = 0

            for recordIndex in 0..<store.count {
                if !store.isHidden(at: recordIndex) {
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
    private let legacyStreamingSnapshotURL: URL
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
        self.snapshotURL = supportDirectory.appendingPathComponent("filename-index-v4.attindex", isDirectory: true)
        self.legacyStreamingSnapshotURL = supportDirectory.appendingPathComponent("filename-index-v2.jsonl", isDirectory: false)
        self.legacySnapshotURL = supportDirectory.appendingPathComponent("filename-index.json", isDirectory: false)
        cleanupStaleTemporaryFiles()
        cleanupLegacySnapshotFiles()

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

        func appendMatch(rowID: Int, score: Int) {
            let record = snapshot.view(at: rowID)
            guard request.includeHidden || !Self.recordIsHidden(record) else { return }
            total += 1
            guard boundedMaxResults > 0 else { return }
            matches.append(SearchMatch(rowID: rowID, score: score))
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        if parsedQuery.isEmpty {
            if let orderedRecords = snapshot.orderedIndices(for: request.sort, queryIsEmpty: true) {
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

                    let record = snapshot.view(at: index)
                    guard request.includeHidden || !record.isHidden else {
                        continue
                    }

                    matchedVisibleCount += 1
                    if matches.count < boundedMaxResults {
                        matches.append(SearchMatch(rowID: index, score: 0))
                    } else if canStopAtResultLimit {
                        break
                    }
                }

                total = request.includeHidden ? snapshot.count : (snapshot.visibleCount ?? matchedVisibleCount)
            } else {
                for index in 0..<snapshot.count {
                    if index.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }
                    appendMatch(rowID: index, score: 0)
                }
            }
        } else {
            if let fastResponse = Self.fastLargePathSubstringSearch(
                snapshot: snapshot,
                request: request,
                parsedQuery: parsedQuery,
                maxResults: boundedMaxResults,
                started: started,
                snapshotRevision: snapshotRevision,
                shouldCancel: shouldCancel
            ) {
                return fastResponse
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
                return indexedResponse
            }

            for index in 0..<snapshot.count {
                if index.isMultiple(of: 512), shouldCancel() {
                    return nil
                }
                let record = snapshot.view(at: index)
                if let score = FuzzyMatcher.score(record: record, parsedQuery: parsedQuery) {
                    appendMatch(rowID: index, score: score)
                }
            }
        }

        guard !shouldCancel() else { return nil }

        if shouldSortMatches {
            sortAndLimitMatches()
        }

        guard !shouldCancel() else { return nil }

        return SearchResponse(
            results: Self.materialize(matches, from: snapshot),
            totalMatches: total,
            elapsed: Date().timeIntervalSince(started),
            snapshotRevision: snapshotRevision
        )
    }

    private static func materialize(_ matches: [SearchMatch], from snapshot: SearchSnapshot) -> [SearchResult] {
        matches.map { SearchResult(record: snapshot.record(at: $0.rowID), score: $0.score) }
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

            let orderedRows = request.sort.ascending ? snapshot.modifiedAscending : snapshot.modifiedDescending
            var matches: [SearchMatch] = []
            matches.reserveCapacity(min(candidateSet.count, maxResults))

            if request.includeHidden {
                if maxResults > 0 {
                    for (offset, rowID) in orderedRows.enumerated() {
                        if offset.isMultiple(of: 512), shouldCancel() {
                            return nil
                        }
                        guard candidateSet.contains(rowID) else { continue }
                        matches.append(SearchMatch(rowID: rowID, score: 0))
                        if matches.count >= maxResults {
                            break
                        }
                    }
                }

                guard candidateSet.count >= max(maxResults, 1) || candidateSet.count > 1_000 else {
                    return nil
                }
            } else {
                var total = 0
                var hiddenCache: [Int: Bool] = [:]
                for (offset, rowID) in orderedRows.enumerated() {
                    if offset.isMultiple(of: 512), shouldCancel() {
                        return nil
                    }
                    guard candidateSet.contains(rowID) else { continue }

                    guard !snapshot.isHiddenInPath(at: rowID, cache: &hiddenCache) else { continue }

                    total += 1
                    if maxResults > 0, matches.count < maxResults {
                        matches.append(SearchMatch(rowID: rowID, score: 0))
                    }
                }

                guard total >= max(maxResults, 1) || total > 1_000 else {
                    return nil
                }

                guard !shouldCancel() else { return nil }
                return SearchResponse(
                    results: materialize(matches, from: snapshot),
                    totalMatches: total,
                    elapsed: Date().timeIntervalSince(started),
                    snapshotRevision: snapshotRevision,
                    usesIndexedCandidates: true
                )
            }

            guard !shouldCancel() else { return nil }
            return SearchResponse(
                results: materialize(matches, from: snapshot),
                totalMatches: candidateSet.count,
                elapsed: Date().timeIntervalSince(started),
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true
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

        var hiddenCache: [Int: Bool] = [:]
        for (offset, candidate) in exactPathCandidates.enumerated() {
            if offset.isMultiple(of: 512), shouldCancel() {
                return nil
            }

            let rowID = Int(candidate)
            guard rowID >= 0, rowID < snapshot.count else { continue }
            guard request.includeHidden || !snapshot.isHiddenInPath(at: rowID, cache: &hiddenCache) else { continue }

            total += 1
            guard maxResults > 0 else { continue }

            matches.append(SearchMatch(rowID: rowID, score: 0))
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
        return SearchResponse(
            results: materialize(matches, from: snapshot),
            totalMatches: total,
            elapsed: Date().timeIntervalSince(started),
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true
        )
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
            return SearchResponse(
                results: [],
                totalMatches: 0,
                elapsed: Date().timeIntervalSince(started),
                snapshotRevision: snapshotRevision,
                usesIndexedCandidates: true
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

            let record = snapshot.view(at: index)
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

            matches.append(SearchMatch(rowID: index, score: score))
            if matches.count > trimThreshold {
                trimMatches()
            }
        }

        guard !shouldCancel() else { return nil }
        sortAndLimitMatches()

        guard !shouldCancel() else { return nil }
        return SearchResponse(
            results: materialize(matches, from: snapshot),
            totalMatches: total,
            elapsed: Date().timeIntervalSince(started),
            snapshotRevision: snapshotRevision,
            usesIndexedCandidates: true
        )
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
        case .kind:
            return nil
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
            return candidateIndices(snapshot: snapshot, requiredFragments: wildcardRequiredFragments(from: token), field: candidateField)
        case .fuzzy:
            if tokenContainsPathSeparator(token) {
                guard field != .name else {
                    return nil
                }
                return candidateIndices(snapshot: snapshot, requiredFragments: pathLiteralFragments(from: token), field: .path)
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
            return candidateIndices(snapshot: snapshot, requiredFragments: wildcardRequiredFragments(from: token), field: .path)
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
            return snapshot.candidatePathIndices(containingAllBytes: distinctBytes)
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
        try? fileManager.removeItem(at: legacyStreamingSnapshotURL)
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
            status = "Loaded \(snapshot.count) indexed files"
            indexing = false
            discoveredCount = snapshot.count
            searchableCount = snapshot.count
            optimizedCount = loadedOptimized ? snapshot.count : 0
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

    private func rebuild(roots rootURLs: [URL], generation currentGeneration: UInt64) {
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
            searchableCount = snapshot.count
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
            let packageURL = supportDirectory.appendingPathComponent("filename-index-v4-\(UUID().uuidString).attindex.tmp", isDirectory: true)
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
            let mappedStore = try MappedRecordStore(packageURL: packageURL)
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
            optimized: snapshot.count,
            generation: currentGeneration
        )

        guard isCurrentGeneration(currentGeneration) else { return }
        publishRebuildStatus(
            phase: .saving,
            status: "Saving index",
            discovered: records.count,
            searchable: snapshot.count,
            optimized: snapshot.count,
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
            searchableCount = snapshot.count
            optimizedCount = snapshot.count
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
            discoveredCount = snapshot.count
            searchableCount = snapshot.count
            optimizedCount = snapshot.count
            status = "Loaded \(snapshot.count) indexed files"
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
            discoveredCount = snapshot.count
            searchableCount = snapshot.count
            optimizedCount = optimized
            self.status = status
            lastUpdated = Date()
            return true
        }

        if didApply {
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

        let previousSnapshot = lock.withLock { searchSnapshot }
        var deletedRows = Set<Int>()

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
        let snapshot = SearchSnapshot(store: overlayStore, buildsSearchStructures: false)
        let changedPathCount = upserts.count + deletedPrefixes.count

        lock.withLock {
            searchSnapshot = snapshot
            searchSnapshotRevision &+= 1
            status = "Updated \(changedPathCount) changed path\(changedPathCount == 1 ? "" : "s")"
            phase = .ready
            indexing = false
            discoveredCount = snapshot.count
            searchableCount = snapshot.count
            optimizedCount = 0
            recordsByPath.removeAll(keepingCapacity: false)
            lastUpdated = Date()
            completedRefreshBatches &+= 1
        }

        publishStats()
        schedulePersist()
        MemoryTelemetry.log(
            "refresh.overlayApplied",
            records: Self.metrics(for: snapshot.store),
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
            discoveredCount = snapshot.count
            searchableCount = snapshot.count
            optimizedCount = isIndexing ? 0 : snapshot.count
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
            try persistMappedSnapshot(
                roots: snapshotData.roots,
                exclusionPatterns: snapshotData.exclusionPatterns,
                store: snapshotData.snapshot.store
            )
            try persistSearchStructures(for: snapshotData.snapshot, packageURL: snapshotURL)
            MemoryTelemetry.log(
                "snapshot.persist.finished",
                records: metrics,
                structures: lock.withLock { searchSnapshot.diagnostics },
                activeIndexJobs: currentActiveIndexJobCount()
            )
            if snapshotData.snapshot.store.kind == .overlay, let loaded = loadPersistedSnapshot() {
                let compactedSnapshot = SearchSnapshot(store: loaded.store, persistedStructures: loaded.searchStructures)
                lock.withLock {
                    searchSnapshot = compactedSnapshot
                    searchSnapshotRevision &+= 1
                    recordsByPath.removeAll(keepingCapacity: false)
                    discoveredCount = compactedSnapshot.count
                    searchableCount = compactedSnapshot.count
                    optimizedCount = compactedSnapshot.isOptimizedForSearch ? compactedSnapshot.count : 0
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
            publishStats()
            return false
        }
    }

    private func persistMappedSnapshot(roots: [String], exclusionPatterns: [String], store: RecordStore) throws {
        cleanupStaleTemporaryFiles()
        let temporaryURL = supportDirectory.appendingPathComponent("filename-index-v4-\(UUID().uuidString).attindex.tmp", isDirectory: true)
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
    }

    private func persistSearchStructures(for snapshot: SearchSnapshot, packageURL: URL) throws {
        let modifiedOrderURL = packageURL.appendingPathComponent("modifiedOrder.bin", isDirectory: false)
        if snapshot.hasSortedOrder {
            try CompactSearchStructureFiles.writeModifiedOrder(
                snapshot.modifiedDescending,
                to: modifiedOrderURL
            )
        } else {
            try Data().write(to: modifiedOrderURL, options: .atomic)
        }

        let namePostingsURL = packageURL.appendingPathComponent("namePostings.bin", isDirectory: false)
        if let nameGramIndex = snapshot.nameGramIndex {
            try nameGramIndex.write(to: namePostingsURL)
        } else {
            try Data().write(to: namePostingsURL, options: .atomic)
        }

        let pathPostingsURL = packageURL.appendingPathComponent("pathPostings.bin", isDirectory: false)
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
            let manifestURL = snapshotURL.appendingPathComponent("manifest.json", isDirectory: false)
            let manifest = try JSONDecoder().decode(CompactSnapshotManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == Self.snapshotSchemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let store = try MappedRecordStore(packageURL: snapshotURL)
            guard store.count == manifest.recordCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return LoadedMappedSnapshot(
                manifest: manifest,
                store: store,
                searchStructures: loadPersistedSearchStructures(packageURL: snapshotURL, recordCount: store.count)
            )
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            MemoryTelemetry.log("snapshot.load.v4Failed", activeIndexJobs: currentActiveIndexJobCount())
            return nil
        }
    }

    private func loadPersistedSearchStructures(packageURL: URL, recordCount: Int) -> PersistedSearchStructures {
        let modifiedDescending = CompactSearchStructureFiles.loadModifiedOrder(
            from: packageURL.appendingPathComponent("modifiedOrder.bin", isDirectory: false),
            expectedCount: recordCount,
            fileManager: fileManager
        )
        let nameGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent("namePostings.bin", isDirectory: false),
            fileManager: fileManager
        )
        let pathGramIndex = try? MappedIntPostingIndex.load(
            from: packageURL.appendingPathComponent("pathPostings.bin", isDirectory: false),
            fileManager: fileManager
        )

        return PersistedSearchStructures(
            modifiedDescending: modifiedDescending,
            nameGramIndex: nameGramIndex ?? nil,
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
        for url in contents {
            let name = url.lastPathComponent
            let isTemporary = name.hasPrefix(".dat.nosync")
                || (name.hasPrefix("filename-index-v2-") && name.hasSuffix(".jsonl.tmp"))
                || (name.hasPrefix("filename-index-v4-") && name.hasSuffix(".attindex.tmp"))
                || name == "filename-index.json.tmp"
            guard isTemporary else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard minimumAge <= 0 || now.timeIntervalSince(modified) >= minimumAge else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func cleanupLegacySnapshotFiles() {
        try? fileManager.removeItem(at: legacyStreamingSnapshotURL)
        try? fileManager.removeItem(at: legacySnapshotURL)
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
                indexedCount: searchSnapshot.count,
                snapshotRevision: searchSnapshotRevision,
                phase: phase,
                discoveredCount: discoveredCount,
                searchableCount: searchableCount,
                optimizedCount: optimizedCount,
                recordStoreKind: searchSnapshot.store.kind,
                mappedByteSize: searchSnapshot.store.mappedByteSize,
                heapPageCount: searchSnapshot.store.heapPageCount,
                overlayCount: searchSnapshot.store.overlayCount,
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
                searchableCount = snapshot.count
                optimizedCount = buildsSearchStructures ? snapshot.count : 0
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
                    indexedCount: searchSnapshot.count,
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
            IndexStats(
                indexedCount: searchSnapshot.count,
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
            rhs: snapshot.view(at: rhs.rowID),
            rhsScore: rhs.score,
            sort: sort,
            queryIsEmpty: queryIsEmpty
        )
    }

    private static func compare(_ lhs: SearchResult, _ rhs: SearchResult, sort: SortSpec, queryIsEmpty: Bool) -> Bool {
        compareRecords(
            lhs: lhs.record,
            lhsScore: lhs.score,
            rhs: rhs.record,
            rhsScore: rhs.score,
            sort: sort,
            queryIsEmpty: queryIsEmpty
        )
    }

    private static func compareRecords<L: SearchRecordReadable, R: SearchRecordReadable>(
        lhs: L,
        lhsScore: Int,
        rhs: R,
        rhsScore: Int,
        sort: SortSpec,
        queryIsEmpty: Bool
    ) -> Bool {
        let ascending = sort.ascending

        func ordered<T: Comparable>(_ left: T, _ right: T) -> Bool? {
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        }

        let primary: Bool?
        switch sort.column {
        case .relevance:
            if queryIsEmpty {
                primary = lhs.modifiedTime == rhs.modifiedTime ? nil : lhs.modifiedTime > rhs.modifiedTime
            } else if lhsScore != rhsScore {
                primary = lhsScore > rhsScore
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
